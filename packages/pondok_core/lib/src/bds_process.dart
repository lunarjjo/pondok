/// Process supervisor for a real `bedrock_server` child process.
///
/// Every semantic below was verified against the official 1.26.52.3 Linux
/// binary during the Phase 0 PoC (docs/evidence/):
///
/// * the server must be started with `LD_LIBRARY_PATH=.` inside its own
///   directory (official instruction from the download page);
/// * commands are plain lines on stdin; `stop` produces
///   `Server stop requested.` → `Stopping server...` → `Quit correctly`
///   → **exit code 0**;
/// * an externally killed process surfaces a non-zero/abnormal exit code —
///   this is the crash signal;
/// * startup completes when the `Server started.` line appears (~2 s on a
///   fast host; much longer under translation on a phone — the watchdog
///   budget is therefore configurable and generous by default).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'console_line.dart';
import 'security.dart';

/// Lifecycle states of a supervised server process.
enum BdsState { idle, starting, running, stopping, stopped, crashed, startupFailed }

/// How the process ended — derived strictly from observable facts.
enum BdsExitKind { cleanStop, killedByUs, crashed, unknown }

class BdsExit {
  final int code;
  final BdsExitKind kind;
  final String detail;
  const BdsExit(this.code, this.kind, this.detail);

  @override
  String toString() => 'BdsExit(code: $code, kind: $kind, $detail)';
}

/// Configuration for one supervised start.
class BdsProcessConfig {
  /// Absolute path to the bedrock_server executable (or a wrapper such as
  /// box64 — see RuntimeProfile in the app layer).
  final String binary;

  /// Working directory = the server instance directory (where
  /// server.properties and worlds/ live).
  final String workingDir;

  /// Extra environment. LD_LIBRARY_PATH is always set to include the binary's
  /// own directory, matching the official launch instruction.
  final Map<String, String> environment;

  /// Time budget for seeing `Server started.`.
  final Duration startupTimeout;

  /// Graceful window after sending `stop` before escalating to SIGTERM.
  final Duration gracefulStopTimeout;

  /// Window after SIGTERM before SIGKILL (last resort).
  final Duration sigtermTimeout;

  const BdsProcessConfig({
    required this.binary,
    required this.workingDir,
    this.environment = const {},
    this.startupTimeout = const Duration(minutes: 10),
    this.gracefulStopTimeout = const Duration(seconds: 60),
    this.sigtermTimeout = const Duration(seconds: 10),
  });
}

/// Supervised process handle.
class BdsProcess {
  final BdsProcessConfig config;

  Process? _process;
  final _parser = ConsoleParser();
  final _lines = StreamController<ConsoleLine>.broadcast();
  final _stateChanges = StreamController<BdsState>.broadcast();

  Timer? _startupWatchdog;
  Completer<void>? _startupCompleter;
  Completer<BdsExit>? _exitCompleter;
  BdsState _state = BdsState.idle;
  BdsExit? _lastExit;
  DateTime? _startedAt;
  bool _escalatedKill = false;
  bool _startupFailed = false;

  BdsProcess(this.config);

  // ---------------------------------------------------------------- streams

  /// Structured console lines (stdout + stderr merged, parsed).
  Stream<ConsoleLine> get lines => _lines.stream;

  Stream<BdsState> get stateChanges => _stateChanges.stream;

  BdsState get state => _state;

  BdsExit? get lastExit => _lastExit;

  int? get pid => _process?.pid;

  /// Wall-clock uptime of the current/last run.
  Duration? get uptime =>
      _startedAt == null ? null : DateTime.now().difference(_startedAt!);

  bool get isAlive => _state == BdsState.starting || _state == BdsState.running;

  // ----------------------------------------------------------------- start

  /// Starts the process and completes when the server reports
  /// `Server started.` — or throws [BdsStartupException] when the watchdog
  /// fires or the process dies first.
  Future<void> start() async {
    if (isAlive) throw StateError('process already running');
    _setState(BdsState.starting);
    _startedAt = DateTime.now();
    _startupCompleter = Completer<void>();
    _exitCompleter = Completer<BdsExit>();
    _escalatedKill = false;

    final binDir = File(config.binary).parent.path;
    final env = <String, String>{
      ...Platform.environment,
      ...config.environment,
      'LD_LIBRARY_PATH': [
        if (config.environment['LD_LIBRARY_PATH'] case final v?) v,
        binDir,
        '.',
      ].join(':'),
    };

    try {
      _process = await Process.start(
        config.binary,
        const [],
        workingDirectory: config.workingDir,
        environment: env,
      );
    } catch (e) {
      _setState(BdsState.startupFailed);
      _startupCompleter!.completeError(BdsStartupException('spawn failed: $e'));
      _exitCompleter!.complete(BdsExit(-1, BdsExitKind.unknown, 'spawn failed: $e'));
      rethrow;
    }

    _watchStdout(_process!.stdout);
    _watchStdout(_process!.stderr);

    _startupWatchdog = Timer(config.startupTimeout, () {
      if (_state == BdsState.starting && !_startupCompleter!.isCompleted) {
        _startupFailed = true;
        // Set the state BEFORE completing the error: start()'s caller may
        // observe it immediately, while _onExit runs asynchronously later.
        _setState(BdsState.startupFailed);
        _startupCompleter!.completeError(
            BdsStartupException('no "Server started." within ${config.startupTimeout}'));
        _startupFailedShutdown();
      }
    });

    _process!.exitCode.then((code) => _onExit(code));

    // Wait for either startup success, startup failure, or early death.
    final earlyExit = _exitCompleter!.future.then((_) => true);
    try {
      await Future.any([
        _startupCompleter!.future,
        earlyExit,
      ]);
    } on BdsStartupException {
      rethrow;
    }
    if (_state == BdsState.startupFailed || _state == BdsState.crashed) {
      throw BdsStartupException('process died during startup: ${_lastExit?.detail}');
    }
  }

  void _watchStdout(Stream<List<int>> stream) {
    stream
        .transform(const LineStreamSplitter())
        .listen((line) => _onLine(line), onDone: () {}, onError: (Object e) {
      // A dead pipe is expected during shutdown; ignore.
    });
  }

  void _onLine(String line) {
    final parsed = _parser.feed(line);
    if (parsed == null) return;
    _lines.add(parsed);

    if (_state == BdsState.starting &&
        ConsoleEvents.serverStarted.hasMatch(parsed.message)) {
      _startupWatchdog?.cancel();
      _setState(BdsState.running);
      if (!_startupCompleter!.isCompleted) _startupCompleter!.complete();
    }
  }

  // --------------------------------------------------------------- commands

  /// Sends a console command (sanitized first). Returns the sanitized form.
  Future<String> sendCommand(String command) async {
    final clean = CommandSanitizer.sanitize(command);
    final stdin = _process?.stdin;
    // NOTE: `stopping` is deliberately allowed here. An earlier version
    // required isAlive (starting|running) only, so stop() — which sets the
    // state to stopping BEFORE issuing the `stop` command — silently failed
    // to send anything, the graceful window expired, and every "stop"
    // degraded to SIGTERM. Caught by the real-BDS integration suite
    // (exit -15 instead of 0); see DEBUG_LOG.md.
    final commandable = isAlive || _state == BdsState.stopping;
    if (stdin == null || !commandable) throw StateError('server not running');
    stdin.writeln(clean);
    await stdin.flush();
    return clean;
  }

  // ------------------------------------------------------------------ stop

  /// Graceful stop ladder: `stop` command → wait → SIGTERM → wait → SIGKILL.
  /// Returns how the process actually ended.
  Future<BdsExit> stop() async {
    if (!isAlive) return _lastExit ?? const BdsExit(0, BdsExitKind.unknown, 'not running');
    _setState(BdsState.stopping);

    try {
      await sendCommand('stop');
    } catch (_) {
      // stdin already closed — escalate immediately.
    }

    final exit = await _exitCompleter!.future
        .timeout(config.gracefulStopTimeout, onTimeout: () => _escalate('graceful window elapsed'));
    return exit;
  }

  Future<BdsExit> _escalate(String reason) async {
    if (_process == null) return _lastExit!;
    _escalatedKill = true;
    _emitLine('pondok: escalating shutdown ($reason) → SIGTERM');
    Process.killPid(_process!.pid, ProcessSignal.sigterm);
    final termExit = await _exitCompleter!.future.timeout(
      config.sigtermTimeout,
      onTimeout: () {
        _emitLine('pondok: SIGTERM ignored → SIGKILL');
        Process.killPid(_process!.pid, ProcessSignal.sigkill);
        return _exitCompleter!.future;
      },
    );
    return termExit;
  }

  void _startupFailedShutdown() {
    _escalatedKill = true;
    _process?.kill();
  }

  // ----------------------------------------------------------------- events

  Future<void> _onExit(int code) async {
    _startupWatchdog?.cancel();
    final flushed = _parser.flush();
    if (flushed != null && !_lines.isClosed) _lines.add(flushed);
    await _lines.close();
    try {
      await _process?.stdin.close();
    } catch (_) {
      // stdin already closed during shutdown — fine.
    }

    final kind = _classifyExit(code);
    _lastExit = BdsExit(code, kind, 'pid ${_process?.pid}');
    if (_startupFailed) {
      _setState(BdsState.startupFailed);
    } else {
      _setState(kind == BdsExitKind.cleanStop || _escalatedKill
          ? BdsState.stopped
          : BdsState.crashed);
    }
    if (!_exitCompleter!.isCompleted) _exitCompleter!.complete(_lastExit!);
    if (!_startupCompleter!.isCompleted && kind != BdsExitKind.cleanStop) {
      // Died before finishing startup — surface as startup failure.
      _startupCompleter!.completeError(
          BdsStartupException('died during startup: $code'));
    }
  }

  BdsExitKind _classifyExit(int code) {
    if (code == 0) return BdsExitKind.cleanStop;
    if (_state == BdsState.stopping || _escalatedKill) return BdsExitKind.killedByUs;
    return BdsExitKind.crashed;
  }

  void _setState(BdsState s) {
    _state = s;
    // The exit handler can resume after dispose() closed the controller
    // (async gap) — guarded instead of throwing into the exit path.
    if (!_stateChanges.isClosed) _stateChanges.add(s);
  }

  void _emitLine(String msg) {
    if (_lines.isClosed) return;
    _lines.add(ConsoleLine(level: ConsoleLevel.raw, message: msg, raw: msg));
  }

  /// Releases stream controllers (idempotent; call after the process ended).
  Future<void> dispose() async {
    if (!_stateChanges.isClosed) await _stateChanges.close();
  }
}

class BdsStartupException implements Exception {
  final String reason;
  BdsStartupException(this.reason);
  @override
  String toString() => 'BdsStartupException: $reason';
}

/// Splits a byte stream into lines without dropping a trailing line that
/// lacks a newline (real servers emit `Quit correctly` without one — the
/// Phase 0 evidence depends on capturing it).
class LineStreamSplitter extends StreamTransformerBase<List<int>, String> {
  const LineStreamSplitter();

  @override
  Stream<String> bind(Stream<List<int>> stream) {
    late final StreamController<String> controller;
    var buffer = <int>[];

    controller = StreamController<String>(
      onListen: () {
        stream.listen(
          (chunk) {
            buffer.addAll(chunk);
            var idx = buffer.indexOf(10);
            while (idx >= 0) {
              final lineBytes = buffer.sublist(0, idx);
              buffer = buffer.sublist(idx + 1);
              controller.add(_decodeLossy(lineBytes));
              idx = buffer.indexOf(10);
            }
          },
          onDone: () {
            if (buffer.isNotEmpty) {
              controller.add(_decodeLossy(buffer));
              buffer = [];
            }
            controller.close();
          },
          onError: controller.addError,
        );
      },
    );
    return controller.stream;
  }
}

/// UTF-8 decode that never throws (BDS can emit odd bytes in crash dumps).
String _decodeLossy(List<int> bytes) {
  try {
    return utf8.decode(bytes, allowMalformed: true);
  } catch (_) {
    return bytes.map((b) => b < 32 ? 0x20 : b).map(String.fromCharCode).join();
  }
}

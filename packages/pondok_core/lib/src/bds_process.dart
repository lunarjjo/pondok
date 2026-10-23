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

  /// Last raw output lines the process emitted (stdout + stderr merged),
  /// newest last — the single most valuable crash clue, previously lost to
  /// the exit race (D-17): the child writes its dying message into the pipe
  /// microseconds before the kernel reaps it, and `exitCode` completes
  /// BEFORE the pipe bytes reach Dart's event loop.
  final String outputTail;

  const BdsExit(this.code, this.kind, this.detail, {this.outputTail = ''});

  @override
  String toString() => 'BdsExit(code: $code, kind: $kind, $detail)';
}

/// Human-readable reading of a raw wait status — Dart reports the exit code
/// as a NEGATIVE number when the child was killed by a signal, so a death by
/// SIGILL (unsupported CPU instruction) is distinguishable from SIGSYS
/// (seccomp) and from a plain `exit(1)`.
String describeExitCode(int code) {
  if (code >= 0) {
    return code == 0 ? 'exit 0 (normal)' : 'exit $code';
  }
  const signals = {
    1: 'SIGHUP', 2: 'SIGINT', 3: 'SIGQUIT', 4: 'SIGILL',
    5: 'SIGTRAP', 6: 'SIGABRT', 7: 'SIGBUS', 8: 'SIGFPE',
    9: 'SIGKILL', 11: 'SIGSEGV', 13: 'SIGPIPE', 15: 'SIGTERM',
    31: 'SIGSYS',
  };
  const hints = {
    4: ' — instruksi ilegal: CPU/chipset mungkin tak mendukung instruksi yang dipakai penerjemah',
    6: ' — abort internal (libc/runtime menemukan kondisi tak valid)',
    7: ' — akses memori tak selaras/tak valid',
    11: ' — kesalahan memori (dynarec/JIT umumnya)',
    31: ' — syscall diblokir filter keamanan (seccomp) Android/OEM',
  };
  final sig = -code;
  final name = signals[sig] ?? 'sinyal $sig';
  return 'dibunuh $name${hints[sig] ?? ''}';
}

/// Configuration for one supervised start.
class BdsProcessConfig {
  /// Absolute path to the executable (or a wrapper such as proot — see
  /// RuntimeProfile in bundled_runtime.dart).
  final String binary;

  /// Arguments for the executable. Empty for a direct bedrock_server
  /// launch; a proot wrapper fills these in (rootfs, binds, inner command).
  final List<String> args;

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
    this.args = const [],
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

  /// Ring of the most recent RAW lines (pre-parse), kept for exit detail.
  final _rawTail = <String>[];
  static const _maxTail = 40;

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
        config.args,
        workingDirectory: config.workingDir,
        environment: env,
      );
    } catch (e) {
      // errno 13 = EACCES: the kernel refused to execute the binary at all.
      // On Android this is the classic SELinux exec-from-app-storage denial
      // (or an OEM hardening of it) — surface it as such instead of a bare
      // 'spawn failed', which tells the user nothing actionable.
      var hint = '';
      if (e is ProcessException && (e.errorCode == 13 || e.errorCode == 8)) {
        hint = ' (izin eksekusi ditolak oleh sistem — pembatasan Android/OEM pada penyimpanan aplikasi)';
      } else if (e is ProcessException && e.errorCode == 2) {
        hint = ' (berkas tidak ditemukan — pohon runtime rusak; coba pasang ulang dari APK)';
      }
      _setState(BdsState.startupFailed);
      // Uniform contract: start() failures surface as BdsStartupException
      // (an earlier `rethrow` leaked the raw ProcessException instead —
      // callers keyed on the wrapper missed the reason entirely). The
      // startup completer is left uncompleted on purpose: nobody can await
      // it anymore, and completing it with an error would surface as an
      // unhandled async error on top of the thrown one.
      final wrapped = BdsStartupException('spawn failed: $e$hint');
      _lastExit = BdsExit(-1, BdsExitKind.unknown, 'spawn failed: $e$hint');
      _exitCompleter!.complete(_lastExit!);
      throw wrapped;
    }

    // D-17 fix — drain BEFORE finalize. `exitCode` completes when the child
    // is reaped, but the last stderr bytes can still be sitting in the pipe;
    // closing the line stream at that moment silently discards the exact
    // message that explains the death. Each watcher signals a Completer when
    // its pipe reaches EOF; _superviseExit waits for BOTH (bounded) before
    // classifying the exit.
    final outDone = Completer<void>();
    final errDone = Completer<void>();
    _watchStdout(_process!.stdout, outDone);
    _watchStdout(_process!.stderr, errDone);

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

    _superviseExit(outDone, errDone);

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

  /// Waits for process exit AND both pipes to reach EOF (bounded by a short
  /// timeout in case an orphaned grandchild inherited the descriptors), then
  /// finalizes. Order matters: classify first, publish last.
  Future<void> _superviseExit(
      Completer<void> outDone, Completer<void> errDone) async {
    final code = await _process!.exitCode;
    // Bounded drain: normally EOF arrives immediately after exit; if an
    // orphan holds the pipe open, do not stall the crash state forever.
    await Future.any([
      Future.wait([outDone.future, errDone.future]),
      Future<void>.delayed(const Duration(seconds: 5)),
    ]);
    _onExit(code);
  }

  void _watchStdout(Stream<List<int>> stream, Completer<void> done) {
    stream
        .transform(const LineStreamSplitter())
        .listen((line) {
      _rawTail.add(line);
      if (_rawTail.length > _maxTail) {
        _rawTail.removeRange(0, _rawTail.length - _maxTail);
      }
      _onLine(line);
    }, onDone: () {
      if (!done.isCompleted) done.complete();
    }, onError: (Object e) {
      // A dead pipe is expected during shutdown; ignore — but still mark
      // EOF so the exit supervisor is never stuck waiting on this pipe.
      if (!done.isCompleted) done.complete();
    });
  }

  /// The raw tail as plain text (for BdsExit and the diagnostics UI).
  String get rawTailText => _rawTail.join('\n');

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
    _lastExit = BdsExit(
      code,
      kind,
      'pid ${_process?.pid} · ${describeExitCode(code)}',
      outputTail: rawTailText,
    );
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

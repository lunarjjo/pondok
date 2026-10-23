import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:pondok_core/pondok_core.dart';

import 'device_info.dart';

/// Runs the actual server through the bundled stack and exposes exactly
/// what the home screen needs: state, last console lines, uptime, and —
/// since D-17 — the full story of WHY a start failed.
///
/// Launch policy (the D-17 fix for "Kehilangan proses (crash)" with zero
/// visible output):
///
///   1. try the persisted launch mode (PROOT by default — the CI-proven
///      stack; DIRECT after a successful fallback);
///   2. on failure, automatically try the other profile — DIRECT runs
///      box64 through the rootfs's own ld.so without ptrace, so devices
///      whose kernels/OEMs break proot still get a server;
///   3. if both fail, run the on-device probe ladder and surface the
///      verdict + evidence instead of a bare "crash" badge;
///   4. nothing ever throws into the widget tree — the old code's
///      unhandled `server.start()` future silently swallowed the only
///      exception that carried the reason.
///
/// Every step is appended to the persistent runtime log as well.
class ServerController extends ChangeNotifier {
  final String baseDir;

  /// Injection points for widget tests.
  final Future<BdsProcessConfig> Function(String baseDir, LaunchMode mode)?
      profileFactory;
  final StackDiagnostics Function(String baseDir)? diagnosticsFactory;
  final Future<Map<String, String>> Function()? deviceInfoReader;

  ServerController({
    required this.baseDir,
    this.profileFactory,
    this.diagnosticsFactory,
    this.deviceInfoReader,
  }) : _log = RuntimeLog(baseDir);

  final RuntimeLog _log;

  BdsProcess? _process;
  BdsState _state = BdsState.idle;
  BdsExit? _lastExit;
  DateTime? _startedAt;
  LaunchMode _launchMode = LaunchMode.proot;
  bool _modeLoaded = false;

  String? _failure;
  List<ProbeResult>? _diagnostics;
  bool _diagnosing = false;
  Map<String, String> _deviceFacts = const {};

  StreamSubscription<BdsState>? _stateSub;
  StreamSubscription<ConsoleLine>? _linesSub;

  /// Ring buffer of the most recent console lines (bounded — a server can
  /// emit hundreds of lines per minute under load).
  final _lines = <ConsoleLine>[];
  static const _maxLines = 400;

  BdsState get state => _state;
  BdsExit? get lastExit => _lastExit;
  bool get isRunning =>
      _state == BdsState.starting || _state == BdsState.running;

  LaunchMode get launchMode => _launchMode;
  String get launchModeLabel =>
      _launchMode == LaunchMode.proot ? 'PROOT' : 'DIRECT';

  /// Human-readable reason of the last failed start (null when none).
  String? get failure => _failure;

  /// Probe ladder results (null until diagnostics ran).
  List<ProbeResult>? get diagnostics => _diagnostics;
  bool get diagnosing => _diagnosing;

  String get logPath => _log.path;

  List<ConsoleLine> get lines => List.unmodifiable(_lines);

  // ------------------------------------------------------------- lifecycle

  /// Loads the persisted launch mode + device facts. Cheap; called from the
  /// home screen boot; never blocks the UI on failure.
  Future<void> hydrate() async {
    if (!_modeLoaded) {
      _modeLoaded = true;
      try {
        final f = File('$baseDir/launch_mode.json');
        if (await f.exists()) {
          final d = jsonDecode(await f.readAsString());
          if (d is Map<String, dynamic> && d['mode'] == 'direct') {
            _launchMode = LaunchMode.direct;
          }
        }
      } catch (_) {}
      notifyListeners();
    }
    if (_deviceFacts.isEmpty) {
      final facts =
          await (deviceInfoReader?.call() ?? DeviceInfoService().read());
      _deviceFacts = facts;
      unawaited(_log.log('device: ${DeviceFacts(facts).describe()}'));
    }
  }

  Future<void> _persistMode() async {
    try {
      final f = File('$baseDir/launch_mode.json');
      await f.parent.create(recursive: true);
      await f.writeAsString(
          jsonEncode({'mode': _launchMode.name, 'at': DateTime.now().toIso8601String()}),
          flush: true);
    } catch (_) {}
  }

  Future<BdsProcessConfig> _profile(LaunchMode mode) async {
    if (profileFactory != null) return profileFactory!(baseDir, mode);
    if (mode == LaunchMode.direct) {
      final loader = await resolveRootfsLoader(baseDir);
      return directRuntimeProfile(baseDir, loader: loader);
    }
    return bundledRuntimeProfile(baseDir);
  }

  // ------------------------------------------------------------------ start

  Future<void> start() async {
    if (isRunning) return;
    await hydrate();
    _failure = null;
    _diagnostics = null;
    notifyListeners();

    unawaited(_log.log('start: mode ${_launchMode.name}'));

    await _startWithMode(_launchMode);
    if (isRunning) return;

    // Automatic fallback: the OTHER profile gets exactly one shot.
    final other =
        _launchMode == LaunchMode.proot ? LaunchMode.direct : LaunchMode.proot;
    unawaited(_log.log(
        'mode ${_launchMode.name} gagal (${_state.name}) → coba ${other.name}'));
    final previous = _failure;
    await _startWithMode(other);
    if (isRunning) {
      _launchMode = other;
      await _persistMode();
      unawaited(_log.log('fallback sukses: mode tersimpan = ${other.name}'));
      return;
    }
    _failure = previous != null && _failure != null
        ? '$previous\n— lalu mode cadangan juga gagal —\n$_failure'
        : _failure;

    // Both profiles dead: run the ladder and attach the verdict.
    await runDiagnostics();
  }

  Future<void> _startWithMode(LaunchMode mode) async {
    BdsProcess? proc;
    try {
      final profile = await _profile(mode);
      proc = BdsProcess(profile);
      await _attachProcess(proc);
      _startedAt = DateTime.now();
      _lines.clear();

      await proc.start();
      _state = proc.state;
      notifyListeners();
      return;
    } catch (e) {
      // e is BdsStartupException (or a spawn failure wrapped by it). The
      // exit object carries the decoded signal + captured output tail.
      final exit = proc?.lastExit;
      var reason = e.toString().replaceFirst('BdsStartupException: ', '');
      if (exit != null) {
        final tail = exit.outputTail.trim();
        if (tail.isNotEmpty) {
          reason = '$reason\nOutput proses terakhir:\n$tail';
        }
      }
      _failure = reason;
      _lastExit = exit ?? _lastExit;
      _state = proc?.state ?? BdsState.startupFailed;
      if (_state == BdsState.idle) _state = BdsState.startupFailed;
      notifyListeners();
      unawaited(_log.log('gagal (${mode.name}): $reason'));
      await _detachProcess(proc);
    }
  }

  Future<void> _attachProcess(BdsProcess proc) async {
    await _detachProcess(_process);
    _process = proc;
    _stateSub = proc.stateChanges.listen((s) {
      _state = s;
      notifyListeners();
    });
    _linesSub = proc.lines.listen((l) {
      _lines.add(l);
      if (_lines.length > _maxLines) {
        _lines.removeRange(0, _lines.length - _maxLines);
      }
      notifyListeners();
    });
  }

  Future<void> _detachProcess(BdsProcess? proc) async {
    await _stateSub?.cancel();
    await _linesSub?.cancel();
    _stateSub = null;
    _linesSub = null;
    await proc?.dispose();
  }

  // ------------------------------------------------------------ diagnostics

  /// Runs the on-device probe ladder (manual button or automatic after a
  /// double failure). Never throws; updates [diagnostics] and [failure].
  Future<void> runDiagnostics() async {
    if (_diagnosing) return;
    _diagnosing = true;
    _diagnostics = null;
    notifyListeners();
    unawaited(_log.log('diagnostik: mulai'));

    try {
      final diag = diagnosticsFactory?.call(baseDir) ??
          StackDiagnostics(baseDir, device: DeviceFacts(_deviceFacts));
      final results = <ProbeResult>[];
      await diag.run(onProbe: (r) {
        results.add(r);
        _diagnostics = List.unmodifiable(results);
        notifyListeners();
      });
      final verdict = diag.summarize(results);
      _diagnostics = List.unmodifiable(results);
      _failure = (_failure == null || _failure!.isEmpty)
          ? verdict
          : '$_failure\n\nDiagnostik:\n$verdict';
      unawaited(_log.log('diagnostik selesai:\n$verdict'));
    } catch (e) {
      unawaited(_log.log('diagnostik error: $e'));
    } finally {
      _diagnosing = false;
      notifyListeners();
    }
  }

  /// One pasteable report containing everything we need to debug remotely.
  Future<String> buildBugReport() async {
    final b = StringBuffer('== Pondok bug report ==\n');
    b.writeln('waktu: ${DateTime.now().toIso8601String()}');
    b.writeln('perangkat: ${DeviceFacts(_deviceFacts).describe()}');
    b.writeln('mode: ${_launchMode.name}');
    b.writeln('state: ${_state.name}');
    b.writeln('failure: ${_failure ?? '(tidak ada)'}');
    if (_lastExit != null) {
      b.writeln('exit terakhir: $_lastExit');
      final tail = _lastExit!.outputTail.trim();
      if (tail.isNotEmpty) b.writeln('output tail:\n$tail');
    }
    final diag = _diagnostics;
    if (diag != null && diag.isNotEmpty) {
      b.writeln('diagnostik:');
      for (final r in diag) {
        b.writeln('- $r');
        if (r.note.isNotEmpty) b.writeln('  ${r.note}');
      }
    }
    final logTail = await _log.tail(60);
    if (logTail.isNotEmpty) {
      b.writeln('log terakhir:\n$logTail');
    }
    return b.toString();
  }

  // ---------------------------------------------------------------- command

  Future<void> sendCommand(String command) async {
    await _process?.sendCommand(command);
  }

  Future<BdsExit> stop() async {
    final proc = _process;
    if (proc == null) {
      return _lastExit ??
          const BdsExit(0, BdsExitKind.unknown, 'not running');
    }
    final exit = await proc.stop();
    _lastExit = exit;
    unawaited(_log.log(
        'stop: ${exit.code} ${exit.kind.name}${exit.outputTail.trim().isEmpty ? '' : '\n${exit.outputTail.trim()}'}'));
    await _detachProcess(proc);
    _process = null;
    notifyListeners();
    return exit;
  }

  Duration? get uptime =>
      _startedAt == null ? null : DateTime.now().difference(_startedAt!);

  String get stateLabel {
    switch (_state) {
      case BdsState.idle:
        return 'Berhenti';
      case BdsState.starting:
        return 'Menyiapkan… (boot pertama memuat penerjemah)';
      case BdsState.running:
        return 'Berjalan';
      case BdsState.stopping:
        return 'Menghentikan…';
      case BdsState.stopped:
        return 'Berhenti';
      case BdsState.crashed:
        return 'Kehilangan proses (crash)';
      case BdsState.startupFailed:
        return 'Gagal menyala';
    }
  }

  @override
  void dispose() {
    unawaited(_detachProcess(_process));
    super.dispose();
  }
}

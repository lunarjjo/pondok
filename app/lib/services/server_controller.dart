import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:pondok_core/pondok_core.dart';

/// Runs the actual server through the bundled stack and exposes exactly
/// what the home screen needs: state, last console lines, uptime.
///
/// The launch profile (proot → rootfs → box64 → bedrock_server) is built
/// by pondok_core — the same command line CI verifies on real arm64
/// hardware (tools/stack_supervisor.py, mode "proot").
class ServerController extends ChangeNotifier {
  final String baseDir;

  ServerController({required this.baseDir});

  BdsProcess? _process;
  BdsState _state = BdsState.idle;
  BdsExit? _lastExit;
  DateTime? _startedAt;

  /// Ring buffer of the most recent console lines (bounded — a server can
  /// emit hundreds of lines per minute under load).
  final _lines = <ConsoleLine>[];
  static const _maxLines = 400;

  BdsState get state => _state;
  BdsExit? get lastExit => _lastExit;
  bool get isRunning => _state == BdsState.starting || _state == BdsState.running;

  List<ConsoleLine> get lines => List.unmodifiable(_lines);

  Future<void> start() async {
    if (isRunning) return;
    final proc = BdsProcess(bundledRuntimeProfile(baseDir));
    _process = proc;
    _startedAt = DateTime.now();
    _lines.clear();

    proc.stateChanges.listen((s) {
      _state = s;
      notifyListeners();
    });
    proc.lines.listen((l) {
      _lines.add(l);
      if (_lines.length > _maxLines) _lines.removeRange(0, _lines.length - _maxLines);
      notifyListeners();
    });
    // Completes on "Server started." or throws BdsStartupException.
    await proc.start();
    _state = proc.state;
    notifyListeners();
  }

  Future<void> sendCommand(String command) async {
    await _process?.sendCommand(command);
  }

  Future<BdsExit> stop() async {
    final exit = await _process?.stop() ??
        const BdsExit(0, BdsExitKind.unknown, 'not running');
    _lastExit = exit;
    await _process?.dispose();
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
}

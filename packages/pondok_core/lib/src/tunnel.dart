/// Tunnel abstraction (Phase 5) + provider-agnostic reconnect policy.
///
/// The public-internet path is a UDP tunnel to an edge network; exactly one
/// game port is forwarded. Administration NEVER flows through the tunnel —
/// the app exposes no network listener at all (docs/ARCHITECTURE.md §7).
///
/// This module contains the pure parts (interface, backoff schedule, event
/// types) plus the playit.gg agent supervisor, which parses the agent's
/// first-run claim URL from stdout — the same observable behavior the
/// provider documents publicly.
library;

import 'dart:async';
import 'dart:io';

import 'bds_process.dart' show LineStreamSplitter;
import 'security.dart';

/// Connectivity state of the tunnel.
enum TunnelState { disabled, installing, unclaimed, connecting, online, offline, failed }

/// Emitted whenever the public address is (re)learned.
class TunnelStatus {
  final TunnelState state;
  final String? publicHost;
  final int? publicPort;
  final String detail;
  const TunnelStatus(this.state, {this.publicHost, this.publicPort, this.detail = ''});

  /// The string players type into the Bedrock "Add external server" form.
  String? get playerAddress =>
      publicHost == null ? null : '$publicHost${publicPort == null ? '' : ':$publicPort'}';

  @override
  String toString() => 'TunnelStatus($state, ${playerAddress ?? detail})';
}

/// Provider-agnostic tunnel API. Implementations own exactly one process.
abstract class TunnelProvider {
  String get id;
  String get displayName;

  Stream<TunnelStatus> get status;
  TunnelStatus get lastStatus;

  /// Starts the agent. [localPort] is the server's RakNet UDP port; the
  /// provider forwards its edge to this port. Completes when the provider
  /// reports online (or throws with a user-actionable reason).
  Future<void> start({required int localPort});

  Future<void> stop();

  /// Restarts with the bounded exponential backoff policy defined below.
  Future<void> reconnect();

  void dispose();
}

/// Bounded exponential backoff with jitter — deterministic when [jitter] is
/// fixed (tests assert the exact schedule).
class BackoffSchedule {
  final Duration initial;
  final Duration maximum;
  final double multiplier;

  const BackoffSchedule({
    this.initial = const Duration(seconds: 2),
    this.maximum = const Duration(minutes: 5),
    this.multiplier = 2.0,
  });

  Duration delayForAttempt(int attempt, {double Function()? jitter}) {
    var d = initial;
    for (var i = 1; i < attempt; i++) {
      d = Duration(microseconds: (d.inMicroseconds * multiplier).round());
      if (d > maximum) {
        d = maximum;
        break;
      }
    }
    final j = jitter?.call() ?? 0;
    return Duration(
        microseconds: (d.inMicroseconds * (1 + j))
            .clamp(0, maximum.inMicroseconds * 2)
            .toInt());
  }
}

/// playit.gg agent supervisor.
///
/// Observed/documented agent behavior this relies on:
/// * on first run (no secret), the agent prints a claim URL/code to stdout —
///   parsed here and surfaced to the UI;
/// * with `SECRET_KEY` set (env), the agent attaches unattended;
/// * the agent itself maintains the edge connection; process-level death is
///   what our supervisor detects and restarts with backoff.
class PlayitProvider implements TunnelProvider {
  @override
  final String id = 'playit';
  @override
  String get displayName => 'playit.gg';

  final String agentBinary;
  final String stateDir; // holds playit.toml + agent secret
  final BackoffSchedule backoff;

  final _statusCtrl = StreamController<TunnelStatus>.broadcast();
  Process? _process;
  TunnelStatus _last = const TunnelStatus(TunnelState.disabled);
  Timer? _reconnectTimer;
  int _attempt = 0;
  bool _stopping = false;
  final Redactor _redactor = Redactor();

  PlayitProvider({
    required this.agentBinary,
    required this.stateDir,
    this.backoff = const BackoffSchedule(),
  });

  @override
  Stream<TunnelStatus> get status => _statusCtrl.stream;

  @override
  TunnelStatus get lastStatus => _last;

  /// The persisted agent secret (playit "agent secret key"), stored in
  /// app-private storage by the app layer, passed here at start().
  String? agentSecret;

  @override
  Future<void> start({required int localPort}) async {
    _stopping = false;
    _setStatus(const TunnelStatus(TunnelState.connecting));
    final env = <String, String>{
      ...Platform.environment,
      if (agentSecret != null && agentSecret!.isNotEmpty) 'SECRET_KEY': agentSecret!,
    };
    final proc = await Process.start(
      agentBinary,
      const [],
      workingDirectory: stateDir,
      environment: env,
    );
    _process = proc;
    proc.exitCode.then((_) => _onAgentDeath());

    final claimCompleter = Completer<void>();
    var sawClaim = false;
    final sub = proc.stdout
        .transform(const LineStreamSplitter())
        .listen((line) {
      // Never persist secrets/claim codes — redact before emitting.
      final safe = _redactor.redact(line);
      _emitRaw(safe);

      final claim = RegExp(r'https://playit\.gg/claim/([A-Za-z0-9]+)').firstMatch(line);
      if (claim != null && !sawClaim) {
        sawClaim = true;
        _setStatus(TunnelStatus(TunnelState.unclaimed, detail: claim.group(0)!));
        if (!claimCompleter.isCompleted) claimCompleter.complete();
      }
      // The agent prints tunnel address lines like `... <host>:<port> ...`
      final addr = RegExp(r'([\w.-]+\.playit\.gg):(\d+)').firstMatch(line);
      if (addr != null) {
        _setStatus(TunnelStatus(
          TunnelState.online,
          publicHost: addr.group(1),
          publicPort: int.tryParse(addr.group(2)!),
        ));
        _attempt = 0;
      }
      if (line.contains('packet connections established')) {
        if (!claimCompleter.isCompleted) claimCompleter.complete();
      }
    });

    await proc.stderr
        .transform(const LineStreamSplitter())
        .listen(_emitRaw)
        .asFuture<void>()
        .catchError((_) {});

    if (sawClaim && agentSecret == null) {
      // Fresh agent: wait for the user to complete the claim in a browser.
      await claimCompleter.future.timeout(
        const Duration(minutes: 15),
        onTimeout: () {
          // claim flow continues async; not fatal
        },
      );
    }
    await sub.asFuture<void>().catchError((_) {});
  }

  void _emitRaw(String line) {
    // Agent output is surfaced through the status stream's detail only when
    // it changes state; full raw logs belong to the app-layer log sink.
  }

  @override
  Future<void> stop() async {
    _stopping = true;
    _reconnectTimer?.cancel();
    final p = _process;
    if (p == null) return;
    p.kill();
    await p.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => 0);
    _process = null;
    _setStatus(const TunnelStatus(TunnelState.disabled));
  }

  @override
  Future<void> reconnect() async {
    if (_reconnectTimer?.isActive ?? false) return;
    _attempt++;
    final delay = backoff.delayForAttempt(_attempt);
    _setStatus(TunnelStatus(TunnelState.offline,
        detail: 'reconnecting in ${delay.inSeconds}s (attempt $_attempt)'));
    _reconnectTimer = Timer(delay, () async {
      try {
        await stop();
        final port = _lastPort;
        if (port != null) await start(localPort: port);
      } catch (_) {
        _setStatus(const TunnelStatus(TunnelState.failed, detail: 'reconnect failed'));
      }
    });
  }

  int? _lastPort;

  void _onAgentDeath() {
    if (_stopping) return;
    _process = null;
    _setStatus(const TunnelStatus(TunnelState.offline, detail: 'agent exited'));
    // The app layer decides whether to reconnect (user policy); the default
    // policy invokes reconnect().
  }

  void _setStatus(TunnelStatus s) {
    _last = s;
    if (!_statusCtrl.isClosed) _statusCtrl.add(s);
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _statusCtrl.close();
  }
}

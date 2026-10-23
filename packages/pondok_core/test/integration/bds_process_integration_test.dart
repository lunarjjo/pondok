import 'dart:async';
import 'dart:io';

import 'package:pondok_core/pondok_core.dart';
import 'package:test/test.dart';

/// REAL-BDS integration suite.
///
/// Runs only when PODOK_BDS_DIR points at an extracted official BDS
/// distribution (CI downloads and caches it; see .github/workflows/ci.yml).
/// This is the automated version of the Phase 0 PoC: every assertion below
/// was first observed manually against 1.26.52.3 (docs/evidence/).
///
/// Semantics asserted:
///   1. start → "Server started." within the watchdog budget
///   2. console command round-trip (`list` → "There are 0/N players online")
///   3. `allowlist add X` rewrites allowlist.json (verified live format)
///   4. graceful `stop` → exit code 0
///   5. restart opens the SAME world (no re-creation)
///   6. server.properties port change is honored on next start
///   7. kill -9 → abnormal exit (crash detection)
///   8. startup watchdog fires when the binary never reports started
String? bdsDir() {
  final d = Platform.environment['PODOK_BDS_DIR'];
  if (d == null || !File('$d/bedrock_server').existsSync()) return null;
  return d;
}

Future<String> _freshInstance(String tag) async {
  final src = bdsDir()!;
  final dst =
      await Directory.systemTemp.createTemp('pondok_bds_$tag');
  await _copyTree(Directory(src), dst);
  return dst.path;
}

Future<void> _copyTree(Directory src, Directory dst) async {
  await dst.create(recursive: true);
  await for (final e in src.list(recursive: true, followLinks: false)) {
    final rel = e.path.substring(src.path.length);
    if (e is File) {
      final t = File('${dst.path}$rel');
      await t.parent.create(recursive: true);
      await e.copy(t.path);
    } else if (e is Directory) {
      await Directory('${dst.path}$rel').create(recursive: true);
    }
  }
}

void main() {
  final dir = bdsDir();

  if (dir == null) {
    test('BDS integration suite (SKIPPED — set PODOK_BDS_DIR)', () {}, skip: true);
    return;
  }

  test('1+2+4. start → console round-trip → graceful stop (exit 0)', () async {
    final inst = await _freshInstance('basic');
    addTearDown(() => Directory(inst).delete(recursive: true));

    final proc = BdsProcess(BdsProcessConfig(
      binary: '$inst/bedrock_server',
      workingDir: inst,
      startupTimeout: const Duration(seconds: 90),
      gracefulStopTimeout: const Duration(seconds: 45),
    ));

    final sawVersion = <String>[];
    final sawPlayers = <String>[];
    final sub = proc.lines.listen((l) {
      final v = ConsoleEvents.versionLine.firstMatch(l.message);
      if (v != null) sawVersion.add(v.group(1)!);
      final pc = ConsoleEvents.playerCount.firstMatch(l.message);
      if (pc != null) sawPlayers.add('${pc.group(1)}/${pc.group(2)}');
    });
    addTearDown(sub.cancel);

    await proc.start();
    expect(proc.state, BdsState.running);
    expect(proc.pid, isNotNull);
    expect(proc.uptime, isNotNull);

    await proc.sendCommand('list');
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(sawPlayers, isNotEmpty, reason: 'list must answer with a player count');
    expect(sawPlayers.first, startsWith('0/'));

    final exit = await proc.stop();
    expect(exit.code, 0, reason: 'graceful stop must exit 0 (verified in PoC)');
    expect(exit.kind, BdsExitKind.cleanStop);
    expect(proc.state, BdsState.stopped);
    await proc.dispose();
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('3. allowlist add rewrites allowlist.json (live format)', () async {
    final inst = await _freshInstance('allowlist');
    addTearDown(() => Directory(inst).delete(recursive: true));

    final proc = BdsProcess(BdsProcessConfig(
      binary: '$inst/bedrock_server',
      workingDir: inst,
      startupTimeout: const Duration(seconds: 90),
    ));
    await proc.start();
    addTearDown(() async {
      if (proc.isAlive) await proc.stop();
      await proc.dispose();
    });

    await proc.sendCommand('allowlist add IntegrationPlayer');
    await Future<void>.delayed(const Duration(seconds: 3));

    final json = await File('$inst/allowlist.json').readAsString();
    final allow = Allowlist.parse(json);
    expect(allow.contains('IntegrationPlayer'), isTrue,
        reason: 'verified live in PoC: [{"ignoresPlayerLimit":false,"name":...}]');

    // Both directions stay in sync: file → object → command form.
    expect(Allowlist.commandRemove('IntegrationPlayer'), 'allowlist remove IntegrationPlayer');

    await proc.stop();
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('5. restart opens the same world (persistence)', () async {
    final inst = await _freshInstance('persist');
    addTearDown(() => Directory(inst).delete(recursive: true));

    var proc = BdsProcess(BdsProcessConfig(
      binary: '$inst/bedrock_server',
      workingDir: inst,
      startupTimeout: const Duration(seconds: 90),
    ));
    final firstRun = <String>[];
    final sub = proc.lines.listen((l) => firstRun.add(l.raw));
    await proc.start();
    expect(firstRun.join('\n'), contains('CREATING VANILLA WORLD')); // first run creates
    await proc.stop();
    await sub.cancel();
    await proc.dispose();

    proc = BdsProcess(BdsProcessConfig(
      binary: '$inst/bedrock_server',
      workingDir: inst,
      startupTimeout: const Duration(seconds: 90),
    ));
    final secondRun = <String>[];
    final sub2 = proc.lines.listen((l) => secondRun.add(l.raw));
    await proc.start();
    final joined = secondRun.join('\n');
    expect(joined, contains("Opening level 'worlds/Bedrock level/db'"));
    expect(joined, isNot(contains('CREATING VANILLA WORLD')),
        reason: 'world must persist across restarts (PoC verified)');
    await proc.stop();
    await sub2.cancel();
    await proc.dispose();
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('6. server.properties changes take effect (port)', () async {
    final inst = await _freshInstance('props');
    addTearDown(() => Directory(inst).delete(recursive: true));

    // Edit BEFORE start, through the typed properties API.
    final props = await ServerProperties.loadFile('$inst/server.properties');
    final prevPort = props.set('server-port', '19199');
    expect(prevPort, '19132');
    props.set('server-name', 'Integration Test');
    await props.saveFile('$inst/server.properties');

    final proc = BdsProcess(BdsProcessConfig(
      binary: '$inst/bedrock_server',
      workingDir: inst,
      startupTimeout: const Duration(seconds: 90),
    ));
    final ports = <String>[];
    final sub = proc.lines.listen((l) {
      final m = ConsoleEvents.acceptingClients.firstMatch(l.message);
      if (m != null) ports.add(m.group(1)!);
    });
    await proc.start();
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(ports, contains('19199'),
        reason: 'verified in PoC: edited port is what the server binds');
    await proc.stop();
    await sub.cancel();
    await proc.dispose();
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('7. kill -9 → crash classification', () async {
    final inst = await _freshInstance('crash');
    addTearDown(() => Directory(inst).delete(recursive: true));

    final proc = BdsProcess(BdsProcessConfig(
      binary: '$inst/bedrock_server',
      workingDir: inst,
      startupTimeout: const Duration(seconds: 90),
    ));
    await proc.start();

    Process.killPid(proc.pid!, ProcessSignal.sigkill);
    final exit = await proc.stop().catchError((_) => proc.lastExit!);
    // The exit kind must NOT be a clean stop.
    expect(exit.kind, anyOf(BdsExitKind.crashed, BdsExitKind.killedByUs));
    expect(exit.code == 0, isFalse, reason: 'SIGKILL cannot yield exit 0');
    expect(proc.state, anyOf(BdsState.crashed, BdsState.stopped));
    await proc.dispose();
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('8. startup watchdog fires for a silent process', () async {
    final inst = await _freshInstance('watchdog');
    addTearDown(() => Directory(inst).delete(recursive: true));

    final proc = BdsProcess(BdsProcessConfig(
      binary: '/bin/cat', // never prints "Server started."
      workingDir: inst,
      startupTimeout: const Duration(seconds: 2),
    ));
    try {
      await proc.start();
      fail('watchdog must reject a process that never starts');
    } on BdsStartupException {
      // expected
    }
    expect(proc.state, BdsState.startupFailed);
    await proc.dispose();
  }, timeout: const Timeout(Duration(minutes: 1)));
}

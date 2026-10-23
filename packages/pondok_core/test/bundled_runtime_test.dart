import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pondok_core/pondok_core.dart';
import 'package:test/test.dart';

import 'tar_test_helpers.dart';

/// End-to-end tests of the bundled-runtime installer against a SYNTHETIC
/// pack built with the same primitives (ZipWriter + hand-built tar) — the
/// same code path the device runs, without shipping real binaries in git.
///
/// Cover: install layout, idempotency, sha verification failure, repair
/// preserving worlds/ + server.properties/allowlist, profile command line.
void main() {
  late Directory tmp;
  late String baseDir;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pondok_bundled_');
    baseDir = '${tmp.path}/pondok';
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  /// Builds a fake runtime pack zip: manifest.json + proot + rootfs.tar +
  /// bds.zip — with REAL sha256s, like the CI builder.
  Future<String> buildPack() async {
    final src = '${tmp.path}/packsrc';
    await Directory(src).create(recursive: true);

    // proot: a stand-in script (installer only copies + chmods it).
    await File('$src/proot').writeAsString('#!/bin/sh\necho fake-proot\n');

    // rootfs.tar: contains box64 where the profile expects it.
    final tb = TarBuilder()
      ..dir('opt/')
      ..dir('opt/box64/')
      ..file('opt/box64/box64', '#!/bin/sh\necho fake-box64\n', mode: 0x1ED)
      ..dir('usr/')
      ..dir('usr/bin/')
      ..file('usr/bin/sh', '#!/bin/sh\n', mode: 0x1ED);
    await File('$src/rootfs.tar').writeAsBytes(tb.finish());

    // bds.zip: fake-but-plausibly-sized bedrock_server + default configs.
    // The transport default mirrors the REAL distribution (nethernet) —
    // the installer must rewrite it (product-managed raknet).
    final bdsZip = ZipWriter('$src/bds.zip');
    final serverBytes = Uint8List(1024 * 1024 + 7)..fillRange(0, 30, 0x7F);
    bdsZip.addFile('bedrock_server', serverBytes);
    bdsZip.addFile(
        'server.properties',
        utf8.encode('motd=Pondok test\nserver-port=19132\n'
            'transport=nethernet\n'));
    bdsZip.addFile('allowlist.json', utf8.encode('[]\n'));
    await bdsZip.close();

    Future<String> sha(String p) async => sha256OfFile(p);
    final manifest = {
      'format': 'pondok-runtime-pack/1',
      'packVersion': 1,
      'createdAt': '2026-10-23T00:00:00+00:00',
      'components': {
        'proot': {'tag': 'vTEST', 'sha256': await sha('$src/proot')},
        'box64': {
          'tag': 'vTEST',
          'sha256': await sha('$src/rootfs.tar'), // not checked by verify()
          'path': '/opt/box64/box64',
        },
        'rootfs': {'base': 'ubuntu-base-TEST-arm64', 'sha256_gz': 'deadbeef'},
        'bds': {
          'version': '1.26.52.3',
          'sha256': await sha('$src/bds.zip'),
          'zipBytes': await File('$src/bds.zip').length(),
        },
      },
      'members': {
        'proot': {
          'sha256': await sha('$src/proot'),
          'size': await File('$src/proot').length(),
        },
        'rootfs.tar': {
          'sha256': await sha('$src/rootfs.tar'),
          'size': await File('$src/rootfs.tar').length(),
        },
        'bds.zip': {
          'sha256': await sha('$src/bds.zip'),
          'size': await File('$src/bds.zip').length(),
        },
      },
    };
    await File('$src/manifest.json')
        .writeAsString(jsonEncode(manifest));

    final pack = ZipWriter('${tmp.path}/runtime_pack.zip');
    pack.addFile('manifest.json', await File('$src/manifest.json').readAsBytes());
    pack.addFile('proot', await File('$src/proot').readAsBytes());
    pack.addFile('rootfs.tar', await File('$src/rootfs.tar').readAsBytes());
    pack.addFile('bds.zip', await File('$src/bds.zip').readAsBytes());
    await pack.close();
    return '${tmp.path}/runtime_pack.zip';
  }

  test('install produces the exact device layout + healthy marker',
      () async {
    final pack = await buildPack();
    final runtime = BundledRuntime(baseDir);
    final result = await runtime.install(pack);

    expect(result.alreadyInstalled, isFalse);
    expect(result.manifest.bdsVersion, '1.26.52.3');

    final p = BundledRuntimePaths(baseDir);
    expect(await File(p.proot).exists(), isTrue, reason: 'proot placed');
    expect(await File(p.box64).exists(), isTrue, reason: 'box64 inside rootfs');
    expect(await File(p.bedrockServer).exists(), isTrue);
    expect(await File('$baseDir/server/server.properties').exists(), isTrue);
    // Product-managed transport: nethernet must never survive install.
    final props = await File('$baseDir/server/server.properties').readAsString();
    expect(props, contains('transport=raknet'));
    expect(props, isNot(contains('nethernet')));
    expect(await File(p.installedMarker).exists(), isTrue, reason: 'marker last');

    expect((await runtime.verify()).isHealthy, isTrue);
    expect(await runtime.isInstalled(), isTrue);
    expect(await Directory('$baseDir/.staging').exists(), isFalse,
        reason: 'staging cleaned');
  });

  test('install is idempotent for a healthy tree', () async {
    final pack = await buildPack();
    final runtime = BundledRuntime(baseDir);
    await runtime.install(pack);
    final again = await runtime.install(pack);
    expect(again.alreadyInstalled, isTrue);
    expect(again.files, 0);
  });

  test('tampered pack member (sha mismatch) aborts BEFORE activation',
      () async {
    final pack = await buildPack();
    // Corrupt the pack zip's proot bytes in place: rewrite the archive with
    // a different proot but the ORIGINAL manifest sha.
    final raw = await File(pack).readAsBytes();
    final marker = utf8.encode('fake-proot');
    final idx = _indexOfSub(raw, marker);
    expect(idx, greaterThan(0), reason: 'fixture sanity');
    raw[idx] = 0x46; // 'F' — one byte flip
    final tampered = '${tmp.path}/tampered_pack.zip';
    await File(tampered).writeAsBytes(raw);

    final runtime = BundledRuntime(baseDir);
    await expectLater(runtime.install(tampered), throwsA(isA<StateError>()));
    expect(
        await File(BundledRuntimePaths(baseDir).installedMarker).exists(),
        isFalse,
        reason: 'no marker after failed install');
    expect(await Directory('$baseDir/runtime').exists(), isFalse,
        reason: 'nothing activated');
  });

  test('corrupted installed tree: verify fails, repair preserves player data',
      () async {
    final pack = await buildPack();
    final runtime = BundledRuntime(baseDir);
    await runtime.install(pack);

    // Simulate a server that has been played on.
    final p = BundledRuntimePaths(baseDir);
    await Directory('${p.server}/worlds/Bedrock level').create(recursive: true);
    await File('${p.server}/worlds/Bedrock level/level.dat')
        .writeAsBytes(List.filled(2048, 9));
    await File('${p.server}/server.properties')
        .writeAsString('motd=Server Saya\nserver-port=19132\n');
    await File('${p.server}/allowlist.json')
        .writeAsString('[{"name":"Steve"}]');

    // Corrupt the runtime: verify must catch it.
    await File(p.proot).writeAsString('corrupted');
    final report = await runtime.verify();
    expect(report.isHealthy, isFalse);
    expect(report.problems.join(','), contains('proot'));
    expect(await runtime.isInstalled(), isFalse);

    // Repair from the SAME pack.
    final result = await runtime.install(pack, force: true);
    expect(result.alreadyInstalled, isFalse);

    expect((await runtime.verify()).isHealthy, isTrue);
    expect(await File(p.proot).readAsString(), contains('fake-proot'));

    // Player data survived.
    expect(await File('${p.server}/worlds/Bedrock level/level.dat').exists(), isTrue);
    // Managed transport survives repairs even when the preserved user file
    // lacked the line entirely (it would silently fall back to nethernet).
    final repaired = await File('${p.server}/server.properties').readAsString();
    expect(repaired, contains('transport=raknet'));
    expect(repaired, contains('motd=Server Saya'));
    expect(await File('${p.server}/allowlist.json').readAsString(), contains('Steve'));
    final props = await File('${p.server}/server.properties').readAsString();
    expect(props, contains('motd=Server Saya'));
    expect(await Directory('$baseDir/.worlds.keep').exists(), isFalse,
        reason: 'keep dir cleaned up');
  });

  test('profile: the launch line mirrors the CI-verified command', () {
    final cfg = bundledRuntimeProfile(baseDir);
    expect(cfg.binary, '$baseDir/runtime/proot');
    expect(cfg.args.sublist(0, 2), ['-R', '$baseDir/runtime/rootfs']);
    expect(cfg.args, contains('$baseDir/server:/srv/server'));
    expect(cfg.args, contains('-w'));
    expect(cfg.args, contains('/srv/server'));
    final inner = cfg.args.last;
    expect(inner, contains('/opt/box64/box64'));
    expect(inner, contains('bedrock_server'));
    expect(inner, contains('LD_LIBRARY_PATH=.:/usr/lib/box64-x86_64-linux-gnu'));
    // Proot traces the whole process tree — startup budget is generous.
    expect(cfg.startupTimeout, greaterThanOrEqualTo(const Duration(minutes: 10)));
  });

  test('manifest rejects unknown format', () {
    expect(() => RuntimePackManifest.parse('{"format":"other/1"}'),
        throwsA(isA<FormatException>()));
  });

  test('exec bits are actually applied through the platform chmod',
      () async {
    if (Platform.isWindows) return;
    final pack = await buildPack();
    await BundledRuntime(baseDir).install(pack);
    final p = BundledRuntimePaths(baseDir);
    for (final f in [p.proot, p.bedrockServer, p.box64]) {
      final r = await Process.run('test', ['-x', f]);
      expect(r.exitCode, 0, reason: '$f must be executable');
    }
  });
}

/// Uint8List.indexOf searches for a single int element — we need a
/// sub-array search for the tamper test.
int _indexOfSub(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

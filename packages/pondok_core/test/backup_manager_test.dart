import 'dart:io';

import 'package:pondok_core/pondok_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String instanceDir;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pondok_backup_test');
    instanceDir = '${tmp.path}/instance';
    final server = Directory('$instanceDir/server');
    await Directory('${server.path}/worlds/Bedrock level/db')
        .create(recursive: true);
    await File('${server.path}/worlds/Bedrock level/db/000003.log')
        .writeAsBytes(List.generate(4096, (i) => i & 0xFF));
    await File('${server.path}/worlds/Bedrock level/level.dat')
        .writeAsBytes(List.generate(1024, (i) => (i * 3) & 0xFF));
    await File('${server.path}/server.properties')
        .writeAsString('server-port=19132\nlevel-name=Bedrock level\n');
    await File('${server.path}/allowlist.json')
        .writeAsString('[{"ignoresPlayerLimit":false,"name":"PoCPlayer"}]');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  group('BackupManager', () {
    test('create produces a CRC-valid backup and manifest entry', () async {
      final manifest = BackupManifest('$instanceDir/backups/manifest.json');
      final mgr = BackupManager(instanceDir, manifest);
      final entry = await mgr.create(bdsVersion: '1.26.52.3', worldName: 'Bedrock level');

      expect(entry, isNotNull);
      final zip = File('$instanceDir/backups/${entry!.file}');
      expect(await zip.exists(), isTrue);
      expect(entry.bytes, await zip.length());

      // Re-open and verify every member's CRC (like the real restore path).
      final a = ZipArchive.open(zip.path);
      final names = a.entries.map((e) => e.name).toSet();
      expect(names, containsAll([
        'worlds/Bedrock level/db/000003.log',
        'worlds/Bedrock level/level.dat',
        'server.properties',
        'allowlist.json',
        'pondok-backup.json',
      ]));
      for (final e in a.entries) {
        if (e.isDirectory) continue;
        final data = a.readEntry(e);
        expect(data, isNotNull, reason: e.name);
        expect(crc32(data!), e.crc32, reason: 'CRC for ${e.name}');
      }
      a.close();
    });

    test('restore swaps worlds and config, and survives verify', () async {
      final manifest = BackupManifest('$instanceDir/backups/manifest.json');
      final mgr = BackupManager(instanceDir, manifest);
      final entry = await mgr.create(bdsVersion: '1.26.52.3');

      // Mutate the live world (simulating play after backup).
      await File('$instanceDir/server/worlds/Bedrock level/db/000003.log')
          .writeAsBytes([1, 2, 3]);
      await File('$instanceDir/server/server.properties')
          .writeAsString('server-port=25565\n');

      await mgr.restore(entry!, backupDir: '$instanceDir/backups');

      final log = await File('$instanceDir/server/worlds/Bedrock level/db/000003.log')
          .readAsBytes();
      expect(log.length, 4096); // original content restored
      final props = await File('$instanceDir/server/server.properties').readAsString();
      expect(props, contains('server-port=19132'));
      expect(await Directory('$instanceDir/.restore-staging').exists(), isFalse);
      expect(await Directory('$instanceDir/.pre-restore-worlds').exists(), isFalse);
    });

    test('manifest prune keeps the newest valid backup unconditionally', () async {
      final manifest = BackupManifest('$instanceDir/backups/manifest.json', retention: 2);
      final dir = Directory('$instanceDir/backups')..createSync(recursive: true);
      final now = DateTime.now();
      for (var i = 0; i < 5; i++) {
        final f = File('${dir.path}/b$i.zip')..writeAsBytesSync([i]);
        manifest.entries.add(BackupEntry(
          file: 'b$i.zip',
          createdAt: now.subtract(Duration(hours: 5 - i)),
          worldName: 'w',
          bdsVersion: '1',
          bytes: 1,
          fileCount: 1,
        ));
      }
      final removed = await manifest.prune(dir.path);
      // 5 entries, retention 2 → keep newest + 1 more → 3 removed
      expect(removed, hasLength(3));
      expect(manifest.entries.first.file, 'b4.zip'); // newest never removed
      for (final r in removed) {
        expect(await File('${dir.path}/$r').exists(), isFalse);
      }
    });

    test('prune with retention 1 still keeps the newest', () async {
      final manifest = BackupManifest('$instanceDir/backups/manifest.json', retention: 1);
      final dir = Directory('$instanceDir/backups')..createSync(recursive: true);
      final now = DateTime.now();
      for (var i = 0; i < 3; i++) {
        File('${dir.path}/c$i.zip').writeAsBytesSync([i]);
        manifest.entries.add(BackupEntry(
          file: 'c$i.zip',
          createdAt: now.subtract(Duration(hours: 3 - i)),
          worldName: 'w',
          bdsVersion: '1',
          bytes: 1,
          fileCount: 1,
        ));
      }
      await manifest.prune(dir.path);
      expect(manifest.entries, hasLength(1));
      expect(manifest.entries.first.file, 'c2.zip');
    });

    test('manifest JSON round-trips', () async {
      final path = '$instanceDir/backups/manifest.json';
      final m = BackupManifest(path, retention: 7);
      m.entries.add(BackupEntry(
        file: 'x.zip',
        createdAt: DateTime(2026, 10, 23, 8),
        worldName: 'Bedrock level',
        bdsVersion: '1.26.52.3',
        bytes: 12345,
        fileCount: 9,
      ));
      await m.save();
      final back = BackupManifest(path);
      await back.load();
      expect(back.retention, 7);
      expect(back.entries.single.file, 'x.zip');
      expect(back.entries.single.bdsVersion, '1.26.52.3');
    });
  });
}

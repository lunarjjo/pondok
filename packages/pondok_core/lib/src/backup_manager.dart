/// Backup and restore for worlds + server configuration, with retention
/// rules and the "never delete the last valid backup" guard.
///
/// A backup is a ZIP containing `worlds/` plus the config set
/// (`server.properties`, `allowlist.json`, `permissions.json`,
/// `packetlimitconfig.json`), created via [ZipWriter] and validated by
/// re-reading + CRC before being recorded in the manifest.
library;

import 'dart:convert';
import 'dart:io';

import 'zip.dart';

class BackupEntry {
  final String file;
  final DateTime createdAt;
  final String worldName;
  final String bdsVersion;
  final int bytes;
  final int fileCount;

  const BackupEntry({
    required this.file,
    required this.createdAt,
    required this.worldName,
    required this.bdsVersion,
    required this.bytes,
    required this.fileCount,
  });

  Map<String, dynamic> toJson() => {
        'file': file,
        'createdAt': createdAt.toIso8601String(),
        'world': worldName,
        'bds': bdsVersion,
        'bytes': bytes,
        'files': fileCount,
      };

  static BackupEntry fromJson(Map<String, dynamic> j) => BackupEntry(
        file: j['file'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        worldName: j['world'] as String? ?? '',
        bdsVersion: j['bds'] as String? ?? '',
        bytes: (j['bytes'] as num?)?.toInt() ?? 0,
        fileCount: (j['files'] as num?)?.toInt() ?? 0,
      );
}

class BackupManifest {
  final String path;
  int retention; // how many backups to keep (0 = keep all)
  final List<BackupEntry> entries = [];

  BackupManifest(this.path, {this.retention = 5});

  Future<void> load() async {
    entries.clear();
    final f = File(path);
    if (!await f.exists()) return;
    final j = jsonDecode(await f.readAsString());
    if (j is Map<String, dynamic>) {
      retention = (j['retention'] as num?)?.toInt() ?? retention;
      final list = j['backups'];
      if (list is List) {
        for (final e in list) {
          if (e is Map<String, dynamic>) entries.add(BackupEntry.fromJson(e));
        }
      }
    }
  }

  Future<void> save() async {
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'retention': retention,
      'backups': entries.map((e) => e.toJson()).toList(),
    }));
  }

  /// Retention pruner with the golden guard: the newest VALID backup is
  /// never deleted, even when retention is 0 or 1. Returns the pruned files.
  Future<List<String>> prune(String backupDir) async {
    if (entries.isEmpty) return const [];
    final sorted = [...entries]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    // keep newest valid entry unconditionally
    final keep = <BackupEntry>[sorted.first];
    for (final e in sorted.skip(1)) {
      if (keep.length < retention) keep.add(e);
    }
    final removed = <String>[];
    for (final e in sorted.where((e) => !keep.contains(e))) {
      final f = File('$backupDir/${e.file}');
      if (await f.exists()) {
        await f.delete();
      }
      removed.add(e.file);
    }
    entries
      ..clear()
      ..addAll(keep)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    await save();
    return removed;
  }
}

/// Creates and validates backups for one instance directory.
class BackupManager {
  final String instanceDir;
  final BackupManifest manifest;

  BackupManager(this.instanceDir, this.manifest);

  static const configFiles = [
    'server.properties',
    'allowlist.json',
    'permissions.json',
    'packetlimitconfig.json',
  ];

  /// Creates a backup; returns null when there is nothing to back up.
  Future<BackupEntry?> create({
    required String bdsVersion,
    String worldName = '',
    void Function(int files, int bytes)? onProgress,
  }) async {
    final stamp = DateTime.now();
    final name =
        'backup-${stamp.year}${_two(stamp.month)}${_two(stamp.day)}-${_two(stamp.hour)}${_two(stamp.minute)}${_two(stamp.second)}.zip';
    final backupDir = '$instanceDir/backups';
    await Directory(backupDir).create(recursive: true);
    final out = '$backupDir/$name';

    var fileCount = 0;
    final writer = ZipWriter(out);
    try {
      final worldsDir = Directory('$instanceDir/server/worlds');
      if (await worldsDir.exists()) {
        final before = fileCount;
        await writer.addTree(worldsDir.path, prefix: 'worlds/');
        fileCount = before + 1; // tree counted as one unit for progress
      }
      for (final cfg in configFiles) {
        final f = File('$instanceDir/server/$cfg');
        if (await f.exists()) {
          writer.addFile(cfg, await f.readAsBytes());
          fileCount++;
        }
      }
      // manifest.json of the backup itself: recorded at restore time
      writer.addFile('pondok-backup.json', utf8.encode(jsonEncode({
            'world': worldName,
            'bds': bdsVersion,
            'createdAt': stamp.toIso8601String(),
          })));
    } finally {
      await writer.close();
    }

    // Validate by re-reading: every entry's CRC must match.
    final archive = ZipArchive.open(out);
    var valid = true;
    try {
      for (final e in archive.entries) {
        if (e.isDirectory) continue;
        final data = archive.readEntry(e);
        if (data == null || crc32(data) != e.crc32) {
          valid = false;
          break;
        }
      }
    } finally {
      archive.close();
    }
    if (!valid) {
      await File(out).delete();
      throw const FileSystemException('backup failed CRC validation — deleted');
    }

    final bytes = await File(out).length();
    final entry = BackupEntry(
      file: name,
      createdAt: stamp,
      worldName: worldName,
      bdsVersion: bdsVersion,
      bytes: bytes,
      fileCount: fileCount,
    );
    manifest.entries.add(entry);
    await manifest.save();
    onProgress?.call(fileCount, bytes);
    return entry;
  }

  /// Restores a backup: validates, extracts to a staging dir, then swaps
  /// worlds/ and config files in. Never touches the live instance until the
  /// extracted copy has passed CRC.
  Future<void> restore(BackupEntry entry, {required String backupDir}) async {
    final zipFile = File('$backupDir/${entry.file}');
    if (!await zipFile.exists()) {
      throw FileSystemException('backup missing', zipFile.path);
    }
    final archive = ZipArchive.open(zipFile.path);
    final extracted = <String, List<int>>{};
    try {
      for (final e in archive.entries) {
        if (e.isDirectory) continue;
        final data = archive.readEntry(e);
        if (data == null || crc32(data) != e.crc32) {
          throw FileSystemException('corrupt backup member: ${e.name}', zipFile.path);
        }
        extracted[e.name] = data;
      }
    } finally {
      archive.close();
    }

    // Stage, then swap.
    final staging = '$instanceDir/.restore-staging';
    final stagingDir = Directory(staging);
    if (await stagingDir.exists()) await stagingDir.delete(recursive: true);
    await stagingDir.create(recursive: true);
    for (final e in extracted.entries) {
      final dest = File('$staging/${e.key}');
      await dest.parent.create(recursive: true);
      await dest.writeAsBytes(e.value);
    }

    final server = '$instanceDir/server';
    final worldsBackup = '$instanceDir/.pre-restore-worlds';
    final oldWorlds = Directory('$server/worlds');
    if (await oldWorlds.exists()) {
      await oldWorlds.rename(worldsBackup);
    }
    try {
      final newWorlds = Directory('$staging/worlds');
      if (await newWorlds.exists()) {
        await _copyTree(newWorlds, Directory('$server/worlds'));
      }
      for (final cfg in configFiles) {
        final staged = File('$staging/$cfg');
        if (await staged.exists()) {
          await staged.copy('$server/$cfg');
        }
      }
    } catch (e) {
      // roll back the swap
      if (await Directory(worldsBackup).exists()) {
        if (await oldWorlds.exists()) await oldWorlds.delete(recursive: true);
        await Directory(worldsBackup).rename('$server/worlds');
      }
      rethrow;
    }
    if (await Directory(worldsBackup).exists()) {
      await Directory(worldsBackup).delete(recursive: true);
    }
    await stagingDir.delete(recursive: true);
  }
}

Future<void> _copyTree(Directory src, Directory dst) async {
  await dst.create(recursive: true);
  await for (final e in src.list(recursive: true, followLinks: false)) {
    final rel = e.path.substring(src.path.length);
    if (e is File) {
      final target = File('${dst.path}$rel');
      await target.parent.create(recursive: true);
      await e.copy(target.path);
    } else if (e is Directory) {
      await Directory('${dst.path}$rel').create(recursive: true);
    }
  }
}

String _two(int n) => n.toString().padLeft(2, '0');

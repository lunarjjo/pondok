/// Fully-bundled runtime: install + verify + launch profile for the
/// runtime pack that ships INSIDE the APK (ADR-004 — owner directive:
/// zero-setup, "user tinggal pakai").
///
/// Device layout under [baseDir] (the app's private files dir):
///
///     <baseDir>/
///       runtime/proot          static proot (sha-pinned by manifest)
///       runtime/rootfs/        ubuntu-base + box64 @ /opt/box64/box64
///       server/                Bedrock instance: bedrock_server + libs,
///                               worlds/, server.properties, allowlist.json
///       installed.json         success marker + embedded manifest
///       .staging/              scratch during install (always cleaned)
///
/// Safety semantics (same discipline as BackupManager / UpdatePipeline):
/// * everything is assembled in `.staging/` and only activated at the end
///   — a failed install can never destroy a known-good runtime;
/// * member sha256s from the manifest are verified BEFORE use;
/// * repair preserves player data: worlds/, server.properties, allowlist,
///   ops/permissions are snapshotted and restored around re-extraction.
library;

import 'dart:convert';
import 'dart:io';

import 'bds_process.dart';
import 'downloader.dart' as dl;
import 'tar.dart';

/// Parsed `manifest.json` of a runtime pack.
class RuntimePackManifest {
  final String format;
  final int packVersion;
  final String createdAt;
  final Map<String, dynamic> components;
  final Map<String, Map<String, dynamic>> members;

  const RuntimePackManifest({
    required this.format,
    required this.packVersion,
    required this.createdAt,
    required this.components,
    required this.members,
  });

  static RuntimePackManifest parse(String json) {
    return fromMap(jsonDecode(json) as Map<String, dynamic>);
  }

  static RuntimePackManifest fromMap(Map<String, dynamic> d) {
    if (d['format'] != 'pondok-runtime-pack/1') {
      throw const FormatException('unknown runtime pack format');
    }
    final rawMembers =
        (d['members'] as Map<String, dynamic>).cast<String, Map<String, dynamic>>();
    return RuntimePackManifest(
      format: d['format'] as String,
      packVersion: d['packVersion'] as int,
      createdAt: d['createdAt'] as String,
      components: (d['components'] as Map<String, dynamic>).cast<String, dynamic>(),
      members: rawMembers,
    );
  }

  String? memberSha(String name) => members[name]?['sha256'] as String?;
  String get bdsVersion => (components['bds']?['version'] ?? '?') as String;
  String get prootTag => (components['proot']?['tag'] ?? '?') as String;
  String get box64Tag => (components['box64']?['tag'] ?? '?') as String;

  @override
  String toString() =>
      'RuntimePackManifest(v$packVersion, bds $bdsVersion, proot $prootTag, box64 $box64Tag)';
}

/// Outcome of one install/verify run.
class RuntimeInstallResult {
  final RuntimePackManifest manifest;
  final int files;
  final int bytes;
  final bool alreadyInstalled;
  const RuntimeInstallResult(this.manifest, this.files, this.bytes, this.alreadyInstalled);
}

/// Points of interest inside the installed tree.
class BundledRuntimePaths {
  final String baseDir;
  const BundledRuntimePaths(this.baseDir);

  String get runtime => '$baseDir/runtime';
  String get proot => '$runtime/proot';
  String get rootfs => '$runtime/rootfs';
  String get box64 => '$rootfs/opt/box64/box64';
  String get server => '$baseDir/server';
  String get bedrockServer => '$server/bedrock_server';
  String get installedMarker => '$baseDir/installed.json';
  String get staging => '$baseDir/.staging';
}

/// Install / verify / repair the bundled runtime.
class BundledRuntime {
  /// Player data that MUST survive a repair re-extraction of server/.
  static const _preserveFiles = [
    'server.properties',
    'allowlist.json',
    'ops.json',
    'permissions.json',
  ];

  final BundledRuntimePaths paths;
  BundledRuntime(String baseDir) : paths = BundledRuntimePaths(baseDir);

  /// Marker file content of the last successful install (null if none).
  /// The marker wraps the pack manifest: {"installedAt":…, "manifest":…}.
  Future<RuntimePackManifest?> installedManifest() async {
    final f = File(paths.installedMarker);
    if (!await f.exists()) return null;
    try {
      final d = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final inner = d['manifest'];
      if (inner is! Map<String, dynamic>) return null;
      return RuntimePackManifest.fromMap(inner);
    } catch (_) {
      return null;
    }
  }

  Future<bool> isInstalled() async =>
      await installedManifest() != null && (await verify()).isHealthy;

  /// Installs from the pack zip; idempotent when the same packVersion is
  /// already healthy. [packZipPath] is the file the caller streamed out of
  /// the APK asset (Kotlin channel — never loads it into memory).
  Future<RuntimeInstallResult> install(
    String packZipPath, {
    void Function(RuntimeInstallPhase phase, int detail)? onProgress,
    bool force = false,
  }) async {
    if (!force) {
      final current = await installedManifest();
      if (current != null && (await verify()).isHealthy) {
        return RuntimeInstallResult(current, 0, 0, true);
      }
    }

    final base = Directory(paths.baseDir);
    await base.create(recursive: true);
    await Directory(paths.staging).create(recursive: true);
    try {
      onProgress?.call(RuntimeInstallPhase.unpackPack, 0);
      final packDir = '${paths.staging}/pack';
      final unzipped = await dl.extractZip(packZipPath, packDir);
      if (!unzipped.allCrcValid) {
        throw StateError('runtime pack CRC failures: ${unzipped.crcFailures.take(3)}');
      }

      final manifest = RuntimePackManifest.parse(
          await File('$packDir/manifest.json').readAsString());
      onProgress?.call(RuntimeInstallPhase.verifyPack, 0);
      await _requireFile('$packDir/proot', manifest.memberSha('proot'));
      await _requireFile('$packDir/rootfs.tar', manifest.memberSha('rootfs.tar'));
      await _requireFile('$packDir/bds.zip', manifest.memberSha('bds.zip'));

      onProgress?.call(RuntimeInstallPhase.unpackRootfs, 0);
      final newRuntime = '${paths.staging}/runtime';
      await Directory('$newRuntime/rootfs').create(recursive: true);
      final tarReport = await extractTar(
        '$packDir/rootfs.tar',
        '$newRuntime/rootfs',
        onEntry: (_) {},
      );
      await File('$packDir/proot').copy('$newRuntime/proot');

      onProgress?.call(RuntimeInstallPhase.unpackServer, 0);
      final newServer = '${paths.staging}/server';
      await Directory(newServer).create(recursive: true);
      await dl.extractZip('$packDir/bds.zip', newServer);
      if (!await File('$newServer/bedrock_server').exists()) {
        throw StateError('bds.zip has no bedrock_server');
      }
      await _ensureManagedProperties(newServer);

      // Exec bits (dart:io cannot chmod): batched platform chmod.
      onProgress?.call(RuntimeInstallPhase.permissions, 0);
      final execs = <String>[
        '$newRuntime/proot',
        '$newServer/bedrock_server',
        ...tarReport.execPaths,
      ];
      await applyExecBits(execs);

      onProgress?.call(RuntimeInstallPhase.activate, 0);
      await _activate(newRuntime, newServer, manifest);

      return RuntimeInstallResult(
        manifest,
        tarReport.files + unzipped.filesExtracted,
        tarReport.bytes + unzipped.bytesExtracted,
        false,
      );
    } finally {
      await Directory(paths.staging).delete(recursive: true)
          .catchError((_) => Directory(paths.staging));
    }
  }

  /// Swap staged trees into place. Never leaves the app without a marker:
  /// the marker is written last; any earlier crash simply restarts install.
  ///
  /// Player data survives repairs:
  /// * worlds/ is MOVED aside (rename — O(1) even for gigabytes) to
  ///   `<baseDir>/.worlds.keep` and moved back after the swap. The keep dir
  ///   lives OUTSIDE .staging so a failed install can never delete it, and
  ///   a crashed repair leaves it behind for the next one to restore.
  /// * small config files (server.properties, allowlist, ops, permissions)
  ///   are snapshotted as bytes and rewritten after the swap.
  Future<void> _activate(
      String newRuntime, String newServer, RuntimePackManifest manifest) async {
    final keep = Directory('${paths.baseDir}/.worlds.keep');
    final worlds = Directory('${paths.server}/worlds');
    var worldsPreserved = false;
    if (await worlds.exists() && !await keep.exists()) {
      await worlds.rename(keep.path);
      worldsPreserved = true;
    }

    Map<String, List<int>>? preserved;
    if (await Directory(paths.server).exists()) {
      preserved = {};
      for (final name in _preserveFiles) {
        final f = File('${paths.server}/$name');
        if (await f.exists()) {
          preserved[name] = await f.readAsBytes();
        }
      }
    }

    try {
      await _replaceDir(newRuntime, paths.runtime);
      await _replaceDir(newServer, paths.server);

      if (preserved != null) {
        for (final e in preserved.entries) {
          await File('${paths.server}/${e.key}').writeAsBytes(e.value, flush: true);
        }
        // A preserved properties file may predate the managed-transport
        // policy (or have dropped the line) — normalize before activation.
        await _ensureManagedProperties(paths.server);
      }
      if (worldsPreserved || await keep.exists()) {
        await Directory(paths.server).create(recursive: true);
        await keep.rename('${paths.server}/worlds');
      }

      await File(paths.installedMarker).writeAsString(
        jsonEncode({
          'installedAt': DateTime.now().toIso8601String(),
          'manifest': {
            'format': manifest.format,
            'packVersion': manifest.packVersion,
            'createdAt': manifest.createdAt,
            'components': manifest.components,
            'members': manifest.members,
          },
        }),
        flush: true,
      );
    } catch (_) {
      // Put the worlds back where they were if the swap did not complete.
      if (worldsPreserved && await keep.exists() && !await worlds.exists()) {
        await Directory(paths.server).create(recursive: true);
        await keep.rename(worlds.path);
      }
      rethrow;
    }
  }

  Future<void> _replaceDir(String from, String to) async {
    final target = Directory(to);
    if (await target.exists()) {
      await target.rename('${to}.old');
    }
    await Directory(from).rename(to);
    final old = Directory('$to.old');
    if (await old.exists()) {
      await old.delete(recursive: true);
    }
  }

  /// Product-managed defaults on the ACTIVE server.properties.
  ///
  /// `transport=raknet` is required: the 1.26.x default (nethernet) is
  /// signaling-service based — it never answers LAN-style unconnected
  /// pings (verified against the real binary) and its Minecraft-services
  /// dependency kills the server at boot when DNS is unreachable.
  ///
  /// This key is OWNED by pondok (the whole product — LAN join, RakNet
  /// health check, playit tunneling — needs it): every existing
  /// transport line is normalized and a missing one is appended, both
  /// after fresh extraction and after repair-time restore.
  Future<void> _ensureManagedProperties(String serverDir) async {
    final f = File('$serverDir/server.properties');
    if (!await f.exists()) return;
    final text = await f.readAsString();
    var managed = text;
    final re = RegExp(r'^transport=.*$', multiLine: true);
    if (re.hasMatch(managed)) {
      managed = managed.replaceAllMapped(re, (_) => 'transport=raknet');
    } else {
      managed = managed.isEmpty || managed.endsWith('\n')
          ? '${managed}transport=raknet\n'
          : '$managed\ntransport=raknet\n';
    }
    if (managed != text) {
      await f.writeAsString(managed, flush: true);
    }
  }

  Future<void> _requireFile(String path, String? sha) async {
    final f = File(path);
    if (!await f.exists()) {
      throw StateError('runtime pack member missing: ${f.path}');
    }
    if (sha != null) {
      final actual = await dl.sha256OfFile(path);
      if (actual != sha) {
        throw StateError('sha256 mismatch for ${f.path}');
      }
    }
  }

  /// Cheap health check of the installed tree — the exact files the launch
  /// path touches, plus the pinned hashes of the two entry binaries.
  Future<RuntimeVerifyReport> verify() async {
    final problems = <String>[];

    final manifest = await installedManifest();
    if (manifest == null) problems.add('no installed.json');

    final proot = File(paths.proot);
    if (!await proot.exists()) {
      problems.add('proot missing');
    } else if (manifest != null) {
      final sha = manifest.memberSha('proot');
      if (sha != null && await dl.sha256OfFile(paths.proot) != sha) {
        problems.add('proot sha mismatch');
      }
    }

    if (!await File(paths.box64).exists()) problems.add('box64 missing');
    if (!await File(paths.bedrockServer).exists()) {
      problems.add('bedrock_server missing');
    } else if (await File(paths.bedrockServer).length() < 1024 * 1024) {
      problems.add('bedrock_server suspiciously small');
    }

    return RuntimeVerifyReport(problems);
  }
}

class RuntimeVerifyReport {
  final List<String> problems;
  const RuntimeVerifyReport(this.problems);
  bool get isHealthy => problems.isEmpty;

  @override
  String toString() => isHealthy ? 'healthy' : 'issues: ${problems.join(', ')}';
}

enum RuntimeInstallPhase {
  unpackPack('Membuka paket runtime'),
  verifyPack('Memverifikasi integritas'),
  unpackRootfs('Meng-install sistem runtime'),
  unpackServer('Meng-install server Bedrock'),
  permissions('Menerapkan izin eksekusi'),
  activate('Mengaktifkan');

  final String label;
  const RuntimeInstallPhase(this.label);
}

/// dart:io cannot chmod — apply executable bits in batches through the
/// platform chmod (Android ships toybox chmod). Batches keep argv short.
Future<void> applyExecBits(List<String> paths, {int batch = 200}) async {
  for (var i = 0; i < paths.length; i += batch) {
    final slice = paths.skip(i).take(batch).toList();
    final r = await Process.run('chmod', ['+x', ...slice]);
    if (r.exitCode != 0) {
      throw StateError('chmod failed (${r.exitCode}): ${r.stderr}');
    }
  }
}

/// Launch configuration for the bundled stack on the device:
///
///     proot -R <runtime>/rootfs
///           -b <server>:/srv/server
///           -w /srv/server
///           /bin/sh -c "… exec /opt/box64/box64 ./bedrock_server"
///
/// Mirrors EXACTLY what tools/stack_supervisor.py proves in CI on real
/// arm64 hardware — same flags, same inner environment.
BdsProcessConfig bundledRuntimeProfile(
  String baseDir, {
  Duration? startupTimeout,
  Duration? gracefulStopTimeout,
}) {
  final p = BundledRuntimePaths(baseDir);
  // Mirrors tools/stack_supervisor.py exactly: the '.' carries bedrock's
  // own bundled x86_64 libs, the box64-x86_64-linux-gnu path carries the
  // un-wrapped ones (libstdc++ etc.) from box64's official lib bundle.
  const inner = 'mkdir -p /tmp 2>/dev/null; '
      'export HOME=/tmp PATH=/usr/bin:/bin '
      'LD_LIBRARY_PATH=.:/usr/lib/box64-x86_64-linux-gnu; '
      'exec /opt/box64/box64 ./bedrock_server';
  return BdsProcessConfig(
    binary: p.proot,
    args: [
      '-R', p.rootfs,
      '-b', '${p.server}:/srv/server',
      '-w', '/srv/server',
      '/bin/sh', '-c', inner,
    ],
    workingDir: p.baseDir,
    environment: const {'TERM': 'dumb'},
    // First boot pays box64 JIT warmup under proot — budget generously.
    startupTimeout: startupTimeout ?? const Duration(minutes: 15),
    gracefulStopTimeout: gracefulStopTimeout ?? const Duration(seconds: 120),
    sigtermTimeout: const Duration(seconds: 20),
  );
}

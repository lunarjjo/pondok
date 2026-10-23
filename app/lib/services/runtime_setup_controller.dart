import 'dart:io';

import 'package:flutter/foundation.dart';

import 'pack_source.dart';
import 'package:pondok_core/pondok_core.dart';

/// Orchestrates the ONE thing a fresh install has to do before the server
/// can run: unpack the bundled runtime from the APK (ADR-004 — zero setup,
/// zero downloads).
///
/// UX contract from the owner: "user tinggal pakai" — no configuration, no
/// runtime downloads, no Termux, nothing. The first launch shows a single
/// progress indicator while this runs; after that the app is ready forever
/// (self-healing: if the tree is damaged, it is rebuilt from the APK asset
/// while preserving worlds/ + server settings).
class RuntimeSetupController extends ChangeNotifier {
  /// APK asset path (Flutter-side).
  static const assetName = 'assets/runtime_pack.zip';

  final String baseDir;
  final PackSource packSource;

  RuntimeSetupController({required this.baseDir, PackSource? packSource})
      : packSource = packSource ?? PackSource();

  RuntimeSetupPhase _phase = RuntimeSetupPhase.checking;
  String? _error;
  RuntimePackManifest? _manifest;

  RuntimeSetupController.fromBaseDir(this.baseDir, {PackSource? packSource})
      : packSource = packSource ?? PackSource();

  RuntimeSetupPhase get phase => _phase;
  String? get error => _error;
  RuntimePackManifest? get manifest => _manifest;
  bool get isReady => _phase == RuntimeSetupPhase.ready;

  BundledRuntime get _runtime => BundledRuntime(baseDir);

  Future<void> ensureInstalled() async {
    _set(RuntimeSetupPhase.checking);
    try {
      // Healthy tree? install() is idempotent, but skip the whole copy
      // dance (and the disk space it needs) when we can tell upfront.
      final already = await _runtime.isInstalled();
      if (already) {
        _manifest = await _runtime.installedManifest();
        _set(RuntimeSetupPhase.ready);
        return;
      }

      _set(RuntimeSetupPhase.copyingPack);
      final packFile = '$baseDir/runtime_pack.zip.download';
      await Directory(baseDir).create(recursive: true);
      await packSource.copyTo(assetName, packFile);

      _set(RuntimeSetupPhase.installing);
      // Repair semantics: force only when a marker exists but the tree is
      // unhealthy — install() then rebuilds it while preserving player data.
      final markerExists = await File('$baseDir/installed.json').exists();
      final healthy = (await _runtime.verify()).isHealthy;
      final result = await _runtime.install(packFile, force: markerExists && !healthy);
      _manifest = result.manifest;

      await File(packFile).delete().catchError((_) => File(packFile));
      _set(RuntimeSetupPhase.ready);
    } catch (e) {
      _error = e.toString();
      _set(RuntimeSetupPhase.failed);
    }
  }

  void _set(RuntimeSetupPhase p) {
    _phase = p;
    notifyListeners();
  }
}

enum RuntimeSetupPhase {
  checking('Memeriksa runtime…'),
  copyingPack('Menyalin paket runtime dari APK…'),
  installing('Meng-install runtime — sekali saja…'),
  ready('Runtime siap'),
  failed('Gagal');

  final String label;
  const RuntimeSetupPhase(this.label);
}

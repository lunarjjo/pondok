import 'dart:io';

import 'package:flutter/services.dart';

/// Copies the bundled runtime pack (a ~150-250 MB asset) out of the APK
/// into a plain file the installer can read.
///
/// Why a platform channel instead of rootBundle: rootBundle.load() reads
/// the whole asset into memory — a 250 MB spike that low-RAM phones may
/// not survive. The Kotlin side streams it with a 64 KiB buffer.
class PackSource {
  static const _channel = MethodChannel('pondok/assets');

  /// [assetName] is the plain Flutter asset path (as declared in pubspec).
  /// The Android AssetManager needs the APK-level prefix — that mapping
  /// lives HERE, not at every call site; the test fallback then uses the
  /// plain path against rootBundle.
  Future<void> copyTo(String assetName, String destFile) async {
    try {
      await _channel.invokeMethod<int>('copyAsset', {
        'name': 'flutter_assets/$assetName',
        'dest': destFile,
      });
    } on MissingPluginException {
      // Widget/host tests: no Kotlin side. Fall back to rootBundle — test
      // packs are tiny, so the memory spike is acceptable there.
      // NOTE: caught BEFORE PlatformException — MissingPluginException is
      // a subtype of it.
      final data = await rootBundle.load(assetName);
      await File(destFile).writeAsBytes(data.buffer.asUint8List(), flush: true);
    } on PlatformException catch (e) {
      throw StateError('asset copy failed: ${e.code} ${e.message}');
    }
  }
}

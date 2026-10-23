import 'package:flutter/services.dart';

/// Best-effort device facts through the existing `pondok/assets` channel.
///
/// Used by the diagnostics ladder to decorate bug reports with the exact
/// hardware/OS context (model, ABI, SELinux state). Every failure maps to
/// an empty map — diagnostics must never die because a channel went
/// missing (tests run without the platform side).
class DeviceInfoService {
  static const _channel = MethodChannel('pondok/assets');

  Future<Map<String, String>> read() async {
    try {
      final res =
          await _channel.invokeMethod<Map<Object?, Object?>>('deviceInfo');
      if (res == null) return const {};
      return {
        for (final e in res.entries)
          e.key.toString(): e.value?.toString() ?? '',
      };
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    } catch (_) {
      return const {};
    }
  }
}

/// Persistent, rotation-bounded runtime log (D-17).
///
/// The single most expensive thing in a distributed on-device bug is
/// information that existed only in memory when the failure happened.
/// Every start attempt, exit, fallback switch, and probe result lands
/// here, so the user can hand us the file (or read the last lines in the
/// UI) instead of "tidak ada log error atau apapun yang tampil".
///
/// Semantics: append-only, best-effort, NEVER throws into the caller —
/// a logging failure must not become the next crash. Rotation keeps the
/// current file <= 256 KiB plus one .old generation.
library;

import 'dart:io';

class RuntimeLog {
  final String baseDir;
  static const _maxBytes = 256 * 1024;

  RuntimeLog(this.baseDir);

  String get path => '$baseDir/logs/pondok.log';
  String get oldPath => '$baseDir/logs/pondok.log.old';

  /// Appends one timestamped line. Safe on any failure.
  Future<void> log(String message) async {
    try {
      final dir = Directory('$baseDir/logs');
      if (!await dir.exists()) await dir.create(recursive: true);
      final f = File(path);
      if (await f.exists() && await f.length() > _maxBytes) {
        final old = File(oldPath);
        if (await old.exists()) await old.delete();
        await f.rename(oldPath);
      }
      final stamp = DateTime.now().toIso8601String().substring(0, 19);
      final lines = message.split('\n').map((l) => '$stamp $l').join('\n');
      await f.writeAsString('$lines\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Logging must never take the app down with it.
    }
  }

  /// Last [maxLines] lines currently on disk (for the UI / bug reports).
  Future<String> tail([int maxLines = 80]) async {
    try {
      final f = File(path);
      if (!await f.exists()) return '';
      final text = await f.readAsString();
      final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
      if (lines.length <= maxLines) return lines.join('\n');
      return lines.sublist(lines.length - maxLines).join('\n');
    } catch (_) {
      return '';
    }
  }
}

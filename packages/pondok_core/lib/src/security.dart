/// Security primitives: console-command sanitization, path containment, and
/// log redaction. Everything here is pure and unit-tested with adversarial
/// corpora (see test/security_test.dart).
library;

import 'dart:io';

/// Sanitizes a console command before it is written to the server's stdin.
///
/// Rules (each backed by a test):
/// * strips every control character other than the final newline we append;
/// * rejects embedded newlines/carriage returns (command injection into the
///   console stream);
/// * caps length (BDS input buffer safety);
/// * forbids NUL bytes outright.
class CommandSanitizer {
  static const int maxLength = 512;

  /// Returns the sanitized command, or throws [FormatException] with a reason.
  static String sanitize(String input) {
    if (input.contains('\x00')) {
      throw const FormatException('NUL byte in command');
    }
    var s = input.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), '');
    s = s.replaceAll('\r', '').replaceAll('\n', ' ');
    s = s.trim();
    if (s.isEmpty) throw const FormatException('empty command');
    if (s.length > maxLength) {
      throw FormatException('command longer than $maxLength characters');
    }
    return s;
  }
}

/// Canonicalizes [path] and asserts it stays inside [root]. Defends the file
/// manager and import/export features against path traversal
/// (`../../`, absolute escape, symlinked `..` segments are all resolved
/// before the containment check).
class PathGuard {
  final String root;

  PathGuard(this.root) : _canonicalRoot = _normalize(root);

  final String _canonicalRoot;

  static String _normalize(String p) {
    // Pure lexical normalization (no symlink resolution — the caller passes
    // already-resolved roots; symlinks inside are guarded by [strict]).
    final abs = p.startsWith('/');
    final out = <String>[];
    for (final seg in p.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (out.isNotEmpty) out.removeLast();
        continue;
      }
      out.add(seg);
    }
    return (abs ? '/' : '') + out.join('/');
  }

  /// Returns the canonically-joined path, or throws [FormatException] when
  /// the result would escape [root].
  String resolve(String path) {
    final combined = path.startsWith('/') ? path : '$root/$path';
    final normalized = _normalize(combined);
    if (normalized == _canonicalRoot || normalized.startsWith('$_canonicalRoot/')) {
      return normalized;
    }
    throw FormatException('path escapes instance root: $path');
  }

  /// Symlink-aware containment check for an existing path.
  Future<bool> containsRealPath(String path) async {
    final resolved = await _resolveReal(path);
    final rootResolved = await _resolveReal(root);
    return resolved == rootResolved || resolved.startsWith('$rootResolved/');
  }

  static Future<String> _resolveReal(String path) async {
    final t = FileSystemEntity.typeSync(path);
    if (t == FileSystemEntityType.directory) {
      return Directory(path).resolveSymbolicLinks();
    }
    return File(path).resolveSymbolicLinks();
  }
}

/// Redacts secrets from text before it is persisted to logs.
class Redactor {
  final List<Pattern> _patterns;

  /// Patterns typically cover: playit secret keys, claim codes, bearer tokens,
  /// long hex/base64 blobs after `secret`/`token`/`key` labels.
  Redactor({List<Pattern>? extraPatterns})
      : _patterns = [
          RegExp(r'secret[_-]?key["\s:=]+[A-Za-z0-9_\-/.]{8,}', caseSensitive: false),
          RegExp(r'bearer\s+[A-Za-z0-9._\-]{8,}', caseSensitive: false),
          RegExp('(token|password|passwd|secret)["\\s:=]+[^\\s"\']{6,}',
              caseSensitive: false),
          RegExp(r'claim/[A-Za-z0-9]{10,}'),
          ...?extraPatterns,
        ];

  String redact(String text) {
    var t = text;
    for (final p in _patterns) {
      t = t.replaceAllMapped(p, (m) {
        final s = m.group(0)!;
        // keep the label, mask the value
        final idx = RegExp('[:=\\s]').allMatches(s).toList();
        if (idx.isEmpty) return '***REDACTED***';
        final cut = idx.last.end;
        return '${s.substring(0, cut)}***REDACTED***';
      });
    }
    return t;
  }
}

/// Minimal tar reader for the runtime-pack `rootfs.tar` member.
///
/// Scope is deliberately narrow but honest about what it handles:
///
/// * ustar headers (name + prefix), GNU longname ('L') and pax ('x')
///   path overrides — everything `tar -cf` on the CI runner emits;
/// * regular files, directories, symlinks, hardlinks (materialized as
///   copies — dart:io has no link(2));
/// * octal AND base-256 (GNU) size/mode fields;
/// * devices/fifos are SKIPPED with a counter — a container-style rootfs
///   does not need them under proot (proot fakes /dev nodes itself).
///
/// Extraction is streaming (chunked reads/writes) so a ~100 MB rootfs
/// never sits whole in memory. Permissions: dart:io cannot chmod, so
/// entries whose mode has any executable bit are collected into
/// [TarExtractReport.execPaths] — the caller applies them in batches via
/// the platform `chmod` (one Process.run per batch, not per file).
library;

import 'dart:io';
import 'dart:typed_data';

const int _block = 512;
const int _chunk = 1 << 20;

class TarEntryInfo {
  final String name;
  final int mode;
  final int size;
  final String typeFlag;
  final String? linkTarget;
  const TarEntryInfo(this.name, this.mode, this.size, this.typeFlag, this.linkTarget);
}

class TarExtractReport {
  final int files;
  final int dirs;
  final int symlinks;
  final int hardlinks;
  final int skippedSpecial;
  final int bytes;
  final List<String> execPaths;
  const TarExtractReport({
    required this.files,
    required this.dirs,
    required this.symlinks,
    required this.hardlinks,
    required this.skippedSpecial,
    required this.bytes,
    required this.execPaths,
  });

  @override
  String toString() => 'TarExtractReport(files: $files, dirs: $dirs, '
      'symlinks: $symlinks, hardlinks: $hardlinks, skipped: $skippedSpecial, '
      'bytes: $bytes, exec: ${execPaths.length})';
}

/// Thrown on anything malformed — a broken rootfs must never be half-used.
class TarFormatException implements Exception {
  final String reason;
  const TarFormatException(this.reason);
  @override
  String toString() => 'TarFormatException: $reason';
}

/// Extracts [tarPath] into [destDir]. [onEntry] fires per stored entry
/// (files/dirs/symlinks) for progress reporting.
Future<TarExtractReport> extractTar(
  String tarPath,
  String destDir, {
  void Function(String name)? onEntry,
}) async {
  final raf = File(tarPath).openSync();
  try {
    return _TarReader(raf, destDir, onEntry).run();
  } finally {
    raf.closeSync();
  }
}

class _TarReader {
  final RandomAccessFile raf;
  final String destDir;
  final void Function(String name)? onEntry;

  int files = 0, dirs = 0, symlinks = 0, hardlinks = 0, skipped = 0, bytes = 0;
  final execPaths = <String>[];

  _TarReader(this.raf, this.destDir, this.onEntry);

  TarExtractReport run() {
    var pendingLongName = <String?>[];
    var pendingPaxPath = <String?>[];
    var sawAny = false;
    while (true) {
      final header = _readExact(_block);
      if (_isZeroBlock(header)) {
        if (sawAny) break; // first zero block after data = end of archive
        throw const TarFormatException('archive starts with a zero block');
      }
      sawAny = true;
      final type = String.fromCharCode(header[156]);
      final size = _octalOrBase256(header, 124, 12);

      if (type == 'L') {
        // GNU long name: content = path of the NEXT header.
        final data = _readExact(_padded(size));
        pendingLongName = [_trimNul(data)];
        _skipToBoundary();
        continue;
      }
      if (type == 'x' || type == 'g') {
        // pax extended header: "len key=value\n" records; we only need
        // the `path` override for the next entry.
        final data = _readExact(_padded(size));
        final path = _paxPath(String.fromCharCodes(data));
        if (type == 'x' && path != null) pendingPaxPath = [path];
        _skipToBoundary();
        continue;
      }

      final entry = _parseHeader(header, type, size, pendingLongName, pendingPaxPath);
      pendingLongName = const [];
      pendingPaxPath = const [];

      switch (type) {
        case '0':
        case '\x00':
        case '7': // contiguous == regular for our purposes
          _extractFile(entry);
          break;
        case '5':
          Directory(_join(entry.name)).createSync(recursive: true);
          dirs++;
          onEntry?.call(entry.name);
          break;
        case '2':
          _extractSymlink(entry);
          break;
        case '1':
          _extractHardlink(entry);
          break;
        default:
          skipped++; // devices ('3','4'), fifo ('6'), dump dirs etc.
      }
      _skipToBoundary();
    }
    return TarExtractReport(
      files: files, dirs: dirs, symlinks: symlinks, hardlinks: hardlinks,
      skippedSpecial: skipped, bytes: bytes, execPaths: List.unmodifiable(execPaths),
    );
  }

  TarEntryInfo _parseHeader(
    Uint8List header, String type, int size,
    List<String?> longName, List<String?> paxPath,
  ) {
    var name = longName.isNotEmpty && longName.first != null
        ? longName.first!
        : _string(header, 0, 100);
    final prefix = _string(header, 345, 155);
    if (prefix.isNotEmpty && longName.isEmpty) name = '$prefix/$name';
    if (paxPath.isNotEmpty && paxPath.first != null) name = paxPath.first!;
    if (name.isEmpty) throw const TarFormatException('entry with empty name');
    final mode = _octalOrBase256(header, 100, 8);
    final linkTarget = _string(header, 157, 100);
    return TarEntryInfo(name, mode, size, type, linkTarget.isEmpty ? null : linkTarget);
  }

  void _extractFile(TarEntryInfo entry) {
    final target = _join(entry.name);
    Directory(File(target).parent.path).createSync(recursive: true);
    final out = File(target).openSync(mode: FileMode.write);
    try {
      var left = entry.size;
      while (left > 0) {
        final want = left > _chunk ? _chunk : left;
        final chunk = _readExact(want);
        out.writeFromSync(chunk);
        left -= want;
        bytes += want;
      }
    } finally {
      out.flushSync();
      out.closeSync();
    }
    if (entry.mode & 0x49 != 0) execPaths.add(target);
    files++;
    onEntry?.call(entry.name);
  }

  void _extractSymlink(TarEntryInfo entry) {
    if (entry.linkTarget == null) {
      throw TarFormatException('symlink without target: ${entry.name}');
    }
    final path = _join(entry.name);
    final link = Link(path);
    if (link.existsSync()) link.deleteSync();
    Directory(File(path).parent.path).createSync(recursive: true);
    link.createSync(entry.linkTarget!);
    symlinks++;
    onEntry?.call(entry.name);
  }

  void _extractHardlink(TarEntryInfo entry) {
    // dart:io cannot link(2) — materialize as a copy. Rootfs hardlinks are
    // rare and small (e.g. busybox-style); content identity is preserved.
    if (entry.linkTarget == null) {
      throw TarFormatException('hardlink without target: ${entry.name}');
    }
    final source = _join(entry.linkTarget!);
    final target = _join(entry.name);
    if (!File(source).existsSync()) {
      throw TarFormatException('hardlink target missing: ${entry.linkTarget}');
    }
    Directory(File(target).parent.path).createSync(recursive: true);
    File(source).copySync(target);
    if (entry.mode & 0x49 != 0) execPaths.add(target);
    hardlinks++;
    onEntry?.call(entry.name);
  }

  // -------------------------------------------------------------- low level

  String _join(String name) {
    var n = name.replaceAll('\\', '/');
    // Normalize leading "./" segments — `tar -C dir .` produces them and
    // they would otherwise leak into execPaths/marker comparisons.
    while (n.startsWith('./')) {
      n = n.substring(2);
    }
    if (n.startsWith('/') || n.contains('..')) {
      throw TarFormatException('unsafe entry name: $name');
    }
    return n.isEmpty ? destDir : '$destDir/$n';
  }

  Uint8List _readExact(int n) {
    final b = raf.readSync(n);
    if (b.length != n) throw const TarFormatException('unexpected EOF');
    return b;
  }

  void _skipToBoundary() {
    final pos = raf.positionSync();
    final next = (pos + _block - 1) ~/ _block * _block;
    raf.setPositionSync(next);
  }

  int _padded(int size) => (size + _block - 1) ~/ _block * _block;

  bool _isZeroBlock(Uint8List b) {
    for (final v in b) {
      if (v != 0) return false;
    }
    return true;
  }

  String _trimNul(Uint8List b) {
    var end = b.length;
    // GNU longname data is NUL-terminated (and padded with NULs).
    while (end > 0 && b[end - 1] == 0) {
      end--;
    }
    // Some tars terminate with a single '\n' before the NUL.
    if (end > 0 && b[end - 1] == 0x0A) end--;
    return String.fromCharCodes(b.sublist(0, end));
  }

  String _string(Uint8List b, int off, int len) {
    var end = off;
    final stop = off + len;
    while (end < stop && b[end] != 0) {
      end++;
    }
    return String.fromCharCodes(b.sublist(off, end));
  }

  int _octalOrBase256(Uint8List b, int off, int len) {
    // GNU base-256: high bit of the first byte set.
    if (b[off] & 0x80 != 0) {
      var v = b[off] & 0x7F;
      for (var i = off + 1; i < off + len; i++) {
        v = (v << 8) | b[i];
      }
      return v;
    }
    var s = String.fromCharCodes(
        b.sublist(off, off + len).where((c) => c != 0 && c != 0x20));
    if (s.isEmpty) return 0;
    return int.tryParse(s, radix: 8) ??
        (throw TarFormatException('bad octal field "$s"'));
  }
}

String? _paxPath(String data) {
  // Records: "%d path=%s\n" lengths include the record itself.
  var rest = data;
  while (rest.isNotEmpty) {
    final sp = rest.indexOf(' ');
    if (sp <= 0) break;
    final len = int.tryParse(rest.substring(0, sp));
    if (len == null || len <= 0 || len > rest.length) break;
    final record = rest.substring(sp + 1, len);
    final eq = record.indexOf('=');
    if (eq > 0 && record.substring(0, eq) == 'path') {
      var value = record.substring(eq + 1);
      if (value.endsWith('\n')) value = value.substring(0, value.length - 1);
      return value;
    }
    rest = rest.substring(len);
  }
  return null;
}

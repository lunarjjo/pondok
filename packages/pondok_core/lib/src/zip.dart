/// Pure-Dart ZIP archive support (read + write) with CRC32 verification and
/// a from-scratch SHA-256 — the only hashing/serialization the core needs.
///
/// Why hand-rolled: the core is deliberately dependency-free (see
/// docs/DEPENDENCIES.md) so it runs on any CI host; decompression reuses
/// dart:io's zlib codec (raw deflate), while the container format, CRC32
/// and SHA-256 are implemented here. Limitations (documented, acceptable for
/// our artifacts): no Zip64 (entries < 4 GiB), no encryption, no spanning.
library;

import 'dart:io';
import 'dart:typed_data';

// --------------------------------------------------------------------- CRC32

final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
    t[n] = c;
  }
  return t;
}();

int crc32(List<int> data, [int seed = 0]) {
  var c = 0xFFFFFFFF ^ seed;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

// ------------------------------------------------------------------- SHA-256

/// Incremental SHA-256 (FIPS 180-4), pure Dart.
class Sha256 {
  final Uint32List _state = Uint32List.fromList([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ]);
  final Uint8List _buffer = Uint8List(64);
  int _bufferLen = 0;
  int _lengthBytes = 0;

  static const _k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, //
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  void update(List<int> data) {
    _lengthBytes += data.length;
    var i = 0;
    if (_bufferLen > 0) {
      while (_bufferLen < 64 && i < data.length) {
        _buffer[_bufferLen++] = data[i++];
      }
      if (_bufferLen == 64) {
        _processBlock(_buffer);
        _bufferLen = 0;
      }
    }
    while (i + 64 <= data.length) {
      _processBlock(Uint8List.fromList(data.sublist(i, i + 64)));
      i += 64;
    }
    while (i < data.length) {
      _buffer[_bufferLen++] = data[i++];
    }
  }

  int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

  void _processBlock(Uint8List block) {
    final w = Uint32List(64);
    for (var t = 0; t < 16; t++) {
      w[t] = (block[t * 4] << 24) |
          (block[t * 4 + 1] << 16) |
          (block[t * 4 + 2] << 8) |
          block[t * 4 + 3];
    }
    for (var t = 16; t < 64; t++) {
      final s0 = _rotr(w[t - 15], 7) ^ _rotr(w[t - 15], 18) ^ (w[t - 15] >> 3);
      final s1 = _rotr(w[t - 2], 17) ^ _rotr(w[t - 2], 19) ^ (w[t - 2] >> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & 0xFFFFFFFF;
    }
    var a = _state[0], b = _state[1], c = _state[2], d = _state[3];
    var e = _state[4], f = _state[5], g = _state[6], h = _state[7];
    for (var t = 0; t < 64; t++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ (~e & g);
      final temp1 = (h + s1 + ch + _k[t] + w[t]) & 0xFFFFFFFF;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xFFFFFFFF;
      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xFFFFFFFF;
    }
    _state[0] = (_state[0] + a) & 0xFFFFFFFF;
    _state[1] = (_state[1] + b) & 0xFFFFFFFF;
    _state[2] = (_state[2] + c) & 0xFFFFFFFF;
    _state[3] = (_state[3] + d) & 0xFFFFFFFF;
    _state[4] = (_state[4] + e) & 0xFFFFFFFF;
    _state[5] = (_state[5] + f) & 0xFFFFFFFF;
    _state[6] = (_state[6] + g) & 0xFFFFFFFF;
    _state[7] = (_state[7] + h) & 0xFFFFFFFF;
  }

  Uint8List digest() {
    final bitLen = _lengthBytes * 8;
    // padding: 0x80 then zeros until 56 mod 64, then 8-byte big-endian length
    final padLen = (_bufferLen < 56) ? 56 - _bufferLen : 120 - _bufferLen;
    final tail = Uint8List(padLen + 8);
    tail[0] = 0x80;
    for (var i = 0; i < 8; i++) {
      tail[padLen + i] = (bitLen >> (56 - 8 * i)) & 0xFF;
    }
    final savedBufferLen = _bufferLen;
    final savedLength = _lengthBytes;
    update(tail);
    // restore so digest() is idempotent-ish for testing edge cases
    _bufferLen = savedBufferLen;
    _lengthBytes = savedLength;

    final out = Uint8List(32);
    for (var i = 0; i < 8; i++) {
      out[i * 4] = (_state[i] >> 24) & 0xFF;
      out[i * 4 + 1] = (_state[i] >> 16) & 0xFF;
      out[i * 4 + 2] = (_state[i] >> 8) & 0xFF;
      out[i * 4 + 3] = _state[i] & 0xFF;
    }
    return out;
  }

  String hexDigest() => digest().map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

// -------------------------------------------------------------- ZIP reading

class ZipEntry {
  final String name;
  final int compressionMethod; // 0 store, 8 deflate
  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final bool isDirectory;
  final int localHeaderOffset;

  const ZipEntry({
    required this.name,
    required this.compressionMethod,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.isDirectory,
    required this.localHeaderOffset,
  });
}

class ZipArchive {
  final RandomAccessFile _raf;
  final List<ZipEntry> entries;

  ZipArchive._(this._raf, this.entries);

  static ZipArchive open(String path) {
    final raf = File(path).openSync();
    final size = raf.lengthSync();
    if (size < 22) {
      raf.closeSync();
      throw const FileSystemException('not a zip file (too small)');
    }
    // Locate EOCD by scanning backwards (comment may be present, ≤ 64 KiB).
    final scanWindow = size < 22 + 65536 ? size : 22 + 65536;
    raf.setPositionSync(size - scanWindow);
    final tail = raf.readSync(scanWindow);
    var eocd = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tail[i] == 0x50 &&
          tail[i + 1] == 0x4b &&
          tail[i + 2] == 0x05 &&
          tail[i + 3] == 0x06) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) {
      raf.closeSync();
      throw const FileSystemException('EOCD not found — not a zip file');
    }
    final entryCount = _u16(tail, eocd + 10);
    final cdOffset = _u32(tail, eocd + 16);

    // Read the central directory.
    final cdLen = size - cdOffset > 4 * 1024 * 1024 ? 4 * 1024 * 1024 : size - cdOffset;
    raf.setPositionSync(cdOffset);
    final cd = raf.readSync(cdLen);
    var p = 0;
    final entries = <ZipEntry>[];
    for (var n = 0; n < entryCount; n++) {
      if (p + 46 > cd.length || _u32(cd, p) != 0x02014b50) break;
      final method = _u16(cd, p + 10);
      final crc = _u32(cd, p + 16);
      final csize = _u32(cd, p + 20);
      final usize = _u32(cd, p + 24);
      final nameLen = _u16(cd, p + 28);
      final extraLen = _u16(cd, p + 30);
      final commentLen = _u16(cd, p + 32);
      final lho = _u32(cd, p + 42);
      final name = String.fromCharCodes(cd.sublist(p + 46, p + 46 + nameLen));
      entries.add(ZipEntry(
        name: name,
        compressionMethod: method,
        crc32: crc,
        compressedSize: csize,
        uncompressedSize: usize,
        isDirectory: name.endsWith('/'),
        localHeaderOffset: lho,
      ));
      p += 46 + nameLen + extraLen + commentLen;
    }
    return ZipArchive._(raf, entries);
  }

  /// Reads and decompresses one entry; verifies nothing (the caller —
  /// [extractZip] — checks CRC and decides policy).
  Uint8List? readEntry(ZipEntry entry) {
    _raf.setPositionSync(entry.localHeaderOffset);
    final lh = _raf.readSync(30);
    if (_u32(lh, 0) != 0x04034b50) return null;
    final nameLen = _u16(lh, 26);
    final extraLen = _u16(lh, 28);
    final dataStart = entry.localHeaderOffset + 30 + nameLen + extraLen;
    _raf.setPositionSync(dataStart);
    final compressed = _raf.readSync(entry.compressedSize);
    if (entry.compressionMethod == 0) {
      return Uint8List.fromList(compressed);
    }
    if (entry.compressionMethod == 8) {
      return Uint8List.fromList(ZLibCodec(raw: true).decoder.convert(compressed));
    }
    return null; // unsupported method
  }

  void close() => _raf.closeSync();
}

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
int _u32(Uint8List b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

// -------------------------------------------------------------- ZIP writing

/// Minimal, honest ZIP writer: deflate (or store) + correct CRC32 + central
/// directory. Used for backups and world export.
class ZipWriter {
  final RandomAccessFile _raf;
  final List<_WrittenEntry> _written = [];

  ZipWriter(String path) : _raf = File(path).openSync(mode: FileMode.write);

  void addFile(String name, List<int> data, {bool compress = true, int modTime = 0, int modDate = 0}) {
    final crc = crc32(data);
    List<int> stored = data;
    var method = 0;
    if (compress && data.length > 64) {
      final deflated = ZLibCodec(raw: true, level: 6).encoder.convert(data);
      if (deflated.length < data.length) {
        stored = deflated;
        method = 8;
      }
    }
    final nameBytes = name.codeUnits;
    final offset = _raf.positionSync();
    final header = ByteData(30);
    header.setUint32(0, 0x04034b50, Endian.little);
    header.setUint16(4, 20, Endian.little); // version needed
    header.setUint16(6, 0, Endian.little); // flags
    header.setUint16(8, method, Endian.little);
    header.setUint16(10, modTime, Endian.little);
    header.setUint16(12, modDate, Endian.little);
    header.setUint32(14, crc, Endian.little);
    header.setUint32(18, stored.length, Endian.little);
    header.setUint32(22, data.length, Endian.little);
    header.setUint16(26, nameBytes.length, Endian.little);
    header.setUint16(28, 0, Endian.little);
    _raf.writeFromSync(header.buffer.asUint8List());
    _raf.writeFromSync(nameBytes);
    _raf.writeFromSync(stored);
    _written.add(_WrittenEntry(
      name: name,
      crc: crc,
      csize: stored.length,
      usize: data.length,
      method: method,
      offset: offset,
      modTime: modTime,
      modDate: modDate,
    ));
  }

  /// Adds a directory entry (trailing slash).
  void addDirectory(String name) {
    final n = name.endsWith('/') ? name : '$name/';
    final nameBytes = n.codeUnits;
    final offset = _raf.positionSync();
    final header = ByteData(30);
    header.setUint32(0, 0x04034b50, Endian.little);
    header.setUint16(4, 20, Endian.little);
    header.setUint16(8, 0, Endian.little);
    header.setUint16(26, nameBytes.length, Endian.little);
    _raf.writeFromSync(header.buffer.asUint8List());
    _raf.writeFromSync(nameBytes);
    _written.add(_WrittenEntry(
      name: n,
      crc: 0,
      csize: 0,
      usize: 0,
      method: 0,
      offset: offset,
      modTime: 0,
      modDate: 0,
    ));
  }

  /// Recursively adds a directory tree from disk.
  Future<void> addTree(String rootPath, {String? prefix, bool Function(String path)? skip}) async {
    final p = prefix ?? '';
    final root = Directory(rootPath);
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      final rel = entity.path.substring(rootPath.length).replaceFirst(RegExp(r'^[/\\]'), '');
      if (rel.isEmpty) continue;
      if (skip != null && skip(entity.path)) continue;
      if (entity is File) {
        final data = await entity.readAsBytes();
        addFile('$p${rel.replaceAll('\\', '/')}', data);
      } else if (entity is Directory) {
        // Directory entries are implicit; only files are recorded.
      }
    }
  }

  /// Finalizes: writes the central directory + EOCD. Must be called once.
  Future<void> close() async {
    final cdStart = _raf.positionSync();
    for (final e in _written) {
      final nameBytes = e.name.codeUnits;
      final cd = ByteData(46);
      cd.setUint32(0, 0x02014b50, Endian.little);
      cd.setUint16(4, 20, Endian.little); // version made by
      cd.setUint16(6, 20, Endian.little); // version needed
      cd.setUint16(8, 0, Endian.little); // flags
      cd.setUint16(10, e.method, Endian.little);
      cd.setUint16(12, e.modTime, Endian.little);
      cd.setUint16(14, e.modDate, Endian.little);
      cd.setUint32(16, e.crc, Endian.little);
      cd.setUint32(20, e.csize, Endian.little);
      cd.setUint32(24, e.usize, Endian.little);
      cd.setUint16(28, nameBytes.length, Endian.little);
      cd.setUint16(30, 0, Endian.little); // extra len
      cd.setUint16(32, 0, Endian.little); // comment len
      cd.setUint16(34, 0, Endian.little); // disk start
      cd.setUint16(36, 0, Endian.little); // internal attrs
      cd.setUint32(38, 0, Endian.little); // external attrs
      cd.setUint32(42, e.offset, Endian.little);
      _raf.writeFromSync(cd.buffer.asUint8List());
      _raf.writeFromSync(nameBytes);
    }
    final cdSize = _raf.positionSync() - cdStart;
    final eocd = ByteData(22);
    eocd.setUint32(0, 0x06054b50, Endian.little);
    eocd.setUint16(8, _written.length, Endian.little);
    eocd.setUint16(10, _written.length, Endian.little);
    eocd.setUint32(12, cdSize, Endian.little);
    eocd.setUint32(16, cdStart, Endian.little);
    _raf.writeFromSync(eocd.buffer.asUint8List());
    await _raf.close();
  }
}

class _WrittenEntry {
  final String name;
  final int crc, csize, usize, method, offset, modTime, modDate;
  _WrittenEntry({
    required this.name,
    required this.crc,
    required this.csize,
    required this.usize,
    required this.method,
    required this.offset,
    required this.modTime,
    required this.modDate,
  });
}

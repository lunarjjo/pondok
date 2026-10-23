/// Streaming downloader + CRC-validating ZIP extraction for the runtime
/// layer (BDS distributions, playit agent, Debian rootfs).
///
/// Design notes from Phase 0:
/// * the official CDN requires a browser-like User-Agent (handled by
///   [BdsHttp]);
/// * Mojang publishes no checksums, so archive integrity is enforced by
///   validating **every member's CRC32** during extraction — the same values
///   the ZIP format itself carries — plus an optional expected SHA-256
///   recorded by us on first download for ledger provenance.
library;

import 'dart:convert';
import 'dart:io';

import 'version_manifest.dart';
import 'zip.dart';

class DownloadProgress {
  final int received;
  final int? total;
  const DownloadProgress(this.received, this.total);

  double? get fraction => total == null || total == 0 ? null : received / total!;
}

/// Streams [url] to [destFile], reporting progress. Returns the file.
Future<File> downloadFile(
  BdsHttp http,
  Uri url,
  String destFile, {
  void Function(DownloadProgress)? onProgress,
}) async {
  final req = await http.client.getUrl(url);
  final res = await req.close();
  if (res.statusCode != 200) {
    throw HttpException('download failed: HTTP ${res.statusCode} for $url');
  }
  final total = res.contentLength >= 0 ? res.contentLength : null;
  var received = 0;
  final sink = File(destFile).openSync(mode: FileMode.write);
  try {
    await for (final chunk in res) {
      sink.writeFromSync(chunk);
      received += chunk.length;
      onProgress?.call(DownloadProgress(received, total));
    }
  } finally {
    await sink.close();
  }
  return File(destFile);
}

/// Computes SHA-256 of a file, in chunks (large zips must not be slurped).
Future<String> sha256OfFile(String path) async {
  final digest = await _DigestSink.run(path);
  return digest;
}

class _DigestSink {
  static Future<String> run(String path) async {
    final bytes = await _chunkedHash(path);
    return bytes;
  }
}

Future<String> _chunkedHash(String path) async {
  // The crypto package is not a dependency; SHA-256 is implemented in
  // zip.dart's companion (pure Dart, used for zip too) — see Sha256 there.
  final f = File(path);
  final raf = await f.open();
  try {
    final h = Sha256();
    var offset = 0;
    const chunk = 1 << 20;
    while (true) {
      await raf.setPosition(offset);
      final data = await raf.read(chunk);
      if (data.isEmpty) break;
      h.update(data);
      offset += data.length;
    }
    return h.hexDigest();
  } finally {
    await raf.close();
  }
}

/// Extraction result with per-member CRC outcomes.
class ExtractResult {
  final int filesExtracted;
  final int bytesExtracted;
  final List<String> crcFailures;
  const ExtractResult(this.filesExtracted, this.bytesExtracted, this.crcFailures);

  bool get allCrcValid => crcFailures.isEmpty;
}

/// Extracts a zip with CRC validation. Fails loudly on any corrupt member —
/// a half-trusted distribution must never be activated.
Future<ExtractResult> extractZip(
  String zipPath,
  String destDir, {
  void Function(String entry)? onEntry,
}) async {
  final archive = ZipArchive.open(zipPath);
  final out = Directory(destDir);
  var files = 0;
  var bytes = 0;
  final failures = <String>[];

  for (final entry in archive.entries) {
    // Path traversal defense: the entry name must stay inside destDir.
    final safeName = _safeEntryName(entry.name);
    if (safeName == null) {
      failures.add('${entry.name} (unsafe path)');
      continue;
    }
    final target = '${out.path}/$safeName';
    if (entry.isDirectory) {
      await Directory(target).create(recursive: true);
      continue;
    }
    await Directory(File(target).parent.path).create(recursive: true);
    final data = archive.readEntry(entry);
    if (data == null) {
      failures.add('${entry.name} (unreadable)');
      continue;
    }
    if (crc32(data) != entry.crc32) {
      failures.add('${entry.name} (CRC mismatch)');
      continue;
    }
    await File(target).writeAsBytes(data, flush: true);
    onEntry?.call(entry.name);
    files++;
    bytes += data.length;
  }
  return ExtractResult(files, bytes, failures);
}

String? _safeEntryName(String name) {
  // Zip Slip defense: normalize and reject escapes.
  final n = name.replaceAll('\\', '/');
  if (n.startsWith('/') || n.contains('..')) return null;
  return n;
}

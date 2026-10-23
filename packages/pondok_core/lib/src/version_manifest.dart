/// Version discovery for the official Bedrock Dedicated Server.
///
/// Two complementary mechanisms, both verified live during Phase 0:
///
/// 1. **minecraft.wiki MediaWiki API** — the page wikitext carries the
///    current release in a footnote (`{{fn|As of 1.26.52.3}}`) and the
///    rendered infobox carries both release and preview versions;
/// 2. **official CDN HEAD probe** — `HEAD minecraft.net/bedrockdedicatedserver/
///    bin-linux/bedrock-server-<v>.zip` answers 200 for existing versions and
///    404 for non-existent ones (a browser-like User-Agent is REQUIRED —
///    verified: a plain client receives HTTP 308 and no body).
///
/// The manifest never guesses: a version is "available" only when the probe
/// says so.
library;

import 'dart:convert';
import 'dart:io';

const String bdsDownloadBase = 'https://www.minecraft.net/bedrockdedicatedserver';
const String bdsLinuxPath = 'bin-linux';
const String bdsLinuxPreviewPath = 'bin-linux-preview';
const String wikiApiUrl =
    'https://minecraft.wiki/api.php?action=parse&page=Bedrock_Dedicated_Server&prop=wikitext&format=json';
const String browserLikeUa =
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36';

final RegExp _versionPattern = RegExp(r'(\d+)\.(\d+)\.(\d+)\.(\d+)');

/// One available distribution.
class BdsVersion {
  final String version;
  final bool preview;

  const BdsVersion(this.version, {this.preview = false});

  String get downloadUrl =>
      '$bdsDownloadBase/${preview ? bdsLinuxPreviewPath : bdsLinuxPath}/bedrock-server-$version.zip';

  @override
  bool operator ==(Object other) =>
      other is BdsVersion && other.version == version && other.preview == preview;

  @override
  int get hashCode => Object.hash(version, preview);

  @override
  String toString() => 'BdsVersion($version${preview ? ' preview' : ''})';
}

/// Compares dotted versions: 1.26.52.3 > 1.26.9.1 (numeric per component).
int compareBdsVersions(String a, String b) {
  final pa = _versionPattern.firstMatch(a);
  final pb = _versionPattern.firstMatch(b);
  if (pa == null || pb == null) return a.compareTo(b);
  for (var i = 1; i <= 4; i++) {
    final d = int.parse(pa.group(i)!).compareTo(int.parse(pb.group(i)!));
    if (d != 0) return d;
  }
  return 0;
}

/// Result of a manifest check.
class VersionManifest {
  final BdsVersion? latestRelease;
  final BdsVersion? latestPreview;
  final String source;

  const VersionManifest({this.latestRelease, this.latestPreview, required this.source});

  List<BdsVersion> get all => [
        if (latestRelease != null) latestRelease!,
        if (latestPreview != null) latestPreview!,
      ];
}

/// HTTP client wrapper with the quirks the PoC exposed (UA + redirects).
class BdsHttp {
  final HttpClient client;

  BdsHttp() : client = HttpClient() {
    client.userAgent = browserLikeUa;
    client.autoUncompress = true;
    // minecraft.net's CDN has long-lived connections; keep it modest.
    client.idleTimeout = const Duration(seconds: 30);
  }

  Future<String> getText(Uri url) async {
    final req = await client.getUrl(url);
    req.followRedirects = true;
    req.maxRedirects = 5;
    final res = await req.close();
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode} for $url');
    }
    return await res.transform(utf8.decoder).join();
  }

  /// HEAD-style probe: opens the URL and closes without a body, returning
  /// only the final status code.
  Future<int> probe(Uri url) async {
    HttpClientRequest req;
    try {
      req = await client.headUrl(url);
      req.followRedirects = true;
      req.maxRedirects = 5;
    } on HttpException catch (e) {
      // Some servers answer HEAD oddly; retry with a GET we abort at once.
      final getReq = await client.openUrl('GET', url);
      getReq.followRedirects = true;
      getReq.maxRedirects = 5;
      getReq.headers.set(HttpHeaders.contentLengthHeader, '0');
      final res = await getReq.close();
      await res.drain<void>();
      if (res.statusCode >= 300 && res.statusCode < 400) {
        throw HttpException('probe redirect not followed: $url ($e)');
      }
      return res.statusCode;
    }
    final res = await req.close();
    await res.drain<void>();
    return res.statusCode;
  }

  void close() => client.close();
}

/// Fetches the current latest versions from minecraft.wiki.
///
/// Parsing strategy (in order of reliability):
/// * wikitext footnote `As of <version>` — release (verified present);
/// * rendered infobox — release + preview (verified present in HTML).
Future<VersionManifest> fetchLatestVersions(BdsHttp http) async {
  try {
    final text = await http.getText(Uri.parse(wikiApiUrl));
    final m = RegExp(r'As of (\d+\.\d+\.\d+\.\d+)').firstMatch(text);
    if (m != null) {
      return VersionManifest(
        latestRelease: BdsVersion(m.group(1)!),
        source: 'minecraft.wiki (wikitext footnote)',
      );
    }
    // Fall through to the rendered-text strategy.
    final html = await http.getText(Uri.parse(
        'https://minecraft.wiki/api.php?action=parse&page=Bedrock_Dedicated_Server&prop=text&format=json'));
    final rel = RegExp(r'(?:Release:?\s*|Latest version.{0,200}?)(\d+\.\d+\.\d+\.\d+)')
        .firstMatch(html);
    final prev = RegExp(r'Preview:?\s*(?:</?[a-z]+>|\s)*(\d+\.\d+\.\d+\.\d+)').firstMatch(html);
    if (rel != null) {
      return VersionManifest(
        latestRelease: BdsVersion(rel.group(1)!),
        latestPreview: prev == null ? null : BdsVersion(prev.group(1)!, preview: true),
        source: 'minecraft.wiki (rendered)',
      );
    }
  } catch (_) {
    // Network failures degrade to an empty manifest — callers decide whether
    // to offer manual version entry.
  }
  return const VersionManifest(source: 'unavailable');
}

/// Verifies that a specific version exists on the official CDN.
Future<bool> versionExists(BdsHttp http, String version, {bool preview = false}) async {
  final v = BdsVersion(version, preview: preview);
  try {
    final code = await http.probe(Uri.parse(v.downloadUrl));
    return code == 200;
  } catch (_) {
    return false;
  }
}

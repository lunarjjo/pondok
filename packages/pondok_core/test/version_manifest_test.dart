import 'dart:io';

import 'package:pondok_core/pondok_core.dart';
import 'package:test/test.dart';

/// Parsing logic is tested against FIXTURES captured from the live sources
/// during Phase 0 (2026-10-23). Live-network tests run only when the CI
/// runner opts in via PODOK_NETWORK_TESTS=1.
const wikiWikitextFixture =
    '| website = https://www.minecraft.net/en-us/download/server/bedrock\n'
    '| size =\n'
    "'''Release''':{{fn|As of 1.26.52.3}}<br>\n"
    '* Linux: \u2248 92.7 MB\n'
    '* Windows: \u2248 83.8 MB<br>\n';

void main() {
  group('BdsVersion', () {
    test('download URLs follow the verified official patterns', () {
      final rel = const BdsVersion('1.26.52.3');
      expect(rel.downloadUrl,
          'https://www.minecraft.net/bedrockdedicatedserver/bin-linux/bedrock-server-1.26.52.3.zip');
      final prev = const BdsVersion('1.26.70.20', preview: true);
      expect(prev.downloadUrl,
          'https://www.minecraft.net/bedrockdedicatedserver/bin-linux-preview/bedrock-server-1.26.70.20.zip');
    });

    test('equality and toString', () {
      expect(const BdsVersion('1.26.52.3'), const BdsVersion('1.26.52.3'));
      expect(const BdsVersion('1.26.52.3', preview: true),
          isNot(const BdsVersion('1.26.52.3')));
    });
  });

  group('wikitext footnote parsing (fixture from live API)', () {
    test('extracts the release version from the As-of footnote', () {
      final m = RegExp(r'As of (\d+\.\d+\.\d+\.\d+)').firstMatch(wikiWikitextFixture);
      expect(m, isNotNull);
      expect(m!.group(1), '1.26.52.3');
    });
  });

  group('live network (opt-in)', () {
    test('fetchLatestVersions reaches minecraft.wiki', () {
      if (Platform.environment['PODOK_NETWORK_TESTS'] != '1') {
        // CI sets this on a job with network; local offline runs skip.
        return;
      }
      final http = BdsHttp();
      addTearDown(http.close);
      final m = fetchLatestVersions(http);
      expect(m, completes);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('versionExists probes the official CDN', () async {
      if (Platform.environment['PODOK_NETWORK_TESTS'] != '1') {
        return;
      }
      final http = BdsHttp();
      addTearDown(http.close);
      expect(await versionExists(http, '1.26.52.3'), isTrue);
      expect(await versionExists(http, '1.00.00.00'), isFalse);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}

import 'package:pondok_core/pondok_core.dart';
import 'package:test/test.dart';

void main() {
  group('parseConsoleLine — format verified from real 1.26.52.3 logs', () {
    test('parses the canonical INFO line', () {
      const raw = '[2026-10-23 06:11:48:175 INFO] Starting Server';
      final l = parseConsoleLine(raw)!;
      expect(l.level, ConsoleLevel.info);
      expect(l.message, 'Starting Server');
      expect(l.time, DateTime(2026, 10, 23, 6, 11, 48, 175));
      expect(l.raw, raw);
    });

    test('parses WARN lines', () {
      final l = parseConsoleLine(
          '[2026-10-23 06:11:50:148 WARN] Allow list is enabled but contains no entries. ')!;
      expect(l.level, ConsoleLevel.warn);
      expect(l.message.trim(), 'Allow list is enabled but contains no entries.');
    });

    test('raw lines keep content and level raw', () {
      final l = parseConsoleLine('Quit correctly')!;
      expect(l.level, ConsoleLevel.raw);
      expect(l.message, 'Quit correctly');
    });

    test('NO LOG FILE line parses as raw', () {
      final l = parseConsoleLine('NO LOG FILE! - setting up server logging...')!;
      expect(l.level, ConsoleLevel.raw);
    });

    test('blank line returns null', () {
      expect(parseConsoleLine(''), isNull);
      expect(parseConsoleLine('\r'), isNull);
    });

    test('CRLF is stripped', () {
      final l = parseConsoleLine('[2026-10-23 06:11:48:175 INFO] Hi\r')!;
      expect(l.message, 'Hi');
    });

    test('ASCII art banner lines parse as raw', () {
      final l = parseConsoleLine('#####')!;
      expect(l.level, ConsoleLevel.raw);
    });

    test('message containing brackets is not mis-parsed', () {
      final l =
          parseConsoleLine('[2026-10-23 06:11:48:582 INFO] Accepting clients on [::]:19132')!;
      expect(l.message, 'Accepting clients on [::]:19132');
    });
  });

  group('ConsoleParser — streaming semantics (no folding)', () {
    test('every line is emitted immediately, banners included', () {
      final p = ConsoleParser();
      final a = p.feed('[2026-10-23 06:11:53:204 INFO] Stopping server...');
      expect(a!.message, 'Stopping server...');
      // Banner art is NOT swallowed into the previous entry — the console
      // screen must see it live (regression: folded updates never reached
      // stream listeners).
      final banner = p.feed('#              CREATING VANILLA WORLD               #');
      expect(banner, isNotNull);
      expect(banner!.level, ConsoleLevel.raw);
      expect(banner.message, contains('CREATING VANILLA WORLD'));
    });

    test('two consecutive prefixed lines both emit', () {
      final p = ConsoleParser();
      expect(p.feed('[2026-10-23 06:11:48:175 INFO] A'), isNotNull);
      expect(p.feed('[2026-10-23 06:11:48:176 INFO] B'), isNotNull);
    });

    test('flush is a no-op (nothing buffered)', () {
      final p = ConsoleParser();
      p.feed('[2026-10-23 06:11:48:175 INFO] only');
      expect(p.flush(), isNull);
    });
  });

  group('ConsoleEvents — regexes derived from real lines', () {
    test('serverStarted matches exactly', () {
      expect(ConsoleEvents.serverStarted.hasMatch('Server started.'), isTrue);
      expect(ConsoleEvents.serverStarted.hasMatch('Server started. Extra'), isFalse);
    });

    test('acceptingClients extracts the port', () {
      final m = ConsoleEvents.acceptingClients.firstMatch('Accepting clients on [::]:19140')!;
      expect(m.group(1), '19140');
    });

    test('playerCount parses max-players', () {
      final m = ConsoleEvents.playerCount.firstMatch('There are 0/10 players online:')!;
      expect(m.group(1), '0');
      expect(m.group(2), '10');
    });

    test('versionLine extracts version', () {
      final m = ConsoleEvents.versionLine.firstMatch('Version: 1.26.52.3')!;
      expect(m.group(1), '1.26.52.3');
    });

    test('openingLevel extracts path', () {
      final m = ConsoleEvents.openingLevel.firstMatch("Opening level 'worlds/Bedrock level/db'")!;
      expect(m.group(1), 'worlds/Bedrock level/db');
    });
  });

  group('ConsoleLineFilter', () {
    final lines = [
      parseConsoleLine('[2026-10-23 06:11:48:175 INFO] one')!,
      parseConsoleLine('[2026-10-23 06:11:49:175 WARN] two')!,
      parseConsoleLine('[2026-10-23 06:11:50:175 ERROR] three')!,
      parseConsoleLine('raw four')!,
    ];

    test('whereLevel filters', () {
      expect(lines.whereLevel({ConsoleLevel.warn, ConsoleLevel.error}).length, 2);
    });

    test('whereMessageMatches filters by regex', () {
      expect(lines.whereMessageMatches(RegExp(r'^three$')).length, 1);
      expect(lines.whereMessageMatches(RegExp(r'^t')).length, 2);
    });
  });
}

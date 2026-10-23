import 'package:pondok_core/pondok_core.dart';
import 'package:test/test.dart';

void main() {
  group('Allowlist — format verified live in the PoC', () {
    test('parses the exact output the server wrote', () {
      const json = '[{"ignoresPlayerLimit":false,"name":"PoCPlayer"}]';
      final a = Allowlist.parse(json);
      expect(a.entries, hasLength(1));
      expect(a.entries.first.name, 'PoCPlayer');
      expect(a.entries.first.ignoresPlayerLimit, isFalse);
      expect(a.entries.first.xuid, isNull);
    });

    test('parses entries with xuid', () {
      const json =
          '[{"name":"Alice","ignoresPlayerLimit":true,"xuid":"25354441234905673"}]';
      final a = Allowlist.parse(json);
      expect(a.entries.first.xuid, '25354441234905673');
      expect(a.entries.first.ignoresPlayerLimit, isTrue);
    });

    test('empty file parses to empty list', () {
      expect(Allowlist.parse('[]').entries, isEmpty);
    });

    test('add/remove/set round-trip', () {
      var a = const Allowlist([]);
      a = a.add('Alpha');
      a = a.add('Beta', ignoresPlayerLimit: true);
      expect(a.contains('Alpha'), isTrue);
      a = a.remove('Alpha');
      expect(a.contains('Alpha'), isFalse);
      a = a.setIgnoresPlayerLimit('Beta', false);
      expect(a.entries.first.ignoresPlayerLimit, isFalse);
    });

    test('add is idempotent by name', () {
      var a = const Allowlist([]).add('Dup').add('Dup');
      expect(a.entries, hasLength(1));
    });

    test('serialize is valid JSON the server could read back', () {
      final a = const Allowlist([]).add('PoCPlayer');
      final s = a.serialize();
      final back = Allowlist.parse(s);
      expect(back.entries, a.entries);
    });

    test('rejects non-array root', () {
      expect(() => Allowlist.parse('{"name":"x"}'), throwsFormatException);
    });

    test('console command forms', () {
      expect(Allowlist.commandAdd('Steve'), 'allowlist add Steve');
      expect(Allowlist.commandRemove('Steve'), 'allowlist remove Steve');
      expect(Allowlist.commandList(), 'allowlist list');
      expect(Allowlist.commandReload(), 'allowlist reload');
    });
  });
}

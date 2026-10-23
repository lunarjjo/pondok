import 'package:pondok_core/pondok_core.dart';
import 'package:test/test.dart';

/// Fixture: the exact head of the REAL 1.26.52.3 server.properties shipped
/// by Mojang (Phase 0 evidence). Round-trip stability is asserted against
/// the real formatting: comment blocks precede their keys.
const realPropertiesHead = '''
server-name=Dedicated Server
# Used as the server name
# Allowed values: Any string without semicolon symbol.

gamemode=survival
# Sets the game mode for new players.
# Allowed values: "survival", "creative", or "adventure"

difficulty=easy
# Sets the difficulty of the world.
# Allowed values: "peaceful", "easy", "normal", or "hard"

max-players=10
# The maximum number of players that can play on the server.
# Allowed values: Any positive integer

server-port=19132
transport=nethernet
view-distance=32
''';

void main() {
  group('ServerProperties.parse', () {
    test('parses the real file head', () {
      final p = ServerProperties.parse(realPropertiesHead);
      expect(p['server-name'], 'Dedicated Server');
      expect(p['gamemode'], 'survival');
      expect(p['difficulty'], 'easy');
      expect(p['max-players'], '10');
      expect(p['server-port'], '19132');
      expect(p['transport'], 'nethernet');
      expect(p['view-distance'], '32');
    });

    test('round-trip is stable (comments preserved)', () {
      final p = ServerProperties.parse(realPropertiesHead);
      final out = p.serialize();
      final p2 = ServerProperties.parse(out);
      expect(p2.toMap(), p.toMap());
      expect(out, realPropertiesHead);
    });

    test('unknown keys are kept and flagged', () {
      final p = ServerProperties.parse('some-future-key=42\nserver-port=19132\n');
      expect(p['some-future-key'], '42');
      expect(p.unknownKeys, contains('some-future-key'));
      expect(p.serialize(), contains('some-future-key=42'));
    });

    test('deprecated white-list alias is recognized', () {
      final p = ServerProperties.parse('white-list=true\n');
      expect(propertyRegistry['white-list']!.deprecatedBy, 'allow-list');
      expect(p['white-list'], 'true');
    });
  });

  group('ServerProperties validation (registry from the real file)', () {
    late final ServerProperties p;
    setUpAll(() {
      p = ServerProperties.parse('');
    });

    test('gamemode enum accepts allowed values only', () {
      expect(p.validate('gamemode', 'creative'), isNull);
      final e = p.validate('gamemode', 'hardcore')!;
      expect(e.reason, contains('survival'));
    });

    test('transport accepts raknet and nethernet only', () {
      expect(p.validate('transport', 'raknet'), isNull);
      expect(p.validate('transport', 'nethernet'), isNull);
      expect(p.validate('transport', 'quic'), isNotNull);
    });

    test('server-port range enforced', () {
      expect(p.validate('server-port', '19132'), isNull);
      expect(p.validate('server-port', '0'), isNotNull);
      expect(p.validate('server-port', '70000'), isNotNull);
      expect(p.validate('server-port', 'abc'), isNotNull);
    });

    test('boolean strictness', () {
      expect(p.validate('online-mode', 'true'), isNull);
      expect(p.validate('online-mode', 'TRUE'), isNotNull);
      expect(p.validate('online-mode', '1'), isNotNull);
    });

    test('max-players must be positive integer', () {
      expect(p.validate('max-players', '20'), isNull);
      expect(p.validate('max-players', '-3'), isNotNull);
      expect(p.validate('max-players', '1.5'), isNotNull);
    });

    test('view-distance bounds 4..32', () {
      expect(p.validate('view-distance', '8'), isNull);
      expect(p.validate('view-distance', '2'), isNotNull);
      expect(p.validate('view-distance', '64'), isNotNull);
    });

    test('server-name rejects semicolon (documented rule)', () {
      expect(p.validate('server-name', 'My Server'), isNull);
      expect(p.validate('server-name', 'a;b'), isNotNull);
    });

    test('difficulty enum', () {
      expect(p.validate('difficulty', 'peaceful'), isNull);
      expect(p.validate('difficulty', 'nightmare'), isNotNull);
    });

    test('set() throws on invalid value', () {
      final doc = ServerProperties.parse('server-port=19132\n');
      expect(() => doc.set('server-port', '99999'), throwsFormatException);
      expect(doc['server-port'], '19132'); // unchanged
    });

    test('set() updates and serializes', () {
      final doc = ServerProperties.parse(realPropertiesHead);
      doc.set('server-port', '19140');
      doc.set('server-name', 'PoC Test Server');
      final out = doc.serialize();
      expect(out, contains('server-port=19140'));
      expect(out, contains('server-name=PoC Test Server'));
      expect(out, contains('# Sets the game mode for new players.'));
    });

    test('default values match the real distribution', () {
      expect(propertyRegistry['transport']!.defaultValue, 'nethernet');
      expect(propertyRegistry['online-mode']!.defaultValue, 'true');
      expect(propertyRegistry['allow-list']!.defaultValue, 'true');
      expect(propertyRegistry['view-distance']!.defaultValue, '32');
      expect(propertyRegistry['compression-algorithm']!.allowedValues, ['zlib', 'snappy']);
    });
  });

  group('compareBdsVersions', () {
    test('numeric per component (not lexicographic)', () {
      expect(compareBdsVersions('1.26.52.3', '1.26.9.1'), greaterThan(0));
      expect(compareBdsVersions('1.26.9.1', '1.26.52.3'), lessThan(0));
      expect(compareBdsVersions('1.26.52.3', '1.26.52.3'), 0);
      expect(compareBdsVersions('2.0.0.0', '1.99.99.99'), greaterThan(0));
    });
  });
}

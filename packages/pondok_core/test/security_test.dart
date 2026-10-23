import 'package:pondok_core/pondok_core.dart';
import 'package:test/test.dart';

void main() {
  group('CommandSanitizer', () {
    test('passes plain commands', () {
      expect(CommandSanitizer.sanitize('list'), 'list');
      expect(CommandSanitizer.sanitize('  say hello world  '), 'say hello world');
      expect(CommandSanitizer.sanitize('allowlist add Steve'), 'allowlist add Steve');
    });

    test('newlines are neutralized (console injection)', () {
      expect(CommandSanitizer.sanitize('stop\nrm -rf /'), 'stop rm -rf /');
      expect(CommandSanitizer.sanitize('stop\r\nsay pwned'), 'stop say pwned');
    });

    test('NUL bytes rejected', () {
      expect(() => CommandSanitizer.sanitize('a\x00b'), throwsFormatException);
    });

    test('control characters stripped', () {
      expect(CommandSanitizer.sanitize('say\x08 hi\x07'), 'say hi');
    });

    test('empty command rejected', () {
      expect(() => CommandSanitizer.sanitize('   '), throwsFormatException);
    });

    test('oversized command rejected', () {
      expect(() => CommandSanitizer.sanitize('a' * 600), throwsFormatException);
    });
  });

  group('PathGuard', () {
    test('resolves inside root', () {
      final g = PathGuard('/data/instances/one/server');
      expect(g.resolve('worlds/Bedrock level/db'),
          '/data/instances/one/server/worlds/Bedrock level/db');
      expect(g.resolve('server.properties'),
          '/data/instances/one/server/server.properties');
    });

    test('rejects traversal', () {
      final g = PathGuard('/data/instances/one/server');
      expect(() => g.resolve('../../other/secret'), throwsFormatException);
      expect(() => g.resolve('worlds/../../../etc/passwd'), throwsFormatException);
    });

    test('rejects absolute escape', () {
      final g = PathGuard('/data/instances/one/server');
      expect(() => g.resolve('/etc/passwd'), throwsFormatException);
    });

    test('dot segments normalized but contained', () {
      final g = PathGuard('/data/i/server');
      expect(g.resolve('./worlds/./db'), '/data/i/server/worlds/db');
    });

    test('root itself allowed', () {
      final g = PathGuard('/data/i/server');
      expect(g.resolve('.'), '/data/i/server');
    });
  });

  group('Redactor', () {
    final r = Redactor();

    test('masks secret_key assignments', () {
      final out = r.redact('SECRET_KEY=abc123def456ghi789');
      expect(out, contains('***REDACTED***'));
      expect(out, isNot(contains('abc123def456ghi789')));
    });

    test('masks claim URLs', () {
      final out = r.redact('Visit https://playit.gg/claim/AbCdEf123456 to claim');
      expect(out, isNot(contains('AbCdEf123456')));
    });

    test('masks token/password labels', () {
      expect(r.redact('token: supersecret123'), contains('***REDACTED***'));
      expect(r.redact('password=hunter22222'), contains('***REDACTED***'));
    });

    test('leaves ordinary log lines intact', () {
      const line = '[2026-10-23 06:11:48:175 INFO] Server started.';
      expect(r.redact(line), line);
    });
  });
}

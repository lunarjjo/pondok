import 'dart:io';

import 'package:pondok_core/pondok_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pondok_log_');
  });
  tearDown(() => tmp.delete(recursive: true));

  test('log appends timestamped lines and reads them back', () async {
    final log = RuntimeLog(tmp.path);
    await log.log('start: mode proot');
    await log.log('gagal: exit 7');

    final tail = await log.tail();
    expect(tail, contains('start: mode proot'));
    expect(tail, contains('gagal: exit 7'));
    expect(tail.split('\n').first, startsWith('20'));
  });

  test('multiline messages keep one timestamp per line', () async {
    final log = RuntimeLog(tmp.path);
    await log.log('baris 1\nbaris 2');
    final tail = await log.tail();
    final lines = tail.split('\n');
    expect(lines, hasLength(2));
    expect(lines.every((l) => l.contains('20')), isTrue);
  });

  test('rotation bounds the file at 256 KiB plus one .old', () async {
    final log = RuntimeLog(tmp.path);
    final chunk = 'x' * 1024; // 1 KiB + timestamp per line
    for (var i = 0; i < 400; i++) {
      await log.log(chunk); // > 400 KiB total → at least one rotation
    }
    final f = File(log.path);
    expect(await f.exists(), isTrue);
    expect(await f.length(), lessThan(256 * 1024 + 4096));
    expect(await File(log.oldPath).exists(), isTrue);

    final tail = await log.tail(10);
    expect(tail.split('\n'), hasLength(10));
  });

  test('tail tolerates a missing file', () async {
    final log = RuntimeLog(tmp.path);
    expect(await log.tail(), '');
  });

  test('never throws on an unwritable base dir', () async {
    final log = RuntimeLog('/nonexistent-root/pondok');
    await log.log('masih aman');
    expect(await log.tail(), '');
  });
}

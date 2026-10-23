import 'dart:io';

import 'package:pondok_core/pondok_core.dart';
import 'package:test/test.dart';

import 'tar_test_helpers.dart';

/// The fixtures are built byte-by-byte (tar_test_helpers.dart) so the tests
/// control EVERY header field: modes, typeflags, GNU longname, pax
/// overrides, base-256 sizes. Plus one cross-check against the SYSTEM tar
/// — the same `tar -cf` our CI pack builder uses.
void main() {
  late Directory tmp;
  late String dest;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pondok_tar_');
    dest = '${tmp.path}/out';
    await Directory(dest).create();
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<String> writeTar(TarBuilder b) async {
    final f = File('${tmp.path}/fixture.tar');
    await f.writeAsBytes(b.finish());
    return f.path;
  }

  test('round-trip: files, dirs, symlink, hardlink, exec bits collected',
      () async {
    final b = TarBuilder()
      ..dir('usr/')
      ..dir('usr/bin/')
      ..file('usr/bin/tool', '#!/bin/sh\necho hi\n', mode: 0o755)
      ..file('etc/motd', 'welcome\n')
      ..symlink('usr/bin/alias', '../etc/motd')
      ..hardlink('usr/bin/hard', 'usr/bin/tool');
    final report = await extractTar(await writeTar(b), dest);

    expect(report.files, 3);
    expect(report.dirs, 2);
    expect(report.symlinks, 1);
    expect(report.hardlinks, 1);
    expect(report.execPaths, [
      '$dest/usr/bin/tool',
      '$dest/usr/bin/hard',
    ], reason: 'exec bit from mode 0755, hardlink inherits');
    expect(await File('$dest/etc/motd').readAsString(), 'welcome\n');
    expect(Link('$dest/usr/bin/alias').targetSync(), '../etc/motd');
    expect(await File('$dest/usr/bin/hard').readAsString(), '#!/bin/sh\necho hi\n');
  });

  test('GNU longname (path > 100 chars) resolves via L-member', () async {
    final long =
        'usr/lib/some/deeply/nested/directory/structure/' * 3 + 'libverylongname.so';
    expect(long.length, greaterThan(100));
    final b = TarBuilder()..gnuLongName(long, content: 'binary');
    final report = await extractTar(await writeTar(b), dest);
    expect(report.files, 1);
    expect(await File('$dest/$long').readAsString(), 'binary');
  });

  test('pax path override resolves', () async {
    final b = TarBuilder()..paxPath('opt/box64/pax-named-file', content: 'z');
    final report = await extractTar(await writeTar(b), dest);
    expect(report.files, 1);
    expect(await File('$dest/opt/box64/pax-named-file').readAsString(), 'z');
  });

  test('base-256 (GNU binary) size field decodes', () async {
    final b = TarBuilder()..file('big.bin', 'A' * 300, base256: true, mode: 0o755);
    final report = await extractTar(await writeTar(b), dest);
    expect(report.bytes, 300);
    expect(await File('$dest/big.bin').length(), 300);
  });

  test('device entries are skipped, not extracted', () async {
    final b = TarBuilder()
      ..dir('dev/')
      ..device('dev/null')
      ..file('README', 'fine');
    final report = await extractTar(await writeTar(b), dest);
    expect(report.skippedSpecial, 1);
    expect(await File('$dest/README').readAsString(), 'fine');
    expect(await File('$dest/dev/null').exists(), isFalse);
  });

  test('path traversal entry is rejected loudly', () async {
    final b = TarBuilder()..file('../escape', 'evil');
    await expectLater(
      extractTar(await writeTar(b), dest),
      throwsA(isA<TarFormatException>()),
    );
    expect(await File('${tmp.path}/escape').exists(), isFalse);
  });

  test('empty file (size 0) extracts as empty', () async {
    final b = TarBuilder()..file('empty.marker', '', mode: 0o755);
    final report = await extractTar(await writeTar(b), dest);
    expect(report.files, 1);
    expect(await File('$dest/empty.marker').length(), 0);
    expect(report.execPaths, contains('$dest/empty.marker'));
  });

  test('onEntry fires for stored entries', () async {
    final b = TarBuilder()
      ..dir('d/')
      ..file('d/f', '1')
      ..symlink('d/l', 'f');
    final seen = <String>[];
    await extractTar(await writeTar(b), dest, onEntry: seen.add);
    expect(seen, containsAll(['d/', 'd/f', 'd/l']));
  });

  test('CROSS-CHECK against system tar (same producer as CI)', () async {
    final tarBin = await Process.run('tar', ['--version']);
    if (tarBin.exitCode != 0) {
      return; // no system tar on this host
    }
    final src = Directory('${tmp.path}/tree');
    await Directory('${src.path}/usr/bin').create(recursive: true);
    await File('${src.path}/usr/bin/exec.sh').writeAsString('#!/bin/sh\n');
    await File('${src.path}/data.txt').writeAsString('payload');
    await Link('${src.path}/usr/bin/lnk').create('../data.txt');

    final tarFile = '${tmp.path}/sys.tar';
    final r = await Process.run('tar', ['-cf', tarFile, '-C', src.path, '.']);
    expect(r.exitCode, 0, reason: r.stderr.toString());

    final report = await extractTar(tarFile, dest);
    expect(report.files, 2);
    expect(report.symlinks, 1);
    expect(report.execPaths, contains('$dest/usr/bin/exec.sh'));
    expect(await File('$dest/data.txt').readAsString(), 'payload');
    expect(Link('$dest/usr/bin/lnk').targetSync(), '../data.txt');
  }, skip: Platform.isWindows ? 'posix-only' : false);
}

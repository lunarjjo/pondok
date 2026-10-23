import 'dart:convert';
import 'dart:typed_data';

/// Shared fixture builder for tar tests: a minimal ustar writer with full
/// control over every header field (modes, typeflags, GNU longname, pax
/// overrides, base-256 sizes). Test-only code — never shipped.
const int block = 512;

Uint8List _field(String s, int len) {
  final b = Uint8List(len);
  final src = ascii.encode(s);
  b.setRange(0, src.length.clamp(0, len), src);
  return b;
}

Uint8List _octal(int v, int len) =>
    _field('$v'.toRadixString(8).padLeft(len - 1, '0') + '\x00', len);

Uint8List _base256(int v, int len) {
  final b = Uint8List(len);
  var x = v;
  for (var i = len - 1; i > 0; i--) {
    b[i] = x & 0xFF;
    x >>= 8;
  }
  b[0] = 0x80;
  return b;
}

Uint8List _header({
  required String name,
  int mode = 0o644,
  int size = 0,
  String type = '0',
  String? link,
  bool base256Size = false,
}) {
  final h = Uint8List(block);
  h.setRange(0, 100, _field(name, 100));
  h.setRange(100, 108, _octal(mode, 8));
  h.setRange(108, 116, _octal(0, 8)); // uid
  h.setRange(116, 124, _octal(0, 8)); // gid
  h.setRange(
    124,
    136,
    base256Size ? _base256(size, 12) : _octal(size, 12),
  );
  h.setRange(136, 148, _octal(0, 12)); // mtime
  h.setRange(148, 156, _field('        ', 8)); // chksum placeholder
  h[156] = type.codeUnitAt(0);
  if (link != null) h.setRange(157, 257, _field(link, 100));
  h.setRange(257, 263, _field('ustar\x00', 6));
  h.setRange(263, 265, _field('00', 2));
  var sum = 0;
  for (final b in h) {
    sum += b;
  }
  final cs = '$sum'.toRadixString(8).padLeft(6, '0');
  h.setRange(148, 156, _field('$cs\x00 ', 8));
  return h;
}

Uint8List _pad(Uint8List data) {
  final padded = Uint8List((data.length + block - 1) ~/ block * block);
  padded.setRange(0, data.length, data);
  return padded;
}

class TarBuilder {
  final bytes = <int>[];

  void add(Uint8List header, [Uint8List? data]) {
    bytes.addAll(header);
    if (data != null && data.isNotEmpty) bytes.addAll(_pad(data));
  }

  void file(String name, String content, {int mode = 0o644, bool base256 = false}) =>
      add(_header(name: name, mode: mode, size: content.length, base256Size: base256),
          Uint8List.fromList(utf8.encode(content)));

  void rawFile(String name, List<int> data, {int mode = 0o644}) =>
      add(_header(name: name, mode: mode, size: data.length),
          Uint8List.fromList(data));

  void dir(String name) => add(_header(name: name, type: '5', mode: 0o755));

  void symlink(String name, String target) =>
      add(_header(name: name, type: '2', link: target, mode: 0o777));

  void hardlink(String name, String target) =>
      add(_header(name: name, type: '1', link: target, mode: 0o644));

  void gnuLongName(String realName, {int mode = 0o644, String content = 'x'}) {
    add(_header(name: '././@LongLink', type: 'L', size: realName.length + 1),
        Uint8List.fromList(utf8.encode('$realName\x00')));
    file(realName, content, mode: mode);
  }

  void paxPath(String realName, {String content = 'x'}) {
    final record = '${realName.length + 7} path=$realName\n';
    add(_header(name: ' PaxHeader', type: 'x', size: record.length),
        Uint8List.fromList(utf8.encode(record)));
    file(realName, content);
  }

  void device(String name) => add(_header(name: name, type: '3', mode: 0o666));

  Uint8List finish() =>
      Uint8List.fromList([...bytes, ...List.filled(block * 2, 0)]);
}

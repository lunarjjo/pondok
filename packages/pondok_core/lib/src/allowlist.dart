/// Allowlist (whitelist) management for BDS.
///
/// Format verified live during the Phase 0 PoC: `allowlist add PoCPlayer` on
/// the console rewrote `allowlist.json` to exactly
/// `[{"ignoresPlayerLimit":false,"name":"PoCPlayer"}]`. The file is managed
/// both ways in this app: direct file editing while the server is stopped,
/// and console commands while it runs (kept in sync by the manager).
library;

import 'dart:convert';
import 'dart:io';

class AllowlistEntry {
  final String name;
  final bool ignoresPlayerLimit;

  /// Xbox Live XUID — present for entries added from a running server with
  /// online players; absent for entries added by name only.
  final String? xuid;

  const AllowlistEntry({required this.name, this.ignoresPlayerLimit = false, this.xuid});

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{'name': name, 'ignoresPlayerLimit': ignoresPlayerLimit};
    if (xuid != null) m['xuid'] = xuid;
    return m;
  }

  static AllowlistEntry fromJson(Map<String, dynamic> j) => AllowlistEntry(
        name: (j['name'] ?? '') as String,
        ignoresPlayerLimit: (j['ignoresPlayerLimit'] ?? false) as bool,
        xuid: j['xuid'] == null ? null : j['xuid'].toString(),
      );

  @override
  bool operator ==(Object other) =>
      other is AllowlistEntry && other.name == name && other.xuid == xuid;

  @override
  int get hashCode => Object.hash(name, xuid);

  @override
  String toString() => 'AllowlistEntry($name${xuid == null ? '' : ', xuid: $xuid'})';
}

/// Parsed allowlist document with round-trip-stable serialization.
class Allowlist {
  final List<AllowlistEntry> entries;

  const Allowlist(this.entries);

  static Allowlist parse(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! List) {
      throw const FormatException('allowlist.json must be a JSON array');
    }
    return Allowlist([
      for (final item in decoded)
        if (item is Map<String, dynamic>) AllowlistEntry.fromJson(item),
    ]);
  }

  static Future<Allowlist> loadFile(String path) async {
    final f = File(path);
    if (!await f.exists()) return const Allowlist([]);
    return parse(await f.readAsString());
  }

  bool contains(String name) => entries.any((e) => e.name == name);

  Allowlist add(String name, {bool ignoresPlayerLimit = false, String? xuid}) {
    if (contains(name)) return this;
    return Allowlist([...entries, AllowlistEntry(name: name, ignoresPlayerLimit: ignoresPlayerLimit, xuid: xuid)]);
  }

  Allowlist remove(String name) =>
      Allowlist(entries.where((e) => e.name != name).toList());

  Allowlist setIgnoresPlayerLimit(String name, bool value) => Allowlist([
        for (final e in entries)
          e.name == name ? AllowlistEntry(name: e.name, ignoresPlayerLimit: value, xuid: e.xuid) : e,
      ]);

  String serialize() => const JsonEncoder.withIndent('  ').convert(entries.map((e) => e.toJson()).toList());

  Future<void> saveFile(String path) async {
    await File(path).writeAsString(serialize());
  }

  /// Console command form — verified live in the PoC.
  static String commandAdd(String name) => 'allowlist add $name';
  static String commandRemove(String name) => 'allowlist remove $name';
  static String commandList() => 'allowlist list';
  static String commandReload() => 'allowlist reload';
}

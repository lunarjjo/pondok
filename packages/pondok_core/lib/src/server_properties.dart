/// Typed reader/writer for `server.properties` with per-key validation.
///
/// The [PropertyRegistry] below is derived from the **real 1.26.52.3
/// distribution file** (Phase 0 evidence): defaults and allowed values mirror
/// what Mojang ships, including the new `transport` and script-debugging keys.
/// Unknown keys are preserved (passthrough) but flagged so the editor can
/// warn instead of silently dropping configuration.
library;

import 'dart:io';

enum PropType { string, boolean, integer, decimal, enumeration }

class PropSpec {
  final String name;
  final PropType type;
  final String? defaultValue;
  final List<String>? allowedValues;
  final int? minInt;
  final int? maxInt;
  final double? minDouble;
  final double? maxDouble;
  final String? deprecatedBy;

  const PropSpec.string(this.name, {this.defaultValue, this.deprecatedBy})
      : type = PropType.string,
        allowedValues = null,
        minInt = null,
        maxInt = null,
        minDouble = null,
        maxDouble = null;

  const PropSpec.boolean(this.name, {this.defaultValue, this.deprecatedBy})
      : type = PropType.boolean,
        allowedValues = null,
        minInt = null,
        maxInt = null,
        minDouble = null,
        maxDouble = null;

  const PropSpec.integer(
    this.name, {
    this.defaultValue,
    this.minInt,
    this.maxInt,
    this.deprecatedBy,
  })  : type = PropType.integer,
        allowedValues = null,
        minDouble = null,
        maxDouble = null;

  const PropSpec.decimal(
    this.name, {
    this.defaultValue,
    this.minDouble,
    this.maxDouble,
    this.deprecatedBy,
  })  : type = PropType.decimal,
        allowedValues = null,
        minInt = null,
        maxInt = null;

  const PropSpec.enumeration(
    this.name, {
    this.defaultValue,
    required this.allowedValues,
    this.deprecatedBy,
  })  : type = PropType.enumeration,
        minInt = null,
        maxInt = null,
        minDouble = null,
        maxDouble = null;
}

/// Registry of every key understood in a 1.26.x server.properties.
const propertyRegistry = <String, PropSpec>{
  'server-name': PropSpec.string('server-name', defaultValue: 'Dedicated Server'),
  'gamemode': PropSpec.enumeration('gamemode',
      defaultValue: 'survival', allowedValues: ['survival', 'creative', 'adventure']),
  'force-gamemode': PropSpec.boolean('force-gamemode', defaultValue: 'false'),
  'difficulty': PropSpec.enumeration('difficulty',
      defaultValue: 'easy', allowedValues: ['peaceful', 'easy', 'normal', 'hard']),
  'allow-cheats': PropSpec.boolean('allow-cheats', defaultValue: 'false'),
  'max-players': PropSpec.integer('max-players', defaultValue: '10', minInt: 1),
  'online-mode': PropSpec.boolean('online-mode', defaultValue: 'true'),
  'allow-list': PropSpec.boolean('allow-list', defaultValue: 'true'),
  'server-port': PropSpec.integer('server-port', defaultValue: '19132', minInt: 1, maxInt: 65535),
  // New in 1.26.x: classic RakNet vs NetherNet (WebRTC signaling) transport.
  // Free-tier UDP tunnels (playit.gg) carry classic RakNet — the tunnel setup
  // therefore enforces transport=raknet. Verified default: nethernet.
  'transport': PropSpec.enumeration('transport',
      defaultValue: 'nethernet', allowedValues: ['raknet', 'nethernet']),
  'enable-lan-visibility': PropSpec.boolean('enable-lan-visibility', defaultValue: 'true'),
  'view-distance': PropSpec.integer('view-distance', defaultValue: '32', minInt: 4, maxInt: 32),
  'tick-distance': PropSpec.integer('tick-distance', defaultValue: '4', minInt: 4, maxInt: 32),
  'player-idle-timeout': PropSpec.integer('player-idle-timeout', defaultValue: '30', minInt: 0),
  'max-threads': PropSpec.integer('max-threads', defaultValue: '8', minInt: 1),
  'level-name': PropSpec.string('level-name', defaultValue: 'Bedrock level'),
  'level-seed': PropSpec.string('level-seed', defaultValue: ''),
  'default-player-permission-level': PropSpec.enumeration(
      'default-player-permission-level',
      defaultValue: 'member',
      allowedValues: ['visitor', 'member', 'operator']),
  'texturepack-required': PropSpec.boolean('texturepack-required', defaultValue: 'false'),
  'content-log-file-enabled': PropSpec.boolean('content-log-file-enabled', defaultValue: 'false'),
  'content-log-console-output-enabled':
      PropSpec.boolean('content-log-console-output-enabled', defaultValue: 'false'),
  'content-log-level': PropSpec.string('content-log-level', defaultValue: 'info'),
  'compression-threshold': PropSpec.integer('compression-threshold', defaultValue: '1', minInt: 0),
  'compression-algorithm': PropSpec.enumeration('compression-algorithm',
      defaultValue: 'zlib', allowedValues: ['zlib', 'snappy']),
  'server-authoritative-movement-strict':
      PropSpec.boolean('server-authoritative-movement-strict', defaultValue: 'false'),
  'server-authoritative-dismount-strict':
      PropSpec.boolean('server-authoritative-dismount-strict', defaultValue: 'false'),
  'server-authoritative-entity-interactions-strict':
      PropSpec.boolean('server-authoritative-entity-interactions-strict', defaultValue: 'false'),
  'player-position-acceptance-threshold': PropSpec.decimal(
      'player-position-acceptance-threshold',
      defaultValue: '0.5',
      minDouble: 0),
  'player-movement-action-direction-threshold': PropSpec.decimal(
      'player-movement-action-direction-threshold', defaultValue: '0.85', minDouble: 0),
  'server-authoritative-block-breaking-pick-range-scalar': PropSpec.decimal(
      'server-authoritative-block-breaking-pick-range-scalar',
      defaultValue: '1.5',
      minDouble: 0),
  'chat-restriction': PropSpec.enumeration('chat-restriction',
      defaultValue: 'None',
      allowedValues: ['None', 'KeepUntilLogin', 'AlwaysBlocked']),
  'disable-player-interaction':
      PropSpec.boolean('disable-player-interaction', defaultValue: 'false'),
  'client-side-chunk-generation-enabled':
      PropSpec.boolean('client-side-chunk-generation-enabled', defaultValue: 'true'),
  'block-network-ids-are-hashes':
      PropSpec.boolean('block-network-ids-are-hashes', defaultValue: 'true'),
  'disable-persona': PropSpec.boolean('disable-persona', defaultValue: 'false'),
  'disable-custom-skins': PropSpec.boolean('disable-custom-skins', defaultValue: 'false'),
  'server-build-radius-ratio':
      PropSpec.string('server-build-radius-ratio', defaultValue: 'Disabled'),
  'allow-outbound-script-debugging':
      PropSpec.boolean('allow-outbound-script-debugging', defaultValue: 'false'),
  'allow-inbound-script-debugging':
      PropSpec.boolean('allow-inbound-script-debugging', defaultValue: 'false'),
  'script-debugger-auto-attach': PropSpec.enumeration(
      'script-debugger-auto-attach', defaultValue: 'disabled', allowedValues: [
    'disabled',
    'connect',
    'listen',
  ]),
  // Compatibility keys seen in older distributions / community guides:
  'white-list': PropSpec.boolean('white-list', defaultValue: 'false', deprecatedBy: 'allow-list'),
  'motd': PropSpec.string('motd', defaultValue: ''),
  'text-motd': PropSpec.string('text-motd', defaultValue: ''),
  'server-portv6':
      PropSpec.integer('server-portv6', defaultValue: '19133', minInt: 1, maxInt: 65535),
};

/// One property entry as stored in the document (preserving layout).
class PropertyEntry {
  final String key;
  String value;
  final List<String> leadingComments;
  final int? sourceLine;

  PropertyEntry(this.key, this.value, this.leadingComments, {this.sourceLine});
}

/// Validation failure with a human-readable reason.
class PropertyValidationError {
  final String key;
  final String value;
  final String reason;
  PropertyValidationError(this.key, this.value, this.reason);

  @override
  String toString() => 'invalid $key="$value": $reason';
}

/// A parsed server.properties document, layout-preserving.
class ServerProperties {
  final List<PropertyEntry> entries;
  final List<String> trailingLines;
  final List<String> unknownKeys;

  ServerProperties._(this.entries, this.trailingLines, this.unknownKeys);

  static ServerProperties parse(String text) {
    final entries = <PropertyEntry>[];
    final trailing = <String>[];
    final unknown = <String>[];
    final pending = <String>[];
    var lines = text.split('\n');
    // Drop the artifact of a single trailing newline ('a\n' -> ['a','']).
    if (lines.isNotEmpty && lines.last.isEmpty) lines = lines.sublist(0, lines.length - 1);
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();
      if (trimmed.startsWith('#') || trimmed.isEmpty) {
        pending.add(line);
        continue;
      }
      final eq = trimmed.indexOf('=');
      if (eq <= 0) {
        pending.add(line); // malformed lines ride along, preserved in order
        continue;
      }
      final key = trimmed.substring(0, eq).trim();
      final value = trimmed.substring(eq + 1).trim();
      entries.add(PropertyEntry(key, value, List.of(pending), sourceLine: i + 1));
      pending.clear();
      if (!propertyRegistry.containsKey(key) && !unknown.contains(key)) {
        unknown.add(key);
      }
    }
    // Whatever never attached to an entry is trailing content.
    trailing.addAll(pending);
    return ServerProperties._(entries, trailing, unknown);
  }

  /// Loads from a file path (dart:io).
  static Future<ServerProperties> loadFile(String path) async {
    return parse(await File(path).readAsString());
  }

  String? operator [](String key) {
    for (final e in entries) {
      if (e.key == key) return e.value;
    }
    return null;
  }

  /// Sets a value after validating it; returns the previous value.
  /// Throws [FormatException] on invalid input — callers surface it in the UI.
  String? set(String key, String value) {
    final failure = validate(key, value);
    if (failure != null) {
      throw FormatException(failure.toString());
    }
    String? previous;
    final spec = propertyRegistry[key];
    for (final e in entries) {
      if (e.key == key) {
        previous = e.value;
        e.value = value;
      }
    }
    if (previous == null) {
      entries.add(PropertyEntry(key, value, []));
      if (spec == null && !unknownKeys.contains(key)) unknownKeys.add(key);
    }
    return previous;
  }

  /// Validates a candidate value; returns null when acceptable.
  PropertyValidationError? validate(String key, String value) {
    final spec = propertyRegistry[key];
    if (spec == null) return null; // passthrough, flagged elsewhere
    switch (spec.type) {
      case PropType.boolean:
        if (value != 'true' && value != 'false') {
          return PropertyValidationError(key, value, 'must be "true" or "false"');
        }
        break;
      case PropType.integer:
        final n = int.tryParse(value);
        if (n == null) return PropertyValidationError(key, value, 'must be an integer');
        if (spec.minInt != null && n < spec.minInt!) {
          return PropertyValidationError(key, value, 'must be >= ${spec.minInt}');
        }
        if (spec.maxInt != null && n > spec.maxInt!) {
          return PropertyValidationError(key, value, 'must be <= ${spec.maxInt}');
        }
        break;
      case PropType.decimal:
        final d = double.tryParse(value);
        if (d == null) return PropertyValidationError(key, value, 'must be a number');
        if (spec.minDouble != null && d < spec.minDouble!) {
          return PropertyValidationError(key, value, 'must be >= ${spec.minDouble}');
        }
        if (spec.maxDouble != null && d > spec.maxDouble!) {
          return PropertyValidationError(key, value, 'must be <= ${spec.maxDouble}');
        }
        break;
      case PropType.enumeration:
        if (!spec.allowedValues!.contains(value)) {
          return PropertyValidationError(
              key, value, 'allowed: ${spec.allowedValues!.join(', ')}');
        }
        break;
      case PropType.string:
        if (key == 'server-name' && value.contains(';')) {
          return PropertyValidationError(key, value, 'semicolon is not allowed');
        }
        break;
    }
    return null;
  }

  /// All validation problems of the current document.
  List<PropertyValidationError> validateAll() => [
        for (final e in entries)
          if (validate(e.key, e.value) != null) validate(e.key, e.value)!,
      ];

  /// Serializes back, preserving comments and ordering.
  String serialize() {
    final out = StringBuffer();
    for (final e in entries) {
      for (final c in e.leadingComments) {
        out.writeln(c);
      }
      out.writeln('${e.key}=${e.value}');
    }
    for (final t in trailingLines) {
      out.writeln(t);
    }
    return out.toString();
  }

  Future<void> saveFile(String path) async {
    await File(path).writeAsString(serialize());
  }

  Map<String, String> toMap() => {for (final e in entries) e.key: e.value};
}

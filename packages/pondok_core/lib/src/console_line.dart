/// Console output parsing for the Minecraft Bedrock Dedicated Server.
///
/// The observed (Phase 0, verified against real 1.26.52.3 logs) line format is:
///
/// ```text
/// [2026-10-23 06:11:48:175 INFO] Starting Server
/// ```
///
/// that is `[YYYY-MM-DD HH:MM:SS:mmm LEVEL] message` where the timestamp uses
/// milliseconds after seconds (three digits) and the level is one of INFO,
/// WARN, ERROR (other levels are preserved as parsed). Real servers also emit:
///
/// * raw lines with no prefix (e.g. `Quit correctely`, `NO LOG FILE! - ...`,
///   ASCII-art banners), which are kept with level [ConsoleLevel.raw];
/// * continuation lines of a previous entry — attached when [parseConsole]
///   is used as a stateful stream parser.
library;

/// Severity of a console line.
enum ConsoleLevel { info, warn, error, debug, raw }

/// One structured console line emitted by the server.
class ConsoleLine {
  /// Wall-clock time as printed by the server (local time of the process).
  final DateTime? time;

  /// Severity. [ConsoleLevel.raw] for non-prefixed lines.
  final ConsoleLevel level;

  /// The message body, without the `[timestamp LEVEL]` prefix.
  final String message;

  /// Original, unmodified line — used for the raw console view and evidence.
  final String raw;

  const ConsoleLine({
    required this.level,
    required this.message,
    required this.raw,
    this.time,
  });

  @override
  bool operator ==(Object other) =>
      other is ConsoleLine &&
      other.raw == raw &&
      other.level == level &&
      other.message == message;

  @override
  int get hashCode => Object.hash(raw, level, message);

  @override
  String toString() => 'ConsoleLine(${raw.length > 72 ? '${raw.substring(0, 72)}…' : raw})';
}

final RegExp _prefixed = RegExp(
  r'^\[(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2}):(\d{3}) ([A-Z]+)\] ?(.*)$',
);

ConsoleLevel _levelFor(String token) {
  switch (token) {
    case 'INFO':
      return ConsoleLevel.info;
    case 'WARN':
    case 'WARNING':
      return ConsoleLevel.warn;
    case 'ERROR':
      return ConsoleLevel.error;
    case 'DEBUG':
      return ConsoleLevel.debug;
    default:
      return ConsoleLevel.raw;
  }
}

/// Parses a single line. Returns `null` for blank lines.
ConsoleLine? parseConsoleLine(String line) {
  final l = line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
  if (l.isEmpty) return null;
  final m = _prefixed.firstMatch(l);
  if (m == null) {
    return ConsoleLine(level: ConsoleLevel.raw, message: l, raw: l);
  }
  final time = DateTime(
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6)!),
    int.parse(m.group(7)!),
  );
  return ConsoleLine(
    time: time,
    level: _levelFor(m.group(8)!),
    message: m.group(9) ?? '',
    raw: l,
  );
}

/// Stateful parser for a stream of console output.
///
/// Design note: every line is emitted as its own [ConsoleLine] immediately —
/// including banner art and non-prefixed lines. An earlier draft folded
/// continuations into the previous entry, but folded updates never reach an
/// already-emitted stream listener (the real console screen showed stale
/// text and "CREATING VANILLA WORLD" disappeared) — liveness beats tidiness.
class ConsoleParser {
  /// Feeds one line; returns the parsed [ConsoleLine] or `null` for blank.
  ConsoleLine? feed(String line) => parseConsoleLine(line);

  /// Kept for API compatibility; nothing is buffered, so nothing to flush.
  ConsoleLine? flush() => null;
}

/// Convenience filters used by the console screen.
extension ConsoleLineFilter on List<ConsoleLine> {
  List<ConsoleLine> whereLevel(Set<ConsoleLevel> levels) =>
      where((l) => levels.contains(l.level)).toList();

  List<ConsoleLine> whereMessageMatches(Pattern pattern) => where((l) {
        if (pattern is RegExp) return pattern.hasMatch(l.message);
        return l.message.contains(pattern);
      }).toList();
}

/// Notable console events the supervisor reacts to. Derived exclusively from
/// lines observed in real runs (docs/evidence/).
class ConsoleEvents {
  static final RegExp serverStarted =
      RegExp(r'^Server started\.$');
  static final RegExp openingLevel = RegExp(r"^Opening level '(.*)'");
  static final RegExp creatingWorld = RegExp(r'CREATING VANILLA WORLD');
  static final RegExp acceptingClients = RegExp(r'^Accepting clients on \[.*\]:(\d+)$');
  static final RegExp stopRequested = RegExp(r'^Server stop requested\.');
  static final RegExp stoppingServer = RegExp(r'^Stopping server\.\.\.');
  static final RegExp playerCount = RegExp(r'^There are (\d+)/(\d+) players online:?(.*)$');
  static final RegExp playerJoined = RegExp(r'^Player(?: ([^ ]+))? (?:joined|connected)');
  static final RegExp versionLine = RegExp(r'^Version: (\S+)$');
  static final RegExp crashSignal = RegExp(r'SEGMENTATION FAULT|Aborted|terminate called');
}

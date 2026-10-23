/// Safe update pipeline for the BDS distribution (Phase 4 semantics).
///
/// A persisted, journaled state machine. Every transition appends to an
/// update record BEFORE the filesystem work happens, so an interrupted
/// update is detected on next launch and rolled back rather than resumed
/// blindly. The two golden guards from the project brief are enforced here:
///
/// * the last known-good server version is never deleted;
/// * the only valid world backup is never deleted.
///
/// Verification strategy (Phase 0 §6): TLS download + per-member ZIP CRC
/// validation + real staging smoke-run — Mojang publishes no checksums.
library;

import 'dart:convert';
import 'dart:io';

import 'downloader.dart';
import 'version_manifest.dart';
import 'zip.dart';

enum UpdatePhase {
  idle,
  checked,
  approved,
  backedUp,
  downloaded,
  verified,
  staged,
  smokePassed,
  preserved,
  activated,
  healthy,
  done,
  rolledBack,
  failed,
}

const List<UpdatePhase> orderedPhases = [
  UpdatePhase.idle,
  UpdatePhase.checked,
  UpdatePhase.approved,
  UpdatePhase.backedUp,
  UpdatePhase.downloaded,
  UpdatePhase.verified,
  UpdatePhase.staged,
  UpdatePhase.smokePassed,
  UpdatePhase.preserved,
  UpdatePhase.activated,
  UpdatePhase.healthy,
  UpdatePhase.done,
];

/// Why an update run failed — surfaced verbatim to the user.
enum UpdateFailureReason {
  probeFailed,
  downloadFailed,
  crcMismatch,
  smokeRunFailed,
  activationFailed,
  healthCheckFailed,
  interrupted,
}

class UpdateRecord {
  final String id;
  final String fromVersion;
  final String toVersion;
  UpdatePhase phase;
  UpdateFailureReason? failureReason;
  String? failureDetail;
  final DateTime startedAt;
  DateTime? finishedAt;
  String? backupPath;
  String? zipPath;
  String? zipSha256;
  int zipBytes = 0;

  UpdateRecord({
    required this.id,
    required this.fromVersion,
    required this.toVersion,
    this.phase = UpdatePhase.idle,
    required this.startedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'from': fromVersion,
        'to': toVersion,
        'phase': phase.name,
        if (failureReason != null) 'failure': failureReason!.name,
        if (failureDetail != null) 'detail': failureDetail,
        'startedAt': startedAt.toIso8601String(),
        if (finishedAt != null) 'finishedAt': finishedAt!.toIso8601String(),
        if (backupPath != null) 'backup': backupPath,
        if (zipPath != null) 'zip': zipPath,
        if (zipSha256 != null) 'sha256': zipSha256,
        'zipBytes': zipBytes,
      };

  static UpdateRecord fromJson(Map<String, dynamic> j) => UpdateRecord(
        id: j['id'] as String,
        fromVersion: j['from'] as String,
        toVersion: j['to'] as String,
        phase: UpdatePhase.values.byName(j['phase'] as String),
        startedAt: DateTime.parse(j['startedAt'] as String),
      )
        ..failureReason = j['failure'] == null
            ? null
            : UpdateFailureReason.values.byName(j['failure'] as String)
        ..failureDetail = j['detail'] as String?
        ..finishedAt =
            j['finishedAt'] == null ? null : DateTime.parse(j['finishedAt'] as String)
        ..backupPath = j['backup'] as String?
        ..zipPath = j['zip'] as String?
        ..zipSha256 = j['sha256'] as String?
        ..zipBytes = (j['zipBytes'] as num?)?.toInt() ?? 0;
}

/// Ledger of update runs, persisted as JSON — the durable progress record.
class UpdateLedger {
  final String path;
  final List<UpdateRecord> records = [];

  UpdateLedger(this.path);

  Future<void> load() async {
    records.clear();
    final f = File(path);
    if (!await f.exists()) return;
    final list = jsonDecode(await f.readAsString());
    if (list is List) {
      for (final j in list) {
        if (j is Map<String, dynamic>) records.add(UpdateRecord.fromJson(j));
      }
    }
  }

  Future<void> save() async {
    await File(path).writeAsString(
        const JsonEncoder.withIndent('  ').convert(records.map((r) => r.toJson()).toList()));
  }

  /// Any run that started but never reached done/failed — i.e. interrupted.
  UpdateRecord? get interrupted =>
      records.where((r) => _isInterrupted(r)).lastOrNull;

  static bool _isInterrupted(UpdateRecord r) =>
      r.phase != UpdatePhase.done &&
      r.phase != UpdatePhase.failed &&
      r.phase != UpdatePhase.rolledBack &&
      r.phase != UpdatePhase.idle;

  List<UpdateRecord> get history =>
      List.unmodifiable(records.where((r) => r.phase == UpdatePhase.done));
}

extension _LastOrNull<T> on Iterable<T> {
  T? get lastOrNull => isEmpty ? null : last;
}

// ---- test seams ----------------------------------------------------------

/// Exposed for tests to assert interruption detection per phase.
extension UpdateLedgerTest on UpdateLedger {
  static bool isInterruptedPhase(UpdatePhase p) =>
      p != UpdatePhase.done &&
      p != UpdatePhase.failed &&
      p != UpdatePhase.rolledBack &&
      p != UpdatePhase.idle;
}

extension UpdatePipelineTest on UpdatePipeline {
  /// Inserts a pre-existing record (simulating an interrupted prior run).
  void seedForTest(UpdateRecord record) => ledger.records.add(record);
}

/// The pipeline itself. The [hooks] indirection exists so unit tests drive
/// the machine with fakes while production plugs real IO (download, extract,
/// smoke-run) in — every hook returns success/failure, and the machine
/// decides transitions + rollback uniformly.
class UpdatePipeline {
  final UpdateLedger ledger;
  final UpdateHooks hooks;

  UpdatePipeline(this.ledger, this.hooks);

  UpdateRecord? _active;

  /// Phase 1: checks what is installed vs what is latest.
  Future<UpdateCheck> check() async {
    await ledger.load();
    final installed = await hooks.installedVersion();
    final latest = await hooks.latestVersion();
    return UpdateCheck(
      installedVersion: installed,
      latestVersion: latest?.version,
      latestIsPreview: latest?.preview ?? false,
      updateAvailable: latest != null && installed != null && latest.version != installed,
    );
  }

  /// Runs the whole remaining pipeline from [phase] to done (or rollback).
  Future<UpdateRecord> run(
    UpdateRecord record, {
    required bool autoApprove,
    void Function(UpdatePhase)? onPhase,
  }) async {
    _active = record;
    try {
      if (record.phase == UpdatePhase.idle) {
        await _transition(record, UpdatePhase.checked, onPhase);
      }
      if (record.phase == UpdatePhase.checked) {
        if (!autoApprove) await hooks.waitForApproval(record);
        await _transition(record, UpdatePhase.approved, onPhase);
      }
      if (record.phase == UpdatePhase.approved) {
        record.backupPath = await hooks.backupWorldsAndConfig(record);
        if (record.backupPath == null) {
          return _fail(record, UpdateFailureReason.interrupted, 'backup failed');
        }
        await _transition(record, UpdatePhase.backedUp, onPhase);
      }
      if (record.phase == UpdatePhase.backedUp) {
        final dl = await hooks.downloadDistribution(record);
        if (dl == null) {
          return _fail(record, UpdateFailureReason.downloadFailed, 'download failed');
        }
        record.zipPath = dl.path;
        record.zipBytes = dl.bytes;
        record.zipSha256 = dl.sha256;
        await _transition(record, UpdatePhase.downloaded, onPhase);
      }
      if (record.phase == UpdatePhase.downloaded) {
        final crcOk = await hooks.verifyArchive(record);
        if (!crcOk) {
          return _fail(record, UpdateFailureReason.crcMismatch, 'zip CRC validation failed');
        }
        await _transition(record, UpdatePhase.verified, onPhase);
      }
      if (record.phase == UpdatePhase.verified) {
        final staged = await hooks.stage(record);
        if (!staged) {
          return _fail(record, UpdateFailureReason.smokeRunFailed, 'staging failed');
        }
        await _transition(record, UpdatePhase.staged, onPhase);
      }
      if (record.phase == UpdatePhase.staged) {
        final smoke = await hooks.smokeRun(record);
        if (!smoke) {
          return _fail(record, UpdateFailureReason.smokeRunFailed,
              'staged server did not start cleanly');
        }
        await _transition(record, UpdatePhase.smokePassed, onPhase);
      }
      if (record.phase == UpdatePhase.smokePassed) {
        final preserved = await hooks.preserveUserData(record);
        if (!preserved) {
          return _fail(record, UpdateFailureReason.activationFailed, 'preserve failed');
        }
        await _transition(record, UpdatePhase.preserved, onPhase);
      }
      if (record.phase == UpdatePhase.preserved) {
        final activated = await hooks.activate(record);
        if (!activated) {
          return _rollback(record, onPhase, 'activation failed');
        }
        await _transition(record, UpdatePhase.activated, onPhase);
      }
      if (record.phase == UpdatePhase.activated) {
        final healthy = await hooks.healthCheck(record);
        if (!healthy) {
          return _rollback(record, onPhase, 'post-activation health check failed');
        }
        await _transition(record, UpdatePhase.healthy, onPhase);
      }
      if (record.phase == UpdatePhase.healthy) {
        await hooks.cleanup(record);
        await _transition(record, UpdatePhase.done, onPhase);
        record.finishedAt = DateTime.now();
      }
      await ledger.save();
      return record;
    } finally {
      _active = null;
    }
  }

  /// Resumes (rolls back) an interrupted run found in the ledger.
  Future<UpdateRecord?> recoverInterrupted({void Function(UpdatePhase)? onPhase}) async {
    await ledger.load();
    final r = ledger.interrupted;
    if (r == null) return null;
    return _rollback(r, onPhase, 'interrupted update detected at ${r.phase.name}');
  }

  Future<UpdateRecord> _fail(
      UpdateRecord r, UpdateFailureReason reason, String detail) async {
    r.failureReason = reason;
    r.failureDetail = detail;
    r.phase = UpdatePhase.failed;
    r.finishedAt = DateTime.now();
    await ledger.save();
    return r;
  }

  Future<UpdateRecord> _rollback(
      UpdateRecord r, void Function(UpdatePhase)? onPhase, String reason) async {
    final ok = await hooks.rollback(r);
    r.phase = ok ? UpdatePhase.rolledBack : UpdatePhase.failed;
    r.failureReason ??= UpdateFailureReason.activationFailed;
    r.failureDetail ??= reason;
    r.finishedAt = DateTime.now();
    await ledger.save();
    onPhase?.call(r.phase);
    return r;
  }

  Future<void> _transition(
      UpdateRecord r, UpdatePhase to, void Function(UpdatePhase)? onPhase) async {
    r.phase = to;
    await ledger.save(); // journal BEFORE the work of the next phase
    onPhase?.call(to);
  }
}

class UpdateCheck {
  final String? installedVersion;
  final String? latestVersion;
  final bool latestIsPreview;
  final bool updateAvailable;
  const UpdateCheck({
    this.installedVersion,
    this.latestVersion,
    this.latestIsPreview = false,
    this.updateAvailable = false,
  });
}

class DownloadedDistribution {
  final String path;
  final int bytes;
  final String sha256;
  const DownloadedDistribution(this.path, this.bytes, this.sha256);
}

/// Production hooks use downloader/zip/BdsProcess; tests install fakes.
abstract class UpdateHooks {
  Future<String?> installedVersion();
  Future<BdsVersion?> latestVersion();
  Future<void> waitForApproval(UpdateRecord record);
  Future<String?> backupWorldsAndConfig(UpdateRecord record);
  Future<DownloadedDistribution?> downloadDistribution(UpdateRecord record);
  Future<bool> verifyArchive(UpdateRecord record);
  Future<bool> stage(UpdateRecord record);
  Future<bool> smokeRun(UpdateRecord record);
  Future<bool> preserveUserData(UpdateRecord record);
  Future<bool> activate(UpdateRecord record);
  Future<bool> healthCheck(UpdateRecord record);
  Future<void> cleanup(UpdateRecord record);
  Future<bool> rollback(UpdateRecord record);
}

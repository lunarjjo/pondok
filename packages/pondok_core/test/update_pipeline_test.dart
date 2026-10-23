import 'dart:io';

import 'package:pondok_core/pondok_core.dart';
import 'package:test/test.dart';

/// Drives the update state machine with scripted hooks: success path,
/// failure paths at each critical phase, journal persistence, and the
/// interrupted-run recovery (rollback) semantics.
class FakeHooks implements UpdateHooks {
  String installed = '1.26.50.01';
  BdsVersion? latest = const BdsVersion('1.26.52.3');

  bool backupResult = true;
  bool downloadResult = true;
  bool verifyResult = true;
  bool stageResult = true;
  bool smokeResult = true;
  bool preserveResult = true;
  bool activateResult = true;
  bool healthResult = true;
  bool rollbackResult = true;

  final List<String> calls = <String>[];

  @override
  Future<String?> installedVersion() async => installed;

  @override
  Future<BdsVersion?> latestVersion() async => latest;

  @override
  Future<void> waitForApproval(UpdateRecord record) async {
    calls.add('approve');
  }

  @override
  Future<String?> backupWorldsAndConfig(UpdateRecord record) async {
    calls.add('backup');
    return backupResult ? '/backups/b.zip' : null;
  }

  @override
  Future<DownloadedDistribution?> downloadDistribution(UpdateRecord record) async {
    calls.add('download');
    return downloadResult
        ? const DownloadedDistribution('/staging/bds.zip', 94927522, 'f6348d84')
        : null;
  }

  @override
  Future<bool> verifyArchive(UpdateRecord record) async {
    calls.add('verify');
    return verifyResult;
  }

  @override
  Future<bool> stage(UpdateRecord record) async {
    calls.add('stage');
    return stageResult;
  }

  @override
  Future<bool> smokeRun(UpdateRecord record) async {
    calls.add('smoke');
    return smokeResult;
  }

  @override
  Future<bool> preserveUserData(UpdateRecord record) async {
    calls.add('preserve');
    return preserveResult;
  }

  @override
  Future<bool> activate(UpdateRecord record) async {
    calls.add('activate');
    return activateResult;
  }

  @override
  Future<bool> healthCheck(UpdateRecord record) async {
    calls.add('health');
    return healthResult;
  }

  @override
  Future<void> cleanup(UpdateRecord record) async {
    calls.add('cleanup');
  }

  @override
  Future<bool> rollback(UpdateRecord record) async {
    calls.add('rollback');
    return rollbackResult;
  }
}

UpdateRecord newRecord({String to = '1.26.52.3'}) => UpdateRecord(
      id: 'test-1',
      fromVersion: '1.26.50.01',
      toVersion: to,
      startedAt: DateTime(2026, 10, 23, 12, 0, 0),
    );

var _tmpN = 0;
String _tmpLedgerPath() {
  _tmpN++;
  final d = Directory.systemTemp.createTempSync('pondok_ledger_${_tmpN}');
  return '${d.path}/updates.json';
}

void main() {
  group('UpdatePipeline — happy path', () {
    test('walks all phases to done in order', () async {
      final hooks = FakeHooks();
      final ledger = UpdateLedger(_tmpLedgerPath());
      final pipe = UpdatePipeline(ledger, hooks);
      final phases = <UpdatePhase>[];
      final r = await pipe.run(newRecord(), autoApprove: true, onPhase: phases.add);
      expect(r.phase, UpdatePhase.done);
      expect(r.failureReason, isNull);
      expect(phases, orderedPhases.skip(1).toList());
      // autoApprove skips the interactive approval hook by design.
      expect(hooks.calls, containsAllInOrder([
        'backup', 'download', 'verify', 'stage', 'smoke',
        'preserve', 'activate', 'health', 'cleanup',
      ]));
      expect(r.zipSha256, 'f6348d84');
      expect(r.zipBytes, 94927522);
    });

    test('check() compares installed vs latest', () async {
      final pipe = UpdatePipeline(UpdateLedger(_tmpLedgerPath()), FakeHooks());
      final c = await pipe.check();
      expect(c.installedVersion, '1.26.50.01');
      expect(c.latestVersion, '1.26.52.3');
      expect(c.updateAvailable, isTrue);
    });

    test('check() reports no update when identical', () async {
      final hooks = FakeHooks()..installed = '1.26.52.3';
      final pipe = UpdatePipeline(UpdateLedger(_tmpLedgerPath()), hooks);
      expect((await pipe.check()).updateAvailable, isFalse);
    });
  });

  group('UpdatePipeline — failure paths', () {
    test('download failure → failed, no activation attempted', () async {
      final hooks = FakeHooks()..downloadResult = false;
      final pipe = UpdatePipeline(UpdateLedger(_tmpLedgerPath()), hooks);
      final r = await pipe.run(newRecord(), autoApprove: true);
      expect(r.phase, UpdatePhase.failed);
      expect(r.failureReason, UpdateFailureReason.downloadFailed);
      expect(hooks.calls, isNot(contains('stage')));
    });

    test('CRC mismatch → failed with crcMismatch', () async {
      final hooks = FakeHooks()..verifyResult = false;
      final pipe = UpdatePipeline(UpdateLedger(_tmpLedgerPath()), hooks);
      final r = await pipe.run(newRecord(), autoApprove: true);
      expect(r.failureReason, UpdateFailureReason.crcMismatch);
    });

    test('smoke run failure → failed, world untouched', () async {
      final hooks = FakeHooks()..smokeResult = false;
      final pipe = UpdatePipeline(UpdateLedger(_tmpLedgerPath()), hooks);
      final r = await pipe.run(newRecord(), autoApprove: true);
      expect(r.phase, UpdatePhase.failed);
      expect(r.failureReason, UpdateFailureReason.smokeRunFailed);
      expect(hooks.calls, isNot(contains('preserve')));
    });

    test('activation failure → rolled back', () async {
      final hooks = FakeHooks()..activateResult = false;
      final pipe = UpdatePipeline(UpdateLedger(_tmpLedgerPath()), hooks);
      final r = await pipe.run(newRecord(), autoApprove: true);
      expect(r.phase, UpdatePhase.rolledBack);
      expect(hooks.calls, contains('rollback'));
    });

    test('health check failure → rolled back (the Phase 4 requirement)', () async {
      final hooks = FakeHooks()..healthResult = false;
      final pipe = UpdatePipeline(UpdateLedger(_tmpLedgerPath()), hooks);
      final r = await pipe.run(newRecord(), autoApprove: true);
      expect(r.phase, UpdatePhase.rolledBack);
      expect(hooks.calls, contains('rollback'));
      expect(r.failureDetail, contains('health'));
    });

    test('backup failure → failed before any download', () async {
      final hooks = FakeHooks()..backupResult = false;
      final pipe = UpdatePipeline(UpdateLedger(_tmpLedgerPath()), hooks);
      final r = await pipe.run(newRecord(), autoApprove: true);
      expect(r.phase, UpdatePhase.failed);
      expect(hooks.calls, isNot(contains('download')));
    });
  });

  group('UpdatePipeline — journal and recovery', () {
    test('record JSON round-trips', () {
      final r = newRecord()
        ..phase = UpdatePhase.smokePassed
        ..failureReason = UpdateFailureReason.interrupted
        ..zipBytes = 123;
      final back = UpdateRecord.fromJson(r.toJson());
      expect(back.phase, UpdatePhase.smokePassed);
      expect(back.failureReason, UpdateFailureReason.interrupted);
      expect(back.fromVersion, '1.26.50.01');
    });

    test('interrupted runs are detected from phase alone', () {
      for (final p in UpdatePhase.values) {
        final interrupted = UpdateLedgerTest.isInterruptedPhase(p);
        final expected = p != UpdatePhase.done &&
            p != UpdatePhase.failed &&
            p != UpdatePhase.rolledBack &&
            p != UpdatePhase.idle;
        expect(interrupted, expected, reason: p.name);
      }
    });

    test('recoverInterrupted rolls back an interrupted record', () async {
      final hooks = FakeHooks();
      final ledger = UpdateLedger(_tmpLedgerPath());
      final pipe = UpdatePipeline(ledger, hooks);
      final r = newRecord()..phase = UpdatePhase.preserved;
      ledger.records.add(r);
      await ledger.save(); // persist so recoverInterrupted() can load it
      final recovered = await pipe.recoverInterrupted();
      expect(recovered, isNotNull);
      expect(recovered!.phase, UpdatePhase.rolledBack);
      expect(hooks.calls, contains('rollback'));
    });

    test('recoverInterrupted is a no-op with no interrupted records', () async {
      final ledger = UpdateLedger(_tmpLedgerPath());
      final pipe = UpdatePipeline(ledger, FakeHooks());
      ledger.records.add(newRecord()..phase = UpdatePhase.done);
      await ledger.save();
      expect(await pipe.recoverInterrupted(), isNull);
    });
  });
}

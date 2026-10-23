import 'dart:async';
import 'dart:io';

import 'package:pondok_core/pondok_core.dart';
import 'package:test/test.dart';

/// Unit tests for the D-17 observability fixes in BdsProcess.
///
/// These drive REAL /bin/sh children (the suite runs on Linux hosts —
/// sandbox and CI alike), reproducing exactly the death pattern reported
/// on the phone: "process spawns, dies instantly, message on stderr".
void main() {
  // /bin/sh exists on every Linux the suite runs on (CI ubuntu, sandbox).
  final sh = Platform.isLinux ? '/bin/sh' : null;
  final canRun = sh != null;

  test('describeExitCode decodes signals vs plain exits', () {
    expect(describeExitCode(0), contains('normal'));
    expect(describeExitCode(7), 'exit 7');
    expect(describeExitCode(-4), contains('SIGILL'));
    expect(describeExitCode(-4), contains('instruksi ilegal'));
    expect(describeExitCode(-11), contains('SIGSEGV'));
    expect(describeExitCode(-31), contains('SIGSYS'));
    expect(describeExitCode(-31), contains('seccomp'));
    expect(describeExitCode(-42), contains('sinyal 42'));
  });

  test('spawn failure carries the reason (no silent state)', () async {
    final proc = BdsProcess(BdsProcessConfig(
      binary: '/nonexistent/pondok-probe-binary',
      workingDir: Directory.systemTemp.path,
      startupTimeout: const Duration(seconds: 5),
    ));
    final states = <BdsState>[];
    final sub = proc.stateChanges.listen(states.add);
    addTearDown(sub.cancel);

    await expectLater(
      proc.start(),
      throwsA(isA<BdsStartupException>().having(
        (e) => e.reason, 'reason', contains('spawn failed'),
      )),
    );
    // The state machine settles on a failure state, never on `crashed`
    // with an empty story.
    expect(proc.state, BdsState.startupFailed);
    expect(proc.lastExit, isNotNull);
    expect(proc.lastExit!.detail, contains('spawn failed'));
    await proc.dispose();
  }, skip: !canRun ? 'requires Linux /bin/sh' : null);

  test(
      'D-17 regression: stderr emitted just before death IS captured '
      '(exit race)', () async {
    final tmp = await Directory.systemTemp.createTemp('pondok_d17_');
    addTearDown(() => tmp.delete(recursive: true));

    final proc = BdsProcess(BdsProcessConfig(
      // The exact on-device death shape: writes a dying message to stderr,
      // then exits non-zero immediately.
      binary: sh!,
      args: const ['-c', 'echo "proot: fatal: cannot continue" >&2; exit 7'],
      workingDir: tmp.path,
      startupTimeout: const Duration(seconds: 5),
    ));

    final lines = <String>[];
    final sub = proc.lines.listen((l) => lines.add(l.raw));
    addTearDown(sub.cancel);

    await expectLater(proc.start(), throwsA(isA<BdsStartupException>()));
    await Future<void>.delayed(Duration.zero); // let late events settle

    expect(proc.state, BdsState.crashed);
    expect(proc.lastExit!.code, 7);
    expect(proc.lastExit!.detail, contains('exit 7'));
    // THE assertion this whole file exists for: the dying message must
    // survive the exit race — in the field this was the difference between
    // "tidak ada log error atau apapun yang tampil" and an actionable report.
    expect(lines, contains(contains('proot: fatal: cannot continue')));
    expect(proc.lastExit!.outputTail, contains('proot: fatal: cannot continue'));
    await proc.dispose();
  }, skip: !canRun ? 'requires Linux /bin/sh' : null);

  test('clean lifecycle: Server started. → running → stop', () async {
    final tmp = await Directory.systemTemp.createTemp('pondok_d17_ok_');
    addTearDown(() => tmp.delete(recursive: true));

    final proc = BdsProcess(BdsProcessConfig(
      binary: sh!,
      args: const [
        '-c',
        'echo "Server started."; while true; do sleep 1; done',
      ],
      workingDir: tmp.path,
      startupTimeout: const Duration(seconds: 10),
      gracefulStopTimeout: const Duration(seconds: 1),
      sigtermTimeout: const Duration(seconds: 3),
    ));

    await proc.start();
    expect(proc.state, BdsState.running);

    final exit = await proc.stop();
    // The shell ignores the `stop` line, so the ladder escalates to
    // SIGTERM: exit is the signal's negative encoding.
    expect(exit.code, anyOf(0, -15));
    await proc.dispose();
  }, skip: !canRun ? 'requires Linux /bin/sh' : null);
}


import 'dart:io';

import 'package:pondok_core/pondok_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('pondok_diag_');
  });
  tearDown(() => tmp.delete(recursive: true));

  ProbeOutcome ok([String out = 'probe-ok']) =>
      ProbeOutcome(exitCode: 0, output: out);

  ProbeOutcome fail(int code, [String out = '']) =>
      ProbeOutcome(exitCode: code, output: out);

  StackDiagnostics diagWith(
    ProbeOutcome Function(String binary, List<String> args) behavior, {
    DeviceFacts device = const DeviceFacts(),
  }) {
    return StackDiagnostics(
      tmp.path,
      runner: (binary, args,
              {workingDirectory, environment = const {}, timeout}) async =>
          behavior(binary, args),
      device: device,
    );
  }

  test('all layers healthy → all pass, mode stays PROOT', () async {
    final d = diagWith((b, a) => ok('box64 v0.4.4'));
    final results = await d.run();
    expect(results, hasLength(5));
    expect(results.every((r) => r.isPass), isTrue,
        reason: results.join('\n'));
    expect(d.recommendLaunchMode(results), LaunchMode.proot);
    expect(d.summarize(results), contains('SEMUA lapisan sehat'));
  });

  test('proot chain broken but direct works → DIRECT recommended', () async {
    final d = diagWith((b, a) {
      if (b == '/system/bin/sh') return ok('probe-ok');
      if (b.endsWith('proot')) {
        // proot-rootfs: args contain /bin/true → ptrace denied on this
        // (fictional) device; exec-proot (--version only) still works;
        // proot-box64 (drives /bin/sh) dies with it.
        if (a.contains('/bin/true')) {
          return fail(
              1, 'proot: ptrace(PTRACE_TRACEME): Operation not permitted');
        }
        if (a.contains('/bin/sh')) return fail(1, 'proot: child exited');
        return ok('proot 5.5.0');
      }
      return ok('box64 v0.4.4'); // loader binary → direct-box64
    });
    final results = await d.run();
    final byName = {for (final r in results) r.name: r};
    expect(byName['exec-proot']!.isPass, isTrue);
    expect(byName['proot-rootfs']!.status, ProbeStatus.fail);
    expect(byName['proot-rootfs']!.note, contains('ptrace'));
    expect(byName['proot-box64']!.status, ProbeStatus.fail);
    expect(byName['direct-box64']!.isPass, isTrue);
    expect(d.recommendLaunchMode(results), LaunchMode.direct);
    expect(d.summarize(results), contains('proot → rootfs'));
    expect(d.summarize(results), contains('Mode cadangan DIRECT'));
  });

  test('exec blocked (errno 13) → actionable SELinux note', () async {
    final d = diagWith((b, a) {
      if (b == '/system/bin/sh') return ok('probe-ok');
      // Every app-storage binary is refused by the kernel.
      return const ProbeOutcome(
        spawnError: 'execvp failed: Permission denied',
        spawnErrno: 13,
      );
    });
    final results = await d.run();
    final byName = {for (final r in results) r.name: r};
    expect(byName['sh']!.isPass, isTrue);
    expect(byName['exec-proot']!.status, ProbeStatus.fail);
    expect(byName['exec-proot']!.note, contains('Izin eksekusi DITOLAK'));
    expect(byName['proot-rootfs']!.status, ProbeStatus.skipped);
    expect(byName['proot-box64']!.status, ProbeStatus.skipped);
  });

  test('baseline sh dead → everything else skipped', () async {
    final d = diagWith((b, a) => const ProbeOutcome(
          spawnError: 'execvp failed: No such file or directory',
          spawnErrno: 2,
        ));
    final results = await d.run();
    expect(results.first.status, ProbeStatus.fail);
    expect(results.skip(1).every((r) => r.status == ProbeStatus.skipped),
        isTrue);
    expect(d.summarize(results), contains('Proses dasar sistem'));
  });

  test('timeout is surfaced as its own status', () async {
    final d = StackDiagnostics(
      tmp.path,
      runner: (b, a,
          {workingDirectory, environment = const {}, timeout}) async {
        if (b.endsWith('proot')) {
          return const ProbeOutcome(timedOut: true, output: 'partial');
        }
        return ok();
      },
    );
    final results = await d.run();
    final byName = {for (final r in results) r.name: r};
    expect(byName['exec-proot']!.status, ProbeStatus.timeout);
    expect(byName['exec-proot']!.note, contains('tidak merespons'));
    expect(byName['proot-rootfs']!.status, ProbeStatus.skipped);
  });

  test('signal death gets decoded in the probe note', () async {
    final d = diagWith((b, a) {
      if (b.endsWith('proot') && a.contains('/bin/true')) {
        return const ProbeOutcome(exitCode: -4);
      }
      return ok();
    });
    final results = await d.run();
    final r = {for (final e in results) e.name: e}[
        'proot-rootfs']!;
    expect(r.note, contains('SIGILL'));
    expect(r.note, contains('instruksi ilegal'));
  });

  test('resolveRootfsLoader picks the first candidate that exists', () async {
    expect(await resolveRootfsLoader(tmp.path), isNull);
    final rootfs =
        Directory('${tmp.path}/runtime/rootfs/lib/aarch64-linux-gnu')
          ..createSync(recursive: true);
    expect(await resolveRootfsLoader(tmp.path), isNull);
    File('${rootfs.path}/ld-linux-aarch64.so.1').writeAsStringSync('ELF');
    expect(await resolveRootfsLoader(tmp.path),
        endsWith('/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1'));
  });

  test('directRuntimeProfile shapes the exact fallback command', () {
    final cfg = directRuntimeProfile(tmp.path);
    expect(cfg.binary,
        '${tmp.path}/runtime/rootfs/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1');
    expect(cfg.args.first, '--library-path');
    expect(cfg.args.join(' '), contains('usr/lib/aarch64-linux-gnu'));
    expect(cfg.args.join(' '), contains('box64-x86_64-linux-gnu'));
    expect(cfg.args.join(' '), endsWith('/opt/box64/box64 ./bedrock_server'));
    expect(cfg.workingDir, '${tmp.path}/server');
    expect(cfg.environment['BOX64_LD_LIBRARY_PATH'], contains('box64-x86_64'));
    // No ptrace anywhere — that is the whole point of the fallback.
    expect(cfg.args.join(' '), isNot(contains('-R')));
  });
}

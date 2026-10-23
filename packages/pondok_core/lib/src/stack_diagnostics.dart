/// On-device probe ladder (D-17): when the bundled stack dies on a physical
/// phone, the failure layer is INVISIBLE without instrumentation — the
/// sandbox has no equivalent hardware, and the dying process's stderr is
/// racing the exit notification.
///
/// This ladder reproduces the launch chain one layer at a time, each step
/// cheap, bounded, and self-explanatory:
///
///     1. sh             — can the app spawn ANY process at all?
///     2. exec-proot     — can the kernel execute the extracted static
///                         proot from app-private storage? (SELinux gate)
///     3. proot-rootfs   — does ptrace + the rootfs's dynamic loader chain
///                         work? (proot -R rootfs /bin/true)
///     4. proot-box64    — does the x86 translator run under proot?
///     5. direct-box64   — does box64 run WITHOUT proot, launched through
///                         the rootfs's own ld.so? (the fallback launch mode)
///
/// Every result carries exit code, signal decoding, and merged output —
/// the exact evidence a bug report needs. Results are also appended to the
/// persistent runtime log (runtime_log.dart).
library;

import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io';

import 'bds_process.dart';
import 'bundled_runtime.dart';

/// Outcome of one probe execution.
enum ProbeStatus { pass, fail, skipped, timeout }

class ProbeResult {
  final String name;
  final String label;
  final ProbeStatus status;

  /// Exit code — negative when the probe was killed by a signal.
  final int? exitCode;

  /// Merged stdout+stderr (trimmed, bounded).
  final String output;

  /// Interpretation / skip reason — always populated in Indonesian so it can
  /// be shown to the user verbatim.
  final String note;

  final Duration elapsed;

  const ProbeResult({
    required this.name,
    required this.label,
    required this.status,
    this.exitCode,
    this.output = '',
    this.note = '',
    this.elapsed = const Duration(),
  });

  bool get isPass => status == ProbeStatus.pass;

  String get statusLabel => switch (status) {
        ProbeStatus.pass => 'OK',
        ProbeStatus.fail => 'GAGAL',
        ProbeStatus.skipped => 'LEWATI',
        ProbeStatus.timeout => 'TIMEOUT',
      };

  @override
  String toString() =>
      '[$statusLabel] $name${exitCode != null ? ' ($exitCode)' : ''}'
      '${output.isEmpty ? '' : ' :: ${output.split('\n').first}'}';
}

/// Raw outcome of executing one probe command (before interpretation).
class ProbeOutcome {
  final int? exitCode;
  final String output;
  final bool timedOut;

  /// Non-null when the process could not even be spawned (errno captured).
  final String? spawnError;
  final int? spawnErrno;

  const ProbeOutcome({
    this.exitCode,
    this.output = '',
    this.timedOut = false,
    this.spawnError,
    this.spawnErrno,
  });

  bool get spawnFailed => spawnError != null;
}

/// Injectable command runner — keeps the ladder unit-testable.
typedef ProbeRunner = Future<ProbeOutcome> Function(
  String binary,
  List<String> args, {
  String? workingDirectory,
  Map<String, String> environment,
  Duration? timeout,
});

/// Facts about the host device (from the platform channel, best-effort).
class DeviceFacts {
  final Map<String, String> raw;
  const DeviceFacts([this.raw = const {}]);

  String describe() {
    if (raw.isEmpty) return 'perangkat tidak diketahui';
    final parts = [
      if (raw['model'] != null) raw['model']!,
      if (raw['android'] != null) 'Android ${raw['android']}',
      if (raw['abis'] != null) 'ABI ${raw['abis']}',
      if (raw['pageSize'] != null) 'halaman ${raw['pageSize']}B',
      if (raw['selinuxEnforcing'] == 'true') 'SELinux aktif',
    ];
    return parts.isEmpty ? raw.toString() : parts.join(' · ');
  }
}

/// Which launch profile the stack should use.
enum LaunchMode { proot, direct }

/// The ladder itself.
class StackDiagnostics {
  final String baseDir;
  final ProbeRunner runner;

  /// Device facts only decorate the summary; the ladder works without them.
  final DeviceFacts device;

  StackDiagnostics(this.baseDir, {ProbeRunner? runner, this.device = const DeviceFacts()})
      : runner = runner ?? defaultProbeRunner;

  /// Runs the full ladder. [onProbe] fires after each step (progress UI).
  Future<List<ProbeResult>> run({void Function(ProbeResult)? onProbe}) async {
    final p = BundledRuntimePaths(baseDir);
    final results = <ProbeResult>[];

    // -- 1. baseline: can we spawn a process at all? ----------------------
    // Also harvest uname + page size here — free evidence for bug reports.
    final sh = await _run(
      name: 'sh',
      label: 'Proses dasar sistem',
      binary: '/system/bin/sh',
      args: const [
        '-c',
        'echo probe-ok; uname -a; getconf PAGESIZE 2>/dev/null '
            '|| echo pagesize-unknown',
      ],
      timeout: const Duration(seconds: 10),
      interpret: (o) => switch (o) {
            _ when o.spawnFailed => _note(
                'Tidak bisa menjalankan proses sama sekali: ${o.spawnError}'),
            _ when o.timedOut => 'Proses dasar tidak kunjung selesai.',
            _ when o.exitCode == 0 && o.output.contains('probe-ok') => '',
            _ => 'Keluar dengan ${describeExitCode(o.exitCode ?? -1)}.',
          },
    );
    results.add(sh);
    onProbe?.call(sh);

    // Everything downstream needs a working process spawner.
    final canSpawn = sh.isPass;

    // -- 2. exec the extracted static proot from app storage ---------------
    final execProot = await _run(
      name: 'exec-proot',
      label: 'Eksekusi proot dari penyimpanan aplikasi',
      binary: p.proot,
      args: const ['--version'],
      timeout: const Duration(seconds: 20),
      skip: !canSpawn,
      skipReason: 'proses dasar gagal',
      interpret: (o) => switch (o) {
            _ when o.spawnErrno == 13 =>
              'Izin eksekusi DITOLAK — Android/OEM memblokir eksekusi berkas '
              'dari penyimpanan aplikasi (SELinux). Laporkan merek/model HP-nya.',
            _ when o.spawnErrno == 8 => 'Format berkas ditolak (ENOEXEC) — pohon runtime rusak; pasang ulang.',
            _ when o.spawnErrno == 2 => 'proot tidak ditemukan — pohon runtime rusak; pasang ulang.',
            _ when o.spawnFailed => 'Gagal spawn: ${o.spawnError}',
            _ when o.timedOut => 'proot --version tidak merespons (20 dtk).',
            _ when o.exitCode != 0 =>
              'proot mati segera: ${describeExitCode(o.exitCode!)}'
              '${o.output.isEmpty ? '' : ' — ${o.output.split('\n').last}'}',
            _ => '',
          },
    );
    results.add(execProot);
    onProbe?.call(execProot);

    // -- 3. proot + rootfs + ptrace + dynamic loader chain -----------------
    final prootRootfs = await _run(
      name: 'proot-rootfs',
      label: 'proot → rootfs (ptrace + loader dinamis)',
      binary: p.proot,
      args: ['-R', p.rootfs, '/bin/true'],
      timeout: const Duration(seconds: 45),
      skip: !canSpawn || execProot.status != ProbeStatus.pass,
      skipReason: 'eksekusi proot gagal',
      interpret: (o) => switch (o) {
            _ when o.timedOut => 'Terjebak lebih dari 45 dtk — kemungkinan '
                'ptrace dibatasi kernel/OEM HP ini.',
            _ when o.spawnErrno != null => 'Gagal spawn: ${o.spawnError}',
            _ when o.exitCode != 0 =>
              'proot gagal menjalankan rootfs: ${describeExitCode(o.exitCode!)}'
              '${o.output.isEmpty ? '' : ' — ${o.output.split('\n').where((l) => l.trim().isNotEmpty).lastOrNull ?? ''}'}',
            _ => '',
          },
    );
    results.add(prootRootfs);
    onProbe?.call(prootRootfs);

    // -- 4. box64 under proot -----------------------------------------------
    final prootBox64 = await _run(
      name: 'proot-box64',
      label: 'proot → box64 (penerjemah x86-64)',
      binary: p.proot,
      args: [
        '-R', p.rootfs,
        '/bin/sh', '-c', 'exec /opt/box64/box64 --version',
      ],
      timeout: const Duration(seconds: 60),
      skip: !canSpawn || execProot.status != ProbeStatus.pass,
      skipReason: 'eksekusi proot gagal',
      interpret: (o) => switch (o) {
            _ when o.timedOut => 'box64 tidak merespons dalam 60 dtk.',
            _ when o.spawnErrno != null => 'Gagal spawn: ${o.spawnError}',
            _ when o.exitCode != 0 =>
              'box64 mati: ${describeExitCode(o.exitCode!)}'
              '${o.output.isEmpty ? '' : ' — ${o.output.split('\n').where((l) => l.trim().isNotEmpty).lastOrNull ?? ''}'}',
            _ => '',
          },
    );
    results.add(prootBox64);
    onProbe?.call(prootBox64);

    // -- 5. direct box64 through the rootfs loader (no proot) ---------------
    final loader = await resolveRootfsLoader(baseDir);
    final direct = await _run(
      name: 'direct-box64',
      label: 'box64 langsung tanpa proot (mode cadangan)',
      binary: loader ?? '${p.rootfs}/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1',
      args: [
        '--library-path',
        _directLibraryPath(p),
        p.box64,
        '--version',
      ],
      timeout: const Duration(seconds: 45),
      skip: !canSpawn,
      skipReason: 'proses dasar gagal',
      interpret: (o) => switch (o) {
            _ when o.spawnErrno == 2 =>
              'Loader rootfs tidak ditemukan — pohon runtime rusak; pasang ulang.',
            _ when o.spawnErrno != null => 'Gagal spawn: ${o.spawnError}',
            _ when o.timedOut => 'box64 langsung tidak merespons (45 dtk).',
            _ when o.exitCode != 0 =>
              'box64 langsung mati: ${describeExitCode(o.exitCode!)}'
              '${o.output.isEmpty ? '' : ' — ${o.output.split('\n').where((l) => l.trim().isNotEmpty).lastOrNull ?? ''}'}',
            _ => '',
          },
    );
    results.add(direct);
    onProbe?.call(direct);

    return results;
  }

  String _directLibraryPath(BundledRuntimePaths p) => [
        '${p.rootfs}/usr/lib/aarch64-linux-gnu',
        '${p.rootfs}/lib/aarch64-linux-gnu',
        '${p.rootfs}/usr/lib/box64-x86_64-linux-gnu',
        p.server,
      ].join(':');

  // -------------------------------------------------------------- internals

  Future<ProbeResult> _run({
    required String name,
    required String label,
    required String binary,
    required List<String> args,
    required Duration timeout,
    required String Function(ProbeOutcome) interpret,
    bool skip = false,
    String skipReason = '',
  }) async {
    if (skip) {
      return ProbeResult(
        name: name,
        label: label,
        status: ProbeStatus.skipped,
        note: 'Dilewati: $skipReason.',
      );
    }
    final sw = Stopwatch()..start();
    try {
      final o = await runner(binary, args, timeout: timeout);
      sw.stop();
      final ok = !o.spawnFailed &&
          !o.timedOut &&
          o.exitCode == 0 &&
          o.spawnError == null;
      return ProbeResult(
        name: name,
        label: label,
        status: o.timedOut
            ? ProbeStatus.timeout
            : ok
                ? ProbeStatus.pass
                : ProbeStatus.fail,
        exitCode: o.exitCode,
        output: _bound(o.output),
        note: interpret(o),
        elapsed: sw.elapsed,
      );
    } catch (e) {
      sw.stop();
      return ProbeResult(
        name: name,
        label: label,
        status: ProbeStatus.fail,
        note: 'Exception: $e',
        elapsed: sw.elapsed,
      );
    }
  }

  static String _bound(String s) {
    final t = s.trim();
    return t.length > 1500 ? '${t.substring(t.length - 1500)}\n…(dipangkas)' : t;
  }

  // ------------------------------------------------------------- summary

  /// Plain-Indonesian verdict: which layer broke, what to do next.
  String summarize(List<ProbeResult> results) {
    final lines = <String>[
      'Perangkat: ${device.describe()}',
    ];
    final firstFail = results
        .where((r) => r.status == ProbeStatus.fail || r.status == ProbeStatus.timeout)
        .toList();
    if (firstFail.isEmpty) {
      lines.add('SEMUA lapisan sehat — stack seharusnya bisa menyala. '
          'Jika server tetap gagal, kirim log ini.');
    } else {
      final f = firstFail.first;
      lines.add('Lapisan pertama yang gagal: ${f.label}.');
      if (f.note.isNotEmpty) lines.add(f.note);
    }
    final mode = recommendLaunchMode(results);
    final prootOk = results.any((r) => r.name == 'proot-box64' && r.isPass);
    final directOk = results.any((r) => r.name == 'direct-box64' && r.isPass);
    lines.add(switch (mode) {
      LaunchMode.direct when directOk =>
        'Mode cadangan DIRECT tersedia dan sehat — dipakai otomatis.',
      LaunchMode.proot when prootOk => 'Mode PROOT sehat — dipakai.',
      _ =>
        'Tidak ada mode launch yang sehat di perangkat ini — salin laporannya '
        'dan kirim ke pengembang.',
    });
    return lines.join('\n');
  }

  /// Which profile the server should launch with, given probe evidence.
  LaunchMode recommendLaunchMode(List<ProbeResult> results) {
    final byName = {for (final r in results) r.name: r};
    final directOk = byName['direct-box64']?.isPass ?? false;
    final prootOk = byName['proot-box64']?.isPass ?? false;
    // Prefer the CI-proven proot stack; fall back to direct only when the
    // proot chain is provably broken AND direct works.
    return prootOk || !directOk ? LaunchMode.proot : LaunchMode.direct;
  }
}

String _note(String s) => s;

/// Default runner: real process, bounded by a kill on timeout.
Future<ProbeOutcome> defaultProbeRunner(
  String binary,
  List<String> args, {
  String? workingDirectory,
  Map<String, String> environment = const {},
  Duration? timeout,
}) async {
  final budget = timeout ?? const Duration(seconds: 30);
  Process? proc;
  try {
    proc = await Process.start(
      binary,
      args,
      workingDirectory: workingDirectory,
      environment: {...Platform.environment, ...environment},
    );
  } on ProcessException catch (e) {
    return ProbeOutcome(spawnError: e.message, spawnErrno: e.errorCode);
  } catch (e) {
    return ProbeOutcome(spawnError: e.toString());
  }

  final chunks = <int>[];
  final drained = Completer<void>();
  var open = 2; // stdout + stderr
  void maybeDone() {
    if (open == 0 && !drained.isCompleted) drained.complete();
  }

  proc.stdout.listen(chunks.addAll, onDone: () { open--; maybeDone(); });
  proc.stderr.listen(chunks.addAll, onDone: () { open--; maybeDone(); });

  final exited = Completer<int>();
  unawaited(proc.exitCode.then((c) {
    if (!exited.isCompleted) exited.complete(c);
  }));

  final code = await Future.any([
    exited.future,
    Future<int>.delayed(budget, () => -0x7f),
  ]).then((v) => v);

  if (code == -0x7f) {
    // Timeout: kill and report whatever output we have so far.
    Process.killPid(proc.pid, ProcessSignal.sigkill);
    await Future.any([
      exited.future,
      Future<void>.delayed(const Duration(seconds: 3)),
    ]);
    return ProbeOutcome(
      timedOut: true,
      output: _decode(chunks),
    );
  }

  // Give the pipes a moment to drain after exit (same lesson as D-17).
  await Future.any([
    drained.future,
    Future<void>.delayed(const Duration(seconds: 2)),
  ]);
  return ProbeOutcome(exitCode: code, output: _decode(chunks));
}

String _decode(List<int> bytes) {
  try {
    return utf8.decode(bytes, allowMalformed: true);
  } catch (_) {
    return bytes.map((b) => b < 32 ? 0x20 : b).map(String.fromCharCode).join();
  }
}

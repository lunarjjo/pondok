import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pondok/screens/home_screen.dart';
import 'package:pondok/services/pack_source.dart';
import 'package:pondok/services/runtime_setup_controller.dart';
import 'package:pondok/services/server_controller.dart';
import 'package:pondok_core/pondok_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Widget tests inject controllers with a PREPARED tree, so nothing here
/// touches path_provider, the platform channel, or a real pack asset.
void main() {
  late String baseDir;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final tmp = Directory.systemTemp.createTempSync('pondok_widget_');
    baseDir = '${tmp.path}/pondok';
  });

  /// A healthy fake installed tree — enough for verify() to pass.
  /// ALL real IO (including sha256OfFile) must run inside runAsync:
  /// awaiting real IO directly in the fake-async test body never
  /// completes and hangs the test (the M1 lesson, rediscovered).
  Future<RuntimeSetupController> fakeSetup(WidgetTester tester) async {
    late String prootSha;
    await tester.runAsync(() async {
      Directory('$baseDir/runtime/rootfs/opt/box64')
          .createSync(recursive: true);
      Directory('$baseDir/server').createSync(recursive: true);
      File('$baseDir/runtime/proot').writeAsStringSync('#!/bin/sh\n');
      File('$baseDir/runtime/rootfs/opt/box64/box64')
          .writeAsStringSync('#!/bin/sh\n');
      File('$baseDir/server/bedrock_server')
          .writeAsBytesSync(List.filled(1024 * 1024 + 1, 7));
      prootSha = await sha256OfFile('$baseDir/runtime/proot');
      File('$baseDir/installed.json').writeAsStringSync('''
{
  "installedAt": "2026-10-23T00:00:00",
  "manifest": {
    "format": "pondok-runtime-pack/1",
    "packVersion": 2,
    "createdAt": "2026-10-23T00:00:00+00:00",
    "components": {
      "proot": {"tag": "v5.5.0", "sha256": "$prootSha"},
      "box64": {"tag": "v0.4.4", "sha256": "x", "path": "/opt/box64/box64"},
      "rootfs": {"base": "ubuntu-base-24.04.5-arm64", "sha256_gz": "y"},
      "bds": {"version": "1.26.52.3", "sha256": "z", "zipBytes": 94927522}
    },
    "members": {
      "proot": {"sha256": "$prootSha", "size": 12},
      "rootfs.tar": {"sha256": "r", "size": 1},
      "bds.zip": {"sha256": "b", "size": 1}
    }
  }
}
''');
    });
    return RuntimeSetupController(baseDir: baseDir);
  }

  testWidgets('home renders runtime ready + EULA gate before server',
      (tester) async {
    final setup = await fakeSetup(tester);
    final server = ServerController(baseDir: baseDir);
    // Real file IO cannot advance inside fake-async — drive the (fast,
    // idempotent) install check outside it, exactly like the M1 lesson.
    await tester.runAsync(() => setup.ensureInstalled());
    expect(setup.isReady, isTrue, reason: 'fixture must be healthy');

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(setupController: setup, serverController: server)),
    );
    await _settle(tester);

    expect(find.text('Pondok'), findsOneWidget);
    // Runtime is ready — the zero-setup promise, visible on screen.
    expect(find.text('Runtime'), findsOneWidget);
    expect(find.text('SIAP'), findsOneWidget);
    expect(find.textContaining('Minecraft Bedrock Dedicated Server 1.26.52.3'),
        findsOneWidget);
    expect(find.textContaining('tidak ada unduhan'), findsOneWidget);
    // EULA gate replaces the server card until accepted.
    expect(find.text('Persetujuan EULA'), findsOneWidget);
    expect(find.text('Server'), findsNothing);

    await tester.tap(find.text('Saya setuju — lanjutkan'));
    await _settle(tester);
    expect(find.text('Server'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Konsol'), findsOneWidget);
    // Dispose the tree so no animation ticker outlives the test.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('runtime card shows the one-time installing phase',
      (tester) async {
    // No installed tree + a pack source that never completes: the UI must
    // show the one-time progress state — not a dead screen, not a crash.
    final setup = RuntimeSetupController(
      baseDir: '$baseDir-empty',
      packSource: _HangingPackSource(),
    );
    final server = ServerController(baseDir: '$baseDir-empty');
    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(setupController: setup, serverController: server)),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // Still in the checking phase (real IO cannot advance inside fake
    // async) — the one-time progress state is showing either way.
    expect(
        find.textContaining(
            RegExp('Memeriksa runtime|Menyalin paket runtime')),
        findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining(RegExp('sekali saja', caseSensitive: false)), findsOneWidget);
    // Dispose the tree: kills the spinner's animation ticker and the
    // still-pending install future's UI subscriptions.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'D-17: a failed start shows the reason, tries the fallback mode, '
      'and runs diagnostics — never a silent crash badge', (tester) async {
    final setup = await fakeSetup(tester);
    var profileCalls = <String>[];
    final server = ServerController(
      baseDir: baseDir,
      // Both profiles fail BEFORE any real process spawn (error injected
      // at profile resolution) — keeps the test inside fake-async.
      profileFactory: (base, mode) {
        profileCalls.add(mode.name);
        return Future<BdsProcessConfig>.error(
            StateError('spawn failed: execvp(proot): Permission denied'));
      },
      diagnosticsFactory: (base) => _FakeDiagnostics(base),
      deviceInfoReader: () async => const {
        'model': 'Pixel Test',
        'android': '15',
        'abis': 'arm64-v8a',
      },
    );
    await tester.runAsync(() => server.hydrate());

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(setupController: setup, serverController: server)),
    );
    await tester.runAsync(() => setup.ensureInstalled());
    expect(setup.isReady, isTrue, reason: 'fixture must be healthy');

    // Accept the EULA gate, then press Start.
    await tester.tap(find.text('Saya setuju — lanjutkan'));
    await _settle(tester);
    await tester.tap(find.text('Start'));
    await _settle(tester);

    // Both launch modes were attempted — the automatic fallback ran.
    expect(profileCalls, ['proot', 'direct']);

    // The failure box replaced the silent badge: reason, ladder, log path.
    expect(find.text('Mengapa gagal?'), findsOneWidget);
    expect(find.textContaining('spawn failed: execvp(proot)'), findsOneWidget);
    expect(find.textContaining('mode cadangan juga gagal'), findsOneWidget);
    expect(find.text('Tangga diagnostik:'), findsOneWidget);
    expect(find.text('Eksekusi proot dari penyimpanan aplikasi'),
        findsOneWidget);
    expect(find.textContaining('Izin eksekusi DITOLAK'),
        findsWidgets); // in the summary AND the probe note
    expect(find.textContaining('pondok.log'), findsOneWidget);

    // The manual diagnostics button exists and is usable post-failure.
    expect(find.text('Diagnostik'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });
}

class _FakeDiagnostics extends StackDiagnostics {
  _FakeDiagnostics(super.base);

  @override
  Future<List<ProbeResult>> run({void Function(ProbeResult)? onProbe}) async {
    const rs = [
      ProbeResult(
          name: 'sh',
          label: 'Proses dasar sistem',
          status: ProbeStatus.pass),
      ProbeResult(
          name: 'exec-proot',
          label: 'Eksekusi proot dari penyimpanan aplikasi',
          status: ProbeStatus.fail,
          exitCode: 13,
          note: 'Izin eksekusi DITOLAK — Android/OEM memblokir eksekusi '
              'berkas dari penyimpanan aplikasi (SELinux).'),
      ProbeResult(
          name: 'direct-box64',
          label: 'box64 langsung tanpa proot (mode cadangan)',
          status: ProbeStatus.fail,
          exitCode: 13),
    ];
    for (final r in rs) {
      onProbe?.call(r);
    }
    return rs;
  }
}

class _HangingPackSource implements PackSource {
  @override
  Future<void> copyTo(String assetName, String destFile) =>
      Completer<void>().future;
}

/// pumpAndSettle is banned here: the checking/installing phases run a
/// forever-spinner, and real IO futures never complete under fake async
/// (the M1 hang lesson). A short, bounded pump sequence instead.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

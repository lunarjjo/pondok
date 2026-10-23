import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/runtime_setup_controller.dart';
import '../services/server_controller.dart';
import 'package:pondok_core/pondok_core.dart';

/// The zero-setup home screen (M2).
///
/// First launch: unpacks the bundled runtime from the APK — a single
/// progress indicator, no configuration, no downloads. Then: accept the
/// Minecraft EULA once, press Start, play. Everything the server needs
/// (proot, ubuntu rootfs, box64, the official BDS distribution) already
/// shipped inside the APK itself.
class HomeScreen extends StatefulWidget {
  /// Injection points for widget tests.
  final RuntimeSetupController? setupController;
  final ServerController? serverController;

  const HomeScreen({super.key, this.setupController, this.serverController});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  RuntimeSetupController? _setup;
  ServerController? _server;
  bool _eulaAccepted = false;
  final _commandField = TextEditingController();
  final _consoleScroll = ScrollController();

  static const _eulaKey = 'eula_accepted_v1';

  @override
  void initState() {
    super.initState();
    _loadEula();
    _boot();
  }

  Future<void> _boot() async {
    if (widget.setupController != null && widget.serverController != null) {
      _attach(widget.setupController!, widget.serverController!);
      // Controller may already be ready (pre-warmed, or tests): skip the
      // redundant install check instead of re-running IO.
      if (!_setup!.isReady) await _setup!.ensureInstalled();
      unawaited(_server!.hydrate());
      return;
    }
    // Production path: app-private files dir.
    final dir = await _resolveBaseDir();
    if (!mounted) return;
    _attach(
      RuntimeSetupController(baseDir: '$dir/pondok'),
      ServerController(baseDir: '$dir/pondok'),
    );
    unawaited(_server!.hydrate());
    await _setup!.ensureInstalled();
  }

  Future<String> _resolveBaseDir() async {
    // App-private internal storage (no permissions, persists across
    // launches, executable allowed at targetSdk 28 — ARCHITECTURE.md §2).
    final dir = await getApplicationSupportDirectory();
    return dir.path;
  }

  void _attach(RuntimeSetupController setup, ServerController server) {
    setState(() {
      _setup = setup;
      _server = server;
    });
    setup.addListener(_onChange);
    server.addListener(_onChange);
  }

  void _onChange() {
    if (mounted) setState(() {});
    _autoScrollConsole();
  }

  Future<void> _loadEula() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _eulaAccepted = prefs.getBool(_eulaKey) ?? false);
  }

  Future<void> _acceptEula() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_eulaKey, true);
    setState(() => _eulaAccepted = true);
  }

  void _autoScrollConsole() {
    if (!_consoleScroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_consoleScroll.hasClients) {
        _consoleScroll.animateTo(
          _consoleScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _setup?.removeListener(_onChange);
    _server?.removeListener(_onChange);
    _commandField.dispose();
    _consoleScroll.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final setup = _setup;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Pondok'),
            Text('Bedrock Mobile Server Manager', style: t.bodySmall),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      body: setup == null || _server == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _RuntimeCard(setup: setup),
                const SizedBox(height: 12),
                if (_eulaAccepted) ...[
                  _ServerCard(server: _server!),
                  const SizedBox(height: 12),
                  _ConsoleCard(
                    server: _server!,
                    controller: _commandField,
                    scroll: _consoleScroll,
                  ),
                  const SizedBox(height: 12),
                ] else
                  _EulaCard(onAccept: _acceptEula),
                const SizedBox(height: 12),
                _HonestyCard(manifest: setup.manifest),
              ],
            ),
    );
  }
}

// ------------------------------------------------------------------ runtime

class _RuntimeCard extends StatelessWidget {
  final RuntimeSetupController setup;
  const _RuntimeCard({required this.setup});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final m = setup.manifest;

    Widget trailing;
    String body;
    switch (setup.phase) {
      case RuntimeSetupPhase.checking:
      case RuntimeSetupPhase.copyingPack:
      case RuntimeSetupPhase.installing:
        trailing = const SizedBox(
          width: 18, height: 18,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        );
        body = '${setup.phase.label}\n'
            'Sekali saja — setelah ini server siap dipakai selamanya.';
        break;
      case RuntimeSetupPhase.ready:
        trailing = _Badge('SIAP', color: c.primaryContainer, fg: c.onPrimaryContainer);
        body = 'Semua komponen terpasang dan siap:\n'
            '• Minecraft Bedrock Dedicated Server ${m?.bdsVersion ?? '?'} (distribusi resmi)\n'
            '• Box64 ${m?.box64Tag ?? '?'} + proot ${m?.prootTag ?? '?'} (penerjemah x86-64 → arm64)\n'
            '• Semuanya dibundel di dalam APK — tidak ada unduhan.';
        break;
      case RuntimeSetupPhase.failed:
        trailing = _Badge('GAGAL', color: c.errorContainer, fg: c.onErrorContainer);
        body = setup.error ?? 'Kesalahan tak diketahui';
        break;
    }

    return Card(
      elevation: 0,
      color: c.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.inventory_2_outlined, color: c.primary),
              const SizedBox(width: 12),
              Expanded(child: Text('Runtime', style: t.titleMedium)),
              trailing,
            ]),
            const SizedBox(height: 8),
            Text(body, style: t.bodyMedium),
            if (setup.phase == RuntimeSetupPhase.installing ||
                setup.phase == RuntimeSetupPhase.copyingPack) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(minHeight: 6, borderRadius: BorderRadius.circular(3)),
            ],
            if (setup.phase == RuntimeSetupPhase.failed) ...[
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: () => setup.ensureInstalled(),
                icon: const Icon(Icons.refresh),
                label: const Text('Coba lagi'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------------- eula

class _EulaCard extends StatelessWidget {
  final VoidCallback onAccept;
  const _EulaCard({required this.onAccept});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Card(
      elevation: 0,
      color: c.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.gavel_outlined, color: c.primary),
              const SizedBox(width: 12),
              Expanded(child: Text('Persetujuan EULA', style: t.titleMedium)),
            ]),
            const SizedBox(height: 8),
            Text(
              'Menjalankan server Minecraft tunduk pada Minecraft End User '
              'License Agreement dari Mojang. Kamu setuju untuk mematuhinya '
              'sebelum server dinyalakan.',
              style: t.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'https://www.minecraft.net/eula',
              style: t.bodySmall?.copyWith(color: c.primary),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onAccept,
              icon: const Icon(Icons.check),
              label: const Text('Saya setuju — lanjutkan'),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ server

class _ServerCard extends StatelessWidget {
  final ServerController server;
  const _ServerCard({required this.server});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final running = server.isRunning;

    Color chipColor;
    Color chipFg;
    switch (server.state) {
      case BdsState.running:
        chipColor = c.primaryContainer;
        chipFg = c.onPrimaryContainer;
        break;
      case BdsState.starting:
      case BdsState.stopping:
        chipColor = c.secondaryContainer;
        chipFg = c.onSecondaryContainer;
        break;
      case BdsState.crashed:
      case BdsState.startupFailed:
        chipColor = c.errorContainer;
        chipFg = c.onErrorContainer;
        break;
      default:
        chipColor = c.surfaceContainerHighest;
        chipFg = c.onSurfaceVariant;
    }

    final up = server.uptime;
    final upLabel = up == null
        ? ''
        : 'aktif ${up.inMinutes} mnt ${up.inSeconds % 60} dtk';

    return Card(
      elevation: 0,
      color: c.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(
                running ? Icons.play_circle_fill : Icons.play_circle_outline,
                color: c.primary,
              ),
              const SizedBox(width: 12),
              Expanded(child: Text('Server', style: t.titleMedium)),
              _Badge(server.stateLabel, color: chipColor, fg: chipFg),
            ]),
            const SizedBox(height: 8),
            Text(
              running
                  ? 'Pemain bisa bergabung lewat LAN: IP perangkat ini, port 19132 '
                    '(default).$upLabel'
                  : 'Sekali tombol — proot + box64 + bedrock_server menyala '
                    'dalam satu langkah.',
              style: t.bodyMedium,
            ),
            const SizedBox(height: 12),
            Row(children: [
              FilledButton.icon(
                onPressed: running ? null : () => server.start(),
                icon: const Icon(Icons.power_settings_new),
                label: const Text('Start'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: running ? () => server.stop() : null,
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: running || server.diagnosing
                    ? null
                    : () => server.runDiagnostics(),
                icon: server.diagnosing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.troubleshoot),
                label: const Text('Diagnostik'),
              ),
            ]),
            if (server.state == BdsState.crashed ||
                server.state == BdsState.startupFailed ||
                (server.failure ?? '').isNotEmpty) ...[
              const SizedBox(height: 12),
              _FailureBox(server: server),
            ],
            if (server.lastExit != null) ...[
              const SizedBox(height: 8),
              Text(
                'Berhenti terakhir: ${server.lastExit}',
                style: t.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- failure

/// The D-17 centerpiece: when the server dies, the screen shows the ACTUAL
/// reason — exit code decoded (signal vs plain exit), the process's last
/// output, the probe ladder verdict, and a one-tap copyable bug report.
/// "Kehilangan proses (crash)" with zero explanation is what this replaces.
class _FailureBox extends StatelessWidget {
  final ServerController server;
  const _FailureBox({required this.server});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final diag = server.diagnostics;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.errorContainer.withAlpha(89),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.error.withAlpha(102)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
              Icon(Icons.report_outlined, color: c.error, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Mengapa gagal?', style: t.titleSmall),
              ),
              IconButton.outlined(
                tooltip: 'Salin laporan untuk dikirim ke pengembang',
                onPressed: () => _copyReport(context),
                icon: const Icon(Icons.copy, size: 18),
              ),
          ]),
          if ((server.failure ?? '').isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              server.failure!,
              style: t.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: c.onErrorContainer,
              ),
            ),
          ],
          if (diag != null && diag.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Tangga diagnostik:', style: t.titleSmall),
            const SizedBox(height: 4),
            for (final r in diag)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ProbeBadge(r),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(r.label, style: t.bodySmall),
                          if (r.note.isNotEmpty)
                            Text(
                              r.note,
                              style: t.bodySmall
                                  ?.copyWith(color: c.onSurfaceVariant),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 4),
          Text(
            'Log lengkap: ${server.logPath}',
            style: t.bodySmall?.copyWith(color: c.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Future<void> _copyReport(BuildContext context) async {
    final report = await server.buildBugReport();
    await Clipboard.setData(ClipboardData(text: report));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Laporan lengkap tersalin ke papan klip — '
            'tempelkan (paste) ke pengembang.'),
        duration: Duration(seconds: 3),
      ),
    );
  }
}

class _ProbeBadge extends StatelessWidget {
  final ProbeResult r;
  const _ProbeBadge(this.r);

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final (fg, bg) = switch (r.status) {
      ProbeStatus.pass => (c.onPrimaryContainer, c.primaryContainer),
      ProbeStatus.skipped => (c.onSurfaceVariant, c.surfaceContainerHighest),
      _ => (c.onErrorContainer, c.errorContainer),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${r.statusLabel}${r.exitCode != null && r.status != ProbeStatus.pass ? ' ${r.exitCode}' : ''}',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------- console

class _ConsoleCard extends StatelessWidget {
  final ServerController server;
  final TextEditingController controller;
  final ScrollController scroll;

  const _ConsoleCard({
    required this.server,
    required this.controller,
    required this.scroll,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final lines = server.lines;
    return Card(
      elevation: 0,
      color: c.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.terminal_outlined, color: c.primary),
              const SizedBox(width: 12),
              Expanded(child: Text('Konsol', style: t.titleMedium)),
              Text('${lines.length} baris', style: t.bodySmall),
            ]),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              height: 220,
              decoration: BoxDecoration(
                color: const Color(0xFF101418),
                borderRadius: BorderRadius.circular(8),
              ),
              child: lines.isEmpty
                  ? Center(
                      child: Text(
                        'Konsol menyala bersama server.',
                        style: t.bodySmall?.copyWith(color: Colors.white54),
                      ),
                    )
                  : ListView.builder(
                      controller: scroll,
                      padding: const EdgeInsets.all(10),
                      itemCount: lines.length,
                      itemBuilder: (_, i) => Text(
                        lines[i].raw,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: Color(0xFFB8C4CC),
                        ),
                      ),
                    ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  enabled: server.isRunning,
                  decoration: const InputDecoration(
                    hintText: 'Perintah konsol (mis. list)',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (cmd) => _send(server, cmd),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: server.isRunning ? () => _send(server, controller.text) : null,
                icon: const Icon(Icons.send),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  void _send(ServerController server, String cmd) {
    if (cmd.trim().isEmpty) return;
    server.sendCommand(cmd.trim());
    controller.clear();
  }
}

// ------------------------------------------------------------------ honesty

class _HonestyCard extends StatelessWidget {
  final RuntimePackManifest? manifest;
  const _HonestyCard({required this.manifest});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Card(
      elevation: 0,
      color: c.surfaceContainerLowest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.science_outlined, color: c.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(child: Text('Status verifikasi', style: t.titleSmall)),
            ]),
            const SizedBox(height: 8),
            Text(
              'Terverifikasi di CI pada perangkat keras arm64 ASLI: stack '
              'proot → box64 → bedrock_server menyala, menjawab ping protokol '
              'RakNet, konsol dua arah, stop bersih (exit 0), world bertahan '
              'lintas restart (workflow "runtime-pack").\n'
              'Belum terverifikasi: uji pada HP fisik — butir Definition of '
              'Done yang terbuka; performa di HP bervariasi sesuai chipset.',
              style: t.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------------- misc

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  final Color fg;
  const _Badge(this.label, {required this.color, required this.fg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: fg,
        ),
      ),
    );
  }
}

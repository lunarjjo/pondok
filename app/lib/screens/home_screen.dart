import 'package:flutter/material.dart';

/// Honest home screen for milestone M1: the runtime layer is not yet
/// installable from the app (that is milestone M2), so instead of a fake
/// dashboard this screen states exactly what exists and what does not —
/// the same discipline as docs/PHASE0_REPORT.md.
///
/// When M2 lands, this becomes the server list + onboarding entry.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Pondok'),
            Text('Bedrock Mobile Server Manager', style: t.bodySmall),
          ],
        ),
        backgroundColor: c.surfaceContainerHighest,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _StatusCard(
            icon: Icons.foundation_outlined,
            title: 'Phase 0 complete',
            body: 'Feasibility researched and proven with the real BDS '
                '1.26.52.3 binary: supervised start, console round-trip, '
                'allowlist sync, graceful stop (exit 0), world persistence, '
                'crash detection. Evidence: docs/evidence/ in the repository.',
            trailing: _Badge('VERIFIED'),
          ),
          const SizedBox(height: 12),
          const _StatusCard(
            icon: Icons.terminal_outlined,
            title: 'Core library onboard',
            body: 'pondok_core ships in this APK: process supervisor, console '
                'parser, typed server.properties registry (1.26.x), allowlist, '
                'backup/restore with CRC validation, journaled update '
                'pipeline, tunnel abstraction. 103 unit tests + 6 real-binary '
                'integration tests green in CI.',
            trailing: _Badge('ONBOARD'),
          ),
          const SizedBox(height: 12),
          const _StatusCard(
            icon: Icons.phone_android_outlined,
            title: 'On-device runtime: not installed yet',
            body: 'Installing the Box64/proot runtime and downloading the '
                'official server distribution happens in milestone M2. '
                'Nothing on this screen is simulated — there is no server '
                'running because none has been installed.',
            trailing: _Badge('PENDING', muted: true),
          ),
          const SizedBox(height: 24),
          Text(
            'Status sesi pengembangan',
            style: t.titleSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Proyek ini hanya meng-host server pada perangkat yang terverifikasi '
            'kompatibel. Layanan internet publik lewat tunnel UDP (playit.gg) '
            'dan performa ARM64 melalui Box64 adalah kemampuan yang terdokumentasi '
            'komunitas — verifikasi pada perangkat nyata adalah bagian dari '
            'Definition of Done (lihat ROADMAP.md).',
            style: t.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Widget trailing;

  const _StatusCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: c.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: c.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(title, style: Theme.of(context).textTheme.titleMedium),
                ),
                trailing,
              ],
            ),
            const SizedBox(height: 8),
            Text(body, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final bool muted;
  const _Badge(this.label, {this.muted = false});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: muted ? c.surfaceContainerHighest : c.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: muted ? c.onSurfaceVariant : c.onPrimaryContainer,
        ),
      ),
    );
  }
}

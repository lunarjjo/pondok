import 'package:pondok_core/pondok_core.dart';
import 'package:test/test.dart';

void main() {
  group('BackoffSchedule — bounded exponential with jitter', () {
    const sched = BackoffSchedule(
      initial: Duration(seconds: 2),
      maximum: Duration(minutes: 5),
      multiplier: 2,
    );

    test('doubles per attempt', () {
      expect(sched.delayForAttempt(1), const Duration(seconds: 2));
      expect(sched.delayForAttempt(2), const Duration(seconds: 4));
      expect(sched.delayForAttempt(3), const Duration(seconds: 8));
      expect(sched.delayForAttempt(6), const Duration(seconds: 64));
    });

    test('caps at maximum', () {
      expect(sched.delayForAttempt(20), const Duration(minutes: 5));
      // and stays there
      expect(sched.delayForAttempt(100), const Duration(minutes: 5));
    });

    test('jitter scales the delay but stays bounded', () {
      final d = sched.delayForAttempt(2, jitter: () => 0.5);
      expect(d, const Duration(seconds: 6));
      final big = sched.delayForAttempt(100, jitter: () => 1.0);
      expect(big <= const Duration(minutes: 10), isTrue);
    });

    test('zero jitter is exact', () {
      expect(sched.delayForAttempt(4, jitter: () => 0), const Duration(seconds: 16));
    });
  });

  group('TunnelStatus', () {
    test('player address formatting', () {
      expect(
        const TunnelStatus(TunnelState.online, publicHost: 'glowing.playit.gg', publicPort: 12345)
            .playerAddress,
        'glowing.playit.gg:12345',
      );
      expect(
        const TunnelStatus(TunnelState.online, publicHost: 'glowing.playit.gg')
            .playerAddress,
        'glowing.playit.gg',
      );
      expect(const TunnelStatus(TunnelState.offline).playerAddress, isNull);
    });
  });

  group('TunnelProvider contract', () {
    test('PlayitProvider exposes stable ids', () {
      final p = PlayitProvider(agentBinary: '/x/playit', stateDir: '/x/state');
      expect(p.id, 'playit');
      expect(p.displayName, 'playit.gg');
      expect(p.lastStatus.state, TunnelState.disabled);
      p.dispose();
    });
  });
}

import '../lib/services/playback_recovery.dart';

void main() {
  var checks = 0;
  void check(bool ok, String name) {
    if (!ok) throw StateError(name);
    checks++;
    print('PASS $name');
  }

  const target = Duration(minutes: 37);
  for (final incoming in [
    Duration.zero,
    const Duration(seconds: 1),
    const Duration(seconds: 20),
    target,
  ]) {
    check(
      recoveryVisiblePosition(
            holding: true,
            previous: target,
            incoming: incoming,
          ) ==
          target,
      'hold preserves $incoming',
    );
  }
  check(
    recoveryVisiblePosition(
          holding: false,
          previous: target,
          incoming: const Duration(seconds: 12),
        ) ==
        const Duration(seconds: 12),
    'intentional backward seek allowed outside recovery',
  );
  check(
    !recoverySeekLanded(
      live: false,
      target: target,
      actual: const Duration(seconds: 1),
    ),
    'audio at beginning is not a landed seek',
  );
  check(
    !recoverySeekLanded(
      live: false,
      target: target,
      actual: target - const Duration(seconds: 6),
    ),
    'out of tolerance rejected',
  );
  check(
    recoverySeekLanded(
      live: false,
      target: target,
      actual: target - const Duration(seconds: 5),
    ),
    'tolerance inclusive',
  );
  check(
    recoverySeekLanded(live: true, target: target, actual: Duration.zero),
    'live has no VOD seek requirement',
  );
  check(
    recoverySeekLanded(
      live: false,
      target: Duration.zero,
      actual: Duration.zero,
    ),
    'new playback target zero',
  );
  print('ALL PASS ($checks checks)');
}

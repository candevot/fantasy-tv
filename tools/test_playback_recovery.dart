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

  // STARTUP_FAST_FAIL（2026-11-14）：起播门槛 6 秒，首帧出来后回到 8 秒。
  check(
    stallTimeoutFor(hasRenderedFirstFrame: false) ==
        const Duration(seconds: 6),
    'startup stall threshold is 6s',
  );
  check(
    stallTimeoutFor(hasRenderedFirstFrame: true) ==
        const Duration(seconds: 8),
    'playback stall threshold stays 8s',
  );

  // 坏地址账本：同址 2 次判死，解析类失败 1 次判死，成功一次就销账。
  final ledger = BadAddressLedger();
  const bad = 'http://cdn.example/dead.m3u8';
  check(!ledger.isDead(bad), 'fresh address is alive');
  ledger.noteFailure(bad);
  check(!ledger.isDead(bad), 'one failure is not fatal');
  ledger.noteFailure(bad);
  check(ledger.isDead(bad), 'two failures kill the address');
  ledger.clear(bad);
  check(!ledger.isDead(bad), 'success clears the debt');
  ledger.noteFailure(bad, resolveFailure: true);
  check(ledger.isDead(bad), 'manifest failure kills at once');
  check(ledger.countOf(bad) == ledger.failThreshold, 'resolve failure capped');
  ledger.noteFailure('');
  check(ledger.countOf('') == 0, 'empty url is ignored');

  print('ALL PASS ($checks checks)');
}

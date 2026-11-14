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

  // ALIGN_FONGMI（2026-11-15）：起播门槛 15 秒，首帧出来后 12 秒。
  //
  // 断言直接比常量，而不是抄一份数字：门槛是「传输层超时（30s）+ media3
  // 默认 3 次重试」的下游取值，改传输层时这里跟着常量走，不会再出现
  // 「代码改了、测试还钉在 6s/8s」的假失败。
  check(
    stallTimeoutFor(hasRenderedFirstFrame: false) == startupStallTimeout,
    'startup stall threshold matches startupStallTimeout',
  );
  check(
    stallTimeoutFor(hasRenderedFirstFrame: true) == playbackStallTimeout,
    'playback stall threshold matches playbackStallTimeout',
  );
  check(
    startupStallTimeout == const Duration(seconds: 15),
    'startup stall threshold is 15s',
  );
  check(
    playbackStallTimeout == const Duration(seconds: 12),
    'playback stall threshold is 12s',
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

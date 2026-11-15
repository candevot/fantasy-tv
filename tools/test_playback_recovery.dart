import '../lib/services/playback_progress.dart';
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

  // FLOW_WATCH（2026-11-15，用户最终口径）：
  //   无进展 8 秒 → 切；首帧后 6 秒 buffered 不涨 → 切；
  //   有数据但没首帧 30 秒硬上限 → 切；15 秒起提示「网速较慢（已等 N 秒）」。
  //
  // 断言比的是**唯一出处**（playback_progress.dart 的常量），不是抄一份
  // 数字：原来这里钉死 15/12 秒，改口径时测试跟着一起错，等于没测。
  check(
    stallTimeoutFor(hasRenderedFirstFrame: false) == startupStallTimeout,
    'startup stall threshold matches startupStallTimeout',
  );
  check(
    stallTimeoutFor(hasRenderedFirstFrame: true) == playbackStallTimeout,
    'playback stall threshold matches playbackStallTimeout',
  );
  check(
    startupStallTimeout == fxStartupNoProgressWindow,
    'startup stall window comes from fxStartupNoProgressWindow',
  );
  check(
    playbackStallTimeout == fxStallNoProgressWindow,
    'playback stall window comes from fxStallNoProgressWindow',
  );
  check(
    fxStartupNoProgressWindow == const Duration(seconds: 8),
    'no-progress window is 8s',
  );
  check(
    fxStallNoProgressWindow == const Duration(seconds: 6),
    'post-first-frame stall window is 6s',
  );
  check(
    fxSlowStartupCap == const Duration(seconds: 30),
    'slow-network hard cap is 30s',
  );
  check(
    fxSlowNoticeAfter == const Duration(seconds: 15),
    'slow notice starts at 15s',
  );

  // —— 慢网不是失败：8 秒窗口只看「有没有动」——
  final window = FxProgressWindow();
  const step = Duration(milliseconds: 500);
  // 200KB/s 的慢网：每 500ms 涨 100KB，20 秒内一直没有首帧。
  for (var ms = 0; ms <= 20000; ms += 500) {
    window.add(
      FxProgressSample(
        atMs: ms,
        bytesLoaded: (ms / 1000 * 200 * 1024).round(),
        buffered: Duration(milliseconds: ms ~/ 4),
        position: Duration.zero,
        isLoading: true,
      ),
    );
  }
  check(
    window.state == FxProgressState.slow,
    '200KB/s 慢网 20 秒不判失败（有字节在涨）',
  );
  check(
    window.stalledFor < fxStartupNoProgressWindow,
    '200KB/s 慢网的「无进展」时长永远不到 8 秒',
  );

  // —— 真卡死：8 秒一个字节都不动 ——
  final stuck = FxProgressWindow();
  stuck.add(
    const FxProgressSample(
      atMs: 0,
      bytesLoaded: 4096,
      buffered: Duration(seconds: 2),
    ),
  );
  for (var ms = 500; ms <= 8500; ms += 500) {
    stuck.add(
      FxProgressSample(
        atMs: ms,
        bytesLoaded: 4096,
        buffered: const Duration(seconds: 2),
        isLoading: true,
      ),
    );
  }
  check(
    stuck.state == FxProgressState.stuck,
    '8 秒 bytes / buffered 都不动才是真卡死',
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

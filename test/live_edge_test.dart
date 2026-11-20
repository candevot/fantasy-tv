import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/services/live_edge.dart';

/// LIVE_EDGE（2026-11-20）纯逻辑回归。
///
/// 用户口径（原话）：「直播要什么暂停按钮，刷新之后还是当前的，根本不是
/// 跟上跟不上进度，直播不同步」。
///
/// 交付口径被用户改过一次，这里钉的是**改后**的口径：
///   · 只有「点刷新（以及换线路 / 换台这类主动重开）」才追到直播边缘；
///   · 刷新后位置必须落在窗口末端 3 秒内；
///   · 播放过程中落后就让它落后 —— 不存在「落后 N 秒自动追平」这种自动跳转。
void main() {
  const radius = Duration(seconds: 60);

  test('刷新目标 = 窗口末端前 3 秒（验收：末端 3 秒内）', () {
    expect(fxLiveRefreshRewind, const Duration(seconds: 3));
    final target = fxLiveEdgeTarget(radius);
    expect(target, const Duration(seconds: 57));
    expect(
      fxLiveIsAtEdge(position: target!, duration: radius),
      isTrue,
      reason: '刷新落地位置必须满足「距末端 ≤ 3 秒」',
    );
  });

  test('用户口径的下限 2 秒也在允许回退范围内', () {
    expect(fxLiveEdgeMinRewind, const Duration(seconds: 2));
    final target = fxLiveEdgeTarget(radius, rewind: fxLiveEdgeMinRewind)!;
    expect(target, const Duration(seconds: 58));
    expect(
      fxLiveLag(position: target, duration: radius),
      lessThanOrEqualTo(fxLiveRefreshRewind),
    );
  });

  test('窗口时长未知（HLS live 常见 duration=0）时不给目标，交给兜底 seek', () {
    expect(fxLiveEdgeTarget(Duration.zero), isNull);
    expect(fxLiveEdgeTarget(const Duration(milliseconds: 900)), isNull,
        reason: '窗口比回退还短：没有「末端前 3 秒」这回事');
    // 兜底目标必须远大于任何真实直播窗口，原生 seekTo 会把它钳到末端。
    expect(fxLiveSeekToEnd, greaterThan(const Duration(days: 365)));
  });

  test('落后量：越过末端 / 窗口未知都按 0 处理，绝不为负', () {
    expect(
      fxLiveLag(
        position: const Duration(seconds: 20),
        duration: radius,
      ),
      const Duration(seconds: 40),
    );
    expect(fxLiveLag(position: radius, duration: radius), Duration.zero);
    expect(
      fxLiveLag(
        position: const Duration(seconds: 90),
        duration: radius,
      ),
      Duration.zero,
    );
    expect(
      fxLiveLag(position: const Duration(seconds: 5), duration: Duration.zero),
      Duration.zero,
    );
  });

  test('没有「自动追平」这套东西：模块里不出现阈值 / 定时检查', () {
    // 用户明确要求：不要落后 8 秒自动追平，不要定时位置检查。
    // 这里从源码层面钉住 —— 谁把自动追平加回来，这个用例立刻红。
    final source = _read('lib/services/live_edge.dart');
    for (final banned in <String>[
      'fxLiveLagThreshold',
      'fxLiveWatchInterval',
      'Timer',
      '自动追平',
    ]) {
      expect(source.contains(banned), isFalse, reason: '直播不许出现「$banned」');
    }
  });

  test('探针日志格式：一行含 pos / end / lag / seek，可直接 grep 验收', () {
    final line = fxLiveProbeLog(
      event: 'land',
      position: const Duration(seconds: 12),
      duration: const Duration(seconds: 30),
      target: const Duration(seconds: 27),
      reason: 'refresh',
    );
    expect(line.startsWith('[FxLive] land '), isTrue);
    expect(line, contains('pos=12.0s'));
    expect(line, contains('end=30.0s'));
    expect(line, contains('lag=18.0s'));
    expect(line, contains('seek=27.0s'));
    expect(line, contains('reason=refresh'));
    // 刷新后位置 27s / 末端 30s：3 秒内，验收通过。
    expect(
      fxLiveIsAtEdge(
        position: const Duration(seconds: 27),
        duration: const Duration(seconds: 30),
      ),
      isTrue,
    );
  });
}

String _read(String relative) => File(relative).readAsStringSync();

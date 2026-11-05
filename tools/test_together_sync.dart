// 一起看同步策略单测（纯 Dart，不依赖 Flutter）：
//   /root/flutter_sdk/flutter/bin/cache/dart-sdk/bin/dart tools/test_together_sync.dart
import '../lib/widgets/together_sync.dart';

int _passed = 0;

void check(bool cond, String message) {
  if (!cond) {
    throw StateError('FAIL: $message');
  }
  _passed++;
}

void near(double a, double b, double eps, String message) {
  check((a - b).abs() <= eps, '$message (got $a, want $b)');
}

void main() {
  // 3 次 ping 中位数：故意放一个离群值，结果仍取中间。
  check(TogetherClock.median([12, -4, 5]) == 5, 'median 取排序中间值');
  check(TogetherClock.median([9]) == 9, '单个样本');
  check(TogetherClock.median([]) == 0, '空样本返回 0');

  final clock = TogetherClock();
  check(!clock.ready, '初始未校准');
  clock.update(offsetMs: 123, rttMs: 45);
  check(clock.ready && clock.offsetMs == 123 && clock.rttMs == 45, '时钟写入');
  check(clock.nowServerMs(1000) == 1123, '本地时间换算服务器时间');
  clock.reset();
  check(!clock.ready && clock.offsetMs == 0, '重置');

  // seq 去重：同房间只接受更大的 seq，旧 seq 丢弃。
  final gate = TogetherSeqGate();
  check(gate.accept('100001', 1), '首个 seq');
  check(gate.accept('100001', 2), '新 seq');
  check(!gate.accept('100001', 2), '同 seq 只应用一次');
  check(!gate.accept('100001', 1), '旧 seq 丢弃');
  check(gate.accept('100002', 1), '换房间后 seq 重新计数');
  gate.reset();
  check(gate.accept('100001', 1), 'reset 后可重新接受');

  // drift 决策。
  TogetherSyncDecision d = decideTogetherDrift(
    expected: 100.0,
    current: 99.8,
    playing: true,
    baseRate: 1.0,
  );
  check(d.move == TogetherSyncMove.none, '<0.4s 不动');

  d = decideTogetherDrift(
    expected: 100.0,
    current: 99.5,
    playing: true,
    baseRate: 1.0,
  );
  check(d.move == TogetherSyncMove.rate, '0.5s → 微调');
  near(d.rate, 1.05, 1e-9, '落后 → 1.05x');

  d = decideTogetherDrift(
    expected: 99.4,
    current: 100.0,
    playing: true,
    baseRate: 1.0,
  );
  check(d.move == TogetherSyncMove.rate, '超前 → 微调');
  near(d.rate, 0.95, 1e-9, '超前 → 0.95x');

  d = decideTogetherDrift(
    expected: 102.0,
    current: 100.0,
    playing: true,
    baseRate: 1.0,
  );
  check(d.move == TogetherSyncMove.seek, '>1.5s → 硬 seek');
  near(d.target, 102.0, 1e-9, 'seek 到期望位置');

  d = decideTogetherDrift(
    expected: 100.5,
    current: 100.0,
    playing: false,
    baseRate: 1.0,
  );
  check(d.move == TogetherSyncMove.none, '暂停时不微调倍速');

  d = decideTogetherDrift(
    expected: 100.5,
    current: 100.0,
    playing: true,
    baseRate: 1.0,
    allowRate: false,
  );
  check(d.move == TogetherSyncMove.none, '内核不支持微调时等下一次');

  d = decideTogetherDrift(
    expected: 100.5,
    current: 100.0,
    playing: true,
    baseRate: 1.5,
  );
  near(d.rate, 1.55, 1e-9, '房主 1.5x 时在 1.5 基础上微调');

  // 期望位置外推：1x / 1.5x / 暂停。
  near(
    togetherExpectedPosition(
      position: 100,
      serverTime: 1000,
      nowServerMs: 2500,
      playing: true,
      rate: 1,
    ),
    101.5,
    1e-9,
    '1x 外推 1.5 秒',
  );
  near(
    togetherExpectedPosition(
      position: 100,
      serverTime: 1000,
      nowServerMs: 2500,
      playing: true,
      rate: 1.5,
    ),
    102.25,
    1e-9,
    '1.5x 外推按倍速推进',
  );
  near(
    togetherExpectedPosition(
      position: 100,
      serverTime: 1000,
      nowServerMs: 2500,
      playing: false,
      rate: 1.5,
    ),
    100,
    1e-9,
    '暂停时位置不推进',
  );
  near(
    togetherExpectedPosition(
      position: 100,
      serverTime: 0,
      nowServerMs: 2500,
      playing: true,
      rate: 1,
    ),
    100,
    1e-9,
    '无 serverTime 时不外推',
  );

  // 房主主动 seek vs 正常心跳外推。
  check(
    isTogetherSeekJump(
      prevPosition: 10,
      prevServerTime: 1000,
      prevPlaying: true,
      prevRate: 1,
      position: 100,
      serverTime: 1100,
    ),
    '心跳期间跳 90s 判为 seek',
  );
  check(
    !isTogetherSeekJump(
      prevPosition: 10,
      prevServerTime: 1000,
      prevPlaying: true,
      prevRate: 1,
      position: 19,
      serverTime: 10000,
    ),
    '正常播放 9 秒不算 seek',
  );
  check(
    isTogetherSeekJump(
      prevPosition: 100,
      prevServerTime: 1000,
      prevPlaying: false,
      prevRate: 1,
      position: 10,
      serverTime: 2000,
    ),
    '暂停时拖动进度也算 seek',
  );
  check(
    isTogetherSeekJump(
      prevPosition: 100,
      prevServerTime: 1000,
      prevPlaying: false,
      prevRate: 1,
      position: 100.7,
      serverTime: 1100,
    ),
    '暂停时 0.7s 的 seek 也立即应用',
  );
  check(
    !isTogetherSeekJump(
      prevPosition: 100,
      prevServerTime: 1000,
      prevPlaying: false,
      prevRate: 1,
      position: 100.3,
      serverTime: 1100,
    ),
    '0.3s 的暂停抖动不触发 seek',
  );

  // 边界：0.4 / 1.5 正好落在规则区间内。
  d = decideTogetherDrift(
    expected: 100.4,
    current: 100.0,
    playing: true,
    baseRate: 1.0,
  );
  check(d.move == TogetherSyncMove.rate, '0.4s 进入微调区');
  d = decideTogetherDrift(
    expected: 101.5,
    current: 100.0,
    playing: true,
    baseRate: 1.0,
  );
  check(d.move == TogetherSyncMove.rate, '1.5s 仍微调');
  d = decideTogetherDrift(
    expected: 101.5001,
    current: 100.0,
    playing: true,
    baseRate: 1.0,
  );
  check(d.move == TogetherSyncMove.seek, '>1.5s 硬 seek');

  print('together sync tests passed: $_passed checks');
}

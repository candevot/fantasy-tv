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

  // 时钟校准版本 / 增量：用于发现 offset 台阶。
  final clock2 = TogetherClock();
  check(clock2.version == 0 && clock2.lastOffsetDeltaMs == 0, '时钟初始版本');
  clock2.update(offsetMs: 100, rttMs: 20);
  check(clock2.version == 1 && clock2.lastOffsetDeltaMs == 0, '首次校准无增量');
  clock2.update(offsetMs: 140, rttMs: 20);
  check(clock2.version == 2 && clock2.lastOffsetDeltaMs == 40, '记录 offset 增量');
  clock2.reset();
  check(clock2.version == 0 && clock2.lastOffsetDeltaMs == 0, '重置清空版本');

  // 权威 state 分类：房主缓冲（停滞）不再被当成 seek 拉回成员。
  TogetherAuthorityVerdict v = classifyTogetherAuthority(
    prevPosition: 48,
    prevServerTime: 10000,
    prevPlaying: true,
    prevRate: 1,
    position: 48,
    playing: true,
    serverTime: 19000,
  );
  check(v.isStall, 'position 停住 9 秒判为房主停滞');
  check(!v.isSeek, '停滞不是 seek');

  v = classifyTogetherAuthority(
    prevPosition: 48,
    prevServerTime: 10000,
    prevPlaying: true,
    prevRate: 1,
    position: 50,
    playing: true,
    serverTime: 19000,
  );
  check(v.isStall, '慢推进（缓冲中）也判停滞');

  v = classifyTogetherAuthority(
    prevPosition: 100,
    prevServerTime: 10000,
    prevPlaying: true,
    prevRate: 1,
    position: 90,
    playing: true,
    serverTime: 11000,
  );
  check(v.isSeek, '房主往回拖 10s 判为 seek');

  v = classifyTogetherAuthority(
    prevPosition: 100,
    prevServerTime: 10000,
    prevPlaying: true,
    prevRate: 1,
    position: 200,
    playing: true,
    serverTime: 11000,
  );
  check(v.isSeek, '房主前拖判为 seek');

  v = classifyTogetherAuthority(
    prevPosition: 100,
    prevServerTime: 10000,
    prevPlaying: true,
    prevRate: 1,
    position: 109,
    playing: true,
    serverTime: 19000,
  );
  check(!v.isSeek && !v.isStall, '正常推进 9 秒既不是 seek 也不是停滞');

  v = classifyTogetherAuthority(
    prevPosition: 100,
    prevServerTime: 10000,
    prevPlaying: true,
    prevRate: 1,
    position: 99.8,
    playing: true,
    serverTime: 11000,
  );
  check(v.isStall, '读数小幅回退（<1.5s）当停滞吸收，不回跳');

  // 负向 drift：默认允许回跳，关闭后先降速吸收。
  d = decideTogetherDrift(
    expected: 98.0,
    current: 100.0,
    playing: true,
    baseRate: 1.0,
  );
  check(d.move == TogetherSyncMove.seek, '默认负向 >1.5s 仍可回跳');

  d = decideTogetherDrift(
    expected: 98.0,
    current: 100.0,
    playing: true,
    baseRate: 1.0,
    allowBackwardSeek: false,
  );
  check(d.move == TogetherSyncMove.rate, '禁止回跳时先降速吸收');
  near(d.rate, 0.95, 1e-9, '禁止回跳 → 0.95x');

  d = decideTogetherDrift(
    expected: 98.0,
    current: 100.0,
    playing: false,
    baseRate: 1.0,
    allowBackwardSeek: false,
  );
  check(d.move == TogetherSyncMove.none, '禁止回跳且暂停 → 不动');

  check(
    togetherCanCorrectMember(
      online: true, connected: true, clockSynced: true,
      awaitingRoomState: false,
    ),
    '已校准且拿到新房间状态才周期纠偏',
  );
  check(
    !togetherCanCorrectMember(
      online: false, connected: false, clockSynced: false,
      awaitingRoomState: true,
    ),
    '断线重置时钟不拿冻结旧进度反复 seek',
  );
  check(
    !togetherCanCorrectMember(
      online: true, connected: true, clockSynced: false,
      awaitingRoomState: false,
    ),
    '重连 room_state 先到也须等时钟校准',
  );
  check(
    !togetherCanCorrectMember(
      online: true, connected: true, clockSynced: true,
      awaitingRoomState: true,
    ),
    'hello/pong 不代表重新入房，仍等权威快照',
  );
  check(togetherPositionMoved(10000, 100000), '后拖重置进度锚点，不永久 stall');
  check(togetherPositionMoved(10500, 10000), '后拖后正常推进可恢复纠偏');
  check(!togetherPositionMoved(10010, 10000), '小幅测量抖动仍不算推进');

  // Normal verdicts must retain progress evidence. Previously they returned
  // gap=advance=0, so 0 >= 0 made duplicate snapshots release a stall.
  v = classifyTogetherAuthority(
    prevPosition: 48,
    prevServerTime: 10000,
    prevPlaying: true,
    prevRate: 1,
    position: 49,
    serverTime: 11000,
    playing: true,
  );
  check(!v.isStall && !v.isSeek, '恢复推进属于 normal');
  check(v.gapMs == 1000, 'normal 保留采样时间差');
  near(v.advance, 1, 1e-9, 'normal 保留真实推进量');
  near(v.deviation, 0, 1e-9, 'normal 保留外推偏差');

  bool holding = togetherShouldStallHold(
    holding: false,
    playing: true,
    authorityStalled: true,
    drift: -2,
  );
  check(holding, '房主停滞且成员领先 2s → hold');
  holding = togetherShouldStallHold(
    holding: holding,
    playing: false,
    authorityStalled: false,
    drift: -2,
  );
  check(!holding, '明确暂停立即释放 hold，允许暂停点对齐');
  check(
    !togetherShouldStallHold(
      holding: true,
      playing: true,
      authorityStalled: false,
      authoritySeek: true,
      drift: -20,
    ),
    '房主后拖时立即释放 hold，不先 pause 再 play',
  );
  check(
    togetherShouldStallHold(
      holding: true,
      playing: true,
      authorityStalled: true,
      drift: -1,
    ),
    '保持中尚未追上，仍暂停',
  );
  check(
    !togetherShouldStallHold(
      holding: true,
      playing: true,
      authorityStalled: false,
      drift: -0.3,
    ),
    '房主追上死区即恢复',
  );
  check(
    !togetherShouldStallHold(
      holding: true,
      playing: true,
      authorityStalled: false,
      drift: -20,
      timedOut: true,
    ),
    '权威停滞已过期时，hold 超时释放',
  );
  check(
    !togetherShouldStallHold(
      holding: false,
      playing: true,
      authorityStalled: true,
      drift: -2,
      buffering: true,
    ),
    '本地缓冲中不新建 pause hold',
  );
  check(
    !togetherShouldStallHold(
      holding: false,
      playing: true,
      authorityStalled: true,
      drift: -2,
      seeking: true,
    ),
    'seek 未落位时不新建 pause hold',
  );

  print('together sync tests passed: $_passed checks');
}

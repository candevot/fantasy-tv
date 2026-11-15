/* ========================================================================== */
/*  一起看 · 同步策略（纯 Dart，无 Flutter 依赖，方便单测）                     */
/*                                                                            */
/*  · 时钟：offset = serverTime - 本地中点，取 3 次 ping 的中位数；             */
/*  · 进度：expect = position + (now + offset - serverTime) / 1000；           */
/*  · 纠偏：< 0.4s 不动，0.4–2.0s 微调 ±0.05 倍速，> 2.0s 才硬 seek 一次；       */
/*  · 房主缓冲：position 停住而时钟照走 → 判 stall，成员冻结期望、先降速吸收， */
/*    落后太多就原地保持（暂停）等房主恢复，全程不往回跳。                      */
/* ========================================================================== */

/// 权威进度心跳间隔。
///
/// 验收口径（2026-11-15）：「心跳 1 秒一次，带 quiet 标记」。1 秒一次能把
/// 正常网络下的偏差压在百毫秒量级，基本不需要硬 seek；服务端只接受
/// 主导者的 quiet 心跳，所以多推一条不会把别人拽过去。
const Duration togetherHeartbeatInterval = Duration(seconds: 1);

/// 本地操作之后「乐观主导权」的有效时长（毫秒）。
///
/// 按下按钮那一刻本地就当自己是主导者（不跟别人的权威状态抢位置），
/// 但必须有时限：服务端没采纳（旧服务端 host_only / 房间已解散 /
/// 消息没发出去）时，到点要退回跟随，不能永久忽略别人的 room_state。
/// 700ms ≈ 一次往返 + 一帧，正常网络下服务端的 leaderId 早就回来了。
const int togetherOptimisticLeaderMs = 700;

/// 进度死区：小于该误差不调整，避免播放器/测量抖动导致反复变速。
const double togetherDriftDeadband = 0.4;

/// 超过该误差直接硬 seek；区间内用微调倍速追。
///
/// TOGETHER_OPEN_CONTROL（2026-11-15）：用户验收口径是「允许 ±2 秒误差，
/// 不要每次都硬 seek」。硬跳阈值从 1.5s 放宽到 2.0s —— 1.5~2.0s 这个区间
/// 交给 ±0.05x 的微调倍速慢慢追，观感上不跳，声音也不断。
const double togetherDriftSeek = 2.0;

/// 缓冲中放宽的硬跳阈值：6 秒以内一律不动，让它自己缓冲完。
const double togetherBufferingSeek = 6.0;

/// 微调倍速的步长：房主 1.0x 时成员在 0.95x / 1.05x 之间追。
const double togetherMicroRateStep = 0.05;

/// 硬 seek 后 2 秒内不再纠正，防止 seek 尚未落位又被下一次纠偏打断。
const int togetherSeekCooldownMs = 2000;

/// 成员硬 seek 错峰步长：第 i 位成员等 i * 200ms 再跳。
///
/// 房主拖动后所有成员会在同一帧收到同一份 room_state，如果同时硬 seek，
/// 就会同时去抢服务端 `/api/seg` 的首片中转槽位，抢不到的人被 302 降级
/// 成直连（首屏明显更慢）。按成员序号错开，槽位自然排队。
const int togetherSeekStaggerStepMs = 200;

/// 错峰上限：第 10 位之后统一等 2 秒，别让后排成员等到「已经不在乎」。
const int togetherSeekStaggerMaxMs = 2000;

/// 第 [index] 位成员硬 seek 的等待毫秒数（index 从 0 开始）。
int togetherSeekStaggerMs(int index) {
  if (index <= 0) return 0;
  final ms = index * togetherSeekStaggerStepMs;
  return ms > togetherSeekStaggerMaxMs ? togetherSeekStaggerMaxMs : ms;
}

/// 播放倍速允许范围（与房间 UI / 服务端一致）。
const double togetherMinRate = 0.25;
const double togetherMaxRate = 4.0;

/// 权威状态两次上报的间隔小于该值时，不足以判断房主是否卡住（心跳 9s、
/// 缓冲上报 1s，正常都在这个量级以上）。
const int togetherStallMinGapMs = 500;

/// 「真实后退」门槛：position 往回走超过该秒数才可能是房主拖动进度；
/// 小于它的回退一律视为房主端读数抖动（关键帧 / 段重载）。
const double togetherStallFrozenBand = 0.5;

/// 权威推进量低于 gap*rate 的该比例、且期望进度已经落后本地 → 房主在缓冲。
const double togetherStallAdvanceRatio = 0.5;

/// 房主缓冲期间成员落后多少就原地保持（暂停）而不是继续往前跑。
const double togetherStallHoldDrift = 1.5;

/// 保持期间落后回到该值以内就恢复播放（留 0.4s 死区，避免抖动式恢复）。
const double togetherStallResumeDrift = 0.4;

/// 房主停滞状态的最长保持时间：超时视为房主已断开，恢复正常外推。
const int togetherStallTimeoutMs = 15000;

/// 成员持续领先超过该时长、且超出硬 seek 阈值时，才允许往回跳。
const int togetherBackSeekPersistMs = 1500;

/// 时钟 offset 单次跳变超过该值时，先延长 seek 冷却吸收，不立刻纠偏。
const int togetherClockJumpGuardMs = 300;

/// 房主 position 读数持续回退超过该时长才如实上报（真实拖动进度）。
const int togetherHostBacktrackGraceMs = 5000;

/// Clock reset on disconnect freezes extrapolation at the old snapshot. That
/// frozen position is not a new authority seek; wait for both clock and rejoin.
bool togetherCanCorrectMember({
  required bool online,
  required bool connected,
  required bool clockSynced,
  required bool awaitingRoomState,
}) => online && connected && clockSynced && !awaitingRoomState;

/// Track movement rather than a lifetime high-water mark: a backward seek must
/// not look stalled until playback eventually catches the old position again.
bool togetherPositionMoved(int positionMs, int previousMs) =>
    (positionMs - previousMs).abs() > 20;

/// Hold is only a temporary playback override, never an override of a host
/// pause/seek. While held, periodic drift correction must not move the player.
bool togetherShouldStallHold({
  required bool holding,
  required bool playing,
  required bool authorityStalled,
  required double drift,
  bool authoritySeek = false,
  bool timedOut = false,
  bool seeking = false,
  bool buffering = false,
}) {
  if (!playing || authoritySeek) return false;
  if (holding) {
    return drift <= -togetherStallResumeDrift && !timedOut;
  }
  return authorityStalled &&
      drift <= -togetherStallHoldDrift &&
      !seeking &&
      !buffering;
}

enum TogetherSyncMove { none, rate, seek }

/// 权威 state 相对上一份状态的变化类型。
enum TogetherAuthorityChange {
  /// 正常推进 / 小幅抖动：交给常规纠偏处理。
  normal,

  /// 房主主动拖动进度（前拖或后拖）：成员直接对齐。
  seek,

  /// 房主卡在缓冲：position 停住而房间时钟照走，成员不回跳。
  stall,
}

class TogetherAuthorityVerdict {
  const TogetherAuthorityVerdict({
    required this.change,
    this.gapMs = 0,
    this.advance = 0,
    this.deviation = 0,
  });

  final TogetherAuthorityChange change;

  /// 两次权威上报之间的服务器时间差（毫秒）。
  final int gapMs;

  /// 权威 position 的实际推进量（秒）。
  final double advance;

  /// 权威 position 相对上一份状态外推值的偏差（秒，负 = 落后）。
  final double deviation;

  bool get isSeek => change == TogetherAuthorityChange.seek;
  bool get isStall => change == TogetherAuthorityChange.stall;
}

class TogetherSyncDecision {
  const TogetherSyncDecision.none()
      : move = TogetherSyncMove.none,
        rate = 1.0,
        target = 0;

  const TogetherSyncDecision.rate(this.rate)
      : move = TogetherSyncMove.rate,
        target = 0;

  const TogetherSyncDecision.seek(this.target)
      : move = TogetherSyncMove.seek,
        rate = 1.0;

  final TogetherSyncMove move;
  final double rate;
  final double target;
}

double togetherClampRate(double value) {
  if (!value.isFinite || value <= 0) return 1.0;
  return value.clamp(togetherMinRate, togetherMaxRate).toDouble();
}

/// 根据期望位置与本地位置的偏差决定下一步动作。
///
/// [playing] 为 false 时无法用倍速追进度，只会在误差超过硬 seek 阈值时跳一次；
/// [allowRate] 为 false 表示当前播放内核不支持足够精度的倍速微调，等下一次同步；
/// [allowBackwardSeek] 为 false 时禁止「往回跳」（成员领先的一侧）——负向误差
/// 先降速吸收，只有持续超出硬 seek 阈值（房主没在缓冲）才允许回跳。
TogetherSyncDecision decideTogetherDrift({
  required double expected,
  required double current,
  required bool playing,
  required double baseRate,
  bool allowRate = true,
  bool allowBackwardSeek = true,
  /// 本地正在缓冲（网络跟不上）：放宽硬跳、优先让它自然缓冲完。
  bool buffering = false,
}) {
  if (!expected.isFinite || !current.isFinite) {
    return const TogetherSyncDecision.none();
  }
  final drift = expected - current;
  // 缓冲中不硬跳：这时候 seek 只会让缓冲重新开始，越救越卡。
  // 双方网络不同时，慢的一方缓冲中必然落后，照常硬跳就是
  // 「跳过去 → 又卡 → 又跳」的循环。
  if (buffering && drift.abs() <= togetherBufferingSeek) {
    return const TogetherSyncDecision.none();
  }
  if (drift.abs() < togetherDriftDeadband) {
    return const TogetherSyncDecision.none();
  }
  if (drift.abs() > togetherDriftSeek) {
    // 负向（成员领先）默认也直接回跳；房主缓冲 / 读数回退等场景会关掉它，
    // 改成降速吸收，避免成员被反复拉回去。
    if (drift < 0 && !allowBackwardSeek) {
      if (playing && allowRate) {
        return TogetherSyncDecision.rate(
          togetherClampRate(baseRate - togetherMicroRateStep),
        );
      }
      return const TogetherSyncDecision.none();
    }
    return TogetherSyncDecision.seek(expected);
  }
  if (playing && allowRate) {
    final step = drift > 0 ? togetherMicroRateStep : -togetherMicroRateStep;
    return TogetherSyncDecision.rate(togetherClampRate(baseRate + step));
  }
  return const TogetherSyncDecision.none();
}

/// 由权威 state 推算当前服务器时刻应有的播放位置：
/// expect = position + (nowServerMs - serverTime)/1000 * rate。
double togetherExpectedPosition({
  required double position,
  required int serverTime,
  required int nowServerMs,
  required bool playing,
  required double rate,
}) {
  var value = position;
  if (playing && serverTime > 0 && nowServerMs > serverTime) {
    value += (nowServerMs - serverTime) / 1000.0 * togetherClampRate(rate);
  }
  if (!value.isFinite || value < 0) return 0;
  return value > 86400 ? 86400 : value;
}

/// 判断两份权威 state 之间发生了什么：正常推进 / 房主主动 seek / 房主卡缓冲。
///
/// 房主缓冲时 position 会停住（甚至因段重载、关键帧对齐小幅回退），而房间
/// 时钟 serverTime 照走；旧逻辑只要偏差 >0.5s 就当 seek 直接硬跳，于是房主
/// 卡一下成员就被拉回去一次。这里按「推进量」区分：
///
///  · position 明显前进或后退（>1.5s 偏差，且真的动了）→ seek；
///  · position 停住 / 慢推进、期望进度落后 → stall（房主在缓冲，成员别回跳）；
///  · 其余 → normal，交给常规纠偏。
TogetherAuthorityVerdict classifyTogetherAuthority({
  required double prevPosition,
  required int prevServerTime,
  required bool prevPlaying,
  required double prevRate,
  required double position,
  required int serverTime,
  required bool playing,
}) {
  const normal = TogetherAuthorityVerdict(
    change: TogetherAuthorityChange.normal,
  );
  if (prevServerTime <= 0 || serverTime <= 0) return normal;
  final gapMs = serverTime - prevServerTime;
  if (gapMs < 0) return normal;
  final gap = gapMs / 1000.0;
  final rate = togetherClampRate(prevRate);
  final expected = prevPosition + (prevPlaying ? gap * rate : 0);
  final deviation = position - expected;
  final advance = position - prevPosition;
  TogetherAuthorityVerdict verdict(TogetherAuthorityChange change) =>
      TogetherAuthorityVerdict(
        change: change,
        gapMs: gapMs,
        advance: advance,
        deviation: deviation,
      );

  // 暂停期间 position 只可能来自房主拖动：沿用 0.5s 阈值。
  if (!(prevPlaying && playing)) {
    return deviation.abs() > 0.5
        ? verdict(TogetherAuthorityChange.seek)
        : normal;
  }
  // 明显前拖。
  if (deviation > togetherDriftSeek) {
    return verdict(TogetherAuthorityChange.seek);
  }
  // 真实后退（房主往回拖 / 房主端确实回退过）：position 往回走了才算。
  if (deviation < -togetherDriftSeek && advance < -togetherStallFrozenBand) {
    return verdict(TogetherAuthorityChange.seek);
  }
  // 位置停住或慢推进、而期望进度已经落后 → 房主在缓冲。
  if (gapMs >= togetherStallMinGapMs &&
      advance < togetherStallAdvanceRatio * gap * rate &&
      deviation < -togetherDriftDeadband) {
    return verdict(TogetherAuthorityChange.stall);
  }
  return verdict(TogetherAuthorityChange.normal);
}

/// 判断新 state 是否代表房主主动 seek（而不是正常播放推进 / 心跳 / 缓冲）。
///
/// 只取 [classifyTogetherAuthority] 的 seek 结论；房主缓冲被判成 stall，
/// 不再当成 seek 去硬跳成员。
bool isTogetherSeekJump({
  required double prevPosition,
  required int prevServerTime,
  required bool prevPlaying,
  required double prevRate,
  required double position,
  required int serverTime,
  bool playing = true,
}) {
  return classifyTogetherAuthority(
    prevPosition: prevPosition,
    prevServerTime: prevServerTime,
    prevPlaying: prevPlaying,
    prevRate: prevRate,
    position: position,
    serverTime: serverTime,
    playing: playing,
  ).isSeek;
}

/// 时钟偏移（serverTime - 本地时间）。
class TogetherClock {
  int _offsetMs = 0;
  int _rttMs = 0;
  bool _ready = false;
  int _version = 0;
  int _lastOffsetDeltaMs = 0;

  int get offsetMs => _offsetMs;
  int get rttMs => _rttMs;
  bool get ready => _ready;

  /// 每次成功校准 +1，供上层发现「offset 台阶式变化」。
  int get version => _version;

  /// 最近一次校准相对上一次的 offset 变化量（首次 / reset 后为 0）。
  int get lastOffsetDeltaMs => _lastOffsetDeltaMs;

  int nowServerMs(int localMs) => localMs + _offsetMs;

  void update({required int offsetMs, required int rttMs}) {
    // 首次校准没有「上一次」可比，delta 记 0，避免把冷启动当成时钟跳变。
    final delta = _ready ? offsetMs - _offsetMs : 0;
    _offsetMs = offsetMs;
    _rttMs = rttMs < 0 ? 0 : rttMs;
    _ready = true;
    _lastOffsetDeltaMs = delta;
    _version++;
  }

  void reset() {
    _offsetMs = 0;
    _rttMs = 0;
    _ready = false;
    _version = 0;
    _lastOffsetDeltaMs = 0;
  }

  /// 中位数：样本为空时返回 0。
  static int median(List<int> values) {
    if (values.isEmpty) return 0;
    final sorted = List<int>.from(values)..sort();
    return sorted[sorted.length ~/ 2];
  }
}

/// 同一房间的 state 版本号（seq）去重：只接受更大的 seq。
class TogetherSeqGate {
  String _code = '';
  int _seq = -1;

  int get lastSeq => _seq;

  /// seq <= 0 视为服务端未提供版本号（兼容旧服务端），不做去重。
  bool accept(String code, int seq) {
    if (seq <= 0) return true;
    final sameRoom = code.isNotEmpty && code == _code;
    if (sameRoom && seq <= _seq) return false;
    _code = code;
    _seq = seq;
    return true;
  }

  void reset() {
    _code = '';
    _seq = -1;
  }
}

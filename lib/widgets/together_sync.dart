/* ========================================================================== */
/*  一起看 · 同步策略（纯 Dart，无 Flutter 依赖，方便单测）                     */
/*                                                                            */
/*  · 时钟：offset = serverTime - 本地中点，取 3 次 ping 的中位数；             */
/*  · 进度：expect = position + (now + offset - serverTime) / 1000；           */
/*  · 纠偏：< 0.4s 不动，0.4–1.5s 微调 ±0.05 倍速，> 1.5s 硬 seek 一次。       */
/* ========================================================================== */

/// 进度死区：小于该误差不调整，避免播放器/测量抖动导致反复变速。
const double togetherDriftDeadband = 0.4;

/// 超过该误差直接硬 seek；区间内用微调倍速追。
const double togetherDriftSeek = 1.5;

/// 微调倍速的步长：房主 1.0x 时成员在 0.95x / 1.05x 之间追。
const double togetherMicroRateStep = 0.05;

/// 硬 seek 后 2 秒内不再纠正，防止 seek 尚未落位又被下一次纠偏打断。
const int togetherSeekCooldownMs = 2000;

/// 播放倍速允许范围（与房间 UI / 服务端一致）。
const double togetherMinRate = 0.25;
const double togetherMaxRate = 4.0;

enum TogetherSyncMove { none, rate, seek }

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
/// [allowRate] 为 false 表示当前播放内核不支持足够精度的倍速微调，等下一次同步。
TogetherSyncDecision decideTogetherDrift({
  required double expected,
  required double current,
  required bool playing,
  required double baseRate,
  bool allowRate = true,
}) {
  if (!expected.isFinite || !current.isFinite) {
    return const TogetherSyncDecision.none();
  }
  final drift = expected - current;
  if (drift.abs() < togetherDriftDeadband) {
    return const TogetherSyncDecision.none();
  }
  if (drift.abs() > togetherDriftSeek) {
    return TogetherSyncDecision.seek(expected);
  }
  if (playing && allowRate) {
    final step = drift > 0 ? togetherMicroRateStep : -togetherMicroRateStep;
    return TogetherSyncDecision.rate(
      togetherClampRate(baseRate + step),
    );
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

/// 判断新 state 是否代表房主主动 seek（而不是正常播放推进 / 心跳）。
///
/// 正常心跳的 position 会随服务端时间前进；用上一份权威状态推算当前位置，
/// 只有明显偏离（>0.5s）才视为 seek，避免把心跳误判成跳转。
bool isTogetherSeekJump({
  required double prevPosition,
  required int prevServerTime,
  required bool prevPlaying,
  required double prevRate,
  required double position,
  required int serverTime,
}) {
  if (prevServerTime <= 0 || serverTime <= 0) return false;
  final elapsed = (serverTime - prevServerTime) / 1000.0;
  if (elapsed < 0) return false;
  final expected =
      prevPosition + (prevPlaying ? elapsed * togetherClampRate(prevRate) : 0);
  // 正常心跳的偏差只有几十毫秒；0.5s 以上视为房主主动 seek（含暂停时拖动）。
  return (position - expected).abs() > 0.5;
}

/// 时钟偏移（serverTime - 本地时间）。
class TogetherClock {
  int _offsetMs = 0;
  int _rttMs = 0;
  bool _ready = false;

  int get offsetMs => _offsetMs;
  int get rttMs => _rttMs;
  bool get ready => _ready;

  int nowServerMs(int localMs) => localMs + _offsetMs;

  void update({required int offsetMs, required int rttMs}) {
    _offsetMs = offsetMs;
    _rttMs = rttMs < 0 ? 0 : rttMs;
    _ready = true;
  }

  void reset() {
    _offsetMs = 0;
    _rttMs = 0;
    _ready = false;
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

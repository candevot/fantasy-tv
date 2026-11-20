/// 直播「追到窗口末端」的公共口径（LIVE_EDGE 2026-11-20）。
///
/// 用户口径（原话）：「直播要什么暂停按钮，刷新之后还是当前的，根本不是
/// 跟上跟不上进度，直播不同步」。拆成两条硬规则：
///
/// ① 直播**没有暂停**，也没有可拖动的进度条 —— 直播只有「现在」；
/// ② **只有用户点刷新（以及换线路 / 换台这种主动重开）才追到边缘**，
///    播着播着落后了就让它落后，软件不做任何自动跳转、不做定时位置检查。
///
/// 这里只放纯计算：不 import flutter，不碰播放器、不碰 UI，方便单测锁死
/// 「刷新后到底该落在哪个位置」这个唯一的口径。
library;

/// 刷新 / 重新 prepare 之后要落的位置：窗口末端前 3 秒。
///
/// 验收口径就是「刷新后位置在直播窗口末端 3 秒内」；留 3 秒而不是贴着末端，
/// 是因为贴死末端时内核还没缓冲到最后一两个分片，一落地就转圈。
const Duration fxLiveRefreshRewind = Duration(seconds: 3);

/// 追边允许的最小回退：2 秒（用户口径 2~3 秒，这里是下限）。
const Duration fxLiveEdgeMinRewind = Duration(seconds: 2);

/// 内核报的窗口时长未知（HLS live 的 duration 常为 0）时的兜底 seek 目标。
///
/// ExoPlayer 的 `seekTo` 会把目标钳进当前可播放窗口，所以「seek 到很大的数」
/// 等价于「seek 到窗口末端」—— 这也是原生侧唯一不新增通道就能追边的手段。
const Duration fxLiveSeekToEnd = Duration(days: 36500);

/// 当前位置落后直播末端多少（窗口时长未知 / 已越过末端时返回 0）。
Duration fxLiveLag({
  required Duration position,
  required Duration duration,
}) {
  if (duration <= Duration.zero) return Duration.zero;
  if (position >= duration) return Duration.zero;
  final lag = duration - position;
  return lag.isNegative ? Duration.zero : lag;
}

/// 追边的目标位置：窗口末端前 [rewind]。
///
/// 返回 null 表示「这次不该 seek」：窗口时长未知（duration == 0，交给
/// [fxLiveSeekToEnd] 兜底）或窗口短到回退之后没有意义。
Duration? fxLiveEdgeTarget(
  Duration duration, {
  Duration rewind = fxLiveRefreshRewind,
}) {
  if (duration <= Duration.zero) return null;
  final target = duration - rewind;
  if (target <= Duration.zero) return null;
  return target;
}

/// 当前位置是否已经贴着直播末端（容差默认 3 秒 = 验收口径）。
bool fxLiveIsAtEdge({
  required Duration position,
  required Duration duration,
  Duration tolerance = fxLiveRefreshRewind,
}) {
  if (duration <= Duration.zero) return false;
  return fxLiveLag(position: position, duration: duration) <= tolerance;
}

/// 探针日志：`[FxLive] refresh pos=12.0s end=30.0s lag=18.0s seek=27.0s ...`
///
/// 格式固定成一行、字段固定顺序，真机上 `adb logcat | grep FxLive` 就能直接
/// 核对「刷新之后到底落在哪一帧」，也方便回归测试逐字比对。
String fxLiveProbeLog({
  required String event,
  required Duration position,
  required Duration duration,
  Duration? target,
  String reason = '',
}) {
  String s(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
  final lag = fxLiveLag(position: position, duration: duration);
  final buffer = StringBuffer('[FxLive] $event')
    ..write(' pos=${s(position)}')
    ..write(' end=${s(duration)}')
    ..write(' lag=${s(lag)}')
    ..write(' seek=${target == null ? 'none' : s(target)}');
  if (reason.isNotEmpty) buffer.write(' reason=$reason');
  return buffer.toString();
}

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

// ---------------------------------------------------------------------------
// FULLSCREEN_SWITCH（2026-11-21）：竖屏 ↔ 全屏的画面层交接
// ---------------------------------------------------------------------------
//
// 现场：直播页点全屏 → 黑屏 / 转圈；全屏退回竖屏 → 画面不动，必须退出重进
// 才恢复。根因不在「重新 prepare」，而在**画面层被挂了两块**：
//
//   · 原生 `ExoPlayerPlugin.createView()` 只维护一块 `videoView`，每建一块
//     ExoView 就 `player.setVideoTextureView(新的那块)`；
//   · `ExoView.dispose()` → `detachView(tv)`，只有 `videoView === tv` 时才
//     `clearVideoSurface()`，并把 `videoView` 置空。
//
// 所以竖屏页把自己的画面层留在树上、全屏页又挂一块时：进全屏 = 输出被抢到
// 新的一块；退全屏 = 全屏那块 dispose 时把整条视频输出清掉，而竖屏那块
// 从头到尾没重建过，不会再去 `setVideoTextureView` —— 播放器从此没有输出面，
// 声音还在走、位置还在动，画面就是黑的。
//
// 规则只有一条，和点播页（player_page.dart 的 `_fullscreenActive`）完全一致：
// **任何时刻只允许一块画面层在树上**。点播全屏行为不动，这里只管直播。

/// 直播页要不要挂自己的画面层。
///
/// [fullscreenActive] 为 true（全屏路由在顶层）时必须返回 false：
/// 画面交给全屏页那一块，竖屏这块先摘掉，原生才会把输出面干净地交接过去。
bool fxLiveSurfaceVisible({
  required bool hasPlayer,
  required bool ready,
  required bool fullscreenActive,
}) =>
    hasPlayer && ready && !fullscreenActive;

/// 切页后多久做一次画面健康检查。
///
/// 只查**一次**：这是「交接有没有接上」的自检，不是定时追平。位置在走就
/// 什么都不做 —— 直播播着落后就让它落后（用户口径，见文件头）。
const Duration fxLiveSurfaceCheckDelay = Duration(seconds: 4);

/// 画面是否已经断了：位置在 [tolerance] 内没有推进，且内核没在缓冲。
///
/// 缓冲中不判死：HLS live 换分片时位置本来就会停一下，这时候 seek 反而
/// 把用户从「马上就要出画」打到「重新缓冲」。
bool fxLivePictureDead({
  required Duration before,
  required Duration after,
  required bool isBuffering,
  Duration tolerance = const Duration(milliseconds: 400),
}) {
  if (isBuffering) return false;
  return after - before <= tolerance;
}

/// 交接探针：`[FxLive] switch phase=enter fs=on surface=off playing=true ...`
///
/// phase：enter（进全屏）/ exit（退全屏）/ recover（接不上，落回直播边缘）。
/// 真机上 `adb logcat | grep FxLive` 一行就能看清「谁挂着画面层、在不在播、
/// 离直播末端多远」，作为「切换后仍在直播边缘并播放」的验收证据。
String fxLiveSwitchLog({
  required String phase,
  required bool fullscreen,
  required bool surfaceMounted,
  required bool playing,
  required Duration position,
  required Duration duration,
  String reason = '',
}) {
  String s(Duration d) => '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
  final buffer = StringBuffer('[FxLive] switch phase=$phase')
    ..write(' fs=${fullscreen ? 'on' : 'off'}')
    ..write(' surface=${surfaceMounted ? 'on' : 'off'}')
    ..write(' playing=${playing ? 'yes' : 'no'}')
    ..write(' pos=${s(position)}')
    ..write(' end=${s(duration)}')
    ..write(' lag=${s(fxLiveLag(position: position, duration: duration))}');
  if (reason.isNotEmpty) buffer.write(' reason=$reason');
  return buffer.toString();
}

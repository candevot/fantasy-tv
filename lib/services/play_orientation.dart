import 'dart:async';

/// 全屏播放的目标方向。
///
/// 纯自动判断：按视频自身分辨率定，没有「强制横屏 / 强制竖屏」这种设置项。
/// 用户想临时换方向，点全屏顶栏的转屏按钮即可（切完本次播放不再自动切）。
enum FxPlayOrientation {
  landscape,
  portrait;

  bool get isPortrait => this == FxPlayOrientation.portrait;
}

/// 视频自身分辨率 → 播放方向。
///
/// - `height > width`：竖屏片（竖版短剧 / 竖屏微短剧）→ [portrait]
/// - `width > height`：常规横屏片 → [landscape]
/// - 宽高缺失（0 / null）或正好方形：返回 null，保持现状不切
///
/// 宽高一律用「显示用尺寸」（原生已按 rotate 元数据交换），与用户看到的画面
/// 方向一致；ExoPlayer 的 `onVideoSizeChanged` 与 mpv 两条路径都会换算好。
FxPlayOrientation? fxOrientationForSize(int? width, int? height) {
  final w = width ?? 0;
  final h = height ?? 0;
  if (w <= 0 || h <= 0) return null;
  if (h > w) return FxPlayOrientation.portrait;
  if (w > h) return FxPlayOrientation.landscape;
  return null;
}

/// 拿不到分辨率 / 正好方形时的兜底方向。
///
/// 默认横屏：与改这版之前的行为一致，不会让老片子突然变成竖屏。
FxPlayOrientation fxResolvePlayOrientation({
  int? width,
  int? height,
  FxPlayOrientation fallback = FxPlayOrientation.landscape,
}) {
  return fxOrientationForSize(width, height) ?? fallback;
}

/// 分辨率 → 防抖后的方向决策。
///
/// 为什么需要它：ExoPlayer 的 `onVideoSizeChanged` 可能先给 0×0、再给
/// 1080×1920，切线路 / 切集时还会再给一次；直接跟着切会让画面横竖乱翻。
/// 这里只在「宽高都 > 0 且连续 [stable] 保持同一个值」之后回调一次，
/// 目标方向没变不再回调，所以不会来回抖。
///
/// 用法：
/// ```dart
/// final debouncer = FxPlayOrientationDebouncer(onResolve: apply);
/// debouncer.settleNow(w, h);            // 尺寸已经知道时先定一次
/// debouncer.update(w, h);               // 播放中每次尺寸变化
/// debouncer.force(FxPlayOrientation.portrait); // 用户手动切过 → 冻结
/// ```
class FxPlayOrientationDebouncer {
  FxPlayOrientationDebouncer({
    required this.onResolve,
    this.stable = const Duration(milliseconds: 300),
  });

  /// 方向确定后回调（只在方向真的变了时触发）。
  final void Function(FxPlayOrientation target) onResolve;

  /// 稳定窗口：同一个分辨率保持这么久才认。
  final Duration stable;

  Timer? _timer;

  /// 当前在等的那组值（用来判断「同一个值在等」还是「值变了要重排」）。
  String _pendingKey = '';

  /// 每次值变化 +1；定时器回调按 token 丢弃过期结果。
  int _token = 0;

  int _width = 0;
  int _height = 0;

  /// 上一次真正生效的「尺寸」组合：同样的值再进来直接返回，
  /// 不因为播放器每秒通知一次就反复开定时器。
  String _settledKey = '';

  /// 已经通知出去的方向；null = 还没定过。
  FxPlayOrientation? _applied;

  /// 用户已手动接管：为 true 时 [update] / [settleNow] 不再产出结论。
  bool _frozen = false;

  /// 已经生效的方向（null 表示还没定过）。
  FxPlayOrientation? get applied => _applied;

  /// 是否有等待中的防抖窗口。
  bool get pending => _timer != null;

  /// 是否已被 [force] 冻结（用户手动接管后为 true）。
  bool get frozen => _frozen;

  /// 播放中拿到新分辨率：等稳定后再定方向。
  ///
  /// [width] / [height] 任一 ≤ 0 直接忽略（0×0 先到的场景），
  /// 不取消已有的等待，等真实值来覆盖。
  void update(int? width, int? height) {
    if (_frozen) return;
    final w = width ?? 0;
    final h = height ?? 0;
    if (w <= 0 || h <= 0) return;
    final key = '${w}x$h';
    // 同一个值还在等：不重置定时器，否则一直刷新就永远定不下来。
    if (key == _pendingKey && _timer != null) return;
    // 这个尺寸已经生效过：不用再排一次（播放器状态每秒都在通知）。
    if (key == _settledKey) return;
    _pendingKey = key;
    _width = w;
    _height = h;
    final token = ++_token;
    _timer?.cancel();
    _timer = Timer(stable, () {
      if (token != _token) return;
      _timer = null;
      _emit(fxResolvePlayOrientation(width: w, height: h));
    });
  }

  /// 立即定一次，不进防抖窗口。
  ///
  /// 进全屏时竖屏页已经把真实分辨率交过来了，这时不该再等 300ms 才转
  /// （用户会先看到一个方向不对的画面）。同样是「方向没变就不回调」。
  void settleNow(int? width, int? height) {
    if (_frozen) return;
    final w = width ?? 0;
    final h = height ?? 0;
    if (w <= 0 || h <= 0) return;
    _timer?.cancel();
    _timer = null;
    _pendingKey = '${w}x$h';
    _width = w;
    _height = h;
    _token++;
    _emit(fxResolvePlayOrientation(width: w, height: h));
  }

  /// 用户手动切过方向：记下 [target] 并**冻结**自动判断。
  ///
  /// 冻结之后 [update] / [settleNow] 都直接返回，无论后面拿到什么分辨率，
  /// 本次播放都不会再把方向扳回去 —— 与页面上的「用户已手动干预」标志是
  /// 同一层保护，双保险。
  void force(FxPlayOrientation target) {
    _timer?.cancel();
    _timer = null;
    _pendingKey = '';
    _settledKey = '';
    _token++;
    _applied = target;
    _frozen = true;
  }

  /// 解除 [force] 的冻结：需要重新交给自动判断时用，下一次 [update] 重新判。
  void unfreeze() {
    _frozen = false;
    _pendingKey = '';
    _settledKey = '';
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  void _emit(FxPlayOrientation target) {
    _settledKey = _pendingKey;
    if (target == _applied) return;
    _applied = target;
    onResolve(target);
  }
}

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import '../services/fx_display_settings.dart';
import '../services/fx_player.dart';
import '../services/fx_video_geometry.dart';
import '../theme.dart';

/// 播放器通用小工具：时间格式、进度持久化、白玻璃控件。
String fxPad2(int n) => n.toString().padLeft(2, '0');

/// 切后台 / inactive / paused 一律不暂停（全 App 统一）：系统切后台、来电等
/// 场景由系统音频策略处理，App 层不再用超时定时器断播。
/// 续播门槛：上次进度不足 60 秒时从头播，避免把「片头 20 秒」误当成续播。
const double fxResumeMinSeconds = 60;

/// 片尾判定窗口：距结尾不足这么多秒，就认为「这集已经看完了」，进度归零。
///
/// 原来是写死的 1.5 秒，太小了 —— 用户在最后几十秒退出（看片尾曲、
/// 等字幕、手动退出），进度会被存成「距结尾 43 秒」，下次打开直接从
/// 那里开始播，用户看到的就是「一打开就是片尾曲、总共只有 43 秒」。
///
/// 现在按「距结尾 90 秒以内算看完」处理。一集 40 分钟以上的剧，
/// 最后 90 秒基本就是片尾曲 / 下集预告，重看这一段没有意义。
const double fxEndingWindowSeconds = 90;

/// 判断某个播放位置是否已经算「看完」（应当把进度归零）。
bool fxIsFinishedPosition(double positionSeconds, double durationSeconds) {
  if (durationSeconds <= 0) return false;
  return positionSeconds >= durationSeconds - fxEndingWindowSeconds;
}

/// 控件无操作后自动隐藏：参考实现 5000ms（PlayerControllerImpl）。
const Duration kPlayerControlsAutoHide = Duration(seconds: 5);

/// 双击判定窗口：参考 300ms。与 Flutter 内置的 kDoubleTapTimeout 一致，
/// 播放器手势层按这个窗口自判，避免单击显隐被系统双击识别拖慢。
const Duration kPlayerDoubleTapWindow = Duration(milliseconds: 300);

/// 锁定屏幕后解锁钮自动隐藏时长：参考 3000ms（LayoutLockVolume）。
const Duration kPlayerUnlockAutoHide = Duration(seconds: 3);

/// 长按临时倍速：libmpv 内核按参考实现取 3.0x（IJK / 阿里内核才是 2.0x）。
const double kPlayerHoldRate = 3.0;

/// 预告 / 花絮 / 拉片 / 解说这类片段单独占一集，但不是正片。
const List<String> fxExtraEpisodeKeys = <String>['预告', '花絮', '拉片', '解说'];

bool fxIsExtraEpisode(String name) {
  final s = name.trim();
  if (s.isEmpty) return false;
  return fxExtraEpisodeKeys.any(s.contains);
}

/// 正片集数：不把预告 / 花絮 / 拉片 / 解说算进去。
int fxMainEpisodeCount(Iterable<Episode> episodes) =>
    episodes.where((e) => !fxIsExtraEpisode(e.name)).length;

/// 集名规范化：
/// - 空名或不是「第N集」形式 → 统一显示「第N集」；
/// - 预告 / 花絮 / 拉片 / 解说 → 原名前 8 字 + 序号（如「拉片 2」）。
/// 电影的多条是「正片 / 普通话版 / 粤语版」这类**版本**，不是集。
/// 这些名字要原样显示，不能被改写成「第01集」。
const List<String> _fxVersionWords = <String>[
  '正片',
  '普通话',
  '普通话版',
  '国语',
  '国语版',
  '粤语',
  '粤语版',
  '原声',
  '原声版',
  '中字',
  '中字版',
  '高清',
  '蓝光',
  'TC',
  'HD',
  '4K',
];

String fxEpisodeLabel(int ep, [String? name]) {
  final s = (name ?? '').trim();
  if (s.isEmpty) return '第${fxPad2(ep)}集';
  if (_fxVersionWords.contains(s)) return s;
  if (fxIsExtraEpisode(s)) {
    final head = s.characters.take(8).toString().trim();
    return '$head $ep';
  }
  return '第${fxPad2(ep)}集';
}

String fxTime(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  if (h > 0) return '$h:${fxPad2(m)}:${fxPad2(s)}';
  return '${fxPad2(m)}:${fxPad2(s)}';
}

String fxClock(DateTime t) => '${fxPad2(t.hour)}:${fxPad2(t.minute)}';

/// 缓冲比例文案（0–100 的真实值）：`42%` / `<1%` / `100%`。
///
/// BUFFER_PCT_REAL（2026-11-14）：别再四舍五入成 0% / 99% —— 4K 长片刚
/// 起播时 buffered/duration 往往不到 1%，直接 round 会显示「缓冲中 0%」，
/// 看起来像坏掉的假进度。小于 1% 一律显示 `<1%`。
String fxPercentLabel(double percent) {
  final p = percent.isFinite ? percent.clamp(0.0, 100.0).toDouble() : 0.0;
  if (p >= 100) return '100%';
  if (p > 0 && p < 1) return '<1%';
  return '${p.round()}%';
}

/// 实时网速文案：`1.8 MB/s` / `320 KB/s` / `0 KB/s`。
///
/// BUFFER_UI（2026-11-15）：0 必须显示「0 KB/s」，不能返回空串、也不能
/// 留着上一个数 —— 用户是靠这一行判断「还在不在下」，藏着只会让他以为卡死。
String fxSpeedLabel(double bytesPerSecond) {
  final b = bytesPerSecond.isFinite && bytesPerSecond > 0
      ? bytesPerSecond
      : 0.0;
  if (b <= 0) return '0 KB/s';
  if (b >= 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB/s';
  if (b >= 1024) return '${(b / 1024).round()} KB/s';
  return '<1 KB/s';
}

/// 缓冲层标题：拿不到真实比例就说「缓冲中…」，绝不编数字。
String fxBufferingText(double? percent) {
  if (percent == null) return '缓冲中…';
  return '缓冲中 ${fxPercentLabel(percent)}';
}

/// 真实分辨率文案：`宽x高`（如 `1920x1080` / `720x480`）。
///
/// 宽或高任一缺失、≤0 时返回空串（胶囊自动隐藏）；
/// 不做分档，低于 1080P 的老片也照常显示。
String fxResolutionText(int? width, int? height) {
  final w = width ?? 0;
  final h = height ?? 0;
  if (w <= 0 || h <= 0) return '';
  return '${w}x$h';
}

/// 顶栏唯一的画质胶囊文案：取播放器真实视频宽高拼成 `宽x高`，未就绪时为空。
String fxPlayerQuality(FxPlayer? player) {
  final value = player?.value;
  if (value == null || !value.isInitialized) return '';
  final width = (value.videoWidth ?? 0) > 0 ? value.videoWidth : value.width;
  final height = (value.videoHeight ?? 0) > 0
      ? value.videoHeight
      : value.height;
  return fxResolutionText(width, height);
}

/// 字幕距播放器底部的安全距离：至少 96dp，始终高过底部控件区。
const double fxSubtitleMinBottom = 96;

/// 画面比例档位 → BoxFit：
/// - 适应 / 填充 / 拉伸 → contain / cover / fill；
/// - 16:9 / 4:3 / 1:1 固定比例档 → 框内裁满（外圈黑边交给 [fxAspectFrame]）。
BoxFit fxAspectFit(FxAspectMode mode) => switch (mode) {
  FxAspectMode.contain => BoxFit.contain,
  FxAspectMode.cover => BoxFit.cover,
  FxAspectMode.fill => BoxFit.fill,
  _ => BoxFit.cover,
};

/// 固定比例档外框：按目标比例居中裁出一个框（框内画面裁满），
/// 框外留黑边；适应 / 填充 / 拉伸三档原样返回，交给 BoxFit 处理。
Widget fxAspectFrame(FxAspectMode mode, Widget child) {
  final ratio = mode.frameRatio;
  if (ratio == null) return child;
  return Container(
    color: Colors.black,
    alignment: Alignment.center,
    child: ClipRect(
      child: AspectRatio(aspectRatio: ratio, child: child),
    ),
  );
}

/// 镜像包装：默认档原样返回，水平 / 垂直镜像用 Transform.flip 翻转画面。
Widget fxMirrorWrap(FxMirrorMode mode, Widget child) {
  if (mode == FxMirrorMode.none) return child;
  return Transform.flip(flipX: mode.flipX, flipY: mode.flipY, child: child);
}

/// 静态画面（切集 / 切线路的冻结帧）按当前画面比例与镜像档位渲染，
/// 与 [FxPlayerSurface] 共用同一套裁切与翻转，改档立即生效。
///
/// [child] 里要按传入的 [BoxFit] 配置子内容，保证与视频同一档适配。
class FxAspectBox extends StatelessWidget {
  const FxAspectBox({super.key, required this.child});

  final Widget Function(BuildContext context, BoxFit fit) child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: FxDisplaySettings.instance,
      builder: (context, _) {
        final aspect = FxDisplaySettings.instance.aspect;
        final mirror = FxDisplaySettings.instance.mirror;
        return fxMirrorWrap(
          mirror,
          fxAspectFrame(aspect, child(context, fxAspectFit(aspect))),
        );
      },
    );
  }
}

/// 播放器画面：按「画面比例 / 镜像模式」当前档位渲染，切档立即生效（不重载），
/// 并把字幕抬到控件区上方。
///
/// [subtitleBottom] 必须不小于 [fxSubtitleMinBottom]；全屏时传
/// 「底部控件高度 + 安全间距」，避免字幕被进度条/按钮盖住。
class FxPlayerSurface extends StatefulWidget {
  const FxPlayerSurface({
    super.key,
    required this.player,
    this.subtitleBottom = fxSubtitleMinBottom,
  });

  final FxPlayer player;
  final double subtitleBottom;

  @override
  State<FxPlayerSurface> createState() => _FxPlayerSurfaceState();
}

class _FxPlayerSurfaceState extends State<FxPlayerSurface> {
  int _renderEpoch = 0;

  /// 最近一次拿到的**真实**视频宽高比。
  ///
  /// 粘住的理由（ASPECT_NO_FLICKER 2026-11-15）：切集 / 换线时播放器会把
  /// 宽高清成 null，再重新上报。如果这里跟着退回 16:9，容器会「16:9 → 真实
  /// 比例」跳一次 —— 竖屏短剧就是肉眼可见的一下闪跳。所以只有拿到新的真实
  /// 宽高才更新，拿不到就一直用上一次的值；从来没拿到过才退回 16:9。
  double _videoRatio = kFxFallbackVideoAspect;

  /// 只接受真实宽高；返回是否真的变了。
  bool _syncVideoRatio() {
    final v = widget.player.value;
    final real =
        fxVideoAspectOf(v.width, v.height) ??
        fxVideoAspectOf(v.videoWidth, v.videoHeight);
    if (real == null || !real.isFinite || real <= 0) return false;
    if ((real - _videoRatio).abs() < 0.001) return false;
    _videoRatio = real;
    return true;
  }

  // 放在共享画面层处理，普通播放、直播、离线和一起看都不会漏接。
  void _onPlayerChanged() {
    if (!mounted) return;
    final epoch = widget.player.renderEpoch;
    // 比例变化也要重建：容器 / 画面框的尺寸就是按它算的。
    final ratioChanged = _syncVideoRatio();
    if (epoch == _renderEpoch && !ratioChanged) return;
    setState(() => _renderEpoch = epoch);
  }

  @override
  void initState() {
    super.initState();
    FxDisplaySettings.instance.addListener(_onSettingsChanged);
    widget.player.addListener(_onPlayerChanged);
    _renderEpoch = widget.player.renderEpoch;
    _syncVideoRatio();
    // 幂等：读回已保存的画面比例 / 镜像档位，读完会再通知一次。
    unawaited(FxDisplaySettings.instance.ensureLoaded());
  }

  @override
  void didUpdateWidget(covariant FxPlayerSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.player, widget.player)) return;
    oldWidget.player.removeListener(_onPlayerChanged);
    widget.player.addListener(_onPlayerChanged);
    _renderEpoch = widget.player.renderEpoch;
    // 换播放器（换片 / 换集新建实例）：先看新实例是否已有真实宽高，
    // 没有就保持上一次的比例，避免闪跳。
    _syncVideoRatio();
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    FxDisplaySettings.instance.removeListener(_onSettingsChanged);
    widget.player.removeListener(_onPlayerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = FxDisplaySettings.instance;
    final aspect = settings.aspect;
    final mirror = settings.mirror;
    // 画面由 PlatformView 承载（ExoPlayer 的 TextureView，MATCH_PARENT）。
    // 换成 ExoPlayer 之后没有再「往纹理里写字幕」这回事：硬字幕是画面像素的
    // 一部分，镜像时会跟着翻；独立软字幕轨由 PlayerView 自己渲染。
    // 原来的 mpv sub-visibility / FxMirrorSubtitle 那一套随之去掉。
    final fit = fxAspectFit(aspect);
    // ASPECT_REAL（2026-11-15）：画面比例由 Flutter 侧几何决定，原生不再
    // 参与 —— 所以切档**不需要**重建 PlatformView（以前按档位换 key，
    // 每次改「适应 / 填充 / 拉伸」都要重新挂一次纹理，用户看到的就是黑一下）。
    final surface = widget.player.buildVideo(fit: fit);
    // MIRROR_NATIVE（2026-11-14）：镜像不能再用 Transform.flip 包 PlatformView。
    // 混合合成下原生视图不跟随 Flutter 变换，翻不了（或翻一下就错位）。
    // 改成下发到原生，翻 PlayerView 自己的 scaleX/scaleY。
    widget.player.setMirror(flipX: mirror.flipX, flipY: mirror.flipY);
    // 注意：这里**不能**再包一层 [fxMirrorWrap] —— 镜像已经下发到原生
    // （见上），Transform 对混合合成的原生视图不生效，包上反而会错位。
    // 冻结帧那层（[FxAspectBox]）是纯 Flutter 绘制，才需要自己翻。
    return FxVideoStage(mode: aspect, videoRatio: _videoRatio, child: surface);
  }
}

/// 播放画面几何：把原生画面摆进一个「比例正确」的框里。
///
/// 为什么必须在 Flutter 侧算：Android 那个 PlatformView 就是一块
/// MATCH_PARENT 的 TextureView（`ExoPlayerPlugin.kt` 的 `ExoView`），它只把
/// 视频纹理**铺满自己占的位置**，完全不看视频宽高比 —— 谁把它摆成多大，
/// 画面就被拉成多大。所以「不变形」的唯一办法是：框的实际宽高比 = 视频
/// 真实宽高比（见 [fxFitSize]）。
///
/// 三档语义：
/// - [FxAspectMode.contain]（默认「适应」）：等比放大到完整放进容器，留黑边；
/// - [FxAspectMode.cover]（「填充」）：等比放大到盖住容器，超出部分裁掉，
///   **不改变比例**；
/// - [FxAspectMode.fill]（「拉伸」）：直接铺满容器，会变形 —— 只有用户主动
///   选它才这样。
/// - 16:9 / 4:3 / 1:1 固定比例档：先把容器框成目标比例（框外黑边），
///   视频在框内按「填充」裁满，和改版前的语义一致。
class FxVideoStage extends StatelessWidget {
  const FxVideoStage({
    super.key,
    required this.mode,
    required this.videoRatio,
    required this.child,
  });

  /// 当前画面比例档位（全局设置）。
  final FxAspectMode mode;

  /// 视频真实宽高比；拿不到时传 [kFxFallbackVideoAspect]。
  final double videoRatio;

  /// 画布本体（原生画面 / 冻结帧）。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final maxHeight = constraints.maxHeight;
        // 尺寸还没定（无限宽 / 无限高，比如塞进列表里）：不猜，原样交回去。
        if (!maxWidth.isFinite ||
            !maxHeight.isFinite ||
            maxWidth <= 0 ||
            maxHeight <= 0) {
          return child;
        }
        final container = Size(maxWidth, maxHeight);
        final frame = mode.frameRatio;
        final Size box;
        if (frame == null) {
          // 适应 / 填充 / 拉伸：直接按视频比例算框。
          box = fxFitSize(container, videoRatio, fxAspectFit(mode));
        } else {
          // 固定比例档：先框成目标比例，再让视频在框内裁满（不变形）。
          final framed = fxFitSize(container, frame, BoxFit.contain);
          box = fxFitSize(framed, videoRatio, BoxFit.cover);
        }
        if (!box.width.isFinite || !box.height.isFinite) return child;
        if (box.width <= 0 || box.height <= 0) return child;
        // OverflowBox：填充档的框比容器大，必须让它按真实尺寸排出去，
        // 否则 SizedBox 会被父约束夹回容器尺寸 —— 那又变形了。
        // 多出来的部分由外层 ClipRect 裁掉。
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.center,
            minWidth: 0,
            maxWidth: double.infinity,
            minHeight: 0,
            maxHeight: double.infinity,
            child: SizedBox.fromSize(size: box, child: child),
          ),
        );
      },
    );
  }
}

String fxProgressKey(String videoId, int ep) => 'pos_${videoId}_$ep';

Future<double> fxLoadProgress(String videoId, int ep) async {
  try {
    final sp = await SharedPreferences.getInstance();
    final v = sp.getDouble(fxProgressKey(videoId, ep));
    if (v == null || v.isNaN || v.isInfinite || v < 0) return 0;
    return v;
  } catch (_) {
    return 0;
  }
}

Future<void> fxSaveProgress(String videoId, int ep, double seconds) async {
  if (seconds.isNaN || seconds.isInfinite) return;
  try {
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble(fxProgressKey(videoId, ep), seconds < 0 ? 0 : seconds);
  } catch (_) {
    // 本地存储失败不影响播放
  }
}

/// 白玻璃提示，不抢播放器控件的焦点
void fxToast(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        message,
        style: const TextStyle(
          color: Fx.ink,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
      backgroundColor: Colors.white.withValues(alpha: .96),
      elevation: 4,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(18, 0, 18, 18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      duration: const Duration(seconds: 2),
    ),
  );
}

/// 续播不弹任何提示：静默 seek 回上次位置（见播放页 / 全屏页），
/// 播放期间不允许有遮挡画面的浮层文案。

/* ---------------------------------------------------------------- 全屏控件规格 */

/// FS_ICON_SPEC（2026-11-15）：全屏播放器里**所有**圆形按钮的唯一规格。
///
/// 用户报的原话：「有的图标有圆底气泡，有的没有」—— 原因是各个控件各自传
/// size / iconSize / tint：返回 34、转屏 32、投屏 32、锁 42、快进 44、
/// 底栏播放 34，底色 .16 / .18 混着来。同一层级看着就是两套设计。
///
/// 现在全部走 [PGlassIcon.fs]（就是下面这几个数），改规格只改这一处：
///   · 玻璃底直径 30dp（圆角 15dp），图标 19.5dp；
///   · 底色 `Colors.white × .13`，描边 `white × .32`，投影与原来一致；
///   · 热区 44dp（视觉不变，只有命中框放大，`hitSize` 机制）；
///   · 文字胶囊 / 状态胶囊与圆底**同高同圆角**（30dp / r15），见 [PGlassPill]。
const double kFsControlSize = 30;
const double kFsControlGlyph = 19.5;
const double kFsControlHit = 44;
const double kFsControlTint = .13;
const double kFsPillHeight = kFsControlSize;
const double kFsPillRadius = kFsPillHeight / 2;

/// 播放器圆形玻璃按钮
class PGlassIcon extends StatelessWidget {
  const PGlassIcon({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 38,
    this.iconSize = 20,
    this.active = false,
    this.tooltip,
    this.tint = .14,
    this.iconColor = Colors.white,
    this.hitSize = 0,
  });

  /// 全屏控件的统一规格（见 [kFsControlSize] 那一组常量）。
  ///
  /// 只开放 icon / onTap / active / tooltip：尺寸和底色不给调用方改，
  /// 「统一」才是硬的。
  const PGlassIcon.fs({
    super.key,
    required this.icon,
    this.onTap,
    this.active = false,
    this.tooltip,
    this.iconColor = Colors.white,
  })  : size = kFsControlSize,
        iconSize = kFsControlGlyph,
        tint = kFsControlTint,
        hitSize = kFsControlHit;

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final bool active;
  final String? tooltip;
  final double tint;
  final Color iconColor;

  /// 最小点击热区（dp）。0 = 跟视觉尺寸一致（主播放页保持原样）。
  ///
  /// TOGETHER_TAP44（2026-11-15）：一起看视频区里的按钮视觉只有 30dp，
  /// 手指点上去经常落空。这里只放大**不可见**的命中框，视觉圆钮尺寸不变，
  /// 所以主播放页与一起看看起来完全一样，只是一起看更好点。
  final double hitSize;

  @override
  Widget build(BuildContext context) {
    final button = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: active
              ? Fx.accent.withValues(alpha: .82)
              : Colors.white.withValues(alpha: tint),
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white.withValues(alpha: .32),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .10),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Icon(icon, size: iconSize, color: iconColor),
      ),
    );
    // 命中框放大：只改可点区域，不改视觉尺寸（布局高度会跟着热区走，
    // 所以调用方要确认这一行够高 —— 一起看的视频区控件行按 44 排）。
    final hit = hitSize > size ? hitSize : size;
    final sized = SizedBox(
      width: hit,
      height: hit,
      child: Center(child: button),
    );
    if (tooltip == null) return sized;
    return Tooltip(message: tooltip!, child: sized);
  }
}

/// 白玻璃胶囊（电量 / 时间 / 信息 / 画质 / 文字按钮）
///
/// PILL_ALIGN（2026-11-15）：胶囊的**高度与圆角跟圆形图标底对齐** ——
/// 30dp 高、15dp 圆角（= 30/2，视觉上就是「胶囊两端是半圆」）。
/// 原来是内容撑高（≈26dp）+ 圆角 20，和 30dp 的圆钮并排时中间差 4dp，
/// 一排控件看着就是高低不齐。
class PGlassPill extends StatelessWidget {
  const PGlassPill({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 10),
    this.height = kFsPillHeight,
    this.tint = kFsControlTint,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  /// 胶囊高度（默认与圆形底同高 30dp）；传 0 表示按内容撑高（旧行为）。
  final double height;

  /// 底色透明度，默认与圆形底一致 .13。
  final double tint;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      height: height <= 0 ? null : height,
      padding: padding,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: tint),
        borderRadius: BorderRadius.circular(
          height <= 0 ? 20 : height / 2,
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: .32),
          width: 1,
        ),
      ),
      child: child,
    );
    if (onTap == null) return box;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: box,
    );
  }
}

/// 一起看等拿不到线路信息的场景沿用的产品名（播放页已改用真实线路名）。
const String fxPlayerBrand = '幻想腾讯4K';

/// 「正在加载 幻想腾讯4K 第03集」（仅一起看等无线路名场景使用）
String fxLoadingEpisodeText(int ep) =>
    '正在加载 $fxPlayerBrand ${fxEpisodeLabel(ep)}';

/// 播放器加载文案：线路名必须来自本次请求的 lineId，取不到时省略线路名。
/// 「正在加载 幻想蓝光 · 第01集」/「正在加载 第01集」
String fxLoadingLineText(int ep, String lineName) {
  final name = lineName.trim();
  final label = fxEpisodeLabel(ep);
  return name.isEmpty ? '正在加载 $label' : '正在加载 $name · $label';
}

/// 按线路 id 从详情线路表里取线路名；查不到返回空串。
String fxLineNameOf(List<LineInfo> lines, String lineId) {
  for (final line in lines) {
    if (line.id == lineId) return line.displayName.trim();
  }
  return '';
}

/// 播放器进度条。
///
/// 交互按腾讯视频：
/// - 拖动过程中只更新高亮，**松手才真正 seek**；
/// - 高亮跟手，不回弹；
/// - 触摸热区固定 ≥32px，视觉条可单独加粗到 4–6px；
/// - 拖动时通过 [onScrub] 把目标时间交给外层，实时刷新左右时间文案。
class PProgressBar extends StatefulWidget {
  const PProgressBar({
    super.key,
    required this.position,
    required this.duration,
    required this.onSeek,
    this.buffered = Duration.zero,
    this.onScrub,
    this.onScrubStart,
    this.height = 4,
    this.thumbSize = 16,
    this.touchHeight = 36,
    this.showThumb = true,
    this.enabled = true,
    this.trackColor,
    this.bufferedColor,
    this.activeColors = const [Color(0xFF8E6BFF), Color(0xFF5B8CFF)],
    this.thumbColor = Fx.gold,
  });

  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;

  /// 已缓冲的时长（媒体时间，非文件字节）。
  final Duration buffered;

  /// 拖动预览：目标时间；松手后为 null。
  final ValueChanged<Duration?>? onScrub;

  /// 手指刚落下（还没拖动）时回调。
  ///
  /// TOGETHER_DRAG_CLAIM（2026-11-15）：一起看里用它「接手主导权」——
  /// 拖动开始那一刻就把本地操作时间戳刷掉，别的成员的 1 秒心跳不会在
  /// 拖动途中把人拽回去，松手时也不至于已经被拉偏了。
  final VoidCallback? onScrubStart;
  final double height;
  final double thumbSize;

  /// 触摸热区高度，最小 32。
  final double touchHeight;
  final bool showThumb;
  final bool enabled;
  final Color? trackColor;
  final Color? bufferedColor;
  final List<Color> activeColors;
  final Color thumbColor;

  @override
  State<PProgressBar> createState() => _PProgressBarState();
}

class _PProgressBarState extends State<PProgressBar> {
  double? _drag;

  bool get _hasDuration => widget.duration.inMilliseconds > 0;

  double get _fraction {
    if (!_hasDuration) return 0;
    final f = widget.position.inMilliseconds / widget.duration.inMilliseconds;
    return f.clamp(0.0, 1.0).toDouble();
  }

  double get _bufferedFraction {
    if (!_hasDuration) return 0;
    // FxPlayer 的 buffered 来自 ExoPlayer 上报的 bufferedPosition
    // （libmpv demuxer-cache-time），它本身就是已缓冲到的绝对位置，
    // 不要再叠加 position，否则会虚高成假的 100%。
    return (widget.buffered.inMilliseconds / widget.duration.inMilliseconds)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  Duration _targetFor(double fraction) => Duration(
    milliseconds: (widget.duration.inMilliseconds * fraction.clamp(0.0, 1.0))
        .round(),
  );

  void _seekTo(double fraction) {
    if (!_hasDuration || !widget.enabled) return;
    widget.onSeek(_targetFor(fraction));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final f = (_drag ?? _fraction).clamp(0.0, 1.0).toDouble();
        final activeWidth = math.max(0.0, width * f);
        final bufferedWidth = math.max(0.0, width * _bufferedFraction);
        final thumb = widget.thumbSize;
        final touchHeight = math.max(
          32.0,
          math.max(widget.touchHeight, thumb + 10),
        );
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 单击松手才 seek；拖动过程中只跟手改高亮。
          onTapUp: widget.enabled
              ? (details) {
                  widget.onScrubStart?.call();
                  if (width <= 0 || !_hasDuration) return;
                  final target = (details.localPosition.dx / width)
                      .clamp(0.0, 1.0)
                      .toDouble();
                  _seekTo(target);
                }
              : null,
          onHorizontalDragStart: widget.enabled
              ? (details) {
                  widget.onScrubStart?.call();
                  widget.onScrub?.call(_targetFor(_fraction));
                  setState(() => _drag = _fraction);
                }
              : null,
          onHorizontalDragUpdate: widget.enabled
              ? (details) {
                  if (width <= 0 || !_hasDuration) return;
                  final value = (details.localPosition.dx / width)
                      .clamp(0.0, 1.0)
                      .toDouble();
                  widget.onScrub?.call(_targetFor(value));
                  setState(() => _drag = value);
                }
              : null,
          onHorizontalDragEnd: widget.enabled
              ? (details) {
                  final value = _drag;
                  if (value != null) _seekTo(value);
                  // 高亮保持到外层预览时间结束，避免 seek 完成前回弹。
                  setState(() => _drag = null);
                  widget.onScrub?.call(null);
                }
              : null,
          onHorizontalDragCancel: widget.enabled
              ? () {
                  setState(() => _drag = null);
                  widget.onScrub?.call(null);
                }
              : null,
          child: SizedBox(
            height: touchHeight,
            child: Stack(
              alignment: Alignment.centerLeft,
              clipBehavior: Clip.none,
              children: [
                // 底轨
                Positioned(
                  left: 0,
                  right: 0,
                  child: Container(
                    height: widget.height,
                    decoration: BoxDecoration(
                      color:
                          widget.trackColor ??
                          Colors.white.withValues(alpha: .28),
                      borderRadius: BorderRadius.circular(widget.height),
                    ),
                  ),
                ),
                // 已缓冲
                Positioned(
                  left: 0,
                  child: Container(
                    width: bufferedWidth,
                    height: widget.height,
                    decoration: BoxDecoration(
                      color:
                          widget.bufferedColor ??
                          Colors.white.withValues(alpha: .34),
                      borderRadius: BorderRadius.circular(widget.height),
                    ),
                  ),
                ),
                // 已播放
                Positioned(
                  left: 0,
                  child: Container(
                    width: activeWidth,
                    height: widget.height,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: widget.activeColors),
                      borderRadius: BorderRadius.circular(widget.height),
                    ),
                  ),
                ),
                if (widget.showThumb)
                  Positioned(
                    left: math.max(
                      0.0,
                      math.min(width - thumb, activeWidth - thumb / 2),
                    ),
                    child: Container(
                      width: thumb,
                      height: thumb,
                      decoration: BoxDecoration(
                        color: widget.thumbColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: .22),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.mood_rounded,
                        size: thumb * .62,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 播放器通用进度行：左时间 + 进度条 + 右时间。
///
/// 拖动时左侧时间实时跟着手指走，松手后保持到真正 seek 完成，避免回弹。
class FxSeekRow extends StatefulWidget {
  const FxSeekRow({
    super.key,
    required this.position,
    required this.duration,
    required this.onSeek,
    this.buffered = Duration.zero,
    this.onScrubStart,
    this.height = 4,
    this.touchHeight = 36,
    this.thumbSize = 16,
    this.labelWidth = 46,
    this.gap = 8,
    this.timeFontSize = 11,
    this.timeFontWeight = FontWeight.w600,
    this.timeColor = Colors.white,
    this.enabled = true,
    this.showThumb = true,
    this.activeColors = const [Color(0xFF8E6BFF), Color(0xFF5B8CFF)],
  });

  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;
  final Duration buffered;

  /// 手指落下（含单击）时回调：一起看拿它「接手主导权」。
  final VoidCallback? onScrubStart;
  final double height;
  final double touchHeight;
  final double thumbSize;
  final double labelWidth;
  final double gap;
  final double timeFontSize;
  final FontWeight timeFontWeight;
  final Color timeColor;
  final bool enabled;
  final bool showThumb;
  final List<Color> activeColors;

  @override
  State<FxSeekRow> createState() => _FxSeekRowState();
}

class _FxSeekRowState extends State<FxSeekRow> {
  Duration? _preview;
  Timer? _timer;

  @override
  void didUpdateWidget(covariant FxSeekRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final preview = _preview;
    if (preview == null) return;
    // 真实进度追上预览值就结束预览；seek 慢时由下方定时器兜底。
    if ((widget.position - preview).abs() <= const Duration(seconds: 1)) {
      _timer?.cancel();
      _preview = null;
    }
  }

  void _onScrub(Duration? target) {
    _timer?.cancel();
    if (target != null) {
      if (!mounted) return;
      setState(() => _preview = target);
      return;
    }
    _timer = Timer(const Duration(milliseconds: 1600), () {
      if (!mounted) return;
      setState(() => _preview = null);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _preview ?? widget.position;
    final style = TextStyle(
      color: widget.timeColor,
      fontSize: widget.timeFontSize,
      fontWeight: widget.timeFontWeight,
      letterSpacing: .3,
      shadows: const [Shadow(color: Colors.black54, blurRadius: 3)],
    );
    return Row(
      children: [
        SizedBox(
          width: widget.labelWidth,
          child: Text(fxTime(shown), style: style),
        ),
        SizedBox(width: widget.gap),
        Expanded(
          child: PProgressBar(
            position: shown,
            duration: widget.duration,
            buffered: widget.buffered,
            height: widget.height,
            touchHeight: widget.touchHeight,
            thumbSize: widget.thumbSize,
            showThumb: widget.showThumb,
            enabled: widget.enabled,
            activeColors: widget.activeColors,
            onSeek: widget.onSeek,
            onScrubStart: widget.onScrubStart,
            onScrub: _onScrub,
          ),
        ),
        SizedBox(width: widget.gap),
        SizedBox(
          width: widget.labelWidth,
          child: Text(
            fxTime(widget.duration),
            style: style,
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

/// 播放器加载 / 缓冲浮层。
///
/// BUFFER_UI（2026-11-15，用户口径）：**去掉假进度**。
/// ```
/// 以前   一个圆环 + 百分比（bufferedPosition / duration，用户看着像进度，
///        其实和「还要等多久」没关系，缓到 42% 可能还要等十秒）
/// 现在   只有不确定进度的转圈；下面一行实时网速「1.8 MB/s」/「320 KB/s」，
///        网速为 0 就写「0 KB/s」（不留上一个数）；再下面是
///        「正在尝试其他线路（2/11）」或 15 秒后的「网速较慢（已等 18 秒）」
/// ```
/// 一律小字、半透明，不抢画面：这层是解释「在等什么」，不是让用户读的字。
class FxLoadingOverlay extends StatelessWidget {
  const FxLoadingOverlay({
    super.key,
    required this.title,
    this.speedText = '',
    this.attemptText = '',
    this.noteText = '',
    this.dim = true,
    this.compact = false,
  });

  /// 主文案（加载页由 [fxLoadingLineText] 生成，含当前线路名）。
  final String title;

  /// 实时网速文案（`1.8 MB/s` / `320 KB/s` / `0 KB/s`）。
  ///
  /// 传 [fxSpeedLabel] 的结果：**0 也照实显示**「0 KB/s」，不要藏着或
  /// 留着上一秒的数字 —— 用户是靠这一行判断「到底还在不在下」的。
  final String speedText;

  /// 「正在尝试其他线路（2/11）」这类线路轮换提示；空串不显示。
  final String attemptText;

  /// 「网速较慢（已等 18 秒）」这类说明；空串不显示。
  final String noteText;

  final bool dim;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ring = compact ? 44.0 : 62.0;
    final muted = Colors.white.withValues(alpha: .72);
    return IgnorePointer(
      child: Container(
        color: dim ? Colors.black.withValues(alpha: .26) : Colors.transparent,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipOval(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: Container(
                  width: ring,
                  height: ring,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: .14),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: .34),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .16),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  // 只有转圈：**不确定进度**，不画进度环、不写百分比。
                  child: SizedBox(
                    width: ring * .44,
                    height: ring * .44,
                    child: CircularProgressIndicator(
                      strokeWidth: compact ? 2.4 : 3,
                      color: Colors.white,
                      backgroundColor: Colors.white.withValues(alpha: .18),
                    ),
                  ),
                ),
              ),
            ),
            // 实时网速：紧跟图标下面，小字、半透明。
            if (speedText.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                speedText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: muted,
                  fontSize: compact ? 10 : 11,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
            ],
            // 线路轮换提示：「正在尝试其他线路（2/11）」放在网速下面。
            if (attemptText.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                attemptText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: muted,
                  fontSize: compact ? 10 : 11,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
            ],
            // 慢网说明：「网速较慢（已等 18 秒）」——告诉用户在等什么，
            // 30 秒硬上限到点内核会直接切下一条，不需要他点任何按钮。
            if (noteText.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                noteText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: .62),
                  fontSize: compact ? 9.5 : 10.5,
                  fontWeight: FontWeight.w500,
                  height: 1.25,
                ),
              ),
            ],
            // 主文案（线路名 / 第几集）：放最后，只当背景信息。
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .42),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Colors.white.withValues(alpha: .26),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .14),
                    blurRadius: 14,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: compact ? 11.5 : 12.5,
                  fontWeight: FontWeight.w700,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

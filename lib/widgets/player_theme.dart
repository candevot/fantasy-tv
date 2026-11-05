import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import '../services/fx_player.dart';
import '../theme.dart';

/// 播放器通用小工具：时间格式、进度持久化、白玻璃控件。
String fxPad2(int n) => n.toString().padLeft(2, '0');

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
String fxEpisodeLabel(int ep, [String? name]) {
  final s = (name ?? '').trim();
  if (s.isEmpty) return '第${fxPad2(ep)}集';
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

/// 分辨率通俗标签：4K / 1080P / 720P / 标清。
///
/// 只按视频原始宽度分档，不再拼接其他后缀；未就绪时返回空串。
String fxResolutionLabel(int? width) {
  if (width == null || width <= 0) return '';
  if (width >= 3800) return '4K';
  if (width >= 1800) return '1080P';
  if (width >= 1200) return '720P';
  return '标清';
}

/// 顶栏唯一的画质胶囊文案：取播放器真实视频宽度，未就绪时为空。
String fxPlayerQuality(FxPlayer? player) {
  final value = player?.value;
  if (value == null || !value.isInitialized) return '';
  final width = (value.videoWidth ?? 0) > 0 ? value.videoWidth : value.width;
  return fxResolutionLabel(width);
}

/// 真实缓冲进度：`player.stream.buffer`（libmpv demuxer-cache-time，
/// 已缓冲位置）÷ 总时长。
///
/// - 时长未知时返回 null：调用方用不确定转圈 +「加载中…」，不猜进度；
/// - 百分比向下取整并锁在 99% 以内，绝不显示假的 100%。
double? fxBufferedPercent(Duration buffered, Duration duration) {
  if (duration <= Duration.zero) return null;
  if (buffered <= Duration.zero) return 0;
  final ratio = buffered.inMilliseconds / duration.inMilliseconds;
  if (!ratio.isFinite) return null;
  final percent = (ratio * 100).floorToDouble();
  if (percent <= 0) return 0;
  return percent > 99 ? 99 : percent;
}

/// 字幕距播放器底部的安全距离：至少 96dp，始终高过底部控件区。
const double fxSubtitleMinBottom = 96;

/// 播放器画面：固定等比完整显示，并把字幕抬到控件区上方。
///
/// [subtitleBottom] 必须不小于 [fxSubtitleMinBottom]；全屏时传
/// 「底部控件高度 + 安全间距」，避免字幕被进度条/按钮盖住。
class FxPlayerSurface extends StatelessWidget {
  const FxPlayerSurface({
    super.key,
    required this.player,
    this.fit = BoxFit.contain,
    this.subtitleBottom = fxSubtitleMinBottom,
  });

  final FxPlayer player;
  final BoxFit fit;
  final double subtitleBottom;

  @override
  Widget build(BuildContext context) {
    return Video(
      controller: player.videoController,
      controls: NoVideoControls,
      fit: fit,
      alignment: Alignment.center,
      fill: Colors.black,
      wakelock: true,
      pauseUponEnteringBackgroundMode: false,
      resumeUponEnteringForegroundMode: false,
      subtitleViewConfiguration: SubtitleViewConfiguration(
        padding: EdgeInsets.fromLTRB(
          24,
          0,
          24,
          subtitleBottom < fxSubtitleMinBottom
              ? fxSubtitleMinBottom
              : subtitleBottom,
        ),
      ),
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

/// 「撑满全屏」开关的存储 key。默认开：全屏用 cover 裁边不变形；
/// 关掉后全屏回到 contain（完整显示，可能上下留黑边）。
const String fxFillScreenKey = 'player_fill_screen';

Future<bool> fxLoadFillScreen() async {
  try {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(fxFillScreenKey) ?? true;
  } catch (_) {
    return true;
  }
}

Future<void> fxSaveFillScreen(bool value) async {
  try {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(fxFillScreenKey, value);
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
      backgroundColor: Colors.white.withOpacity(.96),
      elevation: 4,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(18, 0, 18, 18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      duration: const Duration(seconds: 2),
    ),
  );
}

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
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final bool active;
  final String? tooltip;
  final double tint;
  final Color iconColor;

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
              ? Fx.accent.withOpacity(.82)
              : Colors.white.withOpacity(tint),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withOpacity(.32), width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(.10),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Icon(icon, size: iconSize, color: iconColor),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// 白玻璃胶囊（电量 / 时间 / 信息）
class PGlassPill extends StatelessWidget {
  const PGlassPill({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(.28), width: 1),
      ),
      child: child,
    );
    if (onTap == null) return box;
    return GestureDetector(
        onTap: onTap, behavior: HitTestBehavior.opaque, child: box);
  }
}

/// 播放器加载文案里的产品名（需求指定，切集/换线路加载时展示）。
const String fxPlayerBrand = '幻想腾讯4K';

/// 「正在加载 幻想腾讯4K 第03集」
String fxLoadingEpisodeText(int ep) =>
    '正在加载 $fxPlayerBrand ${fxEpisodeLabel(ep)}';

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
    // FxPlayer 的 buffered 来自 media_kit `stream.buffer`
    // （libmpv demuxer-cache-time），它本身就是已缓冲到的绝对位置，
    // 不要再叠加 position，否则会虚高成假的 100%。
    return (widget.buffered.inMilliseconds / widget.duration.inMilliseconds)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  Duration _targetFor(double fraction) => Duration(
        milliseconds:
            (widget.duration.inMilliseconds * fraction.clamp(0.0, 1.0)).round(),
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
        final touchHeight =
            math.max(32.0, math.max(widget.touchHeight, thumb + 10));
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 单击松手才 seek；拖动过程中只跟手改高亮。
          onTapUp: widget.enabled
              ? (details) {
                  if (width <= 0 || !_hasDuration) return;
                  final target = (details.localPosition.dx / width)
                      .clamp(0.0, 1.0)
                      .toDouble();
                  _seekTo(target);
                }
              : null,
          onHorizontalDragStart: widget.enabled
              ? (details) {
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
                      color: widget.trackColor ?? Colors.white.withOpacity(.28),
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
                          widget.bufferedColor ?? Colors.white.withOpacity(.34),
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
                        0.0, math.min(width - thumb, activeWidth - thumb / 2)),
                    child: Container(
                      width: thumb,
                      height: thumb,
                      decoration: BoxDecoration(
                        color: widget.thumbColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(.22),
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
            onScrub: _onScrub,
          ),
        ),
        SizedBox(width: widget.gap),
        SizedBox(
          width: widget.labelWidth,
          child: Text(fxTime(widget.duration),
              style: style, textAlign: TextAlign.right),
        ),
      ],
    );
  }
}

/// 播放器加载 / 缓冲浮层。
///
/// - 切集、切线路、首帧未出：圆环 +「正在连接线路…」等文案；
/// - 播放中缓冲：圆环 +「缓冲中 42%」（[fxBufferedPercent] 的真实进度）；
/// - 时长未知：不确定圆环 +「加载中…」。
class FxLoadingOverlay extends StatelessWidget {
  const FxLoadingOverlay({
    super.key,
    required this.title,
    this.percent,
    this.subtitle,
    this.dim = true,
    this.compact = false,
  });

  /// 主文案。
  final String title;

  /// 0–100；为 null 时圆环不确定进度。即使调用方传 100 也会锁到 99，
  /// 缓冲进度不能显示假的 100%（媒体缓存经常先到 duration 但仍在缓冲）。
  final double? percent;

  /// 副文案，如线路名。
  final String? subtitle;
  final bool dim;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    // 兜底：任何情况下都不把缓冲显示成 100%。
    final safePercent = percent == null
        ? null
        : percent!.isFinite
            ? percent!.clamp(0.0, 99.0).toDouble()
            : null;
    final value = safePercent == null ? null : safePercent / 100;
    final ring = compact ? 44.0 : 62.0;
    return IgnorePointer(
      child: Container(
        color: dim ? Colors.black.withOpacity(.26) : Colors.transparent,
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
                    color: Colors.white.withOpacity(.14),
                    border: Border.all(
                        color: Colors.white.withOpacity(.34), width: 1),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(.16),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  alignment: Alignment.center,
                  child: SizedBox(
                    width: ring * .72,
                    height: ring * .72,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CircularProgressIndicator(
                          value: value,
                          strokeWidth: compact ? 2.4 : 3,
                          color: Colors.white,
                          backgroundColor: Colors.white.withOpacity(.18),
                        ),
                        if (safePercent != null)
                          Text(
                            '${safePercent.round()}%',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(.42),
                borderRadius: BorderRadius.circular(16),
                border:
                    Border.all(color: Colors.white.withOpacity(.26), width: 1),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(.14),
                    blurRadius: 14,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: compact ? 11.5 : 12.5,
                      fontWeight: FontWeight.w700,
                      height: 1.35,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withOpacity(.72),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

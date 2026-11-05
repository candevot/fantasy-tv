import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';

/// 播放器通用小工具：时间格式、进度持久化、白玻璃控件。
String fxPad2(int n) => n.toString().padLeft(2, '0');

String fxEpisodeLabel(int n) => '第${fxPad2(n)}集';

String fxTime(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  if (h > 0) return '$h:${fxPad2(m)}:${fxPad2(s)}';
  return '${fxPad2(m)}:${fxPad2(s)}';
}

String fxClock(DateTime t) => '${fxPad2(t.hour)}:${fxPad2(t.minute)}';

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
          color: active ? Fx.accent.withOpacity(.82) : Colors.white.withOpacity(tint),
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
    return GestureDetector(onTap: onTap, behavior: HitTestBehavior.opaque, child: box);
  }
}

/// 播放器细进度条：表情把手 + 拖动
class PProgressBar extends StatefulWidget {
  const PProgressBar({
    super.key,
    required this.position,
    required this.duration,
    required this.onSeek,
    this.height = 3,
    this.thumbSize = 17,
    this.showThumb = true,
    this.trackColor,
    this.activeColors = const [Color(0xFF8E6BFF), Color(0xFF5B8CFF)],
    this.thumbColor = Fx.gold,
  });

  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;
  final double height;
  final double thumbSize;
  final bool showThumb;
  final Color? trackColor;
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

  void _seekTo(double fraction) {
    if (!_hasDuration) return;
    final ms = (widget.duration.inMilliseconds * fraction).round();
    widget.onSeek(Duration(milliseconds: ms));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final f = (_drag ?? _fraction).clamp(0.0, 1.0).toDouble();
        final activeWidth = math.max(0.0, width * f);
        final thumb = widget.thumbSize;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            if (width <= 0) return;
            _seekTo((details.localPosition.dx / width).clamp(0.0, 1.0).toDouble());
          },
          onHorizontalDragStart: (details) {
            setState(() => _drag = _fraction);
          },
          onHorizontalDragUpdate: (details) {
            if (width <= 0) return;
            setState(
              () => _drag = (details.localPosition.dx / width).clamp(0.0, 1.0).toDouble(),
            );
          },
          onHorizontalDragEnd: (details) {
            final value = _drag;
            setState(() => _drag = null);
            if (value != null) _seekTo(value);
          },
          onHorizontalDragCancel: () => setState(() => _drag = null),
          child: SizedBox(
            height: math.max(28, thumb + 10),
            child: Stack(
              alignment: Alignment.centerLeft,
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  child: Container(
                    height: widget.height,
                    decoration: BoxDecoration(
                      color: widget.trackColor ?? Colors.white.withOpacity(.34),
                      borderRadius: BorderRadius.circular(widget.height),
                    ),
                  ),
                ),
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
                    left: (width - thumb) * f,
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

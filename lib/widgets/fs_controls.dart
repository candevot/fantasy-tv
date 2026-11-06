import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'player_theme.dart';

/* ========================================================================== */
/*  全屏横屏播放器 · 通用白玻璃控件                                            */
/*  样式与竖屏播放器一致：半透明白玻璃 + 细白描边 + 柔和投影                      */
/* ========================================================================== */

/// 白玻璃文字胶囊：片头/尾、倍速、选集这类短标签按钮
class FsTextAction extends StatelessWidget {
  const FsTextAction({
    super.key,
    required this.text,
    this.icon,
    this.onTap,
    this.active = false,
    this.size = 1,
  });

  final String text;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool active;

  /// 相对缩放：1 = 标准，紧凑布局传 .88
  final double size;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding:
            EdgeInsets.symmetric(horizontal: 12 * size, vertical: 7 * size),
        decoration: BoxDecoration(
          color: active
              ? Fx.accent.withValues(alpha: .86)
              : Colors.white.withValues(alpha: .13),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: .30), width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .12),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14 * size, color: Colors.white),
              SizedBox(width: 4 * size),
            ],
            Text(
              text,
              style: TextStyle(
                color: Colors.white,
                fontSize: 12.5 * size,
                fontWeight: FontWeight.w600,
                height: 1.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶栏唯一的画质胶囊：只显示 4K / 1080P / 720P / 标清。
///
/// 纯信息展示，不可点击；切换清晰度仍在底部「清晰度」按钮。
class FsQualityPill extends StatelessWidget {
  const FsQualityPill({
    super.key,
    required this.label,
    this.size = 1,
  });

  final String label;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return PGlassPill(
      padding: EdgeInsets.symmetric(horizontal: 10 * size, vertical: 5 * size),
      child: Text(
        label,
        maxLines: 1,
        style: TextStyle(
          color: Colors.white,
          fontSize: 11.5 * size,
          fontWeight: FontWeight.w700,
          letterSpacing: .2,
          shadows: const [Shadow(color: Colors.black54, blurRadius: 3)],
        ),
      ),
    );
  }
}

/// 时间胶囊：自带 1 秒定时刷新，避免整页重建
class FsClockPill extends StatefulWidget {
  const FsClockPill({super.key, this.size = 1});

  final double size;

  @override
  State<FsClockPill> createState() => _FsClockPillState();
}

class _FsClockPillState extends State<FsClockPill> {
  late String _text = fxClock(DateTime.now());
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final next = fxClock(DateTime.now());
      if (!mounted || next == _text) return;
      setState(() => _text = next);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PGlassPill(
      padding: EdgeInsets.symmetric(
          horizontal: 10 * widget.size, vertical: 5 * widget.size),
      child: Text(
        _text,
        style: TextStyle(
          color: Colors.white,
          fontSize: 12 * widget.size,
          fontWeight: FontWeight.w700,
          letterSpacing: .5,
          shadows: const [Shadow(color: Colors.black54, blurRadius: 3)],
        ),
      ),
    );
  }
}

/// 顶部控制条（对齐腾讯）：返回 · 片名/第xx集 · 画质 · 投屏 · 更多。
///
/// 画质只保留一个胶囊，内容限定为 4K / 1080P / 720P / 标清。
/// 已按产品要求移除截图按钮：顶栏只剩返回/剧名、投屏、更多。
class FsTopBar extends StatelessWidget {
  const FsTopBar({
    super.key,
    required this.title,
    required this.epLabel,
    required this.onBack,
    required this.onCast,
    required this.onMore,
    this.compact = false,
  });

  final String title;
  final String epLabel;

  final VoidCallback onBack;
  final VoidCallback onCast;
  final VoidCallback onMore;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final s = compact ? .9 : 1.0;
    final gap = SizedBox(width: 7 * s);
    return Container(
      padding: EdgeInsets.fromLTRB(14, 8, 10, 18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: .52), Colors.black.withValues(alpha: 0)],
        ),
      ),
      child: Row(
        children: [
          PGlassIcon(
            icon: Icons.arrow_back_ios_new_rounded,
            size: 34 * s,
            iconSize: 17 * s,
            tint: .16,
            tooltip: '退出全屏',
            onTap: onBack,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14 * s,
                    fontWeight: FontWeight.w700,
                    shadows: const [
                      Shadow(color: Colors.black54, blurRadius: 4)
                    ],
                  ),
                ),
                if (epLabel.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    epLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 11 * s,
                      shadows: const [
                        Shadow(color: Colors.black54, blurRadius: 4)
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          PGlassIcon(
            icon: Icons.tv_rounded,
            size: 32 * s,
            iconSize: 17 * s,
            tooltip: '投屏',
            onTap: onCast,
          ),
          gap,
          PGlassIcon(
            icon: Icons.more_horiz_rounded,
            size: 32 * s,
            iconSize: 19 * s,
            tooltip: '更多',
            onTap: onMore,
          ),
        ],
      ),
    );
  }
}

/// 左右侧控件：左中锁屏，右中 +10s / -10s。
///
/// 未锁定时锁按钮就放在左侧控件层里，随控件层的显隐一起出现 /
/// 一起淡出（页面统一 5 秒自动隐藏），不会自己常驻。
class FsSideControls extends StatelessWidget {
  const FsSideControls({
    super.key,
    required this.onLock,
    required this.onSeekBy,
    this.showSeek = true,
  });

  final VoidCallback onLock;
  final ValueChanged<int> onSeekBy;

  /// 直播没有可回看的进度：只保留左侧锁屏，隐藏 ±10s。
  final bool showSeek;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          left: 14,
          top: 0,
          bottom: 0,
          child: Center(
            child: PGlassIcon(
              icon: Icons.lock_outline_rounded,
              size: 42,
              iconSize: 21,
              tint: .16,
              tooltip: '锁定屏幕',
              onTap: onLock,
            ),
          ),
        ),
        if (showSeek)
          Positioned(
            right: 14,
            top: 0,
            bottom: 0,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PGlassIcon(
                    icon: Icons.forward_10_rounded,
                    size: 44,
                    iconSize: 23,
                    tint: .16,
                    tooltip: '快进 10 秒',
                    onTap: () => onSeekBy(10),
                  ),
                  const SizedBox(height: 22),
                  PGlassIcon(
                    icon: Icons.replay_10_rounded,
                    size: 44,
                    iconSize: 23,
                    tint: .16,
                    tooltip: '后退 10 秒',
                    onTap: () => onSeekBy(-10),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 锁屏后唯一的解锁按钮：半透明小圆钮。
///
/// [visible] 由页面控制：刚锁定时亮 3 秒自动淡出；锁定后点屏幕是
/// 显隐切换（隐藏立即生效）。[visible] 为 false 时 opacity=0 且
/// [IgnorePointer] 让出触摸，绝非常驻画面上。
class FsUnlockButton extends StatelessWidget {
  const FsUnlockButton({
    super.key,
    required this.onUnlock,
    this.visible = true,
    this.alignment = const Alignment(-.96, 0),
    this.size = 40,
  });

  final VoidCallback onUnlock;

  /// 是否显示；隐藏时不可点击，淡出后完全让出触摸。
  final bool visible;
  final Alignment alignment;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 160),
        child: Align(
          alignment: alignment,
          child: Opacity(
            opacity: .62,
            child: PGlassIcon(
              icon: Icons.lock_rounded,
              size: size,
              iconSize: size * .48,
              tint: .12,
              tooltip: '点击解锁',
              onTap: onUnlock,
            ),
          ),
        ),
      ),
    );
  }
}

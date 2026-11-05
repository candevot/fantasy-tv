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
              ? Fx.accent.withOpacity(.86)
              : Colors.white.withOpacity(.13),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withOpacity(.30), width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(.12),
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

/// 网速占位胶囊。
///
/// 说明：media_kit 未暴露实时下载码率，项目也没有引入测速插件，
/// 这里只显示不带数字的「网速 --」，不再展示写死的假电量。
class FsNetSpeedPill extends StatelessWidget {
  const FsNetSpeedPill({super.key, this.size = 1});

  final double size;

  @override
  Widget build(BuildContext context) {
    return PGlassPill(
      padding: EdgeInsets.symmetric(horizontal: 9 * size, vertical: 5 * size),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.network_check_rounded,
            size: 15 * size,
            color: Colors.white,
          ),
          SizedBox(width: 3 * size),
          Text(
            '网速 --',
            style: TextStyle(
              color: Colors.white,
              fontSize: 11.5 * size,
              fontWeight: FontWeight.w700,
              letterSpacing: .2,
              shadows: const [Shadow(color: Colors.black54, blurRadius: 3)],
            ),
          ),
        ],
      ),
    );
  }
}

/// 真实分辨率胶囊（取自 media_kit videoParams，如 1280x720）
class FsResolutionPill extends StatelessWidget {
  const FsResolutionPill({
    super.key,
    required this.resolution,
    this.size = 1,
  });

  final String resolution;
  final double size;

  @override
  Widget build(BuildContext context) {
    return PGlassPill(
      padding: EdgeInsets.symmetric(horizontal: 9 * size, vertical: 5 * size),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.aspect_ratio_rounded,
            size: 14 * size,
            color: Colors.white,
          ),
          SizedBox(width: 3 * size),
          Text(
            resolution,
            style: TextStyle(
              color: Colors.white,
              fontSize: 11.5 * size,
              fontWeight: FontWeight.w700,
              letterSpacing: .2,
              shadows: const [Shadow(color: Colors.black54, blurRadius: 3)],
            ),
          ),
        ],
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

/// 顶部控制条：返回 · 片名/第xx集 —— 分辨率 · 网速 · 时间 · 旋转锁定 · 画中画 · 投屏 · 设置
class FsTopBar extends StatelessWidget {
  const FsTopBar({
    super.key,
    required this.title,
    required this.epLabel,
    required this.onBack,
    required this.onRotate,
    required this.rotationLocked,
    required this.onPip,
    required this.onCast,
    required this.onSettings,
    this.resolution = '',
    this.compact = false,
  });

  final String title;
  final String epLabel;

  /// 真实分辨率文本，空串则不显示
  final String resolution;
  final VoidCallback onBack;
  final VoidCallback onRotate;
  final bool rotationLocked;
  final VoidCallback onPip;
  final VoidCallback onCast;
  final VoidCallback onSettings;
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
          colors: [Colors.black.withOpacity(.52), Colors.black.withOpacity(0)],
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
          if (resolution.isNotEmpty) ...[
            FsResolutionPill(resolution: resolution, size: s),
            gap,
          ],
          FsNetSpeedPill(size: s),
          gap,
          FsClockPill(size: s),
          const SizedBox(width: 8),
          PGlassIcon(
            icon: rotationLocked
                ? Icons.screen_lock_rotation_rounded
                : Icons.screen_rotation_rounded,
            size: 32 * s,
            iconSize: 17 * s,
            active: rotationLocked,
            tooltip: rotationLocked ? '解除旋转锁定' : '锁定屏幕旋转',
            onTap: onRotate,
          ),
          gap,
          PGlassIcon(
            icon: Icons.picture_in_picture_alt_rounded,
            size: 32 * s,
            iconSize: 17 * s,
            tooltip: '画中画',
            onTap: onPip,
          ),
          gap,
          PGlassIcon(
            icon: Icons.tv_rounded,
            size: 32 * s,
            iconSize: 17 * s,
            tooltip: '投屏',
            onTap: onCast,
          ),
          gap,
          PGlassIcon(
            icon: Icons.settings_rounded,
            size: 32 * s,
            iconSize: 17 * s,
            tooltip: '播放设置',
            onTap: onSettings,
          ),
        ],
      ),
    );
  }
}

/// 中部：只保留播放/暂停一个圆钮（下一集在底部控制栏）
class FsCenterControls extends StatelessWidget {
  const FsCenterControls({
    super.key,
    required this.playing,
    required this.onTogglePlay,
  });

  final bool playing;
  final VoidCallback onTogglePlay;

  @override
  Widget build(BuildContext context) {
    return PGlassIcon(
      icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
      size: 58,
      iconSize: 34,
      tint: .18,
      tooltip: playing ? '暂停' : '播放',
      onTap: onTogglePlay,
    );
  }
}

/// 左右侧控件：左中锁屏，右中 +10s / -10s
class FsSideControls extends StatelessWidget {
  const FsSideControls({
    super.key,
    required this.onLock,
    required this.onSeekBy,
  });

  final VoidCallback onLock;
  final ValueChanged<int> onSeekBy;

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

/// 锁屏后唯一的解锁按钮（在横屏左侧黑边区域）
class FsUnlockButton extends StatelessWidget {
  const FsUnlockButton({super.key, required this.onUnlock});

  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: const Alignment(-.96, 0),
      child: PGlassIcon(
        icon: Icons.lock_rounded,
        size: 46,
        iconSize: 22,
        tint: .20,
        tooltip: '点击解锁',
        onTap: onUnlock,
      ),
    );
  }
}

/// 播放进度行：当前时间 + 细进度条（表情把手）+ 总时长
class FsProgressRow extends StatelessWidget {
  const FsProgressRow({
    super.key,
    required this.position,
    required this.duration,
    required this.onSeek,
  });

  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;

  static const TextStyle _timeStyle = TextStyle(
    color: Colors.white,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: .3,
    shadows: [Shadow(color: Colors.black54, blurRadius: 3)],
  );

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 48,
          child: Text(fxTime(position), style: _timeStyle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: PProgressBar(
            position: position,
            duration: duration,
            height: 3,
            thumbSize: 17,
            onSeek: onSeek,
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 48,
          child: Text(fxTime(duration),
              style: _timeStyle, textAlign: TextAlign.right),
        ),
      ],
    );
  }
}

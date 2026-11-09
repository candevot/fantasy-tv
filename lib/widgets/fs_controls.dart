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

/// 顶栏唯一的画质胶囊：显示真实分辨率 `宽x高`（如 1920x1080），空串自动隐藏。
///
/// 纯信息展示，不可点击；码率档切换已收进 ⋯ 播放设置面板。
class FsQualityPill extends StatelessWidget {
  const FsQualityPill({
    super.key,
    required this.label,
    this.size = 1,
  });

  final String label;
  final double size;

  /// 胶囊固定宽度：分辨率从 720x480 变到 3840x2160 时，胶囊宽度不变，
  /// 顶栏右侧的投屏 / 更多按钮就不会跟着左右跳（用户报的「控件位置不固定」）。
  static const double fixedWidth = 88;

  @override
  Widget build(BuildContext context) {
    // 未就绪时只占位、不画胶囊：否则分辨率一到，右侧按钮会突然左移。
    if (label.isEmpty) return SizedBox(width: fixedWidth * size);
    return SizedBox(
      width: fixedWidth * size,
      child: PGlassPill(
        padding: EdgeInsets.symmetric(horizontal: 8 * size, vertical: 5 * size),
        child: FittedBox(
          fit: BoxFit.scaleDown,
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

/// 顶部控制条（对齐腾讯）：返回 · 片名/第xx集 · 投屏 · 更多。
///
/// 画质胶囊只保留一个，内容为真实分辨率 `宽x高`（如 1920x1080），
/// 分辨率未知时传空串自动隐藏。
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
    this.qualityLabel = '',
  });

  final String title;
  final String epLabel;

  /// 真实分辨率胶囊（`1920x1080`）；空串自动隐藏。
  final String qualityLabel;

  final VoidCallback onBack;
  final VoidCallback onCast;
  /// 保留字段：顶栏已不再渲染「更多」按钮（重复入口），
  /// 播放设置统一走底栏。调用方仍可传，留作将来放其它功能。
  final VoidCallback onMore;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final s = compact ? .9 : 1.0;
    // 刘海 / 挖孔 / 圆角屏：先让出安全边距，按钮不压进屏幕圆角与摄像头。
    // 这里只认「屏幕」安全区，不认画面宽高——控件位置必须固定，不能因为
    // 片源是 4:3 / 21:9 就跟着画面矩形跑。
    final safe = MediaQuery.viewPaddingOf(context);
    // 右侧留白收到 6dp：分辨率胶囊 + 投屏 + 更多这一组要贴着屏幕右缘，
    // 留 10dp 时在大屏横屏上视觉重心偏中间。
    return Container(
      padding: EdgeInsets.fromLTRB(
        14 + safe.left,
        8 + safe.top,
        6 + safe.right,
        18,
      ),
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
          // 分辨率胶囊固定 88dp 槽位（未就绪只占位不画），保证右侧按钮不随
          // 分辨率出现 / 消失而左右跳。
          //
          // 注意：这三个必须是「非 flex」子项。之前用 Flexible 包了一层，
          // 它会和标题的 Expanded 各分走一半宽度，而 FittedBox 只取内容自然
          // 宽度，右端就空出一截 —— 表现就是「投屏 / 三点太靠中间」。
          // 现在交给 Expanded 吃掉所有剩余空间，这组自然贴到屏幕右边。
          FsQualityPill(label: qualityLabel, size: s),
          const SizedBox(width: 8),
          PGlassIcon(
            icon: Icons.tv_rounded,
            size: 32 * s,
            iconSize: 17 * s,
            tooltip: '投屏',
            onTap: onCast,
          ),
          // 顶栏不再放「更多」：底栏右下角的「播放设置」是唯一入口，
          // 两个 ⋯ 并存在竖屏 / 横屏里都会被误认为重复功能。
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
    // 左右安全边距：刘海 / 圆角屏上按钮不贴边、不进圆角区。
    final safe = MediaQuery.viewPaddingOf(context);
    return Stack(
      children: [
        Positioned(
          left: 14 + safe.left,
          top: safe.top,
          bottom: safe.bottom,
          child: Center(
            child: PGlassIcon(
              // 未锁定态：闭合的锁 + 「锁定屏幕」，与锁定态的打开锁形成
              // 明确对比，一眼能看出当前是否已锁定。
              icon: Icons.lock_rounded,
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
            right: 14 + safe.right,
            top: safe.top,
            bottom: safe.bottom,
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
              // 锁定态必须是「打开的锁」：旧实现用 Icons.lock_rounded
              // （闭合锁），和未锁定态的锁屏按钮长得一样，用户看到的就是
              // 「开锁 / 解锁都显示锁上」，分不清当前到底锁没锁。
              icon: Icons.lock_open_rounded,
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

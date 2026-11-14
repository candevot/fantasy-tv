import 'dart:async';

import 'package:flutter/material.dart';

import '../services/device_status.dart';
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
    this.narrow = false,
    this.qualityLabel = '',
    this.speedText = '',
    this.showCast = true,
    this.onRotate,
    this.rotatedToPortrait = false,
    this.onLongPressQuality,
  });

  final String title;
  final String epLabel;

  /// 真实分辨率胶囊（`1920x1080`）；空串自动隐藏。
  final String qualityLabel;

  /// 实时网速（如「3.2 MB/s」），显示在分辨率胶囊左边；空串隐藏。
  final String speedText;

  final VoidCallback onBack;
  final VoidCallback onCast;

  /// 是否显示投屏按钮。离线播放没有投屏入口，传 false 直接不渲染，
  /// 不再靠外层盖一层渐变遮罩（那种做法位置一挪就会漏出来）。
  final bool showCast;
  /// 保留字段：顶栏已不再渲染「更多」按钮（重复入口），
  /// 播放设置统一走底栏。调用方仍可传，留作将来放其它功能。
  final VoidCallback onMore;
  final bool compact;

  /// 窄屏（竖屏全屏播放）：右侧一组收窄，网速与时钟胶囊让位给标题，
  /// 避免 360dp 宽度下顶栏一行挤爆。横屏全屏不传，保持原样。
  final bool narrow;

  /// 手动转屏按钮；null 时不渲染（离线 / 一起看等场景不传）。
  final VoidCallback? onRotate;

  /// 当前是否竖屏布局：只决定转屏按钮的图标语义（点了会切到另一边）。
  final bool rotatedToPortrait;

  /// 长按分辨率胶囊的回调：播放诊断浮层的入口。
  ///
  /// 为什么挂在胶囊上：顶栏已经没有空位再加按钮，而胶囊本身就是「画面参数」
  /// 的语义位；长按不抢点按，不改变任何现有交互。null = 不响应长按。
  final VoidCallback? onLongPressQuality;

  @override
  Widget build(BuildContext context) {
    final s = compact ? .9 : 1.0;
    // 刘海 / 挖孔 / 圆角屏：先让出安全边距，按钮不压进屏幕圆角与摄像头。
    // 这里只认「屏幕」安全区，不认画面宽高——控件位置必须固定，不能因为
    // 片源是 4:3 / 21:9 就跟着画面矩形跑。
    final safe = MediaQuery.viewPaddingOf(context);
    // 右侧留白：分辨率胶囊 + 投屏这一组不能贴着屏幕边缘。
    //
    // 手机是弧形圆角屏（不是直边），横屏时右上角就是圆的 —— 只留 6dp 时
    // 这一组会压进圆角里被裁掉一截。这里按「屏幕圆角半径」估一个安全值：
    // 竖屏圆角通常在 24~40dp，横屏顶栏高度约 50dp，右上角圆弧大约占
    // 20~28dp，所以右侧留 24dp + safe.right 才稳。
    final cornerGuard = (safe.right > 0 ? 10.0 : 24.0);
    return Container(
      padding: EdgeInsets.fromLTRB(
        14 + safe.left,
        8 + safe.top,
        cornerGuard + safe.right,
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
          // TOPBAR_RIGHT_GROUP（2026-11-12）：右侧一组全部集中贴右。
          //
          // 之前网速是 Row 的直接子项、夹在 Expanded 和胶囊之间，
          // 窄屏时会被标题挤到屏幕中间偏左，看起来「散在左边」。
          // 现在把 网速 / 分辨率 / 电量 / 投屏 收进一个 Row，
          // 由 Spacer 推到最右，视觉上是一整组。
          const Spacer(),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 实时网速：能看出在动。网络卡住时掉到 0，一眼就知道。
              // 竖屏（narrow）先让它：360dp 宽装不下这么多胶囊。
              if (!narrow && speedText.isNotEmpty) ...[
                _TopChip(text: speedText, size: s),
                const SizedBox(width: 6),
              ],
              // 胶囊固定宽度、分辨率未就绪时只占位不画内容 —— 那样就没有可
              // 长按的区域。这里固定一个最小高度把它撑起来，长按才不会落空。
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPress: onLongPressQuality,
                child: SizedBox(
                  height: 26 * s,
                  child: Center(
                    child: FsQualityPill(label: qualityLabel, size: s),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // 电量：和手机状态栏同款语义，充电时变绿
              _BatteryChip(size: s),
              if (!narrow) ...[
                const SizedBox(width: 6),
                // 当前时间：全屏时看不到系统状态栏，这里补一个
                _ClockChip(size: s),
              ],
              if (onRotate != null) ...[
                const SizedBox(width: 6),
                // 手动转屏：竖着看短剧想横过来、或反过来时用。点过一次之后
                // 本次播放内不再自动跟着分辨率切（页面记 user override）。
                PGlassIcon(
                  icon: rotatedToPortrait
                      ? Icons.crop_landscape_rounded
                      : Icons.crop_portrait_rounded,
                  size: 32 * s,
                  iconSize: 17 * s,
                  tint: .18,
                  tooltip: rotatedToPortrait ? '转成横屏' : '转成竖屏',
                  onTap: onRotate,
                ),
              ],
              if (showCast) ...[
                const SizedBox(width: 6),
                PGlassIcon(
                  icon: Icons.cast_rounded,
                  size: 32 * s,
                  iconSize: 17 * s,
                  tint: .18,
                  tooltip: '投屏',
                  onTap: onCast,
                ),
              ],
            ],
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
            // 右侧侧栏同样让开弧形圆角：14dp 太贴边，横屏时快进/快退按钮
            // 会压进右下圆角。跟顶栏、底栏统一到 24dp。
            right: 24 + safe.right,
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

/// 顶栏小胶囊：网速 / 时间这类纯文字信息。
///
/// 统一圆角 + 半透明黑底，和 FsQualityPill 同一套视觉，
/// 避免文字直接飘在画面上看不清。
class _TopChip extends StatelessWidget {
  const _TopChip({required this.text, this.size = 1});

  final String text;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 7 * size, vertical: 3 * size),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .34),
        borderRadius: BorderRadius.circular(7 * size),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: .92),
          fontSize: 10 * size,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      ),
    );
  }
}

/// 顶栏电量胶囊：图标 + 百分比，充电时图标变绿。
class _BatteryChip extends StatelessWidget {
  const _BatteryChip({this.size = 1});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: DeviceStatus.instance,
      builder: (context, _) {
        final st = DeviceStatus.instance;
        final lv = st.level;
        if (lv < 0) return const SizedBox.shrink();
        final charging = st.charging;
        // 低电量（≤15% 且没充电）用红色提醒
        final low = lv <= 15 && !charging;
        final color = charging
            ? const Color(0xFF4CC38A)
            : (low ? const Color(0xFFFF6B6B) : Colors.white);
        final icon = charging
            ? Icons.battery_charging_full_rounded
            : (lv >= 95
                ? Icons.battery_full_rounded
                : (lv >= 70
                    ? Icons.battery_5_bar_rounded
                    : (lv >= 45
                        ? Icons.battery_4_bar_rounded
                        : (lv >= 20
                            ? Icons.battery_3_bar_rounded
                            : Icons.battery_1_bar_rounded))));
        return Container(
          padding:
              EdgeInsets.symmetric(horizontal: 7 * size, vertical: 3 * size),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .34),
            borderRadius: BorderRadius.circular(7 * size),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13 * size, color: color),
              SizedBox(width: 3 * size),
              Text(
                '$lv%',
                style: TextStyle(
                  color: color,
                  fontSize: 10 * size,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 顶栏时间胶囊：HH:mm，每分钟自动刷新。
///
/// 全屏播放会把系统状态栏藏起来，用户看不到时间。这里补一个，
/// 和电量并排，位置与 B站/腾讯的全屏顶栏一致。
class _ClockChip extends StatefulWidget {
  const _ClockChip({this.size = 1});

  final double size;

  @override
  State<_ClockChip> createState() => _ClockChipState();
}

class _ClockChipState extends State<_ClockChip> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // 对齐到下一分钟整点再开始 1 分钟周期，避免显示错一分钟。
    final now = DateTime.now();
    final msToNextMinute = 60000 - (now.second * 1000 + now.millisecond);
    Timer(Duration(milliseconds: msToNextMinute), () {
      if (!mounted) return;
      setState(() {});
      _timer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted) setState(() {});
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final text =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    return _TopChip(text: text, size: widget.size);
  }
}

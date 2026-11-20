import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../services/app_settings.dart';
import '../services/video_marks.dart';
import '../theme.dart';
import 'fs_controls.dart';
import 'fs_side_panel.dart';
import 'player_theme.dart';

/* ========================================================================== */
/*  全屏横屏播放器 · 底部控制条 / 选集 / 倍速 / 片头尾弹层                  */
/* ========================================================================== */

/// 倍速标签：1.0x / 2.0x 保留一位小数，0.75x、1.25x 原样输出
String fxRateLabel(double rate) {
  if ((rate - rate.roundToDouble()).abs() < .0001) {
    return '${rate.toStringAsFixed(1)}x';
  }
  return '${rate}x';
}

/// 白玻璃浮层卡片（倍速、片头尾、选集共用，浅色底 + 深色字）
class FsGlassCard extends StatelessWidget {
  const FsGlassCard({
    super.key,
    required this.child,
    this.width,
    this.padding = const EdgeInsets.fromLTRB(14, 12, 14, 14),
  });

  final Widget child;
  final double? width;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .95),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white, width: 1),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF50729F).withValues(alpha: .24),
            blurRadius: 26,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// 底部控制栏
/// 进度条（左 00:25 / 右 10:34）+ 播放暂停 · 下一集 · 选集 · ⋯设置 · 退出；
/// 倍速 / 清晰度 / 线路已收进 ⋯ 播放设置面板（onSpeed / qualityLabel 只给
/// 还没迁移的调用方用，传 null / 空串即不显示）。
class FsBottomBar extends StatelessWidget {
  const FsBottomBar({
    super.key,
    required this.position,
    required this.duration,
    this.buffered = Duration.zero,
    required this.playing,
    required this.rate,
    required this.qualityLabel,
    this.qualityActive = false,
    this.onSeek,
    required this.onTogglePlay,
    this.onNext,
    this.onSpeed,
    this.onQuality,
    this.onEpisodes,
    this.onMore,
    required this.onExit,
    this.onJump,
    this.jumpActive = false,
    this.compact = false,
    this.bottomInset = 0,
    this.live = false,
    this.narrow = false,
  });

  final Duration position;
  final Duration duration;
  final Duration buffered;
  final bool playing;
  final double rate;

  /// 清晰度切换入口文案；空串时不显示入口。
  final String qualityLabel;

  /// 当前选中的不是主播放地址时高亮入口。
  final bool qualityActive;
  final ValueChanged<Duration>? onSeek;
  final VoidCallback onTogglePlay;
  final VoidCallback? onNext;
  final VoidCallback? onSpeed;
  final VoidCallback? onQuality;
  final VoidCallback? onEpisodes;

  /// ⋯「播放设置」入口：打开播放设置面板；null 时不显示（如直播）。
  final VoidCallback? onMore;
  final VoidCallback onExit;

  /// 底部「片头/尾」按钮：打开本剧片头 / 片尾标记面板；null 时不显示。
  final VoidCallback? onJump;

  /// 本剧已标记时高亮「片头/尾」入口。
  final bool jumpActive;
  final bool compact;
  final double bottomInset;

  /// 窄屏（竖屏全屏播放，约 360dp 宽）：底栏仍是底部横排，但把「片头/尾」
  /// 和「倍速」两个文字入口收进 ⋯ 播放设置，右侧一组不再被 FittedBox 缩成
  /// 蚂蚁字，选集 / 齿轮 / 退出保持原尺寸好点。
  final bool narrow;

  /// 直播：隐藏进度条 / 下一集 / 倍速 / 选集，显示 LIVE，只保留
  /// 播放暂停、清晰度（线路切换）和退出全屏。
  final bool live;

  @override
  Widget build(BuildContext context) {
    final s = compact ? .9 : 1.0;
    // 刘海 / 圆角屏：左右让出安全边距，底栏按钮不压进屏幕圆角。
    //
    // 右侧比左侧多让 8dp：手机是弧形圆角屏，横屏时右下角也是圆的，
    // 只留 16dp 时「选集 / 播放设置 / 退出全屏」这一组会压进圆角被裁一截。
    // 顶栏同理（见 fs_controls 的 cornerGuard），两处保持一致。
    final safe = MediaQuery.viewPaddingOf(context);
    return Container(
      padding: EdgeInsets.fromLTRB(
        16 + safe.left,
        26,
        24 + safe.right,
        6 + bottomInset,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withValues(alpha: 0), Colors.black.withValues(alpha: .66)],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!live)
            FxSeekRow(
              position: position,
              duration: duration,
              buffered: buffered,
              onSeek: onSeek ?? (_) {},
              height: 5,
              touchHeight: 40,
              thumbSize: 16,
              labelWidth: 48,
              timeFontSize: 11,
              timeFontWeight: FontWeight.w600,
            ),
          if (!live) const SizedBox(height: 4),
          // BOTTOMBAR_3GROUP（2026-11-12）：底栏拆成「左固定 / 中弹性 / 右固定」三组。
          //
          // 之前只有一个 Row + 一个 Flexible：Flexible 里的文字按钮（片头尾/
          // 倍速/选集）会先抢宽度，左边「暂停 / 下一集」被挤到屏幕外，
          // 右边又空出一大块 —— 就是用户看到的「左边溢出、右边空」。
          //
          // 现在：
          //   左组（暂停/下一集）不参与压缩，固定宽度；
          //   中间 Spacer 吃掉所有剩余空间，把右组顶到最右；
          //   右组（文字按钮 + 齿轮 + 退出）用 FittedBox 保底，超宽时整体缩小。
          Row(
            children: [
              // ── 左组：播放 / 下一集（不压缩）──
              // FS_ICON_SPEC：底栏所有圆钮与顶栏 / 侧栏同一规格（30dp 底、
              // 19.5 图标、tint .13、44dp 热区），间距交给热区自带的留白。
              PGlassIcon.fs(
                icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                tooltip: playing ? '暂停' : '播放',
                onTap: onTogglePlay,
              ),
              const SizedBox(width: 2),
              if (live) ...[
                const _FsLiveBadge(),
              ] else ...[
                PGlassIcon.fs(
                  icon: Icons.skip_next_rounded,
                  tooltip: '下一集',
                  onTap: onNext,
                ),
              ],
              // ── 中间：吃掉剩余空间，把右组顶到最右 ──
              const Spacer(),
              // ── 右组：文字按钮 + 齿轮 + 退出 ──
              //
              // 不能包 Flexible：Flexible 的 flex 会和 Expanded/Spacer 一起
              // 平分剩余空间，右组只拿到三分之一宽度，按钮就被拉回屏幕中间，
              // 右边空出一大片。这里让它按内容自然宽度靠右，
              // 外层 Container 的 24 + safe.right 内边距负责避开弧形屏幕圆角。
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 文字胶囊只留给真正要看字的入口（片头尾 / 倍速 /
                      // 清晰度）：样式已与圆底同高同圆角同底色，见 FsTextAction。
                      if (!live && !narrow && onJump != null) ...[
                        FsTextAction(
                          text: '片头/尾',
                          size: s,
                          active: jumpActive,
                          onTap: onJump,
                        ),
                        const SizedBox(width: 8),
                      ],
                      if (!live && !narrow && onSpeed != null) ...[
                        FsTextAction(
                          text: '倍速',
                          size: s,
                          active: (rate - 1).abs() > .001,
                          onTap: onSpeed,
                        ),
                        const SizedBox(width: 8),
                      ],
                      if (qualityLabel.isNotEmpty) ...[
                        FsTextAction(
                          text: qualityLabel,
                          size: s,
                          active: qualityActive,
                          onTap: onQuality,
                        ),
                        const SizedBox(width: 8),
                      ],
                      // 「选集」是图标入口：改用统一规格的玻璃圆底，
                      // 不再用文字胶囊（用户要求同一层级外观一致）。
                      if (!live && onEpisodes != null) ...[
                        PGlassIcon.fs(
                          icon: Icons.playlist_play_rounded,
                          tooltip: '选集',
                          onTap: onEpisodes,
                        ),
                        const SizedBox(width: 2),
                      ],
                      if (onMore != null) ...[
                        PGlassIcon.fs(
                          icon: Icons.settings_rounded,
                          tooltip: '播放设置',
                          onTap: onMore,
                        ),
                        const SizedBox(width: 2),
                      ],
                      PGlassIcon.fs(
                        icon: Icons.fullscreen_exit_rounded,
                        tooltip: '退出全屏',
                        onTap: onExit,
                      ),
                    ],
                  ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 倍速弹层
class FsSpeedPanel extends StatelessWidget {
  const FsSpeedPanel({super.key, required this.rate, required this.onPick});

  final double rate;
  final ValueChanged<double> onPick;

  static const List<double> options = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    return FsGlassCard(
      width: 306,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.speed_rounded, size: 17, color: Fx.accent),
              const SizedBox(width: 6),
              const Text(
                '倍速播放',
                style: TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w800, color: Fx.ink),
              ),
              const Spacer(),
              Text(
                '当前 ${fxRateLabel(rate)}',
                style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: Fx.accent),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final v in options)
                _FsChip(
                  label: fxRateLabel(v),
                  active: (rate - v).abs() < .001,
                  width: 64,
                  onTap: () => onPick(v),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 定时关闭选中项的红字颜色（竞品同款：当前项红字高亮）。
const Color _kSleepActive = Color(0xFFE05252);

/// 定时关闭 · 右侧面板。
///
/// 条目与竞品一致：不开启（默认）/ 看完当集 / 30 分钟 / 60 分钟 / 90 分钟 /
/// 自定义分钟（1–1440）；当前项红字高亮 + 对勾。
/// 到点只暂停播放并保留进度，不退出 App。
class FsSleepPanel extends StatelessWidget {
  const FsSleepPanel({
    super.key,
    required this.mode,
    required this.minutes,
    required this.onPick,
    required this.onCustom,
  });

  final FxSleepMode mode;
  final int minutes;

  /// 选中条目：off / episode 传 minutes=0，预设分钟条目传 30 / 60 / 90。
  final void Function(FxSleepMode mode, int minutes) onPick;

  /// 自定义分钟：弹输入框（1–1440），确认后生效。
  final VoidCallback onCustom;

  /// 分钟数不在预设里 = 用户自己输入的值，高亮「自定义」这一行。
  bool get _customActive =>
      mode == FxSleepMode.minutes &&
      !AppSettings.sleepTimerOptions.contains(minutes);

  String get _currentLabel => switch (mode) {
        FxSleepMode.off => '不开启',
        FxSleepMode.episode => '看完当集',
        FxSleepMode.minutes => '$minutes 分钟',
      };

  @override
  Widget build(BuildContext context) {
    return FsGlassCard(
      width: 182,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.timer_outlined, size: 17, color: Fx.accent),
              const SizedBox(width: 6),
              const Text(
                '定时关闭',
                style: TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w800, color: Fx.ink),
              ),
              const Spacer(),
              Text(
                '当前 $_currentLabel',
                style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: _kSleepActive),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _FsSleepTile(
            label: '不开启',
            active: mode == FxSleepMode.off,
            onTap: () => onPick(FxSleepMode.off, 0),
          ),
          _FsSleepTile(
            label: '看完当集',
            active: mode == FxSleepMode.episode,
            onTap: () => onPick(FxSleepMode.episode, 0),
          ),
          for (final m in AppSettings.sleepTimerOptions)
            _FsSleepTile(
              label: '$m 分钟',
              active: mode == FxSleepMode.minutes && minutes == m,
              onTap: () => onPick(FxSleepMode.minutes, m),
            ),
          _FsSleepTile(
            label: _customActive ? '自定义 · $minutes 分钟' : '自定义分钟',
            active: _customActive,
            onTap: onCustom,
          ),
        ],
      ),
    );
  }
}

class _FsSleepTile extends StatelessWidget {
  const _FsSleepTile({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                  color: active ? _kSleepActive : Fx.ink,
                ),
              ),
            ),
            if (active)
              const Icon(Icons.check_rounded, size: 16, color: _kSleepActive),
          ],
        ),
      ),
    );
  }
}

/// 清晰度弹层。
///
/// 产品要求：只在线路提供 ≥2 个真实码率时出现；不再展示「自动」。
/// 名称完整显示（如「臻彩视听 MAX 4K」），当前档高亮。
class FsQualityPanel extends StatelessWidget {
  const FsQualityPanel({
    super.key,
    required this.items,
    required this.currentKey,
    required this.onPick,
    this.showSource = false,
  });

  final List<QualityItem> items;

  /// null 表示当前使用主播放地址。
  final String? currentKey;

  /// null 表示切回主播放地址。
  final ValueChanged<String?> onPick;

  /// 主地址不在 items 里时，用「默认」档位代表它。
  final bool showSource;

  QualityItem? get _current {
    for (final q in items) {
      if (q.key == currentKey) return q;
    }
    return null;
  }

  String get _currentLabel {
    if (currentKey == null) return '默认';
    final q = _current;
    if (q == null) return '默认';
    final name = q.name.trim();
    return name.isEmpty ? q.key : name;
  }

  @override
  Widget build(BuildContext context) {
    final options = <Widget>[
      if (showSource)
        _FsChip(
          label: '默认',
          active: currentKey == null,
          onTap: () => onPick(null),
        ),
      for (final q in items)
        _FsChip(
          label: q.name.trim().isEmpty ? q.key : q.name.trim(),
          active: currentKey == q.key,
          onTap: () => onPick(q.key),
        ),
    ];
    return FsGlassCard(
      width: 348,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.high_quality_rounded,
                  size: 17, color: Fx.accent),
              const SizedBox(width: 6),
              const Text(
                '清晰度',
                style: TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w800, color: Fx.ink),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '当前 $_currentLabel',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: Fx.accent),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: options),
          const SizedBox(height: 9),
          const Text(
            '切换后保持当前播放进度与播放状态',
            style: TextStyle(fontSize: 10.5, color: Fx.sub),
          ),
        ],
      ),
    );
  }
}

/// 「跳过片头片尾」时长面板（竖屏播放设置行弹层、全屏右下角同一套位置）。
///
/// 只手动输入分秒，不再「把当前进度设为片头 / 片尾」：两行 `[MM:SS]` 输入
/// （00:00–10:00，00:00 = 未设置 = 完全不跳），「应用」按 videoId 落盘，
/// 「清空本剧设置」把两项一起归零并删掉本剧的存储。
class FsJumpPanel extends StatefulWidget {
  const FsJumpPanel({
    super.key,
    required this.mark,
    required this.onApply,
    required this.onClear,
  });

  /// 本剧当前时长（用来回填两个输入框）。
  final VideoMark mark;

  /// 「应用」：输入框里的片头 / 片尾各多少秒（已校验在 0–10:00 内）。
  final void Function(int introSeconds, int outroSeconds) onApply;

  /// 「清空本剧设置」：删掉本剧的片头 / 片尾存储。
  final VoidCallback onClear;

  /// 秒 → 展示用 `[MM:SS]`，裁到 0–10:00。
  static String label(int seconds) {
    final total = seconds <= 0
        ? 0
        : seconds > VideoMarks.maxSeconds
            ? VideoMarks.maxSeconds
            : seconds;
    return '${fxPad2(total ~/ 60)}:${fxPad2(total % 60)}';
  }

  @override
  State<FsJumpPanel> createState() => _FsJumpPanelState();
}

class _FsJumpPanelState extends State<FsJumpPanel> {
  late final TextEditingController _introCtl;
  late final TextEditingController _outroCtl;

  /// 校验失败提示：null = 这一项没问题。
  String? _introError;
  String? _outroError;

  static const String _kRangeHint = '请输入 00:00–10:00 的分秒';

  @override
  void initState() {
    super.initState();
    _introCtl = TextEditingController(
      text: FsJumpPanel.label(widget.mark.introSeconds),
    );
    _outroCtl = TextEditingController(
      text: FsJumpPanel.label(widget.mark.outroSeconds),
    );
    _introCtl.addListener(() {
      if (_introError != null) setState(() => _introError = null);
    });
    _outroCtl.addListener(() {
      if (_outroError != null) setState(() => _outroError = null);
    });
  }

  @override
  void dispose() {
    _introCtl.dispose();
    _outroCtl.dispose();
    super.dispose();
  }

  /// 外面（清空按钮 / 另一处设置）改了本剧时长就回填输入框；
  /// 值相同不动，避免打断正在输入的光标。
  @override
  void didUpdateWidget(FsJumpPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.mark == oldWidget.mark) return;
    _fill(_introCtl, widget.mark.introSeconds);
    _fill(_outroCtl, widget.mark.outroSeconds);
    _introError = null;
    _outroError = null;
  }

  void _fill(TextEditingController ctl, int seconds) {
    final text = FsJumpPanel.label(seconds);
    if (ctl.text != text) ctl.text = text;
  }

  /// `[MM:SS]` → 秒：空串 = 未设置 = 0；没有冒号按秒读；
  /// 超出 0–10:00（含格式坏掉）返回 null，交给输入框显示错误。
  int? _parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return 0;
    final parts = text.split(':');
    if (parts.length > 2) return null;
    var seconds = 0;
    for (final part in parts) {
      if (part.isEmpty) return null;
      final n = int.tryParse(part);
      if (n == null) return null;
      seconds = seconds * 60 + n;
    }
    return seconds <= VideoMarks.maxSeconds ? seconds : null;
  }

  /// 「应用」：两项都合法才落盘，顺手把输入规范回填（90 秒 → 01:30）。
  void _apply() {
    final intro = _parse(_introCtl.text);
    final outro = _parse(_outroCtl.text);
    if (intro == null || outro == null) {
      setState(() {
        _introError = intro == null ? _kRangeHint : null;
        _outroError = outro == null ? _kRangeHint : null;
      });
      return;
    }
    final introText = FsJumpPanel.label(intro);
    final outroText = FsJumpPanel.label(outro);
    if (_introCtl.text != introText) _introCtl.text = introText;
    if (_outroCtl.text != outroText) _outroCtl.text = outroText;
    setState(() {
      _introError = null;
      _outroError = null;
    });
    widget.onApply(intro, outro);
  }

  /// 「清空本剧设置」：两个输入框一起归 00:00，存储交给调用方删。
  void _clear() {
    if (_introCtl.text != '00:00') _introCtl.text = '00:00';
    if (_outroCtl.text != '00:00') _outroCtl.text = '00:00';
    setState(() {
      _introError = null;
      _outroError = null;
    });
    widget.onClear();
  }

  @override
  Widget build(BuildContext context) {
    final mark = widget.mark;
    return FsGlassCard(
      width: 316,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bookmark_border_rounded,
                  size: 17, color: Fx.gold),
              const SizedBox(width: 6),
              const Text(
                '跳过片头片尾',
                style: TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w800, color: Fx.ink),
              ),
              const Spacer(),
              Text(
                mark.isEmpty
                    ? '未设置'
                    : '片头 ${FsJumpPanel.label(mark.introSeconds)}'
                        ' · 片尾 ${FsJumpPanel.label(mark.outroSeconds)}',
                style: const TextStyle(fontSize: 10.5, color: Fx.sub),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '手动输入分秒（00:00–10:00）；填 00:00 = 未设置，完全不跳',
            style: TextStyle(fontSize: 10.5, color: Fx.sub, height: 1.4),
          ),
          const SizedBox(height: 8),
          _FsJumpField(
            label: '片头',
            controller: _introCtl,
            error: _introError,
            help: '播放到该时长自动跳到片头结束（跳过前 N 秒）',
          ),
          const SizedBox(height: 6),
          _FsJumpField(
            label: '片尾',
            controller: _outroCtl,
            error: _outroError,
            help: '时长-位置 ≤ 该值时跳到结尾 / 自动下一集',
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _FsJumpButton(label: '应用', primary: true, onTap: _apply),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _FsJumpButton(
                    label: '清空本剧设置', primary: false, onTap: _clear),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 一行时长输入：`片头 [MM:SS]` 输入框 + 帮助 / 校验提示。
class _FsJumpField extends StatelessWidget {
  const _FsJumpField({
    required this.label,
    required this.controller,
    required this.help,
    this.error,
  });

  final String label;
  final TextEditingController controller;
  final String help;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 34,
              child: Text(
                label,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700, color: Fx.ink),
              ),
            ),
            Expanded(
              child: TextField(
                controller: controller,
                // 数字键盘就够：冒号由 [_MmSsFormatter] 自动补。
                keyboardType: TextInputType.number,
                inputFormatters: const [_MmSsFormatter()],
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Fx.ink,
                  letterSpacing: .8,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '00:00',
                  hintStyle: const TextStyle(fontSize: 14, color: Fx.sub),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                  filled: true,
                  fillColor: const Color(0xFFF3F6FC),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Fx.accent),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          error ?? help,
          style: TextStyle(
            fontSize: 10,
            height: 1.3,
            color: error == null ? Fx.sub : const Color(0xFFE5484D),
          ),
        ),
      ],
    );
  }
}

/// 面板底部按钮：「应用」渐变主按钮，「清空本剧设置」浅灰次按钮。
class _FsJumpButton extends StatelessWidget {
  const _FsJumpButton({
    required this.label,
    required this.primary,
    required this.onTap,
  });

  final String label;
  final bool primary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: primary ? Fx.brand : null,
          color: primary ? null : const Color(0xFFF3F6FC),
          border: primary ? null : Border.all(color: const Color(0xFFE7EDF7)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: primary ? Colors.white : Fx.ink,
          ),
        ),
      ),
    );
  }
}

/// 分秒输入格式化：只留数字（最多 4 位），冒号插在最后两位前，
/// 依次键入 `1` `3` `0` → `1:30`，`1000` → `10:00`，`30` → `30`（30 秒）。
/// 数字键盘即可完成分:秒输入；0–10:00 的校验在点「应用」时做。
class _MmSsFormatter extends TextInputFormatter {
  const _MmSsFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    // 超过 4 位（> 10:00）多打的数字直接丢掉。
    final kept = digits.length > 4 ? digits.substring(0, 4) : digits;
    final text = _mmSs(kept);

    // 光标跟着「前面有几个数字」走：改中间也不会乱跳。
    var cursor = newValue.selection.baseOffset;
    if (cursor < 0 || cursor > newValue.text.length) {
      cursor = newValue.text.length;
    }
    final before =
        newValue.text.substring(0, cursor).replaceAll(RegExp(r'\D'), '').length;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: _offsetAfter(text, before)),
    );
  }

  /// 展示：≤2 位原样（就是秒）；再多把冒号插在最后两位前。
  static String _mmSs(String digits) => digits.length <= 2
      ? digits
      : '${digits.substring(0, digits.length - 2)}:'
          '${digits.substring(digits.length - 2)}';

  /// [text] 里数够 [count] 个数字之后的下标（0 个在开头，数不到在末尾）。
  static int _offsetAfter(String text, int count) {
    if (count <= 0) return 0;
    var seen = 0;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c < 48 || c > 57) continue;
      seen++;
      if (seen == count) return i + 1;
    }
    return text.length;
  }
}

class _FsChip extends StatelessWidget {
  const _FsChip({
    required this.label,
    required this.active,
    required this.onTap,
    this.width,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: width,
        alignment: width == null ? null : Alignment.center,
        padding: EdgeInsets.symmetric(
            horizontal: width == null ? 13 : 0, vertical: 8),
        decoration: BoxDecoration(
          color: active ? Fx.accent : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border:
              Border.all(color: active ? Fx.accent : const Color(0xFFE4EAF4)),
          boxShadow: [
            BoxShadow(
              color: Fx.accent.withValues(alpha: active ? .28 : .04),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Text(
          label,
          maxLines: width == null ? 2 : 1,
          overflow:
              width == null ? TextOverflow.visible : TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            height: 1.15,
            fontWeight: active ? FontWeight.w700 : FontWeight.w600,
            color: active ? Colors.white : Fx.sub,
          ),
        ),
      ),
    );
  }
}

/// 打开右侧选集面板，返回选中的集数；取消返回 null。
///
/// SIDE_PANEL（2026-11-20）：从「底部抽屉」改成「右侧竖排面板」，和
/// 「播放设置」共用 `FxSidePanel` 壳体 —— 宽度 / 圆角 / 背景 / × / 外点
/// 关闭全部一致，不会再出现两个面板长得不一样。
Future<int?> showFsEpisodeSheet(
  BuildContext context, {
  required List<Episode> episodes,
  required int current,
  String title = '',
}) {
  return showFxSidePanel<int>(
    context,
    builder: (_) => FsEpisodeSheet(
      episodes: episodes,
      current: current,
      title: title,
    ),
  );
}

/// 右侧选集面板：标题「选集 · 第N集 · 共M集」+ 5 列正方形数字网格。
///
/// 当前集紫色实底白字；长剧集上下滚，打开时自动定位到当前集。
class FsEpisodeSheet extends StatefulWidget {
  const FsEpisodeSheet({
    super.key,
    required this.episodes,
    required this.current,
    this.title = '',
  });

  final List<Episode> episodes;
  final int current;

  /// 附带片名（一起看房间用）；空串只显示「选集 · 第N集 · 共M集」。
  final String title;

  @override
  State<FsEpisodeSheet> createState() => _FsEpisodeSheetState();
}

class _FsEpisodeSheetState extends State<FsEpisodeSheet> {
  /// 网格列数：腾讯视频就是 5 列（EPISODE_GRID_5）。
  static const int _columns = 5;

  /// 格子间距；格子本身正方形（childAspectRatio: 1）。
  static const double _gap = 8;

  /// 网格左右内边距。
  static const double _padH = 16;

  /// 网格滚动控制器：打开时直接跳到当前集那一行。
  final ScrollController _scroll = ScrollController();

  /// 只自动定位一次：用户手动滑走之后重建不能又把位置拽回来。
  bool _located = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 自动定位到当前集。
  ///
  /// 不用 `ensureVisible`：GridView 是懒加载的，100 集的剧里当前集那一格
  /// 可能还没建出来 —— 拿不到 context 就永远不会定位。这里改成按
  /// 「第几行 × 行高」一次 jumpTo，格子边长由 [LayoutBuilder] 给的可用宽度
  /// 现算（面板宽度随屏幕变，不能写死）。
  void _locateCurrent(double contentWidth) {
    if (_located) return;
    final index = widget.episodes.indexWhere((e) => e.n == widget.current);
    if (index < 0) return;
    final cell = (contentWidth - _padH * 2 - _gap * (_columns - 1)) / _columns;
    if (cell <= 0) return;
    _located = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      final row = index ~/ _columns;
      // 当前集停在视口偏上（35%）的位置，前后集都能顺带看到。
      final target = row * (cell + _gap) -
          _scroll.position.viewportDimension * .35 +
          cell / 2;
      _scroll.jumpTo(target.clamp(0.0, max).toDouble());
    });
  }

  String _labelFor(int n) {
    for (final e in widget.episodes) {
      if (e.n == n) return fxEpisodeLabel(e.n, e.name);
    }
    return fxEpisodeLabel(n);
  }

  @override
  Widget build(BuildContext context) {
    final episodes = widget.episodes;
    final current = widget.current;
    final total = episodes.length;
    // 「共 M 集」按主剧情集算（花絮 / 预告不计入总数），和详情页一致。
    final count = total == 0 ? 0 : fxMainEpisodeCount(episodes);
    return FxSidePanel(
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '选集 · ${_labelFor(current)} · 共 ${count == 0 ? total : count} 集',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: kFxSidePanelInk,
            ),
          ),
          if (widget.title.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: kFxSidePanelSub),
            ),
          ],
        ],
      ),
      child: total == 0
          ? const Center(
              child: Text(
                '暂无剧集信息',
                style: TextStyle(fontSize: 12, color: kFxSidePanelSub),
              ),
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                _locateCurrent(constraints.maxWidth);
                return GridView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(_padH, 14, _padH, 22),
              physics: const ClampingScrollPhysics(),
              itemCount: total,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _columns,
                // 正方形格子：宽 = 高。
                childAspectRatio: 1,
                crossAxisSpacing: _gap,
                mainAxisSpacing: _gap,
              ),
              itemBuilder: (context, i) {
                final e = episodes[i];
                final active = e.n == current;
                // 只显示两位数字（01 02 … 99），不显示「第N集」。
                final label = e.n.toString().padLeft(2, '0');
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).pop(e.n),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      // 当前集：紫色实底 + 白字（SIDE_PANEL 强调色）。
                      color: active
                          ? kFxSidePanelAccent
                          : const Color(0x1AFFFFFF),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: active
                            ? kFxSidePanelAccent
                            : const Color(0x24FFFFFF),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: kFxSidePanelAccent.withValues(
                            alpha: active ? .38 : .0,
                          ),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Text(
                      label,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight:
                            active ? FontWeight.w700 : FontWeight.w500,
                        color: active ? Colors.white : kFxSidePanelInk,
                        letterSpacing: .4,
                      ),
                    ),
                  ),
                );
              },
                );
              },
            ),
    );
  }
}

/// 底部控制条的 LIVE 标识：红点 + LIVE + 当前线路。
class _FsLiveBadge extends StatelessWidget {
  const _FsLiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFFF4D4F).withValues(alpha: .20),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFF6B6B).withValues(alpha: .55)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 6, color: Color(0xFFFF5A5A)),
          SizedBox(width: 5),
          Text(
            'LIVE',
            style: TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: .5,
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models.dart';
import '../services/app_settings.dart';
import '../services/video_marks.dart';
import '../theme.dart';
import 'fs_controls.dart';
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
    this.danmuOn,
    this.onDanmu,
    this.onDanmuSettings,
    this.onDanmuSend,
    required this.onExit,
    this.onJump,
    this.jumpActive = false,
    this.compact = false,
    this.bottomInset = 0,
    this.live = false,
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

  /// 弹幕当前开关状态；null 时不显示弹幕按钮（如直播）。
  final bool? danmuOn;

  /// 点弹幕按钮：切换开关。
  final VoidCallback? onDanmu;

  /// 点弹幕设置：打开弹幕设置面板。
  final VoidCallback? onDanmuSettings;

  /// 点气泡：打开发送弹幕输入。
  final VoidCallback? onDanmuSend;
  final VoidCallback onExit;

  /// 底部「片头/尾」按钮：打开本剧片头 / 片尾标记面板；null 时不显示。
  final VoidCallback? onJump;

  /// 本剧已标记时高亮「片头/尾」入口。
  final bool jumpActive;
  final bool compact;
  final double bottomInset;

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
          Row(
            children: [
              PGlassIcon(
                icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: 34 * s,
                iconSize: 19 * s,
                tint: .16,
                tooltip: playing ? '暂停' : '播放',
                onTap: onTogglePlay,
              ),
              const SizedBox(width: 8),
              if (live) ...[
                const _FsLiveBadge(),
                const Spacer(),
              ] else ...[
                PGlassIcon(
                  icon: Icons.skip_next_rounded,
                  size: 34 * s,
                  iconSize: 19 * s,
                  tint: .16,
                  tooltip: '下一集',
                  onTap: onNext,
                ),
                // 弹幕三件套紧跟「下一集」右边：
                // 开关 → 设置 → 发送（用户指定顺序）
                if (danmuOn != null) ...[
                  const SizedBox(width: 8),
                  PGlassIcon(
                    icon: danmuOn!
                        ? Icons.subtitles_rounded
                        : Icons.subtitles_off_rounded,
                    size: 34 * s,
                    iconSize: 20 * s,
                    tint: danmuOn! ? .22 : .10,
                    active: danmuOn!,
                    tooltip: danmuOn! ? '关闭弹幕' : '开启弹幕',
                    onTap: onDanmu,
                  ),
                ],
                if (onDanmuSettings != null) ...[
                  const SizedBox(width: 8),
                  PGlassIcon(
                    icon: Icons.tune_rounded,
                    size: 34 * s,
                    iconSize: 19 * s,
                    tint: .16,
                    tooltip: '弹幕设置',
                    onTap: onDanmuSettings,
                  ),
                ],
                if (onDanmuSend != null) ...[
                  const SizedBox(width: 8),
                  PGlassIcon(
                    icon: Icons.chat_bubble_outline_rounded,
                    size: 34 * s,
                    iconSize: 18 * s,
                    tint: .16,
                    tooltip: '发弹幕',
                    onTap: onDanmuSend,
                  ),
                ],
                const Spacer(),
              ],
              // 中段文字按钮：窄屏 / 刘海屏放不下时整体缩小，绝不挤出屏幕。
              Flexible(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!live) const SizedBox(width: 10),
                        if (!live && onJump != null) ...[
                          FsTextAction(
                            text: '片头/尾',
                            size: s,
                            active: jumpActive,
                            onTap: onJump,
                          ),
                          const SizedBox(width: 8),
                        ],
                        if (!live && onSpeed != null) ...[
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
                        if (!live && onEpisodes != null) ...[
                          FsTextAction(text: '选集', size: s, onTap: onEpisodes),
                          const SizedBox(width: 8),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              // 底栏只留 ⋯ 播放设置：倍速 / 清晰度 / 线路全部收进面板。
              if (onMore != null) ...[
                PGlassIcon(
                  icon: Icons.more_horiz_rounded,
                  size: 34 * s,
                  iconSize: 21 * s,
                  tint: .16,
                  tooltip: '播放设置',
                  onTap: onMore,
                ),
                const SizedBox(width: 8),
              ],
              PGlassIcon(
                icon: Icons.fullscreen_exit_rounded,
                size: 34 * s,
                iconSize: 20 * s,
                tint: .16,
                tooltip: '退出全屏',
                onTap: onExit,
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

/// 打开底部选集抽屉，返回选中的集数；取消返回 null。
Future<int?> showFsEpisodeSheet(
  BuildContext context, {
  required List<Episode> episodes,
  required int current,
}) {
  return showModalBottomSheet<int>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    barrierColor: Colors.black.withValues(alpha: .38),
    builder: (_) => FsEpisodeSheet(episodes: episodes, current: current),
  );
}

/// 全屏底部选集抽屉：当前集高亮，打开时自动滚到可见位置。
class FsEpisodeSheet extends StatefulWidget {
  const FsEpisodeSheet({
    super.key,
    required this.episodes,
    required this.current,
  });

  final List<Episode> episodes;
  final int current;

  @override
  State<FsEpisodeSheet> createState() => _FsEpisodeSheetState();
}

class _FsEpisodeSheetState extends State<FsEpisodeSheet> {
  static const double _itemExtent = 44;
  static const double _gap = 8;

  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollToCurrent();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToCurrent() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final width = MediaQuery.sizeOf(context).width;
      final columns = (width / 86).floor().clamp(4, 9);
      final index = widget.episodes.indexWhere((e) => e.n == widget.current);
      if (index < 0) return;
      final row = index ~/ columns;
      final max = _scroll.position.maxScrollExtent;
      final target = row * (_itemExtent + _gap) -
          _scroll.position.viewportDimension / 2 +
          _itemExtent / 2;
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
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    // EPISODE_SHEET_FIT（2026-11-12）：按「实际可用高度」算，不是按屏幕高度。
    // 全屏播放是横屏，size.height 拿到的是竖屏高度，减掉安全区后
    // 弹窗会超出可见区域 → 底部集数被裁掉。这里改用 constraints 的实际高度。
    final avail = (size.height - pad.top - pad.bottom - 24)
        .clamp(220.0, 560.0)
        .toDouble();
    final height = avail;
    final width = size.width;
    final columns = (width / 86).floor().clamp(4, 9);
    final current = widget.current;
    final total = widget.episodes.length;
    final count = fxMainEpisodeCount(widget.episodes);
    return Container(
      height: height,
      decoration: BoxDecoration(
        // 全屏播放里弹窗用深色，白底在暗画面里太刺眼。
        color: const Color(0xFF16181D),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 14, 10),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    gradient: Fx.brand,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.video_library_rounded,
                      size: 17, color: Colors.white),
                ),
                const SizedBox(width: 9),
                const Text(
                  '选集',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${_labelFor(current)} · 共 $count 集',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11.5, color: Color(0xFF9AA3B2)),
                  ),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).pop(),
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(Icons.close_rounded,
                        size: 20, color: Color(0xFF9AA3B2)),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF2A2E36)),
          Expanded(
            child: total == 0
                ? const Center(
                    child: Text(
                      '暂无剧集信息',
                      style: TextStyle(fontSize: 12, color: Color(0xFF9AA3B2)),
                    ),
                  )
                : GridView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 22),
                    itemCount: total,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisExtent: _itemExtent,
                      crossAxisSpacing: _gap,
                      mainAxisSpacing: _gap,
                    ),
                    itemBuilder: (context, i) {
                      final e = widget.episodes[i];
                      final active = e.n == current;
                      // 只显示两位数字（01 02 … 99），不显示「第N集」。
                      final label = e.n.toString().padLeft(2, '0');
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => Navigator.of(context).pop(e.n),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 140),
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          decoration: BoxDecoration(
                            gradient: active ? Fx.brand : null,
                            color: active ? null : const Color(0xFF23262E),
                            borderRadius: BorderRadius.circular(11),
                            border: Border.all(
                              color: active
                                  ? Colors.transparent
                                  : const Color(0xFF31353F),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color:
                                    Fx.accent.withValues(alpha: active ? .28 : .03),
                                blurRadius: 10,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          // 纯两位数：不用 Flexible/ellipsis，
                          // 之前「第N集」占位太长被截成「第…」。
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Text(
                                label,
                                maxLines: 1,
                                style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: active
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: Colors.white,
                                  letterSpacing: .4,
                                ),
                              ),
                              if (active)
                                const Positioned(
                                  left: 4,
                                  child: Icon(Icons.play_arrow_rounded,
                                      size: 12, color: Colors.white),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
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

/* ========================================================================== */
/*  弹幕设置面板                                                               */
/* ========================================================================== */

/// 弹幕设置 · 右侧面板。
///
/// 用户要求（2026-11-12）：弹幕开关和设置在播放界面，不要藏到设置页。
///
/// 内容：
///   · 总开关（关掉后整层弹幕不渲染）
///   · 透明度 20%–100%（滑杆，实时生效）
///   · 字号 11–24（滑杆，实时生效）
///   · 弹幕量提示（当前这集有多少条）
class FsDanmuPanel extends StatelessWidget {
  const FsDanmuPanel({
    super.key,
    required this.enabled,
    required this.opacity,
    required this.fontSize,
    required this.speed,
    required this.area,
    required this.count,
    required this.onToggle,
    required this.onOpacity,
    required this.onFontSize,
    required this.onSpeed,
    required this.onArea,
    required this.onClose,
  });

  final bool enabled;
  final double opacity;
  final double fontSize;

  /// 滚动速度倍率（0.5 - 2.0）。
  final double speed;

  /// 弹幕占画面高度比例（0.3 - 1.0）。
  final double area;

  /// 当前集弹幕条数（0 表示这个平台没有弹幕库）。
  final int count;

  final ValueChanged<bool> onToggle;
  final ValueChanged<double> onOpacity;
  final ValueChanged<double> onFontSize;
  final ValueChanged<double> onSpeed;
  final ValueChanged<double> onArea;
  final VoidCallback onClose;

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
              const Icon(Icons.subtitles_rounded, size: 17, color: Fx.accent),
              const SizedBox(width: 6),
              const Text(
                '弹幕设置',
                style: TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w800, color: Fx.ink),
              ),
              const Spacer(),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onClose,
                child: const Icon(Icons.close_rounded,
                    size: 17, color: Fx.sub),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 总开关
          Row(
            children: [
              const Text(
                '显示弹幕',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Fx.ink),
              ),
              const SizedBox(width: 6),
              Text(
                count > 0 ? '$count 条' : '暂无弹幕',
                style: const TextStyle(fontSize: 10.5, color: Fx.sub),
              ),
              const Spacer(),
              Switch(
                value: enabled,
                onChanged: onToggle,
                activeThumbColor: Fx.accent,
              ),
            ],
          ),
          if (enabled) ...[
            const SizedBox(height: 6),
            _sliderRow(
              icon: Icons.opacity_rounded,
              label: '不透明度',
              valueText: '${(opacity * 100).round()}%',
              value: opacity,
              min: 0.2,
              max: 1.0,
              onChanged: onOpacity,
            ),
            const SizedBox(height: 8),
            _sliderRow(
              icon: Icons.format_size_rounded,
              label: '字号',
              valueText: fontSize.round().toString(),
              value: fontSize,
              min: 11,
              max: 24,
              onChanged: onFontSize,
            ),
            const SizedBox(height: 8),
            _sliderRow(
              icon: Icons.speed_rounded,
              label: '滚动速度',
              valueText: '${speed.toStringAsFixed(1)}x',
              value: speed,
              min: 0.5,
              max: 2.0,
              onChanged: onSpeed,
            ),
            const SizedBox(height: 8),
            _sliderRow(
              icon: Icons.crop_free_rounded,
              label: '显示区域',
              valueText: '${(area * 100).round()}%',
              value: area,
              min: 0.3,
              max: 1.0,
              onChanged: onArea,
            ),
          ],
        ],
      ),
    );
  }

  Widget _sliderRow({
    required IconData icon,
    required String label,
    required String valueText,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 14, color: Fx.sub),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(fontSize: 11.5, color: Fx.sub),
            ),
            const Spacer(),
            Text(
              valueText,
              style: const TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w700, color: Fx.accent),
            ),
          ],
        ),
        SizedBox(
          height: 28,
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: Fx.accent,
              inactiveTrackColor: const Color(0xFFE3E9F2),
              thumbColor: Colors.white,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}

/// 弹出弹幕设置面板（全屏播放右侧浮层）。
Future<void> showFsDanmuPanel(
  BuildContext context, {
  required int count,
  required ValueChanged<bool> onToggle,
  required ValueChanged<double> onOpacity,
  required ValueChanged<double> onFontSize,
  required ValueChanged<double> onSpeed,
  required ValueChanged<double> onArea,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '弹幕设置',
    barrierColor: Colors.black.withValues(alpha: .28),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (ctx, _, __) => const SizedBox.shrink(),
    transitionBuilder: (ctx, anim, _, __) {
      final a = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: a,
        child: ScaleTransition(
          scale: Tween<double>(begin: .96, end: 1).animate(a),
          child: Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: EdgeInsets.only(
                right: 16,
                top: MediaQuery.paddingOf(ctx).top + 60,
                bottom: MediaQuery.paddingOf(ctx).bottom + 60,
              ),
              child: SingleChildScrollView(
                child: StatefulBuilder(
                  builder: (ctx2, setSt) {
                    final s = AppSettings.instance;
                    return FsDanmuPanel(
                      enabled: s.danmuEnabled,
                      opacity: s.danmuOpacity,
                      fontSize: s.danmuFontSize,
                      speed: s.danmuSpeed,
                      area: s.danmuArea,
                      count: count,
                      onToggle: (v) {
                        onToggle(v);
                        setSt(() {});
                      },
                      onOpacity: (v) {
                        onOpacity(v);
                        setSt(() {});
                      },
                      onFontSize: (v) {
                        onFontSize(v);
                        setSt(() {});
                      },
                      onSpeed: (v) {
                        onSpeed(v);
                        setSt(() {});
                      },
                      onArea: (v) {
                        onArea(v);
                        setSt(() {});
                      },
                      onClose: () => Navigator.of(ctx2).pop(),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

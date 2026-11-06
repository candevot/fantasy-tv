import 'package:flutter/material.dart';

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
    return Container(
      padding: EdgeInsets.fromLTRB(16, 26, 16, 6 + bottomInset),
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
                const Spacer(),
                const SizedBox(width: 10),
                if (onJump != null) ...[
                  FsTextAction(
                    text: '片头/尾',
                    size: s,
                    active: jumpActive,
                    onTap: onJump,
                  ),
                  const SizedBox(width: 8),
                ],
                if (onSpeed != null) ...[
                  FsTextAction(
                    text: '倍速',
                    size: s,
                    active: (rate - 1).abs() > .001,
                    onTap: onSpeed,
                  ),
                  const SizedBox(width: 8),
                ],
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

/// 片头 / 片尾标记面板（底部「片头/尾」按钮、播放设置行点开）。
///
/// 两行设置 + 一行清除：把当前播放位置记成「片头结束 / 片尾开始」，
/// 按 videoId 存 SharedPreferences（见 [VideoMarks]）；没有标记 = 什么都不跳。
class FsJumpPanel extends StatelessWidget {
  const FsJumpPanel({
    super.key,
    required this.position,
    required this.mark,
    required this.onMarkIntro,
    required this.onMarkOutro,
    required this.onClear,
  });

  /// 面板打开期间的当前播放位置（由调用方随播放进度重建）。
  final Duration position;
  final VideoMark mark;
  final VoidCallback onMarkIntro;
  final VoidCallback onMarkOutro;
  final VoidCallback onClear;

  static String _at(int? seconds) =>
      seconds == null ? '未标记' : fxTime(Duration(seconds: seconds));

  @override
  Widget build(BuildContext context) {
    final now = fxTime(position);
    return FsGlassCard(
      width: 306,
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
                '片头 / 片尾',
                style: TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w800, color: Fx.ink),
              ),
              const Spacer(),
              Text(
                '本剧：片头 ${_at(mark.introEnd)} · 片尾 ${_at(mark.outroStart)}',
                style: const TextStyle(fontSize: 10.5, color: Fx.sub),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '标记只对本剧生效，每集到点各跳一次；未标记时不跳',
            style: TextStyle(fontSize: 10.5, color: Fx.sub, height: 1.4),
          ),
          const SizedBox(height: 6),
          _FsJumpTile(
            icon: Icons.fast_forward_rounded,
            title: '将当前 $now 设为片头结束',
            subtitle: mark.hasIntro
                ? '本剧片头结束 ${_at(mark.introEnd)} · 点按修改'
                : '本剧尚未标记片头',
            onTap: onMarkIntro,
          ),
          _FsJumpTile(
            icon: Icons.last_page_rounded,
            title: '将当前 $now 设为片尾开始',
            subtitle: mark.hasOutro
                ? '本剧片尾开始 ${_at(mark.outroStart)} · 点按修改'
                : '本剧尚未标记片尾',
            onTap: onMarkOutro,
          ),
          _FsJumpTile(
            icon: Icons.delete_outline_rounded,
            title: '清除本剧标记',
            subtitle: mark.isEmpty
                ? '本剧还没有标记'
                : '清除后任何位置都不再自动跳',
            onTap: () {
              if (!mark.isEmpty) onClear();
            },
          ),
        ],
      ),
    );
  }
}

class _FsJumpTile extends StatelessWidget {
  const _FsJumpTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
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
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: Fx.accent.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 17, color: Fx.accent),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: Fx.ink,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 10.5, color: Fx.sub),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 18, color: Fx.sub),
          ],
        ),
      ),
    );
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
    final height = (size.height * .8).clamp(260.0, 560.0).toDouble();
    final width = size.width;
    final columns = (width / 86).floor().clamp(4, 9);
    final current = widget.current;
    final total = widget.episodes.length;
    final count = fxMainEpisodeCount(widget.episodes);
    return Container(
      height: height,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                    color: Fx.ink,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${_labelFor(current)} · 共 $count 集',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: Fx.sub),
                  ),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).pop(),
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(Icons.close_rounded, size: 20, color: Fx.sub),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFEDF1F8)),
          Expanded(
            child: total == 0
                ? const Center(
                    child: Text(
                      '暂无剧集信息',
                      style: TextStyle(fontSize: 12, color: Fx.sub),
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
                      final label = fxEpisodeLabel(e.n, e.name);
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => Navigator.of(context).pop(e.n),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 140),
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          decoration: BoxDecoration(
                            gradient: active ? Fx.brand : null,
                            color: active ? null : const Color(0xFFF6F8FC),
                            borderRadius: BorderRadius.circular(11),
                            border: Border.all(
                              color: active
                                  ? Colors.transparent
                                  : const Color(0xFFE3E9F3),
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
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (active) ...[
                                const Icon(Icons.play_arrow_rounded,
                                    size: 14, color: Colors.white),
                                const SizedBox(width: 2),
                              ],
                              Flexible(
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: active
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: active ? Colors.white : Fx.sub,
                                  ),
                                ),
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

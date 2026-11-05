import 'package:flutter/material.dart';

import '../models.dart';
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
        color: Colors.white.withOpacity(.95),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white, width: 1),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF50729F).withOpacity(.24),
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
/// 进度条（左 00:25 / 右 10:34）+ 播放暂停 · 下一集 · 片头/尾 · 倍速 ·
/// 清晰度 · 选集 · 全屏（退出）
class FsBottomBar extends StatelessWidget {
  const FsBottomBar({
    super.key,
    required this.position,
    required this.duration,
    required this.playing,
    required this.rate,
    required this.qualityLabel,
    required this.onSeek,
    required this.onTogglePlay,
    required this.onNext,
    required this.onJump,
    required this.onSpeed,
    required this.onQuality,
    required this.onEpisodes,
    required this.onExit,
    this.compact = false,
    this.bottomInset = 0,
  });

  final Duration position;
  final Duration duration;
  final bool playing;
  final double rate;
  /// 当前清晰度（自动 / 真实码率名 / 原画）
  final String qualityLabel;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onTogglePlay;
  final VoidCallback onNext;
  final VoidCallback onJump;
  final VoidCallback onSpeed;
  final VoidCallback onQuality;
  final VoidCallback onEpisodes;
  final VoidCallback onExit;
  final bool compact;
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    final s = compact ? .9 : 1.0;
    return Container(
      padding: EdgeInsets.fromLTRB(16, 26, 16, 6 + bottomInset),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withOpacity(0), Colors.black.withOpacity(.66)],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FsProgressRow(position: position, duration: duration, onSeek: onSeek),
          const SizedBox(height: 4),
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
              FsTextAction(text: '片头/尾', size: s, onTap: onJump),
              const SizedBox(width: 8),
              FsTextAction(
                text: '倍速',
                size: s,
                active: (rate - 1).abs() > .001,
                onTap: onSpeed,
              ),
              const SizedBox(width: 8),
              FsTextAction(
                text: qualityLabel,
                size: s,
                active: qualityLabel != '自动' && qualityLabel != '原画',
                onTap: onQuality,
              ),
              const SizedBox(width: 8),
              FsTextAction(text: '选集', size: s, onTap: onEpisodes),
              const SizedBox(width: 8),
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

/// 底部横滑剧集条：点击切换并保持全屏
class FsEpisodeStrip extends StatefulWidget {
  const FsEpisodeStrip({
    super.key,
    required this.episodes,
    required this.current,
    required this.onPick,
    required this.onClose,
  });

  final List<Episode> episodes;
  final int current;
  final ValueChanged<int> onPick;
  final VoidCallback onClose;

  @override
  State<FsEpisodeStrip> createState() => _FsEpisodeStripState();
}

class _FsEpisodeStripState extends State<FsEpisodeStrip> {
  static const double _itemExtent = 78;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToCurrent());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _jumpToCurrent() {
    if (!mounted || !_scroll.hasClients) return;
    final index = widget.episodes.indexWhere((e) => e.n == widget.current);
    if (index < 0) return;
    final max = _scroll.position.maxScrollExtent;
    final target = index * _itemExtent -
        _scroll.position.viewportDimension / 2 +
        _itemExtent / 2;
    _scroll.jumpTo(target.clamp(0.0, max).toDouble());
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.episodes.length;
    return FsGlassCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.video_library_rounded,
                  size: 17, color: Fx.accent),
              const SizedBox(width: 6),
              const Text(
                '选集',
                style: TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w800, color: Fx.ink),
              ),
              const SizedBox(width: 8),
              Text(
                '第${fxPad2(widget.current)}集 · 共 $count 集',
                style: const TextStyle(fontSize: 11, color: Fx.sub),
              ),
              const Spacer(),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onClose,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close_rounded, size: 18, color: Fx.sub),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 48,
            child: count == 0
                ? const Center(
                    child: Text(
                      '暂无剧集信息',
                      style: TextStyle(fontSize: 11.5, color: Fx.sub),
                    ),
                  )
                : ListView.separated(
                    controller: _scroll,
                    scrollDirection: Axis.horizontal,
                    itemCount: count,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, i) {
                      final e = widget.episodes[i];
                      final active = e.n == widget.current;
                      final label =
                          e.name.isNotEmpty ? e.name : fxEpisodeLabel(e.n);
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => widget.onPick(e.n),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          width: _itemExtent - 8,
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          decoration: BoxDecoration(
                            gradient: active ? Fx.brand : null,
                            color: active ? null : Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: active
                                  ? Colors.transparent
                                  : const Color(0xFFE3E9F3),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color:
                                    Fx.accent.withOpacity(active ? .30 : .05),
                                blurRadius: 10,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight:
                                  active ? FontWeight.w700 : FontWeight.w500,
                              color: active ? Colors.white : Fx.sub,
                            ),
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

/// 清晰度弹层：自动 + 当前线路提供的全部码率
class FsQualityPanel extends StatelessWidget {
  const FsQualityPanel({
    super.key,
    required this.items,
    required this.currentKey,
    required this.onPick,
  });

  final List<QualityItem> items;

  /// null 表示「自动」
  final String? currentKey;

  /// null 表示切回自动
  final ValueChanged<String?> onPick;

  String get _currentLabel {
    if (currentKey == null) return '自动';
    for (final q in items) {
      if (q.key == currentKey) {
        final name = q.name.trim();
        return name.isEmpty ? q.key : name;
      }
    }
    return '自动';
  }

  @override
  Widget build(BuildContext context) {
    return FsGlassCard(
      width: 330,
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
              const Spacer(),
              Text(
                '当前 $_currentLabel',
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
              _FsChip(
                label: '自动',
                active: currentKey == null,
                width: 76,
                onTap: () => onPick(null),
              ),
              for (final q in items)
                _FsChip(
                  label: q.name.trim().isEmpty ? q.key : q.name.trim(),
                  active: currentKey == q.key,
                  width: 76,
                  onTap: () => onPick(q.key),
                ),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            items.isEmpty ? '当前线路未提供多码率' : '切换后保持当前播放进度',
            style: const TextStyle(fontSize: 10.5, color: Fx.sub),
          ),
        ],
      ),
    );
  }
}

/// 片头 / 片尾弹层
class FsJumpPanel extends StatelessWidget {
  const FsJumpPanel({super.key, required this.onIntro, required this.onOutro});

  final VoidCallback onIntro;
  final VoidCallback onOutro;

  @override
  Widget build(BuildContext context) {
    return FsGlassCard(
      width: 258,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bolt_rounded, size: 17, color: Fx.gold),
              const SizedBox(width: 6),
              const Text(
                '片头 / 片尾',
                style: TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w800, color: Fx.ink),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _FsJumpTile(
            icon: Icons.fast_forward_rounded,
            title: '跳过片头',
            subtitle: '直接前进 90 秒',
            onTap: onIntro,
          ),
          _FsJumpTile(
            icon: Icons.skip_next_rounded,
            title: '跳到片尾',
            subtitle: '跳到最后一分钟',
            onTap: onOutro,
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
                color: Fx.accent.withOpacity(.12),
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
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(
            horizontal: width == null ? 12 : 0, vertical: 8),
        decoration: BoxDecoration(
          color: active ? Fx.accent : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border:
              Border.all(color: active ? Fx.accent : const Color(0xFFE4EAF4)),
          boxShadow: [
            BoxShadow(
              color: Fx.accent.withOpacity(active ? .28 : .04),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w700 : FontWeight.w600,
            color: active ? Colors.white : Fx.sub,
          ),
        ),
      ),
    );
  }
}

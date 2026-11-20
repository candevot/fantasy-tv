/// 详情页 / 一起看共用的**两行线路选择器**（LINE_GROUPS 2026-11-21）。
///
/// 用户口径：「首先分为四大类，然后下面一行才是它的子线路，选择这样，两行
/// 线路。一条选择主线，一条选择子线」。
///
/// 第一行 = 大类（源）：`幻想` + 白名单里的 jar 源（`咕噜` / `橘汁` / `剧圈`
/// / `下饭`）；第二行 = 该大类下的子线路（不带前缀，前缀已经在第一行）。
///
/// **同一个组件**必须同时用在四处，不许出现第二套样式：
///   1. 详情页线路区；
///   2. 一起看房间内线路面板；
///   3. 一起看全屏底栏的线路入口；
///   4. 一起看建房时的「选线路」一步。
///
/// 纯展示 + 回选中的线路；怎么切流（广播 switchLine / 换集）由调用方决定。
library;

import 'package:flutter/material.dart';

import '../models.dart';
import '../services/jar_sources.dart';
import '../theme.dart';

/// 一行的高度：两行固定高度，补线时原地填充、不抖布局。
const double kFxLineGroupRowHeight = 40;

/// 两行线路选择器。
class FxLineGroupSelector extends StatefulWidget {
  const FxLineGroupSelector({
    super.key,
    required this.lines,
    required this.currentLineId,
    required this.onSelected,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    this.showHint = true,
    this.selectFirstOnGroupChange = true,
  });

  /// 全部线路（自有 + jar 混在一起，组件自己按大类分组）。
  final List<LineInfo> lines;

  /// 当前线路 id（第二行据此高亮）。
  final String currentLineId;

  /// 用户点了一条子线路。
  final ValueChanged<LineInfo> onSelected;

  /// 两行 chip 的外边距（详情页 16，弹层里 0）。
  final EdgeInsets padding;

  /// 是否显示「两行怎么用」的提示小字。
  final bool showHint;

  /// 切大类时是否**立刻**选中它的第一条子线路。
  ///
  ///  · 详情页 / 播放页里是 `true`：切大类就等于开始播那一类的第一条
  ///    （用户口径：「切大类时自动选中它的第一条」）；
  ///  · 弹层里是 `false`：点了大类只把第二行换成它的子线路，用户看清了再点
  ///    具体哪一条 —— 否则点「咕噜」弹层立刻关掉，第二行根本没机会显示。
  final bool selectFirstOnGroupChange;

  @override
  State<FxLineGroupSelector> createState() => _FxLineGroupSelectorState();
}

class _FxLineGroupSelectorState extends State<FxLineGroupSelector> {
  /// 当前展开的大类 key（默认跟随正在播放的线路所属大类）。
  String _groupKey = '';

  @override
  void initState() {
    super.initState();
    _groupKey = _groupOfCurrent();
  }

  @override
  void didUpdateWidget(covariant FxLineGroupSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 播放中的线路换了大类（房主广播 / 自动切线）：第一行要跟着切过去，
    // 否则用户看到的是「高亮在 A，第二行显示的是 B」。
    final want = _groupOfCurrent();
    if (want.isNotEmpty && want != _groupKey) {
      _groupKey = want;
    }
  }

  /// 当前线路属于哪个大类；找不到就用第一个有线路的大类。
  String _groupOfCurrent() {
    final groups = fxLineGroups(widget.lines);
    final current = widget.currentLineId.trim();
    if (current.isNotEmpty) {
      for (final group in groups) {
        for (final line in group.lines) {
          if (line.id == current) return group.key;
        }
      }
    }
    for (final group in groups) {
      if (group.available) return group.key;
    }
    return kOwnLineGroupKey;
  }

  void _pickGroup(FxLineGroup group) {
    if (!group.available) return;
    setState(() => _groupKey = group.key);
    if (!widget.selectFirstOnGroupChange) return;
    // 切大类时自动选它的第一条（用户口径第 2 条）；「正在播放的那条就在
    // 这个大类里」就不动，避免自己点自己把播放打断。
    final current = widget.currentLineId.trim();
    if (group.lines.any((line) => line.id == current)) return;
    widget.onSelected(group.lines.first);
  }

  @override
  Widget build(BuildContext context) {
    final groups = fxLineGroups(widget.lines);
    var active = groups.firstWhere(
      (g) => g.key == _groupKey,
      orElse: () => groups.first,
    );
    if (!active.available) {
      final fallback = groups.where((g) => g.available);
      if (fallback.isNotEmpty) active = fallback.first;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.showHint)
          Padding(
            padding: widget.padding.copyWith(top: 0, bottom: 6),
            child: Text(
              active.own
                  ? '先选片源，再选它的线路'
                  : '${active.label} 的子线路',
              style: TextStyle(
                fontSize: 10.5,
                color: Fx.sub.withValues(alpha: .9),
              ),
            ),
          ),
        SizedBox(
          height: kFxLineGroupRowHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: widget.padding,
            itemCount: groups.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final group = groups[i];
              return _GroupChip(
                label: group.label,
                count: group.lines.length,
                own: group.own,
                active: group.key == active.key,
                // 大类里没有任何可用子线路：置灰不可点（用户口径第 4 条）。
                enabled: group.available,
                onTap: () => _pickGroup(group),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: kFxLineGroupRowHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: widget.padding,
            itemCount: active.lines.isEmpty ? 1 : active.lines.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              if (active.lines.isEmpty) {
                return _SubChip(
                  label: '暂无线路',
                  active: false,
                  enabled: false,
                  onTap: null,
                );
              }
              final line = active.lines[i];
              final name = fxLineSubName(line, active.label);
              final playing = line.id == widget.currentLineId.trim();
              return _SubChip(
                label: line.linePending
                    ? '$name · 解析中'
                    : line.lineUnavailable
                        ? '$name · 不可用'
                        : name,
                active: playing,
                enabled: true,
                onTap: () => widget.onSelected(line),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 第一行：大类 chip（幻想 / 咕噜 / 剧圈 / 橘汁 / 下饭）。
class _GroupChip extends StatelessWidget {
  const _GroupChip({
    required this.label,
    required this.count,
    required this.own,
    required this.active,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool own;
  final bool active;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = enabled ? Fx.ink : Fx.sub.withValues(alpha: .45);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? Fx.accent.withValues(alpha: .12) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active
                ? Fx.accent.withValues(alpha: .75)
                : const Color(0xFFE6EBF4),
            width: active ? 1.4 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                color: active ? Fx.accent : ink,
              ),
            ),
            if (enabled && count > 1) ...[
              const SizedBox(width: 4),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  color: Fx.sub.withValues(alpha: .8),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 第二行：子线路 chip（播放中的那条红色实底）。
class _SubChip extends StatelessWidget {
  const _SubChip({
    required this.label,
    required this.active,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool active;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? Fx.accent : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? Fx.accent : const Color(0xFFE6EBF4),
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w800 : FontWeight.w600,
            color: active
                ? Colors.white
                : (enabled ? Fx.ink : Fx.sub.withValues(alpha: .45)),
          ),
        ),
      ),
    );
  }
}

/// 弹层里用的一版：把两行选择器裹进和现有底部弹层一致的容器。
///
/// 一起看的「房间线路面板 / 全屏底栏线路入口 / 建房选线路」都走它，
/// 保证三处和详情页是同一套两行结构。
Widget fxLineGroupSheetBody({
  required List<LineInfo> lines,
  required String currentLineId,
  required ValueChanged<LineInfo> onSelected,
  String title = '播放线路',
  String subtitle = '',
}) {
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w800,
          color: Fx.ink,
        ),
      ),
      if (subtitle.trim().isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 10.5,
            color: Fx.sub.withValues(alpha: .95),
          ),
        ),
      ],
      const SizedBox(height: 10),
      Flexible(
        child: SingleChildScrollView(
          child: FxLineGroupSelector(
            lines: lines,
            currentLineId: currentLineId,
            onSelected: onSelected,
            padding: EdgeInsets.zero,
            showHint: false,
            // 弹层里点了大类只切第二行，等用户点具体子线路再返回。
            selectFirstOnGroupChange: false,
          ),
        ),
      ),
    ],
  );
}

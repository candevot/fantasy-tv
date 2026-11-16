/// 搜索结果「按源分组」（SHELL_GROUP 2026-11-16）。
///
/// 用户口径：**搜索结果按源分组显示，每个源一个分区，不是一条混排长列表**；
/// 影视壳（FongMi `CollectFragment`）的搜索页就是「左侧一列源名 + 右侧结果」，
/// 点某个源只看它。我们要的是同一件事，但默认视图要「一眼扫到所有源」，
/// 所以默认「全部」时按源切成若干组，每组一个吸顶头（源名 + 条数）+ 海报网格。
///
/// 这一层只做**纯分组与排序判定**，不碰 UI、不联网，方便
/// `test/search_group_test.dart` 逐条钉住规则：
///
///   1. 分组键 = 卡片的 `sourceLabel`（`SourceHub.relabel` 写进去的源短名：
///      咕噜 / 下饭 / 幻想 / 幻想4K…）—— 它才是「这条结果从哪个源来的」；
///   2. 没标来源的（老数据 / 主站裸记录）归到「我们自己的源」，不出现空名分区；
///   3. 组间顺序：**我们自己的源优先** → 条数多的在前 → 名字（保证顺序稳定，
///      不会每轮搜索跳来跳去）；
///   4. 组内顺序交给调用方传进来的 [sortCards]（页面传 `SearchRank.sort`：
///      分辨率 → 线路冷却 → 热度 → 时间）；
///   5. 空源不产生分组 —— 它们只出现在左侧源栏（点进去提示「该源没有这部片」）。
library;

import '../models.dart';

/// 分组时「我们自己的源」的标记。
///
/// 和 `KSource.ownResultLabel` 是同一个字符串（`CmsBridge._ownLabeled` 给
/// 主站结果统一标的）。这里不直接 import `source_hub.dart`：那个文件拖
/// shared_preferences / 网络层，纯逻辑层不该被它带进来。
const String kOwnSourceLabel = '幻想';

/// 一个源的分区。
class FxSourceGroup {
  const FxSourceGroup({
    required this.label,
    required this.cards,
    required this.own,
  });

  /// 源短名（= 卡片的 `sourceLabel`）。
  final String label;

  /// 这个源的结果，已按 [sortCards] 排好。
  final List<VideoCard> cards;

  /// 是不是「我们自己的源」（组间排序时排最前，组标题带「优先」标记）。
  final bool own;

  int get count => cards.length;

  @override
  String toString() => 'FxSourceGroup($label, $count, own=$own)';
}

/// 把 [cards] 按源分组，返回已经排好序的组列表。
///
/// [filter] 非空时只保留该源（左侧源栏点某个源）。
/// [sortCards] 决定组内顺序；不传就保持原顺序（测试 / 不需要排序的调用方）。
/// [ownLabel] 是「我们自己的源」的标签，默认 [kOwnSourceLabel]。
List<FxSourceGroup> fxGroupBySource(
  List<VideoCard> cards, {
  String filter = '',
  List<VideoCard> Function(List<VideoCard> cards)? sortCards,
  String ownLabel = kOwnSourceLabel,
}) {
  final wanted = filter.trim();
  final buckets = <String, List<VideoCard>>{};
  for (final card in cards) {
    final raw = card.sourceLabel.trim();
    // 没标来源的归到我们自己的源：宁可归错组，也不要出现一个空名字的分区。
    final key = raw.isEmpty ? ownLabel : raw;
    if (wanted.isNotEmpty && key != wanted) continue;
    (buckets[key] ??= <VideoCard>[]).add(card);
  }

  final groups = <FxSourceGroup>[
    for (final entry in buckets.entries)
      FxSourceGroup(
        label: entry.key,
        cards: sortCards == null ? entry.value : sortCards(entry.value),
        own: entry.key == ownLabel,
      ),
  ];

  groups.sort((a, b) {
    // 1. 我们自己的源永远在最前（用户口径：自己的先出）。
    if (a.own != b.own) return a.own ? -1 : 1;
    // 2. 条数多的源在前（下饭 40 → 韩圈 21 → …）。
    final byCount = b.cards.length.compareTo(a.cards.length);
    if (byCount != 0) return byCount;
    // 3. 名字兜底：同条数时顺序稳定，不会每轮搜索都跳。
    return a.label.compareTo(b.label);
  });
  return groups;
}

/// 左侧源栏的条目：`''` = 「全部」。
class FxRailEntry {
  const FxRailEntry({
    required this.label,
    required this.count,
    required this.own,
  });

  /// 源短名；空串表示「全部」。
  final String label;

  /// 这个源有几条结果（「全部」= 总条数）。
  final int count;

  /// 是不是我们自己的源。
  final bool own;

  bool get isAll => label.isEmpty;

  /// 空源：查过了但一条都没有（点进去要提示「该源没有这部片」）。
  bool get empty => !isAll && count == 0;

  String get displayName => isAll ? '全部' : label;

  @override
  String toString() => 'FxRailEntry($displayName, $count)';
}

/// 生成左侧源栏：`全部` + 每个有结果的源 + 每个查过但没结果的源。
///
/// [emptyLabels] 是「查过但没结果」的源名（页面从本轮检索计划里取，
/// 见 `SearchPage._railEntries` 的注释）；已经出现在 [groups] 里的会跳过。
/// [sortCards] 同 [fxGroupBySource]。
List<FxRailEntry> fxRailEntries(
  List<VideoCard> cards, {
  List<String> emptyLabels = const <String>[],
  List<VideoCard> Function(List<VideoCard> cards)? sortCards,
  String ownLabel = kOwnSourceLabel,
}) {
  final groups = fxGroupBySource(cards, sortCards: sortCards, ownLabel: ownLabel);
  final total = groups.fold<int>(0, (sum, g) => sum + g.count);
  final seen = <String>{};
  final out = <FxRailEntry>[
    FxRailEntry(label: '', count: total, own: false),
    for (final g in groups)
      if (seen.add(g.label))
        FxRailEntry(label: g.label, count: g.count, own: g.own),
  ];
  for (final raw in emptyLabels) {
    final label = raw.trim();
    if (label.isEmpty || !seen.add(label)) continue;
    out.add(FxRailEntry(label: label, count: 0, own: false));
  }
  return out;
}

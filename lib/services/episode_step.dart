import '../models.dart';

/// 「上一集 / 下一集」的集号计算（MEDIA_SESSION，2026-11-15）。
///
/// 为什么单独抽成纯函数：这两个判断现在有**三个消费方**，口径必须完全一致，
/// 否则系统媒体控件上会出现「按钮亮着但按了没反应」或者「明明有下一集却没有
/// 按钮」这类只能靠用户来投诉的 bug：
///
///   1. 通知栏 / 锁屏 / 耳机线控 / 车机的上一集下一集（[fxAdjacentEpisode]）；
///   2. 系统据此决定按钮显不显示（[fxHasAdjacentEpisode] → 原生 MediaSession
///      的可用命令）；
///   3. 自动连播（页面里的 `_nextEpNumber`，同一套口径）。
///
/// 规则（和详情页展示的剧集列表一致）：
///   · 有明确集数表（`detail.allEpisodes`，可能带非连续集号、可能分组）时
///     按表里的**相邻项**走，集号可能不连续（第 10 集后面是第 12 集）；
///   · 只有总集数（`detail.episodes`）时按数字 ±1，超出 1..total 就是没有；
///   · 两者都没有（电影 / 单片，total = 0）= 没有相邻集，一个按钮都不出现。
int? fxAdjacentEpisode(
  List<Episode> episodes,
  int current,
  int delta,
  int total,
) {
  if (delta == 0) return null;
  if (episodes.isNotEmpty) {
    final index = episodes.indexWhere((e) => e.n == current);
    if (index < 0) return null;
    final target = index + delta;
    if (target < 0 || target >= episodes.length) return null;
    return episodes[target].n;
  }
  final next = current + delta;
  if (total <= 0) return null;
  if (next < 1 || next > total) return null;
  return next;
}

/// 有没有相邻集（决定系统媒体控件上那个按钮显不显示）。
bool fxHasAdjacentEpisode(
  List<Episode> episodes,
  int current,
  int delta,
  int total,
) =>
    fxAdjacentEpisode(episodes, current, delta, total) != null;

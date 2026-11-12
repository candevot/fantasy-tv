import 'package:flutter/material.dart';

import '../pages/category_page.dart' show fxInt, fxStr;
import '../theme.dart';
import 'fx_cards.dart';

/// 「最近观看」横滑带 —— 带封面、进度条、集数。
///
/// 用户要求（2026-11-12）：我的界面要像腾讯/爱奇艺那样，
/// 最近观看必须带图展示，而不是一行文字。
///
/// 数据直接读本地历史（FxStore.historyKey），按 updatedAt 倒序，
/// 最多 20 条。点卡片直接续播，点「全部」进历史页。
class FxRecentRow extends StatelessWidget {
  const FxRecentRow({
    super.key,
    required this.items,
    required this.onTapItem,
    required this.onMore,
    this.maxItems = 12,
  });

  /// 历史记录原始 Map（含 id/title/cover/ep/epName/position/duration）。
  final List<Map<String, dynamic>> items;
  final ValueChanged<Map<String, dynamic>> onTapItem;
  final VoidCallback onMore;
  final int maxItems;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final list = items.take(maxItems).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const Text(
                '最近观看',
                style: TextStyle(
                  fontSize: 17,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  color: Fx.ink,
                ),
              ),
              const Spacer(),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onMore,
                child: const Row(
                  children: [
                    Text(
                      '全部',
                      style: TextStyle(fontSize: 12, color: Fx.sub),
                    ),
                    Icon(Icons.chevron_right_rounded, size: 16, color: Fx.sub),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 176,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (ctx, i) => _RecentCard(
              item: list[i],
              onTap: () => onTapItem(list[i]),
            ),
          ),
        ),
      ],
    );
  }
}

class _RecentCard extends StatelessWidget {
  const _RecentCard({required this.item, required this.onTap});

  final Map<String, dynamic> item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final title = fxStr(item['title']);
    final cover = fxStr(item['cover']);
    final ep = fxInt(item['ep'], 1);
    final epName = fxStr(item['epName']);
    final pos = fxInt(item['position'], 0);
    final dur = fxInt(item['duration'], 0);
    final progress = dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 112,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: AspectRatio(
                aspectRatio: 3 / 4,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    FxCover(url: cover, title: title, radius: 10),
                    // 底部进度条：看过的进度，一眼能看出看到哪
                    if (progress > 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          height: 3,
                          color: Colors.black.withValues(alpha: .38),
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: progress,
                            child: Container(color: Fx.accent),
                          ),
                        ),
                      ),
                    // 右上角集数角标
                    if (epName.isNotEmpty || ep > 1)
                      Positioned(
                        right: 5,
                        top: 5,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: .55),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            epName.isNotEmpty
                                ? epName
                                : (ep > 1 ? '第$ep集' : ''),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              height: 1.2,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Fx.ink,
                height: 1.25,
              ),
            ),
            if (progress > 0)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '已看 ${(progress * 100).round()}%',
                  style: const TextStyle(fontSize: 10, color: Fx.sub),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

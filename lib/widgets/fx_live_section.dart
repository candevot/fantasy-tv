import 'package:flutter/material.dart';

import '../models.dart';
import '../pages/live_groups_page.dart' show LiveChannelCard, LiveSection;
import 'fx_cards.dart';

/// 首页「直播」分区。
///
/// 用户要求：去掉顶部分类页签，把直播当成首页的一个区。
///
/// 卡片直接复用直播页已有的 [LiveChannelCard] —— 同一套视觉，
/// 用户在首页点进去和进直播页看到的是同一个样子，不用维护两份样式。
class FxLiveSectionRow extends StatelessWidget {
  const FxLiveSectionRow({
    super.key,
    required this.sections,
    required this.onMore,
    required this.onTapChannel,
    this.maxChannels = 12,
  });

  /// 按分组聚合后的直播频道（央视 / 卫视 / 地方台 …）。
  final List<LiveSection> sections;

  /// 「全部」入口：跳直播页。
  final VoidCallback onMore;

  /// 点某个频道：进直播播放页。
  final ValueChanged<LiveChannel> onTapChannel;

  final int maxChannels;

  @override
  Widget build(BuildContext context) {
    if (sections.isEmpty) return const SizedBox.shrink();
    // 扁平化：按分组顺序取频道，最多 maxChannels 个。
    final channels = <LiveChannel>[];
    for (final s in sections) {
      for (final c in s.channels) {
        if (channels.length >= maxChannels) break;
        channels.add(c);
      }
      if (channels.length >= maxChannels) break;
    }
    if (channels.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FxSectionTitle(title: '直播', onMore: onMore, moreText: '全部'),
          const SizedBox(height: 12),
          SizedBox(
            height: 118,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: channels.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (ctx, i) {
                final c = channels[i];
                return SizedBox(
                  width: 124,
                  child: LiveChannelCard(
                    channel: c,
                    onTap: () => onTapChannel(c),
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

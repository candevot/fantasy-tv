/// 搜索结果「按源分组」的规则测试（SHELL_GROUP 2026-11-16）。
///
/// 用户口径：
///   1. 结果按**源**分组，每个源一个分区（不是一条混排长列表）；
///   2. 我们自己的源优先，其余按条数多的在前；
///   3. 空源不产生分区，但左侧源栏要列出来（点进去提示「该源没有这部片」）；
///   4. 组内按分辨率排序（页面传 `SearchRank.sort`，这里用可注入的替身）。
///
/// 这一层是纯函数（`lib/services/search_group.dart`），所以这些断言不需要
/// Flutter 插件、不需要网络，`flutter test` 直接跑。
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/search_group.dart';
import 'package:fantasy_tv/services/search_relevance.dart';

/// 造一张外部源的卡片：id 按 `@src:<源key>::<vodId>` 编（和线上一致），
/// `sourceLabel` 故意塞**分类名**，用来证明分组键不看它。
VideoCard _card(String title, {String source = '', int year = 2024}) =>
    VideoCard(
      id: source.isEmpty ? 'main-$title' : '@src:$source::$title',
      title: title,
      cover: '',
      year: year,
      sourceLabel: source,
      fromSource: '',
      lineCount: 1,
    );

/// 造一张「sourceLabel 被分类名污染」的卡片（jar 源真实情况）。
VideoCard _pollutedCard(String title, String sourceKey) => VideoCard(
      id: '@src:$sourceKey::$title',
      title: title,
      cover: '',
      year: 2024,
      sourceLabel: '小学',
      fromSource: '',
      lineCount: 1,
    );

/// 假排序：把片名倒序，用来证明「组内排序用的是传进来的函数」。
List<VideoCard> _reverse(List<VideoCard> cards) =>
    cards.reversed.toList(growable: false);

void main() {
  group('fxLooksLikeAudioContent', () {
    test('相声/评书/音乐这类非影视内容被识别出来', () {
      VideoCard c(String t, {String cat = ''}) => VideoCard(
            id: '@src:明星::$t',
            title: t,
            cover: '',
            category: cat,
            sourceLabel: '明星',
          );
      expect(fxLooksLikeAudioContent(c('郭德纲｜长篇单口相声｜全本【济公传】')), isTrue);
      expect(fxLooksLikeAudioContent(c('《济公传》郭德纲评书全集')), isTrue);
      expect(fxLooksLikeAudioContent(c('某某歌曲合集')), isTrue);
      expect(fxLooksLikeAudioContent(c('济公传'), cat: '相声'), isTrue);
      // 正常影视不能误杀
      expect(fxLooksLikeAudioContent(c('济公传')), isFalse);
      expect(fxLooksLikeAudioContent(c('梦幻西游之天命之战')), isFalse);
    });
  });


    test('内部 key 显示成可读源名（u__咕噜_app → 咕噜 • APP）', () {
      final groups = fxGroupBySource(<VideoCard>[
        _pollutedCard('济公传', 'u__咕噜_app'),
        _pollutedCard('济公新传', 'u__哔哩_app'),
      ]);
      final labels = groups.map((g) => g.label).toList();
      expect(labels.any((l) => l.contains('u__')), isFalse,
          reason: '左栏/组标题不能出现内部 key');
      expect(labels.any((l) => l.contains('咕噜')), isTrue);
    });


    test('分组键只认 id 里的 @src:<源key>，sourceLabel 是分类名也不影响', () {
      // 线上真实情况：jar 源返回的 source 字段是「小学」，但 id 里带源 key。
      final groups = fxGroupBySource(<VideoCard>[
        _pollutedCard('梦幻西游', '咕噜'),
        _pollutedCard('梦幻西游2', '咕噜'),
        _pollutedCard('梦幻西游3', '下饭'),
      ]);
      expect(groups.map((g) => g.label).toList(), <String>['咕噜', '下饭']);
      expect(groups.every((g) => g.label != '小学'), isTrue);
    });


    test('按 sourceLabel 分组，每组条数正确', () {
      final groups = fxGroupBySource(<VideoCard>[
        _card('济公传', source: '咕噜'),
        _card('济公新传', source: '咕噜'),
        _card('济公传', source: '下饭'),
        _card('济公传郭德纲版', source: '下饭'),
        _card('新济公传', source: '下饭'),
      ]);
      expect(groups.length, 2);
      // 下饭 3 条 > 咕噜 2 条 → 下饭在前。
      expect(groups.first.label, '下饭');
      expect(groups.first.count, 3);
      expect(groups.last.label, '咕噜');
      expect(groups.last.count, 2);
    });

    test('我们自己的源永远排第一（哪怕条数最少）', () {
      final groups = fxGroupBySource(<VideoCard>[
        _card('济公传', source: '下饭'),
        _card('济公传', source: '下饭'),
        _card('济公传', source: '下饭'),
        _card('济公传', source: '幻想'),
      ]);
      expect(groups.first.label, kOwnSourceLabel);
      expect(groups.first.own, isTrue);
      expect(groups.first.count, 1);
      // 其余仍然按条数排。
      expect(groups[1].label, '下饭');
    });

    test('没标来源的卡片归到我们自己的源，不出现空名分区', () {
      final groups = fxGroupBySource(<VideoCard>[
        _card('济公传'),
        _card('济公传', source: '咕噜'),
      ]);
      expect(groups.map((g) => g.label), isNot(contains('')));
      final own = groups.firstWhere((g) => g.own);
      expect(own.label, kOwnSourceLabel);
      expect(own.count, 1);
    });

    test('条数相同按名字排，顺序稳定', () {
      final a = fxGroupBySource(<VideoCard>[
        _card('x', source: '乙源'),
        _card('x', source: '甲源'),
      ]);
      final b = fxGroupBySource(<VideoCard>[
        _card('x', source: '甲源'),
        _card('x', source: '乙源'),
      ]);
      expect(a.map((g) => g.label).toList(), b.map((g) => g.label).toList());
      expect(a.first.label, '乙源'); // '乙' > '甲' 的码位… 用实际比较兜住
    });

    test('filter 只留指定源（左侧源栏点某个源）', () {
      final groups = fxGroupBySource(
        <VideoCard>[
          _card('济公传', source: '咕噜'),
          _card('济公传', source: '下饭'),
        ],
        filter: '咕噜',
      );
      expect(groups.length, 1);
      expect(groups.single.label, '咕噜');
    });

    test('filter 指向一个没结果的源 → 空列表（页面据此显示「该源没有这部片」）', () {
      final groups = fxGroupBySource(
        <VideoCard>[_card('济公传', source: '咕噜')],
        filter: '布布',
      );
      expect(groups, isEmpty);
    });

    test('组内排序走传进来的 sortCards', () {
      final groups = fxGroupBySource(
        <VideoCard>[
          _card('A', source: '咕噜'),
          _card('B', source: '咕噜'),
        ],
        sortCards: _reverse,
      );
      expect(groups.single.cards.map((c) => c.title).toList(), <String>['B', 'A']);
    });

    test('空输入返回空列表', () {
      expect(fxGroupBySource(const <VideoCard>[]), isEmpty);
    });
  });

  group('fxRailEntries', () {
    test('首项是「全部」，条数 = 所有组之和', () {
      final rail = fxRailEntries(<VideoCard>[
        _card('济公传', source: '咕噜'),
        _card('济公传', source: '下饭'),
        _card('济公新传', source: '下饭'),
      ]);
      expect(rail.first.isAll, isTrue);
      expect(rail.first.displayName, '全部');
      expect(rail.first.count, 3);
      expect(rail.skip(1).map((e) => e.label).toList(), <String>['下饭', '咕噜']);
    });

    test('查过但没结果的源也列出来，count = 0 且 empty = true', () {
      final rail = fxRailEntries(
        <VideoCard>[_card('济公传', source: '咕噜')],
        emptyLabels: <String>['布布', '花卷'],
      );
      final empties = rail.where((e) => e.empty).toList();
      expect(empties.map((e) => e.label).toList(), <String>['布布', '花卷']);
      expect(empties.every((e) => e.count == 0), isTrue);
    });

    test('同一个源不会在栏里出现两次（有结果的优先）', () {
      final rail = fxRailEntries(
        <VideoCard>[_card('济公传', source: '咕噜')],
        emptyLabels: <String>['咕噜'],
      );
      expect(rail.where((e) => e.label == '咕噜').length, 1);
      expect(rail.firstWhere((e) => e.label == '咕噜').count, 1);
    });

    test('空标签 / 空白标签被忽略', () {
      final rail = fxRailEntries(
        <VideoCard>[_card('济公传', source: '咕噜')],
        emptyLabels: <String>['', '   '],
      );
      expect(rail.where((e) => e.label.trim().isEmpty).length, 1); // 只有「全部」
    });
  });
}

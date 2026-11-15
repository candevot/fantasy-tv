import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/search_relevance.dart';

/// SEARCH_RELEVANCE（2026-11-15）回归。
///
/// 现场症状：搜「济公传」，肥猫那一段出的是「背着善宰跑」「与恶魔有约」
/// 「爱情怎么翻译」「釜山行前传：首尔站」—— 完全不是搜的词。
///
/// 根因在 jar 里（`csp_Bili.searchContent(key, quick)` 把关键词当分类 id 传进
/// `categoryContent`，站点对不存在的分类回的是首页 / 合集列表），客户端改不了
/// jar，只能判相关性。这里把判据钉住：**相关的必须留，无关的必须丢**。
void main() {
  group('相关性评分', () {
    test('片名含关键词 = 1', () {
      expect(fxSearchScore('济公传', '济公传'), 1.0);
      expect(fxSearchScore('济公传[电影解说]', '济公传'), 1.0);
      expect(fxSearchScore('郭德纲济公传书场', '济公传'), 1.0);
      // 空格 / 标点 / 大小写不影响
      expect(fxSearchScore('新编 济公　传奇 国语', '济公传'), greaterThan(.9));
    });

    test('关键词含片名 = .95（搜「济公传全集」，片名是「济公传」）', () {
      expect(fxSearchScore('济公传', '济公传全集'), .95);
    });

    test('关键词片段命中（二元组）也相关', () {
      expect(fxSearchScore('济公新传', '济公传'), greaterThanOrEqualTo(.5));
      expect(fxSearchScore('Spider Man', 'spider'), 1.0);
    });

    test('现场那 4 条必须判成无关', () {
      for (final title in <String>[
        '背着善宰跑',
        '与恶魔有约',
        '爱情怎么翻译',
        '釜山行前传：首尔站',
      ]) {
        expect(
          fxSearchScore(title, '济公传'),
          lessThan(kSearchRelevanceMin),
          reason: '《$title》不该被判成「济公传」的搜索结果',
        );
      }
    });

    test('空关键词不做判断（返回 0，但过滤时会整批放行）', () {
      expect(fxSearchScore('济公传', ''), 0);
      expect(fxSearchScore('', '济公传'), 0);
    });
  });

  group('过滤一批卡片', () {
    VideoCard card(String title) => VideoCard.fromJson(<String, dynamic>{
          'id': title,
          'title': title,
          'year': '2016',
        });

    test('搜「济公传」：只留和济公传相关的', () {
      final raw = <VideoCard>[
        card('济公传'),
        card('背着善宰跑'),
        card('新编济公传奇国语'),
        card('与恶魔有约'),
        card('郭德纲济公传书场'),
        card('爱情怎么翻译'),
        card('釜山行前传：首尔站'),
      ];
      final kept = fxRelevantCards(raw, '济公传');
      expect(kept.map((c) => c.title).toList(), <String>[
        '济公传',
        '新编济公传奇国语',
        '郭德纲济公传书场',
      ]);
      // 结果里的片名必须都和关键词相关（用户要的那条验收标准）。
      for (final c in kept) {
        expect(fxSearchRelevant(c.title, '济公传'), isTrue);
      }
    });

    test('全都不相关 → 整批空（页面据此整段不显示肥猫分区）', () {
      final raw = <VideoCard>[
        card('背着善宰跑'),
        card('与恶魔有约'),
      ];
      expect(fxRelevantCards(raw, '济公传'), isEmpty);
    });

    test('空关键词 / 空列表原样返回', () {
      final raw = <VideoCard>[card('背着善宰跑')];
      expect(fxRelevantCards(raw, ''), raw);
      expect(fxRelevantCards(const <VideoCard>[], '济公传'), isEmpty);
    });
  });
}

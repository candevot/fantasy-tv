import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/source_hub.dart';

/// SOURCE_SPLIT（2026-11-15）回归。
///
/// 服务端现在把同一部剧按片源拆成**多条记录**，每条多一个
/// `vod_from_source`（hx=幻想 / xo=官采切片）。App 侧三件事必须同时成立：
///
///   1. 卡片上能看出这条是哪个片源（否则两条一模一样，像重复项）；
///   2. 去重只在**同一片源内**生效（两条都要出现）；
///   3. 换来源标记（relabel）时片源分组不能丢 —— 丢了去重就串了。
void main() {
  VideoCard card({
    required String id,
    String title = '济公传',
    int year = 2024,
    String fromSource = '',
    String source = '量子',
  }) =>
      VideoCard.fromJson(<String, dynamic>{
        'id': id,
        'title': title,
        'year': '$year',
        'sourceLabel': source,
        'fromSource': fromSource,
      });

  group('片源分组展示', () {
    // CARD_SOURCE（2026-11-15）：卡片小字只写线路名。以前拼成
    // 「幻想 · 幻想4K」，源名和线路名重复，用户看成了两行同样的字。
    test('hx → 只显示线路名（不再拼「幻想 · 」前缀）', () {
      final c = card(id: '1', fromSource: 'hx', source: '幻想4K');
      expect(c.fromSource, 'hx');
      expect(c.sourceGroupLabel, '幻想');
      expect(c.sourceLabel, '幻想4K');
      expect(c.sourceLabel.contains(' · '), isFalse);
    });

    test('xo → 只显示线路名（分组名留在 sourceGroupLabel）', () {
      final c = card(id: '2', fromSource: 'xo', source: 'SH4K');
      expect(c.sourceGroupLabel, '官采切片');
      expect(c.sourceLabel, 'SH4K');
    });

    test('老数据 / 外部源没有分组时不加前缀', () {
      final c = card(id: '3', fromSource: '', source: '红牛');
      expect(c.sourceGroupLabel, '');
      expect(c.sourceLabel, '红牛');
    });

    test('只有分组没有线路名时只显示分组', () {
      final c = card(id: '4', fromSource: 'hx', source: '');
      expect(c.sourceLabel, '幻想');
    });
  });

  group('去重键按片源分桶', () {
    test('同片名同年份的两个片源是不同的键（都要留下）', () {
      final hx = card(id: '11', fromSource: 'hx');
      final xo = card(id: '12', fromSource: 'xo');
      expect(SourceHub.dedupeKey(hx), isNot(SourceHub.dedupeKey(xo)));
    });

    test('同片源内仍然算重复', () {
      final a = card(id: '21', fromSource: 'hx');
      final b = card(id: '22', fromSource: 'hx');
      expect(SourceHub.dedupeKey(a), SourceHub.dedupeKey(b));
    });

    test('不同年份即使同片源也不去重', () {
      final a = card(id: '31', fromSource: 'xo', year: 2024);
      final b = card(id: '32', fromSource: 'xo', year: 2026);
      expect(SourceHub.dedupeKey(a), isNot(SourceHub.dedupeKey(b)));
    });
  });

  group('relabel 保留片源分组', () {
    test('换 id 换标记后 fromSource 还在', () {
      final src = card(id: '41', fromSource: 'xo');
      final out = SourceHub.relabel(src, label: '肥猫源', id: '@src:fm::41');
      expect(out.fromSource, 'xo');
      expect(out.sourceLabel, '肥猫源');
      expect(out.id, '@src:fm::41');
      // 分组没丢 → 去重键仍然带着片源。
      expect(SourceHub.dedupeKey(out), SourceHub.dedupeKey(src));
    });
  });
}

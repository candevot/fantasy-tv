import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/cms_api.dart';
import 'package:fantasy_tv/services/cms_bridge.dart';
import 'package:fantasy_tv/services/source_hub.dart';
import 'package:fantasy_tv/widgets/fs_side_panel.dart';
import 'package:flutter/material.dart';

/// UNUSABLE_RECORD / DEDUPE_LINES（2026-11-15）回归。
///
/// 现场症状：搜「济公传」一共 30 条，其中一条「我们自己」的记录点进去必
/// 加载失败，其余线路都正常。实测（线上主站）根因有两条：
///
///   1. `?line=幻想爱奇艺` 切片返回的是**平台线自己的 id**（900000003），
///      主库 `ac=detail&ids=900000003` 回空列表 —— 那条卡片点进去必然失败；
///   2. 主库同名片（202369，`幻想爱奇艺$$$红牛` 两条线路）与它同名同年，
///      但切片记录没有 `vod_from`，旧去重键（片名+片源）不同 → 两条都在
///      列表里，那一条多出来的、点不开的就是这样冒出来的。
///
/// 对应三条修法：切片 id 带线路名、同名去重保留线路多的、没有可用线路的
/// 记录在搜索/列表阶段就丢掉。这里把它们钉住。
void main() {
  group('可用线路计数（usableLineCount）', () {
    test('正常两条线路 = 2', () {
      final vod = <String, dynamic>{
        'vod_id': '202369',
        'vod_name': '济公传',
        'vod_play_from': '幻想爱奇艺\$\$\$红牛',
        'vod_play_url': '第1集\$http://a/1.m3u8#第2集\$http://a/2.m3u8'
            '\$\$\$第1集\$http://b/1.m3u8',
      };
      expect(CmsApi.usableLineCount(vod), 2);
      expect(CmsApi.hasPlayUrl(vod), isTrue);
    });

    test('线路名一堆、地址全空 = 0（空壳记录）', () {
      final vod = <String, dynamic>{
        'vod_id': '9',
        'vod_name': '空壳',
        'vod_play_from': '量子\$\$\$红牛',
        'vod_play_url': '\$\$\$',
      };
      expect(CmsApi.usableLineCount(vod), 0);
      expect(CmsApi.hasPlayUrl(vod), isFalse);
    });

    test('只有 about:blank 占位 = 0', () {
      final vod = <String, dynamic>{
        'vod_id': '10',
        'vod_name': '占位',
        'vod_play_from': '量子',
        'vod_play_url': '正片\$about:blank',
      };
      expect(CmsApi.hasPlayUrl(vod), isFalse);
    });

    test('接口没给 vod_play_url 字段（外部源搜索卡片）不算空壳', () {
      final vod = <String, dynamic>{
        'vod_id': '11',
        'vod_name': '外部源卡片',
      };
      // 计数是 0，但过滤只针对「带了播放字段却都不可用」的记录 ——
      // 外部源搜索卡片本来就不带播放地址，不能因此被丢掉。
      expect(CmsApi.usableLineCount(vod), 0);
      expect(CmsApi.hasPlayUrl(vod), isFalse);
    });
  });

  group('卡片带上线路数（lineCount）', () {
    test('cardJson 数出线路条数，VideoCard 能读到', () {
      final card = CmsApi.cardOf(<String, dynamic>{
        'vod_id': '202369',
        'vod_name': '济公传',
        'vod_year': '2016',
        'vod_play_from': '幻想爱奇艺\$\$\$红牛',
        'vod_play_url': '第1集\$http://a/1.m3u8\$\$\$第1集\$http://b/1.m3u8',
      });
      expect(card.lineCount, 2);
      expect(card.year, 2016);
    });

    test('空壳卡片 lineCount = 0', () {
      final card = CmsApi.cardOf(<String, dynamic>{
        'vod_id': '9',
        'vod_name': '空壳',
        'vod_play_from': '量子',
        'vod_play_url': '',
      });
      expect(card.lineCount, 0);
    });
  });

  group('同名记录判定（SourceHub.sameRecord）', () {
    VideoCard card({
      String id = '1',
      String title = '济公传',
      int year = 2016,
      String from = '',
      int lines = 0,
    }) =>
        VideoCard(
          id: id,
          title: title,
          cover: '',
          year: year,
          fromSource: from,
          lineCount: lines,
        );

    test('片名 + 年份相同、一方片源为空 → 同一条（切片记录并进主库记录）', () {
      final main = card(id: '202369', from: 'hx', lines: 2);
      final slice = card(id: '@line:幻想爱奇艺::900000003', lines: 1);
      expect(SourceHub.sameRecord(main, slice), isTrue);
    });

    test('hx 与 xo 两条不同片源 → 不是同一条（SOURCE_SPLIT 要并存）', () {
      expect(
        SourceHub.sameRecord(card(from: 'hx'), card(id: '2', from: 'xo')),
        isFalse,
      );
    });

    test('年份不同 → 不是同一条（同名重拍剧）', () {
      expect(
        SourceHub.sameRecord(card(year: 2016), card(id: '2', year: 2024)),
        isFalse,
      );
    });

    test('片名不同 → 不是同一条', () {
      expect(
        SourceHub.sameRecord(card(), card(id: '2', title: '新编济公传奇国语')),
        isFalse,
      );
    });
  });

  group('线路切片 id（LINE_SLICE）', () {
    test('编码 / 解析 / 取裸 id', () {
      final id = CmsBridge.sliceId('幻想爱奇艺', '900000003');
      expect(id, '@line:幻想爱奇艺::900000003');
      expect(CmsBridge.sliceOf(id), ('幻想爱奇艺', '900000003'));
      expect(CmsBridge.bareIdOf(id), '900000003');
      expect(CmsBridge.isCms(id), isTrue);
    });

    test('普通 id 不受影响', () {
      expect(CmsBridge.sliceOf('202369'), isNull);
      expect(CmsBridge.bareIdOf('202369'), '202369');
      expect(CmsBridge.sliceOf('@src:foo::123'), isNull);
      expect(CmsBridge.bareIdOf('@src:foo::123'), '123');
    });

    test('空线路名 / 空 id 不编码（退回裸 id）', () {
      expect(CmsBridge.sliceId('', '900000003'), '900000003');
      expect(CmsBridge.sliceId('幻想爱奇艺', ''), '');
    });
  });

  // SIDE_PANEL（2026-11-20）：面板从「底部弹层 + 高度上限（PANEL_CAP）」
  // 改成「右侧竖排面板」。旧断言（横屏 ≤55% 屏高、竖屏 ≤40%）随实现一起
  // 作废，改钉右侧面板的几何：宽度 = 屏宽 × 42%、不超过半屏、放得下时
  // 最少 300dp；高度 = 屏高 − 上下各 12dp。面板自身的交互（4 列图标、
  // 开关行、× 关闭、外点关闭）在 player_more_panel_test.dart 里。
  group('右侧面板宽度 / 高度（SIDE_PANEL）', () {
    Future<(double, double)> panelFor(WidgetTester tester, Size size) async {
      late double width;
      late double height;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size),
          child: Builder(
            builder: (context) {
              width = fxSidePanelWidth(context);
              height = fxSidePanelHeight(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return (width, height);
    }

    testWidgets('横屏 800×360：宽 336（42%）、高 336（上下各留 12）', (tester) async {
      final (w, h) = await panelFor(tester, const Size(800, 360));
      expect(w, closeTo(336, .01));
      expect(h, closeTo(336, .01));
    });

    testWidgets('屏宽够大时下限 300：700×400 → 300', (tester) async {
      final (w, _) = await panelFor(tester, const Size(700, 400));
      // 700 × 42% = 294 < 300，按下限取 300。
      expect(w, closeTo(300, .01));
    });

    testWidgets('绝不超半屏：1080×600 → 453.6（半屏 540）', (tester) async {
      final (w, _) = await panelFor(tester, const Size(1080, 600));
      expect(w, closeTo(453.6, .01));
      expect(w, lessThanOrEqualTo(540));
    });

    testWidgets('窄屏 360×800：半屏是硬上限（180），高 776', (tester) async {
      final (w, h) = await panelFor(tester, const Size(360, 800));
      expect(w, closeTo(180, .01));
      expect(h, closeTo(776, .01));
    });

    testWidgets('任何尺寸都贴右侧、不到屏宽', (tester) async {
      for (final size in <Size>[
        const Size(360, 640),
        const Size(640, 360),
        const Size(400, 800),
        const Size(900, 400),
        const Size(1280, 800),
      ]) {
        final (w, h) = await panelFor(tester, size);
        expect(w, greaterThan(0));
        expect(w, lessThanOrEqualTo(size.width * .5 + .01), reason: '$size');
        expect(h, closeTo(size.height - 24, .01), reason: '$size');
      }
    });
  });
}

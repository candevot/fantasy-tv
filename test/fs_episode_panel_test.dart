import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/widgets/fs_panels.dart';
import 'package:fantasy_tv/widgets/fs_side_panel.dart';
import 'package:fantasy_tv/widgets/together_picker.dart';

/// SIDE_PANEL（2026-11-20）：选集面板 = **右侧竖排面板**（腾讯视频样式）。
///
/// 钉住四件事：
///   · 标题行「选集 · 第N集 · 共M集」；
///   · 5 列网格（腾讯就是 5 列）、格子正方形、当前集紫色实底白字；
///   · 长剧集可上下滚，打开时自动定位到当前集；
///   · 壳体与播放设置共用：右侧 42% 宽、贯穿屏高、× / 外点关闭。
void main() {
  List<Episode> eps(int n) => <Episode>[
        for (var i = 1; i <= n; i++) Episode(i, '', 0),
      ];

  Future<int? Function()> pumpSheet(
    WidgetTester tester,
    Size size, {
    required List<Episode> episodes,
    required int current,
    String title = '',
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    int? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  picked = await showFsEpisodeSheet(
                    context,
                    episodes: episodes,
                    current: current,
                    title: title,
                  );
                },
                child: const Text('选集'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选集'));
    await tester.pumpAndSettle();
    return () => picked;
  }

  testWidgets('标题行：选集 · 第N集 · 共M集', (tester) async {
    await pumpSheet(tester, const Size(800, 360),
        episodes: eps(24), current: 13);
    expect(find.text('选集 · 第13集 · 共 24 集'), findsOneWidget);
  });

  testWidgets('5 列正方形网格', (tester) async {
    await pumpSheet(tester, const Size(800, 360),
        episodes: eps(24), current: 1);
    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 5, reason: '腾讯就是 5 列');
    expect(delegate.childAspectRatio, 1, reason: '格子必须是正方形');
    // 实测一格：宽 = 高。
    final cell = tester.getSize(
      find
          .ancestor(
            of: find.text('02'),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    expect(cell.width, closeTo(cell.height, .01));
  });

  testWidgets('当前集紫色实底白字', (tester) async {
    await pumpSheet(tester, const Size(800, 360),
        episodes: eps(24), current: 5);
    final cell = tester.widget<AnimatedContainer>(
      find
          .ancestor(
            of: find.text('05'),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    final deco = cell.decoration! as BoxDecoration;
    expect(deco.color, kFxSidePanelAccent);
    expect(kFxSidePanelAccent, const Color(0xFF8E6BFF), reason: '紫色实底');
    final text = tester.widget<Text>(find.text('05'));
    expect(text.style?.color, Colors.white);
    expect(text.style?.fontWeight, FontWeight.w700);
  });

  testWidgets('100 集当前第 87 集：自动定位，当前格在视口内', (tester) async {
    await pumpSheet(tester, const Size(800, 360),
        episodes: eps(100), current: 87);
    expect(find.text('87'), findsOneWidget, reason: '必须定位到当前集，不能停在开头');
    final panel = tester.getRect(find.byType(FxSidePanel));
    final cell = tester.getRect(find.text('87'));
    expect(panel.contains(cell.center), isTrue, reason: '当前集要落在面板可见区');
    // 开头几集应该已经被滚出去了。
    expect(find.text('01'), findsNothing);
  });

  testWidgets('点格子回传集数并关闭', (tester) async {
    final result = await pumpSheet(tester, const Size(800, 360),
        episodes: eps(12), current: 3);
    await tester.tap(find.text('07'));
    await tester.pumpAndSettle();
    expect(find.byType(FxSidePanel), findsNothing);
    expect(result(), 7);
  });

  testWidgets('壳体与播放设置一致：右侧 336 宽、贯穿屏高、× 关闭', (tester) async {
    await pumpSheet(tester, const Size(800, 360),
        episodes: eps(12), current: 1);
    final panel = tester.getRect(find.byType(FxSidePanel));
    expect(panel.width, closeTo(336, .01));
    expect(panel.height, closeTo(336, .01));
    expect(panel.right, closeTo(800, .01));
    await tester.tap(find.byType(FxSidePanelClose));
    await tester.pumpAndSettle();
    expect(find.byType(FxSidePanel), findsNothing);
  });

  testWidgets('点外部关闭', (tester) async {
    await pumpSheet(tester, const Size(800, 360),
        episodes: eps(12), current: 1);
    await tester.tapAt(const Offset(80, 180));
    await tester.pumpAndSettle();
    expect(find.byType(FxSidePanel), findsNothing);
  });

  testWidgets('附片名（一起看复用）：标题下行显示片名', (tester) async {
    await pumpSheet(tester, const Size(800, 360),
        episodes: eps(12), current: 2, title: '示例片名');
    expect(find.text('选集 · 第02集 · 共 12 集'), findsOneWidget);
    expect(find.text('示例片名'), findsOneWidget);
  });

  testWidgets('一起看全屏复用同一个面板（行为一致）', (tester) async {
    // 一起看全屏的「选集」走 together_page._pickEpisode →
    // showTogetherEpisodePicker，后者现在直接调 showFsEpisodeSheet。
    // 这里直接开那个入口，断言拿到的是**同一个**右侧面板 / 5 列网格。
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showTogetherEpisodePicker(
                  context,
                  episodes: eps(20),
                  current: 4,
                  title: '一起看示例',
                ),
                child: const Text('一起看选集'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('一起看选集'));
    await tester.pumpAndSettle();
    expect(find.byType(FxSidePanel), findsOneWidget);
    expect(find.text('选集 · 第04集 · 共 20 集'), findsOneWidget);
    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 5);
    await tester.tap(find.text('09'));
    await tester.pumpAndSettle();
    expect(find.byType(FxSidePanel), findsNothing);
  });

  testWidgets('空剧集：暂无剧集信息', (tester) async {
    await pumpSheet(tester, const Size(800, 360),
        episodes: const <Episode>[], current: 1);
    expect(find.text('暂无剧集信息'), findsOneWidget);
  });
}

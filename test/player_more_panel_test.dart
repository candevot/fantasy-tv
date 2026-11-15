import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fantasy_tv/widgets/player_more_panel.dart';

/// PANEL_CAP（2026-11-15）回归：播放设置面板**永远不盖满屏**。
///
/// 现场症状：横屏（屏高 ≈360dp）一开「播放设置」，面板顶到整屏高，画面全被
/// 盖住；竖屏内容多时同样顶满。旧实现只有 `mainAxisSize.min` + 没有任何
/// 高度上限，`isScrollControlled: true` 又允许弹层长到全屏。
///
/// 现在：横屏上限 = 屏高 55% 且 ≤360dp，竖屏 = 屏高 40% 且 ≤480dp，
/// 内容超出时面板内部滚动。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<void> pumpSheet(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showFxMorePanel(
                  context,
                  loopMode: FxLoopMode.off,
                  markLabel: '未设置',
                  onLoopChanged: (_) {},
                  onJumpPanel: () {},
                  onSleepTimer: () {},
                  onDownload: () {},
                  onSpeed: () {},
                  onBackground: () {},
                  onFeedback: () {},
                  diagnosticsOn: false,
                  onDiagnosticsChanged: (_) {},
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  double panelHeight(WidgetTester tester) => tester
      .getSize(
        find.ancestor(
          of: find.text('播放设置'),
          matching: find.byType(Container),
        ).first,
      )
      .height;

  testWidgets('横屏 800×360：面板高度 ≤ 屏高 55%（198）且能滚动', (tester) async {
    await pumpSheet(tester, const Size(800, 360));
    final height = panelHeight(tester);
    expect(height, lessThanOrEqualTo(198.5), reason: '横屏不许顶满屏');
    expect(height, lessThan(360 * .6));
    // 内部一定可滚：横屏 198dp 装不下 8 行，最后一行要能滑出来。
    expect(find.byType(SingleChildScrollView), findsWidgets);
    final scrollable = find.descendant(
      of: find.byType(SingleChildScrollView).first,
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsWidgets);
    await tester.drag(scrollable.first, const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(find.text('问题反馈'), findsOneWidget);
  });

  testWidgets('竖屏 360×800：面板高度 ≤ 屏高 40%（320）', (tester) async {
    await pumpSheet(tester, const Size(360, 800));
    final height = panelHeight(tester);
    expect(height, lessThanOrEqualTo(320.5), reason: '竖屏上限 40% 屏高');
    expect(height, lessThan(800 * .6));
  });

  testWidgets('平板竖屏 800×1280：上限封顶 480', (tester) async {
    await pumpSheet(tester, const Size(800, 1280));
    final height = panelHeight(tester);
    expect(height, lessThanOrEqualTo(480.5));
  });
}

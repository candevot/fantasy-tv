import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fantasy_tv/widgets/fs_side_panel.dart';
import 'package:fantasy_tv/widgets/player_more_panel.dart';

/// SIDE_PANEL（2026-11-20）：播放设置面板 = **右侧竖排面板**（腾讯视频样式）。
///
/// 旧实现（PANEL_CAP 2026-11-15）是底部通栏弹层，只靠高度上限（横屏 55%、
/// 竖屏 40%）保证「不盖满屏」。现在的要求是右侧竖排：
///   · 宽度 = 屏宽 × 42%，不超过半屏，放得下时最少 300dp；
///   · 高度 = 屏高 − 顶 12dp − 底 12dp；
///   · 只做左侧两角圆角；黑 72% + blur 18；
///   · 右上角 × 关闭，点外部关闭；
///   · 顶部 4 列等宽图标（定时关闭 / 下载本集 / 倍速 / 后台播放），
///     下面每行右侧是开关或箭头，整块可滚。
///
/// 这一组测试钉的就是上面这些数值，**功能项一个都不能少**。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<void> pumpPanel(
    WidgetTester tester,
    Size size, {
    FxLoopMode loop = FxLoopMode.off,
    bool diagnostics = false,
    ValueChanged<FxLoopMode>? onLoopChanged,
    ValueChanged<bool>? onDiagnosticsChanged,
  }) async {
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
                  loopMode: loop,
                  markLabel: '未设置',
                  onLoopChanged: onLoopChanged ?? (_) {},
                  onJumpPanel: () {},
                  onSleepTimer: () {},
                  onDownload: () {},
                  onSpeed: () {},
                  onBackground: () {},
                  onFeedback: () {},
                  diagnosticsOn: diagnostics,
                  onDiagnosticsChanged: onDiagnosticsChanged ?? (_) {},
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

  testWidgets('横屏 800×360：右侧贯穿 336×336，贴右边、上下各留 12',
      (tester) async {
    await pumpPanel(tester, const Size(800, 360));
    final rect = tester.getRect(find.byType(FxSidePanel));
    // 宽度 = 800 × 42% = 336。
    expect(rect.width, closeTo(336, .01));
    expect(rect.width, lessThanOrEqualTo(400)); // 不超过半屏
    // 高度 = 屏高 − 12 − 12。
    expect(rect.height, closeTo(336, .01));
    expect(rect.top, closeTo(12, .01));
    expect(rect.bottom, closeTo(348, .01));
    // 贴屏幕右侧。
    expect(rect.right, closeTo(800, .01));
  });

  testWidgets('宽度公式：下限 300、上限半屏', (tester) async {
    // 屏宽 1080：42% = 453.6，半屏 540 → 453.6。
    await pumpPanel(tester, const Size(1080, 600));
    expect(
      tester.getSize(find.byType(FxSidePanel)).width,
      closeTo(453.6, .01),
    );
  });

  testWidgets('窄屏竖屏 360×800：半屏是硬上限（180），高度满屏减 24', (tester) async {
    await pumpPanel(tester, const Size(360, 800));
    final rect = tester.getRect(find.byType(FxSidePanel));
    expect(rect.width, closeTo(180, .01));
    expect(rect.height, closeTo(776, .01));
  });

  testWidgets('壳体规格：左两角圆角 20 + blur 18 + 黑 72%', (tester) async {
    await pumpPanel(tester, const Size(800, 360));
    // 圆角只做左侧两角。
    final clip = tester.widget<ClipRRect>(
      find.descendant(
        of: find.byType(FxSidePanel),
        matching: find.byType(ClipRRect),
      ).first,
    );
    expect(
      clip.borderRadius,
      const BorderRadius.horizontal(
        left: Radius.circular(kFxSidePanelRadius),
      ),
    );
    expect(kFxSidePanelRadius, 20);
    // 玻璃底：BackdropFilter 存在，模糊半径 18。
    expect(
      find.descendant(
        of: find.byType(FxSidePanel),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );
    expect(kFxSidePanelBlur, 18);
    // 底色：黑 72%。
    expect(kFxSidePanelScrim, .72);
    final scrim = tester.widgetList<DecoratedBox>(
      find.descendant(
        of: find.byType(FxSidePanel),
        matching: find.byType(DecoratedBox),
      ),
    );
    expect(
      scrim.where((d) {
        final deco = d.decoration;
        return deco is BoxDecoration &&
            deco.color == Colors.black.withValues(alpha: .72);
      }),
      isNotEmpty,
      reason: '面板底色必须是黑 72%',
    );
  });

  testWidgets('图标行 4 列等宽：定时关闭 / 下载本集 / 倍速 / 后台播放', (tester) async {
    await pumpPanel(tester, const Size(800, 360));
    const labels = <String>['定时关闭', '下载本集', '倍速', '后台播放'];
    final centers = <double>[];
    for (final label in labels) {
      expect(find.text(label), findsOneWidget, reason: '不能删功能项：$label');
      centers.add(tester.getCenter(find.text(label)).dx);
    }
    // 内容宽 336 − 20 − 20 = 296，4 列 → 每列 74。
    for (var i = 1; i < centers.length; i++) {
      expect(centers[i] - centers[i - 1], closeTo(74, .5),
          reason: '4 列必须等宽');
    }
  });

  testWidgets('列表行全在：循环 / 跳过片头尾 / 画面比例 / 镜像 / 诊断 / 反馈',
      (tester) async {
    await pumpPanel(tester, const Size(800, 360));
    final scrollable = find.descendant(
      of: find.byType(FxSidePanel),
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsWidgets, reason: '内容多时必须能滚');
    for (final label in <String>['循环播放', '跳过片头片尾', '画面比例', '播放诊断', '问题反馈']) {
      await tester.scrollUntilVisible(find.text(label), 80,
          scrollable: scrollable.first);
      expect(find.text(label), findsOneWidget, reason: '不能删功能项：$label');
    }
    // 循环 / 诊断是开关（每行右侧的控件），其余是箭头。
    expect(find.byType(Switch), findsWidgets);
  });

  testWidgets('横屏高屏 800×600：两个开关（循环 / 诊断）同屏可见', (tester) async {
    await pumpPanel(tester, const Size(800, 600));
    expect(find.byType(Switch), findsNWidgets(2));
  });

  testWidgets('开关就地生效：循环 → 单集循环，诊断 → 开', (tester) async {
    FxLoopMode? loop;
    bool? diagnostics;
    await pumpPanel(
      tester,
      const Size(800, 600),
      onLoopChanged: (v) => loop = v,
      onDiagnosticsChanged: (v) => diagnostics = v,
    );
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(loop, FxLoopMode.single);
    await tester.tap(find.byType(Switch).last);
    await tester.pumpAndSettle();
    expect(diagnostics, isTrue);
    // 开关不关面板：改完还在。
    expect(find.byType(FxSidePanel), findsOneWidget);
  });

  testWidgets('右上角 × 关闭', (tester) async {
    await pumpPanel(tester, const Size(800, 360));
    expect(find.byType(FxSidePanelClose), findsOneWidget);
    await tester.tap(find.byType(FxSidePanelClose));
    await tester.pumpAndSettle();
    expect(find.byType(FxSidePanel), findsNothing);
  });

  testWidgets('点面板外部关闭', (tester) async {
    await pumpPanel(tester, const Size(800, 360));
    expect(find.byType(FxSidePanel), findsOneWidget);
    // 左侧空白区域（面板外）。
    await tester.tapAt(const Offset(60, 180));
    await tester.pumpAndSettle();
    expect(find.byType(FxSidePanel), findsNothing);
  });
}

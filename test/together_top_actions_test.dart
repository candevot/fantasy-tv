import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/widgets/together_top_actions.dart';

/* ========================================================================== */
/*  一起看 · 顶栏动作区（TOPBAR_44 / 2026-11-16）                              */
/*                                                                            */
/*  用户实测：竖屏顶栏右边「1人 / 邀请 / 投屏 / 我在操作 / 换源 / 换剧」被      */
/*  FittedBox 等比压成一串小胶囊，字和图标都极小、点不准。                       */
/*                                                                            */
/*  这里钉住四条硬口径：                                                        */
/*   1. 热区 ≥ 44dp、字号 ≥ 12sp、图标 ≥ 15dp；                                 */
/*   2. 换源 / 换剧 always，任何屏宽都直接可见；                                */
/*   3. 放不下时收进「更多」，而不是缩小；                                      */
/*   4. 组件树里不存在 FittedBox（禁止硬缩放）。                                */
/* ========================================================================== */

void main() {
  Widget host(Widget child, {double width = 360}) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(width: width, child: child),
      ),
    ),
  );

  TogetherActionItem item(
    String id, {
    required String label,
    bool always = false,
    int priority = 0,
    bool showLabel = true,
  }) => TogetherActionItem(
    id: id,
    label: label,
    icon: Icons.circle_outlined,
    always: always,
    priority: priority,
    showLabel: showLabel,
    onTap: () {},
  );

  group('togetherFitActions：放不下进「更多」，不缩放', () {
    test('全部放得下：没有 overflow', () {
      final fit = togetherFitActions(
        items: <TogetherActionSpec>[
          const TogetherActionSpec(id: 'a', width: 44, priority: 0),
          const TogetherActionSpec(id: 'b', width: 44, priority: 1),
        ],
        available: 200,
      );
      expect(fit.visible, <String>['a', 'b']);
      expect(fit.hasOverflow, isFalse);
    });

    test('always 项永不进「更多」', () {
      final fit = togetherFitActions(
        items: <TogetherActionSpec>[
          const TogetherActionSpec(
            id: 'line',
            width: 80,
            priority: 0,
            always: true,
          ),
          const TogetherActionSpec(
            id: 'drama',
            width: 80,
            priority: 0,
            always: true,
          ),
          const TogetherActionSpec(id: 'extra', width: 80, priority: 9),
        ],
        available: 170,
      );
      expect(fit.visible, containsAll(<String>['line', 'drama']));
      expect(fit.overflow, contains('extra'));
    });

    test('优先级高的留下：从最不重要的开始往「更多」挪', () {
      final fit = togetherFitActions(
        items: <TogetherActionSpec>[
          const TogetherActionSpec(id: 'p0', width: 60, priority: 0),
          const TogetherActionSpec(id: 'p1', width: 60, priority: 1),
          const TogetherActionSpec(id: 'p9', width: 60, priority: 9),
        ],
        // 三个放不下（60*3 + 6*2 = 192），但「两个 + 更多」放得下：
        // 60*2 + 间距6 + 间距6 + 更多44 = 176。
        available: 180,
      );
      expect(fit.visible, <String>['p0', 'p1']);
      expect(fit.overflow, <String>['p9']);
    });

    test('「更多」按钮本身占位：塞到极限时不会假装放得下', () {
      // 两个 100 宽 + 间距 6 = 206 > 200；「更多」44 也放不下。
      final fit = togetherFitActions(
        items: <TogetherActionSpec>[
          const TogetherActionSpec(id: 'a', width: 100, priority: 0),
          const TogetherActionSpec(id: 'b', width: 100, priority: 1),
        ],
        available: 200,
      );
      expect(fit.visible.length + fit.overflow.length, 2);
      expect(fit.hasOverflow, isTrue);
      expect(fit.visible, <String>['a']);
    });

    test('极端窄屏：always 项仍然留在 visible（宁可换行也不藏）', () {
      final fit = togetherFitActions(
        items: <TogetherActionSpec>[
          const TogetherActionSpec(
            id: 'line',
            width: 90,
            priority: 0,
            always: true,
          ),
          const TogetherActionSpec(
            id: 'drama',
            width: 90,
            priority: 0,
            always: true,
          ),
        ],
        available: 60,
      );
      expect(fit.visible, <String>['line', 'drama']);
    });
  });

  group('TogetherTopActionBar：44dp 热区 / 12sp 字号 / 不缩放', () {
    testWidgets('每个动作的热区不小于 44dp，整条只有一行 44dp 高', (tester) async {
      await tester.pumpWidget(
        host(
          TogetherTopActionBar(
            dark: false,
            maxWidth: togetherHeaderActionsBudget(400),
            actions: <TogetherActionItem>[
              item('invite', label: '邀请', always: true),
              item('line', label: '换源', always: true, showLabel: true),
            ],
          ),
          width: 400,
        ),
      );
      final buttons = tester
          .widgetList<TogetherTopActionButton>(
            find.byType(TogetherTopActionButton),
          )
          .toList();
      expect(buttons.length, 2);
      for (final button in buttons) {
        final size = tester.getSize(find.byWidget(button));
        expect(size.height, greaterThanOrEqualTo(kTogetherActionHit));
        expect(size.width, greaterThanOrEqualTo(kTogetherActionHit));
      }
      // 顶栏高度就是一行 44dp：不能因为按钮热区被撑成两行。
      expect(
        tester.getSize(find.byType(TogetherTopActionBar)).height,
        kTogetherActionHit,
      );
      expect(kTogetherActionFont, greaterThanOrEqualTo(12));
      expect(kTogetherActionHit, 44);
    });

    testWidgets('字号不小于 12sp，且不存在 FittedBox', (tester) async {
      await tester.pumpWidget(
        host(
          TogetherTopActionBar(
            dark: false,
            actions: <TogetherActionItem>[
              item('line', label: '换源', always: true),
            ],
          ),
          width: 400,
        ),
      );
      final text = tester.widget<Text>(find.text('换源'));
      expect(text.style?.fontSize, greaterThanOrEqualTo(12));
      // 反面门禁：禁止用 FittedBox 把按钮压小。
      expect(find.byType(FittedBox), findsNothing);
    });

    testWidgets('竖屏常见屏宽：始终单行 44dp，邀请 / 换源 / 换剧常驻', (tester) async {
      // 用户实测口径：竖屏顶栏必须一行放得下，且高频三项直接可见。
      // 「1人 / 投屏」在窄屏允许收进「更多」，但绝不能靠缩小来实现。
      for (final screenWidth in <double>[320, 360, 411, 480, 600]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: screenWidth,
                  child: TogetherTopActionBar(
                    dark: false,
                    maxWidth: togetherHeaderActionsBudget(screenWidth),

                    actions: <TogetherActionItem>[
                      item('members', label: '1人', priority: 2),
                      item('cast', label: '投屏', priority: 3, showLabel: false),
                      item('invite', label: '邀请', priority: 0, always: true),
                      item('line', label: '换源', priority: 0, always: true),
                      item('drama', label: '换剧', priority: 0, always: true),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'W=$screenWidth 溢出');

        // 单行：所有可见动作 top 相同，顶栏高度就是一行 44dp。
        final tops = <double>{
          for (final e in find.byType(TogetherTopActionButton).evaluate())
            tester.getRect(find.byWidget(e.widget)).top,
          for (final e in find.byType(TogetherTopMoreButton).evaluate())
            tester.getRect(find.byWidget(e.widget)).top,
        };
        expect(tops.length, 1, reason: 'W=$screenWidth 必须单行');
        expect(
          tester.getSize(find.byType(TogetherTopActionBar)).height,
          kTogetherActionHit,
          reason: 'W=$screenWidth 顶栏高度 = 一行 44dp',
        );

        // 高频三项直接可见（Tooltip 也一起找，图标降级时文字会消失）。
        for (final label in <String>['邀请', '换源', '换剧']) {
          expect(
            find.byTooltip(label),
            findsOneWidget,
            reason: 'W=$screenWidth 「$label」必须直接可见',
          );
        }
        // 热区仍然 ≥44dp。
        for (final e in find.byType(TogetherTopActionButton).evaluate()) {
          final size = tester.getSize(find.byWidget(e.widget));
          expect(size.height, greaterThanOrEqualTo(kTogetherActionHit));
          expect(size.width, greaterThanOrEqualTo(kTogetherActionHit));
        }
        // 依然没有任何缩放。
        expect(find.byType(FittedBox), findsNothing);
      }
    });

    testWidgets('宽屏（480dp 以上）五个动作全部直接可见', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 600,
                child: TogetherTopActionBar(
                  dark: false,
                  maxWidth: togetherHeaderActionsBudget(600),
                  actions: <TogetherActionItem>[
                    item('members', label: '1人', priority: 2),
                    item('cast', label: '投屏', priority: 3),
                    item('invite', label: '邀请', priority: 0, always: true),
                    item('line', label: '换源', priority: 0, always: true),
                    item('drama', label: '换剧', priority: 0, always: true),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(TogetherTopMoreButton), findsNothing);
      expect(find.text('1人'), findsOneWidget);
      expect(find.text('邀请'), findsOneWidget);
      expect(find.text('换源'), findsOneWidget);
      expect(find.text('换剧'), findsOneWidget);
    });

    testWidgets('宽屏全部直接显示，不出现「更多」', (tester) async {
      await tester.pumpWidget(
        host(
          TogetherTopActionBar(
            dark: false,
            actions: <TogetherActionItem>[
              item('members', label: '1人', priority: 2),
              item('invite', label: '邀请', priority: 3),
              item('line', label: '换源', always: true),
              item('drama', label: '换剧', always: true),
            ],
          ),
          width: 1200,
        ),
      );
      expect(find.byType(TogetherTopMoreButton), findsNothing);
      expect(find.text('1人'), findsOneWidget);
      expect(find.text('邀请'), findsOneWidget);
      expect(find.text('换源'), findsOneWidget);
      expect(find.text('换剧'), findsOneWidget);
    });

    testWidgets('「更多」菜单项热区也是 44dp', (tester) async {
      await tester.pumpWidget(
        host(
          TogetherTopActionBar(
            dark: false,
            // 320dp 屏的预算：三个 always（邀请 / 换源 / 换剧）+ 「1人」
            // 放不下，「1人」必须收进「更多」。
            maxWidth: togetherHeaderActionsBudget(320),
            actions: <TogetherActionItem>[
              item('members', label: '1人', priority: 2),
              item('invite', label: '邀请', always: true),
              item('line', label: '换源', always: true),
              item('drama', label: '换剧', always: true),
            ],
          ),
          width: 320,
        ),
      );
      await tester.tap(find.byType(TogetherTopMoreButton));
      await tester.pumpAndSettle();
      final entries = tester.widgetList<PopupMenuItem<String>>(
        find.byType(PopupMenuItem<String>),
      );
      expect(entries, isNotEmpty);
      for (final entry in entries) {
        expect(entry.height, greaterThanOrEqualTo(44));
      }
    });
  });

  group('togetherPillWidth：宽度估算（用真实字宽，不用魔法数）', () {
    test('带图标比不带图标宽，文字越长越宽', () {
      final short = togetherPillWidth('邀请');
      final shortIcon = togetherPillWidth(
        '邀请',
        icon: Icons.person_add_alt_1_rounded,
      );
      final longer = togetherPillWidth('邀请好友');
      expect(shortIcon, greaterThan(short));
      expect(longer, greaterThan(short));
    });

    test('大字体缩放会算得更宽（不靠猜，直接量）', () {
      final normal = togetherPillWidth('换剧');
      final scaled = togetherPillWidth(
        '换剧',
        textScaler: const TextScaler.linear(1.6),
      );
      expect(scaled, greaterThan(normal));
    });
  });
}

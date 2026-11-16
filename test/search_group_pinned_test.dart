/// 「组标题吸顶」的行为测试（SHELL_GROUP 2026-11-16 要求 ③）。
///
/// 用户口径：「组标题吸顶（sticky header），滚到哪个源标题就停在顶部」。
///
/// 实现用的是 Flutter 自带的 `PinnedHeaderSliver` 包在 `SliverMainAxisGroup`
/// 里 —— 这样吸顶只在**本组**范围内生效，滚到下一组时上一组的标题被顶掉
/// （正是壳 RecyclerView 分段标题的行为）。这个测试把那个语义钉死：
///   1. 滚动过程中，第 1 组的标题一直停在视口顶部（y == 0）；
///   2. 滚到第 2 组时，顶部换成了第 2 组的标题。
///
/// 只依赖 flutter_test，不联网、不需要插件。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一组：吸顶标题 + 若干占位卡片。
Widget _group(String title, int count) {
  return SliverMainAxisGroup(
    slivers: [
      PinnedHeaderSliver(
        // key 挂在**容器**上：Text 在 40dp 里垂直居中，量它得到的 y 会是 10
        // 而不是 0（第一版就踩了这个坑）。
        child: Container(
          key: ValueKey<String>('hdr-$title'),
          height: 40,
          color: Colors.white,
          alignment: Alignment.centerLeft,
          child: Text(title),
        ),
      ),
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (ctx, i) => SizedBox(
            height: 100,
            child: Text('$title-$i'),
          ),
          childCount: count,
        ),
      ),
    ],
  );
}

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: [
            _group('甲源', 6),
            _group('乙源', 6),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('组标题在本组滚动时吸顶（y 恒为 0）', (tester) async {
    await _pump(tester);
    final header = find.byKey(const ValueKey<String>('hdr-甲源'));
    expect(header, findsOneWidget);
    expect(tester.getTopLeft(header).dy, 0);

    // 在本组内滚一点：标题仍然钉在顶部。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(header, findsOneWidget);
    expect(tester.getTopLeft(header).dy, 0);
  });

  testWidgets('滚到下一组时，顶部换成下一组的标题', (tester) async {
    await _pump(tester);
    // 第 1 组：1 个 40dp 标题 + 6 × 100dp = 640dp；滚到 700 之后应进入第 2 组。
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
    await tester.pumpAndSettle();

    final second = find.byKey(const ValueKey<String>('hdr-乙源'));
    expect(second, findsOneWidget);
    expect(tester.getTopLeft(second).dy, 0);
  });
}

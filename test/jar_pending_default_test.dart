import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/jar_sources.dart';
import 'package:fantasy_tv/widgets/fx_line_group_selector.dart';

/// JAR_PENDING / JAR_FIRST（2026-11-22 用户实测 bug）回归：
///
/// 现场：点进详情页，第一行只有「幻想」，等播放之后咕噜的线路才冒出来。
/// 原因：jar 源是**异步**搜这个片名之后才把线路补进列表的，详情页先只渲染
/// 自有线路。
///
/// 用户口径（两条，缺一不可）：
///   1. jar 已就绪时，进详情页**先把咕噜大类以「加载中」占位显示**，拿到
///      线路原地填充；jar 没就绪 / 该片在咕噜里没有时，大类自动消失、
///      回落到幻想；
///   2. **默认选中咕噜的第一条子线路**（优先咕噜）。
/// 并且不允许出现「先显示幻想再突然跳成咕噜」的错位。
void main() {
  LineInfo own(String name, {int prio = 0}) =>
      LineInfo('own_$name', name, 'hls', prio);

  LineInfo jar(String from, {String vodId = '418792'}) => LineInfo(
        fxJarLineId('咕噜', vodId, from),
        '咕噜·$from',
        'hls',
        0,
      );

  /* ------------------------------------------------------- 纯函数 */

  test('占位：jar 就绪时咕噜排在幻想前面、状态是 pending', () {
    final groups = fxLineGroups(
      <LineInfo>[own('幻想4K'), own('量子')],
      pendingLabels: const <String>['咕噜'],
    );
    expect(groups, hasLength(2));
    expect(groups.first.label, '咕噜');
    expect(groups.first.pending, isTrue);
    expect(groups.first.available, isFalse);
    expect(groups.last.own, isTrue, reason: '幻想永远是自有大类');
    expect(groups.last.label, kOwnLineGroupLabel);
  });

  test('占位只对白名单源生效，且不会覆盖已经有线路的源', () {
    final groups = fxLineGroups(
      <LineInfo>[own('幻想4K'), jar('4K')],
      pendingLabels: const <String>['咕噜', '不存在的源'],
    );
    // 咕噜已经有真线路 → 不能是 pending，也不能重复出现两次。
    expect(groups.where((g) => g.label == '咕噜'), hasLength(1));
    expect(groups.firstWhere((g) => g.label == '咕噜').pending, isFalse);
    expect(groups.every((g) => g.label != '不存在的源'), isTrue);
  });

  test('默认线路：有咕噜就选咕噜第一条，没有就 null（交给健康度默认线）', () {
    final jarLines = <LineInfo>[jar('4K'), jar('量子资源')];
    final pick = fxJarDefaultLine(<LineInfo>[own('幻想4K'), ...jarLines]);
    expect(pick, isNotNull);
    expect(pick!.displayName, '咕噜·4K');
    expect(fxJarDefaultLine(<LineInfo>[own('幻想4K'), own('量子')]), isNull);
  });

  /* ------------------------------------------------------- 组件 */

  Future<void> pump(
    WidgetTester tester, {
    required List<LineInfo> lines,
    required String currentLineId,
    List<String> pendingGroups = const <String>[],
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FxLineGroupSelector(
            lines: lines,
            currentLineId: currentLineId,
            pendingGroups: pendingGroups,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('进详情页第一眼：咕噜在前、显示加载中，不是先高亮幻想', (tester) async {
    final ownLines = <LineInfo>[own('幻想4K'), own('量子')];
    // 此刻线路列表里还只有自有线路（jar 还没回来），_lineId 是幻想那条。
    await pump(
      tester,
      lines: ownLines,
      currentLineId: ownLines.first.id,
      pendingGroups: const <String>['咕噜'],
    );

    // ① 咕噜大类在，且带「加载中」字样。
    expect(find.text('咕噜'), findsOneWidget);
    expect(find.text('加载中'), findsOneWidget);
    // ② 第二行是加载占位（说明当前停的就是咕噜那一格，而不是幻想）。
    expect(find.text('线路加载中…'), findsOneWidget);
    expect(find.text('暂无线路'), findsNothing);
    // ③ 咕噜排在幻想左边（顺序固定，不会等线路到了才右移）。
    final julu = tester.getTopLeft(find.text('咕噜'));
    final ownChip = tester.getTopLeft(find.text(kOwnLineGroupLabel));
    expect(julu.dx, lessThan(ownChip.dx), reason: '咕噜必须排在幻想前面');
    // ④ 加载中的大类不可点（没有线路），但看得见。
    expect(find.text('幻想4K'), findsNothing, reason: '第二行显示的是咕噜的占位');
  });

  testWidgets('线路到了：原地填充子线路，不再有加载态', (tester) async {
    final ownLines = <LineInfo>[own('幻想4K'), own('量子')];
    final jarLines = <LineInfo>[jar('4K'), jar('量子资源')];
    await pump(
      tester,
      lines: ownLines,
      currentLineId: ownLines.first.id,
      pendingGroups: const <String>['咕噜'],
    );
    expect(find.text('线路加载中…'), findsOneWidget);

    // jar 回来了：同一条组件树里直接换成真线路，占位收起。
    await pump(
      tester,
      lines: <LineInfo>[...ownLines, ...jarLines],
      currentLineId: jarLines.first.id,
      pendingGroups: const <String>[],
    );

    expect(find.text('加载中'), findsNothing);
    expect(find.text('线路加载中…'), findsNothing);
    // 第二行是咕噜的子线路，且前缀已经被剥掉（`咕噜·4K` → `4K`）。
    expect(find.text('4K'), findsOneWidget);
    expect(find.text('量子资源'), findsOneWidget);
    expect(find.text('咕噜·4K'), findsNothing);
  });

  testWidgets('咕噜里没有这部片：占位消失，整条大类不见、回落到幻想', (tester) async {
    final ownLines = <LineInfo>[own('幻想4K'), own('量子')];
    await pump(
      tester,
      lines: ownLines,
      currentLineId: ownLines.first.id,
      pendingGroups: const <String>['咕噜'],
    );
    expect(find.text('咕噜'), findsOneWidget);

    // 合并跑完、一条 jar 线路都没有 → 占位收起。
    await pump(
      tester,
      lines: ownLines,
      currentLineId: ownLines.first.id,
      pendingGroups: const <String>[],
    );

    expect(find.text('咕噜'), findsNothing, reason: '没有线路的大类整条不出现');
    expect(find.text('加载中'), findsNothing);
    // 回落到幻想：第二行是它自己的子线路。
    expect(find.text('幻想4K'), findsOneWidget);
  });

  testWidgets('用户点了幻想之后，咕噜回来也不再抢高亮', (tester) async {
    final ownLines = <LineInfo>[own('幻想4K'), own('量子')];
    final jarLines = <LineInfo>[jar('4K')];
    await pump(
      tester,
      lines: ownLines,
      currentLineId: ownLines.first.id,
      pendingGroups: const <String>['咕噜'],
    );
    // 用户点「幻想」大类（组件内部只切第一行 + 回选第一条子线路）。
    await tester.tap(find.text(kOwnLineGroupLabel));
    await tester.pump();
    expect(find.text('幻想4K'), findsOneWidget);

    // 咕噜线路随后到达，但当前线路仍是幻想那条 → 第一行不许跳走。
    await pump(
      tester,
      lines: <LineInfo>[...ownLines, ...jarLines],
      currentLineId: ownLines.first.id,
      pendingGroups: const <String>[],
    );
    expect(find.text('幻想4K'), findsOneWidget);
    expect(find.text('4K'), findsNothing);
  });
}

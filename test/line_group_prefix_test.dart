import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/jar_sources.dart';
import 'package:fantasy_tv/widgets/fx_line_group_selector.dart';

/// LINE_PREFIX（2026-11-21 用户实测 bug）回归：两行线路的**第一行大类**
/// 按「线路名前缀」判，不再按数据来源判。
///
/// 现场（截图）：详情页第一行选中「幻想」，第二行却是
/// 「咕噜 / 幻想爱奇艺 / 红牛」，「咕噜」还高亮着 —— 原因是服务端采集入库的
/// 线路名本身带源名前缀（库里 `vod_play_from` 有 `咕噜`、`咕噜·量子资源`），
/// 旧实现只认 `咕噜·`（必须带分隔符），裸名字那条 `咕噜` 就落进了「幻想」。
///
/// 这里把用户给的分组规则钉成真值表：**每条线路名 → 归属哪个大类**。
void main() {
  LineInfo line(String name, {String? id}) =>
      LineInfo(id ?? 'id_$name', name, 'hls', 0);

  /* ------------------------------------------------------- 真值表 */

  /// 用户口径原文：
  /// ```
  /// 线路名以「咕噜」开头          → 咕噜大类（显示时去掉「咕噜·」前缀）
  /// 线路名以「剧圈」「橘汁」「下饭」开头 → 各自大类
  /// 其余（SH4K / 幻想爱奇艺 / shvip / bilibili / qq / mgtv / youku /
  ///       量子 / 红牛）→ 幻想大类
  /// ```
  const Map<String, String> truthTable = <String, String>{
    // 咕噜：裸名字 + 采集器写出来的 `咕噜·<源线路名>` 全是咕噜大类。
    '咕噜': '咕噜',
    '咕噜·量子资源': '咕噜',
    '咕噜·暴风资源': '咕噜',
    '咕噜·非凡资源': '咕噜',
    '咕噜·电影天堂': '咕噜',
    '咕噜·4K': '咕噜',
    '咕噜4K': '咕噜',
    // 另外三个 jar 源：前缀同样归各自大类。
    '剧圈·线路1': '剧圈',
    '剧圈': '剧圈',
    '橘汁·高清': '橘汁',
    '下饭·线路2': '下饭',
    // 其余一律「幻想」—— 包括自有的 `量子`（和 `咕噜·量子资源` 是两条线）。
    '量子': kOwnLineGroupKey,
    'SH4K': kOwnLineGroupKey,
    '幻想爱奇艺': kOwnLineGroupKey,
    '幻想自建': kOwnLineGroupKey,
    'shvip': kOwnLineGroupKey,
    'bilibili': kOwnLineGroupKey,
    'qq': kOwnLineGroupKey,
    'mgtv': kOwnLineGroupKey,
    'youku': kOwnLineGroupKey,
    '红牛': kOwnLineGroupKey,
    'TW线路': kOwnLineGroupKey,
  };

  test('分组真值表：每条线路名 → 归属大类', () {
    for (final entry in truthTable.entries) {
      expect(
        fxLineGroupKeyOf(line(entry.key)),
        entry.value,
        reason: '线路名「${entry.key}」应该归「${entry.value}」大类',
      );
    }
  });

  test('「咕噜」「咕噜·量子资源」「量子」三条互不混淆', () {
    final gulu = line('咕噜');
    final guluQuantum = line('咕噜·量子资源');
    final ownQuantum = line('量子');
    expect(fxLineGroupKeyOf(gulu), '咕噜');
    expect(fxLineGroupKeyOf(guluQuantum), '咕噜');
    // 自有的「量子」不许被「咕噜·量子资源」带走。
    expect(fxLineGroupKeyOf(ownQuantum), kOwnLineGroupKey);

    final groups = fxLineGroups(<LineInfo>[gulu, guluQuantum, ownQuantum]);
    final own = groups.firstWhere((g) => g.own);
    final guluGroup = groups.firstWhere((g) => g.key == '咕噜');
    expect(own.lines.map((l) => l.name).toList(), <String>['量子']);
    expect(
      guluGroup.lines.map((l) => l.name).toList(),
      <String>['咕噜', '咕噜·量子资源'],
    );
    // 两条「量子」不同 id，不合并。
    expect(guluGroup.lines[1].id, isNot(own.lines[0].id));
  });

  test('装饰字符 / 分隔符不影响前缀判定', () {
    expect(fxLineGroupKeyOf(line('🕊┃︎咕噜┃APP')), '咕噜');
    expect(fxLineGroupKeyOf(line('咕噜 4K')), '咕噜');
    expect(fxLineGroupKeyOf(line('咕噜・暴风资源')), '咕噜');
    expect(fxLineGroupKeyOf(line('咕噜|量子资源')), '咕噜');
  });

  test('jar 编码的线路 id 优先于名字（房间线路 / 老数据）', () {
    final line = LineInfo(fxJarLineId('剧圈', '42', '线路1'), '线路1', 'hls', 0);
    expect(fxLineGroupKeyOf(line), '剧圈');
  });

  /* --------------------------------------------------- 子线路显示名 */

  test('第二行去掉前缀；裸名字显示「默认」；幻想爱奇艺不剥', () {
    expect(fxLineSubName(line('咕噜·量子资源'), '咕噜'), '量子资源');
    expect(fxLineSubName(line('咕噜·暴风资源'), '咕噜'), '暴风资源');
    expect(fxLineSubName(line('剧圈·线路1'), '剧圈'), '线路1');
    // 名字就是大类名：再显示一次「咕噜」纯属重复。
    expect(fxLineSubName(line('咕噜'), '咕噜'), kBareLineSubName);
    expect(kBareLineSubName, '默认');
    // 幻想大类只剥带分隔符的写法。
    expect(fxLineSubName(line('幻想爱奇艺'), '幻想'), '幻想爱奇艺');
    expect(fxLineSubName(line('幻想·蓝光'), '幻想'), '蓝光');
    expect(fxLineSubName(line('SH4K'), '幻想'), 'SH4K');
    expect(fxLineSubName(line('量子'), '幻想'), '量子');
  });

  /* ------------------------------------------- 类别固定 + 置灰口径 */

  test('大类固定五个；没有线路的大类 available=false（置灰）', () {
    final groups = fxLineGroups(<LineInfo>[
      line('SH4K'),
      line('量子'),
      line('咕噜'),
    ]);
    expect(groups.map((g) => g.label).toList(),
        <String>['幻想', '咕噜', '橘汁', '剧圈', '下饭']);
    expect(groups[0].available, isTrue);
    expect(groups[1].available, isTrue);
    expect(groups[2].available, isFalse);
    expect(groups[3].available, isFalse);
    expect(groups[4].available, isFalse);
  });

  test('四个 jar 源都有子线路时，四个大类全部可用（不再置灰）', () {
    final groups = fxLineGroups(<LineInfo>[
      line('SH4K'),
      line('咕噜·4K'),
      line('橘汁·高清'),
      line('剧圈·线路1'),
      line('下饭·线路2'),
    ]);
    expect(groups.skip(1).every((g) => g.available), isTrue);
    expect(groups.skip(1).map((g) => g.key).toList(),
        <String>['咕噜', '橘汁', '剧圈', '下饭']);
  });

  /* --------------------------------------------- 设置页的源状态文案 */

  test('源状态三档：可用 / jar 未安装 / 已停用', () {
    expect(
      fxJarSourceStateOf(installed: true, enabled: true),
      FxJarSourceState.available,
    );
    expect(
      fxJarSourceStateOf(installed: false, enabled: true),
      FxJarSourceState.jarMissing,
    );
    expect(
      fxJarSourceStateOf(installed: true, enabled: false),
      FxJarSourceState.disabled,
    );
    // 用户自己关掉的优先显示「已停用」（是他刚改的，比缺 jar 更直接）。
    expect(
      fxJarSourceStateOf(installed: false, enabled: false),
      FxJarSourceState.disabled,
    );
    expect(fxJarSourceStateLabel(FxJarSourceState.available), '可用');
    expect(fxJarSourceStateLabel(FxJarSourceState.jarMissing), 'jar 未安装');
    expect(fxJarSourceStateLabel(FxJarSourceState.disabled), '已停用');
  });

  /* -------------------------------------------------- 组件层（两行） */

  testWidgets('第一行点「咕噜」→ 第二行换成咕噜的子线路（chip 可点）',
      (tester) async {
    final lines = <LineInfo>[
      line('SH4K'),
      line('幻想爱奇艺'),
      line('红牛'),
      line('咕噜'),
      line('咕噜·量子资源'),
      line('剧圈·线路1'),
    ];
    LineInfo? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 380,
          child: FxLineGroupSelector(
            lines: lines,
            currentLineId: 'id_SH4K',
            onSelected: (l) => picked = l,
          ),
        ),
      ),
    ));
    // 默认展开「幻想」：第二行是自有的三条。
    expect(find.text('红牛'), findsOneWidget);
    expect(find.text(kBareLineSubName), findsNothing);

    // 点「咕噜」大类 chip（第一行）。可点 = 不置灰。
    await tester.tap(find.text('咕噜'));
    await tester.pumpAndSettle();
    // 切大类会自动选中它的第一条（详情页口径）。
    expect(picked?.name, '咕噜');
    // 第二行换成咕噜的子线路：裸名字显示「默认」，另一条剥掉前缀。
    expect(find.text(kBareLineSubName), findsOneWidget);
    expect(find.text('量子资源'), findsOneWidget);
    // 幻想大类的子线路已经不在第二行。
    expect(find.text('红牛'), findsNothing);
  });

  testWidgets('没有线路的大类点不动（置灰）', (tester) async {
    final lines = <LineInfo>[line('SH4K'), line('量子')];
    LineInfo? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 380,
          child: FxLineGroupSelector(
            lines: lines,
            currentLineId: 'id_SH4K',
            onSelected: (l) => picked = l,
          ),
        ),
      ),
    ));
    await tester.tap(find.text('剧圈'));
    await tester.pumpAndSettle();
    expect(picked, isNull);
    // 第二行还是幻想自己的线路。
    expect(find.text('量子'), findsOneWidget);
  });
}

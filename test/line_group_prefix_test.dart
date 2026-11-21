import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/jar_sources.dart';
import 'package:fantasy_tv/widgets/fx_line_group_selector.dart';

/// JAR_ONLY_BY_ID（2026-11-21 用户实测 bug）回归：两行线路的**第一行大类**
/// 只按「jar 线路 id」判，绝不按线路名前缀判。
///
/// 现场（截图）：详情页「八仙」第一行 咕噜 选中，第二行只有「暴风资源」一条；
/// 「济公传」第二行只有「默认」一条。这两条其实是**我们采集入库的线路** ——
/// 库里 `vod_play_from` 真的就叫 `咕噜` / `咕噜·暴风资源` / `咕噜·量子资源`，
/// 旧实现按名字前缀把它们塞进了咕噜大类，冒充成 jar 的子线路；而 jar 真返回的
/// `咕噜4K` / `咖啡4K超清` / `金牌极速` / `玫瑰4K` … 一条都没出现。
///
/// 现在的口径（用户原话）：
///   · 「CMS 采集的线路只归幻想大类，绝不能塞进 jar 源的大类里冒充」；
///   · 「没有的话就消失」——没有真实子线路的源，大类整条不出现。
void main() {
  LineInfo line(String name, {String? id}) =>
      LineInfo(id ?? 'id_$name', name, 'hls', 0);

  /// jar 真返回的线路（`JarSpider` 产出的形态：id 编码 + 名字带前缀）。
  LineInfo jarLine(String label, String from, {String vodId = '1'}) =>
      LineInfo(fxJarLineId(label, vodId, from), '$label·$from', 'hls', 0);

  /* ------------------------------------------------------- 真值表 */

  test('采集线路名带「咕噜」前缀也仍然归幻想大类', () {
    const Map<String, String> truthTable = <String, String>{
      // 我们自己库里的 vod_play_from（实测 八仙 / 济公传）
      '咕噜': kOwnLineGroupKey,
      '咕噜·旋风VIP': kOwnLineGroupKey,
      '咕噜·暴风资源': kOwnLineGroupKey,
      '咕噜·量子资源': kOwnLineGroupKey,
      '咕噜·非凡资源': kOwnLineGroupKey,
      '咕噜·电影天堂': kOwnLineGroupKey,
      '剧圈·线路1': kOwnLineGroupKey,
      '橘汁·高清': kOwnLineGroupKey,
      '下饭·线路2': kOwnLineGroupKey,
      '量子': kOwnLineGroupKey,
      'SH4K': kOwnLineGroupKey,
      '幻想爱奇艺': kOwnLineGroupKey,
      '红牛': kOwnLineGroupKey,
    };
    for (final entry in truthTable.entries) {
      expect(
        fxLineGroupKeyOf(line(entry.key)),
        entry.value,
        reason: '采集线路「${entry.key}」必须留在幻想大类',
      );
    }
  });

  test('只有 jar 编码的 id 才进 jar 大类', () {
    expect(fxLineGroupKeyOf(jarLine('咕噜', '4K')), '咕噜');
    // 不在白名单里的源（已去掉的剧圈 / 橘汁 / 下饭）就算带了 id 也只算自有
    // 线路，防止老历史数据把它们又拉回第一行。
    expect(fxLineGroupKeyOf(jarLine('剧圈', 'YZ有广')), kOwnLineGroupKey);
    expect(fxLineGroupKeyOf(jarLine('橘汁', '高清')), kOwnLineGroupKey);
    expect(fxLineGroupKeyOf(jarLine('下饭', '线路2')), kOwnLineGroupKey);
  });

  test('「咕噜」采集线路和「咕噜·4K」jar 线路不再混为一谈', () {
    final groups = fxLineGroups(<LineInfo>[
      line('咕噜'), // 采集入库的裸名字
      line('咕噜·量子资源'), // 采集入库的子线路
      jarLine('咕噜', '4K'), // jar 真返回
    ]);
    expect(groups.map((g) => g.label).toList(), <String>['幻想', '咕噜']);
    expect(
      groups[0].lines.map((l) => l.name).toList(),
      <String>['咕噜', '咕噜·量子资源'],
    );
    expect(groups[1].lines.map((l) => l.name).toList(), <String>['咕噜·4K']);
    expect(groups[1].lines.single.id, isNot(groups[0].lines.first.id));
  });

  /* --------------------------------------------------- 子线路显示名 */

  test('第二行去掉前缀；裸名字显示「默认」；幻想爱奇艺不剥', () {
    expect(fxLineSubName(jarLine('咕噜', '量子资源'), '咕噜'), '量子资源');
    expect(fxLineSubName(jarLine('咕噜', '暴风资源'), '咕噜'), '暴风资源');
    expect(fxLineSubName(jarLine('剧圈', '线路1'), '剧圈'), '线路1');
    // 名字就是大类名：再显示一次「咕噜」纯属重复。
    expect(fxLineSubName(line('咕噜'), '咕噜'), kBareLineSubName);
    expect(kBareLineSubName, '默认');
    // 幻想大类只剥带分隔符的写法。
    expect(fxLineSubName(line('幻想爱奇艺'), '幻想'), '幻想爱奇艺');
    expect(fxLineSubName(line('幻想·蓝光'), '幻想'), '蓝光');
    expect(fxLineSubName(line('SH4K'), '幻想'), 'SH4K');
  });

  /* ------------------------------------------- 有数据才出现，空就消失 */

  test('没有子线路的 jar 源整条不出现（不置灰、不占位）', () {
    final groups = fxLineGroups(<LineInfo>[line('SH4K'), line('量子')]);
    expect(groups.map((g) => g.label).toList(), <String>['幻想']);
  });

  test('有子线路的源才出现在第一行，顺序按白名单', () {
    final groups = fxLineGroups(<LineInfo>[
      line('SH4K'),
      jarLine('剧圈', 'YZ有广'),
      jarLine('咕噜', '4K'),
      jarLine('咕噜', '暴风资源'),
    ]);
    // KEEP_GULU_ONLY：白名单只剩咕噜，剧圈那条退回幻想大类、不单独成大类。
    expect(
      groups.map((g) => g.label).toList(),
      <String>['幻想', '咕噜'],
    );
    expect(groups.every((g) => g.available), isTrue);
    expect(groups[0].lines.length, 2);
    expect(groups[1].lines.length, 2);
  });

  test('已去掉的源（剧圈 / 橘汁 / 下饭）不会出现在第一行', () {
    expect(kEnabledJarSources, <String>['咕噜']);
    final groups = fxLineGroups(<LineInfo>[
      line('SH4K'),
      jarLine('橘汁', '高清'),
      jarLine('下饭', '线路2'),
      jarLine('咕噜', '4K'),
    ]);
    expect(groups.map((g) => g.label).toList(), <String>['幻想', '咕噜']);
    // 橘汁 / 下饭的老线路退回幻想大类，不丢数据也不冒充。
    expect(groups[0].lines.length, 3);
    // 白名单里没有的源，就算带 jar 编码也不出现第二行。
    expect(groups.map((g) => g.label), <String>['幻想', '咕噜']);
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
    expect(fxJarSourceStateLabel(FxJarSourceState.available), '可用');
    expect(fxJarSourceStateLabel(FxJarSourceState.jarMissing), 'jar 未安装');
    expect(fxJarSourceStateLabel(FxJarSourceState.disabled), '已停用');
  });

  /* -------------------------------------------------- 组件层（两行） */

  testWidgets('第一行点「咕噜」→ 第二行换成咕噜的真子线路', (tester) async {
    final lines = <LineInfo>[
      line('SH4K'),
      line('幻想爱奇艺'),
      line('红牛'),
      jarLine('咕噜', '4K'),
      jarLine('咕噜', '暴风资源'),
      // 剧圈已停用：带 jar 编码的老线路退回幻想大类，不单独成大类。
      jarLine('剧圈', 'YZ有广'),
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
    // 第一行：幻想 / 咕噜（没有线路的源不出现；剧圈已停用也不出现）。
    expect(find.text('咕噜'), findsOneWidget);
    expect(find.text('剧圈'), findsNothing);
    expect(find.text('橘汁'), findsNothing);
    expect(find.text('下饭'), findsNothing);

    await tester.tap(find.text('咕噜'));
    await tester.pumpAndSettle();
    // 切大类会自动选中它的第一条（详情页口径）。
    expect(picked?.name, '咕噜·4K');
    expect(find.text('4K'), findsOneWidget);
    expect(find.text('暴风资源'), findsOneWidget);
    expect(find.text('红牛'), findsNothing);
  });

  testWidgets('没有线路的源连 chip 都不显示', (tester) async {
    final lines = <LineInfo>[line('SH4K'), line('量子')];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 380,
          child: FxLineGroupSelector(
            lines: lines,
            currentLineId: 'id_SH4K',
            onSelected: (_) {},
          ),
        ),
      ),
    ));
    expect(find.text('咕噜'), findsNothing);
    expect(find.text('剧圈'), findsNothing);
    expect(find.text('暂无线路'), findsNothing);
  });
}

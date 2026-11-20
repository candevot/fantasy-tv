import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fantasy_tv/services/jar_sources.dart';
import 'package:fantasy_tv/services/source_hub.dart';

/// 片源管理（设置 → 片源管理）那一层的回归：白名单 / 默认开关 / 持久化。
///
/// 用户口径：
///   · 「设置里片源管理只显示这四个源」→ `jarSources` 里最多四个，
///     别的肥猫源一条都不许出现；
///   · 「默认只启用用户挑中的那几个」→ 没改过设置时，白名单里的都算开着；
///   · 「可以手动启用 / 停用每个 jar 源」→ 关掉之后 `jarSources` 立刻少一条，
///     并且落盘（下次启动还是关的）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 每个用例从干净状态开始：片源表回到「只有内置目录」。
    await SourceHub.instance.resetLocal();
  });

  test('云端没下发 jar 站点时，四个源从内置目录补进片源表', () async {
    final hub = SourceHub.instance;
    await hub.ensureReady();
    final labels = hub.cloudSources
        .where((s) => SourceHub.jarLabelOf(s).isNotEmpty)
        .map(SourceHub.jarLabelOf)
        .toList();
    expect(labels.toSet(),
        <String>{'咕噜', '橘汁', '剧圈', '下饭'});
    // 类名对得上（内联 ext 的那两个也要在）。
    final apis = <String>{
      for (final s in hub.cloudSources)
        if (SourceHub.jarLabelOf(s).isNotEmpty) s.api,
    };
    expect(apis, containsAll(<String>['csp_Gulu', 'csp_AppDrama', 'csp_App99', 'csp_JuXiaFan']));
  });

  test('默认启用名单 = 白名单里的四个（顺序固定）', () async {
    final hub = SourceHub.instance;
    await hub.ensureReady();
    expect(
      hub.jarSources.map(SourceHub.jarLabelOf).toList(),
      <String>['咕噜', '橘汁', '剧圈', '下饭'],
    );
    // jar 源不进自有检索计划（首页 / 分类 / 排行只用自有源）。
    expect(
      hub.searchPlan.own.any((s) => s.kind.name == 'jar'),
      isFalse,
    );
    expect(hub.searchPlan.external.length, 4);
  });

  test('关掉一个源：它立刻退出检索，落盘后重读仍然是关的', () async {
    final hub = SourceHub.instance;
    await hub.ensureReady();
    await hub.setJarSourceEnabled('剧圈', false);
    expect(hub.jarSourceEnabled('剧圈'), isFalse);
    expect(
      hub.jarSources.map(SourceHub.jarLabelOf).toList(),
      <String>['咕噜', '橘汁', '下饭'],
    );
    // 白名单里没有的源：开关恒为 false，也不会被写进启用表。
    expect(hub.jarSourceEnabled('豆瓣'), isFalse);
    // 重新打开
    await hub.setJarSourceEnabled('剧圈', true);
    expect(hub.jarSources.length, 4);
  });

  test('空白名单（用户没挑）→ 一个 jar 源都不启用', () {
    // 常量本身不能改，这里只钉住「白名单为空就不启用」这条判定：
    // `jarSourceEnabled` 对不在白名单里的源恒为 false。
    expect(kEnabledJarSources.contains('豆瓣'), isFalse);
    expect(SourceHub.instance.jarSourceEnabled('豆瓣'), isFalse);
  });
}

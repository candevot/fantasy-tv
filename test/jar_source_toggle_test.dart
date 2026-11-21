import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fantasy_tv/services/jar_config.dart';
import 'package:fantasy_tv/services/jar_sources.dart';
import 'package:fantasy_tv/services/source_hub.dart';

/// 片源管理（设置 → 片源管理）那一层的回归：白名单 / 默认开关 / 持久化。
///
/// 用户口径（2026-11-21，服务器 jar 实测之后）：
///   · 只留**真能出线路**的源：咕噜（15 条线路）、剧圈（2 条）；
///   · 橘汁（searchContent 恒空）、下饭（25～49 秒回空）已从白名单去掉，
///     界面上一条都不许出现；
///   · 「显示可用但永远灰」不允许：能在片源表里的源，必须是实测能出线路的。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 测试环境没有外网：配置直接走内置兜底那份（与线上 hx_all.json 一致）。
    JarConfig.networkEnabled = false;
    JarConfig.instance.reset();
    await SourceHub.instance.resetLocal();
  });

  tearDown(() {
    JarConfig.networkEnabled = true;
  });

  test('云端没下发 jar 站点时，白名单里的源从内置目录补进片源表', () async {
    final hub = SourceHub.instance;
    await hub.ensureReady();
    final labels = hub.cloudSources
        .where((s) => SourceHub.jarLabelOf(s).isNotEmpty)
        .map(SourceHub.jarLabelOf)
        .toList();
    expect(labels.toSet(), <String>{'咕噜', '剧圈'});
    // 类名对得上；已去掉的源一个都不许把类名带回来。
    final apis = <String>{
      for (final s in hub.cloudSources)
        if (SourceHub.jarLabelOf(s).isNotEmpty) s.api,
    };
    expect(apis, <String>{'csp_Gulu', 'csp_App99'});
  });

  test('默认启用名单 = 白名单里的两个（顺序固定）', () async {
    final hub = SourceHub.instance;
    await hub.ensureReady();
    expect(
      hub.jarSources.map(SourceHub.jarLabelOf).toList(),
      <String>['咕噜', '剧圈'],
    );
    // jar 源不进自有检索计划（首页 / 分类 / 排行只用自有源）。
    expect(
      hub.searchPlan.own.any((s) => s.kind.name == 'jar'),
      isFalse,
    );
    expect(hub.searchPlan.external.length, 2);
  });

  test('剧圈的 ext 与线上 hx_all.json 逐字段一致（缺一个就搜不到）', () async {
    final hub = SourceHub.instance;
    await hub.ensureReady();
    final ju = hub.jarSources.firstWhere((s) => SourceHub.jarLabelOf(s) == '剧圈');
    expect(ju.api, 'csp_App99');
    expect(ju.ext, contains('"host":"http://124.221.3.182:19987/app/bn"'));
    expect(ju.ext, contains('"package":"com.qingtangxiaozhuan.xyz"'));
    expect(
      ju.ext,
      contains(
        '"buildSignature":"054FA8DDA4319C6B6A9B954CA5777541C993F00B1B0BD4394F7EDE48184C4594"',
      ),
    );
    // 咕噜不需要 ext（线上也是空的）。
    final gulu = hub.jarSources.firstWhere((s) => SourceHub.jarLabelOf(s) == '咕噜');
    expect(gulu.api, 'csp_Gulu');
    expect(gulu.ext, isEmpty);
  });

  test('关掉一个源：它立刻退出检索，落盘后重读仍然是关的', () async {
    final hub = SourceHub.instance;
    await hub.ensureReady();
    await hub.setJarSourceEnabled('剧圈', false);
    expect(hub.jarSourceEnabled('剧圈'), isFalse);
    expect(
      hub.jarSources.map(SourceHub.jarLabelOf).toList(),
      <String>['咕噜'],
    );
    // 白名单里没有的源：开关恒为 false，也不会被写进启用表。
    expect(hub.jarSourceEnabled('豆瓣'), isFalse);
    expect(hub.jarSourceEnabled('橘汁'), isFalse);
    // 重新打开
    await hub.setJarSourceEnabled('剧圈', true);
    expect(hub.jarSources.length, 2);
  });

  test('空白名单（用户没挑）→ 一个 jar 源都不启用', () {
    expect(kEnabledJarSources.contains('豆瓣'), isFalse);
    expect(SourceHub.instance.jarSourceEnabled('豆瓣'), isFalse);
  });
}

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/app_settings.dart';
import 'package:fantasy_tv/services/cms_bridge.dart';
import 'package:fantasy_tv/services/jar_plugin.dart';
import 'package:fantasy_tv/services/jar_sources.dart';
import 'package:fantasy_tv/services/jar_spider.dart';
import 'package:fantasy_tv/services/source_hub.dart';

/// JAR_BOOT（2026-11-21 用户实测）回归：**首次进 App 自动装 spider.jar**，
/// 装好后那四个 jar 源立刻可用（chips 不再置灰），没装时一条请求都不发。
///
/// 现场：装 App 后详情页第一行四个 jar 大类全是灰的 —— 根因就是 `spider.jar`
/// 没装，jar 通道不可用 → 源没有线路 → chips 置灰。
///
/// 这里钉住四件事：
///   1. 「首次使用自动安装」默认 **开**；
///   2. 冷启动真的会调 `jarInstall`，地址 / md5 都用默认服务器那份，
///      并留下 `[JarBoot]` 日志（真机 `adb logcat | grep JarBoot` 可查）；
///   3. **jar 没装时搜索 / 详情不向 jar 源发请求**（不白等十几秒）；
///   4. 装好后四个源都能合并出子线路 → 四个大类 `available=true`（不置灰）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  var installed = false;
  DebugPrintCallback originalDebugPrint = debugPrint;
  final logs = <String>[];

  /// 咕噜风格的详情：两段线路（`4K` / `量子资源`）。
  String detailBody({String vodId = '418792', String name = '八仙'}) {
    const sep = r'$$$';
    return '''
{"list":[{"vod_id":"$vodId","vod_name":"$name","vod_year":"2016",
"vod_pic":"https://img/1.jpg","vod_play_from":"4K${sep}量子资源",
"vod_play_url":"第1集\$https://cdn/a/1.m3u8${sep}第1集\$https://cdn/b/1.m3u8"}]}''';
  }

  /// 搜索响应：片名 + 年份和详情一致（能命中融合索引）。
  String searchBody({String vodId = '418792', String name = '八仙'}) {
    return '''
{"list":[{"vod_id":"$vodId","vod_name":"$name","vod_year":"2016",
"vod_pic":"https://img/1.jpg","vod_play_from":"4K",
"vod_play_url":"第1集\$https://cdn/a/1.m3u8"}]}''';
  }

  void mockJar(Object? Function(String method, Map<String, dynamic> args) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(JarSpider.channel, (call) async {
      calls.add(call);
      final args = Map<String, dynamic>.from(
        (call.arguments as Map?) ?? <String, dynamic>{},
      );
      return handler(call.method, args);
    });
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    calls.clear();
    logs.clear();
    installed = false;
    JarSpider.debugForceSupported = true;
    JarMergeIndex.instance.clear();
    originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    await SourceHub.instance.resetLocal();
    SourceHub.instance.invalidateJarStatus();
    // JarSpider 是静态缓存（`_status` 等），跨用例会串：这里清干净，
    // 否则上一个用例的「未安装」会被下一个用例当成现状。
    await JarSpider.destroy();
  });

  tearDown(() {
    debugPrint = originalDebugPrint;
    JarSpider.debugForceSupported = false;
    JarMergeIndex.instance.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(JarSpider.channel, null);
  });

  /* --------------------------------------------- 1. 默认开关 / 默认地址 */

  test('「首次使用自动安装」默认开，地址与 md5 指向自建服务器那份', () async {
    expect(AppSettings.defaultJarAutoInstall, isTrue);
    expect(AppSettings.defaultJarUrl, 'http://125.94.244.87/spider.jar');
    expect(AppSettings.defaultJarMd5, 'cbe016eb3cb002ae62058604843f5106');
    await AppSettings.instance.init();
    // 没存过任何设置时就是默认值（不是 false）。
    expect(AppSettings.instance.jarAutoInstall, isTrue);
    expect(AppSettings.instance.jarUrl, AppSettings.defaultJarUrl);
    expect(AppSettings.instance.jarMd5, AppSettings.defaultJarMd5);
  });

  /* --------------------------------- 2. 冷启动静默装（日志 + md5 校验） */

  test('冷启动自动装 jar：走 jarInstall + md5，落地 ready，并留 JarBoot 日志',
      () async {
    mockJar((method, args) {
      switch (method) {
        case 'status':
          return jsonEncode(<String, Object?>{
            'installed': installed,
            'md5': installed ? AppSettings.defaultJarMd5 : '',
          });
        case 'installBundled':
          // CI 里没有 assets/spiders/spider.jar：内置那一支按失败走，
          // 正好验证「内置不可用 → 下载」这条路。
          return jsonEncode(<String, Object?>{'error': '内置 jar 不存在'});
        case 'jarInstall':
          installed = true;
          return jsonEncode(<String, Object?>{
            'ok': true,
            'path': '/data/app/spiders/spider.jar',
            'md5': AppSettings.defaultJarMd5,
            'size': 1929492,
          });
        case 'selfTest':
          return jsonEncode(<String, Object?>{'ok': true, 'items': 20});
        default:
          return jsonEncode(<String, Object?>{'ok': true});
      }
    });

    await JarPluginManager.instance.bootSilently();

    // ① 真的去装了，而且用的是默认地址 + 默认 md5（强校验）。
    final install = calls.where((c) => c.method == 'jarInstall').toList();
    expect(install, isNotEmpty);
    final args = Map<String, dynamic>.from(install.first.arguments as Map);
    expect(args['url'], AppSettings.defaultJarUrl);
    expect(args['md5'], AppSettings.defaultJarMd5);

    // ② 状态机落到 ready，jar 视为已安装。
    expect(JarPluginManager.instance.phase, JarPluginPhase.ready);
    expect(JarPluginManager.instance.installed, isTrue);

    // ③ 日志：开始 + 结果各一条，真机 grep JarBoot 就能看出装没装。
    final boot = logs.where((l) => l.contains('[JarBoot]')).toList();
    expect(boot.length, greaterThanOrEqualTo(2));
    expect(boot.first, contains('启动检查'));
    expect(boot.first, contains('auto=true'));
    expect(boot.last, contains('phase=ready'));
    expect(boot.last, contains('installed=true'));

    // ④ 装完之后片源中心那边也是「就绪」。
    await SourceHub.instance.refreshJarStatus();
    expect(SourceHub.instance.jarReady, isTrue);
    expect(SourceHub.instance.jarMissing, isFalse);
    expect(SourceHub.instance.jarNotice, isEmpty);
  });

  test('自动安装关掉之后，纯后台触发不再下载（只留手动安装）', () async {
    await AppSettings.instance.init();
    await AppSettings.instance.setJarAutoInstall(false);
    mockJar((method, args) => jsonEncode(<String, Object?>{
          'installed': false,
          if (method == 'installBundled') 'error': '内置 jar 不存在',
        }));

    await JarPluginManager.instance.bootSilently();

    expect(calls.any((c) => c.method == 'jarInstall'), isFalse);
    expect(JarPluginManager.instance.phase, JarPluginPhase.failed);
    expect(JarPluginManager.instance.error, contains('安装 / 更新'));
    // 失败不阻断使用：jar 只是不可用，App 该干嘛干嘛。
    await SourceHub.instance.refreshJarStatus();
    expect(SourceHub.instance.jarMissing, isTrue);
    expect(SourceHub.instance.jarNotice, contains('jar 未就绪'));
  });

  /* ------------------------- 3. 没装 jar：搜索 / 详情不发 jar 请求 */

  test('jar 没装：详情合并直接返回空，一条 jar 请求都不发', () async {
    mockJar((method, args) => jsonEncode(<String, Object?>{
          'installed': false,
        }));
    JarMergeIndex.instance.attach(
      title: '八仙',
      year: 2016,
      label: '咕噜',
      vodId: '418792',
    );
    final detail = _detailOf(title: '八仙');
    final extra = await CmsBridge.jarLinesFor(detail);
    expect(extra, isEmpty);
    expect(calls.any((c) => c.method == 'detail'), isFalse);
    expect(calls.any((c) => c.method == 'search'), isFalse);
  });

  test('jar 没装：按片名补命中也不发请求（fillJarHitsFor 返回 0）', () async {
    mockJar((method, args) => jsonEncode(<String, Object?>{
          'installed': false,
        }));
    final hits = await CmsBridge.fillJarHitsFor(_detailOf(title: '八仙'));
    expect(hits, 0);
    expect(calls.any((c) => c.method == 'search'), isFalse);
  });

  /* ------------- 4. 装好后：白名单里的源能合并出子线路 */

  test('装好 jar：源能合并子线路 → 该源大类出现且可点',
      () async {
    installed = true;
    mockJar((method, args) {
      if (method == 'status') {
        return jsonEncode(<String, Object?>{
          'installed': true,
          'md5': AppSettings.defaultJarMd5,
        });
      }
      if (method == 'detail') return detailBody();
      return jsonEncode(<String, Object?>{'ok': true});
    });
    await SourceHub.instance.refreshJarStatus();
    expect(SourceHub.instance.jarReady, isTrue);

    // 搜索期已经命中过这部片（索引里每个启用源各一条），详情页据此合并。
    for (final label in kEnabledJarSources) {
      JarMergeIndex.instance.attach(
        title: '八仙',
        year: 2016,
        label: label,
        vodId: '418792',
      );
    }
    final extra = await CmsBridge.jarLinesFor(_detailOf(title: '八仙'));
    expect(extra.length, kEnabledJarSources.length * 2);
    for (final label in kEnabledJarSources) {
      expect(extra.any((l) => l.name == '$label·4K'), isTrue);
      expect(extra.any((l) => l.name == '$label·量子资源'), isTrue);
    }

    final groups = fxLineGroups(<LineInfo>[
      ..._detailOf(title: '八仙').lines,
      ...extra,
    ]);
    // 第一行：幻想 + 真的有线路的 jar 源（白名单 = 只保留 咕噜）。
    expect(groups.map((g) => g.label).toList(),
        <String>['幻想', '咕噜']);
    expect(groups.skip(1).every((g) => g.available), isTrue);
    // 第二行：`咕噜·4K` 去掉前缀，且「量子资源」不会和自有的「量子」混。
    final gulu = groups.firstWhere((g) => g.key == '咕噜');
    expect(fxLineSubName(gulu.lines.first, '咕噜'), '4K');
  });

  test('装好 jar 后按片名补命中：每个启用源各发一次搜索，索引补齐', () async {
    installed = true;
    mockJar((method, args) {
      if (method == 'status') {
        return jsonEncode(<String, Object?>{
          'installed': true,
          'md5': AppSettings.defaultJarMd5,
        });
      }
      if (method == 'search') return searchBody();
      return jsonEncode(<String, Object?>{'ok': true});
    });
    await SourceHub.instance.refreshJarStatus();

    final hits = await CmsBridge.fillJarHitsFor(_detailOf(title: '八仙'));
    expect(hits, kEnabledJarSources.length);
    final searches = calls.where((c) => c.method == 'search').toList();
    expect(searches.length, kEnabledJarSources.length);
    // 补完索引，详情页同一套合并就能出各源的子线路。
    final recorded = JarMergeIndex.instance.hitsFor(title: '八仙', year: 2016);
    expect(recorded.map((h) => h.label).toSet(),
        kEnabledJarSources.toSet());
  });
}

VideoDetail _detailOf({required String title}) => VideoDetail(
      id: '888',
      title: title,
      cover: '',
      backdrop: '',
      rating: 8,
      year: 2016,
      area: '',
      category: '国产剧',
      status: '',
      episodes: 40,
      desc: '',
      tags: const <String>[],
      director: const <String>[],
      cast: const <String>[],
      lines: <LineInfo>[
        LineInfo('hl_4k', 'SH4K', 'hls', 1),
        LineInfo('hl_quantum', '量子', 'hls', 2),
      ],
      groups: const <EpisodeGroup>[],
      related: const <VideoCard>[],
    );

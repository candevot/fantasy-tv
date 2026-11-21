import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/cms_bridge.dart';
import 'package:fantasy_tv/services/jar_sources.dart';
import 'package:fantasy_tv/services/jar_spider.dart';

/// FUSION（2026-11-21）回归：jar 源和我们自己的片源**融合**的四条口径。
///
/// 用户原话：「也就是那些线路和子线路的片源，没有的它能搜到，我们没有的它能
/// 搜到，我们有的它合并进来」。落成可测的四件事：
///
///   1. **我们有的片** → 不新增卡片，把 jar 的子线路合并进我们那条记录；
///   2. **我们没有的片** → 新增卡片（详情 / 播放都走 jar 通道）；
///   3. 合并进来的线路名是 `<源名>·<子线路名>`（`咕噜·4K`），同源同名只留一条；
///   4. 自有线路永远排在 jar 线路前面；线路 id 编码后能反解回「哪个源、哪部片、
///      哪一段 flag」，播放据此现场解析。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  DebugPrintCallback originalDebugPrint = debugPrint;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    calls.clear();
    JarSpider.debugForceSupported = true;
    originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {};
    JarMergeIndex.instance.clear();
  });

  tearDown(() {
    debugPrint = originalDebugPrint;
    JarSpider.debugForceSupported = false;
    JarMergeIndex.instance.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(JarSpider.channel, null);
  });

  /// 咕噜风格的一条详情：`vod_play_from` 四段、`vod_play_url` 四段。
  /// TVBox 的线路分隔是 `$$$`，集与集之间是 `#`，集内「集名\$地址」。
  String detailBody({
    String vodId = '418792',
    String name = '八仙',
    String year = '2016',
    List<String> from = const <String>['4K', '暴风资源', '量子资源'],
  }) {
    const sep = r'$$$';
    final urls = <String>[
      for (var i = 0; i < from.length; i++) '第1集\$https://cdn/$i/1.m3u8',
    ];
    return '''
{"list":[{"vod_id":"$vodId","vod_name":"$name","vod_year":"$year",
"vod_pic":"https://img/1.jpg","vod_play_from":"${from.join(sep)}",
"vod_play_url":"${urls.join(sep)}"}]}''';
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

  /* -------------------------------------------------- 1. 纯逻辑：白名单 */

  test('白名单按源名前缀匹配（咕噜 • APP 命中 咕噜）', () {
    // KEEP_GULU_ONLY（2026-11-21）：白名单只剩咕噜。
    expect(kEnabledJarSources, <String>['咕噜']);
    expect(fxJarLabelOf('咕噜 • APP'), '咕噜');
    expect(fxJarLabelOf('🕊┃︎咕噜┃APP'), '咕噜');
    // 剧圈已从白名单移除（要两参 + 真 ext 才出线路），别名解析也不再命中。
    expect(fxJarLabelOf('剧圈99'), '');
    // 实测不可用的源（橘汁 searchContent 恒空 / 下饭 25～49 秒回空）已去掉。
    expect(fxJarLabelOf('橘汁 • APP'), '');
    expect(fxJarLabelOf('下饭 • APP'), '');
    expect(fxJarLabelOf('豆瓣 • 首页'), '');
  });

  test('内置兜底目录只剩咕噜一个源', () {
    expect(kBuiltinJarSources.length, 1);
    expect(
      kBuiltinJarSources.map((e) => e.api).toList(),
      <String>['csp_Gulu'],
    );
    for (final def in kBuiltinJarSources) {
      expect(fxJarLabelOf(def.name), def.key);
      // 内置目录 = 白名单的子集：兜底不许放水。
      expect(kEnabledJarSources, contains(def.key));
    }
    // 剧圈那条（App99 系 + ext）已从兜底删掉，只留注释备查。
    expect(
      kBuiltinJarSources.any((e) => e.key == '剧圈'),
      isFalse,
    );
  });

  /* -------------------------------------------------- 2. 搜索期：合并 vs 新增 */

  test('我们有的片 → merge（不新增卡片）', () {
    final ownKeys = <String>{JarMergeIndex.keyOf('八仙', 2016)};
    expect(
      fxJarAction(title: '八仙', year: 2016, ownKeys: ownKeys),
      FxJarHitAction.merge,
    );
    // 片名归一化后相同也算命中（全角/空格差异不影响）。
    expect(
      fxJarAction(title: ' 八仙 ', year: 2016, ownKeys: ownKeys),
      FxJarHitAction.merge,
    );
  });

  test('我们没有的片 → add（作为新条目上屏）', () {
    final ownKeys = <String>{JarMergeIndex.keyOf('八仙', 2016)};
    expect(
      fxJarAction(title: '人世间', year: 2022, ownKeys: ownKeys),
      FxJarHitAction.add,
    );
    // 同名不同年 = 另一部片，不能合并。
    expect(
      fxJarAction(title: '八仙', year: 1998, ownKeys: ownKeys),
      FxJarHitAction.add,
    );
  });

  test('融合索引：同源同片只记一次，换片能查到', () {
    final index = JarMergeIndex.instance;
    index.attach(title: '八仙', year: 2016, label: '咕噜', vodId: '418792');
    index.attach(title: '八仙', year: 2016, label: '咕噜', vodId: '418792');
    // 白名单只剩 咕噜：这里用同一源的第二条片验证「同片只记一次、不同片能查到」。
    index.attach(title: '八仙', year: 2016, label: '咕噜', vodId: '77');
    final hits = index.hitsFor(title: '八仙', year: 2016);
    expect(hits.length, 2);
    expect(hits.map((e) => e.label), <String>['咕噜', '咕噜']);
    // 年份对不上时退一步按片名找（jar 常把年份写成 0）。
    expect(index.hitsFor(title: '八仙', year: 0).length, 2);
    // 没搜过的片一条都没有。
    expect(index.hitsFor(title: '人世间', year: 2022), isEmpty);
  });

  /* -------------------------------------------------- 3. 线路编码 */

  test('jar 线路 id 能反解回 源/片/flag', () {
    final id = fxJarLineId('咕噜', '418792', '4K');
    expect(fxIsJarLine(LineInfo(id, '咕噜·4K', 'hls', 0)), isTrue);
    final ref = fxParseJarLineId(id)!;
    expect(ref.label, '咕噜');
    expect(ref.vodId, '418792');
    expect(ref.from, '4K');
    // 自有线路不是 jar 线路。
    expect(fxParseJarLineId('hl_4k'), isNull);
    expect(fxParseJarLineId('jar::坏数据'), isNull);
  });

  /* -------------------------------------------------- 4. 两行分组 */

  test('两行线路：有子线路的源才出现，子线路不带前缀', () {
    final lines = <LineInfo>[
      LineInfo('hl_4k', 'SH4K', 'hls', 1),
      LineInfo('hl_qiyi', '幻想爱奇艺', 'hls', 2),
      // jar 真返回的两条（id 编码）+ 采集入库的同名线路（只按名字）。
      LineInfo(fxJarLineId('咕噜', '1', '4K'), '咕噜·4K', 'hls', 0),
      LineInfo(fxJarLineId('咕噜', '1', '暴风资源'), '咕噜·暴风资源', 'hls', 0),
      LineInfo('hl_gulu_cms', '咕噜·暴风资源', 'hls', 3),
    ];
    final groups = fxLineGroups(lines);
    // 第一行：幻想 + 真有线路的咕噜（剧圈没有 → 不出现）。
    expect(groups.map((g) => g.label).toList(), <String>['幻想', '咕噜']);
    expect(groups[0].own, isTrue);
    // 采集那条「咕噜·暴风资源」留在幻想大类，不进咕噜。
    expect(groups[0].lines.length, 3);
    expect(groups[1].lines.length, 2);
    // 第二行：子线路去掉前缀。
    expect(fxLineSubName(groups[1].lines[0], '咕噜'), '4K');
    expect(fxLineSubName(groups[1].lines[1], '咕噜'), '暴风资源');
    expect(fxLineSubName(groups[0].lines[0], '幻想'), 'SH4K');
  });

  test('自有线路永远在 jar 线路前面（同组内保序）', () {
    final own = <LineInfo>[
      LineInfo('a', 'SH4K', 'hls', 0),
      LineInfo('b', '量子', 'hls', 0),
    ];
    final jar = <LineInfo>[
      LineInfo(fxJarLineId('咕噜', '1', '4K'), '咕噜·4K', 'hls', 0),
      LineInfo(fxJarLineId('咕噜', '1', '量子资源'), '咕噜·量子资源', 'hls', 0),
    ];
    final mixed = fxOwnLinesFirst(<LineInfo>[...jar, ...own]);
    expect(mixed.map((l) => l.name).toList(),
        <String>['SH4K', '量子', '咕噜·4K', '咕噜·量子资源']);
  });

  /* -------------------------------------------------- 5. jar 详情合并 */

  test('我们有的片：jar 详情的子线路合并成 `<源名>·<子线路>`', () async {
    mockJar((method, args) {
      if (method == 'status') {
        return jsonEncode(<String, Object?>{'installed': true, 'md5': 'abc'});
      }
      return detailBody();
    });
    JarMergeIndex.instance.attach(
      title: '八仙',
      year: 2016,
      label: '咕噜',
      vodId: '418792',
    );
    final detail = VideoDetail(
      id: '888',
      title: '八仙',
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
      ],
      groups: const <EpisodeGroup>[],
      related: const <VideoCard>[],
    );
    final extra = await CmsBridge.jarLinesFor(detail);
    expect(extra.map((l) => l.name).toList(),
        <String>['咕噜·4K', '咕噜·暴风资源', '咕噜·量子资源']);
    // 每条都编成了 jar 线路 id，播放能反解。
    for (final line in extra) {
      final ref = fxParseJarLineId(line.id);
      expect(ref, isNotNull);
      expect(ref!.label, '咕噜');
      expect(ref.vodId, '418792');
    }
    expect(CmsBridge.isJarLine(extra.first.id), isTrue);
  });

  test('我们没有的片：详情完全由 jar 源提供', () async {
    mockJar((method, args) => method == 'status'
        ? jsonEncode(<String, Object?>{'installed': true, 'md5': 'abc'})
        : detailBody(vodId: '999', name: '人世间'));
    final detail = await CmsBridge.detail(
      '@src:咕噜::999',
    );
    expect(detail.title, '人世间');
    expect(detail.lines.map((l) => l.name).toList(),
        <String>['咕噜·4K', '咕噜·暴风资源', '咕噜·量子资源']);
    // 没给线路的片子不能凭空多出线路。
    expect(detail.lines.every((l) => l.id.startsWith(kFxJarLineMark)), isTrue);
  });

  test('播放：jar 线路现场解析（playerContent），不读库里的地址', () async {
    mockJar((method, args) {
      if (method == 'status') {
        return jsonEncode(<String, Object?>{'installed': true, 'md5': 'abc'});
      }
      if (method == 'player') {
        expect(args['flag'], '4K');
        expect(args['id'], 'https://cdn/0/1.m3u8');
        return jsonEncode(<String, Object?>{
          'parse': 0,
          'url': 'https://cdn/0/1.m3u8?token=abc',
        });
      }
      return detailBody();
    });
    final info = await CmsBridge.play(
      '@src:咕噜::418792',
      1,
      fxJarLineId('咕噜', '418792', '4K'),
    );
    expect(info.url, 'https://cdn/0/1.m3u8?token=abc');
    expect(info.lineName, '咕噜·4K');
    // 真去敲了 playerContent，而不是拿详情里那个集地址直接播。
    expect(
      calls.any((c) => c.method == 'player'),
      isTrue,
    );
  });
}

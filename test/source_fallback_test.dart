import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/fallback_match.dart';
import 'package:fantasy_tv/services/source_fallback.dart';

/// 三段降级的**决策流程**回归（FX_FALLBACK 2026-11-15）。
///
/// 规则判定在 `tools/test_fallback_match.dart`（纯函数）；这里钉的是「走哪一段、
/// 换到哪条记录、什么情况不许换」—— 也就是真正会出现死循环 / 跳错片子的地方：
///   · 第 2 段必须排除自己那条记录；
///   · 目标源集数不够 → 不许换（会掉进度），但要把「该源只有 N 集」带出来；
///   · 命中一次之后 `switched` 必须为真，第二次调用直接放弃（只切一次）；
///   · 第 3 段要把「查过的源」记进 `triedSources`，并且 jar 没装时如实上报；
///   · 片名 / 年份 / 解说预告这三道闸在真实检索结果上同样生效。
///
/// 网络调用全部用假替身注入，跑起来是纯内存的。

VideoCard _card({
  required String id,
  required String title,
  int year = 2016,
  String sourceLabel = '幻想',
}) =>
    VideoCard(
      id: id,
      title: title,
      cover: '',
      status: '',
      category: '',
      year: year,
      sourceLabel: sourceLabel,
    );

VideoDetail _detail({
  required String id,
  required String title,
  required int year,
  int episodes = 12,
  List<LineInfo>? lines,
}) =>
    VideoDetail(
      id: id,
      title: title,
      cover: '',
      backdrop: '',
      rating: 0,
      year: year,
      area: '',
      category: '',
      status: '',
      episodes: episodes,
      desc: '',
      tags: const <String>[],
      director: const <String>[],
      cast: const <String>[],
      lines: lines ??
          <LineInfo>[
            LineInfo('cms_${id}_1', '红牛', 'hls', 0, epNames: _epNames(episodes)),
          ],
      groups: const <EpisodeGroup>[],
      related: const <VideoCard>[],
    );

List<String> _epNames(int n) =>
    <String>[for (var i = 0; i < n; i++) '第${i + 1}集'];

void main() {
  test('第 2 段：同片名的另一条记录命中，集号保持不变', () async {
    final fb = FxSourceFallback(
      title: '济公传',
      year: 2016,
      currentId: '100',
      sourceName: '幻想',
      searchOwn: (kw) async => <VideoCard>[
        _card(id: '100', title: '济公传'), // 就是当前这条：必须排除
        _card(id: '200', title: '济公传', year: 2016),
      ],
      fetchDetail: (id) async => _detail(id: id, title: '济公传', year: 2016),
      searchExternal: (kw, tried) async => const FxExternalHits(),
    );

    final out = await fb.find(ep: 5);
    expect(out.hit, isTrue);
    expect(out.candidate!.videoId, '200');
    expect(out.candidate!.ep, 5);
    expect(out.candidate!.level, 2);
    expect(fb.switched, isTrue);
  });

  test('只切一次：命中之后再次 find 直接放弃', () async {
    var searches = 0;
    final fb = FxSourceFallback(
      title: '济公传',
      year: 2016,
      currentId: '100',
      sourceName: '幻想',
      searchOwn: (kw) async {
        searches++;
        return <VideoCard>[_card(id: '200', title: '济公传')];
      },
      fetchDetail: (id) async => _detail(id: id, title: '济公传', year: 2016),
      searchExternal: (kw, tried) async => const FxExternalHits(),
    );

    expect((await fb.find(ep: 5)).hit, isTrue);
    final second = await fb.find(ep: 5);
    expect(second.hit, isFalse);
    expect(second.reason, 'already_switched');
    expect(searches, 1, reason: '第二次调用不该再搜一遍');
  });

  test('目标源集数不够：不换源，并把「该源只有 8 集」带出来', () async {
    final fb = FxSourceFallback(
      title: '济公传',
      year: 2016,
      currentId: '100',
      sourceName: '幻想',
      searchOwn: (kw) async => <VideoCard>[_card(id: '200', title: '济公传')],
      // 目标记录只到 8 集
      fetchDetail: (id) async =>
          _detail(id: id, title: '济公传', year: 2016, episodes: 8),
      searchExternal: (kw, tried) async => const FxExternalHits(),
    );

    final out = await fb.find(ep: 12);
    expect(out.hit, isFalse);
    expect(out.note, fxFallbackShortEpText(8));
    expect(fb.switched, isFalse);
  });

  test('片名 / 年份 / 解说预告 三道闸：不同名不换', () async {
    final fb = FxSourceFallback(
      title: '济公传',
      year: 2016,
      currentId: '100',
      sourceName: '幻想',
      searchOwn: (kw) async => <VideoCard>[
        _card(id: '201', title: '济公传第二季'),
        _card(id: '202', title: '济公传', year: 2010),
        _card(id: '203', title: '济公传 第3集解说'),
      ],
      fetchDetail: (id) async => _detail(id: id, title: '济公传', year: 2016),
      searchExternal: (kw, tried) async => const FxExternalHits(),
    );

    final out = await fb.find(ep: 1);
    expect(out.hit, isFalse);
  });

  test('第 2 段没命中就进第 3 段，命中记日志级别的来源名', () async {
    final triedSeen = <Set<String>>[];
    final fb = FxSourceFallback(
      title: '济公传',
      year: 2016,
      currentId: '100',
      sourceName: '幻想',
      searchOwn: (kw) async => const <VideoCard>[],
      fetchDetail: (id) async => _detail(
        id: id,
        title: '济公传',
        year: 2016,
        lines: <LineInfo>[
          LineInfo(
            '@src:gl::keep_1',
            '咕噜线路',
            'hls',
            0,
            epNames: _epNames(12),
          ),
        ],
      ),
      searchExternal: (kw, tried) async {
        triedSeen.add(<String>{...tried});
        return FxExternalHits(
          triedKeys: const <String>['gl|http://gulu.example'],
          hits: <FxExternalHit>[
            FxExternalHit(
              card: _card(
                id: '@src:gl::777',
                title: '济公传',
                sourceLabel: '咕噜',
              ),
              sourceName: '咕噜',
              sourceKey: 'gl|http://gulu.example',
            ),
          ],
        );
      },
    );

    final out = await fb.find(ep: 3);
    expect(out.hit, isTrue);
    expect(out.candidate!.level, 3);
    expect(out.candidate!.sourceName, '咕噜');
    expect(out.candidate!.ep, 3);
    expect(fb.triedSources, contains('gl|http://gulu.example'));
    expect(triedSeen.single, isEmpty, reason: '第一轮没有已试过的源');
  });

  test('jar 没装：第 3 段跳过，结果里如实上报 jarSkipped', () async {
    final fb = FxSourceFallback(
      title: '济公传',
      year: 2016,
      currentId: '100',
      sourceName: '幻想',
      searchOwn: (kw) async => const <VideoCard>[],
      fetchDetail: (id) async => _detail(id: id, title: '济公传', year: 2016),
      searchExternal: (kw, tried) async => const FxExternalHits(
        jarSkipped: true,
        reason: 'jar_missing',
      ),
    );

    final out = await fb.find(ep: 1);
    expect(out.hit, isFalse);
    expect(out.jarSkipped, isTrue);
    expect(out.reason, 'jar_missing');
  });

  test('降级只发生在集号合法时', () async {
    final fb = FxSourceFallback(
      title: '济公传',
      year: 2016,
      currentId: '100',
      sourceName: '幻想',
      searchOwn: (kw) async => <VideoCard>[_card(id: '200', title: '济公传')],
      fetchDetail: (id) async => _detail(id: id, title: '济公传', year: 2016),
      searchExternal: (kw, tried) async => const FxExternalHits(),
    );
    final out = await fb.find(ep: 0);
    expect(out.hit, isFalse);
    expect(out.reason, 'bad_ep');
    expect(fb.switched, isFalse);
  });
}

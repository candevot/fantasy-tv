// 肥猫首页 / 分类（FATCAT_HOME）的数据层回归：
//   · 选源顺序：肥猫配置靠前的常用源（咕噜 / 热播 / 下饭 / 快映 / 一起）优先，
//     其余按配置顺序补位，同「类名 + ext」只留一份；
//   · 卡片加工：id 必须编码成 `@src:`（否则详情 / 播放路由不回原 jar 源），
//     来源标记换成源名，直播条目与空数据丢掉；
//   · 首页流：并行拉、谁先回谁先上屏、最多 6 个分区 / 每区 20 条，
//     坏源 / 空源不拖垮整页；
//   · 当日缓存：同一天内复用（第二次进首页不再爬），换了天 / 坏数据一律当没有。
//
// 这里不真的装 spider.jar，也不联网：`poolProvider` / `homeFetcher` /
// `categoryFetcher` 三个注入点把「41 个 jar 源」换成了假的。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/fatcat_home.dart';
import 'package:fantasy_tv/services/source_hub.dart';

KSource jarSource(String name, {String api = '', String ext = ''}) => KSource(
      key: 'u_$name',
      name: name,
      api: api.isEmpty ? 'csp_$name' : api,
      kind: KSourceKind.jar,
      origin: KSourceOrigin.user,
      ext: ext,
    );

VideoCard card({
  required String id,
  String title = '示例片',
  String category = '电影',
  int year = 2024,
}) =>
    VideoCard.fromJson(<String, dynamic>{
      'id': id,
      'title': title,
      'category': category,
      'year': '$year',
    });

/// 一个源给 [count] 张卡片（id 带源名，便于断言来自哪个源）。
List<VideoCard> cardsOf(String name, int count) => <VideoCard>[
      for (var i = 0; i < count; i++) card(id: '$name-$i', title: '$name 片$i')
    ];

/// 假的「取这个源的首页」：走一遍真实的 [FatcatHome.prepare]（id 编码、
/// 来源标记、直播过滤），和生产里 `_fetchHome` 的出口保持一致。
Future<List<VideoCard>> fakeHome(KSource source, int count) async =>
    FatcatHome.prepare(source, cardsOf(source.name, count));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FatcatHome.clearCache();
    FatcatHome.resetFetchers();
  });

  tearDown(() {
    FatcatHome.resetFetchers();
    FatcatHome.clearCache();
  });

  group('分区 / 拉取的硬上限', () {
    test('最多 6 个分区、每区 20 条、首屏并行 4 路', () {
      // 这几个数字就是「一次别拉 41 个源」的约定，改之前先想清楚首屏耗时。
      expect(fatcatMaxSections, 6);
      expect(fatcatSectionLimit, 20);
      expect(fatcatParallel, 4);
      expect(fatcatBannerCount, 5);
      expect(fatcatTimeout, const Duration(seconds: 8));
    });
  });

  group('选源顺序', () {
    test('优先名单在前，其余按配置顺序补位', () {
      final pool = <KSource>[
        jarSource('随便一', api: 'csp_A'),
        jarSource('下饭', api: 'csp_B'),
        jarSource('咕噜', api: 'csp_C'),
        jarSource('热播', api: 'csp_D'),
      ];
      final names = FatcatHome.candidates(pool: pool)
          .map((source) => source.name)
          .toList();
      expect(names, <String>['咕噜', '热播', '下饭', '随便一']);
    });

    test('同一个类 + 同一个 ext 只留一次（同类不同 ext 是两个站点）', () {
      final pool = <KSource>[
        jarSource('咕噜', api: 'csp_One', ext: 'a'),
        jarSource('咕噜备用', api: 'csp_One', ext: 'a'),
        jarSource('咕噜二站', api: 'csp_One', ext: 'b'),
      ];
      expect(FatcatHome.candidates(pool: pool).length, 2);
    });

    test('名单里一个都没有时保持配置顺序', () {
      final pool = <KSource>[
        jarSource('甲', api: 'csp_A'),
        jarSource('乙', api: 'csp_B'),
        jarSource('丙', api: 'csp_C'),
      ];
      expect(
        FatcatHome.candidates(pool: pool).map((source) => source.key).toList(),
        <String>['u_甲', 'u_乙', 'u_丙'],
      );
    });
  });

  group('卡片加工', () {
    test('id 编码成 @src:<源key>::<vod_id>，标记换成源名', () {
      final ready =
          FatcatHome.prepare(jarSource('咕噜', api: 'csp_Gulu'), <VideoCard>[
        card(id: '100', title: '藏海花'),
      ]);
      expect(ready.length, 1);
      expect(ready.first.id, '@src:u_咕噜::100');
      expect(ready.first.sourceLabel, '咕噜');
      expect(SourceHub.rawIdOf(ready.first.id), '100');
    });

    test('直播条目、空 id、空片名都丢掉', () {
      final ready = FatcatHome.prepare(jarSource('咕噜'), <VideoCard>[
        card(id: '1', title: '正常片'),
        card(id: '2', title: '直播频道', category: '直播'),
        card(id: '', title: '没有 id'),
        card(id: '3', title: ''),
      ]);
      expect(ready.map((c) => c.title).toList(), <String>['正常片']);
    });

    test('同一个 vod_id 只留一条', () {
      final ready = FatcatHome.prepare(jarSource('咕噜'), <VideoCard>[
        card(id: '9', title: '第一部'),
        card(id: '9', title: '第二部'),
      ]);
      expect(ready.length, 1);
      expect(ready.first.title, '第一部');
    });
  });

  group('首页流', () {
    test('谁先回谁先渲染：快的源先出分区 + banner', () async {
      FatcatHome.poolProvider = () => <KSource>[
            jarSource('慢的', api: 'csp_Slow'),
            jarSource('快的', api: 'csp_Fast'),
            jarSource('空的', api: 'csp_Empty'),
          ];
      FatcatHome.homeFetcher = (source) async {
        if (source.name == '空的') return const <VideoCard>[];
        if (source.name == '慢的') {
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
        return fakeHome(source, 3);
      };
      final seen = <String>[];
      var firstBanner = 0;
      var finished = false;
      await for (final feed in FatcatHome.homeStream(force: true)) {
        seen.add(feed.sections.map((s) => s.title).join(','));
        if (!feed.finished && feed.sections.length == 1) {
          firstBanner = feed.banners.length;
        }
        if (feed.finished) finished = true;
      }
      expect(seen.first, '快的'); // 慢的还没回，先上屏的就是快的
      expect(seen.last, '快的,慢的'); // 慢的回来追加在后面
      expect(firstBanner, 3); // banner 来自首个有内容的源
      expect(seen.last.contains('空的'), isFalse);
      expect(finished, isTrue);
    });

    test('最多 6 个分区（10 个源也只铺 6 个）', () async {
      FatcatHome.poolProvider = () => <KSource>[
            for (var i = 0; i < 10; i++) jarSource('源$i', api: 'csp_S$i'),
          ];
      FatcatHome.homeFetcher = (source) => fakeHome(source, 1);
      var count = 0;
      await for (final feed in FatcatHome.homeStream(force: true)) {
        count = feed.sections.length;
      }
      expect(count, fatcatMaxSections);
    });

    test('每区最多 20 条', () async {
      FatcatHome.poolProvider = () => <KSource>[jarSource('大源')];
      FatcatHome.homeFetcher = (source) => fakeHome(source, 40);
      var perSection = 0;
      await for (final feed in FatcatHome.homeStream(force: true)) {
        if (feed.sections.isNotEmpty)
          perSection = feed.sections.first.items.length;
      }
      expect(perSection, fatcatSectionLimit);
    });

    test('同名源只占一个分区', () async {
      FatcatHome.poolProvider = () => <KSource>[
            jarSource('咕噜', api: 'csp_A'),
            jarSource('咕噜', api: 'csp_B'),
          ];
      FatcatHome.homeFetcher = (source) => fakeHome(source, 1);
      var titles = const <String>[];
      await for (final feed in FatcatHome.homeStream(force: true)) {
        titles = feed.sections.map((s) => s.title).toList();
      }
      expect(titles, <String>['咕噜']);
    });

    test('一个源抛异常不影响其它源', () async {
      FatcatHome.poolProvider = () => <KSource>[
            jarSource('坏的', api: 'csp_Bad'),
            jarSource('好的', api: 'csp_Good'),
          ];
      FatcatHome.homeFetcher = (source) async {
        if (source.name == '坏的') throw StateError('jar 炸了');
        return fakeHome(source, 1);
      };
      var titles = const <String>[];
      await for (final feed in FatcatHome.homeStream(force: true)) {
        titles = feed.sections.map((s) => s.title).toList();
      }
      expect(titles, <String>['好的']);
    });

    test('没有任何源可用时也一定收尾（页面不会卡在骨架）', () async {
      FatcatHome.poolProvider = () => const <KSource>[];
      var events = 0;
      var finished = false;
      await for (final feed in FatcatHome.homeStream(force: true)) {
        events++;
        if (feed.finished) finished = true;
      }
      expect(events, 1);
      expect(finished, isTrue);
    });

    test('当日缓存：第二次进首页不再爬源', () async {
      FatcatHome.poolProvider = () => <KSource>[jarSource('缓存源')];
      var calls = 0;
      FatcatHome.homeFetcher = (source) {
        calls++;
        return fakeHome(source, 2);
      };
      await for (final _ in FatcatHome.homeStream(force: true)) {}
      final first = calls;
      expect(first, 1);

      var cached = false;
      var titles = const <String>[];
      await for (final feed in FatcatHome.homeStream()) {
        if (feed.finished && feed.fromCache) cached = true;
        titles = feed.sections.map((s) => s.title).toList();
      }
      expect(calls, first); // 第二次一条都没再拉
      expect(cached, isTrue);
      expect(titles, <String>['缓存源']);
    });
  });

  group('分类页', () {
    test('多源合并 + 去重 + hasMore', () async {
      FatcatHome.poolProvider = () => <KSource>[
            jarSource('A', api: 'csp_A'),
            jarSource('B', api: 'csp_B'),
          ];
      FatcatHome.categoryFetcher = (source, key, page) async {
        if (source.name == 'A')
          return FatcatHome.prepare(source, cardsOf('A', 21));
        return FatcatHome.prepare(source, <VideoCard>[
          card(id: 'A-0', title: 'A 片0'), // 和 A 源重复，要被去掉
          card(id: 'B-1', title: 'B 家的片'),
        ]);
      };
      final feed = await FatcatHome.category('movie', 1, force: true);
      expect(feed.items.length, 22); // A 的 21 条 + B 里那条新的
      expect(feed.hasMore, isTrue); // 有源给满了一页
      expect(feed.sources, 2);
      expect(feed.items.first.id, '@src:u_A::A-0');
      expect(feed.items.last.id, '@src:u_B::B-1');
    });

    test('全空时 hasContent=false（调用方据此回落）', () async {
      FatcatHome.poolProvider = () => <KSource>[jarSource('A')];
      FatcatHome.categoryFetcher =
          (source, key, page) async => const <VideoCard>[];
      final feed = await FatcatHome.category('movie', 1, force: true);
      expect(feed.hasContent, isFalse);
      expect(feed.items, isEmpty);
    });
  });

  group('当日缓存格式', () {
    test('同一天：编码后能解回来，分区顺序不变', () {
      final feed = FatcatFeed(
        banners: <BannerItem>[
          BannerItem('@src:u_咕噜::1', '藏海花', '', '简介', 8.1),
        ],
        sections: <HomeSection>[
          HomeSection('咕噜', <VideoCard>[card(id: '1', title: '藏海花')]),
          HomeSection('热播', <VideoCard>[card(id: '2', title: '大江大河')]),
        ],
        finished: true,
      );
      final back = FatcatHome.decodeFeed(FatcatHome.encodeFeed(feed));
      expect(back, isNotNull);
      expect(back!.sections.map((s) => s.title).toList(), <String>['咕噜', '热播']);
      expect(back.sections.first.items.first.title, '藏海花');
      expect(back.banners.single.title, '藏海花');
      expect(back.fromCache, isTrue);
      expect(back.finished, isTrue);
    });

    test('换了天就当作没有缓存（不同天重新爬）', () {
      final feed = FatcatFeed(
        sections: <HomeSection>[
          HomeSection('咕噜', <VideoCard>[card(id: '1')]),
        ],
      );
      final raw = FatcatHome.encodeFeed(feed);
      expect(
        FatcatHome.decodeFeed(
          raw,
          now: DateTime.now().add(const Duration(days: 1)),
        ),
        isNull,
      );
      expect(FatcatHome.decodeFeed(raw), isNotNull);
    });

    test('空快照 / 坏数据不返回缓存', () {
      expect(
        FatcatHome.decodeFeed(FatcatHome.encodeFeed(const FatcatFeed())),
        isNull,
      );
      expect(FatcatHome.decodeFeed('not a map'), isNull);
      expect(FatcatHome.decodeFeed(<String, dynamic>{'sections': 'x'}), isNull);
    });

    test('日期键是年-月-日（补零）', () {
      expect(FatcatHome.dayKey(DateTime(2026, 1, 5)), '2026-01-05');
      expect(FatcatHome.dayKey(DateTime(2026, 11, 15)), '2026-11-15');
    });
  });
}

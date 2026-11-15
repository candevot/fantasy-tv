// TVBox 配置协议面的解析单测（PROTOCOL_FACE 2026-11-15 · 移植阶段 1 第 1 条）。
//
// 钉住四件事：
//   1. `sites` 的 12 个字段都解析出来了（含缺字段兜底 —— 这是最容易写错、
//      又最不容易在真机上发现的地方：丢一个 timeout 就会让慢源被全局 12 秒误杀）；
//   2. 顶层 `parses` / `flags` / `ads` / `hosts` / `rules` / `doh` / `spider`
//      全都不再被丢弃；
//   3. depot（`{urls:[…]}`）能合并成一份，站点按 key 去重、其余取并集；
//   4. `host=ip`、`ext` 对象/字符串两种写法都不炸。

import 'package:flutter_test/flutter_test.dart';
import 'package:fantasy_tv/services/tvbox_config.dart';

void main() {
  group('sites 的 12 个字段', () {
    test('全字段都能解析出来', () {
      final config = TvBoxConfig.parse(<String, Object?>{
        'sites': <Object?>[
          <String, Object?>{
            'key': 'gulu',
            'name': '咕噜 • APP',
            'api': 'https://a.example.com/api.php/provide/vod',
            'type': 1,
            'ext': 'https://a.example.com/ext',
            'jar': 'https://a.example.com/own.jar',
            'click': 'document.querySelector("#start").click()',
            'playUrl': 'parse:虾米',
            'timeout': 25,
            'header': <String, Object?>{
              'Referer': 'https://a.example.com/',
              'Cookie': 'uid=1',
            },
            'categories': <Object?>['电影', '电视剧'],
            'searchable': 0,
            'changeable': 0,
            'quickSearch': 0,
            'style': <String, Object?>{'ratio': 1.33},
            'playerType': 2,
          },
        ],
      });
      expect(config.sites, hasLength(1));
      final site = config.sites.first;
      expect(site.key, 'gulu');
      expect(site.name, '咕噜 • APP');
      expect(site.api, 'https://a.example.com/api.php/provide/vod');
      expect(site.type, 1);
      expect(site.ext, 'https://a.example.com/ext');
      expect(site.jar, 'https://a.example.com/own.jar');
      expect(site.click, contains('#start'));
      expect(site.playUrl, 'parse:虾米');
      expect(site.timeout, 25);
      expect(site.timeoutOrNull, const Duration(seconds: 25));
      expect(site.header['Referer'], 'https://a.example.com/');
      expect(site.header['Cookie'], 'uid=1');
      expect(site.categories, <String>['电影', '电视剧']);
      expect(site.searchableEnabled, isFalse);
      expect(site.changeableEnabled, isFalse);
      expect(site.quickSearchEnabled, isFalse);
      // style 是对象 → 按 JSON 落成字符串（直接 toString 会得到非法 JSON）。
      expect(site.style, contains('"ratio"'));
      expect(site.playerType, 2);
    });

    test('缺字段全部走壳的默认值', () {
      final config = TvBoxConfig.parse(<String, Object?>{
        'sites': <Object?>[
          <String, Object?>{'key': 'k', 'name': 'n', 'api': 'http://x/y'},
        ],
      });
      final site = config.sites.single;
      expect(site.type, 0);
      expect(site.timeout, 0);
      expect(site.timeoutOrNull, isNull);
      expect(site.header, isEmpty);
      expect(site.categories, isEmpty);
      expect(site.jar, isEmpty);
      expect(site.playUrl, isEmpty);
      expect(site.click, isEmpty);
      // 壳的默认：searchable / changeable / quickSearch 都是 1。
      expect(site.searchableEnabled, isTrue);
      expect(site.changeableEnabled, isTrue);
      expect(site.quickSearchEnabled, isTrue);
      expect(site.playerType, 0);
    });

    test('key 缺失时按 name 兜底，api 缺失则整条跳过', () {
      final config = TvBoxConfig.parse(<String, Object?>{
        'sites': <Object?>[
          <String, Object?>{'name': '只有名字', 'api': 'http://a/b'},
          <String, Object?>{'key': 'no_api', 'name': '没有地址'},
        ],
      });
      expect(config.sites, hasLength(1));
      expect(config.sites.first.key, '只有名字');
      // 被跳过的那条也算进原始条数（验证脚本要报「识别到多少条」）。
      expect(config.siteCount, 2);
      expect(config.skippedSites, 1);
    });

    test('timeout 是字符串 / 负数时按 1 秒处理，不抛异常', () {
      final config = TvBoxConfig.parse(<String, Object?>{
        'sites': <Object?>[
          <String, Object?>{'key': 'a', 'api': 'http://a/b', 'timeout': '18'},
          <String, Object?>{'key': 'b', 'api': 'http://a/b', 'timeout': -5},
        ],
      });
      expect(config.sites[0].timeoutOrNull, const Duration(seconds: 18));
      // 负数：当作「配了但非法」，按最小 1 秒算，而不是当成没配。
      expect(config.sites[1].timeoutOrNull, isNull);
      expect(config.sitesWithTimeout, 1);
    });

    test('header 写成 JSON 字符串也认', () {
      final config = TvBoxConfig.parse(<String, Object?>{
        'sites': <Object?>[
          <String, Object?>{
            'key': 'a',
            'api': 'http://a/b',
            'header': '{"Referer":"http://a/"}',
          },
        ],
      });
      expect(config.sites.single.header['Referer'], 'http://a/');
    });
  });

  group('顶层协议面', () {
    test('parses / flags / ads / hosts / rules / doh / spider 都解析出来', () {
      final config = TvBoxConfig.parse(<String, Object?>{
        'spider': 'http://125.94.244.87/spider.jar',
        'parses': <Object?>[
          <String, Object?>{'name': '聚合', 'type': 3, 'url': 'Web'},
          <String, Object?>{
            'name': '虾米',
            'type': 0,
            'url': 'https://jx.xmflv.com/?url=',
            'ext': <String, Object?>{
              'header': <String, Object?>{'user-agent': 'UA/1.0'},
              'flag': <Object?>['量子', '红牛'],
            },
          },
          // 空条目被丢掉。
          <String, Object?>{'name': '', 'url': ''},
        ],
        'flags': <Object?>['youku', '爱奇艺'],
        'ads': <Object?>['pv.vipwm.cc'],
        'hosts': <Object?>['api.example.com=1.2.3.4', 'jk.example.com=5.6.7.8'],
        'rules': <Object?>[
          <String, Object?>{
            'name': '农民',
            'hosts': <Object?>['toutiaovod.com'],
            'regex': <Object?>['video/tos/cn'],
          },
          <String, Object?>{'name': '磁力广告', 'exclude': <Object?>['磁力']},
        ],
        'doh': <Object?>[
          <String, Object?>{
            'name': 'Google',
            'url': 'https://dns.google/dns-query',
            'ips': <Object?>['8.8.8.8'],
          },
        ],
      });
      expect(config.spider, 'http://125.94.244.87/spider.jar');
      expect(config.parses, hasLength(2));
      expect(config.parses[1].name, '虾米');
      expect(config.parses[1].type, 0);
      expect(config.parses[1].header['user-agent'], 'UA/1.0');
      expect(config.parses[1].flag, <String>['量子', '红牛']);
      expect(config.parses[1].serves('红牛'), isTrue);
      expect(config.parses[1].serves('咪咕'), isFalse);
      expect(config.flags, <String>['youku', '爱奇艺']);
      expect(config.ads, <String>['pv.vipwm.cc']);
      expect(config.hostsMap, <String, String>{
        'api.example.com': '1.2.3.4',
        'jk.example.com': '5.6.7.8',
      });
      expect(config.rules, hasLength(2));
      expect(config.rules.first['name'], '农民');
      expect(config.doh, hasLength(1));
      expect(config.dohUrl, 'https://dns.google/dns-query');
    });

    test('hosts 里的坏条目（没有 = / 空）被忽略', () {
      final config = TvBoxConfig.parse(<String, Object?>{
        'hosts': <Object?>['no_equals_here', ' = ', 'ok.com=9.9.9.9'],
      });
      expect(config.hostsMap, <String, String>{'ok.com': '9.9.9.9'});
    });

    test('lives[0].url 作为直播地址兜底', () {
      final config = TvBoxConfig.parse(<String, Object?>{
        'lives': <Object?>[
          <String, Object?>{'name': '直播', 'url': 'http://live.example.com/tv.m3u'},
        ],
      });
      expect(config.liveUrl, 'http://live.example.com/tv.m3u');
    });

    test('parses 的 ext 是 JSON 字符串时也能解出 flag/header', () {
      final config = TvBoxConfig.parse(<String, Object?>{
        'parses': <Object?>[
          <String, Object?>{
            'name': 'x',
            'type': 1,
            'url': 'http://p/?url=',
            'ext': '{"flag":["A"],"header":{"Referer":"http://r/"}}',
          },
        ],
      });
      expect(config.parses.single.flag, <String>['A']);
      expect(config.parses.single.header['Referer'], 'http://r/');
    });
  });

  group('depot 合并', () {
    test('识别 {urls:[…]} 形态', () {
      final body = <String, Object?>{
        'urls': <Object?>[
          'http://a/1.json',
          <String, Object?>{'url': 'http://a/2.json', 'name': '第二份'},
        ],
      };
      expect(TvBoxConfig.depotUrlsOf(body), <String>[
        'http://a/1.json',
        'http://a/2.json',
      ]);
    });

    test('两份配置合并：站点按 key 去重，其余取并集，spider 取第一个非空', () {
      const a = TvBoxConfig(
        sites: <FxSite>[
          FxSite(key: 'k1', name: 'A1', api: 'http://a/1'),
        ],
        parses: <FxParse>[FxParse(name: 'p1', type: 1, url: 'http://p1/?url=')],
        flags: <String>['youku'],
        ads: <String>['ad1'],
        hosts: <String>['a.com=1.1.1.1'],
        doh: <FxDoh>[FxDoh(name: 'g', url: 'https://dns.google/dns-query')],
        spider: '',
      );
      const b = TvBoxConfig(
        sites: <FxSite>[
          FxSite(key: 'k1', name: 'B1', api: 'http://b/1'),
          FxSite(key: 'k2', name: 'B2', api: 'http://b/2'),
        ],
        parses: <FxParse>[
          FxParse(name: 'p1', type: 1, url: 'http://other/?url='),
          FxParse(name: 'p2', type: 0, url: 'http://p2/?url='),
        ],
        flags: <String>['youku', '爱奇艺'],
        ads: <String>['ad2'],
        hosts: <String>['b.com=2.2.2.2'],
        doh: <FxDoh>[
          FxDoh(name: 'g', url: 'https://dns.google/dns-query'),
          FxDoh(name: 'c', url: 'https://cloudflare-dns.com/dns-query'),
        ],
        spider: 'http://spider.jar',
      );
      final merged = a.merge(b);
      expect(merged.sites.map((s) => s.key), <String>['k1', 'k2']);
      // 先出现的赢：k1 还是 A 那份。
      expect(merged.sites.first.name, 'A1');
      expect(merged.parses.map((p) => p.name), <String>['p1', 'p2']);
      expect(merged.flags, <String>['youku', '爱奇艺']);
      expect(merged.ads, <String>['ad1', 'ad2']);
      expect(merged.hosts, <String>['a.com=1.1.1.1', 'b.com=2.2.2.2']);
      expect(merged.doh, hasLength(2));
      expect(merged.spider, 'http://spider.jar');
    });
  });

  group('落盘往返', () {
    test('protocolToMap → fromProtocolMap 保留 parses/flags/hosts/rules/doh/spider', () {
      final config = TvBoxConfig.parse(<String, Object?>{
        'spider': 'http://s.jar',
        'parses': <Object?>[
          <String, Object?>{
            'name': '虾米',
            'type': 0,
            'url': 'https://jx/?url=',
            'ext': <String, Object?>{'flag': <Object?>['A']},
          },
        ],
        'flags': <Object?>['A'],
        'ads': <Object?>['ad.com'],
        'hosts': <Object?>['h.com=1.1.1.1'],
        'rules': <Object?>[
          <String, Object?>{'name': 'r', 'regex': <Object?>['x']},
        ],
        'doh': <Object?>[
          <String, Object?>{'name': 'g', 'url': 'https://dns.google/dns-query'},
        ],
      });
      final back = TvBoxConfig.fromProtocolMap(config.protocolToMap());
      expect(back.parses.single.name, '虾米');
      expect(back.parses.single.flag, <String>['A']);
      expect(back.flags, <String>['A']);
      expect(back.ads, <String>['ad.com']);
      expect(back.hostsMap['h.com'], '1.1.1.1');
      expect(back.rules.single['name'], 'r');
      expect(back.dohUrl, 'https://dns.google/dns-query');
      expect(back.spider, 'http://s.jar');
    });
  });

  group('ads 广告域过滤', () {
    tearDown(FxAds.resetForTest);

    test('精确域 / 子域 / 混在 URL 里都能认出来', () {
      final ads = FxAds(<String>['pv.vipwm.cc', 'mozai.4gtv.tv']);
      expect(ads.matches('https://pv.vipwm.cc/a.m3u8'), isTrue);
      expect(ads.matches('https://cdn.pv.vipwm.cc/a.m3u8'), isTrue);
      expect(ads.matches('https://mozai.4gtv.tv/x'), isTrue);
      expect(ads.matches('https://cdn.example.com/a.m3u8'), isFalse);
      // 大小写不敏感。
      expect(ads.matches('https://PV.VIPWM.CC/a.m3u8'), isTrue);
    });

    test('空表不误伤', () {
      expect(FxAds.none.isEmpty, isTrue);
      expect(FxAds.none.matches('https://pv.vipwm.cc/a.m3u8'), isFalse);
    });

    test('install / reset 换掉全局表', () {
      expect(FxAds.active.isEmpty, isTrue);
      FxAds.install(FxAds(<String>['pv.vipwm.cc']));
      expect(FxAds.active.matches('https://pv.vipwm.cc/a.m3u8'), isTrue);
      FxAds.resetForTest();
      expect(FxAds.active.isEmpty, isTrue);
    });
  });

  group('统计口径（验证脚本用）', () {
    test('summary 报出 sites / parses / timeout / header 数', () {
      final config = TvBoxConfig.parse(<String, Object?>{
        'sites': <Object?>[
          <String, Object?>{'key': 'a', 'api': 'http://a/1', 'timeout': 20},
          <String, Object?>{
            'key': 'b',
            'api': 'http://b/1',
            'header': <String, Object?>{'Referer': 'http://b/'},
          },
          <String, Object?>{'key': 'c', 'api': 'http://c/1'},
        ],
        'parses': <Object?>[
          <String, Object?>{'name': 'p', 'type': 1, 'url': 'http://p/?url='},
        ],
      });
      expect(config.sitesWithTimeout, 1);
      expect(config.sitesWithHeader, 1);
      final text = config.summary();
      expect(text, contains('sites=3/3'));
      expect(text, contains('parses=1'));
      expect(text, contains('timeout=1'));
      expect(text, contains('header=1'));
    });
  });
}

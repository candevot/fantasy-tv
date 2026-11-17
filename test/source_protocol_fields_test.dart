// 「站点 12 个字段落到哪里」单测（PROTOCOL_FACE 2026-11-15 · 移植阶段 1 第 1/3/4 条）。
//
// `TvBoxConfig` 只负责把 JSON 变成模型；真正被搜索 / 详情 / 播放用到的是
// `KSource` 上的字段。这一组钉住**落地**这一段：
//   · 12 个字段从配置 → KSource（含从本地缓存读回，即 `fromMap`）；
//   · `timeout` → `ownTimeout`（单源超时的实际取值）→ `cmsProfile.timeout`；
//   · `header` / `playUrl` / `click` → `cmsProfile`（CmsClient 发请求时用）；
//   · `searchable` / `changeable` / `quickSearch` 的三态语义；
//   · `type: 0` → `directKind`（决定 `ac=videolist` 还是 `detail`）。

import 'package:flutter_test/flutter_test.dart';
import 'package:fantasy_tv/services/jar_spider.dart';
import 'package:fantasy_tv/services/source_hub.dart';

KSource _source(Map<String, dynamic> map) {
  final source = KSource.fromMap(map);
  expect(source, isNotNull);
  return source!;
}

void main() {
  group('配置字段 → KSource', () {
    test('12 个字段全部落地', () {
      final s = _source(<String, dynamic>{
        'key': 'k',
        'name': '站点',
        'api': 'https://a/api.php/provide/vod',
        'kind': 'cms',
        'origin': 'cloud',
        'ext': '{"site_urls":["https://a/"]}',
        'timeout': 30,
        'header': <String, dynamic>{'Referer': 'https://a/'},
        'playUrl': 'parse:虾米',
        'click': 'document.querySelector("#start").click()',
        'categories': <String>['电影', '电视剧'],
        'jar': 'https://a/own.jar',
        'searchable': 0,
        'changeable': 0,
        'quickSearch': 0,
        'style': '{"ratio":1.33}',
        'playerType': 2,
      });
      expect(s.ext, contains('site_urls'));
      expect(s.timeout, 30);
      expect(s.header['Referer'], 'https://a/');
      expect(s.playUrl, 'parse:虾米');
      expect(s.click, contains('#start'));
      expect(s.categories, <String>['电影', '电视剧']);
      expect(s.jar, 'https://a/own.jar');
      expect(s.searchableFlag, 0);
      expect(s.changeable, 0);
      expect(s.quickSearch, 0);
      expect(s.style, contains('ratio'));
      expect(s.playerType, 2);
    });

    test('老缓存（没有新字段）读回来就是壳的默认值', () {
      final s = _source(<String, dynamic>{
        'key': 'old',
        'name': '老源',
        'api': 'https://old/api.php/provide/vod',
        'kind': 'cms',
        'origin': 'cloud',
      });
      expect(s.timeout, 0);
      expect(s.ownTimeout, isNull);
      expect(s.header, isEmpty);
      expect(s.playUrl, isEmpty);
      expect(s.categories, isEmpty);
      expect(s.jar, isEmpty);
      expect(s.searchableFlag, 1);
      expect(s.changeable, 1);
      expect(s.quickSearch, 1);
      expect(s.playerType, 0);
    });

    test('toMap → fromMap 不丢字段（落盘往返）', () {
      final s = _source(<String, dynamic>{
        'key': 'k',
        'name': '站点',
        'api': 'https://a/api.php/provide/vod',
        'kind': 'cms',
        'origin': 'cloud',
        'timeout': 45,
        'header': <String, dynamic>{'Cookie': 'u=1'},
        'playUrl': 'json:https://p/?url=',
        'categories': <String>['动漫'],
        'searchable': 0,
      });
      final back = _source(s.toMap());
      expect(back.timeout, 45);
      expect(back.header['Cookie'], 'u=1');
      expect(back.playUrl, 'json:https://p/?url=');
      expect(back.categories, <String>['动漫']);
      expect(back.searchableFlag, 0);
      // 默认值不必写进 map（省体积），读回来仍是默认。
      final plain = _source(<String, dynamic>{
        'key': 'p',
        'name': 'p',
        'api': 'https://p/api.php/provide/vod',
        'kind': 'cms',
        'origin': 'user',
      });
      expect(plain.toMap().containsKey('timeout'), isFalse);
    });
  });

  group('单源超时', () {
    test('配了 timeout 用配置的，没配返回 null（交给全局 12 秒）', () {
      final slow = _source(<String, dynamic>{
        'key': 'slow',
        'api': 'https://slow/api.php/provide/vod',
        'kind': 'cms',
        'origin': 'cloud',
        'timeout': 60,
      });
      expect(slow.ownTimeout, const Duration(seconds: 60));

      final normal = _source(<String, dynamic>{
        'key': 'n',
        'api': 'https://n/api.php/provide/vod',
        'kind': 'cms',
        'origin': 'cloud',
      });
      expect(normal.ownTimeout, isNull);
      // 全局兜底（2026-11-18 从 12s 调到 8s：36 个源并发时 12 秒整体太慢，
      // 实测 98% 的源 3 秒内返回）。这里锁住当前值，改动要同步改本断言。
      expect(SourceHub.sourceTimeout, const Duration(seconds: 8));
    });

    test('timeout 传进 CmsClient 的站点画像', () {
      final s = _source(<String, dynamic>{
        'key': 'slow',
        'api': 'https://slow/api.php/provide/vod',
        'kind': 'cms',
        'origin': 'cloud',
        'timeout': 60,
      });
      expect(s.cmsProfile.timeout, const Duration(seconds: 60));
      expect(s.cmsProfile.key, 'slow');
    });
  });

  group('站点画像（CmsClient 的入参）', () {
    test('header / ext / playUrl / click / directKind 全带上', () {
      final cms = _source(<String, dynamic>{
        'key': 'c',
        'api': 'https://c/api.php/provide/vod',
        'kind': 'cms',
        'origin': 'cloud',
        'ext': 'abc',
        'header': <String, dynamic>{'Referer': 'https://c/'},
        'playUrl': 'parse:云解',
        'click': 'click()',
      });
      expect(cms.cmsProfile.header['Referer'], 'https://c/');
      expect(cms.cmsProfile.ext, 'abc');
      expect(cms.cmsProfile.playUrl, 'parse:云解');
      expect(cms.cmsProfile.click, 'click()');
      // type 1（cms）→ ac=detail；type 0（direct）→ ac=videolist。
      expect(cms.cmsProfile.directKind, isFalse);

      final direct = _source(<String, dynamic>{
        'key': 'd',
        'api': 'https://d/list.json',
        'kind': 'direct',
        'origin': 'cloud',
      });
      expect(direct.cmsProfile.directKind, isTrue);
    });

    test('quickSearch=0 传进画像（搜索时不带 quick 参数）', () {
      final s = _source(<String, dynamic>{
        'key': 'q',
        'api': 'https://q/api.php/provide/vod',
        'kind': 'cms',
        'origin': 'cloud',
        'quickSearch': 0,
      });
      expect(s.quickSearchEnabled, isFalse);
      expect(s.cmsProfile.quickSearch, isFalse);
    });
  });

  group('可搜 / 可换源', () {
    test('searchable: 0 时这个源不参与检索', () {
      final s = _source(<String, dynamic>{
        'key': 'x',
        'api': 'https://x/api.php/provide/vod',
        'kind': 'cms',
        'origin': 'cloud',
        'searchable': 0,
      });
      expect(s.searchableFlag, 0);
      expect(s.searchable, isFalse);
    });

    test('没有 searchable 字段时默认参与检索', () {
      final s = _source(<String, dynamic>{
        'key': 'x',
        'api': 'https://x/api.php/provide/vod',
        'kind': 'cms',
        'origin': 'cloud',
      });
      expect(s.searchable, isTrue);
    });

    test('changeable: 0 时不可被换源选中', () {
      final s = _source(<String, dynamic>{
        'key': 'x',
        'api': 'https://x/api.php/provide/vod',
        'kind': 'cms',
        'origin': 'cloud',
        'changeable': 0,
      });
      expect(s.changeableEnabled, isFalse);
    });
  });

  group('flags → jar 的 playerContent', () {
    tearDown(() => JarSpider.setVipFlags(const <String>[]));

    test('没配 flags 时保持写死的默认名单（行为与改造前一致）', () {
      JarSpider.setVipFlags(const <String>[]);
      expect(JarSpider.vipFlags, JarSpider.defaultVipFlags);
      expect(JarSpider.vipFlags, contains('iqiyi'));
    });

    test('配了 flags 就用配置的（壳的 VodConfig.get().getFlags() 语义）', () {
      JarSpider.setVipFlags(<String>['youku', ' 优酷 ', '爱奇艺', '']);
      expect(JarSpider.vipFlags, <String>['youku', '优酷', '爱奇艺']);
      expect(JarSpider.vipFlags, isNot(contains('qq')));
    });
  });

  group('copyWith 不丢协议字段', () {
    test('改名后 timeout / header / playUrl 还在', () {
      final s = _source(<String, dynamic>{
        'key': 'k',
        'name': '旧名',
        'api': 'https://a/api.php/provide/vod',
        'kind': 'cms',
        'origin': 'user',
        'timeout': 20,
        'header': <String, dynamic>{'Referer': 'https://a/'},
        'playUrl': 'parse:虾米',
      });
      final renamed = s.copyWith(name: '新名');
      expect(renamed.name, '新名');
      expect(renamed.timeout, 20);
      expect(renamed.header['Referer'], 'https://a/');
      expect(renamed.playUrl, 'parse:虾米');
    });
  });
}

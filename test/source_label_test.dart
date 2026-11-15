import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/services/source_hub.dart';

/// SOURCE_LABEL（2026-11-15）回归：搜索结果卡片上「来源」到底写什么。
///
/// 用户实测：搜「济公传」时同一条我们自己的片，有的标「来源：云端」、
/// 有的标「来源：幻想」，看着像两个站。规则定死成三句话：
///
///   1. 我们自己的源（api 含 `125.94.244.87/api.php`）→ **永远**只叫「幻想」；
///   2. 肥猫的 jar 源（`csp_*`）→ 用它自己的名字（`咕噜 • APP` → `咕噜`）；
///   3. 用户自加的源 → 也用它自己的名字；
///   4. 认不出来的（直播 / 暂不支持 / 没名字）→ 空串，卡片不显示这一行。
///
/// 另一条同样要钉住的约定：**线路名不是来源标注**。
/// 「幻想4K / 幻想1080P / 量子 / 红牛 / SH4K」这些是线路名，跟着 [VideoCard]
/// 自己的字段走，不能被来源标注顶掉。
void main() {
  KSource src({
    String key = 'k',
    String name = 'n',
    required String api,
    KSourceKind kind = KSourceKind.cms,
    KSourceOrigin origin = KSourceOrigin.cloud,
  }) =>
      KSource(
        key: key,
        name: name,
        api: api,
        kind: kind,
        origin: origin,
      );

  group('我们自己的源：永远只叫「幻想」', () {
    test('主站采集库', () {
      final s = src(
        key: 'hx_all',
        name: '幻想·全部线路',
        api: 'http://125.94.244.87/api.php/provide/vod/',
      );
      expect(s.resultLabel, '幻想');
    });

    test('云端下发的线路切片（以前这里标「云端」）', () {
      final s = src(
        key: 'hx_4k',
        name: '幻想·4K',
        api: 'http://125.94.244.87/api.php/provide/vod/?line=幻想4K',
      );
      expect(s.resultLabel, '幻想');
      // 线路名归线路名，来源标注不跟它混。
      expect(s.resultLabel, isNot(contains('4K')));
    });

    test('自己动手加的、但地址是 hx 库的源，也算我们自己的', () {
      final s = src(
        key: 'u_hx',
        name: '我的幻想',
        api: 'http://125.94.244.87/api.php/provide/vod/?line=红牛',
        origin: KSourceOrigin.user,
      );
      expect(s.resultLabel, '幻想');
    });
  });

  group('肥猫的 jar 源：用它自己的名字', () {
    test('「咕噜 • APP」→ 咕噜', () {
      final s = src(
        key: '咕噜',
        name: '咕噜 • APP',
        api: 'csp_Gulu',
        kind: KSourceKind.jar,
      );
      expect(s.resultLabel, '咕噜');
      // 不是统一的「肥猫」。
      expect(s.resultLabel, isNot('肥猫'));
    });

    test('「豆瓣 • 首页」→ 豆瓣', () {
      final s = src(name: '豆瓣 • 首页', api: 'csp_Douban', kind: KSourceKind.jar);
      expect(s.resultLabel, '豆瓣');
    });

    test('「玩偶 • 4K」→ 玩偶（后缀是类型，不是名字）', () {
      final s = src(name: '玩偶 • 4K', api: 'csp_Wogg', kind: KSourceKind.jar);
      expect(s.resultLabel, '玩偶');
    });

    test('「韩圈 • APP」→ 韩圈（名字里有空格也照常）', () {
      final s = src(name: '韩圈 • APP', api: 'csp_Hxq', kind: KSourceKind.jar);
      expect(s.resultLabel, '韩圈');
    });

    test('没有分隔符的名字原样留着', () {
      final s = src(name: '剧圈', api: 'csp_App99', kind: KSourceKind.jar);
      expect(s.resultLabel, '剧圈');
    });
  });

  group('用户自加的源：用它自己的名字', () {
    test('CMS 源', () {
      final s = src(
        key: 'u_mine',
        name: '我的采集站',
        api: 'http://example.com/api.php/provide/vod/',
        origin: KSourceOrigin.user,
      );
      expect(s.resultLabel, '我的采集站');
    });
  });

  group('认不出来的不标', () {
    test('直播源不标（直播有独立入口）', () {
      final s = src(
        name: '我的直播',
        api: 'http://example.com/live.m3u',
        kind: KSourceKind.live,
      );
      expect(s.resultLabel, '');
    });

    test('暂不支持的 type 4 不标', () {
      final s = src(
        name: 'python 源',
        api: './api/drpy2.min.js',
        kind: KSourceKind.unsupported,
      );
      expect(s.resultLabel, '');
    });

    test('没名字 / 没 api 都不标', () {
      expect(src(name: '   ', api: 'csp_Gulu', kind: KSourceKind.jar).resultLabel, '');
      expect(src(name: '空地址', api: '  ').resultLabel, '');
    });
  });

  group('id 路由：我们自己的库不走 @src: 前缀', () {
    test('hx 源的卡片 id 就是裸 vod_id（详情走主站，永远找得到）', () {
      final s = src(
        key: 'hx_4k',
        api: 'http://125.94.244.87/api.php/provide/vod/?line=幻想4K',
      );
      expect(s.isOwnLibrary, isTrue);
      expect(s.cardIdOf('12345'), '12345');
      expect(s.cardIdOf('12345'), isNot(startsWith(SourceHub.idMark)));
    });

    test('外部源仍然编码成 @src:<key>::<id>', () {
      final s = src(name: '咕噜', api: 'csp_Gulu', kind: KSourceKind.jar);
      expect(s.isOwnLibrary, isFalse);
      expect(s.cardIdOf('abc'), '${SourceHub.idMark}咕噜::abc');
      expect(SourceHub.rawIdOf(s.cardIdOf('abc')), 'abc');
    });
  });
}

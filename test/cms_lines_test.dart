import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/services/cms_api.dart';
import 'package:fantasy_tv/services/cms_source.dart';

/// 多线路回归（LINES_ALL，2026-11-15）。
///
/// 用户实测报「详情页只显示红牛一条线路」。接口本身是对的 ——
/// `?ac=detail&ids=2` 的 `vod_play_from` 是
/// `量子$$$幻想4K$$$红牛$$$幻想蓝光`，四条线路、四个地址块都在。
/// 所以这里用**真实接口返回**（test/fixtures/detail_romelia.json，抓自
/// 125.94.244.87）把「解析层必须原样给出四条」钉成断言：
///   · 只出 1 条 → 解析层把 `$$$` 切丢了；
///   · 出 4 条但集名 / 集数串行 → 又是「点进去播不出来」。
void main() {
  Map<String, dynamic> _realVod() {
    final body = jsonDecode(
      File('test/fixtures/detail_romelia.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final list = body['list'] as List<dynamic>;
    return Map<String, dynamic>.from(list.first as Map<dynamic, dynamic>);
  }

  group('多线路解析（真实接口数据）', () {
    test('罗梅莉亚战记：四条线路一个都不能少，顺序也不变', () {
      final lines = parseLines(_realVod());
      expect(
        <String>[for (final line in lines) line.info.displayName],
        <String>['量子', '幻想4K', '红牛', '幻想蓝光'],
      );
      expect(lines.length, 4);
    });

    test('每条线路都有自己的集地址，长度不为 0', () {
      for (final line in parseLines(_realVod())) {
        expect(line.count, greaterThan(0), reason: '${line.info.name} 没有集地址');
        expect(line.info.epNames.length, line.count);
      }
    });

    test('线路类型判定按地址本身走，不按线路名猜', () {
      final byName = <String, CmsLine>{
        for (final line in parseLines(_realVod())) line.info.name: line,
      };
      // 量子给的是 /share/<md5> 页面（不是 m3u8），要现场交给 hxparse。
      expect(byName['量子']!.needsParse, isTrue);
      // 幻想4K / 幻想蓝光的令牌已经包在 hxparse 的 m3u8 地址里
      // （`/hxparse/play/fuying/FY-SH4K-<md5>/index.m3u8`），可以直接播。
      expect(byName['幻想4K']!.needsParse, isFalse);
      expect(byName['幻想4K']!.urls.first, endsWith('index.m3u8'));
      expect(byName['幻想蓝光']!.needsParse, isFalse);
      // 红牛给的是 hn.bfvvs.com 的真 m3u8 直链。
      expect(byName['红牛']!.needsParse, isFalse);
      expect(byName['红牛']!.urls.first, contains('.m3u8'));
    });

    test('detailJson 交给 UI 的 lines 也是四条', () {
      final vod = _realVod();
      final json = CmsApi.detailJson(vod, parseLines(vod));
      final lines = json['lines'] as List<dynamic>;
      expect(lines.length, 4);
      expect(
        <String>[for (final l in lines) '${(l as Map<String, dynamic>)['name']}'],
        <String>['量子', '幻想4K', '红牛', '幻想蓝光'],
      );
    });

    test('单线路影片（济公传只有红牛）就只出一条，不补假线路', () {
      final lines = parseLines(<String, dynamic>{
        'vod_id': 202369,
        'vod_name': '济公传',
        'vod_play_from': '红牛',
        'vod_play_url': '第01集\$https://hn.bfvvs.com/play/x/index.m3u8',
      });
      expect(lines.length, 1);
      expect(lines.first.info.name, '红牛');
    });

    test('空线路 / 占位地址不进 UI（about:blank 那类脏数据）', () {
      final lines = parseLines(<String, dynamic>{
        'vod_id': 1,
        'vod_play_from': 'tips\$\$\$红牛',
        'vod_play_url': 'about:blank\$\$\$第01集\$https://hn.bfvvs.com/play/y/index.m3u8',
      });
      expect(<String>[for (final l in lines) l.info.name], <String>['红牛']);
    });
  });

  group('热播排序参数（HOT_ORDER）', () {
    test('sort=hot / hits / sort=rating 映射到服务端字段', () {
      // 首页六行与排行榜都按 `sort: 'hot'` 请求，映射到 vod_hits；
      // 映射错了首页展示的就是「最近入库」而不是热播剧。
      expect(CmsApi.orderOf('hot'), 'vod_hits');
      expect(CmsApi.orderOf('hits'), 'vod_hits');
      expect(CmsApi.orderOf('rating'), 'vod_score');
      expect(CmsApi.orderOf('latest'), 'vod_time');
      // 大小写不敏感（页面/云端配置都可能写大写）。
      expect(CmsApi.orderOf('HOT'), 'vod_hits');
    });
  });
}

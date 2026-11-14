import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/cms_api.dart';
import 'package:fantasy_tv/services/cms_source.dart';

/// 数据层回归：`vod_play_from` / `vod_play_url` 的解析规则。
///
/// 这里的字符串都是站点真实返回的片段（2026-11-14 抓的）：
///   · `幻想4K` 给的是 `FY-SH4K-<md5>` 令牌，不是 m3u8；
///   · `量子` 给的是 `https://lzv34.com/share/<md5>` 页面，也不是 m3u8；
///   · `幻想爱奇艺` 不来自采集，压根没有集地址。
///
/// 解析错一处，用户就会看到「能点但播不出来」的线路，所以规则固定在这里。
Map<String, dynamic> _vod(Map<String, dynamic> over) => <String, dynamic>{
      'vod_id': 3822,
      'vod_name': '头号玩家',
      'vod_year': '2018',
      ...over,
    };

void main() {
  test('幻想4K 令牌线路：判定为需解析，集名按线路自己保存', () {
    final lines = parseLines(_vod(<String, dynamic>{
      'vod_play_from': '幻想4K',
      'vod_play_url': '国语高清正片\$FY-SH4K-11d01a6e89b1238ef9dcd95f7213b418'
          '#英语高清正片\$FY-SH4K-d1789766544bb2399551741a21828378',
    }));
    expect(lines.length, 1);
    final line = lines.single;
    expect(line.info.name, '幻想4K');
    expect(line.info.type, 'parse');
    expect(line.info.id, 'cms_3822_1');
    expect(line.count, 2);
    expect(line.info.epNames, <String>['国语高清正片', '英语高清正片']);
    expect(line.urlAt(1), 'FY-SH4K-11d01a6e89b1238ef9dcd95f7213b418');
    expect(line.urlAt(3), isNull);
    expect(needsParse(line.urlAt(1)!), isTrue);
    expect(parseKindOf(line.info.name, line.urlAt(1)!), 'fuying');
  });

  test('量子：share 页面要解析，真 m3u8 直链不解析', () {
    final share = parseLines(_vod(<String, dynamic>{
      'vod_play_from': '量子',
      'vod_play_url':
          '第01集\$https://lzv34.com/share/3d8d871debc0dcfeb788f3fbf310f07f',
    })).single;
    expect(share.info.type, 'parse');
    expect(share.info.epNames, <String>['第01集']);

    final direct = parseLines(_vod(<String, dynamic>{
      'vod_play_from': '红牛',
      'vod_play_url': '第01集\$https://cdn.example.com/a/1.m3u8'
          '#第02集\$https://cdn.example.com/a/2.m3u8',
    })).single;
    expect(direct.info.type, 'hls');
    expect(direct.count, 2);
    expect(needsParse(direct.urlAt(2)!), isFalse);
  });

  test('单集线路叫「正片」，多集才叫「第 N 集」', () {
    final single = parseLines(_vod(<String, dynamic>{
      'vod_play_from': '量子',
      'vod_play_url': r'$https://cdn.example.com/movie.m3u8',
    })).single;
    expect(single.info.epNames, <String>['正片']);

    final multi = parseLines(_vod(<String, dynamic>{
      'vod_play_from': '量子',
      'vod_play_url':
          r'$https://cdn.example.com/1.m3u8#$https://cdn.example.com/2.m3u8',
    })).single;
    expect(multi.info.epNames, <String>['第1集', '第2集']);
  });

  test('幻想爱奇艺没有采集地址：按最长线路补占位集，播放时按集号现查', () {
    final lines = parseLines(_vod(<String, dynamic>{
      'vod_play_from': '量子\$\$\$幻想爱奇艺',
      'vod_play_url': '第01集\$https://cdn.example.com/1.m3u8'
          '#第02集\$https://cdn.example.com/2.m3u8'
          '#第03集\$https://cdn.example.com/3.m3u8\$\$\$',
    }));
    expect(lines.length, 2);
    final iqiyi = lines[1];
    expect(iqiyi.info.name, '幻想爱奇艺');
    expect(iqiyi.info.type, 'parse');
    expect(iqiyi.count, 3);
    expect(iqiyi.info.epNames, <String>['第1集', '第2集', '第3集']);
    expect(iqiyi.isIqiyiAt(1), isTrue);
    expect(parseKindOf(iqiyi.info.name, ''), 'iqiyi');
  });

  test('线路名比地址块多一项时按下标对齐，不错位', () {
    final lines = parseLines(_vod(<String, dynamic>{
      'vod_play_from': '量子\$\$\$幻想爱奇艺',
      'vod_play_url': '第01集\$https://cdn.example.com/1.m3u8',
    }));
    expect(lines.length, 2);
    expect(lines[0].info.name, '量子');
    expect(lines[0].info.type, 'hls');
    expect(lines[1].info.name, '幻想爱奇艺');
    expect(lines[1].info.type, 'parse');
  });

  test('集数 / 线路列表走最长线路，卡片也按最长线路算', () {
    final vod = _vod(<String, dynamic>{
      'vod_play_from': '量子\$\$\$幻想4K',
      'vod_play_url': '第01集\$https://cdn.example.com/1.m3u8'
          '#第02集\$https://cdn.example.com/2.m3u8'
          '\$\$\$正片\$FY-SH4K-abc',
    });
    final detail = CmsApi.detailOf(vod, parseLines(vod));
    expect(detail.episodes, 2, reason: '取最长那条线路（量子 2 集）');
    expect(detail.lines.length, 2);
    expect(detail.allEpisodes.length, 2);
    expect(detail.allEpisodes.first.name, '第01集');

    final card = CmsApi.cardOf(vod);
    expect(card.id, '3822');
    expect(card.title, '头号玩家');
    expect(card.year, 2018);
    expect(card.sourceLabel, '量子');
    expect(detail.sourceLabel.isNotEmpty, isTrue);
  });

  test('findLine：按 id、显示名、基础名都能定位', () {
    final lines = parseLines(_vod(<String, dynamic>{
      'vod_play_from': '幻想4K\$\$\$量子',
      'vod_play_url': '正片\$FY-SH4K-abc\$\$\$正片\$https://cdn.example.com/x.m3u8',
    }));
    expect(findLine(lines, 'cms_3822_2')?.info.name, '量子');
    expect(findLine(lines, '幻想4K')?.info.name, '幻想4K');
    expect(findLine(lines, '幻想4K·高清')?.info.name, '幻想4K');
    expect(findLine(lines, '不存在的线路'), isNull);
  });

  test('解析地址：默认 /hxparse/parse，另一套路径由 _resolve 兜底', () {
    final fuying = CmsApi.fuyingUri('FY-SH4K-abc');
    expect(fuying.path, '/hxparse/parse/fuying');
    expect(fuying.queryParameters['u'], 'FY-SH4K-abc');

    final short = CmsApi.fuyingUri('FY-SH4K-abc', base: CmsApi.parsePathShort);
    expect(short.path, '/hxparse/fuying');

    final iqiyi = CmsApi.iqiyiUri(title: '头号玩家', year: 2018, ep: 2);
    expect(iqiyi.path, '/hxparse/parse/iqiyi');
    expect(iqiyi.queryParameters['title'], '头号玩家');
    expect(iqiyi.queryParameters['year'], '2018');
    expect(iqiyi.queryParameters['ep'], '2');
    // 年份未知时不传空串以外的垃圾，交给服务端按剧名自己找。
    expect(CmsApi.iqiyiUri(title: 'x').queryParameters['year'], '');
  });

  test('脏数据不炸：空 play_url / 乱序字段 / 非 http 地址', () {
    expect(parseLines(_vod(<String, dynamic>{})), isEmpty);
    expect(parseLines(_vod(<String, dynamic>{'vod_play_from': '量子'})), isEmpty);
    expect(
      parseLines(_vod(<String, dynamic>{
        'vod_play_url': '第01集\$https://cdn.example.com/1.m3u8',
      })).single.info.name,
      '线路1',
    );
    expect(
        lineInfosOf(_vod(<String, dynamic>{
          'vod_play_from': '幻想蓝光',
          'vod_play_url': '正片\$https://hx.example.com/p/1',
        })),
        isA<List<LineInfo>>());
  });
}

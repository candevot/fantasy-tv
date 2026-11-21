import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/services/platform_rank.dart';

/// 平台热播榜解析（RANK_BOARD 2026-11-21）。
///
/// 这一层只有一个责任：把 `GET /api/rank?source=…&type=…` 的 `data`
/// 解析成榜单页能直接渲染的东西，并且**不把没片可点的条目带上屏**。
/// 这里钉住四件事：
///   1. 名次用的是服务端给的 `rank`，不是列表下标（服务端只返回对得上库的
///      条目，名次会断号，按下标显示就会出现「第 3 名」其实是平台第 7 名）；
///   2. `vod_id` 为空 / 为 0 / 缺 title 的条目直接丢掉；
///   3. 年份缺失按 0 处理，页面据此隐藏年份；
///   4. 频道号 / 平台 key 与同步脚本一致（1 电影 2 电视剧 3 动漫 4 综艺）。
void main() {
  group('PlatformRankBoard.fromJson', () {
    test('按服务端 rank 渲染，不用列表下标', () {
      final board = PlatformRankBoard.fromJson(<String, dynamic>{
        'source': 'tencent',
        'type': 1,
        'channel': 'movie',
        'channelName': '电影',
        'count': 2,
        'updatedAt': 1795264411,
        'stale': false,
        'items': <dynamic>[
          <String, dynamic>{
            'rank': 4,
            'title': '四渡',
            'year': 2026,
            'vod_id': 1000193568,
            'cover': 'https://img/4.jpg',
          },
          <String, dynamic>{
            'rank': 9,
            'title': '空枪',
            'year': 2026,
            'vod_id': 1000194037,
            'cover': 'https://img/9.jpg',
          },
        ],
      });

      expect(board.source, 'tencent');
      expect(board.type, 1);
      expect(board.channelName, '电影');
      expect(board.stale, isFalse);
      expect(board.items.map((e) => e.rank).toList(), <int>[4, 9]);
      expect(board.items.first.vodId, '1000193568');
      expect(board.items.first.title, '四渡');
      expect(board.items.first.year, 2026);
    });

    test('没片可点的条目不上屏（vod_id 空 / 0 / 缺 title）', () {
      final board = PlatformRankBoard.fromJson(<String, dynamic>{
        'source': 'iqiyi',
        'type': 2,
        'items': <dynamic>[
          <String, dynamic>{'rank': 1, 'title': '两京十五日', 'vod_id': 0},
          <String, dynamic>{'rank': 2, 'title': '', 'vod_id': 12},
          <String, dynamic>{'rank': 3, 'title': '折月亮', 'vod_id': ''},
          <String, dynamic>{'rank': 5, 'title': '罪恶拼图', 'vod_id': 1000193559},
        ],
      });

      expect(board.items.length, 1);
      expect(board.items.single.rank, 5);
      expect(board.items.single.vodId, '1000193559');
    });

    test('年份缺失按 0；stale 只有 true 才算', () {
      final board = PlatformRankBoard.fromJson(<String, dynamic>{
        'source': 'tencent',
        'type': 3,
        'stale': 'true',
        'items': <dynamic>[
          <String, dynamic>{'rank': 2, 'title': '名侦探柯南', 'vod_id': 27793},
        ],
      });

      expect(board.items.single.year, 0);
      expect(board.stale, isFalse);
      expect(board.channelName, '');
    });

    test('空 / 脏 items 不抛异常，就是空榜', () {
      expect(PlatformRankBoard.fromJson(<String, dynamic>{'items': null}).items,
          isEmpty);
      expect(
        PlatformRankBoard.fromJson(<String, dynamic>{
          'items': <dynamic>['x', 1, null],
        }).items,
        isEmpty,
      );
      expect(PlatformRankBoard.empty.isEmpty, isTrue);
    });
  });

  group('平台 / 频道定义', () {
    test('频道号与 hot_rank_sync.php 一致', () {
      expect(PlatformRankApi.channels.map((c) => c.type).toList(),
          <int>[1, 2, 3, 4]);
      expect(PlatformRankApi.channels.map((c) => c.label).toList(),
          <String>['电影', '电视剧', '动漫', '综艺']);
    });

    test('两个平台，key 与接口参数一致', () {
      expect(PlatformRankApi.platforms.map((p) => p.key).toList(),
          <String>['tencent', 'iqiyi']);
    });

    test('未知 key / type 回落第一项，界面不会崩', () {
      expect(PlatformRankApi.platformOf('bilibili').key, 'tencent');
      expect(PlatformRankApi.channelOf(9).type, 1);
    });
  });
}

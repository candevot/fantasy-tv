import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/services/cms_source.dart';
import 'package:fantasy_tv/services/play_path.dart';

/// 死线路（DEAD_LINE）与线路对齐（LINE_ALIGN）回归 —— 2026-11-15。
///
/// 现场：用户切到「幻想蓝光」线路时 App **直接退出**。两件事叠在一起：
///   1. 幻想蓝光的 FY-PAN1 令牌**整批失效**（/hxparse/play/fuying/FY-PAN1-…
///      404，上游 jx4k.fuyingapi.top 回「只支持 http/https 地址」），
///      全库 36,079 条带这条线路的记录里没有一条能播；
///   2. 采集器 filter_episodes() 只过滤 vod_play_url 不动 vod_play_from，
///      于是一条线路整条都是预告/花絮时，地址被删、线路名还在，
///      后面所有线路 from/url 整体错位一格 —— 库里因此出现
///      「有线路名、没地址」的段（空 URL），那正是把播放器带崩的输入。
///
/// 这个文件钉住两件事：
///   · 死线路在**解析层**就被跳过，用户拿不到一条必然失败的线路；
///   · 错位 / 空地址的脏数据进来时，解析层只少一条线路，绝不抛异常。

Map<String, dynamic> _vod(String from, String url) => <String, dynamic>{
      'vod_id': 5004,
      'vod_name': '八仙',
      'vod_year': '2026',
      'vod_play_from': from,
      'vod_play_url': url,
    };

void main() {
  group('死线路判定（DEAD_LINE）', () {
    test('幻想蓝光 + PAN1 令牌：判死', () {
      expect(isDeadLine('幻想蓝光', const <String>['FY-PAN1-abc']), isTrue);
      expect(
        isDeadLine(' 幻想蓝光 ', const <String>[
          'http://125.94.244.87/hxparse/play/fuying/FY-PAN1-abc/index.m3u8',
        ]),
        isTrue,
      );
    });

    test('名字不参与判定：名叫幻想蓝光、地址是活的 → 保留（不能误伤）', () {
      expect(
        isDeadLine('幻想蓝光', const <String>['https://x/y/index.m3u8']),
        isFalse,
      );
      expect(
        isDeadLine('幻想蓝光', const <String>['FY-SH4K-abc']),
        isFalse,
        reason: '4K 令牌是活的，不能因为挂在蓝光名下就被丢掉',
      );
    });

    test('FY-PAN1 令牌：地址命中即判死（换了个线路名也一样）', () {
      expect(
        isDeadLine('某条新线路', const <String>[
          'http://125.94.244.87/hxparse/play/fuying/FY-PAN1-abc/index.m3u8',
        ]),
        isTrue,
      );
      expect(
        isDeadAddress(
          'http://125.94.244.87/hxparse/play/fuying/FY-PAN1-abc/index.m3u8',
        ),
        isTrue,
      );
    });

    test('mgtv 网页地址判死，爱奇艺 / 4K 令牌不误伤', () {
      expect(isDeadAddress('https://www.mgtv.com/b/841794/24769816.html'), isTrue);
      expect(
        isDeadAddress(
          'http://125.94.244.87/hxparse/play/fuying/FY-SH4K-ee1cd9/index.m3u8',
        ),
        isFalse,
      );
      expect(
        isDeadAddress('http://125.94.244.87/hxparse/play/iqiyi/1/index.m3u8'),
        isFalse,
      );
      expect(isDeadAddress('https://hn.bfvvs.com/play/bYEQzLOb/index.m3u8'),
          isFalse);
    });

    test('一条线路只要还有一集能播就不算死', () {
      expect(
        isDeadLine('幻想蓝光', const <String>[
          'FY-PAN1-dead',
          'https://hn.bfvvs.com/play/live/index.m3u8',
        ]),
        isFalse,
        reason: '地址有活口时按「名字就判死」会误伤换成新令牌的情况',
      );
    });

    test('空地址 = 没得播，判死', () {
      expect(isDeadLine('量子', const <String>['']), isTrue);
      expect(isDeadLine('量子', const <String>[]), isTrue);
    });
  });

  group('死线路在解析层就被跳过（不该让播放器拿到）', () {
    // 取自 ac=detail&ids=5004 修之前的真实输出（11 条线路，蓝光用的是 PAN1）。
    const from = 'SH4K\$\$\$幻想4K\$\$\$幻想蓝光\$\$\$bilibili\$\$\$qq\$\$\$幻想爱奇艺\$\$\$红牛';
    const url = '第1集\$SH4K-ee1c\$\$\$'
        '第1集\$http://125.94.244.87/hxparse/play/fuying/FY-SH4K-ee1c/index.m3u8\$\$\$'
        '原声版\$http://125.94.244.87/hxparse/play/fuying/FY-PAN1-qGh7/index.m3u8\$\$\$'
        '正片\$https://www.bilibili.com/bangumi/play/ep7303508\$\$\$'
        '八仙！\$https://v.qq.com/x/cover/mzc00200iivbt9k/e4102d2ebh9.html\$\$\$'
        '第1集\$http://125.94.244.87/hxparse/play/iqiyi/1/index.m3u8?ep=1\$\$\$'
        '正片\$https://hn.bfvvs.com/play/bYEQzLOb/index.m3u8';

    test('幻想蓝光不出现，其它线路一条不少', () {
      final lines = parseLines(_vod(from, url));
      final names = <String>[for (final line in lines) line.info.name];
      expect(names, isNot(contains('幻想蓝光')));
      expect(names, containsAll(<String>['SH4K', '幻想4K', 'bilibili', 'qq', '红牛']));
    });

    test('每条剩下的线路都有非空地址（不会把空 URL 交给播放器）', () {
      for (final line in parseLines(_vod(from, url))) {
        expect(line.count, greaterThan(0), reason: '${line.info.name} 没有集');
        for (final u in line.urls) {
          expect(u.trim(), isNotEmpty, reason: '${line.info.name} 有空的集地址');
        }
      }
    });
  });

  group('线路下标错位的脏数据（LINE_ALIGN）', () {
    test('from 比 url 多一段：只少一条线路，不抛异常', () {
      // 这就是采集器老 bug 留下的形状：3 个线路名、2 个地址块。
      final lines = parseLines(_vod(
        '幻想4K\$\$\$幻想蓝光\$\$\$红牛',
        '第1集\$http://125.94.244.87/hxparse/play/fuying/FY-SH4K-ee/index.m3u8\$\$\$'
            '第1集\$https://hn.bfvvs.com/play/bYEQzLOb/index.m3u8',
      ));
      // 客户端只能做「防御」：不抛异常、不把空地址摆出来。
      // 名字和地址到底该怎么配对，是服务端 repair_line_align.php 的事
      // （它按地址形态重新配对，库里现在已经是 0 条错位）。
      expect(lines.length, lessThanOrEqualTo(2));
      expect(lines, isNotEmpty);
      for (final line in lines) {
        expect(line.count, greaterThan(0));
        for (final u in line.urls) {
          expect(u.trim(), isNotEmpty);
        }
      }
    });

    test('线路名和地址错位（蓝光那格是死令牌）：死地址绝不摆给用户', () {
      // 采集器老 bug 的另一种形态：段数相等，但某一格的名字和地址对不上。
      final lines = parseLines(_vod(
        '幻想4K\$\$\$幻想蓝光',
        'http://125.94.244.87/hxparse/play/fuying/FY-PAN1-qGh7/index.m3u8\$\$\$'
            'http://125.94.244.87/hxparse/play/fuying/FY-SH4K-ee1c/index.m3u8',
      ));
      // 关键约束：走出去的每一条线路，地址都必须还活着 ——
      // 死令牌那一段（FY-PAN1）不能被当成一条可点的线路摆给用户。
      for (final line in lines) {
        for (final u in line.urls) {
          expect(isDeadAddress(u), isFalse,
              reason: '${line.info.name} 带了一条死地址 $u');
        }
      }
      expect(lines, isNotEmpty, reason: '活的那条线路不能跟着一起消失');
    });

    test('空地址段不会变成一条可点的线路', () {
      final lines = parseLines(_vod(
        '量子\$\$\$红牛',
        '第01集\$https://v.lzcdn31.com/share/abc\$\$\$',
      ));
      expect(<String>[for (final line in lines) line.info.name], <String>['量子']);
    });
  });
}

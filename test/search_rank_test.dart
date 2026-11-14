import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/services/stream_resolution.dart';

/// 搜索结果排序的回归（SEARCH_RANK，2026-11-15）。
///
/// 规则（用户定的）：**按线路的真实分辨率打分**，估不出来才按线路名推断：
///
/// ```
/// 2160p=100  1440p=90  1080p=75  720p=50  480p=20  未知=10
/// 记录分 = 最高分辨率分 × 0.7 + 线路数 × 5
/// ```
///
/// 这里钉住三件事：
///   1. 线路名推断的关键词表（肥猫那种「金牌极速 / 旋风VIP」没有分辨率
///      线索时按 1080p 估，不能按 480p 压到最底）；
///   2. 真实接口数据（罗梅莉亚战记，四条线路）算出来的分；
///   3. 第三层「播放器学到的真实分辨率」一旦命中，必须覆盖估算。
void main() {
  group('线路名 → 分辨率（第二层推断）', () {
    test('关键词表', () {
      expect(tierOfLineName('SH4K').label, '2160p');
      expect(tierOfLineName('幻想4K').label, '2160p');
      expect(tierOfLineName('蓝光').label, '1080p');
      expect(tierOfLineName('幻想蓝光').label, '1080p');
      expect(tierOfLineName('幻想爱奇艺').label, '1080p');
      expect(tierOfLineName('shvip').label, '1080p');
      expect(tierOfLineName('bilibili').label, '1080p');
      expect(tierOfLineName('高清').label, '720p');
      expect(tierOfLineName('标清').label, '480p');
      expect(tierOfLineName('量子').label, '720p');
      expect(tierOfLineName('红牛').label, '720p');
      // 肥猫那些源：「金牌极速 / 旋风VIP / 电影天堂」不含任何分辨率线索，
      // 按 1080p 估（影视壳的源绝大多数是 1080）。
      expect(tierOfLineName('金牌极速').label, '1080p');
      expect(tierOfLineName('旋风VIP').label, '1080p');
      expect(tierOfLineName('电影天堂').label, '1080p');
    });

    test('分数档位', () {
      expect(scoreOfTier(res2160), 100);
      expect(scoreOfTier(res1440), 90);
      expect(scoreOfTier(res1080), 75);
      expect(scoreOfTier(res720), 50);
      expect(scoreOfTier(res480), 20);
      expect(scoreOfTier(resUnknown), 10);
    });
  });

  group('记录打分（Σ 线路）', () {
    test('单线路：分 = 分辨率分 × 0.7 + 5', () {
      final score = scoreOfRecord(
        playFrom: '金牌极速',
        playUrl: r'第01集$https://x.com/1/index.m3u8',
      );
      expect(score.resolution.label, '1080p');
      expect(score.lineCount, 1);
      expect(score.score, 75 * 0.7 + 5);
    });

    test('多线路取最高分辨率，线路数再加分', () {
      final score = scoreOfRecord(
        playFrom: r'量子$$$4K$$$红牛',
        playUrl: r'第1集$https://a/1.m3u8$$$第1集$https://b/1.m3u8$$$第1集$https://c/1.m3u8',
      );
      expect(score.resolution.label, '2160p');
      expect(score.lineCount, 3);
      expect(score.score, 100 * 0.7 + 15);
    });

    test('空地址 / 占位地址的线路不计分', () {
      final score = scoreOfRecord(
        playFrom: r'tips$$$红牛',
        playUrl: r'about:blank$$$第01集$https://hn.bfvvs.com/play/x/index.m3u8',
      );
      expect(score.lineCount, 1);
      expect(score.resolution.label, '720p');
    });

    test('第三层命中（播放器学到的真实分辨率）覆盖估算', () {
      const from = '金牌极速';
      const url = r'第01集$https://x.com/1/index.m3u8';
      final estimated = scoreOfRecord(playFrom: from, playUrl: url);
      final learned = scoreOfRecord(
        playFrom: from,
        playUrl: url,
        learnedHeightByLine: const <String, int>{'金牌极速': 2160},
      );
      expect(estimated.resolution.label, '1080p');
      expect(learned.resolution.label, '2160p');
      expect(learned.score, greaterThan(estimated.score));
    });
  });

  group('真实接口数据（四条线路）', () {
    Map<String, dynamic> vod() {
      final body = jsonDecode(
        File('test/fixtures/detail_romelia.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      return Map<String, dynamic>.from(
        (body['list'] as List<dynamic>).first as Map<dynamic, dynamic>,
      );
    }

    test('罗梅莉亚战记：量子 / 幻想4K / 红牛 / 幻想蓝光 四条线路都在分里', () {
      final score = scoreOfRecord(
        playFrom: '${vod()['vod_play_from']}',
        playUrl: '${vod()['vod_play_url']}',
      );
      expect(score.lineCount, 4);
      // 幻想4K 的地址里带 SH4K，按 2160p 计。
      expect(score.resolution.label, '2160p');
      expect(score.score, 100 * 0.7 + 4 * 5);
    });
  });
}

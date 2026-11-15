import 'package:flutter_test/flutter_test.dart';
import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/episode_step.dart';

/// MEDIA_SESSION（2026-11-15）：系统媒体控件上「上一集 / 下一集」按钮的
/// 边界口径。
///
/// 为什么单独钉这个：通知栏 / 锁屏 / 耳机线控的切集按钮是**系统**渲染的，
/// 它只看 MediaSession 里声明的可用命令。口径算错的表现不是报错，而是：
///   · 最后一集上还挂一个按了没反应的「下一集」（用户以为卡住了）；
///   · 明明有下一集却没有按钮（用户以为这是单片）；
///   · 电影（单片）上出现「第1集/第2集」这种不存在的集数。
List<Episode> eps(List<int> nums) =>
    <Episode>[for (final n in nums) Episode(n, '', 0)];

void main() {
  group('明确集数表（detail.allEpisodes）', () {
    final list = eps(<int>[1, 2, 3]);

    test('中间集两个方向都有', () {
      expect(fxAdjacentEpisode(list, 2, -1, 3), 1);
      expect(fxAdjacentEpisode(list, 2, 1, 3), 3);
      expect(fxHasAdjacentEpisode(list, 2, -1, 3), isTrue);
      expect(fxHasAdjacentEpisode(list, 2, 1, 3), isTrue);
    });

    test('第一集没有上一集、最后一集没有下一集', () {
      expect(fxAdjacentEpisode(list, 1, -1, 3), isNull);
      expect(fxAdjacentEpisode(list, 3, 1, 3), isNull);
      expect(fxHasAdjacentEpisode(list, 1, -1, 3), isFalse);
      expect(fxHasAdjacentEpisode(list, 3, 1, 3), isFalse);
    });

    test('集号不连续时按表里的相邻项走（第10集后面是第12集）', () {
      final gaps = eps(<int>[10, 12, 20]);
      expect(fxAdjacentEpisode(gaps, 10, 1, 3), 12);
      expect(fxAdjacentEpisode(gaps, 12, 1, 3), 20);
      expect(fxAdjacentEpisode(gaps, 20, 1, 3), isNull);
      expect(fxAdjacentEpisode(gaps, 12, -1, 3), 10);
    });

    test('当前集号不在表里：两个方向都不给（宁可不切，也别跳到错的集）', () {
      expect(fxAdjacentEpisode(list, 9, 1, 3), isNull);
      expect(fxAdjacentEpisode(list, 9, -1, 3), isNull);
    });
  });

  group('只有总集数（detail.episodes）', () {
    test('按数字 ±1', () {
      expect(fxAdjacentEpisode(const <Episode>[], 5, 1, 12), 6);
      expect(fxAdjacentEpisode(const <Episode>[], 5, -1, 12), 4);
      expect(fxAdjacentEpisode(const <Episode>[], 12, 1, 12), isNull);
      expect(fxAdjacentEpisode(const <Episode>[], 1, -1, 12), isNull);
    });

    test('单片（total = 0）：两个方向都没有，通知上不出现集数按钮', () {
      expect(fxAdjacentEpisode(const <Episode>[], 1, 1, 0), isNull);
      expect(fxAdjacentEpisode(const <Episode>[], 1, -1, 0), isNull);
      expect(fxHasAdjacentEpisode(const <Episode>[], 1, 1, 0), isFalse);
    });

    test('delta = 0 不是一次切集', () {
      expect(fxAdjacentEpisode(const <Episode>[], 3, 0, 12), isNull);
    });
  });
}

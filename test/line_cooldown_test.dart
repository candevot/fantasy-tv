import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/fallback_match.dart';
import 'package:fantasy_tv/services/line_cooldown.dart';

/// 线路「临时不可用」冷却期回归（AUTO_LINE_FULL 2026-11-15）。
///
/// 用户定稿的规则：
/// ```
/// 失败 → 立刻切下一条；这条线路记 10 分钟不再试
/// 本次播放内失败线路沉到最后
/// 下次打开同一部剧，同分辨率下「最近失败过」的排后面，10 分钟后恢复
/// ```
/// 这套记账如果写错，用户会遇到「明明有线路却不播」或者「一直在坏线路上
/// 反复重试」—— 两种都比播不出来更让人崩溃。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await FxLineCooldown.clearAll();
  });

  test('失败后进入 10 分钟冷却，过期自动恢复', () async {
    final now = DateTime(2026, 11, 15, 12);
    FxLineCooldown.markFailed('100', '红牛', now: now);
    expect(FxLineCooldown.isCooling('100', '红牛', now: now), isTrue);
    expect(
      FxLineCooldown.isCooling(
        '100',
        '红牛',
        now: now.add(const Duration(minutes: 9, seconds: 59)),
      ),
      isTrue,
    );
    expect(
      FxLineCooldown.isCooling(
        '100',
        '红牛',
        now: now.add(const Duration(minutes: 10, seconds: 1)),
      ),
      isFalse,
      reason: '10 分钟后恢复原权重',
    );
  });

  test('只影响同一部剧的同名线路（别把别的剧/别的线路一起拉黑）', () async {
    final now = DateTime(2026, 11, 15, 12);
    FxLineCooldown.markFailed('100', '红牛', now: now);
    expect(FxLineCooldown.isCooling('100', '量子', now: now), isFalse);
    expect(FxLineCooldown.isCooling('200', '红牛', now: now), isFalse);
  });

  test('冷却中的线路沉到最后（本次播放内排序）', () async {
    final now = DateTime(2026, 11, 15, 12);
    FxLineCooldown.markFailed('100', '红牛', now: now);
    final lines = <LineInfo>[
      LineInfo('a', '红牛', 'hls', 0),
      LineInfo('b', '量子', 'hls', 1),
      LineInfo('c', '幻想4K', 'parse', 2),
    ];
    final ordered = FxLineCooldown.sortLines('100', lines);
    expect(ordered.last.name, '红牛');
    expect(ordered.first.name, '量子');
  });

  test('sortPenalty：最近失败过的卡片排在后面（同分辨率时）', () async {
    final now = DateTime(2026, 11, 15, 12);
    FxLineCooldown.markFailed('100', '红牛', now: now);
    final failed = VideoCard(
      id: '100',
      title: '济公传',
      cover: '',
      status: '',
      category: '',
      sourceLabel: '红牛',
    );
    final fresh = VideoCard(
      id: '100',
      title: '济公传',
      cover: '',
      status: '',
      category: '',
      sourceLabel: '量子',
    );
    expect(FxLineCooldown.sortPenalty(failed, now: now), 1);
    expect(FxLineCooldown.sortPenalty(fresh, now: now), 0);
  });

  test('播成功 / 重试都会清掉冷却记录', () async {
    final now = DateTime(2026, 11, 15, 12);
    FxLineCooldown.markFailed('100', '红牛', now: now);
    FxLineCooldown.markHealthy('100', '红牛');
    expect(FxLineCooldown.isCooling('100', '红牛', now: now), isFalse);

    FxLineCooldown.markFailed('100', '量子', now: now);
    FxLineCooldown.clearFor('100');
    expect(FxLineCooldown.isCooling('100', '量子', now: now), isFalse);
    // 纯判定层与这一层用同一个窗长。
    expect(fxLineCooldownWindow, const Duration(minutes: 10));
  });
}

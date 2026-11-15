// 源级失败账本单测（PROTOCOL_FACE 2026-11-15 · 移植阶段 1 第 8 条）。
//
// 壳的语义：源崩过一次就先不调它（`Prefers("crash")` → `homeContent` 返回空）。
// 我们做成通用版：连续失败 N 次进冷却、成功即清账、崩溃单独关更久、落盘。
//
// 这一组测试用**注入时钟**，所以「10 分钟后自动恢复」能在一秒内跑完。

import 'package:flutter_test/flutter_test.dart';
import 'package:fantasy_tv/services/source_failure.dart';

void main() {
  late DateTime now;

  SourceFailureLedger ledger({
    SourceFailureStore? store,
    Duration cooldown = const Duration(minutes: 10),
    int threshold = 2,
  }) =>
      SourceFailureLedger(
        store: store,
        cooldown: cooldown,
        cooldownThreshold: threshold,
        clock: () => now,
      );

  setUp(() {
    now = DateTime(2026, 11, 15, 21, 0, 0);
  });

  group('连续失败 → 冷却', () {
    test('第一次失败不进冷却，第二次进 10 分钟', () async {
      final l = ledger();
      await l.recordFailure('a', SourceFailureKind.timeout);
      expect(l.shouldSkip('a'), isFalse);
      expect(l.remaining('a'), Duration.zero);

      await l.recordFailure('a', SourceFailureKind.timeout);
      expect(l.shouldSkip('a'), isTrue);
      expect(l.remaining('a'), const Duration(minutes: 10));
      expect(l.entryOf('a')?.failures, 2);
      expect(l.entryOf('a')?.lastKind, SourceFailureKind.timeout);
    });

    test('冷却到期自动恢复', () async {
      final l = ledger();
      await l.recordFailure('a', SourceFailureKind.timeout);
      await l.recordFailure('a', SourceFailureKind.timeout);
      expect(l.shouldSkip('a'), isTrue);

      now = now.add(const Duration(minutes: 9, seconds: 59));
      expect(l.shouldSkip('a'), isTrue);

      now = now.add(const Duration(seconds: 2));
      expect(l.shouldSkip('a'), isFalse);
      expect(l.remaining('a'), Duration.zero);
    });

    test('成功即清账（冷却也一起清）', () async {
      final l = ledger();
      await l.recordFailure('a', SourceFailureKind.error);
      await l.recordFailure('a', SourceFailureKind.error);
      expect(l.shouldSkip('a'), isTrue);

      await l.recordSuccess('a');
      expect(l.shouldSkip('a'), isFalse);
      expect(l.entryOf('a')?.failures, 0);
      // 累计失败次数保留（诊断用：这个源一直不稳）。
      expect(l.entryOf('a')?.totalFailures, 2);
    });

    test('空结果不触发冷却（源通着，只是没这部片）', () async {
      final l = ledger(threshold: 1);
      await l.recordFailure('a', SourceFailureKind.empty);
      await l.recordFailure('a', SourceFailureKind.empty);
      await l.recordFailure('a', SourceFailureKind.empty);
      expect(l.shouldSkip('a'), isFalse);
      // 「空」不算失败：连续失败次数保持 0，累计失败也保持 0
      // （只留下「最近一次是什么结局」，用于日志 / 排序）。
      expect(l.entryOf('a')?.failures, 0);
      expect(l.entryOf('a')?.totalFailures, 0);
      expect(l.entryOf('a')?.lastKind, SourceFailureKind.empty);
    });
  });

  group('崩溃熔断（壳的 crash 语义）', () {
    test('崩溃一次就关，且比普通失败关得久（30 分钟）', () async {
      final l = ledger();
      await l.recordFailure('jar_src', SourceFailureKind.crash);
      expect(l.shouldSkip('jar_src'), isTrue);
      expect(l.remaining('jar_src'), const Duration(minutes: 30));

      now = now.add(const Duration(minutes: 29));
      expect(l.shouldSkip('jar_src'), isTrue);
      now = now.add(const Duration(minutes: 2));
      expect(l.shouldSkip('jar_src'), isFalse);
    });

    test('冷却阈值可配（threshold=1 时一次超时就关）', () async {
      final l = ledger(threshold: 1, cooldown: const Duration(minutes: 2));
      await l.recordFailure('a', SourceFailureKind.timeout);
      expect(l.shouldSkip('a'), isTrue);
      expect(l.remaining('a'), const Duration(minutes: 2));
    });
  });

  group('落盘', () {
    test('写盘后换一个账本能读回冷却状态', () async {
      final store = MemorySourceFailureStore();
      final first = ledger(store: store);
      await first.recordFailure('a', SourceFailureKind.timeout);
      await first.recordFailure('a', SourceFailureKind.timeout);

      final second = ledger(store: store);
      await second.ensureLoaded();
      expect(second.shouldSkip('a'), isTrue);
      expect(second.entryOf('a')?.failures, 2);
      expect(second.entryOf('a')?.lastKind, SourceFailureKind.timeout);
    });

    test('坏账本按空表处理（不抛异常）', () async {
      final store = MemorySourceFailureStore('{不是 JSON');
      final l = ledger(store: store);
      await l.ensureLoaded();
      expect(l.length, 0);
      expect(l.shouldSkip('anything'), isFalse);
    });

    test('清空会同时清掉落盘', () async {
      final store = MemorySourceFailureStore();
      final l = ledger(store: store);
      await l.recordFailure('a', SourceFailureKind.crash);
      await l.clear();
      expect(l.length, 0);
      final fresh = ledger(store: store);
      await fresh.ensureLoaded();
      expect(fresh.shouldSkip('a'), isFalse);
    });
  });

  group('容量与诊断', () {
    test('超过上限丢最久没失败的', () async {
      final l = SourceFailureLedger(
        cooldown: const Duration(minutes: 1),
        cooldownThreshold: 99,
        maxEntries: 3,
        clock: () => now,
      );
      for (var i = 0; i < 5; i++) {
        now = now.add(const Duration(seconds: 1));
        await l.recordFailure('k$i', SourceFailureKind.empty);
      }
      expect(l.length, 3);
      expect(l.entryOf('k0'), isNull);
      expect(l.entryOf('k1'), isNull);
      expect(l.entryOf('k4'), isNotNull);
    });

    test('summary 报出记录数与冷却中的源', () async {
      final l = ledger();
      await l.recordFailure('a', SourceFailureKind.crash);
      await l.recordFailure('b', SourceFailureKind.empty);
      final text = l.summary();
      expect(text, contains('记 2 源'));
      expect(text, contains('冷却 1'));
      expect(l.coolingKeys(), <String>['a']);
    });

    test('空表摘要不出现「冷却」', () {
      expect(ledger().summary(), 'source_fail[空]');
    });
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/widgets/together_sync.dart';
import 'package:fantasy_tv/widgets/together_ui.dart';

/* ========================================================================== */
/*  一起看 · 同步验收口径回归（2026-11-15）                                    */
/*                                                                            */
/*  用户口径逐条钉住：                                                          */
/*   1. 偏差 ±2 秒内不硬 seek，用 ±0.05x 微调倍速追；超过 2 秒才硬跳；           */
/*   2. 心跳 1 秒一次；                                                        */
/*   3. 本地操作有 700ms 乐观主导权，到点必须能退回跟随；                        */
/*   4. 操作流水：别人「小明 …」、自己「你 …」，同动作 1 秒内合并。              */
/* ========================================================================== */

void main() {
  group('纠偏决策：±2 秒内不硬 seek', () {
    TogetherSyncDecision decide(double drift, {bool playing = true}) =>
        decideTogetherDrift(
          expected: 100 + drift,
          current: 100,
          playing: playing,
          baseRate: 1.0,
        );

    test('死区内（< 0.4s）不动', () {
      for (final drift in <double>[0, 0.1, -0.1, 0.39, -0.39]) {
        expect(decide(drift).move, TogetherSyncMove.none, reason: '$drift');
      }
    });

    test('0.4–2.0 秒：微调 ±0.05 倍速，绝不 seek', () {
      for (final drift in <double>[0.5, 1.0, 1.5, 1.99, -0.5, -1.0, -1.99]) {
        final d = decide(drift);
        expect(d.move, TogetherSyncMove.rate, reason: '$drift');
        expect(d.rate, closeTo(drift > 0 ? 1.05 : 0.95, 1e-9), reason: '$drift');
      }
    });

    test('超过 2.0 秒才硬 seek，目标是期望位置', () {
      final forward = decide(2.01);
      expect(forward.move, TogetherSyncMove.seek);
      expect(forward.target, closeTo(102.01, 1e-9));
      final backward = decide(-2.01);
      expect(backward.move, TogetherSyncMove.seek);
      expect(backward.target, closeTo(97.99, 1e-9));
    });

    test('暂停态不微调倍速：只在超阈值时跳一次', () {
      expect(decide(1.0, playing: false).move, TogetherSyncMove.none);
      expect(decide(2.5, playing: false).move, TogetherSyncMove.seek);
    });

    test('缓冲中 6 秒内一律不动（跳了只会更卡）', () {
      expect(
        decideTogetherDrift(
          expected: 106,
          current: 100,
          playing: true,
          baseRate: 1,
          buffering: true,
        ).move,
        TogetherSyncMove.none,
      );
    });
  });

  group('权威变化分类', () {
    test('房主正常推进不当成 seek', () {
      final verdict = classifyTogetherAuthority(
        prevPosition: 100,
        prevServerTime: 1000000,
        prevPlaying: true,
        prevRate: 1,
        position: 101,
        serverTime: 1001000,
        playing: true,
      );
      expect(verdict.change, TogetherAuthorityChange.normal);
    });

    test('房主拖到 10:00 判 seek', () {
      expect(
        isTogetherSeekJump(
          prevPosition: 100,
          prevServerTime: 1000000,
          prevPlaying: true,
          prevRate: 1,
          position: 600,
          serverTime: 1001000,
        ),
        isTrue,
      );
    });

    test('房主卡缓冲（位置停住、时钟照走）判 stall 而不是 seek', () {
      final verdict = classifyTogetherAuthority(
        prevPosition: 100,
        prevServerTime: 1000000,
        prevPlaying: true,
        prevRate: 1,
        position: 100,
        serverTime: 1005000,
        playing: true,
      );
      expect(verdict.change, TogetherAuthorityChange.stall);
    });
  });

  group('同步节奏常量', () {
    test('心跳 1 秒一次', () {
      expect(togetherHeartbeatInterval, const Duration(seconds: 1));
    });

    test('乐观主导权 700ms，且短于一次心跳间隔的容错窗口', () {
      expect(togetherOptimisticLeaderMs, 700);
      expect(
        togetherOptimisticLeaderMs,
        lessThan(togetherHeartbeatInterval.inMilliseconds * 2),
      );
    });

    test('硬 seek 后 2 秒冷却', () {
      expect(togetherSeekCooldownMs, 2000);
    });
  });

  group('操作流水文案', () {
    test('别人：名字 + 做了什么', () {
      expect(
        togetherOperationText(name: '小明', label: '换了线路 → 幻想4K', mine: false),
        '小明 换了线路 → 幻想4K',
      );
    });

    test('自己：换成「你」，所有人看到同一份流水', () {
      expect(
        togetherOperationText(name: '小明', label: '拖到 12:34', mine: true),
        '你 拖到 12:34',
      );
    });

    test('没有名字 / 没有标签时也不出现空文案', () {
      expect(
        togetherOperationText(name: '  ', label: '', mine: false),
        '有人 操作了播放',
      );
    });

    test('同一动作 1 秒内合并，超过 1 秒或换动作不合并', () {
      final t0 = DateTime(2026, 11, 15, 12, 0, 0);
      expect(
        togetherShouldMergeOperation(
          lastAction: 'seek',
          lastAt: t0,
          action: 'seek',
          now: t0.add(const Duration(milliseconds: 800)),
        ),
        isTrue,
      );
      expect(
        togetherShouldMergeOperation(
          lastAction: 'seek',
          lastAt: t0,
          action: 'seek',
          now: t0.add(const Duration(milliseconds: 1200)),
        ),
        isFalse,
      );
      expect(
        togetherShouldMergeOperation(
          lastAction: 'pause',
          lastAt: t0,
          action: 'seek',
          now: t0.add(const Duration(milliseconds: 100)),
        ),
        isFalse,
      );
    });
  });
}

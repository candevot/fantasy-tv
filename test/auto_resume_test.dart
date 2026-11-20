import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fantasy_tv/services/auto_resume.dart';
import 'package:fantasy_tv/services/line_cooldown.dart';

/// 两个现场问题的判定层回归（AUTO_RESUME / SH4K_RETRY 2026-11-20）。
///
/// ① **自动切线路之后画面停着不动，要手动点播放。**
///    根因是「要不要继续播」用了 `isPlaying` 当用户意图：
///    `_bootstrapSource` 一进来就 `_controller?.pause()`（先停旧实例再开新地址），
///    ExoPlayer 缓冲中 `isPlaying` 也是 false —— 两个都会被读成「用户暂停」，
///    于是新线路 open 完立刻又被 `pause()` 回去（画面停帧）。
///
/// ② **SH4K 有时判「线路用不了」。**
///    令牌解析线路首帧天然慢（本站 302 + 上游清单 + AES key），8 秒无进展
///    窗口太紧；一次抖动就记 10 分钟不可用，下次进来还是「用不了」。
void main() {
  group('① 换线后要不要继续播', () {
    test('用户没按过暂停 → 必须自动起播', () {
      expect(fxShouldPlayAfterSwitch(userPaused: false), isTrue);
    });

    test('用户自己按过暂停 → 保持暂停（自动换线不许把用户的暂停顶掉）', () {
      expect(fxShouldPlayAfterSwitch(userPaused: true), isFalse);
    });

    test('「旧实例被我们 pause 了 / 缓冲中 isPlaying=false」都不算用户暂停', () {
      // 这两种情况在调用点看起来一模一样的 `isPlaying == false`；判定层只收
      // 用户意图，所以结论都是「继续播」。
      expect(
        fxShouldPlayAfterSwitch(userPaused: false),
        isTrue,
        reason: '换线前先停旧实例不是用户暂停',
      );
    });
  });

  group('换线接续位置（最多回退 3 秒）', () {
    test('候选位置就是切换前的位置 → 原样接上', () {
      expect(
        fxResumeSecondsAfterSwitch(snapshotSeconds: 120, candidateSeconds: 120),
        120,
      );
    });

    test('候选位置落后超过 3 秒 → 只退到 3 秒，不多丢', () {
      expect(
        fxResumeSecondsAfterSwitch(
          snapshotSeconds: 120,
          candidateSeconds: 10,
        ),
        117,
        reason: '120 - 3 = 117：最多回退 3 秒',
      );
    });

    test('候选位置落后 3 秒以内 → 用候选（对齐分片不影响观感）', () {
      expect(
        fxResumeSecondsAfterSwitch(
          snapshotSeconds: 120,
          candidateSeconds: 118.5,
        ),
        118.5,
      );
    });

    test('候选位置比切换前还靠前 → 不许快进', () {
      expect(
        fxResumeSecondsAfterSwitch(
          snapshotSeconds: 120,
          candidateSeconds: 300,
        ),
        120,
      );
    });

    test('快退到片头附近不会变成负数', () {
      expect(
        fxResumeSecondsAfterSwitch(snapshotSeconds: 1.5, candidateSeconds: 0.2),
        0.2,
      );
      expect(
        fxResumeSecondsAfterSwitch(snapshotSeconds: 0, candidateSeconds: 0.2),
        0.2,
      );
    });

    test('两边都没有可信位置 → 从头播', () {
      expect(
        fxResumeSecondsAfterSwitch(snapshotSeconds: 0, candidateSeconds: 0),
        0,
      );
      expect(
        fxResumeSecondsAfterSwitch(
          snapshotSeconds: double.nan,
          candidateSeconds: double.nan,
        ),
        0,
      );
    });

    test('回退上限就是 3 秒', () {
      expect(fxAutoSwitchMaxRewind, const Duration(seconds: 3));
    });
  });

  group('② 令牌解析线路（SH4K）', () {
    test('本站 hxparse 包装地址 / SH4K 令牌 / 线路名都能认出来', () {
      expect(
        fxIsTokenParseLine(
          url: 'http://125.94.244.87/hxparse/xo?u=SH4K-4b79ba60e48e1f82',
        ),
        isTrue,
      );
      expect(
        fxIsTokenParseLine(
          url: 'http://125.94.244.87/hxparse/parse/fuying?u=SH4K-4b79ba60',
        ),
        isTrue,
      );
      expect(
        fxIsTokenParseLine(url: 'http://125.94.244.87/hxparse/play/iqiyi/1'),
        isTrue,
      );
      expect(fxIsTokenParseLine(lineName: 'SH4K'), isTrue);
      expect(fxIsTokenParseLine(lineName: '幻想4K'), isTrue);
      expect(fxIsTokenParseLine(lineName: '幻想蓝光'), isFalse);
    });

    test('直链 / 咕噜这类采集线路不算令牌线路', () {
      expect(
        fxIsTokenParseLine(
          url: 'https://cdn.example.com/hls/abc/index.m3u8',
          lineName: '红牛',
        ),
        isFalse,
      );
      expect(fxIsTokenParseLine(url: ''), isFalse);
    });

    test('令牌线路的起播窗口放宽到 20 秒，直链仍是 8 秒', () {
      expect(fxTokenStartupNoProgressWindow, const Duration(seconds: 20));
      expect(
        fxStartupNoProgressWindowFor(
          url: 'http://125.94.244.87/hxparse/xo?u=SH4K-4b79ba60',
        ),
        const Duration(seconds: 20),
      );
      expect(
        fxStartupNoProgressWindowFor(
          url: 'https://cdn.example.com/hls/abc/index.m3u8',
        ),
        const Duration(seconds: 8),
      );
    });

    test('判死前补一次快速重试，间隔 1.5 秒', () {
      expect(fxFastRetryDelay, const Duration(milliseconds: 1500));
      expect(
        fxShouldFastRetry(reason: 'no_first_frame', tokenLine: true),
        isTrue,
        reason: 'SH4K 慢一次就该再要一次地址',
      );
      expect(
        fxShouldFastRetry(reason: 'http_302', tokenLine: true),
        isTrue,
      );
      expect(
        fxShouldFastRetry(reason: 'http_503', tokenLine: false),
        isTrue,
        reason: '一次 5xx 是上游抖动，不是线路坏',
      );
      expect(
        fxShouldFastRetry(reason: 'stuck_no_progress'),
        isTrue,
      );
      // 真坏不补：再要一次也是一样的结果，只会白等。
      for (final hard in <String>[
        'http_403',
        'http_404',
        'parse_error',
        'manifest_invalid',
        'no_segments',
        'dns_error',
        'dead_line',
      ]) {
        expect(
          fxShouldFastRetry(reason: hard, tokenLine: true),
          isFalse,
          reason: '$hard 是真坏，不该补重试',
        );
      }
      // 只补一次。
      expect(
        fxShouldFastRetry(reason: 'no_first_frame', retries: 1, tokenLine: true),
        isFalse,
      );
      expect(fxShouldFastRetry(reason: ''), isFalse);
    });

    test('冷却期按原因分档：抖动 2 分钟，真坏 10 分钟', () {
      expect(fxTransientCooldownWindow, const Duration(minutes: 2));
      expect(
        fxCooldownWindowFor('no_first_frame'),
        const Duration(minutes: 2),
      );
      expect(fxCooldownWindowFor('stuck_no_progress'),
          const Duration(minutes: 2));
      expect(fxCooldownWindowFor('http_502'), const Duration(minutes: 2));
      expect(fxCooldownWindowFor('http_404'), const Duration(minutes: 10));
      expect(fxCooldownWindowFor('parse_error'), const Duration(minutes: 10));
      expect(fxCooldownWindowFor(''), const Duration(minutes: 10));
    });
  });

  group('冷却记账按原因落盘', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await FxLineCooldown.clearAll();
    });

    test('抖动失败 2 分钟就恢复（下次进来不会还说线路用不了）', () async {
      final now = DateTime(2026, 11, 20, 21);
      FxLineCooldown.markFailed('784', 'SH4K', now: now, reason: 'no_first_frame');
      expect(FxLineCooldown.isCooling('784', 'SH4K', now: now), isTrue);
      expect(
        FxLineCooldown.isCooling(
          '784',
          'SH4K',
          now: now.add(const Duration(minutes: 1, seconds: 59)),
        ),
        isTrue,
      );
      expect(
        FxLineCooldown.isCooling(
          '784',
          'SH4K',
          now: now.add(const Duration(minutes: 2, seconds: 1)),
        ),
        isFalse,
        reason: '抖动只冷却 2 分钟',
      );
    });

    test('真坏（4xx / 解析失败）仍然冷却 10 分钟', () async {
      final now = DateTime(2026, 11, 20, 21);
      FxLineCooldown.markFailed('784', 'SH4K', now: now, reason: 'http_404');
      expect(
        FxLineCooldown.isCooling(
          '784',
          'SH4K',
          now: now.add(const Duration(minutes: 9)),
        ),
        isTrue,
      );
      expect(
        FxLineCooldown.isCooling(
          '784',
          'SH4K',
          now: now.add(const Duration(minutes: 10, seconds: 1)),
        ),
        isFalse,
      );
    });

    test('没写原因（老调用点）按真坏 10 分钟算', () async {
      final now = DateTime(2026, 11, 20, 21);
      FxLineCooldown.markFailed('784', '红牛', now: now);
      expect(
        FxLineCooldown.isCooling(
          '784',
          '红牛',
          now: now.add(const Duration(minutes: 5)),
        ),
        isTrue,
      );
    });
  });
}

import 'package:flutter_test/flutter_test.dart';

import '../lib/services/app_settings.dart';
import '../lib/services/playback_params.dart';

/// 参数面（PARAMS_ALIGN 2026-11-15 · 阶段 2）的取值回归。
///
/// 这些数字是**逐位对齐 FongMi 5.16 内核参数**的契约值，不是随手定的：
///   · 缓冲档位 = 1..10，一档 50 秒（壳 `Setting.getBuffer()` +
///     `ExoUtil.buildLoadControl()` 里 `DEFAULT_MIN/MAX_BUFFER_MS(50000) × 档位`）；
///   · 默认档位 1 —— 必须与改造前写死的 `setBufferDurationsMs(50_000, 50_000,
///     1_000, 2_000)` 完全等价，否则「零风险纯参数」这条前提就不成立了。
///
/// 原生侧的对应断言在 `tools/check_kotlin_compile.sh` 管不到的运行时，
/// 这里先在 Dart 侧把「送出去的值」钉死：只要这里绿，说明推给内核的
/// 档位 → 毫秒换算与壳一致。
void main() {
  test('缓冲档位区间与默认值 = 壳的 1..10 / 默认 1', () {
    expect(AppSettings.minBufferLevel, 1);
    expect(AppSettings.maxBufferLevel, 10);
    expect(AppSettings.defaultBufferLevel, 1);
  });

  test('一档 = 50 秒（壳 DEFAULT_MIN_BUFFER_MS = 50_000）', () {
    expect(AppSettings.bufferStepMs, 50000);
    // 默认档位必须与改造前写死的 50s/50s 完全一致。
    expect(AppSettings.defaultBufferLevel * AppSettings.bufferStepMs, 50000);
    // 最高档 = 500 秒，与壳 `50000 × 10` 一致。
    expect(AppSettings.maxBufferLevel * AppSettings.bufferStepMs, 500000);
  });

  test('档位文案与内核换算同源', () {
    expect(AppSettings.bufferLevelHint(1), contains('50'));
    expect(AppSettings.bufferLevelHint(3), contains('150'));
    expect(AppSettings.bufferLevelHint(10), contains('500'));
  });

  test('画像签名字段齐全：三处任一变化都要重推', () {
    const base = PlaybackParams();
    expect(base.bufferLevel, AppSettings.defaultBufferLevel);
    // 默认值对齐壳的 pref 缺省值（`prefer_aac` / `tunnel` 未设置都是 false）。
    expect(base.preferAac, isFalse);
    expect(base.tunneling, isFalse);

    final changed = PlaybackParams(
      bufferLevel: 4,
      preferAac: true,
      tunneling: true,
    );
    expect(changed.signature, isNot(base.signature));
    expect(
      changed.signature,
      allOf(contains('buf=4'), contains('aac=true'), contains('tun=true')),
    );
  });

  test('相同设置签名相同：去重有效（不重复打通道）', () {
    const a = PlaybackParams(bufferLevel: 2, preferAac: false, tunneling: false);
    const b = PlaybackParams(bufferLevel: 2, preferAac: false, tunneling: false);
    expect(a.signature, b.signature);

    // 只改一个字段也必须变。
    expect(
      const PlaybackParams(bufferLevel: 3).signature,
      isNot(a.signature),
    );
    expect(
      const PlaybackParams(bufferLevel: 2, preferAac: true).signature,
      isNot(a.signature),
    );
    expect(
      const PlaybackParams(bufferLevel: 2, tunneling: true).signature,
      isNot(a.signature),
    );
  });

  test('摘要里带上秒数：真机对照日志用', () {
    const p = PlaybackParams(bufferLevel: 2);
    expect(p.summary(), contains('100s'));
    expect(p.summary(), contains('buffer=2'));
  });
}

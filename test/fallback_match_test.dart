import 'package:flutter_test/flutter_test.dart';

import '../lib/services/fallback_match.dart' as match;

/// 三段降级（FX_FALLBACK 2026-11-15）的匹配规则回归。
///
/// 判定本体是纯函数（[match] 里没有 import、不联网、不碰 UI），这里只是把它
/// 套进 flutter_test 的门禁里；规则逐条断言在 `tools/test_fallback_match.dart`。
/// 之所以要单独的 tester：跨源换源跳错片子（跳到「解说 / 预告」或另一年版本）
/// 用户根本没法自己发现，只能靠这里钉住。
void main() {
  test('片名归一化与同名判定：只认全等，不做模糊', () {
    expect(match.fxNormTitle(' The 100 '), 'the100');
    expect(match.fxSameTitle('The 100', 'the100'), isTrue);
    expect(match.fxSameTitle('济公传', '济公传第二季'), isFalse);
    expect(match.fxSameTitle('济公传', '济公传 高清'), isFalse);
  });

  test('解说 / 预告 / 花絮 不是正片', () {
    expect(match.fxIsExtraClip('济公传第3集解说'), isTrue);
    expect(match.fxIsExtraClip('济公传 预告'), isTrue);
    expect(match.fxIsExtraClip('济公传'), isFalse);
  });

  test('年份差 ≤1 才算同一部，年份未知时可接受', () {
    expect(match.fxYearCompatible(2016, 2015), isTrue);
    expect(match.fxYearCompatible(2016, 2014), isFalse);
    expect(match.fxYearCompatible(0, 2016), isTrue);
  });

  test('集号对齐：对方集数不够就不换，不回到第 1 集', () {
    expect(match.fxFallbackEp(wantEp: 5, availableEps: 12), 5);
    expect(match.fxFallbackEp(wantEp: 12, availableEps: 8), 0);
  });

  test('进度接续：原位置带过去，超过对方时长则夹到末尾', () {
    expect(match.fxFallbackPosition(want: 754, targetDuration: 1800), 754);
    expect(match.fxFallbackPosition(want: 2400, targetDuration: 1800), 1800);
  });

  test('候选线路挑选：健康直链 > 需解析 > 集数未知', () {
    final lines = <match.FxLineProbe>[
      const match.FxLineProbe(id: 'a', type: 'hls', degraded: true, epCount: 40),
      const match.FxLineProbe(id: 'b', type: 'parse', epCount: 40),
      const match.FxLineProbe(id: 'c', type: 'hls', epCount: 40),
    ];
    expect(match.fxPickLineIndex(lines, 5), 2);
    expect(
      match.fxPickLineIndex(
        <match.FxLineProbe>[const match.FxLineProbe(id: 'a', epCount: 3)],
        5,
      ),
      -1,
    );
  });

  test('降级日志与用户提示文案固定', () {
    expect(
      match.fxFallbackLog(level: 2, from: '幻想', to: '咕噜'),
      'fallback level=2 from=幻想 to=咕噜 reason=all_lines_failed',
    );
    expect(match.fxFallbackSearchingText, '当前源播放失败，正在尝试其他源…');
    expect(match.fxFallbackAllFailedText, '所有线路都尝试过了，暂时无法播放');
    expect(match.fxFallbackSwitchedText('咕噜'), '已切换到咕噜');
  });
}

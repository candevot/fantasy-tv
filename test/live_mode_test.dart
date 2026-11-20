import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/widgets/fs_panels.dart';
import 'package:fantasy_tv/widgets/player_theme.dart';

/// LIVE_EDGE（2026-11-20）现场回归：
///
/// 用户实测截图里播 CCTV-4K：顶栏有刷新按钮、左下角有暂停按钮、画面明显
/// 落后直播，原话是「直播要什么暂停按钮，还有刷新按钮，根本就不对，刷新
/// 之后还是当前的，根本不是跟上跟不上进度，直播不同步」。
///
/// 用户后来把口径收窄成：**不要任何自动跳转**，只有点刷新才追到直播末端。
/// 所以这里钉三件事：
///   ① 直播控件里没有播放 / 暂停按钮，也没有可拖动的进度条；
///   ② 刷新 = 重新 prepare + seek 到窗口末端前 3 秒（不是重播缓冲）；
///   ③ 点播（live == false）一个像素都不许变：暂停 + 进度条照旧。
void main() {
  Widget host(Widget child) =>
      MaterialApp(home: Scaffold(body: Center(child: child)));

  FsBottomBar bar({required bool live, required VoidCallback onTogglePlay}) {
    return FsBottomBar(
      position: const Duration(seconds: 30),
      duration: const Duration(seconds: 100),
      buffered: const Duration(seconds: 40),
      playing: true,
      rate: 1,
      qualityLabel: '',
      live: live,
      onTogglePlay: onTogglePlay,
      onSeek: (_) {},
      onNext: () {},
      onEpisodes: () {},
      onMore: () {},
      onExit: () {},
    );
  }

  testWidgets('① 直播底栏没有暂停 / 播放按钮，也没有进度条', (tester) async {
    var toggled = 0;
    await tester.pumpWidget(
      host(bar(live: true, onTogglePlay: () => toggled++)),
    );

    expect(find.byIcon(Icons.pause_rounded), findsNothing,
        reason: '直播不许有暂停按钮');
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing,
        reason: '直播不许有播放按钮（同一个位置）');
    expect(find.byType(FxSeekRow), findsNothing,
        reason: '直播不许有可拖动的进度条');
    // LIVE 小红标还在：用户要知道这是直播。
    expect(find.text('LIVE'), findsOneWidget);
    // 退出全屏仍然可点（直播的唯一出口）。
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);
  });

  testWidgets('③ 点播底栏不受影响：暂停按钮 + 进度条都在', (tester) async {
    var toggled = 0;
    await tester.pumpWidget(
      host(bar(live: false, onTogglePlay: () => toggled++)),
    );

    expect(find.byIcon(Icons.pause_rounded), findsOneWidget,
        reason: '点播必须保留暂停按钮');
    expect(find.byType(FxSeekRow), findsOneWidget,
        reason: '点播必须保留可拖动进度条');
    await tester.tap(find.byIcon(Icons.pause_rounded));
    expect(toggled, 1);
  });

  /* ---------------------- 源码结构断言（改回去就红） ---------------------- */

  test('直播页源码：没有暂停 / 播放按钮，刷新走「重开 + 追到末端」', () {
    final page = _read('lib/pages/live_detail_page.dart');
    expect(page.contains('Icons.pause_rounded'), isFalse,
        reason: '直播页不许出现暂停图标');
    expect(page.contains('Icons.play_arrow_rounded'), isFalse,
        reason: '直播页不许出现播放图标');
    // 刷新按钮必须调「刷新 → 重开 + 落地到边缘」，不是只重开。
    expect(page.contains('_refreshLive'), isTrue);
    expect(page.contains('seekToLiveEdge'), isTrue,
        reason: '刷新必须真的 seek 到直播末端');
    expect(page.contains('fxLiveRefreshRewind'), isTrue);
    // 双击 / 点画面不许暂停：直播页不该再有「点一下就 pause」的函数。
    expect(page.contains('_togglePlay'), isFalse,
        reason: '直播页不许有切换播放 / 暂停的实现');
    // 不许有任何定时位置检查（用户口径：不要自动追平）。
    expect(page.contains('Timer.periodic'), isFalse,
        reason: '直播页不许有定时位置检查');
  });

  test('全屏直播：暂停入口是空操作，不 seek 也不 pause', () {
    final fs = _read('lib/pages/fullscreen_page.dart');
    final toggle = _block(fs, 'void _togglePlay() {');
    expect(toggle.contains('if (_isLive)'), isTrue,
        reason: '直播下 _togglePlay 必须先短路');
    expect(toggle.contains('playOrPause'), isTrue,
        reason: '点播仍然走 playOrPause（这一段不许被削掉）');
    // 短路分支里不许出现 pause / seekTo。
    final liveBranch = toggle.substring(
      toggle.indexOf('if (_isLive)'),
      toggle.indexOf('// 投屏中用户点手机播放'),
    );
    expect(liveBranch.contains('pause()'), isFalse,
        reason: '直播短路分支里不许真的调 pause');
    expect(liveBranch.contains('playOrPause'), isFalse,
        reason: '直播短路分支里不许切播放状态');
    expect(liveBranch.contains('seekTo'), isFalse,
        reason: '直播短路分支里不许 seek（用户口径：不要任何自动跳转）');
    // 定时关闭也不许把直播按停。
    final sleep = _block(fs, 'void _fireSleep() {');
    expect(sleep.contains('if (!_isLive)'), isTrue,
        reason: '定时关闭在直播下必须跳过 pause');
  });

  test('内核：seekToLiveEdge 只在主动重开时被调用（没有定时器调用它）', () {
    final player = _read('lib/services/fx_player.dart');
    expect(player.contains('Future<bool> seekToLiveEdge('), isTrue);
    expect(player.contains('fxLiveProbeLog'), isTrue);
    final live = _read('lib/pages/live_detail_page.dart');
    // 页面上只有「重开后落地」这一处调用。
    final calls = 'player.seekToLiveEdge('.allMatches(live).length;
    expect(calls, 1,
        reason: '直播页只允许 _landOnLiveEdge 这一处追边，防止加回自动 seek');
  });
}

String _read(String relative) => File(relative).readAsStringSync();

/// 取某个函数体（从签名开始到第一个「同级 `  }`」结束），用于结构断言。
String _block(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: '找不到 $signature');
  final end = source.indexOf('\n  }\n', start);
  expect(end, greaterThan(start), reason: '$signature 的函数体没闭合');
  return source.substring(start, end);
}

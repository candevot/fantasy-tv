import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/services/live_edge.dart';

/// FULLSCREEN_SWITCH（2026-11-21）回归：直播竖屏 ↔ 全屏来回切不许卡住。
///
/// 用户实测：「直播页面（CCTV 某台）点全屏 → 卡住；从全屏退回竖屏 → 卡住；
/// 表现为黑屏 / 转圈 / 画面不动，需要退出重进才恢复」。
///
/// 根因不在「重复 prepare」，在**画面层挂了两块**：原生
/// `ExoPlayerPlugin.createView()` 只维护一块 `videoView`，每建一块 ExoView
/// 就 `player.setVideoTextureView(新的那块)`；`ExoView.dispose()` 只有在
/// `videoView === tv` 时才 `clearVideoSurface()`。于是：
///   · 进全屏：输出被全屏那块抢走，竖屏那块成了没有输出的死视图；
///   · 退全屏：全屏那块 dispose 时把整条视频输出清掉，而竖屏那块从头到尾
///     没重建过，不会再去 `setVideoTextureView` → 播放器没有输出面，
///     声音还在走、位置还在动，画面就是黑的。
///
/// 点播页早就按这条规则做了（player_page.dart 的 `_fullscreenActive`），
/// 直播页漏了。这里钉住四件事：
///   ① 任何时刻只有**一块**画面层在树上；
///   ② 来回切 10 次只复用同一个播放器实例（不新建、不重新 prepare）；
///   ③ 万一新宿主没接上画面，4 秒内自检并落回直播边缘 + 播放；
///   ④ 点播全屏路径一个像素都不许变。
void main() {
  group('① 画面层交接：任何时刻只有一块', () {
    test('竖屏 / 全屏的挂载真值表', () {
      // 竖屏页：有播放器且已就绪、且全屏不在顶层 → 挂。
      expect(
        fxLiveSurfaceVisible(
          hasPlayer: true,
          ready: true,
          fullscreenActive: false,
        ),
        isTrue,
      );
      // 全屏在顶层 → 必须摘掉（否则原生输出面被两块抢）。
      expect(
        fxLiveSurfaceVisible(
          hasPlayer: true,
          ready: true,
          fullscreenActive: true,
        ),
        isFalse,
        reason: '全屏期间竖屏必须摘掉自己的 ExoView',
      );
      // 没播放器 / 还没就绪：不挂（纹理挂早了会闪红屏 / 透明残帧）。
      expect(
        fxLiveSurfaceVisible(
          hasPlayer: false,
          ready: true,
          fullscreenActive: false,
        ),
        isFalse,
      );
      expect(
        fxLiveSurfaceVisible(
          hasPlayer: true,
          ready: false,
          fullscreenActive: false,
        ),
        isFalse,
      );
    });

    test('来回切 10 次：播放器只有一个实例，画面层挂 / 摘严格成对', () {
      // 页面里播放器只在 _open() 里创建一次（进页面时），切换全屏不许再建。
      var playerEpoch = 1;
      var fullscreen = false;
      var portraitMounted = false;
      var fullscreenMounted = false;
      var mounts = 0;
      var unmounts = 0;
      final alivePerStep = <int>[];

      void sync(int step) {
        final portrait = fxLiveSurfaceVisible(
          hasPlayer: true,
          ready: true,
          fullscreenActive: fullscreen,
        );
        if (portrait != portraitMounted) {
          portraitMounted = portrait;
          portrait ? mounts++ : unmounts++;
        }
        if (fullscreen != fullscreenMounted) {
          fullscreenMounted = fullscreen;
          fullscreen ? mounts++ : unmounts++;
        }
        alivePerStep.add(
          (portraitMounted ? 1 : 0) + (fullscreenMounted ? 1 : 0),
        );
        expect(
          alivePerStep.last,
          1,
          reason: '第 $step 步同时挂着 ${alivePerStep.last} 块画面层',
        );
      }

      sync(0); // 竖屏在播
      for (var i = 1; i <= 10; i++) {
        // 进全屏：竖屏摘 → 全屏挂（顺序无所谓，原生按 videoView 判归属）。
        fullscreen = true;
        sync(i * 2 - 1);
        // 退全屏：全屏摘 → 竖屏挂。
        fullscreen = false;
        sync(i * 2);
      }

      expect(playerEpoch, 1, reason: '切换全屏不许新建播放器实例');
      expect(alivePerStep.every((n) => n == 1), isTrue);
      // 每一步挂 / 摘都成对：最后只有竖屏那一块还在 → 挂比摘多 1 次。
      expect(mounts, unmounts + 1, reason: '画面层挂 / 摘必须成对，不许泄漏');
      expect(mounts, 21, reason: '1 次首挂 + 10 轮 × 2 次换手');
      expect(portraitMounted, isTrue, reason: '退回竖屏后画面层必须挂回去');
      expect(fullscreenMounted, isFalse);
    });
  });

  group('② 接不上就落回直播边缘并播放', () {
    test('位置不动 = 断了；缓冲中不算断（别把换分片当卡死）', () {
      expect(
        fxLivePictureDead(
          before: const Duration(seconds: 20),
          after: const Duration(seconds: 20, milliseconds: 200),
          isBuffering: false,
        ),
        isTrue,
        reason: '4 秒里位置只走了 200ms → 输出面没接回来',
      );
      expect(
        fxLivePictureDead(
          before: const Duration(seconds: 20),
          after: const Duration(seconds: 24),
          isBuffering: false,
        ),
        isFalse,
        reason: '位置在走 = 画面活着，一次都不许 seek',
      );
      expect(
        fxLivePictureDead(
          before: const Duration(seconds: 20),
          after: const Duration(seconds: 20),
          isBuffering: true,
        ),
        isFalse,
        reason: '缓冲中位置本来就不动，这时候 seek 只会又回到黑屏',
      );
    });

    test('自检只查一次（不是定时追平）', () {
      // 用户口径：播放中落后就让它落后，只有刷新 / 重开才追边。
      expect(fxLiveSurfaceCheckDelay, const Duration(seconds: 4));
      final source = _read('lib/services/live_edge.dart');
      for (final banned in <String>['Timer', '自动追平', 'Timer.periodic']) {
        expect(source.contains(banned), isFalse, reason: '直播不许出现「$banned」');
      }
    });

    test('探针格式：一行带 fs / surface / playing / pos / end / lag', () {
      final line = fxLiveSwitchLog(
        phase: 'enter',
        fullscreen: true,
        surfaceMounted: false,
        playing: true,
        position: const Duration(seconds: 42),
        duration: const Duration(seconds: 90),
        reason: 'fullscreen',
      );
      expect(
        line,
        '[FxLive] switch phase=enter fs=on surface=off playing=yes '
        'pos=42.0s end=90.0s lag=48.0s reason=fullscreen',
      );
    });

    test('日志样例：切一次不中断，退回竖屏仍在原位并播放', () {
      // 正常切换（复用同一个播放器、不 seek）：lag 前后一致，playing 一直是 yes。
      final enter = fxLiveSwitchLog(
        phase: 'enter',
        fullscreen: true,
        surfaceMounted: false,
        playing: true,
        position: const Duration(milliseconds: 42000),
        duration: const Duration(seconds: 90),
        reason: 'fullscreen',
      );
      final exit = fxLiveSwitchLog(
        phase: 'exit',
        fullscreen: false,
        surfaceMounted: true,
        playing: true,
        position: const Duration(milliseconds: 44600),
        duration: const Duration(milliseconds: 92600),
        reason: 'fullscreen',
      );
      // 真断了（输出面没接回来）才会走到这里：补 play + 落回末端前 3 秒。
      final recover = fxLiveSwitchLog(
        phase: 'recover',
        fullscreen: false,
        surfaceMounted: true,
        playing: false,
        position: const Duration(seconds: 44),
        duration: const Duration(milliseconds: 92500),
        reason: 'exit',
      );
      final land = fxLiveProbeLog(
        event: 'land',
        position: const Duration(milliseconds: 89600),
        duration: const Duration(milliseconds: 92500),
        target: const Duration(milliseconds: 89500),
        reason: 'recover-exit',
      );
      for (final line in <String>[enter, exit, recover, land]) {
        // ignore: avoid_print
        print(line);
      }
      expect(enter, contains('lag=48.0s'));
      expect(exit, contains('lag=48.0s'), reason: '正常切换不 rewind，还在原位');
      expect(exit, contains('playing=yes'));
      expect(land, startsWith('[FxLive] land '));
      expect(land, contains('lag=2.9s'));
      expect(
        fxLiveIsAtEdge(
          position: const Duration(milliseconds: 89600),
          duration: const Duration(milliseconds: 92500),
        ),
        isTrue,
        reason: '救回来之后必须落在直播边缘 3 秒内',
      );
    });
  });

  group('③ 源码门禁（改回双画面层就红）', () {
    test('直播页：全屏期间用 fxLiveSurfaceVisible 摘掉画面层', () {
      final page = _read('lib/pages/live_detail_page.dart');
      final build = _block(page, 'Widget _buildPlayer() {');
      expect(build.contains('fxLiveSurfaceVisible('), isTrue,
          reason: '直播页必须走共享口径，别自己写 if (!_fullscreenActive)');
      expect(build.contains('fullscreenActive: _fullscreenActive'), isTrue);
      expect(page.contains('bool _fullscreenActive = false;'), isTrue);
    });

    test('直播页：切全屏不新建播放器 / 不重新 open，追边入口仍然只有一处', () {
      final page = _read('lib/pages/live_detail_page.dart');
      final open = _block(page, 'Future<void> _openFullscreen() async {');
      for (final banned in <String>[
        'FxPlayer.create',
        '_open(',
        '_openAndLand(',
        '.prepare(',
        '.dispose()',
      ]) {
        expect(open.contains(banned), isFalse,
            reason: '切全屏路径不许出现「$banned」：那会重建播放器 / 重新缓冲');
      }
      expect(open.contains('_fullscreenActive = true'), isTrue);
      expect(open.contains('_fullscreenActive = false'), isTrue);
      expect('player.seekToLiveEdge('.allMatches(page).length, 1,
          reason: '直播页只允许 _landOnLiveEdge 这一处追边');
      final recover = _block(
        page,
        'Future<void> _checkSurfaceAfterSwitch(',
      );
      expect(recover.contains('_landOnLiveEdge('), isTrue,
          reason: '接不上要复用唯一的追边入口（会自动落末端前 3 秒）');
      expect(recover.contains('fxLivePictureDead('), isTrue,
          reason: '先判「真的断了」再动手，位置在走就返回');
    });

    test('全屏页：直播自检只在 _isLive 下挂，点播链路不碰', () {
      final fs = _read('lib/pages/fullscreen_page.dart');
      expect(
        fs.contains('if (_isLive) unawaited(_checkLiveSurfaceAfterEnter(c));'),
        isTrue,
        reason: '直播自检必须挂在 _isLive 上，点播不许多一次 seek',
      );
      final check = _block(fs, 'Future<void> _checkLiveSurfaceAfterEnter(');
      expect(check.contains('fxLivePictureDead('), isTrue);
      expect(check.contains('seekToLiveEdge('), isTrue);
      expect(check.contains("reason: 'enter'"), isTrue);
      // 点播的起播 / 切集链路（_bootstrapSource）不许出现直播字样。
      final boot = _block(fs, 'Future<void> _bootstrapSource({');
      expect(boot.contains('_isLive'), isFalse,
          reason: '点播切集 / 重试链路不许被直播逻辑污染');
    });

    test('点播全屏行为未变：竖屏页仍然是原来的 _fullscreenActive 口径', () {
      final vod = _read('lib/pages/player_page.dart');
      expect(
        vod.contains(
          'if (c != null && c.value.isInitialized && !_fullscreenActive)',
        ),
        isTrue,
        reason: '点播「全屏期间摘画面层」原样保留',
      );
      expect(vod.contains('fxLive'), isFalse,
          reason: '直播口径不许渗进点播页');
      expect(vod.contains('setState(() => _fullscreenActive = true);'), isTrue);
      expect(vod.contains('setState(() => _fullscreenActive = false);'), isTrue);
    });
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

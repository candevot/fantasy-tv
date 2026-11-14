import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// ExoPlayer(Media3) 内核的 Dart 封装。
///
/// 为什么需要它：libmpv 在 HLS 上有几个绕不过去的坑 ——
///   · 播放列表重写时容易丢 #EXT-X-ENDLIST，被误判成直播（4K 只播 19 秒）
///   · 分片 302 跳转要自己处理，每片多一次往返
///   · 4K 高码率的自适应缓冲不成熟
///   · demuxer-readahead-secs / cache-buffering-state 这些属性难调，
///     反复出现「加载慢 / 出画黑屏 / 缓冲卡 99」
/// ExoPlayer 是腾讯/阿里播放器的同款内核，这些它原生就解决。
///
/// 设计：只管「播放」这一件事，画面用 PlatformView 交给 Android，
/// 控制层、救援链、一起看同步仍然留在 FxPlayer 里 —— 避免两套生命周期打架。
class ExoPlayerEngine {
  ExoPlayerEngine({MethodChannel? method, EventChannel? event})
      : _method = method ?? const MethodChannel(_methodChannel),
        _event = event ?? const EventChannel(_eventChannel) {
    _sub = _event.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object e) => _error = '$e',
    );
  }

  static const String _methodChannel = 'fantasy_tv/exo_player';
  static const String _eventChannel = 'fantasy_tv/exo_player_events';

  /// PlatformView 的类型名，Flutter 侧用 AndroidView 承载画面。
  static const String viewType = 'fantasy_tv/exo_view';

  /// 当前平台是否支持（只有 Android 有原生实现）。
  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  final MethodChannel _method;
  final EventChannel _event;
  StreamSubscription<dynamic>? _sub;

  /// 内核上报的最新状态；FxPlayer 监听它同步到自己的 value。
  final ValueNotifier<ExoPlayerState> state =
      ValueNotifier<ExoPlayerState>(const ExoPlayerState());

  String? _error;
  bool _disposed = false;

  String? get error => _error;

  Future<bool> init() async {
    if (!isSupported) return false;
    try {
      final r = await _method.invokeMethod<bool>('init');
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 打开一个地址。[headers] 会原样带给 Media3 的 HttpDataSource
  /// （有些源站校验 Referer/UA）。
  Future<bool> open(
    String url, {
    Map<String, String> headers = const {},
    bool isHls = true,
    /// 起始播放位置（毫秒）：原生在 `prepare()` 之前 seekTo，
    /// ExoPlayer 直接从目标分片开始选片，不先请求第 0 片。
    int startPositionMs = 0,
  }) async {
    if (_disposed || !isSupported) return false;
    _error = null;
    try {
      final r = await _method.invokeMethod<bool>('open', {
        'url': url,
        'headers': headers,
        'isHls': isHls,
        'startPositionMs': startPositionMs < 0 ? 0 : startPositionMs,
      });
      return r ?? false;
    } on PlatformException catch (e) {
      _error = e.message;
      return false;
    } catch (e) {
      _error = '$e';
      return false;
    }
  }

  Future<void> play() => _invoke('play');
  Future<void> pause() => _invoke('pause');

  Future<void> seek(Duration position) => _invoke('seek', {
        'positionMs': position.inMilliseconds,
      });

  Future<void> setRate(double rate) => _invoke('rate', {'rate': rate});

  /// 镜像：PlatformView 不能用 Flutter 的 Transform.flip，
  /// 混合合成下原生视图不跟随变换，必须交给原生翻视图自身的 scale。
  Future<void> setMirror({required bool flipX, required bool flipY}) =>
      _invoke('mirror', {'flipX': flipX, 'flipY': flipY});

  /// 主动拉一次状态（事件通道之外的低频兜底，防止漏事件）。
  Future<ExoPlayerState?> poll() async {
    if (_disposed || !isSupported) return null;
    try {
      final m = await _method.invokeMapMethod<String, dynamic>('state');
      if (m == null) return null;
      final s = ExoPlayerState.fromMap(m);
      state.value = s;
      return s;
    } catch (_) {
      return null;
    }
  }

  Future<void> _invoke(String method, [Map<String, dynamic>? args]) async {
    if (_disposed || !isSupported) return;
    try {
      await _method.invokeMethod<dynamic>(method, args);
    } catch (_) {
      // 播放控制失败不抛给页面：FxPlayer 的看门狗会兜底
    }
  }

  void _onEvent(dynamic raw) {
    if (_disposed) return;
    if (raw is! Map) return;
    final s = ExoPlayerState.fromMap(Map<String, dynamic>.from(raw));
    state.value = s;
    if (s.error != null && s.error!.isNotEmpty) _error = s.error;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _sub?.cancel();
    _sub = null;
    try {
      await _method.invokeMethod<void>('release');
    } catch (_) {}
    state.dispose();
  }
}

/// 内核上报的播放状态快照。
@immutable
class ExoPlayerState {
  const ExoPlayerState({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffered = Duration.zero,
    this.preloaded = Duration.zero,
    this.playing = false,
    this.buffering = true,
    this.error,
    this.width = 0,
    this.height = 0,
    this.ended = false,
    this.state = 1,
  });

  final Duration position;
  final Duration duration;

  /// 实际可播到的位置：`max(内核 buffered, 磁盘预取估算)`。
  ///
  /// BUFFERED_MAX（2026-11-14，按逆向报告 §10 改动 1）：用户看到的缓冲条
  /// 应该是「已经下到磁盘的段」，而不是解码器那一小段。对方就是把
  /// `max(exoPlayer.getBufferedPosition(), estimateDiskBufferedPositionMs())`
  /// 喂给进度条的 —— 灰条从一条细线变成大半条，拖动观感完全不同。
  final Duration buffered;

  /// 内核自己报的 buffered（不含磁盘预取），排查时用。
  final Duration preloaded;

  final bool playing;
  final bool buffering;
  final String? error;

  /// 解码后的显示宽高（已按 rotationDegrees 交换横竖屏方向）；0 表示还没拿到。
  final int width;
  final int height;

  /// 是否播放到结尾。
  final bool ended;

  /// Media3 Player.STATE_* 原值：1=IDLE 2=BUFFERING 3=READY 4=ENDED。
  final int state;

  factory ExoPlayerState.fromMap(Map<String, dynamic> m) {
    Duration d(String k) =>
        Duration(milliseconds: (m[k] as num?)?.toInt() ?? 0);
    final exoBuffered = d('bufferedMs');
    // 原生侧预取器报的「从现在起连续已落盘的时长」。
    final diskBuffered = d('preloadedMs');
    return ExoPlayerState(
      position: d('positionMs'),
      duration: d('durationMs'),
      buffered: diskBuffered > exoBuffered ? diskBuffered : exoBuffered,
      preloaded: diskBuffered,
      playing: m['playing'] == true,
      buffering: m['buffering'] == true,
      error: m['error'] as String?,
      width: (m['width'] as num?)?.toInt() ?? 0,
      height: (m['height'] as num?)?.toInt() ?? 0,
      ended: m['ended'] == true,
      state: (m['state'] as num?)?.toInt() ?? 1,
    );
  }

  /// 画面尺寸是否已经拿到（首帧就绪的判据之一）。
  bool get hasSize => width > 0 && height > 0;

  /// 缓冲百分比（0-100）。duration 未知时按 0 处理。
  double get bufferPercent {
    if (duration.inMilliseconds <= 0) return 0;
    final p = buffered.inMilliseconds / duration.inMilliseconds * 100;
    return p.clamp(0, 100).toDouble();
  }

  bool get hasDuration => duration.inMilliseconds > 0;

  @override
  String toString() =>
      'ExoPlayerState(pos=$position, dur=$duration, buf=$buffered, '
      'pre=${preloaded.inSeconds}s, '
      'playing=$playing, buffering=$buffering, ${width}x$height, '
      'ended=$ended, state=$state, err=$error)';
}

/// 画面视图：把 Android 的 PlayerView 嵌进 Flutter。
///
/// 只在 [ExoPlayerEngine.isSupported] 时可用；其它平台返回占位。
/// PlayerView 的 useController 是 false，控制层全部由我们自绘。
class ExoPlayerView extends StatelessWidget {
  const ExoPlayerView({super.key, this.resizeMode = exoResizeFit});

  /// Media3 AspectRatioFrameLayout 的缩放模式：
  /// 0=FIT(适应) 3=FILL(拉伸) 4=ZOOM(铺满裁切)。
  final int resizeMode;

  @override
  Widget build(BuildContext context) {
    if (!ExoPlayerEngine.isSupported) {
      return const ColoredBox(color: Color(0xFF000000));
    }
    // SURFACE_VIEW（2026-11-14）：必须走混合合成（initSurfaceAndroidView）。
    //
    // Media3 的 PlayerView 内部是 SurfaceView，而 AndroidView 默认用
    // 虚拟显示（VirtualDisplay）把原生视图画进纹理 —— SurfaceView 的内容
    // 在虚拟显示里通常渲染不出来，表现就是「有声音、画面全黑」。
    // 混合合成把原生视图直接叠到 Flutter 视图层级上，SurfaceView 才正常。
    return PlatformViewLink(
      viewType: ExoPlayerEngine.viewType,
      onCreatePlatformView: (params) {
        return PlatformViewsService.initSurfaceAndroidView(
          id: params.id,
          viewType: params.viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: <String, dynamic>{'resizeMode': resizeMode},
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create();
      },
      // hitTestBehavior 是必填参数；枚举定义在 rendering 库，
      // widgets.dart 不会把它重新导出，所以要显式 import。
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
      ),
    );
  }
}

/// AspectRatioFrameLayout.RESIZE_MODE_FIT
const int exoResizeFit = 0;

/// AspectRatioFrameLayout.RESIZE_MODE_FILL
const int exoResizeFill = 3;

/// AspectRatioFrameLayout.RESIZE_MODE_ZOOM
const int exoResizeZoom = 4;

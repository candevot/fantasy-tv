import 'dart:async';

import 'package:better_player/better_player.dart';
import 'package:flutter/material.dart';

/// 播放层 —— betterplayer(ExoPlayer/Media3) 的薄封装。
///
/// 为什么换掉 media_kit/libmpv（实测结论）：
///   · libmpv 的 HLS 解复用要自己维护列表重写，一旦漏掉 #EXT-X-ENDLIST
///     就被判成直播流，只播末尾几片（用户看到「一打开就是片尾曲、只有43秒」）；
///   · 分片 302 跳转要手动跟，每片多一次往返；
///   · 60 秒的大分片没有 BYTERANGE 支持，拖进度必须等整片下完。
///
/// betterplayer 用 ExoPlayer(Media3)，这些都是原生的：
///   · HlsMediaSource 原生认 #EXT-X-ENDLIST
///   · DefaultHttpDataSource 自带跨协议 302 跟随
///   · MediaCodecSelector 自动硬解，4K HEVC 走硬件
///   · 内置控件：进度条 / 倍速 / 画质 / 音轨 / 字幕 / PiP / 投屏 / 重试
///
/// 这一层只做三件事：把 betterplayer 的回调转成统一状态流、暴露常用控制、
/// 把内置控件配置成符合本项目风格的样子。播放界面直接用 BetterPlayer 控件，
/// 不再自己画一套（自绘控件是之前「组件不好看、位置不合适」的根源）。
class FxPlayback {
  FxPlayback() {
    _controller = BetterPlayerController(
      PlayerConfiguration(
        autoPlay: true,
        looping: false,
        fit: BoxFit.contain,
        // 播放器自己管生命周期，切后台自动暂停。
        handleLifecycle: true,
        // 页面负责销毁，控制器不自动释放（切换线路时要复用）。
        autoDispose: false,
        // 全屏由页面控制，不用 betterplayer 的横屏跳转。
        fullScreenByDefault: false,
        allowedScreenSleep: false,
        controlsConfiguration: _controlsConfig(),
      ),
    );
    _bind();
  }

  /// 内置控件的样式配置。
  ///
  /// 之前播放界面是自己画的一整套控件（fs_panels.dart 1216 行 +
  /// player_theme.dart 1030 行 + fs_controls.dart），问题是：
  ///   · 底栏同时有文字按钮和图标按钮，风格不统一；
  ///   · 倍速 / 清晰度在底栏和 ⋯ 面板里重复出现；
  ///   · 位置靠手算安全区，圆角屏容易压边。
  /// 现在直接用 betterplayer 的成熟控件，只改颜色和图标，风格统一、位置自动。
  static PlayerControlsConfiguration _controlsConfig() {
    return const PlayerControlsConfiguration(
      controlBarColor: Color(0xCC000000),
      textColor: Colors.white,
      iconsColor: Colors.white,
      progressBarPlayedColor: Color(0xFF6C8CFF),
      progressBarHandleColor: Colors.white,
      progressBarBufferedColor: Color(0x66FFFFFF),
      progressBarBackgroundColor: Color(0x33FFFFFF),
      loadingColor: Colors.white,
      backgroundColor: Colors.black,
      controlBarHeight: 48,
      // 隐藏时间 3 秒（默认就是 3 秒，写出来便于调整）
      controlsHideTime: Duration(seconds: 3),
      showControlsOnInitialize: true,
      // 全部功能入口开启
      enablePlayPause: true,
      enableProgressBar: true,
      enableProgressBarDrag: true,
      enableProgressText: true,
      enableSkips: true,
      enableReplay: true,
      enableOverflowMenu: true,
      enablePlaybackSpeed: true,
      enableQualities: true,
      enableAudioTracks: true,
      enableSubtitles: true,
      enablePip: true,
      enableMute: true,
      enableRetry: true,
      // 全屏按钮关掉：播放页本身就是全屏，不需要二次全屏
      enableFullscreen: false,
      // 投屏交给页面自己的 CastSheet
      enableAirPlay: false,
      forwardSkipTimeInMilliseconds: 10000,
      backwardSkipTimeInMilliseconds: 10000,
      playbackSpeeds: [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0],
    );
  }

  late final BetterPlayerController _controller;

  final ValueNotifier<FxPlaybackValue> value =
      ValueNotifier<FxPlaybackValue>(const FxPlaybackValue());

  final StreamController<Duration> _positionCtrl =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _durationCtrl =
      StreamController<Duration>.broadcast();
  final StreamController<bool> _playingCtrl =
      StreamController<bool>.broadcast();
  final StreamController<bool> _bufferingCtrl =
      StreamController<bool>.broadcast();
  final StreamController<String> _errorCtrl =
      StreamController<String>.broadcast();
  final StreamController<bool> _completedCtrl =
      StreamController<bool>.broadcast();

  Timer? _ticker;
  bool _disposed = false;
  bool _completedFired = false;
  FxPlaybackValue _last = const FxPlaybackValue();

  /// 底层控制器：需要画质列表、音轨列表、字幕等高级能力时直接用。
  BetterPlayerController get controller => _controller;

  Stream<Duration> get positionStream => _positionCtrl.stream;
  Stream<Duration> get durationStream => _durationCtrl.stream;
  Stream<bool> get playingStream => _playingCtrl.stream;
  Stream<bool> get bufferingStream => _bufferingCtrl.stream;
  Stream<String> get errorStream => _errorCtrl.stream;
  Stream<bool> get completedStream => _completedCtrl.stream;

  bool get isPlaying => _controller.videoPlayerValue?.isPlaying ?? false;

  Duration get position =>
      _controller.videoPlayerValue?.position ?? Duration.zero;

  Duration get duration =>
      _controller.videoPlayerValue?.duration ?? Duration.zero;

  /// 打开地址。[headers] 原样带给 ExoPlayer 的 HttpDataSource。
  ///
  /// [isHls] 决定用 HlsMediaSource 还是 ProgressiveMediaSource。
  Future<void> open(
    String url, {
    Map<String, String> headers = const {},
    bool isHls = true,
  }) async {
    _completedFired = false;
    final source = PlayerDataSource(
      DataSourceType.network,
      url,
      headers: headers.isEmpty ? null : headers,
      liveStream: false,
      // 让 ExoPlayer 自己解析 HLS 的多码率 / 多音轨 / 字幕轨
      useAsmsTracks: true,
      useAsmsAudioTracks: true,
      useAsmsSubtitles: true,
      videoFormat: isHls ? VideoFormat.hls : null,
      cacheConfiguration: const CacheConfiguration(
        maxCacheSize: 512 * 1024 * 1024,
        maxCacheFileSize: 64 * 1024 * 1024,
      ),
    );
    await _controller.setupDataSource(source);
    _startTicker();
  }

  Future<void> play() async {
    await _controller.play();
  }

  Future<void> pause() async {
    await _controller.pause();
  }

  Future<void> stop() async {
    _stopTicker();
    await _controller.pause();
    await _controller.seekTo(Duration.zero);
  }

  Future<void> seek(Duration position) async {
    await _controller.seekTo(position);
  }

  Future<void> setRate(double rate) async {
    await _controller.setSpeed(rate);
  }

  /// 画面 Widget —— 直接用 betterplayer 的成熟控件。
  ///
  /// [fit] 由 betterplayer 内部的 AspectRatio + FittedBox 处理（创建时
  /// 配置里已固定为 contain），这里不再额外包一层比例框 —— 外面再套会
  /// 二次约束把画面推出屏幕（用户报的「新播放器在屏幕外」）。
  /// [showControls] 是否显示 betterplayer 的内置控件。
  ///
  /// 竖屏嵌入播放（详情页 / 一起看房间）由页面自己画进度条，
  /// 这时传 false，否则内置控件会和页面控件叠成两层。
  /// 全屏播放传 true，直接用内置控件（画质 / 音轨 / 字幕 / PiP）。
  Widget buildVideo({BoxFit fit = BoxFit.contain, bool showControls = true}) {
    _controller.setControlsEnabled(showControls);
    return BetterPlayer(controller: _controller);
  }

  void _startTicker() {
    _stopTicker();
    // 位置需要轮询：betterplayer 不推连续位置流。
    _ticker = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (_disposed) return;
      _sync();
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _bind() {
    _controller.addEventsListener((event) {
      if (_disposed) return;
      switch (event.betterPlayerEventType) {
        case PlayerEventType.exception:
          final msg = event.parameters?['error']?.toString() ?? '播放异常';
          _errorCtrl.add(msg);
          _setValue(_last.copyWith(hasError: true, errorText: msg));
          break;
        case PlayerEventType.finished:
          if (!_completedFired) {
            _completedFired = true;
            _completedCtrl.add(true);
            _setValue(_last.copyWith(isCompleted: true));
          }
          break;
        default:
          break;
      }
    });
  }

  // 网速估算：betterplayer/ExoPlayer 不暴露实时带宽，这里用「已缓冲时长
  // 的增量」反推。单位换算：增量秒数 × 码率 ≈ 下载字节，但码率未知，
  // 所以直接用「每秒缓冲了多少秒」当作 1x 播放速度的倍数，再乘一个
  // 估计码率给出近似网速。只用于界面显示，不参与任何播放决策。
  DateTime? _speedAt;
  Duration _speedBuffered = Duration.zero;
  double _speedBps = 0;
  int? _lastVideoBytes;

  /// 近似网速（字节/秒）；0 表示还没测到。
  double get measuredBytesPerSecond => _speedBps;

  void _updateSpeed(Duration buffered, Duration duration, int? videoBytes) {
    final now = DateTime.now();
    // 画面分辨率变化时重新起算（切清晰度会让码率跳变）。
    if (videoBytes != _lastVideoBytes) {
      _lastVideoBytes = videoBytes;
      _speedAt = now;
      _speedBuffered = buffered;
      return;
    }
    final last = _speedAt;
    if (last == null) {
      _speedAt = now;
      _speedBuffered = buffered;
      return;
    }
    final dtMs = now.difference(last).inMilliseconds;
    if (dtMs < 900) return;
    final gainedSec =
        (buffered.inMilliseconds - _speedBuffered.inMilliseconds) / 1000.0;
    _speedAt = now;
    _speedBuffered = buffered;
    if (gainedSec <= 0) {
      // 缓冲没长（可能已缓冲到片尾）：逐步衰减到 0，不显示假速度。
      _speedBps = _speedBps * 0.6;
      return;
    }
    // 用分辨率估码率：1080p≈2.5Mbps，720p≈1.2Mbps，4K≈15Mbps。
    final h = videoBytes ?? 0;
    final mbps = h >= 1800
        ? 15.0
        : h >= 1000
            ? 2.5
            : h >= 700
                ? 1.2
                : 0.8;
    final bytes = gainedSec * mbps * 1024 * 1024 / 8;
    _speedBps = bytes / (dtMs / 1000.0);
  }

  void _sync() {
    final vp = _controller.videoPlayerValue;
    if (vp == null) return;

    // better_player 1.36 的 VideoPlayerValue：
    //   duration  Duration?（未就绪为 null）
    //   size      Size?（未就绪为 null）
    //   buffered  List<DurationRange>
    //   initialized 就是「已就绪」，没有 isInitialized 这个字段。
    final dur = vp.duration ?? Duration.zero;
    final size = vp.size;
    final w = size?.width ?? 0;
    final h = size?.height ?? 0;
    final bufferedEnd =
        vp.buffered.isEmpty ? Duration.zero : vp.buffered.last.end;

    _updateSpeed(bufferedEnd, dur, h > 0 ? h.round() : null);

    final next = FxPlaybackValue(
      position: vp.position,
      duration: dur,
      buffered: bufferedEnd,
      bytesPerSecond: _speedBps,
      isPlaying: vp.isPlaying,
      isBuffering: vp.isBuffering,
      isInitialized: vp.initialized,
      videoWidth: w > 0 ? w.round() : null,
      videoHeight: h > 0 ? h.round() : null,
      aspectRatio: w > 0 && h > 0 ? w / h : 16 / 9,
      hasError: _last.hasError,
      errorText: _last.errorText,
      isCompleted: _last.isCompleted,
    );

    if (next.position != _last.position) _positionCtrl.add(next.position);
    if (next.duration != _last.duration) _durationCtrl.add(next.duration);
    if (next.isPlaying != _last.isPlaying) _playingCtrl.add(next.isPlaying);
    if (next.isBuffering != _last.isBuffering) {
      _bufferingCtrl.add(next.isBuffering);
    }

    // 播完判定：位置到末尾 1 秒内且已暂停，只触发一次。
    if (!_completedFired &&
        next.duration.inMilliseconds > 0 &&
        next.position.inMilliseconds >= next.duration.inMilliseconds - 1000 &&
        !next.isPlaying) {
      _completedFired = true;
      _completedCtrl.add(true);
      _setValue(next.copyWith(isCompleted: true));
      return;
    }
    _setValue(next);
  }

  void _setValue(FxPlaybackValue v) {
    _last = v;
    if (!_disposed) value.value = v;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _stopTicker();
    // dispose 在 1.36 是同步 void，不是 Future。
    _controller.dispose(forceDispose: true);
    await _positionCtrl.close();
    await _durationCtrl.close();
    await _playingCtrl.close();
    await _bufferingCtrl.close();
    await _errorCtrl.close();
    await _completedCtrl.close();
    value.dispose();
  }
}

/// 播放状态快照（字段与 FxPlayerValue 对齐，页面层可平滑迁移）。
@immutable
class FxPlaybackValue {
  const FxPlaybackValue({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.buffered = Duration.zero,
    this.isPlaying = false,
    this.isBuffering = true,
    this.isInitialized = false,
    this.isCompleted = false,
    this.hasError = false,
    this.errorText = '',
    this.videoWidth,
    this.videoHeight,
    this.aspectRatio = 16 / 9,
    this.bytesPerSecond = 0,
  });

  final Duration position;
  final Duration duration;
  final Duration buffered;
  final bool isPlaying;
  final bool isBuffering;
  final bool isInitialized;
  final bool isCompleted;
  final bool hasError;
  final String errorText;
  final int? videoWidth;
  final int? videoHeight;
  final double aspectRatio;

  /// 近似网速（字节/秒）；0 表示还没测到。
  final double bytesPerSecond;

  /// 进度（0-1）。
  double get progress {
    if (duration.inMilliseconds <= 0) return 0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  /// 形如 `1920x1080`；未就绪返回空串。
  String get resolutionText {
    final w = videoWidth ?? 0;
    final h = videoHeight ?? 0;
    if (w <= 0 || h <= 0) return '';
    return '${w}x$h';
  }

  FxPlaybackValue copyWith({
    Duration? position,
    Duration? duration,
    Duration? buffered,
    bool? isPlaying,
    bool? isBuffering,
    bool? isInitialized,
    bool? isCompleted,
    bool? hasError,
    String? errorText,
    int? videoWidth,
    int? videoHeight,
    double? aspectRatio,
    double? bytesPerSecond,
  }) {
    return FxPlaybackValue(
      position: position ?? this.position,
      duration: duration ?? this.duration,
      buffered: buffered ?? this.buffered,
      isPlaying: isPlaying ?? this.isPlaying,
      isBuffering: isBuffering ?? this.isBuffering,
      isInitialized: isInitialized ?? this.isInitialized,
      isCompleted: isCompleted ?? this.isCompleted,
      hasError: hasError ?? this.hasError,
      errorText: errorText ?? this.errorText,
      videoWidth: videoWidth ?? this.videoWidth,
      videoHeight: videoHeight ?? this.videoHeight,
      aspectRatio: aspectRatio ?? this.aspectRatio,
      bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
    );
  }
}

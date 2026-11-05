import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// FxPlayer 打开/播放失败时抛出的异常，调用方可据此尝试备用地址。
class FxPlayerException implements Exception {
  const FxPlayerException(this.message);

  final String message;

  @override
  String toString() => 'FxPlayerException: $message';
}

/// 播放器状态快照。
///
/// 字段刻意对齐 video_player 的 `VideoPlayerValue` 常用子集，
/// 方便从旧播放内核平滑迁移，同时补充 media_kit 的原始宽高信息。
class FxPlayerValue {
  const FxPlayerValue({
    this.isInitialized = false,
    this.isPlaying = false,
    this.isBuffering = false,
    this.bufferingPercentage = 0,
    this.buffered = Duration.zero,
    this.isCompleted = false,
    this.hasError = false,
    this.errorText = '',
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.width,
    this.height,
    this.videoWidth,
    this.videoHeight,
    this.aspectRatio = 16 / 9,
  });

  /// 是否已经拿到视频参数/时长，可以开始渲染与 seek。
  final bool isInitialized;

  /// 是否正在播放。
  final bool isPlaying;

  /// 是否正在缓冲。
  final bool isBuffering;

  /// libmpv 的真实缓冲百分比（cache-buffering-state，0–100）。
  final double bufferingPercentage;

  /// 已缓冲 / 已解码的媒体时长（demuxer-cache-time）。
  final Duration buffered;

  /// 是否已播放到结尾。
  final bool isCompleted;

  /// 是否发生播放错误。
  final bool hasError;

  /// 最近一次错误信息（可能为空）。
  final String errorText;

  /// 当前播放进度。
  final Duration position;

  /// 总时长；直播流可能为 0。
  final Duration duration;

  /// 显示用宽度（已按 rotate 交换横竖屏方向）。
  final int? width;

  /// 显示用高度（已按 rotate 交换横竖屏方向）。
  final int? height;

  /// 解码后的原始视频宽度（videoParams.w）。
  final int? videoWidth;

  /// 解码后的原始视频高度（videoParams.h）。
  final int? videoHeight;

  /// 显示宽高比。
  final double aspectRatio;

  /// 画面尺寸，未就绪时宽高为 0。
  Size get size => Size(
        (width ?? 0).toDouble(),
        (height ?? 0).toDouble(),
      );

  /// 形如 `1920x1080` 的分辨率文案；未就绪时返回空串。
  String get resolutionText {
    final rawWidth = videoWidth ?? 0;
    final rawHeight = videoHeight ?? 0;
    final w = rawWidth > 0 ? rawWidth : (width ?? 0);
    final h = rawHeight > 0 ? rawHeight : (height ?? 0);
    if (w <= 0 || h <= 0) return '';
    return '${w}x$h';
  }

  FxPlayerValue copyWith({
    bool? isInitialized,
    bool? isPlaying,
    bool? isBuffering,
    double? bufferingPercentage,
    Duration? buffered,
    bool? isCompleted,
    bool? hasError,
    String? errorText,
    Duration? position,
    Duration? duration,
    int? width,
    int? height,
    int? videoWidth,
    int? videoHeight,
    double? aspectRatio,
  }) {
    return FxPlayerValue(
      isInitialized: isInitialized ?? this.isInitialized,
      isPlaying: isPlaying ?? this.isPlaying,
      isBuffering: isBuffering ?? this.isBuffering,
      bufferingPercentage: bufferingPercentage ?? this.bufferingPercentage,
      buffered: buffered ?? this.buffered,
      isCompleted: isCompleted ?? this.isCompleted,
      hasError: hasError ?? this.hasError,
      errorText: errorText ?? this.errorText,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      width: width ?? this.width,
      height: height ?? this.height,
      videoWidth: videoWidth ?? this.videoWidth,
      videoHeight: videoHeight ?? this.videoHeight,
      aspectRatio: aspectRatio ?? this.aspectRatio,
    );
  }
}

/// 基于 media_kit（libmpv）的播放内核封装。
///
/// - 统一处理 HLS / 加密流 / 各种奇怪编码（libmpv + ffmpeg）；
/// - 提供与 video_player 类似的 `value` / `addListener` / `dispose` 接口；
/// - 以 Stream 形式暴露 position / duration / buffering / error / completed；
/// - [buildVideo] 返回可直接放进页面的视频 Widget。
class FxPlayer implements Listenable {
  FxPlayer._({
    this.readyTimeout = const Duration(seconds: 20),
  }) {
    _player = Player();
    _controller = VideoController(_player);
    _bindStreams();
  }

  /// 创建播放器实例。
  ///
  /// 调用前必须已在 `main()` 中执行 `MediaKit.ensureInitialized()`。
  static FxPlayer create({
    Duration readyTimeout = const Duration(seconds: 20),
  }) {
    return FxPlayer._(readyTimeout: readyTimeout);
  }

  /// 等待首帧/时长的超时时间；超时视为该地址不可播。
  final Duration readyTimeout;

  late final Player _player;
  late final VideoController _controller;

  final Set<VoidCallback> _listeners = <VoidCallback>{};
  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];

  FxPlayerValue _value = const FxPlayerValue();
  bool _disposed = false;
  int _openToken = 0;
  Completer<void>? _ready;

  /// 底层 media_kit Player，需要高级能力（音轨/字幕/属性）时可直接使用。
  Player get player => _player;

  /// media_kit 的视频输出控制器。
  VideoController get videoController => _controller;

  /// 当前状态快照。
  FxPlayerValue get value => _value;

  /// 流式播放进度。
  Stream<Duration> get positionStream => _player.stream.position;

  /// 流式总时长。
  Stream<Duration> get durationStream => _player.stream.duration;

  /// 流式缓冲状态。
  Stream<bool> get bufferingStream => _player.stream.buffering;

  /// 流式错误信息。
  Stream<String> get errorStream => _player.stream.error;

  /// 流式播放完成状态。
  Stream<bool> get completedStream => _player.stream.completed;

  /// 画面组件（media_kit Video，内置控件已关闭，交给页面自绘）。
  Widget buildVideo({
    BoxFit fit = BoxFit.contain,
    Alignment alignment = Alignment.center,
  }) {
    return Video(
      controller: _controller,
      controls: NoVideoControls,
      fit: fit,
      alignment: alignment,
      fill: Colors.black,
      wakelock: true,
      pauseUponEnteringBackgroundMode: false,
      resumeUponEnteringForegroundMode: false,
    );
  }

  /// [buildVideo] 的简写入口。
  Widget video({BoxFit fit = BoxFit.contain}) => buildVideo(fit: fit);

  /// 打开一个网络地址并等待其就绪。
  ///
  /// [headers] 会透传给 libmpv（Referer / User-Agent 等）。
  /// 打不开、解码失败或超时会抛出 [FxPlayerException]，方便上层切换备用地址。
  Future<void> open(
    String url, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    if (_disposed) throw const FxPlayerException('播放器已释放');
    final token = ++_openToken;
    _value = const FxPlayerValue();
    _notify();
    final ready = Completer<void>();
    _ready = ready;
    // 如果 open 自身先抛错而没来得及 await ready，提前吞掉这个错误，
    // 避免出现未处理的异步异常。
    unawaited(ready.future.catchError((Object _) {}));
    try {
      await _player
          .open(
            Media(
              url,
              httpHeaders: headers.isEmpty ? null : headers,
            ),
            play: false,
          )
          .timeout(readyTimeout);
    } catch (error) {
      if (identical(_ready, ready)) _ready = null;
      _fail('$error');
      throw FxPlayerException('$error');
    }
    if (_disposed || token != _openToken) return;
    try {
      await ready.future.timeout(readyTimeout);
    } on TimeoutException {
      if (token == _openToken) {
        _fail('播放超时，线路可能不可用');
        throw const FxPlayerException('播放超时');
      }
    } finally {
      if (identical(_ready, ready)) _ready = null;
    }
  }

  Future<void> play() => _player.play();

  Future<void> pause() => _player.pause();

  /// 播放 / 暂停切换：直接交给 media_kit 处理，
  /// 页面不要用本地布尔自行改状态，避免和真实播放状态互相覆盖。
  Future<void> playOrPause() => _player.playOrPause();

  /// 播放器真实播放状态（libmpv 当前值），按钮图标以此为准。
  bool get isPlaying => _player.state.playing;

  /// libmpv 当前真实倍速；跨页面交接时以此为准，避免本地状态落后。
  double get rate => _player.state.rate;

  /// 播放状态流；页面可用它驱动播放 / 暂停图标。
  Stream<bool> get playingStream => _player.stream.playing;

  Future<void> seek(Duration position) => _player.seek(position);

  /// 兼容 video_player 命名。
  Future<void> seekTo(Duration position) => seek(position);

  Future<void> setRate(double rate) => _player.setRate(rate);

  /// 兼容 video_player 命名。
  Future<void> setPlaybackSpeed(double rate) => setRate(rate);

  /// 兼容 video_player 命名；单集播放固定不循环。
  Future<void> setLooping(bool looping) async {
    await _player.setPlaylistMode(
      looping ? PlaylistMode.loop : PlaylistMode.none,
    );
  }

  @override
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _openToken++;
    final ready = _ready;
    _ready = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(const FxPlayerException('播放器已释放'));
    }
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _listeners.clear();
    try {
      await _player.dispose();
    } catch (_) {
      // 释放失败不影响页面退出。
    }
  }

  // ------------------------------------------------------------- internals

  void _bindStreams() {
    _subscriptions.add(
      _player.stream.position.listen((position) {
        final initialized = _value.isInitialized || position > Duration.zero;
        _setValue(
          _value.copyWith(
            isInitialized: initialized,
            position: position,
          ),
        );
      }),
    );
    _subscriptions.add(
      _player.stream.duration.listen((duration) {
        _setValue(
          _value.copyWith(
            isInitialized: _value.isInitialized || duration > Duration.zero,
            duration: duration,
          ),
        );
      }),
    );
    _subscriptions.add(
      _player.stream.videoParams.listen(_onVideoParams),
    );
    _subscriptions.add(
      _player.stream.buffering.listen((buffering) {
        _setValue(_value.copyWith(isBuffering: buffering));
      }),
    );
    _subscriptions.add(
      _player.stream.buffer.listen((buffered) {
        _setValue(_value.copyWith(buffered: buffered));
      }),
    );
    _subscriptions.add(
      _player.stream.bufferingPercentage.listen((percentage) {
        _setValue(_value.copyWith(bufferingPercentage: percentage));
      }),
    );
    _subscriptions.add(
      _player.stream.playing.listen((playing) {
        _setValue(_value.copyWith(isPlaying: playing));
      }),
    );
    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        _setValue(_value.copyWith(isCompleted: completed));
      }),
    );
    _subscriptions.add(
      _player.stream.error.listen((message) {
        _onError(message);
      }),
    );
  }

  void _onVideoParams(VideoParams params) {
    var width = params.dw;
    var height = params.dh;
    if (width == null || width <= 0) width = params.w;
    if (height == null || height <= 0) height = params.h;
    final rotate = params.rotate ?? 0;
    if (width != null && height != null && (rotate == 90 || rotate == 270)) {
      final swap = width;
      width = height;
      height = swap;
    }
    final hasSize = width != null && height != null && width > 0 && height > 0;
    var aspect = _value.aspectRatio;
    final reportedAspect = params.aspect;
    if (reportedAspect != null && reportedAspect > 0) {
      aspect = reportedAspect;
    }
    if (hasSize) {
      aspect = width / height;
    }
    _setValue(
      _value.copyWith(
        isInitialized: _value.isInitialized || hasSize,
        width: width,
        height: height,
        videoWidth: params.w ?? width,
        videoHeight: params.h ?? height,
        aspectRatio: aspect,
      ),
    );
  }

  void _onError(String message) {
    if (_disposed) return;
    _value = _value.copyWith(hasError: true, errorText: message);
    _notify();
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(FxPlayerException(message));
    }
  }

  void _fail(String message) {
    if (_disposed) return;
    _value = _value.copyWith(hasError: true, errorText: message);
    _notify();
  }

  void _setValue(FxPlayerValue next) {
    if (_disposed) return;
    _value = next;
    _notify();
    if (next.isInitialized) {
      final ready = _ready;
      if (ready != null && !ready.isCompleted) ready.complete();
    }
  }

  void _notify() {
    if (_disposed) return;
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }
}

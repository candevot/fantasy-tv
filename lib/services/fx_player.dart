import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../api.dart';
import '../models.dart';
import 'local_hls_proxy.dart';

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

  /// 真实缓冲进度（0–99）；拿不到可靠数据时返回 null。
  ///
  /// 优先「已缓存时长 / 总时长」；直播 / 时长未知的 HLS 退回 libmpv 的
  /// cache-buffering-state，UI 不会为了凑进度显示假的 100%。
  double? get bufferingPercent {
    if (duration > Duration.zero && buffered > Duration.zero) {
      final ratio = buffered.inMilliseconds / duration.inMilliseconds;
      if (ratio.isFinite) return (ratio * 100).clamp(0.0, 99.0);
    }
    if (bufferingPercentage > 0) {
      return bufferingPercentage.clamp(0.0, 99.0);
    }
    return null;
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
    final android = defaultTargetPlatform == TargetPlatform.android;
    _player = Player(
      configuration: const PlayerConfiguration(
        title: '幻想影视',
        // 字幕 / ASS 交给 libass，复杂样式不走 Flutter 层。
        libass: true,
        // 起播只用 12MB 小缓冲，首帧出来后再动态升到 32MB。
        bufferSize: _startupBufferBytes,
        logLevel: MPVLogLevel.error,
      ),
    );
    _controller = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        // Android 用 gpu 输出 + 硬解优先；其它平台保持 media_kit 默认输出，
        // 避免 vo=gpu 与 libmpv 纹理渲染冲突。
        vo: android ? 'gpu' : 'libmpv',
        hwdec: android ? 'auto-safe' : 'auto',
        enableHardwareAcceleration: true,
      ),
    );
    _bindStreams();
    unawaited(_setCacheLimits(_startupBufferBytes));
    // 长播兜底：每 5 分钟把缓存升到稳定值并重压回看缓存，
    // 播 10 分钟以上内存也不会无限涨。
    _cacheGuardTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(_setCacheLimits(_steadyBufferBytes)),
    );
  }

  /// 起播前向缓存 12MB；首帧后升到 32MB；回看缓存单独压到 8MB。
  static const int _startupBufferBytes = 12 * 1024 * 1024;
  static const int _steadyBufferBytes = 32 * 1024 * 1024;
  static const int _backBufferBytes = 8 * 1024 * 1024;

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
  Timer? _cacheGuardTimer;

  /// 正在执行的 open（url+headers）：同一地址并发 open 直接复用，防重复。
  _OpenRequest? _opening;

  /// 本集是否已经把起播小缓冲提升到稳定值。
  bool _cacheRaised = false;

  /// 直链 HLS 的本地分片代理；只在 direct 模式下懒创建。
  LocalHlsProxy? _hlsProxy;

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

  /// 抓取当前画面的一帧（JPEG 字节）。
  ///
  /// media_kit 的 Video 在 open 新地址时会清空纹理，切线路 / 切集前先存下
  /// 这张快照，切换期间垫在画面层上，等新流首帧就绪后再淡出。
  /// 播放器未就绪、设备不支持或抓取异常时返回 null，调用方退回纯黑即可。
  Future<Uint8List?> captureFrame() async {
    if (_disposed || !_value.isInitialized) return null;
    try {
      final bytes = await _player.screenshot();
      if (bytes == null || bytes.isEmpty) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// 打开一个网络地址并等待其就绪。
  ///
  /// [headers] 会透传给 libmpv（Referer / User-Agent 等）。
  /// [play] 为 true 时 open 后立即起播（首帧优先），不等待全部 metadata；
  /// 默认 false 保持旧调用方（一起看等）先 seek 再播的语义。
  /// [direct] 为 true（调用方已确认是 HLS 直链）时，先走本地分片
  /// 代理（多连接 Range 下载 + 预取）；代理启动失败自动回退直连。
  /// [refreshPlay] 仅供平台线路（临时签名 m3u8）使用：代理遇到 403/404
  /// 或每 90 秒回调它重新请求 `/api/play?...&fresh=1` 拿新地址。
  /// [onPlayExpired] 在连续两次拿不到新地址时回调，由页面提示切换线路。
  /// 打不开、解码失败或超时会抛出 [FxPlayerException]，方便上层切换备用地址。
  Future<void> open(
    String url, {
    Map<String, String> headers = const <String, String>{},
    bool play = false,
    bool waitForWarm = false,
    bool direct = false,
    PlayUrlRefresher? refreshPlay,
    PlayExpiredCallback? onPlayExpired,
  }) {
    if (_disposed) {
      return Future<void>.error(const FxPlayerException('播放器已释放'));
    }
    final key = _openKey(url, headers, direct);
    final pending = _opening;
    // 同一 url + headers 正在打开：忽略重复请求，复用同一个结果。
    if (pending != null && pending.key == key) return pending.future;
    final future = _openInternal(
      url,
      headers,
      play,
      waitForWarm,
      direct,
      refreshPlay,
      onPlayExpired,
    );
    final request = _OpenRequest(key, future);
    _opening = request;
    return future.whenComplete(() {
      if (identical(_opening, request)) _opening = null;
    });
  }

  static String _openKey(
    String url,
    Map<String, String> headers,
    bool direct,
  ) {
    final suffix = direct ? '|direct=1' : '';
    if (headers.isEmpty) return '$url$suffix';
    final entries = headers.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .toList()
      ..sort();
    return '$url$suffix|${entries.join('&')}';
  }

  Future<void> _openInternal(
    String url,
    Map<String, String> headers,
    bool play,
    bool waitForWarm,
    bool direct,
    PlayUrlRefresher? refreshPlay,
    PlayExpiredCallback? onPlayExpired,
  ) async {
    final token = ++_openToken;
    _cacheRaised = false;
    _value = const FxPlayerValue();
    _notify();
    final ready = Completer<void>();
    _ready = ready;
    // 如果 open 自身先抛错而没来得及 await ready，提前吞掉这个错误，
    // 避免出现未处理的异步异常。
    unawaited(ready.future.catchError((Object _) {}));
    try {
      // 1) 直链 HLS：本机代理把分片切成多连接 Range 下载并预取。
      //    代理失败（端口占用 / 拉列表失败 / 超时）就回退直连。
      var playbackUrl = url;
      var playbackHeaders = headers;
      var proxied = false;
      if (direct) {
        final proxy = _hlsProxy ??= LocalHlsProxy(log: debugPrint);
        try {
          final localUrl = await proxy
              .proxy(
                url,
                headers,
                refreshPlay: refreshPlay,
                onPlayExpired: onPlayExpired == null
                    ? null
                    : () {
                        if (_disposed || token != _openToken) return;
                        onPlayExpired();
                      },
              )
              .timeout(const Duration(seconds: 4));
          if (_disposed || token != _openToken) return;
          if (localUrl.isNotEmpty) {
            playbackUrl = localUrl;
            playbackHeaders = const <String, String>{};
            proxied = true;
          }
        } catch (error) {
          debugPrint('FxPlayer: 本地 HLS 代理启动失败，回退直连: $error');
          // 只有当前这次 open 仍是“最新”时才销毁代理；快速连切时旧 open
          // 的失败不能把新 open 正在用的代理关掉。
          if (!_disposed && token == _openToken) {
            final failed = _hlsProxy;
            _hlsProxy = null;
            unawaited(failed?.dispose());
          }
        }
      }
      if (_disposed || token != _openToken) return;

      // 2) 非代理路径保留原有 m3u8 预热；代理路径本身已经拉过列表并预取。
      if (!proxied) {
        final warmup = _FxHlsWarmup.prepare(url, headers);
        if (waitForWarm) {
          await warmup;
        } else {
          unawaited(warmup);
        }
      }
      if (_disposed || token != _openToken) return;
      // 3) 新一集回到 12MB 小缓冲起步，首帧后再升到 32MB。
      unawaited(_setCacheLimits(_startupBufferBytes));
      await _player
          .open(
            Media(
              playbackUrl,
              httpHeaders: playbackHeaders.isEmpty ? null : playbackHeaders,
            ),
            // 5) 立即解除暂停，先出画面，不等 duration / 全部元数据。
            play: play,
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
    // 首帧 / 时长已就绪：把起播小缓冲动态升到 32MB，长播更稳。
    _raiseCacheAfterStart();
  }

  /// 首帧后把前向缓存从 12MB 升到 32MB；每集只升一次。
  void _raiseCacheAfterStart() {
    if (_disposed || _cacheRaised) return;
    _cacheRaised = true;
    unawaited(_setCacheLimits(_steadyBufferBytes));
  }

  /// 限制 demuxer 前向 / 回看缓存；mpv 在播放中会按新上限回收旧缓存，
  /// 长播时不会因为回看缓存累积而内存无限增长。
  Future<void> _setCacheLimits(int forwardBytes) async {
    if (_disposed) return;
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('demuxer-max-bytes', '$forwardBytes');
      await platform.setProperty(
        'demuxer-max-back-bytes',
        '$_backBufferBytes',
      );
    } catch (_) {
      // 旧版本 / 特殊平台没有这些属性时静默跳过。
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
    _cacheGuardTimer?.cancel();
    _cacheGuardTimer = null;
    _opening = null;
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
    final hlsProxy = _hlsProxy;
    _hlsProxy = null;
    hlsProxy?.cancelPrefetch();
    try {
      await _player.dispose();
    } catch (_) {
      // 释放失败不影响页面退出。
    }
    try {
      await hlsProxy?.dispose();
    } catch (_) {
      // 本地代理关闭失败不影响页面退出。
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

/// 切线路 / 切集期间的画面快照层。
///
/// 铺在视频层之上、加载与控件层之下：Video 换源时纹理会先清空，
/// 这张图顶住空窗；[opaque] 置 false 后 200ms 淡出，露出新流首帧。
/// [bytes] 为 null（截图失败）时不渲染任何东西，页面退回纯黑 + 加载层。
class FxSnapshotLayer extends StatelessWidget {
  const FxSnapshotLayer({
    super.key,
    required this.bytes,
    required this.opaque,
    this.fit = BoxFit.contain,
  });

  /// media_kit `Player.screenshot()` 返回的图片字节。
  final Uint8List? bytes;

  /// 是否完全盖住画面；false 时淡出。
  final bool opaque;

  /// 与当前播放模式一致：竖屏 contain，全屏撑满时 cover。
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final data = bytes;
    if (data == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: opaque ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        child: Image.memory(
          data,
          fit: fit,
          gaplessPlayback: true,
          filterQuality: FilterQuality.low,
        ),
      ),
    );
  }
}

/// 正在执行的一次 open，用于忽略同一地址的重复打开请求。
class _OpenRequest {
  const _OpenRequest(this.key, this.future);

  final String key;
  final Future<void> future;
}

/// /api/play 结果缓存 + 下一集预解析（只请求，不创建播放器）。
///
/// - 缓存 10 分钟内有效，最多 8 条，避免 URL 长期失效与内存膨胀；
/// - 同一集并发请求走同一个 Future，不会重复打接口；
/// - [prewarm] 会先清掉旧结果再请求，并把下一集的 m3u8 也预热好，
///   切集时 open 只差一个本地 playlist 往返。
class FxPlayCache {
  static const Duration _ttl = Duration(minutes: 10);
  static const int _maxEntries = 8;

  static final Map<String, _CachedPlayInfo> _cache =
      <String, _CachedPlayInfo>{};
  static final Map<String, Future<PlayInfo>> _inflight =
      <String, Future<PlayInfo>>{};

  static String _key(String id, int ep, String line) => '$id|$ep|$line';

  static PlayInfo? _fresh(String key) {
    final cached = _cache[key];
    if (cached == null) return null;
    if (DateTime.now().difference(cached.at) > _ttl) {
      _cache.remove(key);
      return null;
    }
    return cached.info;
  }

  /// 只看缓存不请求；UI 可用于判断是否可秒开。
  static PlayInfo? peek(String id, int ep, String line) =>
      _fresh(_key(id, ep, line));

  /// 取播放地址：优先缓存 / 正在请求的结果，[force] 时强制重新请求。
  static Future<PlayInfo> resolve(
    String id,
    int ep,
    String line, {
    bool force = false,
  }) {
    final key = _key(id, ep, line);
    if (force) {
      _cache.remove(key);
    } else {
      final cached = _fresh(key);
      if (cached != null) return Future<PlayInfo>.value(cached);
    }
    final pending = _inflight[key];
    if (pending != null) return pending;
    final future = Api.play(id, ep, line).then((info) {
      _cache[key] = _CachedPlayInfo(info, DateTime.now());
      _trim();
      return info;
    });
    _inflight[key] = future;
    return future.whenComplete(() {
      if (identical(_inflight[key], future)) _inflight.remove(key);
    });
  }

  /// 页面进入 / 下一集预热：已有缓存直接复用，不重复请求接口。
  /// 只发请求并预热 m3u8，不创建播放器。
  static void warm(String id, int ep, String line) {
    final key = _key(id, ep, line);
    if (_fresh(key) != null) return;
    _resolveAndWarm(id, ep, line);
  }

  /// 播放 30 秒后调用：后台清空并刷新下一集 /api/play 结果与 m3u8。
  /// 只发请求，不 open；失败静默，不影响当前播放。
  static void prewarm(String id, int ep, String line) {
    _cache.remove(_key(id, ep, line));
    _resolveAndWarm(id, ep, line);
  }

  static void _resolveAndWarm(String id, int ep, String line) {
    final key = _key(id, ep, line);
    if (_inflight.containsKey(key)) return;
    unawaited(
      resolve(id, ep, line).then<void>(
        (info) async {
          final url = info.url.trim();
          if (url.isEmpty) return;
          await _FxHlsWarmup.prepare(url, info.headers);
        },
        onError: (Object error, StackTrace stack) {
          // 预解析失败无需打扰用户，切集时还会正常重试。
        },
      ),
    );
  }

  /// 播放地址失效 / 手动刷新时清掉对应缓存。
  static void invalidate(String id, int ep, String line) {
    _cache.remove(_key(id, ep, line));
  }

  static void _trim() {
    final now = DateTime.now();
    _cache.removeWhere((_, cached) => now.difference(cached.at) > _ttl);
    while (_cache.length > _maxEntries) {
      String? oldestKey;
      DateTime? oldest;
      for (final entry in _cache.entries) {
        if (oldest == null || entry.value.at.isBefore(oldest)) {
          oldest = entry.value.at;
          oldestKey = entry.key;
        }
      }
      if (oldestKey == null) return;
      _cache.remove(oldestKey);
    }
  }
}

class _CachedPlayInfo {
  const _CachedPlayInfo(this.info, this.at);

  final PlayInfo info;
  final DateTime at;
}

/// m3u8 起播预热：用 HTTP GET 拿 master playlist，再并行预热 1–2 个子
/// playlist（等价于 HEAD 的连通性预热，还能让 CDN / DNS 提前命中）。
///
/// 整个预热有 2.2 秒硬预算，失败 / 超时静默返回，open 不会被拖慢。
class _FxHlsWarmup {
  static const Duration _budget = Duration(milliseconds: 1600);
  static const Duration _ttl = Duration(minutes: 8);
  static const int _segmentPrefetchBytes = 256 * 1024;
  static final Map<String, DateTime> _warmed = <String, DateTime>{};
  static final Map<String, Future<void>> _inflight = <String, Future<void>>{};

  static Future<void> prepare(
    String url,
    Map<String, String> headers,
  ) {
    if (url.isEmpty || !_looksLikeHls(url)) return Future<void>.value();
    // 离线缓存播的是本地 index.m3u8，不需要联网预热。
    final scheme = Uri.tryParse(url)?.scheme ?? '';
    if (scheme != 'http' && scheme != 'https') return Future<void>.value();
    final now = DateTime.now();
    final warmedAt = _warmed[url];
    if (warmedAt != null && now.difference(warmedAt) < _ttl) {
      return Future<void>.value();
    }
    final pending = _inflight[url];
    if (pending != null) return pending;
    final future = _warm(url, headers).timeout(_budget, onTimeout: () {});
    _inflight[url] = future;
    return future.whenComplete(() {
      if (identical(_inflight[url], future)) _inflight.remove(url);
      _warmed[url] = DateTime.now();
      _trimWarmed();
    });
  }

  /// 代理地址 / 带 query 的地址要解码后再判断，避免漏掉 .m3u8。
  static bool _looksLikeHls(String url) {
    final lower = Uri.decodeFull(url).toLowerCase();
    return lower.contains('.m3u8');
  }

  static Future<void> _warm(String url, Map<String, String> headers) async {
    final playlistUri = Uri.parse(url);
    final client = http.Client();
    try {
      // 先做 DNS 预解析，再拿 playlist；HTTP 连接也会复用这次解析结果。
      unawaited(_dnsPrefetch(playlistUri));
      final response = await client
          .get(playlistUri, headers: headers)
          .timeout(const Duration(milliseconds: 1200));
      if (response.statusCode < 200 || response.statusCode >= 400) return;
      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      if (!body.contains('#EXTM3U')) return;
      final variants = _variants(body, playlistUri);
      if (variants.isEmpty) {
        // 已经是媒体 playlist：直接取第一个分片的前 256KB 暖 CDN。
        final first = _firstSegment(body, playlistUri);
        if (first != null) unawaited(_prefetchFirstSegment(first, headers));
        return;
      }
      // master playlist：只等第一个子 playlist（拿到真实分片地址），
      // 第二个子 playlist 后台暖连接，不占用起播预算。
      final firstVariant = variants.first;
      final firstBody = await _fetchPlaylistText(client, firstVariant, headers);
      if (firstBody != null) {
        final first = _firstSegment(firstBody, firstVariant);
        if (first != null) unawaited(_prefetchFirstSegment(first, headers));
      }
      if (variants.length > 1) {
        unawaited(_warmVariant(variants[1], headers));
      }
    } catch (_) {
      // 预热失败不影响正常 open。
    } finally {
      client.close();
    }
  }

  static Future<String?> _fetchPlaylistText(
    http.Client client,
    Uri uri,
    Map<String, String> headers,
  ) async {
    try {
      unawaited(_dnsPrefetch(uri));
      final response = await client
          .get(uri, headers: headers)
          .timeout(const Duration(milliseconds: 800));
      if (response.statusCode < 200 || response.statusCode >= 400) return null;
      return utf8.decode(response.bodyBytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  /// 第二个码率只在后台暖连接，不占用等待时间。
  static Future<void> _warmVariant(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final client = http.Client();
    try {
      await _fetchPlaylistText(client, uri, headers);
    } finally {
      client.close();
    }
  }

  /// 取第一个分片的前 ~256KB：不保留响应，只为暖 CDN / DNS，
  /// 让 libmpv 真正请求首分片时更快命中缓存。
  static Future<void> _prefetchFirstSegment(
    Uri uri,
    Map<String, String> headers,
  ) async {
    unawaited(_dnsPrefetch(uri));
    final client = http.Client();
    try {
      final request = http.Request('GET', uri)
        ..headers.addAll(headers)
        ..headers['Range'] = 'bytes=0-${_segmentPrefetchBytes - 1}';
      final response =
          await client.send(request).timeout(const Duration(seconds: 2));
      if (response.statusCode >= 400) return;
      var received = 0;
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 2))) {
        received += chunk.length;
        if (received >= _segmentPrefetchBytes) break;
      }
    } catch (_) {
      // 预取失败不影响播放。
    } finally {
      client.close();
    }
  }

  static Future<void> _dnsPrefetch(Uri uri) async {
    final https = uri.isScheme('https');
    if (uri.host.isEmpty || !(https || uri.isScheme('http'))) return;
    try {
      await InternetAddress.lookup(uri.host)
          .timeout(const Duration(milliseconds: 800));
    } catch (_) {
      // DNS 失败交给真正请求时的系统解析。
    }
  }

  /// 从媒体 playlist 里取第一个分片地址，相对路径按 playlist 地址解析。
  static Uri? _firstSegment(String playlist, Uri base) {
    if (playlist.contains('#EXT-X-STREAM-INF')) return null;
    for (final raw in const LineSplitter().convert(playlist)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      return Uri.tryParse(base.resolve(line).toString());
    }
    return null;
  }

  /// 从 master playlist 里取前两个变体地址（相对路径按 playlist 地址解析）。
  static List<Uri> _variants(String playlist, Uri base) {
    final lines = const LineSplitter().convert(playlist);
    final variants = <Uri>[];
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].trimLeft().startsWith('#EXT-X-STREAM-INF')) continue;
      for (var j = i + 1; j < lines.length; j++) {
        final line = lines[j].trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        final uri = Uri.tryParse(base.resolve(line).toString());
        if (uri != null) variants.add(uri);
        break;
      }
    }
    return variants;
  }

  static void _trimWarmed() {
    if (_warmed.length <= 24) return;
    final now = DateTime.now();
    _warmed.removeWhere((_, at) => now.difference(at) > _ttl);
    while (_warmed.length > 24) {
      _warmed.remove(_warmed.keys.first);
    }
  }
}

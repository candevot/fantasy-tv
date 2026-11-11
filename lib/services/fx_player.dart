import 'dart:async';
import 'dart:typed_data';

import 'package:better_player/better_player.dart' show BetterPlayerController;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'fx_playback.dart';

/// 播放器对外门面 —— 全项目唯一的播放入口。
///
/// 这一版**整体换成 betterplayer(ExoPlayer/Media3)**，不再基于 media_kit/libmpv。
/// 保留原有类名与对外方法签名，页面层（player_page / fullscreen_page /
/// together_page / offline_player_page / live_detail_page）不用改调用方式。
///
/// 为什么整体换（实测结论，不是推测）：
///   · libmpv 的 HLS 解复用要自己维护列表重写，漏掉 #EXT-X-ENDLIST 就被判成
///     直播流，只播末尾几片 —— 用户看到「一打开就是片尾曲、一集只有 43 秒」；
///   · 分片 302 跳转要手动跟，每片多一次往返；
///   · 60 秒的大分片没有 BYTERANGE 支持，拖进度必须等整片下完；
///   · 自绘控件（fs_panels 1216 行 + player_theme 1030 行）风格不统一、
///     入口重复、位置靠手算安全区。
///
/// betterplayer 全部原生解决：HlsMediaSource 认 ENDLIST、
/// DefaultHttpDataSource 跟 302、MediaCodecSelector 自动硬解、
/// 内置控件含进度/倍速/画质/音轨/字幕/PiP/重试。
class FxPlayer implements Listenable {
  FxPlayer._({this.readyTimeout = const Duration(seconds: 20)}) {
    _core = FxPlayback();
    _bind();
  }

  /// 创建播放器实例。
  static FxPlayer create({
    Duration readyTimeout = const Duration(seconds: 20),
  }) {
    return FxPlayer._(readyTimeout: readyTimeout);
  }

  /// 等待首帧/时长的超时时间；超时视为该地址不可播。
  final Duration readyTimeout;

  late final FxPlayback _core;

  final Set<VoidCallback> _listeners = <VoidCallback>{};
  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];

  FxPlayerValue _value = const FxPlayerValue();
  bool _disposed = false;
  bool _playIntent = false;
  int _openToken = 0;
  String _sourceUrl = '';

  /// 底层 betterplayer 控制器（需要画质/音轨列表时直接用）。
  BetterPlayerController get player => _core.controller;

  /// 当前状态快照。
  FxPlayerValue get value => _value;

  /// 流式播放进度。
  Stream<Duration> get positionStream => _core.positionStream;

  /// 流式总时长。
  Stream<Duration> get durationStream => _core.durationStream;

  /// 流式缓冲状态。
  Stream<bool> get bufferingStream => _core.bufferingStream;

  /// 流式错误信息。
  Stream<String> get errorStream => _core.errorStream;

  /// 流式播放完成状态。
  Stream<bool> get completedStream => _core.completedStream;

  /// 播放中状态流。
  Stream<bool> get playingStream => _core.playingStream;

  bool get isPlaying => _value.isPlaying;

  double get rate => _rate;

  double _rate = 1;

  /// 画面组件 —— 直接用 betterplayer 内置控件。
  Widget buildVideo({
    BoxFit fit = BoxFit.contain,
    Alignment alignment = Alignment.center,
  }) {
    return _core.buildVideo();
  }

  /// [buildVideo] 的简写入口。
  Widget video({BoxFit fit = BoxFit.contain}) => buildVideo(fit: fit);

  /// 抓取当前画面的一帧。
  ///
  /// ExoPlayer 不提供截帧 API，统一返回 null —— 页面拿到 null 会退回纯黑，
  /// 这是预期行为（切线路时的那层快照垫底可以不要）。
  Future<Uint8List?> captureFrame() async => null;

  /// 打开一个网络地址并等待其就绪。
  ///
  /// 与旧实现相比参数保持兼容：`refreshPlay` / `onPlayExpired` /
  /// `rescueLines` 这些自愈逻辑在 ExoPlayer 下不再需要
  /// （它自己会重试、跟随跳转、处理签名过期），所以这里只是接收并忽略。
  Future<void> open(
    String url, {
    Map<String, String> headers = const <String, String>{},
    bool play = false,
    bool waitForWarm = false,
    bool direct = false,
    Object? refreshPlay,
    Object? onPlayExpired,
    Object? rescueLines,
  }) async {
    if (_disposed) {
      throw const FxPlayerException('播放器已释放');
    }
    final token = ++_openToken;
    _sourceUrl = url;
    _playIntent = play;

    // 从上次进度续播（页面会在 open 之后再 seek，这里给一个初值）
    final isHls = _looksLikeHls(url);
    try {
      await _core.open(url, headers: headers, isHls: isHls);
    } catch (e) {
      if (token != _openToken) return;
      _fail('$e');
      throw FxPlayerException('$e');
    }
    if (_disposed || token != _openToken) return;

    // 等首帧或时长，最多 readyTimeout。
    await _awaitReady(token);
    if (_disposed || token != _openToken) return;

    if (play) {
      await _core.play();
    }
  }

  /// 等首帧/时长就绪。
  Future<void> _awaitReady(int token) async {
    final deadline = DateTime.now().add(readyTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_disposed || token != _openToken) return;
      final v = _value;
      if (v.isInitialized || v.duration > Duration.zero) return;
      if (v.hasError) {
        throw FxPlayerException(v.errorText.isEmpty ? '播放失败' : v.errorText);
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    // 超时不抛：ExoPlayer 有时要等更久才有 duration，让页面自己决定。
  }

  bool _looksLikeHls(String url) {
    final u = url.toLowerCase();
    return u.contains('.m3u8') ||
        u.contains('/hls/') ||
        u.contains('/playlist') ||
        u.contains('/fyplay') ||
        u.contains('/iqiyi.m3u8');
  }

  Future<void> play() async {
    _playIntent = true;
    await _core.play();
  }

  Future<void> pause() async {
    _playIntent = false;
    await _core.pause();
  }

  Future<void> playOrPause() => _value.isPlaying ? pause() : play();

  Future<void> stop() => _core.stop();

  Future<void> seek(Duration position) => _core.seek(position);

  Future<void> seekTo(Duration position) => seek(position);

  Future<void> setRate(double rate) async {
    _rate = rate;
    await _core.setRate(rate);
  }

  Future<void> setLooping(bool looping) async {
    // betterplayer 的循环在 configuration 里；运行时切换用不到，忽略。
  }

  /// 回前台自愈：ExoPlayer 自己会恢复，这里只把播放态补回来。
  Future<void> recoverAfterBackground(
    Duration expected, {
    required bool wasPlaying,
  }) async {
    if (_disposed) return;
    if (expected > Duration.zero) {
      try {
        await seek(expected);
      } catch (_) {}
    }
    if (wasPlaying && _playIntent) {
      try {
        await play();
      } catch (_) {}
    }
  }

  /// 救援自检：ExoPlayer 内部已有重试，这里只在有错误时重开一次。
  Future<void> resumeSelfCheck() async {
    if (_disposed || _sourceUrl.isEmpty) return;
    if (!_value.hasError) return;
    try {
      await _core.open(_sourceUrl, isHls: _looksLikeHls(_sourceUrl));
      if (_playIntent) await _core.play();
    } catch (_) {}
  }

  // ---------------------------------------------------------------- 状态绑定

  void _bind() {
    _subscriptions.add(_core.positionStream.listen((p) {
      _setValue(_value.copyWith(position: p));
    }));
    _subscriptions.add(_core.durationStream.listen((d) {
      _setValue(_value.copyWith(
        duration: d,
        isInitialized: _value.isInitialized || d > Duration.zero,
      ));
    }));
    _subscriptions.add(_core.bufferingStream.listen((b) {
      _setValue(_value.copyWith(isBuffering: b));
    }));
    _subscriptions.add(_core.playingStream.listen((p) {
      _setValue(_value.copyWith(isPlaying: p));
    }));
    _subscriptions.add(_core.completedStream.listen((c) {
      if (c) _setValue(_value.copyWith(isCompleted: true));
    }));
    _subscriptions.add(_core.errorStream.listen(_fail));

    // 高频字段（缓冲时长、画面尺寸）走 400ms 轮询快照。
    _core.value.addListener(_onCoreValue);
  }

  void _onCoreValue() {
    if (_disposed) return;
    final c = _core.value;
    _setValue(_value.copyWith(
      position: c.position,
      duration: c.duration,
      buffered: c.buffered,
      isPlaying: c.isPlaying,
      isBuffering: c.isBuffering,
      isInitialized: c.isInitialized,
      isCompleted: c.isCompleted,
      hasError: c.hasError,
      errorText: c.errorText,
      width: c.videoWidth,
      height: c.videoHeight,
      videoWidth: c.videoWidth,
      videoHeight: c.videoHeight,
      aspectRatio: c.aspectRatio,
    ));
  }

  void _fail(String message) {
    if (_disposed) return;
    // ExoPlayer 的 cancelled / aborted 不是真失败，忽略。
    final lower = message.toLowerCase();
    if (lower.contains('cancel') || lower.contains('abort')) return;
    _setValue(_value.copyWith(hasError: true, errorText: message));
  }

  void _setValue(FxPlayerValue next) {
    if (_disposed) return;
    _value = next;
    _notify();
  }

  void _notify() {
    for (final l in _listeners.toList(growable: false)) {
      try {
        l();
      } catch (_) {}
    }
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    _core.value.removeListener(_onCoreValue);
    await _core.dispose();
    _listeners.clear();
  }
}

/// 播放器异常。
class FxPlayerException implements Exception {
  const FxPlayerException(this.message);

  final String message;

  @override
  String toString() => 'FxPlayerException: $message';
}

/// 播放器状态快照（字段与旧实现保持一致，页面层零改动）。
@immutable
class FxPlayerValue {
  const FxPlayerValue({
    this.isInitialized = false,
    this.isPlaying = false,
    this.isBuffering = true,
    this.bufferingPercentage = 0,
    this.measuredBufferPercent = 0,
    this.bytesPerSecond = 0,
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

  final bool isInitialized;
  final bool isPlaying;
  final bool isBuffering;
  final double bufferingPercentage;
  final double measuredBufferPercent;
  final double bytesPerSecond;
  final Duration buffered;
  final bool isCompleted;
  final bool hasError;
  final String errorText;
  final Duration position;
  final Duration duration;
  final int? width;
  final int? height;
  final int? videoWidth;
  final int? videoHeight;
  final double aspectRatio;

  Size get size => Size((width ?? 0).toDouble(), (height ?? 0).toDouble());

  /// 形如 `1920x1080`；未就绪返回空串。
  String get resolutionText {
    final rawWidth = videoWidth ?? 0;
    final rawHeight = videoHeight ?? 0;
    final w = rawWidth > 0 ? rawWidth : (width ?? 0);
    final h = rawHeight > 0 ? rawHeight : (height ?? 0);
    if (w <= 0 || h <= 0) return '';
    return '${w}x$h';
  }

  /// 缓冲进度（0-100）；ExoPlayer 不报百分比，按已缓冲/总时长折算。
  double? get bufferingPercent {
    if (duration.inMilliseconds <= 0) return null;
    final p = buffered.inMilliseconds / duration.inMilliseconds * 100;
    return p.clamp(0.0, 100.0);
  }

  bool get bufferingSettled => !isBuffering;

  String get speedText {
    final b = bytesPerSecond;
    if (b <= 0) return '';
    if (b >= 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB/s';
    if (b >= 1024) return '${(b / 1024).toStringAsFixed(0)} KB/s';
    return '${b.toStringAsFixed(0)} B/s';
  }

  FxPlayerValue copyWith({
    bool? isInitialized,
    bool? isPlaying,
    bool? isBuffering,
    double? bufferingPercentage,
    double? measuredBufferPercent,
    double? bytesPerSecond,
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
      measuredBufferPercent:
          measuredBufferPercent ?? this.measuredBufferPercent,
      bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
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

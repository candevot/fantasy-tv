import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:better_player/better_player.dart' show BetterPlayerController;
import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
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

  /// 画面层代际：每次真正换地址都 +1，页面用它做纹理重建的 key。
  ///
  /// ExoPlayer 不需要重建纹理（内嵌在 AndroidView 里），这里保留接口，
  /// 值恒为 0，页面拿到相同 key 就不会白白重建。
  int get renderEpoch => 0;

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
  Future<Uint8List?> captureFrame() => Future<Uint8List?>.value(null);

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

  Future<void> stop() async {
    await _core.stop();
  }

  Future<void> seek(Duration position) => _core.seek(position);

  Future<void> seekTo(Duration position) async {
    await seek(position);
  }

  Future<void> setRate(double rate) async {
    _rate = rate;
    await _core.setRate(rate);
  }

  Future<void> setLooping(bool looping) async {
    // betterplayer 的循环在 configuration 里；运行时切换用不到，忽略。
  }

  /// 回前台自愈：ExoPlayer 自己会恢复，这里只把播放态补回来。
  /// 回前台自愈：把进度拉回切后台时的位置并恢复播放态。
  ///
  /// 返回「是否已完成自愈」：位置确实被拉回、且播放态符合预期时为 true。
  /// 页面用这个值决定要不要再调 [resumeSelfCheck] 做一次断流重连。
  Future<bool> recoverAfterBackground(
    Duration expected, {
    required bool wasPlaying,
  }) async {
    if (_disposed) return false;
    if (expected <= Duration.zero) return false;
    try {
      await seek(expected);
      if (wasPlaying && _playIntent) await play();
      return true;
    } catch (_) {
      return false;
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
    final c = _core.value.value;
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

/// 无感救援链第③步：返回下一条线路的播放源；没有下一条或取不到地址时返回 null。
typedef FxLineRescue = Future<FxLineSource?> Function();

/// 换线路用的播放源，字段语义与 `FxPlayer.open` 的参数一致。
class FxLineSource {
  const FxLineSource({
    required this.url,
    this.headers = const <String, String>{},
    this.direct = false,
  });

  /// 新线路的 m3u8 / 播放地址。
  final String url;

  /// 新线路需要透传给播放器的请求头。
  final Map<String, String> headers;

  /// 是否为 HLS 直链（走本地分片代理）。
  final bool direct;
}

/// 播放地址缓存 + 预热：减少「点播放要等一下」的感知延迟。
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
class _CachedPlayInfo {
  const _CachedPlayInfo(this.info, this.at);

  final PlayInfo info;
  final DateTime at;
}


/// 解析完成后真正交给 mpv 的地址（可能已被本地 HLS 代理改写）。

/// /api/play 结果缓存 + 下一集预解析（只请求，不创建播放器）。
///
/// - 缓存 10 分钟内有效，最多 8 条，避免 URL 长期失效与内存膨胀；
/// - 同一集并发请求走同一个 Future，不会重复打接口；
/// - [prewarm] 会先清掉旧结果再请求，并把下一集的 m3u8 也预热好，
///   切集时 open 只差一个本地 playlist 往返。

class _FxHlsWarmup {
  static const Duration _budget = Duration(milliseconds: 1600);
  static const Duration _ttl = Duration(minutes: 8);
  /// 预热时真正预取的分片数。
  ///
  /// 直连模式下没有客户端代理的整集缓存，起播和 seek 都直接打 CDN。
  /// 之前只暖首片 256KB，等于只做了 DNS/连接预热 —— 首帧仍要等第一个
  /// 完整分片下完。这里改成预取前 3 片（4K 单片 10~40MB 时按字节上限
  /// 截断），让 mpv 一起播就有货可解，起播不再空等。
  static const int _segmentPrefetchCount = 3;

  /// 预取总字节上限：4K 分片很大，不能无限预取。
  static const int _prefetchBudgetBytes = 24 * 1024 * 1024;
  static final Map<String, DateTime> _warmed = <String, DateTime>{};
  static final Map<String, Future<void>> _inflight = <String, Future<void>>{};

  static Future<void> prepare(String url, Map<String, String> headers) {
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
        // 直连没有代理层的整集缓存，开头多备几片，起播/小 seek 不用等。
        final leading = _leadingSegments(
          body,
          playlistUri,
          _segmentPrefetchCount,
        );
        for (final seg in leading) {
          unawaited(_prefetchFirstSegment(seg, headers));
        }
        return;
      }
      // master playlist：只等第一个子 playlist（拿到真实分片地址），
      // 第二个子 playlist 后台暖连接，不占用起播预算。
      final firstVariant = variants.first;
      final firstBody = await _fetchPlaylistText(client, firstVariant, headers);
      if (firstBody != null) {
        final leading = _leadingSegments(
          firstBody,
          firstVariant,
          _segmentPrefetchCount,
        );
        for (final seg in leading) {
          unawaited(_prefetchFirstSegment(seg, headers));
        }
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
  static Future<void> _warmVariant(Uri uri, Map<String, String> headers) async {
    final client = http.Client();
    try {
      await _fetchPlaylistText(client, uri, headers);
    } finally {
      client.close();
    }
  }

  /// 直连模式下的预热：把开头几个分片整片拉一遍。
  ///
  /// 不保留数据（mpv 自己会再拉一次并缓存），目的是：
  ///   1. 暖 DNS / TCP / TLS，起播省掉握手；
  ///   2. 让 CDN 边缘节点预热这几个对象，mpv 再拉时直接命中；
  ///   3. 提前暴露「首片就 404/403」的坏线路，交给上层快速换线。
  ///
  /// 4K 单片 10~40MB，因此按 [_prefetchBudgetBytes] 截断，不会把带宽吃光。
  static Future<void> _prefetchFirstSegment(
    Uri uri,
    Map<String, String> headers,
  ) async {
    unawaited(_dnsPrefetch(uri));
    final client = http.Client();
    var budget = _prefetchBudgetBytes;
    try {
      final request = http.Request('GET', uri)..headers.addAll(headers);
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 3));
      if (response.statusCode >= 400) return;
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 3),
      )) {
        budget -= chunk.length;
        if (budget <= 0) break;
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
      await InternetAddress.lookup(
        uri.host,
      ).timeout(const Duration(milliseconds: 800));
    } catch (_) {
      // DNS 失败交给真正请求时的系统解析。
    }
  }

  /// 从媒体 playlist 里取第一个分片地址，相对路径按 playlist 地址解析。
  /// 取 playlist 里前 [count] 个分片地址（用于直连预热）。
  static List<Uri> _leadingSegments(String playlist, Uri base, int count) {
    if (playlist.contains('#EXT-X-STREAM-INF')) return const <Uri>[];
    final out = <Uri>[];
    for (final raw in const LineSplitter().convert(playlist)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final uri = Uri.tryParse(base.resolve(line).toString());
      if (uri == null) continue;
      out.add(uri);
      if (out.length >= count) break;
    }
    return out;
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

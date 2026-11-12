import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// ExoPlayer(Media3) 内核的 Dart 封装。
///
/// 为什么需要它：libmpv 在 HLS 上有几个绕不过去的坑 ——
///   · 播放列表重写时容易丢 #EXT-X-ENDLIST，被误判成直播（4K 只播 19 秒）
///   · 分片 302 跳转要自己处理，每片多一次往返
///   · 4K 高码率的自适应缓冲不成熟
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
  }) async {
    if (_disposed || !isSupported) return false;
    _error = null;
    try {
      final r = await _method.invokeMethod<bool>('open', {
        'url': url,
        'headers': headers,
        'isHls': isHls,
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
    this.playing = false,
    this.buffering = true,
    this.error,
  });

  final Duration position;
  final Duration duration;
  final Duration buffered;
  final bool playing;
  final bool buffering;
  final String? error;

  factory ExoPlayerState.fromMap(Map<String, dynamic> m) {
    Duration d(String k) =>
        Duration(milliseconds: (m[k] as num?)?.toInt() ?? 0);
    return ExoPlayerState(
      position: d('positionMs'),
      duration: d('durationMs'),
      buffered: d('bufferedMs'),
      playing: m['playing'] == true,
      buffering: m['buffering'] == true,
      error: m['error'] as String?,
    );
  }

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
      'playing=$playing, buffering=$buffering, err=$error)';
}

/// 画面视图：把 Android 的 PlayerView 嵌进 Flutter。
///
/// 只在 [ExoPlayerEngine.isSupported] 时可用；其它平台返回占位。
class ExoPlayerView extends StatelessWidget {
  const ExoPlayerView({super.key});

  @override
  Widget build(BuildContext context) {
    if (!ExoPlayerEngine.isSupported) {
      return const ColoredBox(color: Color(0xFF000000));
    }
    return AndroidView(
      viewType: ExoPlayerEngine.viewType,
      // PlayerView 自己处理比例，这里铺满由 RESIZE_MODE_FIT 决定
      creationParams: const <String, dynamic>{},
      creationParamsCodec: const StandardMessageCodec(),
    );
  }
}

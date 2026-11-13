import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../api.dart';
import '../models.dart';
import 'exo_player.dart';
import 'local_hls_proxy.dart';
import 'playback_recovery.dart';

/// FxPlayer 打开/播放失败时抛出的异常，调用方可据此尝试备用地址。
class FxPlayerException implements Exception {
  const FxPlayerException(this.message);

  final String message;

  @override
  String toString() => 'FxPlayerException: $message';
}

/// 无感救援链第③步：返回下一条线路的播放源；没有下一条或取不到地址时
/// 返回 null。回调必须静默执行（只请求接口，不弹 UI），耗时建议 ≤10s。
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

  /// 新线路需要透传给 mpv 的请求头。
  final Map<String, String> headers;

  /// 是否为 HLS 直链（走本地分片代理）。
  final bool direct;
}

/// 播放器状态快照。
///
/// 字段刻意对齐 video_player 的 `VideoPlayerValue` 常用子集，
/// 方便从旧播放内核平滑迁移，同时补充解码后的原始宽高信息。
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
    this.bytesPerSecond = 0,
    this.measuredBufferPercent = 0,
  });

  /// 是否已经拿到视频参数/时长，可以开始渲染与 seek。
  final bool isInitialized;

  /// 是否正在播放。
  final bool isPlaying;

  /// 是否正在缓冲。
  final bool isBuffering;

  /// libmpv 的真实缓冲百分比（cache-buffering-state，0–100）。
  ///
  /// 注意：这个值在缓存快满时会长期停在 99，**不能直接拿去当进度环**，
  /// 否则界面永远显示「缓冲中 99%」（用户报障原话）。起播进度请用
  /// [measuredBufferPercent]。
  final double bufferingPercentage;

  /// 起播缓冲进度（0–100，按真实下载字节算，能到 100）。
  ///
  /// 与 [bufferingPercentage] 的区别：这个是「为了起播还差多少」，
  /// 由代理层已下载字节 / 起播目标字节得出，涨到头就是 100 并结束。
  final double measuredBufferPercent;

  /// 实时下载速度（字节/秒）；0 表示还没测到。
  final double bytesPerSecond;

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
  Size get size => Size((width ?? 0).toDouble(), (height ?? 0).toDouble());

  /// 形如 `1920x1080` 的分辨率文案；未就绪时返回空串。
  String get resolutionText {
    final rawWidth = videoWidth ?? 0;
    final rawHeight = videoHeight ?? 0;
    final w = rawWidth > 0 ? rawWidth : (width ?? 0);
    final h = rawHeight > 0 ? rawHeight : (height ?? 0);
    if (w <= 0 || h <= 0) return '';
    return '${w}x$h';
  }

  /// 真实缓冲进度（0–99）；拿不到时返回 null，UI 显示不带数字的转圈。
  ///
  /// 只用 libmpv 的 `cache-buffering-state`：本次缓冲需要把缓存填到的
  /// 百分比，0→100 填满即恢复播放，是唯一随缓冲真实推进的进度。
  /// 「已缓存时长 ÷ 总时长」只是全片下载比例——停在百分之十几、缓存够了
  /// 又瞬间跳满，看起来像假进度，不再拿来显示数字。
  double? get bufferingPercent {
    if (measuredBufferPercent > 0) {
      return measuredBufferPercent.clamp(0.0, 100.0);
    }
    // BUFFER_PCT_FIX（2026-11-13）：不再用 mpv 的 cache-buffering-state。
    //
    // 那个值的分母是 demuxer-max-bytes（我们设 192MB），
    // 4K 要真的下满 192MB 才会到 100 —— 永远到不了，界面就长期
    // 停在「缓冲 99%」。用户报障原话就是「缓冲卡 99」。
    //
    // 改成按「已缓冲时长 ÷ 起播需要的最小缓冲」算，涨到 100 就是能播了：
    //   · 起播 / 卡顿恢复都按 2 秒算（cache-pause-wait 已改成 0.5 秒）
    const needSec = 2.0;
    final haveSec = buffered.inMilliseconds / 1000.0;
    if (haveSec <= 0) return null;
    return (haveSec / needSec * 100).clamp(0.0, 100.0);
  }

  /// 起播进度是否已经到顶（可以隐藏进度环）。
  ///
  /// 原来只看 measuredBufferPercent（代理层按字节算的），
  /// 直连模式下它恒为 0 → 永远判成未就绪。现在按已缓冲时长兜底。
  bool get bufferingSettled {
    if (measuredBufferPercent >= 100) return true;
    return buffered.inMilliseconds >= 2000;
  }

  /// 把字节/秒格式化成「3.2 MB/s」这类文案；0 返回空串。
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

/// 基于 ExoPlayer（Android Media3）的播放内核封装。
///
/// PLAYER_CORE（2026-11-13）：内核从 libmpv 换成 ExoPlayer，控件完全不变 ——
/// 页面只拿到一个画面视图，进度条 / 弹幕 / 选集 / 手势全部还是我们自绘的。
/// 参考 FongMi/TV：它也是 ExoPlayer 内核 + 自绘控件。
///
/// 保留的东西（这些是稳定性的来源，跟内核无关）：
///   · 无感救援链：①换签名 ②同地址重开 ③换下一条线路，全程静默
///   · 无字节流动看门狗：连续 30 秒没进展才进救援，缓冲中不算失败
///   · HLS 起播预热：DNS + playlist + 前几片
///   · 高频位置通道：进度条 / 弹幕独立订阅，不跟着整对象重建
///
/// 去掉的东西（ExoPlayer 原生就解决了，不需要我们再管）：
///   · demuxer-readahead-secs / cache-pause-wait / cache-buffering-state
///     那一整套 mpv 属性 —— 这是「加载慢 / 黑屏 / 卡 99」的根源。
///     ExoPlayer 的 DefaultLoadControl 按**时长**缓冲，自己调度分片。
class FxPlayer implements Listenable {
  FxPlayer._({this.readyTimeout = const Duration(seconds: 20)}) {
    _engine = ExoPlayerEngine();
    _engine.state.addListener(_onEngineState);
    unawaited(_engine.init());
    // STATE_POLL（2026-11-14）：不能只等 EventChannel 的事件。
    //
    // 实测症状：画面已经出来了（ExoPlayer 在播），但 Dart 侧状态一直是
    // 初始值（buffering=true / position=0）——
    //   · UI 上「缓冲中」永远不消失
    //   · open() 等不到首帧，30 秒后判失败，用户看到「线路播不出来」
    // 原因就是事件没送达漏了。这里加 500ms 轮询兜底，
    // 直接调内核的 state 方法取快照，事件通道只当加速用。
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_disposed) return;
      unawaited(_engine.poll());
    });
    // 稳定性看门狗：只看「进度 / 缓冲是否还在动」，缓冲中不算失败。
    _watchdogTimer = Timer.periodic(
      _watchdogTick,
      (_) => unawaited(_watchdogTickAsync()),
    );
  }

  /// 起播「还在进展」时的最长等待：只要还在往下拉就一直等，
  /// 避免把「大分片加载慢」误判成「线路不可用」并自动换线。
  static const Duration _openHardCap = Duration(minutes: 2);

  /// 看门狗采样间隔。ExoPlayer 的状态事件本来就不密，4 秒够。
  static const Duration _watchdogTick = Duration(seconds: 4);

  /// 停摆判定门槛：连续这么久完全没有进度 / 缓冲推进才算失败候选。
  static const Duration _stallTimeout = Duration(seconds: 30);

  /// 救援链里 refreshPlay / 同地址 reopen 各自先试几次。
  static const int _rescueTries = 2;

  /// 设备物理内存（MB）；拿不到返回 0。
  static int _deviceMemoryMb() {
    try {
      final info = File('/proc/meminfo').readAsStringSync();
      final m = RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(info);
      if (m == null) return 0;
      return (int.parse(m.group(1)!) / 1024).round();
    } catch (_) {
      return 0;
    }
  }

  /// 同一次播放最多进几轮救援链。没有这个上限时，每轮救援结束都会
  /// 重置 _lastFlowAt，于是又能再等 30 秒 → 再救 → 再等，表现就是
  /// 「一直卡在那几秒、一直循环」。超过上限就把错误交给页面。
  static const int _maxRescueRounds = 3;

  /// 救援重开时等待新流就绪的上限。
  static const Duration _rescueOpenTimeout = Duration(seconds: 8);

  /// 创建播放器实例。
  static FxPlayer create({
    Duration readyTimeout = const Duration(seconds: 20),
  }) {
    return FxPlayer._(readyTimeout: readyTimeout);
  }

  /// 打开地址后等首帧的最长时间。
  final Duration readyTimeout;

  late final ExoPlayerEngine _engine;

  final Set<VoidCallback> _listeners = <VoidCallback>{};

  FxPlayerValue _value = const FxPlayerValue();
  bool _disposed = false;
  bool _playIntent = false;
  int _decodeErrorSerial = 0;

  /// 上一次已经处理过的内核错误文案（去重用，open 时清空）。
  String _lastHandledError = '';
  int _openToken = 0;

  /// 画面层代际：每次真正 open（含救援链重开）都 +1。
  int _renderEpoch = 0;

  /// 当前画面层代际；页面在监听回调里比对它来决定是否重建画面。
  int get renderEpoch => _renderEpoch;
  Completer<void>? _ready;

  // ------------------------------------------------- 看门狗 / 救援链状态

  Timer? _watchdogTimer;

  /// 内核状态轮询（事件通道的兜底）。
  Timer? _pollTimer;
  DateTime _lastFlowAt = DateTime.now();
  int _rescueRounds = 0;
  Duration _lastFlowPos = Duration.zero;
  Duration _lastFlowBuffered = Duration.zero;
  int _lastFlowState = -1;

  /// 救援链正在执行（防止看门狗 / 错误事件重复进入）。
  bool _rescueBusy = false;

  /// 救援代际：新的 open / dispose 会推进它，进行中的救援立即让位。
  int _rescueGen = 0;

  /// 救援重开期间把进度显示钉在原位置，避免 UI / 进度回写读到 0。
  bool _rescueHold = false;

  /// 停摆期间我们主动点亮的「缓冲中」，恢复后要自己熄灭。
  bool _stallIndicated = false;

  /// 救援重开时等待新流就绪的信号。
  Completer<void>? _mediaReady;

  // ------------------------------------------------------ 当前播放源信息

  String _sourceUrl = '';
  Map<String, String> _sourceHeaders = const <String, String>{};
  bool _sourceDirect = false;
  PlayUrlRefresher? _refreshPlay;
  PlayExpiredCallback? _onPlayExpired;
  FxLineRescue? _lineRescue;

  /// 正在执行的 open（url+headers）：同一地址并发 open 直接复用，防重复。
  _OpenRequest? _opening;

  /// 直链 HLS 的本地分片代理；只在 direct 模式下懒创建。
  LocalHlsProxy? _hlsProxy;

  /// 高频播放位置通道（每 50~200ms 更新一次）。
  final ValueNotifier<Duration> _positionNotifier =
      ValueNotifier<Duration>(Duration.zero);

  /// 高频位置（供进度条 / 弹幕订阅）。
  ValueListenable<Duration> get positionListenable => _positionNotifier;

  /// 是否启用本地 HLS 代理。默认 false —— 让播放器直连，
  /// 和 FongMi/TV 的做法一致（ExoPlayer 原生 HLS 比我们再套一层代理稳）。
  static const bool _enableLocalHlsProxy = false;

  /// 底层内核。需要高级能力（缓冲统计等）时可直接使用。
  ExoPlayerEngine get player => _engine;

  /// 当前状态快照。
  FxPlayerValue get value => _value;

  /// 流式播放进度。
  Stream<Duration> get positionStream => _positionCtrl.stream;
  Stream<Duration> get durationStream => _durationCtrl.stream;
  Stream<bool> get bufferingStream => _bufferingCtrl.stream;
  Stream<String> get errorStream => _errorCtrl.stream;
  Stream<bool> get completedStream => _completedCtrl.stream;
  Stream<bool> get playingStream => _playingCtrl.stream;

  final StreamController<Duration> _positionCtrl =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _durationCtrl =
      StreamController<Duration>.broadcast();
  final StreamController<bool> _bufferingCtrl =
      StreamController<bool>.broadcast();
  final StreamController<String> _errorCtrl =
      StreamController<String>.broadcast();
  final StreamController<bool> _completedCtrl =
      StreamController<bool>.broadcast();
  final StreamController<bool> _playingCtrl =
      StreamController<bool>.broadcast();

  /// 画面组件：PlatformView 承载 ExoPlayer 的 PlayerView，
  /// 内置控件已关（useController=false），全部交给页面自绘。
  Widget buildVideo({
    BoxFit fit = BoxFit.contain,
    Alignment alignment = Alignment.center,
  }) {
    // BoxFit → Media3 的缩放模式。不映射的话 PlayerView 永远按 FIT 缩放，
    // 「铺满」「拉伸」两个档位会失效。
    final mode = switch (fit) {
      BoxFit.cover => exoResizeZoom,
      BoxFit.fill => exoResizeFill,
      _ => exoResizeFit,
    };
    return ColoredBox(
      color: Colors.black,
      // 只按缩放模式做 key：切集 / 换线路**不重建** PlatformView。
      // ExoPlayer 的 PlayerView 一直绑着同一个内核实例，重建只会多一次
      // 纹理重新挂载，用户看到的就是切换瞬间的黑一下。
      child: ExoPlayerView(
        key: ValueKey<String>('exo-surface-$mode'),
        resizeMode: mode,
      ),
    );
  }

  /// [buildVideo] 的简写入口。
  Widget video({BoxFit fit = BoxFit.contain}) => buildVideo(fit: fit);

  /// ExoPlayer 没有截帧接口：返回 null，页面退回纯黑垫片。
  Future<Uint8List?> captureFrame() async => null;

  /// 打开一个网络地址并等待其就绪。
  Future<void> open(
    String url, {
    Map<String, String> headers = const <String, String>{},
    bool play = false,
    bool waitForWarm = false,
    bool direct = false,
    PlayUrlRefresher? refreshPlay,
    PlayExpiredCallback? onPlayExpired,
    FxLineRescue? rescueLines,
  }) {
    if (_disposed) {
      return Future<void>.error(const FxPlayerException('播放器已释放'));
    }
    final key = _openKey(url, headers, direct);
    final pending = _opening;
    if (pending != null && pending.key == key) return pending.future;
    final future = _openInternal(
      url,
      headers,
      play,
      waitForWarm,
      direct,
      refreshPlay,
      onPlayExpired,
      rescueLines,
    );
    final request = _OpenRequest(key, future);
    _opening = request;
    return future.whenComplete(() {
      if (identical(_opening, request)) _opening = null;
    });
  }

  static String _openKey(String url, Map<String, String> headers, bool direct) {
    final suffix = direct ? '|direct=1' : '';
    if (headers.isEmpty) return '$url$suffix';
    final entries =
        headers.entries.map((entry) => '${entry.key}=${entry.value}').toList()
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
    FxLineRescue? rescueLines,
  ) async {
    _playIntent = play;
    final token = ++_openToken;
    _rescueGen++;
    _rescueBusy = false;
    _rescueHold = false;
    _rescueRounds = 0;
    _lastFlowPos = Duration.zero;
    _lastFlowBuffered = Duration.zero;
    _lastFlowState = -1;
    _lastBufferedMs = -1;
    _lastSpeedAt = DateTime.now();
    _lastHandledError = '';
    _value = const FxPlayerValue();
    _notify();
    _sourceUrl = url;
    _sourceHeaders = headers;
    _sourceDirect = direct;
    _refreshPlay = refreshPlay;
    _onPlayExpired = onPlayExpired;
    _lineRescue = rescueLines;
    final ready = Completer<void>();
    _ready = ready;
    unawaited(ready.future.catchError((Object _) {}));
    try {
      final source = await _resolvePlaybackSource(
        url,
        headers,
        direct: direct,
        token: token,
        waitForWarm: waitForWarm,
      );
      if (source == null) {
        if (identical(_ready, ready)) _ready = null;
        return;
      }
      await _openMedia(source, play: play, token: token).timeout(_openHardCap);
    } catch (error) {
      if (_disposed || token != _openToken) {
        if (identical(_ready, ready)) _ready = null;
        return;
      }
      if (identical(_ready, ready)) _ready = null;
      _fail('$error');
      throw FxPlayerException('$error');
    }
    if (_disposed || token != _openToken) return;
    try {
      await _awaitReadyOrProgress(ready.future, token);
    } finally {
      if (identical(_ready, ready)) _ready = null;
    }
  }

  /// 等首帧，但把「还在下载」和「卡死」区分开。
  ///
  /// 判据是 ExoPlayer 上报的缓冲位置 / 播放位置：在动就说明线路活着，
  /// 继续等；连续 [_stallTimeout] 纹丝不动才算这次 open 失败。
  Future<void> _awaitReadyOrProgress(Future<void> ready, int token) async {
    final startedAt = DateTime.now();
    var lastMs = -1;
    var lastProgressAt = DateTime.now();
    while (true) {
      if (_disposed || token != _openToken) return;
      try {
        await ready.timeout(const Duration(seconds: 1));
        return; // 首帧到了
      } on TimeoutException {
        // 还没好，继续看有没有进展。
      }
      if (_disposed || token != _openToken) return;

      final st = _engine.state.value;
      final ms = st.buffered.inMilliseconds + st.position.inMilliseconds;
      final now = DateTime.now();
      if (ms > lastMs) {
        lastMs = ms;
        lastProgressAt = now;
      }
      if (now.difference(lastProgressAt) >= _stallTimeout) {
        _logFx('OPEN 放弃：${_stallTimeout.inSeconds}s 无进展');
        _fail('播放超时，线路可能不可用');
        throw const FxPlayerException('播放超时');
      }
      if (now.difference(startedAt) >= _openHardCap) {
        _logFx('OPEN 放弃：超过硬上限 ${_openHardCap.inSeconds}');
        _fail('播放超时，线路可能不可用');
        throw const FxPlayerException('播放超时');
      }
    }
  }

  /// 解析出真正交给内核的地址：直链先过本地分片代理（默认关闭），
  /// 非代理路径做 m3u8 预热。返回 null = 这次 open 已被取代。
  Future<_PlaybackSource?> _resolvePlaybackSource(
    String url,
    Map<String, String> headers, {
    required bool direct,
    required int token,
    required bool waitForWarm,
  }) async {
    var playbackUrl = url;
    var playbackHeaders = headers;
    var proxied = false;
    final useLocalProxy = _enableLocalHlsProxy;
    if (direct && useLocalProxy) {
      final proxy = _hlsProxy ??= LocalHlsProxy(
        log: debugPrint,
        cacheLimitBytes: _proxyCacheLimit,
      );
      try {
        final localUrl = await proxy
            .proxy(
              url,
              headers,
              refreshPlay: _refreshPlay,
              onPlayExpired: _onPlayExpired == null
                  ? null
                  : () {
                      if (_disposed || token != _openToken) return;
                      final expired = _onPlayExpired;
                      if (expired != null) expired();
                    },
            )
            .timeout(const Duration(seconds: 15));
        if (_disposed || token != _openToken) return null;
        if (localUrl.isNotEmpty) {
          playbackUrl = localUrl;
          playbackHeaders = const <String, String>{};
          proxied = true;
        }
      } catch (error) {
        debugPrint('FxPlayer: 本地 HLS 代理本次启动失败，回退直连: $error');
      }
    }
    if (_disposed || token != _openToken) return null;

    if (!proxied) {
      final warmup = _FxHlsWarmup.prepare(url, headers);
      if (waitForWarm) {
        await warmup;
      } else {
        unawaited(warmup);
      }
    }
    if (_disposed || token != _openToken) return null;
    return _PlaybackSource(playbackUrl, playbackHeaders);
  }

  /// 本地代理缓存上限：按设备内存的 1/8，夹在 512MB~2GB。
  static int get _proxyCacheLimit {
    final total = _deviceMemoryMb();
    if (total <= 0) return 512 * 1024 * 1024;
    final bytes = (total * 1024 * 1024) ~/ 8;
    return bytes.clamp(512 * 1024 * 1024, 2 * 1024 * 1024 * 1024);
  }

  /// 把地址交给连接器内核。
  Future<void> _openMedia(
    _PlaybackSource source, {
    required bool play,
    required int token,
  }) async {
    if (_disposed || token != _openToken) {
      throw StateError('open 已被新的播放请求取代');
    }
    final isHls = _looksLikeHls(source.url);
    final ok = await _engine.open(
      source.url,
      headers: source.headers,
      isHls: isHls,
    );
    if (_disposed || token != _openToken) {
      throw StateError('open 已被新的播放请求取代');
    }
    if (!ok) {
      throw FxPlayerException(_engine.error ?? '播放器打开失败');
    }
    // 内核在 open 时会把 lastError 清空，Dart 侧的去重标记也要跟着清，
    // 否则救援重开之后同类错误会被当成「已处理过」而漏掉。
    _lastHandledError = '';
    if (play) {
      await _engine.play();
    }
    _renderEpoch++;
    _notify();
    _lastFlowAt = DateTime.now();
  }

  /// 判断是不是 HLS 播放列表。
  ///
  /// HLS_TYPE_FIX（2026-11-14）：不能只看 `.m3u8` 后缀。
  /// 幻想4K / 幻想蓝光的地址是服务端包装过的 `/api/fyplay?u=…`，
  /// 里面没有 m3u8 字样，但返回的正文就是 m3u8。之前这里判成 false，
  /// 交给 ProgressiveMediaSource 解析 → 直接失败，
  /// 表现就是「除了解析线路，其它线路都播不出来」。
  static bool _looksLikeHls(String url) {
    final lower = Uri.decodeFull(url).toLowerCase();
    if (lower.contains('.m3u8')) return true;
    // 服务端的福盈播放列表包装地址
    if (lower.contains('/api/fyplay')) return true;
    // 爱奇艺播放列表（虽然带 .m3u8，单独列出更明确）
    if (lower.contains('/api/iqiyi.m3u8')) return true;
    return false;
  }

  Future<void> play() {
    _playIntent = true;
    if (_rescueHold) return Future<void>.value();
    return _engine.play();
  }

  Future<void> pause() {
    _playIntent = false;
    return _engine.pause();
  }

  /// 停止播放（直播页 / 一起看退出时用）。
  Future<void> stop() async {
    _playIntent = false;
    await _engine.pause();
    await _engine.seek(Duration.zero);
  }

  /// 显式播放意图与缓冲状态分开，防止报错亮缓冲后把主动暂停误当播放。
  Future<void> playOrPause() => isPlaying ? pause() : play();

  /// 内核真实播放状态，按钮图标以此为准。
  bool get isPlaying => _engine.state.value.playing;

  /// 内核当前真实倍速；跨页面交接时以此为准，避免本地状态落后。
  ///
  /// ExoPlayer 的状态回包里没有倍速字段（我们不常用），所以自己记最近一次
  /// setRate 的值 —— 竖屏 → 全屏交接时读它，倍速不会被重置回 1.0。
  double get rate => _lastRate;

  double _lastRate = 1.0;

  /// 拖动进度：ExoPlayer 自己会重新调度分片，不需要我们干预缓冲参数。
  Future<void> seek(Duration position) async {
    await _engine.seek(position);
    _positionNotifier.value = position;
    _setValue(_value.copyWith(position: position));
  }

  /// 兼容 video_player 命名。
  Future<void> seekTo(Duration position) => seek(position);

  /// 切后台回来后的自愈：确认还在出画、进度没被系统重置。
  Future<bool> recoverAfterBackground(
    Duration expected, {
    bool wasPlaying = true,
  }) async {
    if (_disposed) return false;
    final v = _value;
    if (!v.isInitialized || v.hasError) return false;
    final pos = v.position;
    final rewound =
        expected > const Duration(seconds: 5) &&
        pos + const Duration(seconds: 3) < expected;
    final frozen = wasPlaying && !v.isPlaying;
    if (!rewound && !frozen) return false;
    _logFx('RESUME 自愈：rewound=$rewound frozen=$frozen');
    try {
      if (rewound) await _engine.seek(expected);
      if (wasPlaying) await play();
      _lastFlowAt = DateTime.now();
      _lastFlowPos = expected;
      return true;
    } catch (error) {
      _logFx('RESUME 自愈失败: $error');
      return false;
    }
  }

  Future<void> setRate(double rate) async {
    _lastRate = rate;
    await _engine.setRate(rate);
    _setValue(_value.copyWith());
  }

  /// 兼容 video_player 命名。
  Future<void> setPlaybackSpeed(double rate) => setRate(rate);

  /// 兼容 video_player 命名；单集播放固定不循环（同地址重开即从头）。
  Future<void> setLooping(bool looping) async {}

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
    _rescueGen++;
    _rescueBusy = false;
    _positionNotifier.dispose();
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    _opening = null;
    final ready = _ready;
    _ready = null;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(const FxPlayerException('播放器已释放'));
    }
    final mediaReady = _mediaReady;
    _mediaReady = null;
    if (mediaReady != null && !mediaReady.isCompleted) {
      mediaReady.completeError(const FxPlayerException('播放器已释放'));
    }
    await _positionCtrl.close();
    await _durationCtrl.close();
    await _bufferingCtrl.close();
    await _errorCtrl.close();
    await _completedCtrl.close();
    await _playingCtrl.close();
    _listeners.clear();
    final hlsProxy = _hlsProxy;
    _hlsProxy = null;
    hlsProxy?.cancelPrefetch();
    _engine.state.removeListener(_onEngineState);
    try {
      await _engine.dispose();
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

  /// 内核状态回调：把 ExoPlayerState 同步成 FxPlayerValue。
  ///
  /// 高频位置单独走 _positionNotifier，整对象只在「整秒 / 关键状态变化」
  /// 时才通知，避免顶栏、底栏、弹幕层跟着每帧重建。
  void _onEngineState() {
    if (_disposed) return;
    final st = _engine.state.value;

    final shown = recoveryVisiblePosition(
      holding: _rescueHold,
      previous: _value.position,
      incoming: st.position,
    );
    _positionNotifier.value = shown;

    final hasSize = st.hasSize;
    if (hasSize || st.position > Duration.zero || st.hasDuration) {
      _signalMediaReady();
    }

    final aspect = hasSize ? st.width / st.height : _value.aspectRatio;
    // 实时网速：ExoPlayer 不直接给下载速度，用「已缓冲位置的推进量 ÷ 时间」
    // 估算。原来这值是 mpv 的 cache-speed，换内核后得自己算，
    // 否则顶栏网速会一直空着。必须在 copyWith 之前算，否则会被覆盖。
    final speed = _estimateSpeed(st.buffered.inMilliseconds);
    final next = _value.copyWith(
      isInitialized: _value.isInitialized || hasSize || st.hasDuration,
      isPlaying: st.playing,
      isBuffering: _rescueHold ? true : st.buffering,
      buffered: st.buffered,
      isCompleted: st.ended,
      position: shown,
      duration: st.duration,
      width: hasSize ? st.width : _value.width,
      height: hasSize ? st.height : _value.height,
      videoWidth: hasSize ? st.width : _value.videoWidth,
      videoHeight: hasSize ? st.height : _value.videoHeight,
      aspectRatio: aspect,
      bytesPerSecond: speed > 0 ? speed : null,
    );

    final secondChanged = shown.inSeconds != _value.position.inSeconds;
    final stateChanged =
        next.isPlaying != _value.isPlaying ||
        next.isBuffering != _value.isBuffering ||
        next.isCompleted != _value.isCompleted ||
        next.duration != _value.duration ||
        next.width != _value.width;
    _value = next;
    // 首帧 / 时长就绪就立刻放行 open，不能等 _setValue ——
    // 这条路径不走 _setValue，之前漏了这一步，结果每次 open 都要
    // 干等到 30 秒停摆门槛或 2 分钟硬上限才返回（表现出来就是「加载很慢」）。
    if (next.isInitialized) {
      final ready = _ready;
      if (ready != null && !ready.isCompleted) ready.complete();
    }
    if (secondChanged || stateChanged) {
      _emitStreams(next);
      _notify();
    }

    final err = st.error;
    if (err != null && err.isNotEmpty) {
      _onError(err);
    }
  }

  /// 上一次采样：已缓冲毫秒数 + 采样时间，用来估算下载速度。
  int _lastBufferedMs = -1;
  DateTime _lastSpeedAt = DateTime.now();

  /// 用已缓冲位置的推进量估算下载速度（字节/秒）。
  ///
  /// 只有「缓冲在往前长」才算速度；缓冲停住说明要么下完了、要么卡着，
  /// 两种都不该显示一个假的正数。
  double _estimateSpeed(int bufferedMs) {
    final now = DateTime.now();
    final prevMs = _lastBufferedMs;
    final prevAt = _lastSpeedAt;
    if (bufferedMs < prevMs) {
      // 换源 / seek 之后缓冲位置回退，重新起算。
      _lastBufferedMs = bufferedMs;
      _lastSpeedAt = now;
      return 0;
    }
    final dtMs = now.difference(prevAt).inMilliseconds;
    if (prevMs < 0 || dtMs < 900) return 0;
    _lastBufferedMs = bufferedMs;
    _lastSpeedAt = now;
    final grewMs = bufferedMs - prevMs;
    if (grewMs <= 0) return 0;
    // 不知道真实码率，按 4K 经验值 0.9MB/s 折算：
    // 只用来给用户一个「快 / 慢」的相对参考，不是精确测速。
    const bytesPerSecondOfMedia = 900 * 1024.0;
    return grewMs / 1000.0 * bytesPerSecondOfMedia / (dtMs / 1000.0);
  }

  void _emitStreams(FxPlayerValue v) {
    if (!_positionCtrl.isClosed) _positionCtrl.add(v.position);
    if (!_durationCtrl.isClosed) _durationCtrl.add(v.duration);
    if (!_bufferingCtrl.isClosed) _bufferingCtrl.add(v.isBuffering);
    if (!_playingCtrl.isClosed) _playingCtrl.add(v.isPlaying);
    if (!_completedCtrl.isClosed) _completedCtrl.add(v.isCompleted);
    if (!_errorCtrl.isClosed && v.hasError) _errorCtrl.add(v.errorText);
  }

  /// 内核报错入口。
  ///
  /// - 首帧还没出来：把错误抛给 open 的调用方去试备用地址；
  /// - 首帧之后的任何失败：静默进入三步救援链，期间只显示「缓冲中」。
  void _onError(String message) {
    if (_disposed) return;
    if (_looksCancelled(message)) {
      _logFx('忽略取消事件(cancelled 不算失败): $message');
      return;
    }
    // 内核把 lastError 一直带在每次状态快照里（只在 open 时清空），
    // 不去重的话同一个错误会反复触发救援链，3 轮之后误报「线路不稳定」。
    if (message == _lastHandledError) return;
    _lastHandledError = message;
    if (_value.errorText == message) return;
    _decodeErrorSerial++;
    final mediaReady = _mediaReady;
    if (mediaReady != null && !mediaReady.isCompleted) {
      mediaReady.completeError(FxPlayerException(message));
    }
    final ready = _ready;
    if (ready == null && _value.isInitialized) {
      _logFx('播放中报错，进入救援链: $message');
      _stallIndicated = true;
      _setValue(
        _value.copyWith(hasError: false, errorText: '', isBuffering: true),
      );
      unawaited(_runRescue('播放错误: $message'));
      return;
    }
    _setValue(_value.copyWith(hasError: true, errorText: message));
    if (ready != null && !ready.isCompleted) {
      ready.completeError(FxPlayerException(message));
    }
  }

  void _fail(String message) {
    if (_disposed) return;
    _setValue(_value.copyWith(hasError: true, errorText: message));
  }

  // ------------------------------------------------- 看门狗 / 无感救援链

  Future<void> _watchdogTickAsync() async {
    if (_disposed || _rescueBusy) return;
    final v = _value;
    if (v.hasError) return;
    if (_opening != null || _ready != null || !v.isInitialized || v.isCompleted) {
      _lastFlowAt = DateTime.now();
      return;
    }
    // 用户主动暂停（非缓冲暂停）的时间不计入停摆。
    if (!v.isPlaying && !v.isBuffering) {
      _lastFlowAt = DateTime.now();
      _clearStallIndication();
      return;
    }
    final flowing = _flowing();
    if (flowing) {
      _lastFlowAt = DateTime.now();
      _clearStallIndication();
      return;
    }
    if (!_stallIndicated) {
      _stallIndicated = true;
      _setValue(_value.copyWith(isBuffering: true));
    }
    final stalled = DateTime.now().difference(_lastFlowAt);
    if (stalled < _stallTimeout) return;
    unawaited(_runRescue('连续 ${stalled.inSeconds}s 无进展'));
  }

  /// 播放位置 / 缓冲位置 / 内核状态任一有变化即算「还在流动」。
  bool _flowing() {
    final v = _value;
    final st = _engine.state.value;
    final posMoved = v.position != _lastFlowPos;
    final bufferedMoved = v.buffered != _lastFlowBuffered;
    final stateMoved = st.state != _lastFlowState;
    _lastFlowPos = v.position;
    _lastFlowBuffered = v.buffered;
    _lastFlowState = st.state;
    return posMoved || bufferedMoved || stateMoved;
  }

  /// 字节恢复流动 / 暂停：熄灭我们自己点亮的「缓冲中」。
  void _clearStallIndication() {
    if (!_stallIndicated) return;
    _stallIndicated = false;
    _setValue(_value.copyWith(isBuffering: false));
  }

  /// 救援重开时的新流就绪信号（首帧 / 时长 / 位置任一到达）。
  void _signalMediaReady() {
    _hlsProxy?.markFirstFrameReady();
    final completer = _mediaReady;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  static bool _looksCancelled(String message) {
    final lower = message.toLowerCase();
    return lower.contains('cancel') || lower.contains('abort');
  }

  /// 播放器诊断日志：控制台 + `<App 私有目录>/logs/proxy.log` 双写，
  /// 救援链的每一步与结果都落盘，作为掉线根因证据。
  static void _logFx(String message) {
    debugPrint('FxPlayer: $message');
    HlsProxyLog.write('FX $message');
  }

  static String _shortUrl(String url) =>
      url.length <= 120 ? url : '${url.substring(0, 117)}...';

  /// 回前台自检：切后台期间流可能已经断了（系统冻结进程 / 连接被回收），
  /// 回前台时只重挂画面层是不够的 —— 必须确认还在播，否则自动重连。
  Future<void> resumeSelfCheck() async {
    if (_disposed || _rescueBusy) return;
    final v = _value;
    final url = _sourceUrl;
    if (url.trim().isEmpty) return;
    final wantPlay = _playIntent;
    final target = v.position > Duration.zero ? v.position : _lastFlowPos;

    final needReopen = v.hasError;
    if (!needReopen) {
      final before = v.position;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (_disposed || _rescueBusy) return;
      final after = _value.position;
      final moved = after - before > const Duration(milliseconds: 300);
      final stalled = wantPlay && !moved && !_value.isBuffering;
      if (!stalled) return;
      _logFx('RESUME 自检：位置未推进 ${before.inSeconds}s，准备重连');
    } else {
      _logFx('RESUME 自检：处于错误态（${v.errorText}），自动重连');
    }
    unawaited(_reopenAfterResume(target, wantPlay));
  }

  /// 静默重开同一地址并恢复到 [target]：不弹错误层，成功后继续播。
  Future<void> _reopenAfterResume(Duration target, bool wantPlay) async {
    if (_disposed || _rescueBusy) return;
    _rescueBusy = true;
    _rescueHold = true;
    final gen = _rescueGen;
    final token = ++_openToken;
    try {
      _setValue(
        _value.copyWith(isBuffering: true, hasError: false, errorText: ''),
      );
      final refresher = _refreshPlay;
      var url = _sourceUrl;
      final headers = _sourceHeaders;
      if (refresher != null) {
        final fresh = await _safeRefreshPlay(refresher);
        if (_disposed || gen != _rescueGen) return;
        final trimmed = fresh?.trim() ?? '';
        if (trimmed.startsWith('http')) url = trimmed;
      }
      if (_disposed || gen != _rescueGen) return;
      await _engine.open(url, headers: headers, isHls: _looksLikeHls(url));
      if (_disposed || gen != _rescueGen) return;
      if (target > Duration.zero) {
        await _engine.seek(target);
        if (_disposed || gen != _rescueGen) return;
      }
      if (wantPlay) await _engine.play();
      _lastFlowAt = DateTime.now();
      _lastFlowPos = target;
      _setValue(
        _value.copyWith(
          isBuffering: false,
          hasError: false,
          errorText: '',
          isPlaying: wantPlay,
        ),
      );
      _logFx('RESUME 自检：重连完成，回到 ${target.inSeconds}s');
    } catch (error) {
      _logFx('RESUME 自检：重连失败 $error');
    } finally {
      if (token == _openToken) {
        _rescueHold = false;
        _rescueBusy = false;
      }
    }
  }

  /// 无感救援链：① refreshPlay 换地址 ② 同地址重新 open 并 seek 回原进度
  /// ③ 换下一条线路 seek 回原进度；①② 各先试 2 次。
  /// 全程静默（画面保持 + 「缓冲中」），三步都失败才报一次「播放中断」。
  Future<void> _runRescue(String reason) async {
    if (_disposed || _rescueBusy || _value.hasError) return;
    if (_rescueRounds >= _maxRescueRounds) {
      _logFx('RESCUE 放弃：已尝试 $_rescueRounds 轮，交给页面处理');
      _fail('这条线路不稳定，请切换其它线路');
      return;
    }
    _rescueRounds++;
    _rescueBusy = true;
    final gen = _rescueGen;
    final resume = _value.position;
    final live = _value.duration <= Duration.zero;
    _stallIndicated = true;
    _rescueHold = true;
    _setValue(
      _value.copyWith(isBuffering: true, hasError: false, errorText: ''),
    );
    _logFx('RESCUE 开始：$reason；进度 ${resume.inSeconds}s live=$live');
    try {
      // ① refreshPlay 换新地址（最多 2 次）
      final refresher = _refreshPlay;
      if (refresher == null) {
        _logFx('RESCUE ①-refresh 跳过：本次播放没有 refreshPlay');
      } else {
        for (var i = 1; i <= _rescueTries; i++) {
          if (_disposed || gen != _rescueGen) return;
          final fresh = await _safeRefreshPlay(refresher);
          if (fresh == null) {
            _logFx('RESCUE ①-refresh#$i 未拿到新地址');
            continue;
          }
          _logFx('RESCUE ①-refresh#$i 换地址重开 ${_shortUrl(fresh)}');
          final ok = await _rescueOpen(
            fresh,
            _sourceHeaders,
            direct: _sourceDirect,
            resume: resume,
            live: live,
            gen: gen,
          );
          _logFx('RESCUE ①-refresh#$i ${ok ? '成功' : '失败'}');
          if (ok) return;
        }
      }

      // ② 同地址重新 open（最多 2 次；直播走这里直接重开直播地址）
      for (var i = 1; i <= _rescueTries; i++) {
        if (_disposed || gen != _rescueGen) return;
        _logFx('RESCUE ②-reopen#$i ${_shortUrl(_sourceUrl)}');
        final ok = await _rescueOpen(
          _sourceUrl,
          _sourceHeaders,
          direct: _sourceDirect,
          resume: resume,
          live: live,
          gen: gen,
        );
        _logFx('RESCUE ②-reopen#$i ${ok ? '成功' : '失败'}');
        if (ok) return;
      }

      // ③ 换下一条线路 seek 回原进度
      final switcher = _lineRescue;
      if (switcher == null) {
        _logFx('RESCUE ③-next-line 跳过：页面未提供换线 hook');
      } else if (!_disposed && gen == _rescueGen) {
        FxLineSource? next;
        try {
          next = await switcher();
        } catch (error) {
          _logFx('RESCUE ③-next-line 取址失败: $error');
        }
        if (next == null) {
          _logFx('RESCUE ③-next-line 没有下一条线路');
        } else if (!_disposed && gen == _rescueGen) {
          _logFx('RESCUE ③-next-line 换线重开 ${_shortUrl(next.url)}');
          final ok = await _rescueOpen(
            next.url,
            next.headers,
            direct: next.direct,
            resume: resume,
            live: live,
            gen: gen,
          );
          _logFx('RESCUE ③-next-line ${ok ? '成功' : '失败'}');
          if (ok) return;
        }
      }

      if (_disposed || gen != _rescueGen) return;
      _logFx('RESCUE 三步全部失败 → 播放中断');
      _stallIndicated = false;
      _fail('播放中断，自动恢复失败，请重试或切换线路');
    } finally {
      if (gen == _rescueGen) {
        _rescueBusy = false;
        _rescueHold = false;
      }
    }
  }

  Future<String?> _safeRefreshPlay(PlayUrlRefresher refresher) async {
    try {
      final raw = await refresher().timeout(const Duration(seconds: 15));
      final url = raw?.trim() ?? '';
      return url.isEmpty ? null : url;
    } catch (error) {
      _logFx('RESCUE ①-refresh 调用失败: $error');
      return null;
    }
  }

  /// 救援链的一步：解析地址 → 重新 open → 等新流就绪 → seek 回原进度。
  /// 返回这一步是否成功。
  Future<bool> _rescueOpen(
    String url,
    Map<String, String> headers, {
    required bool direct,
    required Duration resume,
    required bool live,
    required int gen,
  }) async {
    if (_disposed || gen != _rescueGen) return false;
    final token = ++_openToken;
    final errorSerial = _decodeErrorSerial;
    try {
      final source = await _resolvePlaybackSource(
        url,
        headers,
        direct: direct,
        token: token,
        waitForWarm: false,
      );
      if (source == null || _disposed || token != _openToken) {
        _logFx('RESCUE 地址解析被取代或失败');
        return false;
      }
      final mediaReady = Completer<void>();
      unawaited(mediaReady.future.catchError((Object _) {}));
      _mediaReady = mediaReady;
      final reopenPaused = !live && resume > Duration.zero;
      try {
        await _openMedia(
          source,
          play: !reopenPaused,
          token: token,
        ).timeout(_rescueOpenTimeout);
        if (_disposed || token != _openToken) return false;
        await mediaReady.future.timeout(_rescueOpenTimeout);
      } on TimeoutException {
        _logFx('RESCUE 等新流首帧超时(${_rescueOpenTimeout.inSeconds}s)');
        return false;
      } catch (error) {
        _logFx('RESCUE 重开失败: $error');
        return false;
      } finally {
        if (identical(_mediaReady, mediaReady)) _mediaReady = null;
      }
      if (_disposed || token != _openToken) return false;
      if (!live && resume > Duration.zero) {
        try {
          await _engine.seek(resume);
          _logFx('RESCUE 已 seek 回 ${resume.inSeconds}s');
        } catch (error) {
          _logFx('RESCUE seek 回原进度失败: $error');
          return false;
        }
      }
      if (_disposed || token != _openToken || gen != _rescueGen) return false;
      // 确认 seek 落点：ExoPlayer 没有截帧接口，改用「画面尺寸已就绪 +
      // 位置落到目标附近」作为恢复证据，两样都要满足。
      final deadline = DateTime.now().add(_rescueOpenTimeout);
      var verified = false;
      while (!_disposed &&
          token == _openToken &&
          gen == _rescueGen &&
          errorSerial == _decodeErrorSerial &&
          DateTime.now().isBefore(deadline)) {
        final st = _engine.state.value;
        final landed = recoverySeekLanded(
          live: live,
          target: resume,
          actual: st.position,
        );
        if (landed && st.hasSize) {
          verified = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (!verified ||
          _disposed ||
          token != _openToken ||
          gen != _rescueGen ||
          errorSerial != _decodeErrorSerial) {
        _logFx('RESCUE 未确认画面或 seek 落点，继续恢复链');
        return false;
      }
      if (_playIntent) await _engine.play();
      if (_disposed || token != _openToken || gen != _rescueGen) return false;
      _sourceUrl = url;
      _sourceHeaders = headers;
      _sourceDirect = direct;
      _rescueHold = false;
      _stallIndicated = false;
      final st = _engine.state.value;
      _setValue(
        _value.copyWith(
          position: st.position,
          isPlaying: st.playing,
          isBuffering: false,
        ),
      );
      _lastFlowAt = DateTime.now();
      _logFx('RESCUE 已确认画面与进度');
      return true;
    } catch (error) {
      _logFx('RESCUE 重开异常: $error');
      return false;
    }
  }

  void _setValue(FxPlayerValue next) {
    if (_disposed) return;
    _value = next;
    _emitStreams(next);
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

  /// 截帧字节；ExoPlayer 无截帧接口时恒为 null。
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

/// 解析完成后真正交给 mpv 的地址（可能已被本地 HLS 代理改写）。
class _PlaybackSource {
  const _PlaybackSource(this.url, this.headers);

  final String url;
  final Map<String, String> headers;
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

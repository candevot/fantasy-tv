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

  /// 设备能不能**硬解** HEVC（IQ_CODEC 2026-11-15）。
  ///
  /// 原生侧扫 `MediaCodecList(REGULAR_CODECS)`：只要有解码器声明支持
  /// `video/hevc` 且 `isHardwareAccelerated`，就认为这台机器能硬解 1080P HEVC
  /// （爱奇艺线路的 `hevc=1` 码流就是 HEVC Main / 10bit，软解跑不动）。
  ///
  /// 结果在**进程内缓存**：解码器表在一次进程生命周期里不会变，而每次起播
  /// 都扫一遍表要几十毫秒 —— 起播路径上任何一次多余扫描都直接体现为「慢」。
  /// 问到之前一律按「不支持」处理（AVC 一定播得出来，先保出画）。
  static Future<bool> supportsHevc() {
    final cached = _hevcSupport;
    if (cached != null) return cached;
    final future = _probeHevc();
    _hevcSupport = future;
    return future;
  }

  static Future<bool>? _hevcSupport;

  /// 已经拿到的结果（还没探测过是 null）。
  static bool? get hevcSupportKnown => _hevcKnown;

  static bool? _hevcKnown;

  static Future<bool> _probeHevc() async {
    if (!isSupported) {
      _hevcKnown = false;
      return false;
    }
    var supported = false;
    try {
      final r = await _prefetchChannel.invokeMethod<bool>('supportsHevc');
      supported = r ?? false;
    } catch (_) {
      // 老原生包 / 通道未注册：按不支持处理，走 AVC。
      supported = false;
    }
    _hevcKnown = supported;
    return supported;
  }

  /// 预取通道单独一条 [MethodChannel]：`prefetchSegment` 是**静态**方法，
  /// 首页还没创建过 [ExoPlayerEngine] 实例时也要能调（没播放器 = 没 _method）。
  /// 原生侧和播放用的是同一个 `ExoPlayerPlugin` 实例（同一个 SimpleCache），
  /// 所以用同一个 channel 名即可。
  static const MethodChannel _prefetchChannel =
      MethodChannel('fantasy_tv/exo_player');

  /// 把**一个** HLS 分片下载进播放器同一份 SimpleCache（首页续播预取用）。
  ///
  /// 为什么不在这里用 Dart 的 http 自己拉：SimpleCache 是原生磁盘缓存，
  /// 播放器的 CacheDataSource 按原生 `FxCacheKeyFactory` 算出的 key 查它
  /// （`stripQuery(url) + "||" + url`）。Dart 拉下来的字节只能落进内存或临时
  /// 文件，播放器照样查不到、照样回源 —— 只有原生走 CacheDataSource 写进去，
  /// 播放器请求同一 URL 时才是本地命中。
  ///
  /// 原生侧入队后立刻返回（下载在独立单线程里跑），失败静默只留 logcat；
  /// [maxBytes] > 0 时下到这么多字节就停（移动网络的单次上限）。
  static Future<bool> prefetchSegment(
    String url, {
    Map<String, String> headers = const {},
    int maxBytes = 0,
  }) async {
    if (url.isEmpty || !isSupported) return false;
    try {
      final r = await _prefetchChannel.invokeMethod<bool>('prefetchSegment', {
        'url': url,
        'headers': headers,
        'maxBytes': maxBytes < 0 ? 0 : maxBytes,
      });
      return r ?? false;
    } catch (_) {
      // 预取失败不影响播放：播放页那份预取和回源都会兜底。
      return false;
    }
  }

  /// 预载**下一集**的清单 + 前 2 个分片（改动 ⑥）。
  ///
  /// 原生走 CacheDataSource 把字节写进播放器同一份 SimpleCache（只写不读），
  /// 换集时播放器的首批分片请求就是本地命中。原生入队即返回，失败静默。
  ///
  /// 为什么不在这里用 Dart 自己下：SimpleCache 按原生 [FxCacheKeyFactory]
  /// 算出的 key 查，Dart 拉的字节播放器一个都命中不到（同 [prefetchSegment]）。
  static Future<bool> preloadNextEpisode(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    if (url.isEmpty || !isSupported) return false;
    try {
      final r = await _prefetchChannel.invokeMethod<bool>('preloadNext', {
        'url': url,
        'headers': headers,
      });
      return r ?? false;
    } catch (_) {
      // 下一集预载失败不影响当前播放。
      return false;
    }
  }

  /// 取消上一轮下一集预载（换集 / 换线路时调用）。
  ///
  /// 原生 `open` 也会顺手取消一次，这里是给「只换集不 open」的边界兜底。
  static Future<void> cancelNextPreload() async {
    if (!isSupported) return;
    try {
      await _prefetchChannel.invokeMethod<void>('cancelPreload');
    } catch (_) {
      // 取消失败无副作用：下一轮预载会覆盖它。
    }
  }

  // ------------------------------------------------- 后台播放保活（BG_SERVICE）
  //
  // 播放本身**不会**因为切后台而暂停（播放页里写死了永不暂停）。断流的原因
  // 是 Android 回收了「没有前台服务的后台进程」，所以这里只做一件事：
  // 让原生挂一个 foregroundServiceType=mediaPlayback 的前台服务 + 常驻通知，
  // 进程就不会被随手回收。
  //
  // 分工：Dart 只负责「登记片名 / 集号」和「收工」；什么时候真正
  // startForeground 由原生决定（首次 onIsPlayingChanged(true)），
  // 这样地址打不开时不会留下空转的服务。

  /// 登记「现在这一集叫什么」：原生拿它拼通知标题「片名 · 第N集」。
  ///
  /// 在 `open()` 之前调用即可；真正起服务是首次真的出声之后。重复调用安全。
  static Future<void> backgroundStart({
    required String title,
    required int episode,
  }) async {
    final name = title.trim();
    if (name.isEmpty || !isSupported) return;
    try {
      await _prefetchChannel.invokeMethod<bool>('bgStart', {
        'title': name,
        'ep': episode,
      });
    } catch (_) {
      // 保活起不来只是「可能被系统回收」，绝不打断播放。
    }
  }

  /// 收掉前台服务（退出播放页 / 播放结束 / 播放器释放）。
  static Future<void> backgroundStop() async {
    if (!isSupported) return;
    try {
      await _prefetchChannel.invokeMethod<bool>('bgStop');
    } catch (_) {}
  }

  /// 把本应用加进电池优化白名单（**只在「设置」里由用户点**，不主动弹窗）。
  ///
  /// 返回 true = 已经在白名单里，或已把系统页面拉起来。
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!isSupported) return false;
    try {
      final r = await _prefetchChannel.invokeMethod<bool>('bgBattery');
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 当前是否已在电池优化白名单里（设置页显示状态用）。
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!isSupported) return false;
    try {
      final r = await _prefetchChannel.invokeMethod<bool>('bgBatteryIgnoring');
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 取一次「后台播放曾被系统中断」的标记（读后即清，只提示一次）。
  static Future<bool> consumeBackgroundHint() async {
    if (!isSupported) return false;
    try {
      final r = await _prefetchChannel.invokeMethod<bool>('bgConsumeHint');
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

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
    /// Dart 侧「解析播放地址」花掉的毫秒数（hxparse 302 → 最终地址）。
    ///
    /// 为什么由 Dart 传进来：这一步发生在 `open` 之前，原生根本看不到，
    /// 不并进原生时间线的话界面上的「解析 + 首帧」永远对不上「起播总」。
    int resolveMs = 0,
  }) async {
    if (_disposed || !isSupported) return false;
    _error = null;
    try {
      final r = await _method.invokeMethod<bool>('open', {
        'url': url,
        'headers': headers,
        'isHls': isHls,
        'startPositionMs': startPositionMs < 0 ? 0 : startPositionMs,
        // 负数按 0 处理：原生那边把它当「本段耗时」直接累加进时间线。
        'resolveMs': resolveMs < 0 ? 0 : resolveMs,
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

/// 一次起播的分段耗时（全部是**毫秒**）。
///
/// 计时口径：**从「用户点播放」算起的累计值**，不是分段增量 ——
/// 「清单 240ms」表示「到清单就绪为止一共等了 240ms」，其中前 180ms 是
/// Dart 侧解析地址（[resolveMs]）。这样和壳（OK影视/FongMi）报的
/// 「首帧 1 秒」是同一个口径，可以直接比。
///
/// 为什么单独一个类：原生把这条时间线当成一个扁平 map 推上来
/// （`snapshot()['timing']`），Dart 侧到处传 map 容易读错 key，
/// 而且界面只想拿「哪一段慢」。这里解析一次，之后全是强类型字段。
///
/// -1 = 这一步还没到（原生约定），0 是合法值（真的只用 0ms）。
@immutable
class PlaybackTiming {
  const PlaybackTiming({
    this.session = 0,
    this.resolveMs = -1,
    this.manifestMs = -1,
    this.prepareMs = -1,
    this.firstFrameMs = -1,
    this.audioMs = -1,
    this.totalMs = -1,
  });

  /// 空快照：还没 open 过，所有分段都是「未到」。
  const PlaybackTiming.empty() : this(session: 0);

  /// open 序号：换集 / 换线路会 +1，界面据此判断时间线换了一轮。
  final int session;

  /// Dart 侧解析（hxparse 302 → 最终地址）耗时。
  final int resolveMs;

  /// 到清单就绪为止的累计耗时（含 [resolveMs]）。
  final int manifestMs;

  /// 到 `prepare()` 下发为止的累计耗时（含 [resolveMs]）。
  final int prepareMs;

  /// 到首帧真正渲染上屏为止的累计耗时（含 [resolveMs]）—— 这就是用户
/// 感知的「起播多久出画面」。
  final int firstFrameMs;

  /// 到音频轨起来为止的累计耗时（含 [resolveMs]）。
  final int audioMs;

  /// 起播总耗时：首帧到了 = [firstFrameMs]；没到 = 现在的累计值（会一直涨）。
  final int totalMs;

  /// 首帧是否已经到了（到了才有意义拿它当「起播快慢」的判据）。
  bool get hasFirstFrame => firstFrameMs >= 0;

  /// 解析段 + 首帧段之和；原生给的 totalMs 缺失时用这个兜底。
  int get incrementalTotalMs {
    final resolve = resolveMs > 0 ? resolveMs : 0;
    final frame = firstFrameMs > 0 ? firstFrameMs : 0;
    return resolve + frame;
  }

  factory PlaybackTiming.fromMap(Map<String, dynamic>? m) {
    if (m == null) return const PlaybackTiming.empty();
    // 全部走 `as num?`：原生可能给 Int / Long，也可能这一版还没加这个 key。
    int read(String key) => (m[key] as num?)?.toInt() ?? -1;
    return PlaybackTiming(
      session: (m['session'] as num?)?.toInt() ?? 0,
      resolveMs: read('resolveMs'),
      manifestMs: read('manifestMs'),
      prepareMs: read('prepareMs'),
      firstFrameMs: read('firstFrameMs'),
      audioMs: read('audioMs'),
      totalMs: read('totalMs'),
    );
  }

  /// 只留最关键的几段，别让日志刷屏。
  @override
  String toString() =>
      'PlaybackTiming(s$session resolve=$resolveMs manifest=$manifestMs '
      'prepare=$prepareMs firstFrame=$firstFrameMs audio=$audioMs '
      'total=$totalMs)';
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
    this.hasRenderedFirstFrame = false,
    this.error,
    this.width = 0,
    this.height = 0,
    this.ended = false,
    this.state = 1,
    this.retryAttempt = 0,
    this.retryReason = '',
    this.retryResolveToken = 0,
    this.timing = const PlaybackTiming.empty(),
    this.connectCount = 0,
    this.bufferedAhead = Duration.zero,
    this.droppedFrames = 0,
    this.bitrateKbps = 0,
    this.measuredKbps = 0,
    this.videoCodec = '',
    this.iqCodec = '',
    this.iqQuality = '',
    this.bytesLoaded = -1,
    this.bytesLoadedPerSec = 0,
    this.isLoading = true,
    this.fatalError = '',
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

  /// 是否已经真正渲染出过一帧（原生 `onRenderedFirstFrame`）。
  ///
  /// FIRST_FRAME（2026-11-14）：加载层的显隐只看这一个值。
  /// `buffering == false`、`playing == true`、`hasSize == true` 都可能在
  /// 首帧上屏之前成立，用它们收加载层就会出现「缓冲没了但黑屏」。
  /// open / seek 时原生会把它重置为 false。
  final bool hasRenderedFirstFrame;

  final String? error;

  /// 解码后的显示宽高（已按 rotationDegrees 交换横竖屏方向）；0 表示还没拿到。
  final int width;
  final int height;

  /// 是否播放到结尾。
  final bool ended;

  /// Media3 Player.STATE_* 原值：1=IDLE 2=BUFFERING 3=READY 4=ENDED。
  final int state;

  /// 原生分层重试进度（改动 ⑤）：0 = 这次打开还没重试过。
  ///
  /// 同一集同一线路最多重试 2 次：第 1 次 IO/HTTP → 重新 resolve 地址；
  /// 第 2 次解码错误 → 切解码模式（硬解 ↔ 软解）。重试期间原生**不**上报
  /// error（否则救援链会立刻换线路，等于跳过分级重试）。
  final int retryAttempt;

  /// 最近一次重试原因：'' / 'io' / 'decode'。
  final String retryReason;

  /// 重新 resolve 播放地址的请求号：值变化 = 原生希望 Dart 拿新地址重开。
  ///
  /// 原生没法自己解析播放地址（那是 Dart 的 /api/play），所以 IO 类错误
  /// 会把它 +1；Dart 侧看到变化就 refreshPlay 并把新地址交给原生。
  final int retryResolveToken;

  /// 本次 open 的分段耗时时间线（见 [PlaybackTiming]）。
  ///
  /// DIAG（2026-11-15）：用户报「起播比影视壳慢」，只靠感觉猜是哪一段慢
  /// 没有意义 —— 解析、清单、首帧各自花了多少，原生都算好了推上来，
  /// 这里原样带着，界面按需展示。
  final PlaybackTiming timing;

  /// 起播至今 OkHttp `connectStart` 的次数：越接近 1 说明连接池复用越好。
  final int connectCount;

  /// 距播放位置还有多少内容（`bufferedPosition - currentPosition`，>=0）。
  final Duration bufferedAhead;

  /// 累计丢帧。
  final int droppedFrames;

  /// 视频轨道声明的码率（kbps）；拿不到为 0。
  final int bitrateKbps;

  /// OkHttp 实测吞吐（kbps）；0 = 还没测到。
  final int measuredKbps;

  /// 真实解码出来的视频编码（原生 `videoFormat.sampleMimeType` 的短名）：
  /// `'hevc'` / `'avc'` / `'av1'` / `'vp9'`；'' = 还没拿到视频轨。
  ///
  /// IQ_CODEC（2026-11-15）：爱奇艺线路「请求的是 HEVC，实际给的可能是
  /// AVC」。请求参数骗不了人，响应头和内核解出来的轨道才骗不了人，
  /// 所以诊断浮层的「编码」以这个值为准。
  final String videoCodec;

  /// 服务端响应头 `X-Iq-Codec`：`hevc` / `avc`（爱奇艺解析服务实测会带）。
  final String iqCodec;

  /// 服务端响应头 `X-Iq-Quality`：实际给的分辨率，如 `1920x1080`。
  final String iqQuality;

  /// 本次 open 至今收到多少正文字节（原生 `bytesLoaded`）；-1 = 老原生包没有。
  ///
  /// SLOW_NET（2026-11-15）：这是「有没有真的在下」最硬的证据 ——
  /// 缓冲位置会按分片粒度整段推进（一片没下完就一直不动），字节数是连续涨的，
  /// 几十 KB/s 的慢网一眼就能看出来在走。
  final int bytesLoaded;

  /// 原生按 1 秒采样算出来的下载速度（字节/秒）。
  ///
  /// 和按缓冲推进估算的 [measuredKbps] 不同：这个是**真实网络字节**，
  /// 不受「分片整段落盘」影响，慢网时界面能显示「38KB/s」而不是 0。
  final int bytesLoadedPerSec;

  /// 内核是否仍在加载（`STATE_BUFFERING` 或首帧还没渲染）。
  final bool isLoading;

  /// 原生判定的「真失败」码（`http_404` / `dns_error` / `tls_error` /
  /// `connect_refused` / `manifest_invalid` / `no_segments`）；空串 = 没有。
  ///
  /// SLOW_NET（2026-11-15）：这类错误**不等任何窗口**，拿到就立刻换线路 ——
  /// 它不可能是「网慢」，等下去也没有意义。
  final String fatalError;

  factory ExoPlayerState.fromMap(Map<String, dynamic> m) {
    Duration d(String k) =>
        Duration(milliseconds: (m[k] as num?)?.toInt() ?? 0);
    final exoBuffered = d('bufferedMs');
    // 原生侧预取器报的「从现在起连续已落盘的时长」。
    final diskBuffered = d('preloadedMs');
    // 嵌套的 timing 可能是 Map<Object?, Object?>（StandardMessageCodec 不解类型），
    // 先转成 Map<String, dynamic> 再交给 PlaybackTiming 解析。
    final rawTiming = m['timing'];
    final timing = PlaybackTiming.fromMap(
      rawTiming is Map ? Map<String, dynamic>.from(rawTiming) : null,
    );
    // 负值不该让界面出现「-1.2s」：原生保证 >= 0，这里再兜一次。
    final aheadMs = (m['bufferedAheadMs'] as num?)?.toInt() ?? 0;
    return ExoPlayerState(
      position: d('positionMs'),
      duration: d('durationMs'),
      buffered: diskBuffered > exoBuffered ? diskBuffered : exoBuffered,
      preloaded: diskBuffered,
      playing: m['playing'] == true,
      buffering: m['buffering'] == true,
      hasRenderedFirstFrame: m['firstFrameRendered'] == true,
      error: m['error'] as String?,
      width: (m['width'] as num?)?.toInt() ?? 0,
      height: (m['height'] as num?)?.toInt() ?? 0,
      ended: m['ended'] == true,
      state: (m['state'] as num?)?.toInt() ?? 1,
      retryAttempt: (m['retryAttempt'] as num?)?.toInt() ?? 0,
      retryReason: (m['retryReason'] as String?) ?? '',
      retryResolveToken: (m['retryResolveToken'] as num?)?.toInt() ?? 0,
      timing: timing,
      connectCount: (m['connectCount'] as num?)?.toInt() ?? 0,
      // 原生已经保证 >= 0，这里再夹一次：旧的负值不该让界面出现「-1.2s」。
      bufferedAhead: Duration(
        milliseconds: aheadMs < 0 ? 0 : aheadMs,
      ),
      droppedFrames: (m['droppedFrames'] as num?)?.toInt() ?? 0,
      bitrateKbps: (m['bitrateKbps'] as num?)?.toInt() ?? 0,
      measuredKbps: (m['measuredKbps'] as num?)?.toInt() ?? 0,
      videoCodec: _str(m['videoCodec']),
      iqCodec: _str(m['iqCodec']),
      iqQuality: _str(m['iqQuality']),
      bytesLoaded: (m['bytesLoaded'] as num?)?.toInt() ?? -1,
      bytesLoadedPerSec: (m['bytesLoadedPerSec'] as num?)?.toInt() ?? 0,
      // 老原生包没有这个键：退化成 buffering（只要有一项在涨就不会判卡死）。
      isLoading: m['isLoading'] == null
          ? (m['buffering'] == true)
          : m['isLoading'] == true,
      fatalError: _str(m['fatalError']),
    );
  }

  /// 画面尺寸是否已经拿到（**不是**首帧判据，别拿它收加载层）。
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
      'playing=$playing, buffering=$buffering, '
      'firstFrame=$hasRenderedFirstFrame, ${width}x$height, '
      'ended=$ended, state=$state, '
      'retry=$retryAttempt/${retryReason.isEmpty ? '-' : retryReason}, '
      // 诊断字段只挑最关键的：首帧段 + 丢帧，够定位「起播慢 / 掉帧」。
      'frame=${timing.firstFrameMs}ms, drops=$droppedFrames, '
      'kbps=${bitrateKbps > 0 ? bitrateKbps : measuredKbps}, '
      'codec=${videoCodec.isEmpty ? '-' : videoCodec}, '
      // SLOW_NET：慢网排查看这一段（bytes 在涨 = 线路活着，只是慢）。
      'bytes=$bytesLoaded(+$bytesLoadedPerSec/s), loading=$isLoading, '
      'fatal=${fatalError.isEmpty ? '-' : fatalError}, '
      'err=$error)';
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

/// 状态快照里的字符串字段：null / 非字符串一律当空串（老原生包没有这些键）。
String _str(Object? raw) => raw is String ? raw.trim() : '';

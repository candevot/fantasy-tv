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
    // 优先用代理层按真实字节算的起播进度：它涨到 100 会结束，
    // 不会像 mpv 的 cache-buffering-state 那样长期停在 99 假装还在缓。
    if (measuredBufferPercent > 0) {
      return measuredBufferPercent.clamp(0.0, 100.0);
    }
    // 没有代理进度（直连 / 非 HLS）时退回 mpv 的百分比。
    if (bufferingPercentage > 0) return bufferingPercentage.clamp(0.0, 99.0);
    return null;
  }

  /// 起播进度是否已经到顶（可以隐藏进度环）。
  bool get bufferingSettled => measuredBufferPercent >= 100;

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

/// 基于 media_kit（libmpv）的播放内核封装。
///
/// - 统一处理 HLS / 加密流 / 各种奇怪编码（libmpv + ffmpeg）；
/// - 提供与 video_player 类似的 `value` / `addListener` / `dispose` 接口；
/// - 以 Stream 形式暴露 position / duration / buffering / error / completed；
/// - [buildVideo] 返回可直接放进页面的视频 Widget。
class FxPlayer implements Listenable {
  FxPlayer._({this.readyTimeout = const Duration(seconds: 20)}) {
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
    // 长播兜底：每 5 分钟压一次回看缓存，避免长播内存无限涨。
    // 注意不能无条件写回 _steadyBufferBytes —— 那会覆盖首帧后按网速
    // 算出的自适应值（之前就是这样被打回 192MB 的）。
    _cacheGuardTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(_setCacheLimits(_currentForwardBuffer)),
    );
    // 稳定性看门狗：只看「字节是否还在流动」，缓冲中不算失败。
    _watchdogTimer = Timer.periodic(
      _watchdogTick,
      (_) => unawaited(_watchdogTickAsync()),
    );
  }

  /// 起播前向缓存：16MB。代理层已在本地整集预热，mpv 不需要靠大缓冲
  /// 去对抗网络抖动，起播要的是「尽快出画」。
  static const int _startupBufferBytes = 16 * 1024 * 1024;

  /// 稳态缓存上限：首帧后按实测吞吐在 32~96MB 之间自适应。
  ///
  /// 不要再往大调：mpv 的 cache-buffering-state 是「缓存填满多少」，
  /// 上限设 192~256MB 时 4K 码率下要缓很久才填满，界面就长期停在
  /// 「缓冲中 99%」。而且代理层已经把整集预热到本地，mpv 这层只需要
  /// 一小段前向缓冲兜住解复用抖动即可，两层都做大是重复占用。
  static const int _minSteadyBufferBytes = 32 * 1024 * 1024;
  static const int _steadyBufferBytes = 64 * 1024 * 1024;
  static const int _maxSteadyBufferBytes = 96 * 1024 * 1024;
  static const int _backBufferBytes = 8 * 1024 * 1024;

  /// 按实测吞吐挑稳态缓冲：取「约 30 秒的码率量」，夹在 32~96MB。
  /// 网络一般（2MB/s）约 60MB，网络很好（8MB/s）到上限 96MB。
  static int _steadyBufferFor(double? throughput) {
    if (throughput == null || throughput <= 0) return _steadyBufferBytes;
    final target = (throughput * 30).round();
    return target.clamp(_minSteadyBufferBytes, _maxSteadyBufferBytes);
  }

  /// mpv demuxer 预读秒数（demuxer-readahead-secs）：配合 192MiB 缓存，
  /// 网络好时把后续内容尽量读进本地，播放过程不中断。
  static const String _readaheadSeconds = '120';

  /// 起播「还在进展」时的最长等待：只要代理层还在往下拉字节，
  /// 就不把这次 open 判成失败。
  ///
  /// 原先是死等 [readyTimeout]（20 秒），大分片 4K 源（单片 13~22MB）
  /// 在网络很好的情况下也可能超过 20 秒 —— 于是「好线路被判定成不可用」
  /// 并触发自动换线（用户报障原话）。现在改成：有字节进来就继续等，
  /// 只有「连续 [_stallTimeout] 没有任何进展」才算真失败。
  static const Duration _openHardCap = Duration(minutes: 2);

  /// 看门狗采样间隔。
  static const Duration _watchdogTick = Duration(seconds: 2);

  /// 停摆判定门槛：连续 [stall] 完全没有字节流动才算失败候选
  /// （原 12 秒太激进，4K 高码率 seek / 起播都可能超过 12 秒）。
  static const Duration _stallTimeout = Duration(seconds: 30);

  /// 救援链里 refreshPlay / 同地址 reopen 各自先试几次。
  static const int _rescueTries = 2;

  /// mpv 磁盘缓存目录：放在系统临时目录，按播放实例隔离。
  ///
  /// 4K 码率高，磁盘缓存不设上限会一直涨。这里用实例 id 隔离，
  /// 播放器 dispose 时整目录删掉；另外在创建时顺手清理过期目录，
  /// 避免异常退出（被杀进程）留下的残留越积越多。
  String get _diskCacheDir =>
      '${Directory.systemTemp.path}/fx_mpv_cache/$_instanceId';

  static int _instanceSeq = 0;
  final String _instanceId = 'p${DateTime.now().microsecondsSinceEpoch}_${_instanceSeq++}';

  /// 本地分片代理的缓存上限（字节）。
  ///
  /// 无限预加载要把整集拉到本地，缓存太小会「拉进来又被淘汰」，
  /// 拖回去还得重下。按设备内存的 1/8 给，夹在 512MB~2GB。
  static int get _proxyCacheLimit {
    final total = _deviceMemoryMb();
    if (total <= 0) return 512 * 1024 * 1024;
    final bytes = (total * 1024 * 1024) ~/ 8;
    const min = 512 * 1024 * 1024;
    const max = 2 * 1024 * 1024 * 1024;
    return bytes.clamp(min, max);
  }

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

  /// 清理超过 1 天没动过的缓存目录（异常退出的残留）。
  static Future<void> _sweepStaleCacheDirs() async {
    try {
      final root = Directory('${Directory.systemTemp.path}/fx_mpv_cache');
      if (!await root.exists()) return;
      final now = DateTime.now();
      await for (final e in root.list()) {
        if (e is! Directory) continue;
        try {
          final st = await e.stat();
          if (now.difference(st.modified) > const Duration(days: 1)) {
            await e.delete(recursive: true);
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 同一次播放最多进几轮救援链。没有这个上限时，每轮救援结束都会
  /// 重置 _lastFlowAt，于是又能再等 30 秒 → 再救 → 再等，表现就是
  /// 「一直卡在那几秒、一直循环」。超过上限就把错误交给页面（换线路 / 提示），
  /// 不再无限重连。
  static const int _maxRescueRounds = 3;

  /// 救援重开时等待新流首帧 / 时长的上限。
  static const Duration _rescueOpenTimeout = Duration(seconds: 8);

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
  bool _playIntent = false;
  int _decodeErrorSerial = 0;
  int _openToken = 0;

  /// 画面层代际：每次真正 open（含救援链重开）都 +1。
  ///
  /// 内部救援重开同样要通知共享画面层重新挂载。重挂是画面输出异常的
  /// 恢复措施，不代表已证明具体设备的黑屏一定由旧纹理造成；真实显示
  /// 仍需要设备验证，解码截图只能证明解码器产生了画面。
  int _renderEpoch = 0;

  /// 当前画面层代际；页面在监听回调里比对它来决定是否重建 Video。
  int get renderEpoch => _renderEpoch;
  Completer<void>? _ready;
  Timer? _cacheGuardTimer;

  // ------------------------------------------------- 看门狗 / 救援链状态

  /// 无字节流动看门狗（30 秒门槛）。
  Timer? _watchdogTimer;

  /// 最近一次「有字节流动」的时间；停摆计时从它开始。
  DateTime _lastFlowAt = DateTime.now();

  /// 本次播放已执行的救援轮数。
  int _rescueRounds = 0;
  Duration _lastFlowPos = Duration.zero;
  Duration _lastFlowBuffered = Duration.zero;
  double _lastFlowPct = -1;
  int? _lastFlowStreamPos;

  // 网络/音频进度仍前进时，也单独检查视频时间戳，避免音频掩盖视频停摆。
  double? _lastVideoPts;
  Duration _lastVideoPosition = Duration.zero;
  DateTime _lastVideoAt = DateTime.now();
  bool _videoProbeBusy = false;

  /// 救援链正在执行（防止看门狗 / 错误事件重复进入）。
  bool _rescueBusy = false;

  /// 救援代际：新的 open / dispose 会推进它，进行中的救援立即让位。
  int _rescueGen = 0;

  /// 救援重开期间把进度显示钉在原位置，避免 UI / 进度回写读到 0。
  bool _rescueHold = false;

  /// 停摆期间我们主动点亮的「缓冲中」，恢复后要自己熄灭。
  bool _stallIndicated = false;

  /// 救援重开时等待新流就绪（首帧 / 时长 / 位置）的信号。
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

  /// 本集是否已经把起播小缓冲提升到稳定值。
  bool _cacheRaised = false;

  /// 当前生效的前向缓冲字节数。首帧后按实测网速定，之后兜底定时器
  /// 复用它，避免把自适应结果覆盖成固定值。
  int _currentForwardBuffer = _startupBufferBytes;

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
  /// [rescueLines] 是无感救援链第③步：播放中出现任何失败 / 停摆时，
  /// 播放器内部按 ①refreshPlay 换地址 ②同地址重新 open 并 seek 回原进度
  /// ③换下一条线路 的顺序静默自救（①②各先试 2 次），三步都失败才把
  /// 「播放中断」一次性抛给页面；不传则跳过第③步。
  /// 打不开、解码失败或超时会抛出 [FxPlayerException]，方便上层切换备用地址。
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
    // 新的 open 取代正在进行的救援链。
    _rescueGen++;
    _rescueBusy = false;
    _rescueHold = false;
    _rescueRounds = 0;
    _cacheRaised = false;
    _lastVideoPts = null;
    _lastVideoAt = DateTime.now();
    _value = const FxPlayerValue();
    _notify();
    // 记住当前播放源：救援链（refresh → 重开 → 换线路）全程要用。
    _sourceUrl = url;
    _sourceHeaders = headers;
    _sourceDirect = direct;
    _refreshPlay = refreshPlay;
    _onPlayExpired = onPlayExpired;
    _lineRescue = rescueLines;
    final ready = Completer<void>();
    _ready = ready;
    // 如果 open 自身先抛错而没来得及 await ready，提前吞掉这个错误，
    // 避免出现未处理的异步异常。
    unawaited(ready.future.catchError((Object _) {}));
    try {
      // 1) 直链 HLS 走本机代理（多连接 Range + 预取），代理失败回退直连；
      //    非代理路径保留原有 m3u8 预热。被新 open 取代时返回 null 静默让位。
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
      // 2) 交给 mpv：12MB 小缓冲先出画，open 发出后立刻调到 96MiB。
      //
      // 这里**不能**再用 readyTimeout 一刀切：_openMedia 内部要先等本地代理
      // 起好、mpv 接受 URL，大分片源在这一步就可能超过 20 秒。
      // 用 _openHardCap 兜底，真正的「卡死」由后面的 _awaitReadyOrProgress
      // 按下载进展判定，避免把慢线路误判成坏线路。
      await _openMedia(
        source,
        play: play,
        token: token,
      ).timeout(_openHardCap);
    } catch (error) {
      if (_disposed || token != _openToken) {
        // 已被新的播放请求取代：不报错，也不去污染新 open 的状态。
        if (identical(_ready, ready)) _ready = null;
        return;
      }
      if (identical(_ready, ready)) _ready = null;
      _fail('$error');
      throw FxPlayerException('$error');
    }
    if (_disposed || token != _openToken) return;
    try {
      // 不再用固定的 readyTimeout 死等：那会把「大分片加载慢」误判成
      // 「线路不可用」并自动换线。这里只要代理层还在拉字节就一直等，
      // 连续 _stallTimeout 毫无进展才放弃；另外加一个硬上限兜底。
      await _awaitReadyOrProgress(ready.future, token);
    } finally {
      if (identical(_ready, ready)) _ready = null;
    }
    // 首帧 / 时长已就绪：把起播小缓冲动态升到 96MiB，长播更稳。
    _raiseCacheAfterStart();
  }

  /// 等首帧，但把「还在下载」和「卡死」区分开。
  ///
  /// 判据是代理层的已下载字节数：数值在涨就说明线路活着，继续等；
  /// 连续 [_stallTimeout] 字节不动才算这次 open 失败。整体另有
  /// [_openHardCap] 硬上限。
  Future<void> _awaitReadyOrProgress(Future<void> ready, int token) async {
    final startedAt = DateTime.now();
    var lastBytes = -1;
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

      final proxy = _hlsProxy;
      final bytes = proxy == null ? -1 : proxy.cacheBytes;
      final now = DateTime.now();
      if (bytes > lastBytes) {
        lastBytes = bytes;
        lastProgressAt = now;
      }
      // 直连（没有代理）时无从判断进度，退回按 readyTimeout 兜底。
      final idle = proxy == null
          ? now.difference(startedAt)
          : now.difference(lastProgressAt);
      if (idle >= _stallTimeout) {
        _logFx('OPEN 放弃：${idle.inSeconds}s 无下载进展');
        _fail('播放超时，线路可能不可用');
        throw const FxPlayerException('播放超时');
      }
      if (now.difference(startedAt) >= _openHardCap) {
        _logFx('OPEN 放弃：超过硬上限 ${_openHardCap.inSeconds}s');
        _fail('播放超时，线路可能不可用');
        throw const FxPlayerException('播放超时');
      }
    }
  }

  /// 解析出真正交给 mpv 的地址：直链先过本地分片代理（代理失败回退
  /// 直连），非代理路径做 m3u8 预热。返回 null = 这次 open 已被取代。
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
    if (direct) {
      // 缓存上限按设备内存定：无限预加载要把整集尽量拉下来，
      // 512MB 对 1080P（一集 300~600MB）刚好够，但对 4K 完全不够。
      // 这里取可用内存的 1/8，夹在 512MB~2GB：
      //   · 6GB 机 → 768MB   · 8GB 机 → 1GB   · 12GB 机 → 1.5GB
      // 上限同时被 mpv 那层（demuxer 96MB）和系统可用内存兜住，
      // 不会因为开太大把整机拖垮。
      final proxy = _hlsProxy ??= LocalHlsProxy(
        log: debugPrint,
        cacheLimitBytes: _proxyCacheLimit,
      );
      try {
        // 超时不能在 4 秒就放弃代理：平台线路首次代理要做签名重写 +
        // 拉整集列表，很容易超过 4 秒。一旦超时就会回退直连并销毁代理，
        // 之后所有抖动都直连裸奔 —— 这就是「掉线」的主因。
        // 放宽到 20 秒，且超时只当作「这次慢」而不是「代理不可用」。
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
            // 8 秒拿不到本地列表就回退直连：代理的意义是「更快更稳」，
            // 一旦它比直连还慢，就不该让用户继续等。代理实例保留不销毁。
            .timeout(const Duration(seconds: 8));
        if (_disposed || token != _openToken) return null;
        if (localUrl.isNotEmpty) {
          playbackUrl = localUrl;
          playbackHeaders = const <String, String>{};
          proxied = true;
        }
      } catch (error) {
        debugPrint('FxPlayer: 本地 HLS 代理本次启动失败，回退直连: $error');
        // 注意：不销毁代理。之前失败就 dispose + 置空，导致后面整段播放
        // 都直连裸奔（失去整集预热、失去签名刷新），表现就是「经常掉线」。
        // 代理实例本身是好的，只是这一次没能在时限内就绪，留着给下次复用。
      }
    }
    if (_disposed || token != _openToken) return null;

    // 非代理路径保留原有 m3u8 预热；代理路径本身已经拉过列表并预取。
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

  /// 把地址交给 mpv：先按 24MB 起播（首帧优先），首帧后按实测吞吐
  /// 把 demuxer 缓存在 64~256MB 之间自适应，并加大 readahead。
  Future<void> _openMedia(
    _PlaybackSource source, {
    required bool play,
    required int token,
  }) async {
    await _setCacheLimits(_startupBufferBytes);
    if (_disposed || token != _openToken) {
      throw StateError('open 已被新的播放请求取代');
    }
    final opening = _player.open(
      Media(
        source.url,
        httpHeaders: source.headers.isEmpty ? null : source.headers,
      ),
      // 立即解除暂停，先出画面，不等 duration / 全部元数据。
      play: play,
    );
    // 这次 open 会重建 mpv 的视频输出：画面层代际 +1，通知页面重建 Video，
    // 否则救援链重开之后就是「有声音没画面」。
    _renderEpoch++;
    _notify();
    _lastVideoPts = null;
    _lastVideoAt = DateTime.now();
    unawaited(_setCacheLimits(_steadyBufferBytes));
    await opening;
  }

  /// 首帧后按实测吞吐提升前向缓存；每集只升一次。
  ///
  /// 网络好（代理已整集预热，吞吐样本很快就有）直接给到 192~256MB，
  /// 长播不再回源；网络一般则停在 64~128MB，避免为了不可能的带宽
  /// 去占内存、也避免起播阶段等太久。
  void _raiseCacheAfterStart() {
    if (_disposed || _cacheRaised) return;
    _cacheRaised = true;
    final throughput = _hlsProxy?.recentThroughput;
    _currentForwardBuffer = _steadyBufferFor(throughput);
    unawaited(_setCacheLimits(_currentForwardBuffer));
  }

  /// 限制 demuxer 前向 / 回看缓存并固定 60 秒预读（demuxer-readahead-secs，
  /// 4K 高码率 seek / 抖动后不至于瞬间断粮）；mpv 会按新上限回收旧缓存，
  /// 长播时不会因为回看缓存累积而内存无限增长。
  Future<void> _setCacheLimits(int forwardBytes) async {
    if (_disposed) return;
    _currentForwardBuffer = forwardBytes;
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty('demuxer-max-bytes', '$forwardBytes');
      await platform.setProperty('demuxer-max-back-bytes', '$_backBufferBytes');
      await platform.setProperty('demuxer-readahead-secs', _readaheadSeconds);
      // 直连模式下没有客户端代理的整集缓存，开启 mpv 自己的磁盘缓存：
      // 已播过的分片留在本地，往回 seek / 短暂卡顿都不用重新下载。
      // 4K 码率高，磁盘缓存比内存划算，也不会占用 App 内存。
      // 目录必须先存在，否则 mpv 会静默放弃磁盘缓存。
      try {
        unawaited(_sweepStaleCacheDirs());
        final dir = Directory(_diskCacheDir);
        if (!await dir.exists()) await dir.create(recursive: true);
      } catch (_) {
        // 建目录失败就只用内存缓存，不影响播放。
      }
      await platform.setProperty('cache', 'yes');
      await platform.setProperty('cache-on-disk', 'yes');
      await platform.setProperty('cache-dir', _diskCacheDir);
      await platform.setProperty('demuxer-max-back-bytes', '$_backBufferBytes');
      // ── 以下四条照搬腾讯云播放器的策略（从咕噜 APK 的 droppedCap /
      //    concurrentThreads 逆出来的思路），目的是「网络一抖不卡死」：
      //
      // 1) video-sync=audio：以音频为主时钟。默认的 display-resample 会在
      //    掉帧时反复微调音调，弱网下表现为声音发飘；跟音频走最稳。
      await platform.setProperty('video-sync', 'audio');
      // 2) framedrop=vo：解码跟不上时**丢帧**而不是停下来等。
      //    腾讯云的 droppedCap 就是这个语义 —— 宁可少几帧，也不要卡住。
      await platform.setProperty('framedrop', 'vo');
      // 3) 解码线程数按 CPU 核数给（腾讯云的 concurrentThreads）。
      //    太少解不动 4K，太多抢 CPU 反而掉帧。
      final cores = Platform.numberOfProcessors;
      final threads = cores <= 4 ? 2 : (cores <= 6 ? 3 : 4);
      await platform.setProperty('vd-lavc-threads', '$threads');
      // 4) cache-pause-wait 调小：缓冲补到 1.5 秒就继续播，
      //    默认 10 秒意味着「卡一下要等满 10 秒才恢复」。
      await platform.setProperty('cache-pause-wait', '1.5');
    } catch (_) {
      // 旧版本 / 特殊平台没有这些属性时静默跳过。
    }
  }

  Future<void> play() {
    _playIntent = true;
    // 成员同步可能在救援期间请求 play；先记意图，落点验证完成后执行。
    if (_rescueHold) return Future<void>.value();
    return _player.play();
  }

  Future<void> pause() {
    _playIntent = false;
    return _player.pause();
  }

  /// 显式播放意图与缓冲状态分开，防止报错亮缓冲后把主动暂停误当播放。
  Future<void> playOrPause() => _player.state.playing ? pause() : play();

  /// 播放器真实播放状态（libmpv 当前值），按钮图标以此为准。
  bool get isPlaying => _player.state.playing;

  /// libmpv 当前真实倍速；跨页面交接时以此为准，避免本地状态落后。
  double get rate => _player.state.rate;

  /// 播放状态流；页面可用它驱动播放 / 暂停图标。
  Stream<bool> get playingStream => _player.stream.playing;

  Future<void> seek(Duration position) => _player.seek(position);

  /// 兼容 video_player 命名。
  Future<void> seekTo(Duration position) => seek(position);

  /// 切后台回来后的自愈：确认 mpv 还在出画、进度没被系统重置。
  ///
  /// Android 在后台可能回收音频焦点 / 冻结进程，回前台时 libmpv 会停在
  /// 「有 duration 但位置不再推进、playing 变 false」的半死状态，也可能
  /// 被系统 seek 回 0 —— 用户手动点播放就从片头重来（报障原话）。
  ///
  /// [expected] 是切后台那一刻的位置；[wasPlaying] 是切后台那一刻是否在播。
  /// 用户切后台前就主动暂停的，回前台绝不自动续播，只按需把进度拉回去。
  ///
  /// 返回是否做了自愈（页面可据此刷新进度条）。
  Future<bool> recoverAfterBackground(
    Duration expected, {
    bool wasPlaying = true,
  }) async {
    if (_disposed) return false;
    final v = _value;
    if (!v.isInitialized || v.hasError) return false;
    final pos = v.position;
    // 位置被系统重置到片头 / 明显回退。
    final rewound =
        expected > const Duration(seconds: 5) &&
        pos + const Duration(seconds: 3) < expected;
    // 冻结：本该在播却停了（系统收回音频焦点 / 进程被挂起）。
    final frozen = wasPlaying && !v.isPlaying;
    if (!rewound && !frozen) return false;
    _logFx(
      'RESUME 自愈：rewound=$rewound frozen=$frozen wasPlaying=$wasPlaying '
      'pos=${pos.inSeconds}s target=${expected.inSeconds}s',
    );
    try {
      if (rewound) await _player.seek(expected);
      // 只有本来就在播的才恢复播放；用户主动暂停的保持暂停。
      if (wasPlaying) await play();
      _lastFlowAt = DateTime.now();
      _lastFlowPos = expected;
      return true;
    } catch (error) {
      _logFx('RESUME 自愈失败: $error');
      return false;
    }
  }

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
    // 救援链 / 看门狗在释放后一律停手。
    _rescueGen++;
    _rescueBusy = false;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _cacheGuardTimer?.cancel();
    _cacheGuardTimer = null;
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
    // 删掉本实例的 mpv 磁盘缓存目录：4K 码率高，不清理会一直占存储。
    try {
      final dir = Directory(_diskCacheDir);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // 删除失败留待下次启动的过期清理。
    }
  }

  // ------------------------------------------------------------- internals

  void _bindStreams() {
    _subscriptions.add(
      _player.stream.position.listen((position) {
        // 救援重开期间新流的 position 会先归零：保留原进度显示，
        // 避免 UI 进度条 / 观看进度回写读到 0。
        if (position > Duration.zero) _signalMediaReady();
        final shown = recoveryVisiblePosition(
          holding: _rescueHold,
          previous: _value.position,
          incoming: position,
        );
        final initialized = _value.isInitialized || position > Duration.zero;
        _setValue(_value.copyWith(isInitialized: initialized, position: shown));
      }),
    );
    _subscriptions.add(
      _player.stream.duration.listen((duration) {
        if (duration > Duration.zero) _signalMediaReady();
        if (_rescueHold && duration <= Duration.zero) return;
        _setValue(
          _value.copyWith(
            isInitialized: _value.isInitialized || duration > Duration.zero,
            duration: duration,
          ),
        );
      }),
    );
    _subscriptions.add(_player.stream.videoParams.listen(_onVideoParams));
    _subscriptions.add(
      _player.stream.buffering.listen((buffering) {
        _setValue(_value.copyWith(isBuffering: _rescueHold || buffering));
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
        if (_rescueHold) return;
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
      // 新流出画面尺寸 = 首帧就绪信号（救援重开用它判断这步是否成功）。
      _signalMediaReady();
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

  /// mpv / media_kit 报错入口。
  ///
  /// - seek / 切集时 mpv 主动取消产生的 canceled 不算失败（也不会触发
  ///   refreshPlay / onPlayExpired）；
  /// - 首帧还没出来：保持旧行为，把错误抛给 open 的调用方去试备用地址；
  /// - 首帧之后的任何失败：静默进入三步救援链，期间只显示「缓冲中」。
  void _onError(String message) {
    if (_disposed) return;
    if (_looksCancelled(message)) {
      _logFx('忽略 mpv 取消事件(cancelled 不算失败): $message');
      return;
    }
    _decodeErrorSerial++;
    // 救援重开正在等新流就绪：立刻结束等待，让这一步判失败。
    final mediaReady = _mediaReady;
    if (mediaReady != null && !mediaReady.isCompleted) {
      mediaReady.completeError(FxPlayerException(message));
    }
    final ready = _ready;
    if (ready == null && _value.isInitialized) {
      // 播放中出错：静默走救援链，绝不弹错误层。
      _logFx('播放中报错，进入救援链: $message');
      _stallIndicated = true;
      _setValue(
        _value.copyWith(hasError: false, errorText: '', isBuffering: true),
      );
      unawaited(_runRescue('播放错误: $message'));
      return;
    }
    _value = _value.copyWith(hasError: true, errorText: message);
    _notify();
    if (ready != null && !ready.isCompleted) {
      ready.completeError(FxPlayerException(message));
    }
  }

  void _fail(String message) {
    if (_disposed) return;
    _value = _value.copyWith(hasError: true, errorText: message);
    _notify();
  }

  // ------------------------------------------------- 看门狗 / 无感救援链

  /// 每 2 秒采样一次：只有「完全无字节流动」才累计停摆时间。
  ///
  /// 缓冲中（字节仍在进来）绝不计入失败，也不弹错误层，只让页面显示
  /// 「缓冲中 xx%」；连续 [_stallTimeout]（30 秒）毫无流动才进救援链。
  /// 把代理层的真实起播进度 / 下载速度同步到 value。
  ///
  /// 每 2 秒一次（跟看门狗同频）：够平滑，也不会因为高频 setState
  /// 让播放页每帧重建。
  /// 把「起播进度 + 实时网速」同步到 value。
  ///
  /// 两条来源：
  ///  · 走了本地代理（平台线路）：用代理层按真实下载字节算的进度和速度，
  ///    这是最准的；
  ///  · 直连 mpv（采集线路：红牛 / 量子 / 蓝光 / 4K）：代理层根本不存在，
  ///    之前 speed 恒为 0 —— 用户看到的就是「没有实时网速」。
  ///    这里改用 mpv 自己的 `cache-speed`（字节/秒）读速度。
  void _syncProxyProgress() {
    final proxy = _hlsProxy;
    final pct = proxy?.startupPercent ?? _value.measuredBufferPercent;
    double speed = proxy?.liveSpeed ?? 0;
    // 代理不存在或还没测到速度时，退回 mpv 的 cache-speed。
    if (speed <= 0 && _cachedMpvSpeed > 0) speed = _cachedMpvSpeed;
    if (pct == _value.measuredBufferPercent && speed == _value.bytesPerSecond) {
      return;
    }
    _setValue(
      _value.copyWith(
        measuredBufferPercent: pct,
        bytesPerSecond: speed,
      ),
    );
  }

  /// mpv `cache-speed`（字节/秒）的最近一次读数。
  ///
  /// 单独缓存在这里，而不是每次同步都去 getProperty —— 读属性要走
  /// 平台通道，2 秒一次已经够；读失败就保持上一次的值，不要闪成 0。
  double _cachedMpvSpeed = 0;

  /// 从 mpv 读实时下载速度（cache-speed，字节/秒）。直连线路用它显示网速。
  Future<void> _readMpvSpeed() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    if (_disposed || _rescueBusy) return;
    try {
      final raw = await platform
          .getProperty('cache-speed', waitForInitialization: false)
          .timeout(const Duration(seconds: 1));
      final v = double.tryParse(raw.trim());
      if (v != null && v.isFinite && v >= 0) _cachedMpvSpeed = v;
    } catch (_) {
      // 不支持此属性 / 读取超时：保持上一次的值，不清零。
    }
  }

  Future<void> _watchdogTickAsync() async {
    if (_disposed || _rescueBusy) return;
    // 直连线路没有代理层，速度只能问 mpv。
    if (_hlsProxy == null) await _readMpvSpeed();
    _syncProxyProgress();
    final v = _value;
    // 救援 / 最终失败之后都由新的 open 接管，看门狗不再自作主张。
    if (v.hasError) return;
    if (_opening != null ||
        _ready != null ||
        !v.isInitialized ||
        v.isCompleted) {
      _lastFlowAt = DateTime.now();
      return;
    }
    // 用户主动暂停（非缓冲暂停）的时间不计入停摆。
    if (!v.isPlaying && !v.isBuffering) {
      _lastFlowAt = DateTime.now();
      _clearStallIndication();
      return;
    }
    await _checkVideoProgress();
    if (_disposed || _rescueBusy) return;
    final flowing = await _bytesFlowing();
    if (_disposed || _rescueBusy) return;
    if (flowing) {
      _lastFlowAt = DateTime.now();
      _clearStallIndication();
      return;
    }
    // 没有字节流动：只亮「缓冲中 xx%」，错误层一步都不碰。
    if (!_stallIndicated) {
      _stallIndicated = true;
      _setValue(_value.copyWith(isBuffering: true));
    }
    final stalled = DateTime.now().difference(_lastFlowAt);
    if (stalled < _stallTimeout) return;
    unawaited(_runRescue('连续 ${stalled.inSeconds}s 无字节流动'));
  }

  Future<void> _checkVideoProgress() async {
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) {
      // 系统允许后台只解音频，不能把后台视频停摆当成断流。
      _lastVideoAt = DateTime.now();
      _lastVideoPts = null;
      return;
    }
    final platform = _player.platform;
    if (_videoProbeBusy || platform is! NativePlayer) return;
    _videoProbeBusy = true;
    final token = _openToken;
    try {
      final raw = await platform
          .getProperty('video-pts', waitForInitialization: false)
          .timeout(const Duration(seconds: 1));
      if (_disposed || token != _openToken || _rescueBusy) return;
      final pts = double.tryParse(raw);
      if (pts == null ||
          !pts.isFinite ||
          !_value.isPlaying ||
          _value.isBuffering) {
        // 不支持此属性时不猜测。未就绪/正常缓冲也不算视频卡死。
        _lastVideoPts = null;
        _lastVideoAt = DateTime.now();
        return;
      }
      final previous = _lastVideoPts;
      final audioAdvanced = _value.position > _lastVideoPosition;
      _lastVideoPosition = _value.position;
      _lastVideoPts = pts;
      if (previous == null || (pts - previous).abs() > .001 || !audioAdvanced) {
        _lastVideoAt = DateTime.now();
      } else if (DateTime.now().difference(_lastVideoAt) >= _stallTimeout) {
        _logFx('VIDEO 视频时间戳停摆，音频状态=${_value.isPlaying}');
        unawaited(_runRescue('视频时间戳连续30秒未推进'));
      }
    } catch (_) {
      _lastVideoAt = DateTime.now();
      _lastVideoPts = null;
    } finally {
      _videoProbeBusy = false;
    }
  }

  /// 字节是否还在流动：位置 / 已缓存时长 / 缓冲百分比 / stream-pos
  /// 任一有变化即算流动，只有全都纹丝不动才算停摆。
  Future<bool> _bytesFlowing() async {
    final v = _value;
    final posMoved = v.position != _lastFlowPos;
    final bufferedMoved = v.buffered != _lastFlowBuffered;
    final pctMoved = v.bufferingPercentage != _lastFlowPct;
    _lastFlowPos = v.position;
    _lastFlowBuffered = v.buffered;
    _lastFlowPct = v.bufferingPercentage;
    var streamMoved = false;
    final streamPos = await _readStreamPos();
    if (streamPos != null) {
      final previous = _lastFlowStreamPos;
      _lastFlowStreamPos = streamPos;
      // 首次采样视为有流动，避免刚起播就误判停摆。
      streamMoved = previous == null || previous != streamPos;
    }
    if (_disposed) return true;
    return posMoved || bufferedMoved || pctMoved || streamMoved;
  }

  /// 读 mpv 的 stream-pos（当前流的字节位置）；读不到就退回
  /// position / 缓存时长这些信号，不影响看门狗工作。
  Future<int?> _readStreamPos() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return null;
    try {
      final raw = await platform.getProperty(
        'stream-pos',
        waitForInitialization: false,
      );
      return int.tryParse(raw.trim());
    } catch (_) {
      return null;
    }
  }

  /// 字节恢复流动 / 暂停：熄灭我们自己点亮的「缓冲中」。
  void _clearStallIndication() {
    if (!_stallIndicated) return;
    _stallIndicated = false;
    _setValue(_value.copyWith(isBuffering: false));
  }

  /// 救援重开时的新流就绪信号（首帧 / 时长 / 位置任一到达）。
  void _signalMediaReady() {
    // 首帧已出：放开本地代理的整集预热。
    //
    // 对标咕噜咕噜的做法 —— 它的 APK 里有两条明确日志：
    //   「Playlist preload paused:」（起播期间暂停预取）
    //   「Rebalanced to deepen protected next preload:」（首帧后再加深预取）
    // 也就是说它**先保证首片拿满带宽，再开始后台预热**。
    // 我们之前一拿到播放列表就开 6 路预取，首片被挤到后面排队，
    // 这就是「4K 起播比它慢」的直接原因。
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

  /// 无感救援链：① refreshPlay 换地址 ② 同地址重新 open 并 seek 回原进度
  /// ③ 换下一条线路 seek 回原进度；①② 各先试 2 次。
  /// 全程静默（画面保持 + 「缓冲中」），三步都失败才报一次「播放中断」。
  /// 直播（[live]）不 seek，步骤② 直接重 open 直播地址。
  /// 回前台自检：切后台期间流可能已经断了（系统冻结进程 / 连接被回收），
  /// 回前台时只重挂画面层是不够的 —— 必须确认还在播，否则自动重连。
  ///
  /// 与 [_runRescue] 的区别：这里允许在 hasError 状态下执行（断流后
  /// value 就是 hasError），并清掉错误态重新打开同一个地址，避免
  /// 用户看到「加载失败」还得手动点重试。
  Future<void> resumeSelfCheck() async {
    if (_disposed || _rescueBusy) return;
    final v = _value;
    final url = _sourceUrl;
    if (url.trim().isEmpty) return;
    final wantPlay = _playIntent;
    final target = v.position > Duration.zero ? v.position : _lastFlowPos;

    // 判定是否需要重连：报错 / 未初始化 / 本该在播却不动。
    final needReopen = v.hasError;
    if (!needReopen) {
      // 没报错也要确认真的在走：给 1.2 秒观察位置是否推进。
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
    try {
      _setValue(
        _value.copyWith(isBuffering: true, hasError: false, errorText: ''),
      );
      // 平台线路先换新签名（后台待久了签名多半已过期）。
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
      await _player.open(Media(url, httpHeaders: headers.isEmpty ? null : headers));
      if (_disposed || gen != _rescueGen) return;
      if (target > Duration.zero) {
        await _player.seek(target);
        if (_disposed || gen != _rescueGen) return;
      }
      if (wantPlay) await _player.play();
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
      // 交给页面决定是否提示，这里不强制报错。
    } finally {
      _rescueHold = false;
      _rescueBusy = false;
    }
  }

  Future<void> _runRescue(String reason) async {
    if (_disposed || _rescueBusy || _value.hasError) return;
    if (_rescueRounds >= _maxRescueRounds) {
      // 已经救过足够多轮还不行：说明这条线路本身不可用，
      // 停止无限重连，交给页面提示换线路。
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

  /// 救援链的一步：解析地址（代理 / 直连）→ 重新 open → 等新流就绪 →
  /// seek 回原进度 → 恢复播放。返回这一步是否成功。
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
      // 提前挂一个空错误监听，避免等待期间出错变成未处理异常。
      unawaited(mediaReady.future.catchError((Object _) {}));
      _mediaReady = mediaReady;
      // 只有「需要 seek 回原进度」的点播才先暂停打开：先播片头再 seek 会
      // 让用户听到一小段错位音频。直播没有进度可回，而且直播流在暂停态
      // 常常不产生首帧 / 时长，等 mediaReady 会白等到超时、把正常直播判死，
      // 所以直播（以及从 0 开始的点播）一律直接带 play 打开。
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
          await _player.seek(resume);
          _logFx('RESCUE 已 seek 回 ${resume.inSeconds}s');
        } catch (error) {
          _logFx('RESCUE seek 回原进度失败: $error');
          return false;
        }
      }
      if (_disposed || token != _openToken || gen != _rescueGen) return false;
      // 暂停态核实 seek 落点，避免高速播放后离开 ±5 秒窗口而误判。
      // duration / 音频进度不是视频恢复的证据。必须在本次 open 后
      // 能取到解码画面，并确认 seek 已落到目标附近，才算恢复成功。
      final deadline = DateTime.now().add(_rescueOpenTimeout);
      var verified = false;
      while (!_disposed &&
          token == _openToken &&
          gen == _rescueGen &&
          errorSerial == _decodeErrorSerial &&
          DateTime.now().isBefore(deadline)) {
        final position = _player.state.position;
        final landed = recoverySeekLanded(
          live: live,
          target: resume,
          actual: position,
        );
        if (landed) {
          try {
            // raw BGRA 避免高分辨率 JPEG 编码占满播放器锁。
            final frame = await _player
                .screenshot(format: null)
                .timeout(const Duration(seconds: 4));
            if (frame != null && frame.isNotEmpty) {
              verified = true;
              break;
            }
          } on TimeoutException {
            // timeout 不会取消底层截图；不再排队提交第二次截图。
            _logFx('RESCUE 解码画面检查超时');
            return false;
          } catch (_) {
            // 可能尚未解码出画面，在同一预算内等待下一次采样。
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (!verified ||
          _disposed ||
          token != _openToken ||
          gen != _rescueGen ||
          errorSerial != _decodeErrorSerial) {
        _logFx('RESCUE 未确认解码画面或 seek 落点，继续恢复链');
        return false;
      }
      if (_playIntent) await _player.play();
      if (_disposed || token != _openToken || gen != _rescueGen) return false;
      _sourceUrl = url;
      _sourceHeaders = headers;
      _sourceDirect = direct;
      _rescueHold = false;
      _stallIndicated = false;
      _setValue(
        _value.copyWith(
          position: _player.state.position,
          isPlaying: _player.state.playing,
          isBuffering: false,
        ),
      );
      _lastFlowAt = DateTime.now();
      _logFx('RESCUE 已确认解码画面与进度');
      return true;
    } catch (error) {
      _logFx('RESCUE 重开异常: $error');
      return false;
    }
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

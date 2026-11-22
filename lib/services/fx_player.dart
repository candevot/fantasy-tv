import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models.dart';
import 'auto_resume.dart';
import 'cms_bridge.dart';
import 'exo_player.dart';
import 'hls_segment_index.dart';
import 'iqiyi_codec.dart';
import 'line_enrich.dart';
import 'line_probe.dart';
import 'live_edge.dart';
import 'local_hls_proxy.dart';
import 'playback_progress.dart';
import 'playback_recovery.dart';
import 'play_log.dart';

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
    this.hasRenderedFirstFrame = false,
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
    this.timing = const PlaybackTiming.empty(),
    this.connectCount = 0,
    this.droppedFrames = 0,
    this.bufferedAhead = Duration.zero,
    this.bitrateKbps = 0,
    this.measuredKbps = 0,
    this.videoCodec = '',
    this.iqCodec = '',
    this.iqQuality = '',
    this.codecHint = '',
    this.bytesLoaded = -1,
    this.bytesLoadedPerSec = 0,
    this.isLoading = true,
    this.fatalError = '',
  });

  /// 是否已经拿到视频参数/时长，可以开始渲染与 seek。
  final bool isInitialized;

  /// 是否正在播放。
  final bool isPlaying;

  /// 是否正在缓冲。
  final bool isBuffering;

  /// 是否已经在屏幕上渲染出过一帧。
  ///
  /// FIRST_FRAME（2026-11-14）：这是「能不能收起加载层」的唯一判据。
  /// 以前的判据是 `isBuffering == false` / `isPlaying == true` /
  /// 「拿到视频尺寸」，这三种都可能在首帧真正上屏之前就成立 ——
  /// 用户看到的就是「缓冲层消失、画面还是黑的，还要再等一会儿」。
  ///
  /// 值来自原生 `Player.Listener.onRenderedFirstFrame()`；open / seek
  /// 会把它重置成 false，等新画面真的渲染出来再变 true。
  final bool hasRenderedFirstFrame;

  /// 实时下载速度（字节/秒）；0 表示还没测到。
  final double bytesPerSecond;

  /// 已缓冲的媒体时长（`max(ExoPlayer.bufferedPosition, 磁盘预取)`）。
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

  /// 本次 open 的分段耗时时间线（解析 / 清单 / 首帧 / 起播总）。
  ///
  /// DIAG（2026-11-15）：「起播诊断」浮层读这一份。默认 [PlaybackTiming.empty]
  /// 表示还没 open 过，界面据此显示「--」而不是 0ms。
  final PlaybackTiming timing;

  /// 起播至今 OkHttp connectStart 次数（连接池复用程度，越接近 1 越好）。
  final int connectCount;

  /// 累计丢帧。
  final int droppedFrames;

  /// 距当前播放位置还有多少内容可播（原生 `bufferedPosition - position`）。
  ///
  /// 注意与 [buffered] 的区别：[buffered] 是「已缓冲到的绝对位置」（喂进度条
  /// 灰条用），这个是「前面还压着多少秒」—— 诊断时看它才知道会不会卡。
  final Duration bufferedAhead;

  /// 视频轨道声明码率（kbps）；0 = 拿不到。
  final int bitrateKbps;

  /// OkHttp 实测吞吐（kbps）；0 = 还没测到。
  final int measuredKbps;

  /// 真实解码出的视频编码短名：`hevc` / `avc` / `av1` / `vp9`；'' = 未知。
  ///
  /// IQ_CODEC（2026-11-15）：爱奇艺线路「请求 HEVC、实际给 AVC」这件事
  /// 只有内核解出来的轨道说得清，诊断浮层的「编码」就取这里。
  final String videoCodec;

  /// 服务端响应头 `X-Iq-Codec`（`hevc` / `avc`）。
  final String iqCodec;

  /// 服务端响应头 `X-Iq-Quality`（如 `1920x1080`）。
  final String iqQuality;

  /// 本次 open 的地址**请求**的是哪种编码（`hevc` / `avc`）；'' = 非爱奇艺。
  ///
  /// 只是请求参数，不代表服务端真给了（降级后这里仍是 hevc），
  /// 所以诊断浮层把它排在最后一位，前面两位才是实测。
  final String codecHint;

  /// 本次 open 至今收到的正文字节；-1 = 老原生包 / 还没开始。
  ///
  /// SLOW_NET（2026-11-15）：「慢」和「死」的区别就在这几个数上 ——
  /// 字节在涨说明数据真的在下来（几十 KB/s 也是在下），
  /// 连续 8 秒三项全不动才是真卡死。
  final int bytesLoaded;

  /// 原生 1 秒采样算出的下载速度（字节/秒）；0 = 还没测到。
  final int bytesLoadedPerSec;

  /// 内核是否仍在加载（buffering / 首帧未渲染）。
  final bool isLoading;

  /// 原生判定的「真失败」码；空串 = 没有。
  ///
  /// 401/403/404/410/500/502/503、DNS、连接被拒、TLS、清单非法、0 分片
  /// 都归到这里：这些**不等 8 秒窗口**，拿到就立刻换线路。
  final String fatalError;

  /// 已下载量文案（`已下载 1.2MB`）；拿不到字节时为空串。
  ///
  /// 取原生字节数与「缓冲增量预估」的较大者：老原生包没有 bytesLoaded 时
  /// 仍然能给用户一个「在动」的数字。
  String get loadedText {
    final real = bytesLoaded;
    if (real > 0) return fxLoadedText(real);
    return '';
  }

  /// 真实网速文案（优先原生按块统计的真实速率，退回缓冲估算）；0 返回空串。
  ///
  /// NET_SPEED（2026-11-15）：格式和 `fxSpeedLabel`（player_theme）同一套
  /// —— MB 保留一位小数（`1.8 MB/s`），10 KB/s 以下也保留一位（`3.2 KB/s`），
  /// 以上取整（`320 KB/s`）。两处文案必须一致，否则顶栏和缓冲层会显示
  /// 两个不同的数。
  String get realSpeedText {
    final b = bytesLoadedPerSec > 0
        ? bytesLoadedPerSec.toDouble()
        : bytesPerSecond;
    if (b <= 0) return '';
    if (b >= 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1)} MB/s';
    final kb = b / 1024;
    if (kb < 10) return '${kb.toStringAsFixed(1)} KB/s';
    return '${kb.round()} KB/s';
  }

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

  /// 真实缓冲比例（0–100）= 已缓冲位置 ÷ 总时长；两者任一拿不到就返回
  /// null，UI 显示不带数字的转圈。
  ///
  /// BUFFER_PCT_REAL（2026-11-14）：以前这里有两个假数 ——
  ///   · 代理层按字节算的 measuredBufferPercent（直连时恒为 0）；
  ///   · 「已缓冲时长 ÷ 2 秒 × 100」，2 秒一到就顶到 100，界面又被
  ///     FxLoadingOverlay 夹到 99，于是用户看到的就是「一直 99%」。
  /// 现在只报真实值：bufferedPosition / duration。缓存停在 12% 就是 12%，
  /// 不会因为「够播了」而伪造出 99%。
  double? get bufferingPercent {
    final total = duration.inMilliseconds;
    final have = buffered.inMilliseconds;
    if (total <= 0 || have <= 0) return null;
    return (have / total * 100).clamp(0.0, 100.0).toDouble();
  }

  /// 把字节/秒格式化成「1.8 MB/s」/「320 KB/s」这类文案；0 返回空串。
  ///
  /// NET_SPEED（2026-11-15）：顶栏 / 一起看那条网速这里**必须**和缓冲层用
  /// 同一个数（原生按块统计的真实速率）。以前它只读 [bytesPerSecond]
  /// ——「缓冲位置推进量 ÷ 时间」的估算：HLS 分片整块落盘，缓冲阶段这个数
  /// 一直是 0，顶栏就跟着恒 0。现在和 [realSpeedText] 完全同源。
  String get speedText => realSpeedText;

  FxPlayerValue copyWith({
    bool? isInitialized,
    bool? isPlaying,
    bool? isBuffering,
    bool? hasRenderedFirstFrame,
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
    PlaybackTiming? timing,
    int? connectCount,
    int? droppedFrames,
    Duration? bufferedAhead,
    int? bitrateKbps,
    int? measuredKbps,
    String? videoCodec,
    String? iqCodec,
    String? iqQuality,
    String? codecHint,
    int? bytesLoaded,
    int? bytesLoadedPerSec,
    bool? isLoading,
    String? fatalError,
  }) {
    return FxPlayerValue(
      isInitialized: isInitialized ?? this.isInitialized,
      isPlaying: isPlaying ?? this.isPlaying,
      isBuffering: isBuffering ?? this.isBuffering,
      hasRenderedFirstFrame:
          hasRenderedFirstFrame ?? this.hasRenderedFirstFrame,
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
      timing: timing ?? this.timing,
      connectCount: connectCount ?? this.connectCount,
      droppedFrames: droppedFrames ?? this.droppedFrames,
      bufferedAhead: bufferedAhead ?? this.bufferedAhead,
      bitrateKbps: bitrateKbps ?? this.bitrateKbps,
      measuredKbps: measuredKbps ?? this.measuredKbps,
      videoCodec: videoCodec ?? this.videoCodec,
      iqCodec: iqCodec ?? this.iqCodec,
      iqQuality: iqQuality ?? this.iqQuality,
      codecHint: codecHint ?? this.codecHint,
      bytesLoaded: bytesLoaded ?? this.bytesLoaded,
      bytesLoadedPerSec: bytesLoadedPerSec ?? this.bytesLoadedPerSec,
      isLoading: isLoading ?? this.isLoading,
      fatalError: fatalError ?? this.fatalError,
    );
  }
}

/// 基于 ExoPlayer（Android Media3）的播放内核封装。
///
/// PLAYER_CORE（2026-11-13）：内核从 libmpv 换成 ExoPlayer，控件完全不变 ——
/// 页面只拿到一个画面视图，进度条 / 选集 / 手势全部还是我们自绘的。
/// 参考 FongMi/TV：它也是 ExoPlayer 内核 + 自绘控件。
///
/// 保留的东西（这些是稳定性的来源，跟内核无关）：
///   · 无感救援链：①换签名 ②同地址重开 ③换下一条线路，全程静默
///   · 无字节流动看门狗：连续 30 秒没进展才进救援，缓冲中不算失败
///   · HLS 起播预热：DNS + playlist + 前几片
///   · 高频位置通道：进度条独立订阅，不跟着整对象重建
///
/// 去掉的东西（ExoPlayer 原生就解决了，不需要我们再管）：
///   · demuxer-readahead-secs / cache-pause-wait / cache-buffering-state
///     那一整套 mpv 属性 —— 这是「加载慢 / 黑屏 / 卡 99」的根源。
///     ExoPlayer 的 DefaultLoadControl 按**时长**缓冲，自己调度分片。
class FxPlayer implements Listenable {
  FxPlayer._({this.readyTimeout = const Duration(seconds: 10)}) {
    _engine = ExoPlayerEngine();
    _engine.state.addListener(_onEngineState);
    unawaited(_engine.init());
    // STATE_POLL（2026-11-14）：不能只等 EventChannel 的事件。
    //
    // 250ms：进度条吃这个位置回调，
    // 500ms 会让进度条一跳一跳，250ms 看起来就顺了。
    //
    // 实测症状：画面已经出来了（ExoPlayer 在播），但 Dart 侧状态一直是
    // 初始值（buffering=true / position=0）——
    //   · UI 上「缓冲中」永远不消失
    //   · open() 等不到首帧，30 秒后判失败，用户看到「线路播不出来」
    // 原因就是事件没送达漏了。这里加 500ms 轮询兜底，
    // 直接调内核的 state 方法取快照，事件通道只当加速用。
    _pollTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_disposed) return;
      unawaited(_engine.poll());
    });
    // 稳定性看门狗：只看「进度 / 缓冲是否还在动」，缓冲中不算失败。
    _watchdogTimer = Timer.periodic(
      _watchdogTick,
      (_) => unawaited(_watchdogTickAsync()),
    );
  }

  /// 原生 `open` 这一次 MethodChannel 调用本身的超时（不含等首帧）。
  ///
  /// 原生在 `prepare()` 发出后立刻回包，正常 1~2 秒；30 秒只兜住
  /// 「原生一句话都不说」这种病态情况（JSON/线程卡死），不是首帧等待上限。
  static const Duration _openCallTimeout = Duration(seconds: 30);

  /// 慢网但**有进展**时的自动等待上限（SLOW_NET 2026-11-15）。
  ///
  /// 用户定稿：「只要任意一项在涨就无限延长等待（上限 120 秒）」。
  /// 所以这里到点**不判失败** —— 只写一条日志，把决定权交给页面上的
  /// 「继续等待 / 换条线路」两个按钮（见 `player_page.dart`）。
  /// 真卡死（连续 [fxStartupNoProgressWindow] 三项全不动）照旧立刻放弃。
  static const Duration _openSlowCap = fxSlowStartupCap;

  /// 上一次已处理过的「真失败」码（同一条地址只处理一次）。
  String _lastFatalCode = '';

  /// 本次 open 起播前对线路做健康预检的结果；null = 这次没预检。
  ///
  /// 页面用它打「probe line=幻想4K ok=true stage=segment」这类日志：
  /// 播放器不知道线路名，线路名只有页面有。
  FxLineProbeResult? get lastProbe => _lastProbe;

  FxLineProbeResult? _lastProbe;

  /// 预检结果回调（**只用于更新线路健康度 / 排序参考**，不参与起播判定）。
  ///
  /// PROBE_PARALLEL（2026-11-15）：预检已经改成和 open 并行跑，结果到得比
  /// open 早也早不早都无所谓 —— 页面拿它写 `LineHealth`（"播放页的预检也会
  /// 写进来，两边共用同一份档案"），下次详情页排序就会把这条线路降权。
  /// 播放器本身不碰这份档案：它不知道 vodId / 线路名，只有页面有。
  void Function(FxLineProbeResult result)? onProbeResult;

  /// 「上一集 / 下一集」回调（MEDIA_SESSION，2026-11-15）：delta = -1 / +1。
  ///
  /// 触发源全是**系统媒体控件**：通知栏媒体卡片的上一集/下一集按钮、锁屏
  /// 控件、耳机线控（双击切集）、车机方向盘、负一屏媒体中心。
  /// 播放器本身不切集（它只有一集的一条流），切集必须回页面做（页面才知道
  /// 集数列表、线路、播放地址），所以这里只把方向抛给页面。
  void Function(int delta)? onEpisodeStep;

  /// 已处理过的切集请求号（原生每次 +1）。
  int _lastBgStepSeq = 0;

  /// 看门狗采样间隔。ExoPlayer 的状态事件本来就不密，4 秒够。
  static const Duration _watchdogTick = Duration(seconds: 4);

  /// 停摆判定门槛：连续这么久完全没有进度 / 缓冲推进才算失败候选。
  ///
  /// ALIGN_FONGMI（2026-11-15）：两档门槛都抬高了（见
  /// `playback_recovery.dart` 的 [stallTimeoutFor]）：
  ///   · 起播（首帧未渲染）[startupStallTimeout] = 15 秒；
  ///   · 首帧出来后 [playbackStallTimeout] = 12 秒。
  /// 原生传输参数已经和壳对齐（连接 / 读超时 30s、默认 3 次重试），
  /// 原来的 6 秒比传输层还紧，正常波动会被判成死线路。

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
    Duration readyTimeout = const Duration(seconds: 10),
  }) {
    return FxPlayer._(readyTimeout: readyTimeout);
  }

  /// 等一次 `open` 完成，但按「**连续无进展**」判失败（SLOW_NET 2026-11-15）。
  ///
  /// 页面层原来写的是 `controller.open(...).timeout(8s)` —— 固定 8 秒，
  /// 慢网（几十 KB/s 拉 4K）必然误杀，于是「本来能播的线路被判死、越切越糟」。
  /// 现在页面层不再按总时长判，只做三件事：
  ///
  ///   1. 每 [fxProgressSampleInterval] 采一次 `bytesLoaded / buffered / position`
  ///      喂给 [progress]（页面也用它画「正在缓冲 xx% / 已下载 xx」）；
  ///   2. 连续 [noProgress]（默认 8 秒）三项全不动 → 抛 [FxPlayerException]，
  ///      这才叫真卡死；
  ///   3. 原生 `fatalError`（404 / DNS / TLS / 清单非法 / 0 分片）→ 立刻抛，
  ///      不等窗口。
  ///
  /// 慢但有进展时最多等 [fxSlowStartupCap]（30 秒硬上限）：到点直接抛，
  /// 页面立刻换下一条（不弹二选一）。
  static Future<T> awaitOpenProgress<T>(
    FxPlayer player,
    Future<T> open, {
    FxProgressWindow? progress,
    Duration? noProgress,
    void Function(
      FxProgressState verdict,
      FxProgressWindow window,
      Duration elapsed,
    )? onSample,
  }) async {
    final watch = Stopwatch()..start();
    final window =
        progress ?? FxProgressWindow(window: noProgress ?? fxStartupNoProgressWindow);
    if (noProgress != null) window.window = noProgress;
    var slowCapMs = fxSlowStartupCap.inMilliseconds;
    var lastLogMs = -1000;
    var finished = false;
    T? result;
    Object? error;
    StackTrace? stack;
    // 不 await：一边等 open，一边采样。open 自己的异常留到最后再抛，
    // 保证抛出的类型 / 栈和调用方直接 await 时一致。
    unawaited(
      open.then<void>(
        (v) {
          result = v;
          finished = true;
        },
        onError: (Object e, StackTrace st) {
          error = e;
          stack = st;
          finished = true;
        },
      ),
    );
    while (!finished) {
      await Future<void>.delayed(fxProgressSampleInterval);
      if (finished) break;
      final v = player.value;
      window.add(
        FxProgressSample(
          atMs: watch.elapsedMilliseconds,
          bytesLoaded: v.bytesLoaded,
          buffered: v.buffered,
          position: v.position,
          isLoading: v.isLoading,
        ),
      );
      final verdict = window.state;
      if (watch.elapsedMilliseconds - lastLogMs >= 2000) {
        lastLogMs = watch.elapsedMilliseconds;
        fxPlayLog(
          fxProgressLog(
            bytesDelta: window.bytesDelta,
            bufferedDeltaMs: window.bufferedDeltaMs,
            state: verdict,
            extra: 'stage=open firstFrame=${v.hasRenderedFirstFrame} '
                'stalled=${window.stalledFor.inMilliseconds}ms',
          ),
        );
      }
      onSample?.call(verdict, window, watch.elapsed);
      if (v.fatalError.isNotEmpty) {
        throw FxPlayerException('线路不可用(${v.fatalError})');
      }
      if (verdict == FxProgressState.stuck) {
        throw FxPlayerException('连续 ${window.stalledFor.inSeconds} 秒无进展');
      }
      if (watch.elapsedMilliseconds >= slowCapMs) {
        // 慢但一直在动：到 30 秒硬上限**直接切**（用户口径：到点就切，
        // 不弹「继续等待 / 换条线路」——问了也不会点，反而更烦）。
        fxPlayLog(
          fxSlowSwitchLog(
            line: '',
            waitedSeconds: watch.elapsed.inSeconds,
            buffered: v.buffered,
          ),
        );
        throw const FxPlayerException('慢网超时(30s)');
      }
    }
    final err = error;
    if (err != null) {
      Error.throwWithStackTrace(err, stack ?? StackTrace.current);
    }
    return result as T;
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

  // ------------------------------------------- 后台播放保活（BG_SERVICE）

  /// 通知栏标题用的片名与集号（页面在 open 之前交进来）。
  ///
  /// 为什么不放在页面里直接调原生：起服务的时机绑定在「这一集真的播起来了」，
  /// 而那是 FxPlayer 内部（open 成功 / play 成功 / 播放结束）才知道的。
  String _bgTitle = '';
  int _bgEpisode = 0;

  /// 前台服务是不是已经被我们拉起来过（避免每次状态回调都重发一次 start）。
  bool _bgRunning = false;

  /// 通知副标题的后半段（线路名，「第N集 · 线路名」里的后半段）。
  String _bgLine = '';

  /// 封面地址（通知栏 / 锁屏的封面图）。
  String _bgCover = '';

  /// 这一集还有没有上一集 / 下一集（系统据此显示或隐藏通知栏那两个按钮）。
  bool _bgHasPrev = true;
  bool _bgHasNext = true;

  /// 登记当前这一集的名字：原生据此拼「片名 / 第N集 · 线路名」和封面。
  ///
  /// 换集 / 换线路前都要重新调一次（页面在 open 之前调），否则通知会一直
  /// 显示上一集的名字。
  ///
  /// MEDIA_SESSION（2026-11-15）：[line] / [cover] 是这轮新增的 —— 系统媒体
  /// 卡片的副标题和封面就靠它们。**必须在 open 之前登记**：原生把元数据
  /// 挂在 MediaItem 上，prepare 之后再改就得换 source（等于重新起播）。
  void setBackgroundMedia(
    String title,
    int episode, {
    String line = '',
    String cover = '',
    bool hasPrev = true,
    bool hasNext = true,
  }) {
    _bgTitle = title.trim();
    _bgEpisode = episode;
    _bgLine = line.trim();
    _bgCover = cover.trim();
    _bgHasPrev = hasPrev;
    _bgHasNext = hasNext;
  }

  /// 交给原生：首次真的出声时由原生 startForeground（见 ExoPlayerPlugin）。
  Future<void> _startBackground() async {
    if (_bgTitle.isEmpty) return;
    _bgRunning = true;
    await ExoPlayerEngine.backgroundStart(
      title: _bgTitle,
      episode: _bgEpisode,
      line: _bgLine,
      cover: _bgCover,
      hasPrev: _bgHasPrev,
      hasNext: _bgHasNext,
    );
  }

  /// 收掉前台服务（幂等：没起过就什么都不做）。
  Future<void> _stopBackground() async {
    if (!_bgRunning) return;
    _bgRunning = false;
    await ExoPlayerEngine.backgroundStop();
  }

  // ------------------------------------------------- 看门狗 / 救援链状态

  Timer? _watchdogTimer;

  /// 内核状态轮询（事件通道的兜底）。
  Timer? _pollTimer;

  /// 失败时是否自动切到下一条线路。默认关闭：自动换线会把用户选中的
  /// 线路顶掉（用户报「自动跳线路、切回去也放不了」）。
  static const bool _autoSwitchLine = false;

  /// 本次 open 的类型提示（来自服务端的 type 字段）。
  bool? _typeHint;

  /// 本次 open 要不要做任何「前置动作」（见 [open] 的 `preflight` 参数）。
  bool _preflightEnabled = true;
  DateTime _lastFlowAt = DateTime.now();
  int _rescueRounds = 0;
  Duration _lastFlowPos = Duration.zero;
  Duration _lastFlowBuffered = Duration.zero;
  int _lastFlowState = -1;

  /// 上一次看到的已收字节数（慢网下「字节在涨」也算有流动）。
  int _lastFlowBytes = -1;

  /// 救援链正在执行（防止看门狗 / 错误事件重复进入）。
  bool _rescueBusy = false;

  /// 救援代际：新的 open / dispose 会推进它，进行中的救援立即让位。
  int _rescueGen = 0;

  /// 救援重开期间把进度显示钉在原位置，避免 UI / 进度回写读到 0。
  bool _rescueHold = false;

  /// 停摆期间我们主动点亮的「缓冲中」，恢复后要自己熄灭。
  bool _stallIndicated = false;

  /// 坏地址账本（STARTUP_FAST_FAIL 2026-11-14）：同一个播放地址失败 2 次
  /// 就不再在救援链里重试它，解析类失败（列表拿不到 / 不是 m3u8）1 次判死。
  final BadAddressLedger _badAddresses = BadAddressLedger();

  /// 上一次已经记过账的 open 代际（同一次 open 的多个错误只算一次）。
  int _lastCountedOpen = -1;

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

  /// 当前这集清单的本地时间索引（逆向报告 §10 改动 4）。
  ///
  /// 拿它做两件事：seek 时把目标时间换算成分片、对目标分片做一次大小校验，
  /// 校验不过就回源直连重取。索引建不出来时为 null，seek 照常工作。
  HlsPlaylistIndex? _segmentIndex;

  /// 高频播放位置通道（每 50~200ms 更新一次）。
  final ValueNotifier<Duration> _positionNotifier =
      ValueNotifier<Duration>(Duration.zero);

  /// 高频位置（供进度条订阅）。
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
    // ASPECT_REAL（2026-11-15）：画面比例**不再**交给原生。
    //
    // 原生那个 PlatformView 是一块 MATCH_PARENT 的 TextureView
    // （`ExoPlayerPlugin.kt` 的 `ExoView`），它不认 resizeMode —— 传过去的
    // creationParams 只被原样收下、没有任何一处读取。以前指望它按
    // FIT/ZOOM/FILL 缩放，结果「填充 / 拉伸」两个档位一直是空的，而且
    // 「画面被拉成 16:9」正是它铺满容器造成的。
    //
    // 现在比例由 Flutter 侧的 [FxVideoStage] 算好框的尺寸，纹理铺满那个
    // 比例正确的框就不会变形；[fit] 只留作语义标记（谁要用再把几何传下去）。
    return ColoredBox(
      color: Colors.black,
      // key 固定：切集 / 换线路 / 切画面比例档位都**不重建** PlatformView。
      // 重建只会多一次纹理重新挂载，用户看到的就是切换瞬间的黑一下。
      child: ExoPlayerView(
        key: const ValueKey<String>('exo-surface'),
        resizeMode: switch (fit) {
          BoxFit.cover => exoResizeZoom,
          BoxFit.fill => exoResizeFill,
          _ => exoResizeFit,
        },
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
    bool direct = false,
    /// 服务端给的类型（PlayInfo.isHls）。给了就以它为准，不再靠地址后缀猜。
    ///
    /// 幻想自建（pt_zijian）返回的是 `.../cloud/flv/xxx` 这种没有 .m3u8 的
    /// 地址，但 302 之后就是 m3u8 列表。按后缀猜会当成普通视频交给
    /// ProgressiveMediaSource，直接解析失败 —— 表现就是「自建线路播不出来」。
    /// libmpv 时代能播是因为 ffmpeg 会自己嗅探格式，ExoPlayer 不会。
    bool? isHls,
    /// 起始播放位置（续播 / 跟房主进度）。
    ///
    /// 原生侧在 `prepare()` 之前就 `seekTo(起始位置)`：ExoPlayer 会直接
    /// 从目标分片开始选片，**不会**先请求第 0 片。这正是「带上次进度打开
    /// 比从头播慢」的根因 —— 第 0 片先到，服务端 `/api/seg` 的首片中转
    /// 名额就被它用掉了，真正需要的目标片只能直连。
    Duration startPosition = Duration.zero,
    PlayUrlRefresher? refreshPlay,
    PlayExpiredCallback? onPlayExpired,
    FxLineRescue? rescueLines,
    /// 起播前还要不要做任何「前置动作」：并行线路预检（PROBE 2026-11-15）
    /// 与首帧后的拖动索引预取 —— 两者都会拿**播放器正在用的那条地址**
    /// 再发一次请求。
    ///
    /// GULU_FIRST_PLAY（2026-11-22）：短寿命线路必须传 false。预检会拿
    /// **播放器马上要用的那条地址**去拉清单 + 首片，等于在起播前先把这条
    /// 现签的地址消费一次；咕噜这类上游按单次 / 短窗口放行，抢在前面那次
    /// 会让真正起播的请求一直 0 KB/s。用户口径是「不做任何前置验证，
    /// 点进去直接播」—— 这类线路预检和索引预取一起关掉。
    bool preflight = true,
  }) {
    if (_disposed) {
      return Future<void>.error(const FxPlayerException('播放器已释放'));
    }
    // OPEN_RESET（2026-11-14）：每次打开都先把上一次的救援状态清干净。
    //
    // 用户报「默认线路加载不出来，手动切其它线路就开始卡」。根因是
    // 上一次 open 失败时 _rescueHold / _rescueBusy 停在 true：
    //   · play() 里 `if (_rescueHold) return` 直接吞掉起播
    //   · 救援链看到 _rescueBusy 也直接返回
    // 于是之后无论手动还是自动切线路，都只是「一直加载」。
    _rescueHold = false;
    _rescueBusy = false;
    _rescueRounds = 0;
    _lastHandledError = '';
    _lastProbe = null;
    // 记下服务端声明的类型，供 _openMedia / 救援重开使用。
    _typeHint = isHls;
    _preflightEnabled = preflight;
    final startMs = startPosition.inMilliseconds < 0
        ? 0
        : startPosition.inMilliseconds;
    final key = _openKey(url, headers, direct, startMs);
    final pending = _opening;
    if (pending != null && pending.key == key) return pending.future;
    final future = _openInternal(
      url,
      headers,
      play,
      direct,
      startMs,
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

  /// 同一地址 + 同一组请求头 + 同一起始位置才算同一次 open；
  /// 起始位置不同（续播位置变了）必须重新打开，不能复用上一次的 future。
  static String _openKey(
    String url,
    Map<String, String> headers,
    bool direct,
    int startPositionMs,
  ) {
    final suffix = direct ? '|direct=1' : '';
    final start = startPositionMs > 0 ? '|from=$startPositionMs' : '';
    if (headers.isEmpty) return '$url$suffix$start';
    final entries =
        headers.entries.map((entry) => '${entry.key}=${entry.value}').toList()
          ..sort();
    return '$url$suffix$start|${entries.join('&')}';
  }

  Future<void> _openInternal(
    String url,
    Map<String, String> headers,
    bool play,
    bool direct,
    int startPositionMs,
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
    // 原生重试 token 以「本次 open 时的值」为基线：只有之后新增的重试
    // 才会触发 Dart 侧重新 resolve（避免新实例上来就白跑一次 refreshPlay）。
    _lastRetryResolveToken = _engine.state.value.retryResolveToken;
    _value = const FxPlayerValue();
    // 换集 / 换源：上一集的清单索引作废（不同集的时长和分片完全不同）。
    _segmentIndex = null;
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
    _PlaybackSource? opened;
    try {
      // DIAG（2026-11-15）：解析段单独计时。
      //
      // 这一段（hxparse 302 跳转 → 最终播放地址）发生在原生 open 之前，
      // ExoPlayer 侧完全看不到；不测出来，「起播 1.8 秒」里到底多少是解析、
      // 多少是清单 + 首帧就永远说不清 —— 而这正是「比影视壳慢」最可能的
      // 一处：壳（FongMi）解析一次就缓存住，我们每集都可能重新走一遍。
      // 计时范围只包住 _resolvePlaybackSource，别把首帧等待算进去。
      final resolveWatch = Stopwatch()..start();
      final source = await _resolvePlaybackSource(
        url,
        headers,
        direct: direct,
        token: token,
      );
      resolveWatch.stop();
      if (source == null) {
        if (identical(_ready, ready)) _ready = null;
        return;
      }
      // PROBE_PARALLEL（2026-11-15）：预检改为**并行**，不再阻塞起播。
      //
      // 用户口径：秒开是硬指标，预检只做「健康度评分 + 排序参考」。
      // 原来是 `await _probeSource(...)` 之后再 open —— 移动网下等于在起播前
      // 多等一次清单往返（最长 8 秒），而且预检拉的首片和播放器要的首片是
      // 同一个地址，两路请求互相抢带宽，与「秒开」直接冲突。
      //
      // 现在：
      //   · 预检和 open 同时发起，**不等它**；
      //   · open 真失败（fatalError：404/DNS/TLS/清单非法/0 分片）→ 照常立刻
      //     判失败并换线，不等 8 秒无进展窗口；
      //   · open 还在正常加载时预检回「线路坏」→ 不打断，只把结果回调给页面
      //     写进健康度档案（下次排序降权）。
      unawaited(_probeInBackground(source, token, startPositionMs));
      opened = source;
      await _openMedia(
        source,
        play: play,
        token: token,
        startPositionMs: startPositionMs,
        // 毫秒数交给原生，并进同一条时间线（原生时间线的起点就是 open）。
        // 加上 FxPlayCache 记下的 /api/play（hxparse）耗时：那一步在 open
        // 之前，属于同一次「用户点播放」的等待。
        resolveMs:
            resolveWatch.elapsedMilliseconds + FxPlayCache.recentResolveMs(),
      ).timeout(_openCallTimeout);
    } catch (error) {
      if (_disposed || token != _openToken) {
        if (identical(_ready, ready)) _ready = null;
        return;
      }
      if (identical(_ready, ready)) _ready = null;
      _noteStartupFailure(
        error is TimeoutException ? 'hard_cap' : _startupCodeFor('$error'),
      );
      _fail('$error');
      throw FxPlayerException('$error');
    }
    if (_disposed || token != _openToken) return;
    try {
      await _awaitReadyOrProgress(ready.future, token);
    } finally {
      if (identical(_ready, ready)) _ready = null;
    }
    // 清单索引（§10 改动 4）：首帧之后才建。
    //
    // ALIGN_FONGMI（2026-11-15）：原来是在 open 之前就 `unawaited` 拉一遍
    // m3u8 —— 起播那一瞬间等于同时有「播放器 + 预热 + 预取 + 这份索引」
    // 四条路径去要同一个清单，白白多一次回源。索引只是给拖动用的，
    // 首帧更重要，所以挪到首帧之后（后台建，失败也不影响播放）。
    // opened 到这里一定已赋值：source == null 的分支上面已经提前 return，
    // 失败路径是 throw。原来的 `opened != null` 因此永远不会为假，
    // 新版分析器会报 unnecessary_null_comparison（CI 的 flutter analyze 会挂）。
    if (!_disposed && token == _openToken) {
      // TOKEN_ONCE（2026-11-15）：本站 `/hxparse/xo?u=` 这类包装地址背后是
      // 一次性令牌，再抓一次清单就把播放器那条烧成 403（表现为清单到手、
      // 分片 0 KB/s）。索引只服务拖动，令牌丢了整集都播不了，所以直接跳过。
      // GULU_FIRST_PLAY：短寿命线路（preflight=false）同理 —— 索引要拿的
      // 就是播放器正在用的那条地址，再要一次可能把整集的分片一起拖死。
      if (HlsSegmentIndex.isOneTimePlaylist(opened.url)) {
        _logFx('INDEX 跳过：一次性令牌清单 ${opened.url}');
      } else if (!_preflightEnabled) {
        _logFx('INDEX 跳过：短寿命线路不再多要一次清单 ${opened.url}');
      } else {
        unawaited(_primeSegmentIndex(opened.url, opened.headers, token));
      }
    }
  }

  /// 这次起播「连续无进展」的内核窗口（SH4K_RETRY 2026-11-20）。
  ///
  /// 首帧前：令牌解析线路（`/hxparse/xo?u=SH4K-…` / 幻想4K）等 20 秒，
  /// 直链仍按 8 秒。用户口径是「自动换线要能自动起来」——SH4K 要多走本站
  /// 解析 302 + 上游清单 + AES key 三跳，冷启动实测 5~7 秒，8 秒窗口会把
  /// 正常的首帧判成死线路（这正是「SH4K 有时加载不出来」的一半原因）。
  /// 首帧之后仍按 [playbackStallTimeout]（6 秒）判卡顿：那时管线已经通了。
  Duration _startupWindow(bool hasRenderedFirstFrame) {
    final base = stallTimeoutFor(hasRenderedFirstFrame: hasRenderedFirstFrame);
    if (hasRenderedFirstFrame) return base;
    final token = fxStartupNoProgressWindowFor(url: _sourceUrl);
    return token > base ? token : base;
  }

  /// 等首帧，但把「还在下载（慢）」和「卡死（真失败）」区分开。
  ///
  /// SLOW_NET（2026-11-15）用户定稿：
  ///
  /// > 一定要是真失败才会跳过，而不是没有加载出来就跳过。比如用户网速是真的慢。
  ///
  /// 所以这里**删掉了「总共等 N 秒没首帧就算失败」那一条**（原来起播 15 秒、
  /// 首帧后 12 秒，更早是 6 / 8 秒）—— 慢网拉 4K 清单 + 首片 20 秒才出首帧
  /// 很常见，按总时长判定只会把本来能播的线路判死。
  ///
  /// 现在的判据（[FxProgressWindow]）：
  ///   · 每 [fxProgressSampleInterval] 采一次 `bytesLoaded / buffered / position`；
  ///   · 任意一项在涨 = 慢，**无限延长等待**（上限 [fxSlowStartupCap] 只用来
  ///     提示用户，不判失败）；
  ///   · 连续 [fxStartupNoProgressWindow]（8 秒）三项全都不动 = 真卡死，放弃；
  ///   · 原生报「真失败」（`fatalError`：401/403/404/410/500/502/503、DNS、
  ///     连接被拒、TLS、清单非法、0 分片）→ **立刻**放弃，不等窗口。
  Future<void> _awaitReadyOrProgress(Future<void> ready, int token) async {
    final watch = Stopwatch()..start();
    final progress = FxProgressWindow(window: _startupWindow(false));
    var slowCapMs = _openSlowCap.inMilliseconds;
    var lastLogMs = -1000;
    while (true) {
      if (_disposed || token != _openToken) return;
      try {
        await ready.timeout(fxProgressSampleInterval);
        return; // 首帧 / 媒体就绪
      } on TimeoutException {
        // 还没好：看有没有真的在下。
      }
      if (_disposed || token != _openToken) return;

      final st = _engine.state.value;
      final firstFrame =
          st.hasRenderedFirstFrame || _value.hasRenderedFirstFrame;
      // 首帧前后用同一个「无进展」口径，只是窗口长度不同。
      progress.window = _startupWindow(firstFrame);
      progress.add(
        FxProgressSample(
          atMs: watch.elapsedMilliseconds,
          bytesLoaded: st.bytesLoaded,
          buffered: st.buffered,
          position: st.position,
          isLoading: st.isLoading,
        ),
      );
      final verdict = progress.state;
      // 日志 2 秒一条：`[FxPlay] progress bytes=+38KB buffered=+1.2s verdict=slow`。
      if (watch.elapsedMilliseconds - lastLogMs >= 2000) {
        lastLogMs = watch.elapsedMilliseconds;
        fxPlayLog(
          fxProgressLog(
            bytesDelta: progress.bytesDelta,
            bufferedDeltaMs: progress.bufferedDeltaMs,
            state: verdict,
            extra: 'firstFrame=$firstFrame '
                'stalled=${progress.stalledFor.inMilliseconds}ms',
          ),
        );
      }
      // 真失败：地址已经 404 / DNS 不通 / 清单非法，等下去没有任何意义。
      final fatal = st.fatalError;
      if (fatal.isNotEmpty && fatal != _lastFatalCode) {
        _lastFatalCode = fatal;
        _logFx('OPEN 放弃：真失败 $fatal ${_shortUrl(_sourceUrl)}');
        _noteStartupFailure(fatal, resolveFailure: fxIsResolveFailureCode(fatal));
        _fail('线路不可用($fatal)');
        throw FxPlayerException('线路不可用($fatal)');
      }
      if (verdict == FxProgressState.stuck) {
        // 连续一个窗口字节、缓冲、位置全都一动不动 —— 这是真卡死。
        _logFx(
          'OPEN 放弃：连续 ${progress.stalledFor.inSeconds}s 无进展'
          '（bytes=${st.bytesLoaded} buffered=${st.buffered.inMilliseconds}ms）',
        );
        _noteStartupFailure('stuck_no_progress');
        _fail('播放超时，线路可能不可用');
        throw const FxPlayerException('播放超时');
      }
      // 慢但一直在走：到 30 秒硬上限**直接切下一条**。
      // 用户口径：30 秒是硬上限，不是弹性值 —— 再多就等不了了；
      // 而且不弹「继续等待 / 换条线路」，到点直接换。
      if (watch.elapsedMilliseconds >= slowCapMs) {
        _logFx(
          'OPEN 放弃：慢网 ${_openSlowCap.inSeconds}s 硬上限 → 换下一条'
          '（buffered=${st.buffered.inMilliseconds}ms bytes=${st.bytesLoaded}）',
        );
        fxPlayLog(
          fxSlowSwitchLog(
            line: '',
            waitedSeconds: watch.elapsed.inSeconds,
            buffered: st.buffered,
          ),
        );
        _noteStartupFailure('slow_network');
        _fail('网速太慢，已自动换下一条线路');
        throw const FxPlayerException('慢网超时(30s)');
      }
    }
  }

  /// 后台预检：跑完只把结果交出去，**不改变播放状态**。
  ///
  /// PROBE_PARALLEL（2026-11-15）：从 `_openInternal` 里 fire-and-forget 调用。
  /// 结果要么写进健康度档案（页面回调），要么写进日志 —— 绝不 `_fail`，
  /// 也不 dispose 播放器：这时画面可能已经在正常播了，预检说坏只是参考。
  Future<void> _probeInBackground(
    _PlaybackSource source,
    int token,
    int startPositionMs,
  ) async {
    final result = await _probeSource(source, token, startPositionMs);
    if (result == null || result.skipped) return;
    if (_disposed || token != _openToken) return;
    final sink = onProbeResult;
    if (sink == null) return;
    try {
      sink(result);
    } catch (error) {
      // 回调只更新排序参考，出错也不能影响播放。
      _logFx('PROBE 结果回调异常（忽略）: $error');
    }
  }

  /// 起播前的线路健康预检（PROBE 2026-11-15，用户口径）。
  ///
  /// 三级：能连上 → 清单是 #EXTM3U 且有分片 → 第一个分片能下到字节。
  /// 每项最多 3 秒、总共 8 秒（见 [probeLine]）—— 预检自己不许卡住。
  ///
  /// 什么情况**不探**（探了只会多一次请求，甚至把整集搞废）：
  ///   · 本地代理 / 本地文件（`127.0.0.1`、`file:`、`content:`）；
  ///   · 一次性令牌清单（探一次就把令牌烧掉，播放器那条反而 403）；
  ///   · 10 分钟内已经探通过的地址（救援链「同地址重开」不必再探）；
  ///   · 从中间续播（[startPositionMs] > 0）：线路早就在放了，不用再验；
  ///   · 非 HLS（mp4 直链没有清单，探了必然「不是 #EXTM3U」）。
  ///
  /// 返回 null = 这次 open 已被新的请求取代。
  Future<FxLineProbeResult?> _probeSource(
    _PlaybackSource source,
    int token,
    int startPositionMs,
  ) async {
    _lastProbe = null;
    if (!FxLineProbeCache.enabled) return const FxLineProbeResult.skipped();
    // GULU_FIRST_PLAY：短寿命线路不预检（会把现签地址提前消费一次）。
    if (!_preflightEnabled) {
      _logFx('PROBE 跳过：短寿命线路不预检（起播直接用现签地址）');
      return const FxLineProbeResult.skipped();
    }
    final url = source.url.trim();
    if (url.isEmpty) return const FxLineProbeResult.skipped();
    final lower = url.toLowerCase();
    if (lower.startsWith('file:') ||
        lower.startsWith('content:') ||
        lower.startsWith('/')) {
      return const FxLineProbeResult.skipped();
    }
    final host = Uri.tryParse(url)?.host ?? '';
    if (host == '127.0.0.1' || host == 'localhost') {
      return const FxLineProbeResult.skipped();
    }
    final looksHls = _typeHint ?? _looksLikeHls(url);
    if (!looksHls) {
      // 预检只对「清单型」地址有意义：mp4 直链没有 #EXTM3U。
      return const FxLineProbeResult.skipped();
    }
    if (HlsSegmentIndex.isOneTimePlaylist(url)) {
      _logFx('PROBE 跳过：一次性令牌清单（再抓一次会把令牌烧掉）');
      return const FxLineProbeResult.skipped();
    }
    if (FxLineProbeCache.isHealthy(url)) {
      _logFx('PROBE 跳过：10 分钟内已探通');
      return const FxLineProbeResult.skipped();
    }
    if (startPositionMs > 0) {
      _logFx('PROBE 跳过：续播位置 $startPositionMs ms 的线路已在用');
      return const FxLineProbeResult.skipped();
    }
    final probe = await probeLine(url, headers: source.headers);
    if (_disposed || token != _openToken) return null;
    _lastProbe = probe;
    _logFx(
      'PROBE ${probe.ok ? '通过' : '失败'} stage=${probe.stage} '
      'reason=${probe.reason.isEmpty ? '-' : probe.reason} '
      'segs=${probe.segments} ${probe.elapsed.inMilliseconds}ms '
      '${_shortUrl(url)}',
    );
    if (probe.ok) FxLineProbeCache.markHealthy(url);
    return probe;
  }

  /// 解析出真正交给内核的地址：直链先过本地分片代理（默认关闭），
  /// 非代理路径做 m3u8 预热。返回 null = 这次 open 已被取代。
  Future<_PlaybackSource?> _resolvePlaybackSource(
    String url,
    Map<String, String> headers, {
    required bool direct,
    required int token,
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
      // ALIGN_FONGMI（2026-11-15）：预热**永远不阻塞 open**，也永远不拉分片。
      //
      // 壳（FongMi/TV）没有这一步：拿到直链就 setMediaSource + prepare，
      // 起播链路里只有播放器自己那一次请求。我们以前在首次打开时
      // `await` 预热（预算 1.6s），等于在「开播」前面白插一段串行等待，
      // 正好和「秒开」相反 —— 现在只做 DNS 预热（几毫秒、不产生 HTTP 请求），
      // 且 fire-and-forget，open 一步都不等它。
      unawaited(_FxHlsWarmup.prepare(url));
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
    int startPositionMs = 0,
    /// Dart 侧解析地址花掉的毫秒数；透传给原生并进它的起播时间线。
    int resolveMs = 0,
  }) async {
    if (_disposed || token != _openToken) {
      throw StateError('open 已被新的播放请求取代');
    }
    // 优先用服务端声明的类型；没有才退回按地址猜。
    final isHls = _typeHint ?? _looksLikeHls(source.url);
    // RESUME_LOG（2026-11-14）：续播最容易被中间某一环静默丢掉参数，
    // 真机 logcat 里搜 `RESUME` 就能看到这一条，配合原生的
    // 「RESUME 起始位置 Xms / 首个分片索引 N」一起确认。
    _logFx(
      'RESUME 起始位置 ${startPositionMs}ms → open（hls=$isHls, '
      'direct=$_sourceDirect）',
    );
    final ok = await _engine.open(
      source.url,
      headers: source.headers,
      isHls: isHls,
      // RESUME_FIRST_SEG：起始位置交给原生，在 prepare 之前落位，
      // 首个分片请求就是目标片。
      startPositionMs: startPositionMs,
      // 解析段并进原生时间线，界面上的「起播总」才是用户真正等的时间。
      resolveMs: resolveMs,
      // MEDIA_SESSION：通知 / 锁屏的片名、集号、线路名、封面跟着 open 走。
      // 元数据必须在 prepare 之前挂在 MediaItem 上，所以不能等
      // `_startBackground`（那是 open 之后才发的）。
      bgTitle: _bgTitle,
      bgEpisode: _bgEpisode,
      bgLine: _bgLine,
      bgCover: _bgCover,
      bgHasPrev: _bgHasPrev,
      bgHasNext: _bgHasNext,
      // PARAMS_ALIGN（2026-11-15 · 阶段 2 第 2 条）：内核在 build 时就把
      // playWhenReady 置 true（对齐壳 Players.java:151），不再等我们补发
      // play() —— 省掉一次通道往返，起播快一拍。
      //
      // 但「明确要暂停」的场景必须让原生知道：`play: false` 传下去之后，
      // 原生换源 / 重试重开都不会把播放器拉起来。`play: true` 时不发键
      // （缺省就是 true），载荷与改造前逐字节一致。
      autoplay: play,
    );
    if (_disposed || token != _openToken) {
      throw StateError('open 已被新的播放请求取代');
    }
    if (!ok) {
      throw FxPlayerException(_engine.error ?? '播放器打开失败');
    }
    // 原生 open 已经把首帧标记清空（快照里是 false）。这里同步一次本地值：
    // 250ms 轮询有可能在 open 之前带回过上一部片的 true，不覆盖的话
    // 加载层会在 open 返回到下一次轮询之间提前收起（又变成黑屏）。
    _value = _value.copyWith(hasRenderedFirstFrame: false);
    // 内核在 open 时会把 lastError 清空，Dart 侧的去重标记也要跟着清，
    // 否则救援重开之后同类错误会被当成「已处理过」而漏掉。
    _lastHandledError = '';
    // BG_SERVICE：先把片名 / 集号交给原生，再 play。
    // 原生在 open 成功那一刻 startForeground（首次真的出声时还会再补一次），
    // 顺序不能反，否则通知标题会拿到空片名、服务干脆不起来。
    unawaited(_startBackground());
    if (play) {
      // PARAMS_ALIGN 第 2 条：原生已经在 prepare 时 playWhenReady=true，
      // 这次 play() 是**幂等**的兜底（老原生包没有 autoplay 键时靠它起播）。
      // 不能删：Dart 与原生版本可能不同步（用户装了旧 APK）。
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
    // BG_SERVICE：暂停后再点播放，前台服务要跟着回来（暂停期间我们保留服务，
    // 但用户从通知栏 / 系统恢复播放时这里兜一层）。
    unawaited(_startBackground());
    return _engine.play();
  }

  Future<void> pause() {
    _playIntent = false;
    // 注意：暂停**不**收服务 —— 通知栏要留着「播放」按钮让用户从后台继续，
    // 这也是各视频 App 的常规行为（收掉的话用户就没法在通知栏点回来了）。
    return _engine.pause();
  }

  /// 停止播放（直播页 / 一起看退出时用）。
  Future<void> stop() async {
    _playIntent = false;
    // BG_SERVICE：真的「停止播放」才收前台服务。
    await _stopBackground();
    await _engine.pause();
    await _engine.seek(Duration.zero);
  }

  /// 显式播放意图与缓冲状态分开，防止报错亮缓冲后把主动暂停误当播放。
  Future<void> playOrPause() => isPlaying ? pause() : play();

  /// 内核真实播放状态，按钮图标以此为准。
  bool get isPlaying => _engine.state.value.playing;

  /// 本实例是否已经释放。
  ///
  /// SWITCH_INSTANCE_REUSE（改动 ④）：播放页换集时用它判断「还能不能复用
  /// 这个实例」—— 复用就不新建、也不 release 原生播放器。
  bool get isDisposed => _disposed;

  /// 内核当前真实倍速；跨页面交接时以此为准，避免本地状态落后。
  ///
  /// ExoPlayer 的状态回包里没有倍速字段（我们不常用），所以自己记最近一次
  /// setRate 的值 —— 竖屏 → 全屏交接时读它，倍速不会被重置回 1.0。
  double get rate => _lastRate;

  double _lastRate = 1.0;

  /// 拖动进度：ExoPlayer 自己会重新调度分片，不需要我们干预缓冲参数。
  ///
  /// 拖动静音闸（§10 改动 3，1200ms + 首帧解锁）在原生 `ExoPlayerPlugin`
  /// 的 `seek` 分支里做：它拿得到 `player.volume` 与 `onRenderedFirstFrame`，
  /// Dart 侧再闸一次只会和它互相打架。这里只补「按目标位置校验分片」。
  Future<void> seek(Duration position) async {
    await _engine.seek(position);
    _positionNotifier.value = position;
    // 拖动后画面要重新渲染一帧才不是黑的：首帧标记先落回 false，
    // 加载层重新压住，等原生 onRenderedFirstFrame 再放开。
    _setValue(
      _value.copyWith(position: position, hasRenderedFirstFrame: false),
    );
    // 拖动后按目标位置把本地清单索引对到一个分片，先校验再预热。
    _warmSegmentAt(position);
  }

  /// 后台建当前清单的本地时间索引（§10 改动 4）。
  ///
  /// 不阻塞 open：索引只是「seek 时知道该预取哪一片」的加速器，
  /// 拉不到 / 超时就当作没有。
  Future<void> _primeSegmentIndex(
    String url,
    Map<String, String> headers,
    int token,
  ) async {
    if (_disposed) return;
    final index = await HlsSegmentIndex.instance.indexOf(url, headers);
    if (_disposed || token != _openToken || index == null) return;
    _segmentIndex = index;
    _logFx(
      'INDEX 就绪：${index.segments.length} 片 / '
      '总时长 ${(index.totalDurationMs / 1000).round()}s',
    );
  }

  /// 拖动后按目标位置校验命中的分片（§10 改动 4）。
  ///
  /// 分片大小和清单声明对不上时，[HlsSegmentIndex.verify] 会立刻回源直连
  /// 重取这一片。校验是后台的，不挡 seek。
  void _warmSegmentAt(Duration position) {
    final index = _segmentIndex;
    if (index == null) return;
    final segment = index.segmentAt(position);
    if (segment == null) return;
    final headers = _sourceHeaders;
    unawaited(() async {
      final probe = await HlsSegmentIndex.instance.verify(
        segment,
        headers: headers,
      );
      _logFx(
        'SEEK 分片校验 @${position.inSeconds}s → 分片 '
        '${segment.startMs}ms：${probe.result.name}（${probe.note}）',
      );
    }());
  }

  /// 兼容 video_player 命名。
  Future<void> seekTo(Duration position) => seek(position);

  /// 直播追边（LIVE_EDGE 2026-11-20）：把播放位置挪到直播窗口末端前 [rewind]。
  ///
  /// 只给**用户主动重开**用（直播页的刷新 / 换线路 / 换台）。直播页不会定时
  /// 调用它：播着播着落后了就让它落后，软件不自动跳。
  ///
  /// 窗口时长就是内核报的 `duration`（HLS live 的窗口末端）；窗口未知
  /// （duration == 0，很多直播清单就是这样）时退回 [fxLiveSeekToEnd] ——
  /// ExoPlayer 的 `seekTo` 会把目标钳进可播放窗口，等于落到末端。
  Future<bool> seekToLiveEdge({
    Duration rewind = fxLiveRefreshRewind,
    String reason = 'manual',
  }) async {
    if (_disposed) return false;
    final v = _value;
    if (!v.isInitialized || v.hasError) return false;
    final target = fxLiveEdgeTarget(v.duration, rewind: rewind);
    final seekTo =
        target ?? (v.duration <= Duration.zero ? fxLiveSeekToEnd : null);
    // 窗口比回退还短：没有「末端前 N 秒」这回事，宁可不 seek。
    if (seekTo == null) return false;
    _logFx(
      fxLiveProbeLog(
        event: 'refresh',
        position: v.position,
        duration: v.duration,
        target: seekTo,
        reason: reason,
      ),
    );
    try {
      await seek(seekTo);
      return true;
    } catch (error) {
      _logFx('[FxLive] 追边失败 reason=$reason error=$error');
      return false;
    }
  }

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

  /// 上一次下发的镜像档位（0=无,1=X,2=Y,3=XY），避免每帧重复过通道。
  int _mirrorFlags = -1;

  /// 镜像（原生翻转，PlatformView 不支持 Flutter Transform）。
  void setMirror({required bool flipX, required bool flipY}) {
    final flags = (flipX ? 1 : 0) | (flipY ? 2 : 0);
    if (flags == _mirrorFlags) return;
    _mirrorFlags = flags;
    unawaited(_engine.setMirror(flipX: flipX, flipY: flipY));
  }

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
    // BG_SERVICE：退出播放页 / 释放实例 = 前台服务必须收掉，不留空保活。
    await _stopBackground();
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
  /// 时才通知，避免顶栏、底栏跟着每帧重建。
  void _onEngineState() {
    if (_disposed) return;
    final st = _engine.state.value;

    // MEDIA_SESSION：系统媒体控件按了「上一集 / 下一集」。
    // 原生只把请求号 +1 推上来（它不知道集数 / 线路 / 地址），这里转给页面。
    if (st.bgStepSeq != _lastBgStepSeq) {
      _lastBgStepSeq = st.bgStepSeq;
      if (st.bgStepSeq > 0) {
        final delta = st.bgStepDelta < 0 ? -1 : 1;
        _logFx('媒体按键：${delta < 0 ? "上一集" : "下一集"}（seq=${st.bgStepSeq}）');
        final sink = onEpisodeStep;
        if (sink != null) {
          try {
            unawaited(Future<void>.sync(() => sink(delta)));
          } catch (error) {
            _logFx('媒体按键处理失败：$error');
          }
        }
      }
    }

    // BG_SERVICE：播到结尾就收掉前台服务（没东西可放了，留着就是空保活）。
    // 自动连播下一集会重新 open → play，服务自己会再起来。
    if (st.ended && _bgRunning) unawaited(_stopBackground());

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
      // FIRST_FRAME：只有原生确认「已经渲染出一帧」才置 true。
      // 加载层的显隐完全按它走，不再用 isBuffering / isPlaying 猜。
      hasRenderedFirstFrame: st.hasRenderedFirstFrame,
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
      // 诊断字段原样透传：这里不做任何加工，界面看到的就是原生算出来的。
      timing: st.timing,
      connectCount: st.connectCount,
      droppedFrames: st.droppedFrames,
      bufferedAhead: st.bufferedAhead,
      bitrateKbps: st.bitrateKbps,
      measuredKbps: st.measuredKbps,
      // IQ_CODEC：编码信息原样透传（原生从 videoFormat / 响应头拿的）。
      videoCodec: st.videoCodec,
      iqCodec: st.iqCodec,
      iqQuality: st.iqQuality,
      codecHint: iqRequestedCodec(_sourceUrl),
      // SLOW_NET（2026-11-15）：「慢」和「死」的区别全在这三个字段上。
      bytesLoaded: st.bytesLoaded,
      bytesLoadedPerSec: st.bytesLoadedPerSec,
      isLoading: st.isLoading,
      fatalError: st.fatalError,
    );

    final secondChanged = shown.inSeconds != _value.position.inSeconds;
    final stateChanged =
        next.isPlaying != _value.isPlaying ||
        next.isBuffering != _value.isBuffering ||
        // 首帧状态翻转必须立刻通知：加载层就是靠它收起的。
        next.hasRenderedFirstFrame != _value.hasRenderedFirstFrame ||
        next.isCompleted != _value.isCompleted ||
        next.duration != _value.duration ||
        next.width != _value.width ||
        // DIAG（2026-11-15）：首帧耗时是逐毫秒变的（原生每轮快照都重算），
        // 不并进通知判据的话诊断浮层要等别的状态变化才刷新，看起来像卡住。
        next.timing.firstFrameMs != _value.timing.firstFrameMs ||
        // BUFFER_UI（2026-11-15）：实时网速要每秒刷新。缓冲中位置不动、
        // 其它字段也不变，不把网速并进判据的话，加载层会一直显示旧值
        // （用户看到「1.8 MB/s」卡住不动，和假进度没区别）。
        next.bytesLoadedPerSec != _value.bytesLoadedPerSec;
    _value = next;
    // SLOW_NET：原生已经判定「真失败」（404 / DNS / TLS / 清单非法 /
    // 0 分片）—— 这类错误不可能是「网慢」，不等任何窗口，立刻处理：
    //   · 起播阶段（ready 还没完成）：记一次账本并直接判失败，页面马上换线；
    //   · 首帧之后：让它走救援链（换签名 / 同地址重开 / 换线路），
    //     不等看门狗那 10 秒无进展窗口。
    final fatal = next.fatalError;
    if (fatal.isNotEmpty && fatal != _lastFatalCode) {
      _lastFatalCode = fatal;
      _logFx('真失败 code=$fatal，不等待窗口直接处理 ${_shortUrl(_sourceUrl)}');
      _noteStartupFailure(fatal, resolveFailure: fxIsResolveFailureCode(fatal));
      if (next.isInitialized) {
        unawaited(_runRescue('真失败 $fatal'));
      } else {
        _setValue(next.copyWith(hasError: true, errorText: '线路不可用($fatal)'));
        final pending = _ready;
        if (pending != null && !pending.isCompleted) {
          pending.completeError(FxPlayerException('线路不可用($fatal)'));
        }
      }
    }
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
    // LAYERED_RETRY（改动 ⑤）：原生第 1 档重试（IO/HTTP）会要求重新 resolve
    // 播放地址 —— 原生拿不到 /api/play，只能由 Dart 换新地址再 open。
    _syncNativeRetryResolve(st);
  }

  /// 原生分层重试：token 变化 = 请 Dart 重新 resolve 播放地址。
  ///
  /// 起播阶段（还在 open 里）不插手：那条链本来就有 refreshPlay + 同地址
  /// 重开的救援逻辑，两处同时重开会互相取代。这里只处理「已经在播」的情况。
  void _syncNativeRetryResolve(ExoPlayerState st) {
    final token = st.retryResolveToken;
    if (token == _lastRetryResolveToken) return;
    _lastRetryResolveToken = token;
    if (token <= 0 || _opening != null || !_value.isInitialized) return;
    unawaited(_reResolveAfterNativeRetry());
  }

  /// 原生 retry=1 reason=io：拿新签名地址按原进度重新 open。
  ///
  /// 原生在发这个请求的同时已经用**原地址**重开了一次兜底，所以这里失败
  /// 也没关系（最多就是回到原地址重开的结果）。
  Future<void> _reResolveAfterNativeRetry() async {
    if (_disposed) return;
    final refresher = _refreshPlay;
    if (refresher == null) return;
    final oldUrl = _sourceUrl;
    if (oldUrl.isEmpty) return;
    final gen = _rescueGen;
    final token = _openToken;
    _logFx('原生重试 retry=1 reason=io：重新 resolve 播放地址');
    String? fresh;
    try {
      fresh = await _safeRefreshPlay(refresher);
    } catch (_) {
      fresh = null;
    }
    if (_disposed || gen != _rescueGen || token != _openToken) return;
    final next = (fresh ?? '').trim();
    if (next.isEmpty || next == oldUrl) {
      _logFx('原生重试：没拿到新地址，沿用原地址（原生已用原地址重开）');
      return;
    }
    final resume = _value.position;
    try {
      await _engine.open(
        next,
        headers: _sourceHeaders,
        isHls: _typeHint ?? _looksLikeHls(next),
        startPositionMs: resume.inMilliseconds,
        // PARAMS_ALIGN 第 2 条：这是原生重试触发的重开，播放意图必须沿用
        // 用户当前的 `_playIntent` —— 暂停态换地址不该变成自动开播。
        autoplay: _playIntent,
      );
      if (_disposed || gen != _rescueGen || token != _openToken) return;
      _sourceUrl = next;
      _lastFlowAt = DateTime.now();
      _logFx('原生重试：地址已刷新，从 ${resume.inSeconds}s 重新 open');
    } catch (_) {
      _logFx('原生重试：用新地址重开失败，交给原生兜底');
    }
  }

  /// 原生分层重试的「重新 resolve 地址」请求号上一次的值（改动 ⑤）。
  ///
  /// 原生在 IO/HTTP 错误时会把它 +1；这里看到变化就去 refreshPlay 拿新地址，
  /// 把「地址过期」这条真的修掉（原生自己只重开了原地址）。
  int _lastRetryResolveToken = 0;

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
      // 起播阶段原生把错误交回来了（快速失败生效）：记一次账本。
      // 清单类（拿不到列表 / 不是 m3u8 / 解析不了）一次即判死。
      _noteStartupFailure(_startupCodeFor(message));
      ready.completeError(FxPlayerException(message));
    }
  }

  /// 起播失败统一出口：打日志 + 记账（不动 UI）。
  ///
  /// 日志格式固定为 `[startup] fail <code> <url 前 80 字符>`，
  /// 真机 `adb logcat | grep '\[startup\] fail'` 就能看到失败原因和时间点。
  ///
  /// 同一次 open 只记一次账：原生错误事件和「等首帧超时」经常同时出现，
  /// 各记一遍会让一个只是运气不好的地址立刻被判死。
  void _noteStartupFailure(
    String code, {
    String? url,
    bool resolveFailure = false,
  }) {
    final target = url ?? _sourceUrl;
    _logStartupFail(code, target);
    if (target.trim().isEmpty) return;
    if (_openToken == _lastCountedOpen) return;
    _lastCountedOpen = _openToken;
    final resolve = resolveFailure || code == 'manifest_invalid';
    final count = _badAddresses.noteFailure(target, resolveFailure: resolve);
    if (_badAddresses.isDead(target)) {
      _logFx('BADURL 账本判死($code) 已失败 $count 次：${_shortUrl(target)}');
    }
  }

  /// 起播失败日志（固定格式，便于 logcat 抓时间线）。
  static void _logStartupFail(String code, String url) {
    final short = url.length <= 80 ? url : url.substring(0, 80);
    debugPrint('[startup] fail $code $short');
  }

  /// 原生错误文案 → 起播失败码。
  static String _startupCodeFor(String message) =>
      _looksManifestFailure(message) ? 'manifest_invalid' : 'native_error';

  /// 清单类失败：列表拿不到 / 不是 m3u8 / 解析不了。
  ///
  /// 原生快照里的 `error` 是 `ERROR_CODE_xxx: message` 的拼接
  /// （`ExoPlayerPlugin.onPlayerError`），HLS 的清单坏掉会落到
  /// PARSING_CONTAINER_MALFORMED / PARSING_MANIFEST_MALFORMED /
  /// IO_INVALID_HTTP_CONTENT_TYPE 这几个码上。
  static bool _looksManifestFailure(String message) {
    final lower = message.toLowerCase();
    return lower.contains('parsing_') ||
        lower.contains('manifest') ||
        lower.contains('parser') ||
        lower.contains('container_malformed') ||
        lower.contains('invalid_http_content_type');
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
    // STARTUP_FAST_FAIL：首帧还没渲染（起播 / seek 后重新出画）时门槛 6 秒，
    // 首帧出来后回到宽松值。见 [stallTimeoutFor]。
    final stallLimit = stallTimeoutFor(
      hasRenderedFirstFrame: v.hasRenderedFirstFrame,
    );
    if (stalled < stallLimit) return;
    _logStartupFail('stall', _sourceUrl);
    unawaited(_runRescue('连续 ${stalled.inSeconds}s 无进展'));
  }

  /// 播放位置 / 缓冲位置 / 收到的字节数 / 内核状态，任一有变化即算「还在流动」。
  ///
  /// SLOW_NET（2026-11-15）：加了**字节数**这一项 —— 慢网下一个分片要下
  /// 十几秒，期间 bufferedPosition 一动不动（分片整段落盘才推进），
  /// 只看缓冲位置会把「正在慢慢下」误判成「卡死」。字节在涨就是活着。
  bool _flowing() {
    final v = _value;
    final st = _engine.state.value;
    final posMoved = v.position != _lastFlowPos;
    final bufferedMoved = v.buffered != _lastFlowBuffered;
    final stateMoved = st.state != _lastFlowState;
    final bytesMoved =
        st.bytesLoaded >= 0 && st.bytesLoaded != _lastFlowBytes;
    if (bytesMoved) _lastFlowBytes = st.bytesLoaded;
    _lastFlowPos = v.position;
    _lastFlowBuffered = v.buffered;
    _lastFlowState = st.state;
    return posMoved || bufferedMoved || stateMoved || bytesMoved;
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
      await _engine.open(
        url,
        headers: headers,
        // 救援重开也要沿用服务端给的类型，否则自建线路永远打不开
        isHls: _typeHint ?? _looksLikeHls(url),
        // 重连也带着原进度打开：不然位置 0 会先把中转名额用掉。
        startPositionMs: target.inMilliseconds,
        // PARAMS_ALIGN 第 2 条：重连沿用**原来的**播放意图。
        // 回前台自检时用户可能是暂停态（wantPlay=false）—— 不传这个键，
        // 内核会按 autoplay=true 自己播起来，等于把用户的暂停吃掉了。
        autoplay: wantPlay,
      );
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
          if (_badAddresses.isDead(fresh)) {
            // 账本判死：这个地址已经证明不行，别再把 6~8 秒花在它身上。
            _logFx(
              'RESCUE ①-refresh#$i 跳过：账本已判死 '
              '(${_badAddresses.countOf(fresh)} 次) ${_shortUrl(fresh)}',
            );
            _logStartupFail('bad_url_skip', fresh);
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
      //
      // 账本判死的地址直接跳过：同一个死地址再打一遍只是多等 6~8 秒，
      // 而且这期间旧实例还在抢带宽（用户看到的就是一直转圈）。
      if (_badAddresses.isDead(_sourceUrl)) {
        _logFx(
          'RESCUE ②-reopen 跳过：账本已判死 '
          '(${_badAddresses.countOf(_sourceUrl)} 次) ${_shortUrl(_sourceUrl)}',
        );
        _logStartupFail('bad_url_skip', _sourceUrl);
      } else {
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
          if (_badAddresses.isDead(_sourceUrl)) {
            _logFx('RESCUE ②-reopen 提前收手：账本已判死 ${_shortUrl(_sourceUrl)}');
            break;
          }
        }
      }

      // ③ 换下一条线路 —— AUTO_SWITCH_OFF（2026-11-14）：默认关闭。
      //
      // 用户明确报「有时候自动跳线路，手动切回去也播放不了」：
      // 自动换线会把用户选中的线路顶掉，换到一条更差的线路上，
      // 再切回去时播放器还在上一轮救援的状态里，于是也放不出来。
      // 线路交给用户自己选。①②（换签名 / 同址重开）仍然保留，
      // 这两步不改线路，救得回来就不会打断观看。
      final switcher = _autoSwitchLine ? _lineRescue : null;
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
      _logStartupFail('rescue_all_failed', _sourceUrl);
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
      // 救援链同样把解析段测出来（虽然不弹界面，但并进时间线后，
      // 事后看「救援那一次为什么慢」也能分出是解析还是首帧）。
      final resolveWatch = Stopwatch()..start();
      final source = await _resolvePlaybackSource(
        url,
        headers,
        direct: direct,
        token: token,
      );
      resolveWatch.stop();
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
          startPositionMs: live || resume <= Duration.zero
              ? 0
              : resume.inMilliseconds,
          resolveMs:
              resolveWatch.elapsedMilliseconds + FxPlayCache.recentResolveMs(),
        ).timeout(_rescueOpenTimeout);
        if (_disposed || token != _openToken) return false;
        await mediaReady.future.timeout(_rescueOpenTimeout);
      } on TimeoutException {
        _logFx('RESCUE 等新流首帧超时(${_rescueOpenTimeout.inSeconds}s)');
        _noteStartupFailure('rescue_timeout', url: url);
        return false;
      } catch (error) {
        _logFx('RESCUE 重开失败: $error');
        _noteStartupFailure(_startupCodeFor('$error'), url: url);
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
          _noteStartupFailure('rescue_seek_failed', url: url);
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
        _noteStartupFailure('rescue_verify_failed', url: url);
        return false;
      }
      if (_playIntent) await _engine.play();
      if (_disposed || token != _openToken || gen != _rescueGen) return false;
      _sourceUrl = url;
      _sourceHeaders = headers;
      _sourceDirect = direct;
      // 这个地址救回来了：销掉账本里的欠账（刚才只是运气不好）。
      _badAddresses.clear(url);
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
      _noteStartupFailure('rescue_error', url: url);
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
///   切集时 open 只差一个本地 playlist 往返；
/// - **短寿命线路（[isShortLived]，咕噜这类 jar 现签地址）整套缓存全部绕开**：
///   不预热、不读缓存、每次现解析。详见 [isShortLived]。
class FxPlayCache {
  static const Duration _ttl = Duration(minutes: 10);
  static const int _maxEntries = 8;

  /// 这条线路的播放地址是不是「短寿命 / 现签」型（GULU_FIRST_PLAY 2026-11-22）。
  ///
  /// 用户实测（v1.0.493）：咕噜线路**首播**永远 0 KB/s 卡在「正在加载」，
  /// 手点右上角「刷新」立刻秒播。两条路只差一件事 ——
  ///
  /// ```
  /// 首播  FxPlayCache.resolve(force:false) → 命中详情页 warm() 预解析的地址
  /// 刷新  FxPlayCache.resolve(force:true)  → 丢缓存 → CmsBridge.play →
  ///       jar 分支 JarSpider.play → playerContent **现签**一条新地址
  /// ```
  ///
  /// jar 源（`csp_Gulu`）的 `playerContent` 是**现场**调上游解析接口签地址，
  /// 每次签出来的都不一样、且寿命以秒计（上游按会话 / 单次使用放行）。
  /// 把它放进 10 分钟 TTL 的缓存里，首播拿到的必然是「上一次」签的那条 ——
  /// 这就是根因。
  ///
  /// **为什么选「首播强制现解析」而不是「把 TTL 缩到秒级」**：
  /// `detail_page._loadDetail` 的 `warm()` 和播放器首播几乎在同一帧发生
  /// （`warm` 同步写 `_inflight`，首播 `resolve` 直接复用同一个 Future），
  /// 也就是说首播拿到的地址 age≈0 —— 无论 TTL 是 10 分钟还是 1 秒，
  /// 首播命中的都是**同一条预解析地址**。TTL 只决定「第二次以后」还能不能
  /// 复用，治不了首播这一次；而用户钉死的口径正是「首播要能直接播」。
  /// 所以对这类线路干脆不缓存：省掉预解析（不阻塞、也不白跑），
  /// 每次要播都现签，等价于用户手点「刷新」。
  static bool isShortLived(String line) => CmsBridge.isJarLine(line);

  static final Map<String, _CachedPlayInfo> _cache =
      <String, _CachedPlayInfo>{};
  static final Map<String, Future<PlayInfo>> _inflight =
      <String, Future<PlayInfo>>{};

  /// 最近一次「真的发了一次 /api/play（hxparse / CMS 现解析）」花了多少毫秒。
  ///
  /// DIAG（2026-11-15）：解析地址这一步发生在 [FxPlayer.open] **之前**，
  /// 播放器（原生）完全看不到它，但它属于用户等待。这里记一手，
  /// [FxPlayer.open] 开计时线时把它并进「解析」那一段 —— 否则诊断浮层上的
  /// 「解析」永远是 0ms，看起来像是不花时间，实际都藏在 open 之前的停顿里。
  static int _lastResolveMs = 0;
  static DateTime? _lastResolveAt;

  /// 取「刚刚解析地址花掉的毫秒数」：5 秒内有效，过期按 0 算
  /// （过期说明这次 open 用的是缓存/预取结果，本来就不花时间）。
  static int recentResolveMs() {
    final at = _lastResolveAt;
    if (at == null) return 0;
    if (DateTime.now().difference(at) > const Duration(seconds: 5)) return 0;
    return _lastResolveMs;
  }

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
  ///
  /// 短寿命线路永远返回 null：它的地址没有「可复用」这回事，
  /// 返回非空会让首播误判成 cacheHit、跳过现解析（见 [isShortLived]）。
  static PlayInfo? peek(String id, int ep, String line) =>
      isShortLived(line) ? null : _fresh(_key(id, ep, line));

  /// 取播放地址：优先缓存 / 正在请求的结果，[force] 时强制重新请求。
  ///
  /// 短寿命线路（[isShortLived]）等价于 `force: true`：每次都现签。
  /// 日志固定一行，排障时 `adb logcat | grep FxPlay` 就能看出首播到底用的是
  /// 缓存地址还是现签地址：
  /// ```
  /// [FxPlay] resolve line=咕噜·金牌极速 ep=1 cache=short-lived url=https://…
  /// [FxPlay] resolve line=量子 ep=1 cache=hit age=12430ms url=https://…
  /// [FxPlay] resolve line=量子 ep=1 cache=miss url=https://…
  /// ```
  static Future<PlayInfo> resolve(
    String id,
    int ep,
    String line, {
    bool force = false,
  }) {
    final key = _key(id, ep, line);
    final shortLived = isShortLived(line);
    var cacheState = 'miss';
    if (force || shortLived) {
      cacheState = force && !shortLived ? 'force' : 'short-lived';
      _cache.remove(key);
    } else {
      final entry = _cache[key];
      final cached = _fresh(key);
      if (cached != null) {
        final age = entry == null
            ? 0
            : DateTime.now().difference(entry.at).inMilliseconds;
        fxPlayLog(
          'resolve line=$line ep=$ep cache=hit age=${age}ms url=${cached.url}',
        );
        return Future<PlayInfo>.value(cached);
      }
    }
    final pending = _inflight[key];
    if (pending != null) {
      fxPlayLog('resolve line=$line ep=$ep cache=inflight');
      return pending;
    }
    // 播放地址统一走 CmsBridge：CMS 影片按 vod_id 现解析，旧接口的影片
    // 照旧走 /api/play —— 两套编号不能互换（见 cms_bridge 的说明）。
    final resolveWatch = Stopwatch()..start();
    // ENRICH（2026-11-15）：客户端补出来的线路（`enrich:` 前缀）服务端不认识，
    // 先去问 LineEnrich 现算地址；不是补的线路返回 null，照旧走 CmsBridge。
    final future = () async {
      final enriched = await LineEnrich.instance.resolvePlay(
        ep: ep,
        lineId: line,
      );
      if (enriched != null) return enriched;
      return CmsBridge.play(id, ep, line);
    }().then((info) {
      resolveWatch.stop();
      _lastResolveMs = resolveWatch.elapsedMilliseconds;
      _lastResolveAt = DateTime.now();
      // 短寿命地址不进缓存：存下来只会在下一次首播里变成「过期的那一条」。
      if (!shortLived) {
        _cache[key] = _CachedPlayInfo(info, DateTime.now());
        _trim();
      }
      fxPlayLog(
        'resolve line=$line ep=$ep cache=$cacheState '
        'cost=${_lastResolveMs}ms url=${info.url}',
      );
      return info;
    });
    _inflight[key] = future;
    return future.whenComplete(() {
      if (identical(_inflight[key], future)) _inflight.remove(key);
    });
  }

  /// 页面进入 / 下一集预热：已有缓存直接复用，不重复请求接口。
  /// 只发请求并预热 m3u8，不创建播放器。
  ///
  /// 短寿命线路直接跳过（GULU_FIRST_PLAY）：预解析出来的地址到用户真点播放
  /// 时已经不是「要播的那一条」了，白跑一次 playerContent 只会多签一条废地址。
  /// 首播由 [resolve] 现签，**不增加任何等待**。
  static void warm(String id, int ep, String line) {
    if (isShortLived(line)) {
      fxPlayLog('warm skip short-lived line=$line ep=$ep（首播现解析）');
      return;
    }
    final key = _key(id, ep, line);
    if (_fresh(key) != null) return;
    _resolveAndWarm(id, ep, line);
  }

  /// 播放 30 秒后调用：后台清空并刷新下一集 /api/play 结果与 m3u8。
  /// 只发请求，不 open；失败静默，不影响当前播放。
  static void prewarm(String id, int ep, String line) {
    if (isShortLived(line)) return;
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
          await _FxHlsWarmup.prepare(url);
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

/// 起播预热（ALIGN_FONGMI 2026-11-15：**只做 DNS，绝不阻塞 open**）。
///
/// 历史：这里以前会在 open 之前 GET master playlist、再 GET 第一个子
/// playlist、再整片拉前 3 个分片并直接丢弃（最多 24MB）。问题有三层：
///   1. `open` 等它（首次打开 waitForWarm = true，预算 1.6s）——
///      起播前面白插一段串行等待；
///   2. 那 3 个分片和播放器要的第 0 片是**同一个地址**，两路请求一起打
///      CDN，首片等于和自己的预热抢带宽；
///   3. 清单被要了三遍（预热 + 分片索引 + 播放器），每次都是一次回源。
///
/// 壳（FongMi/TV）压根没有这一步：解析出直链就 `setMediaSource` + `prepare`。
/// 所以这里只保留「系统 DNS 预热」——几毫秒、不产生 HTTP 请求、不占连接，
/// 而且对 ExoPlayer 的 HttpURLConnection 也有效（同一个系统解析缓存）。
class _FxHlsWarmup {
  static const Duration _ttl = Duration(minutes: 8);
  static final Map<String, DateTime> _warmed = <String, DateTime>{};
  static final Map<String, Future<void>> _inflight = <String, Future<void>>{};

  static Future<void> prepare(String url) {
    if (url.isEmpty) return Future<void>.value();
    final uri = Uri.tryParse(url);
    if (uri == null) return Future<void>.value();
    // 离线缓存播的是本地 index.m3u8，不需要联网预热。
    if (!uri.isScheme('http') && !uri.isScheme('https')) {
      return Future<void>.value();
    }
    final now = DateTime.now();
    final warmedAt = _warmed[url];
    if (warmedAt != null && now.difference(warmedAt) < _ttl) {
      return Future<void>.value();
    }
    final pending = _inflight[url];
    if (pending != null) return pending;
    final future = _dnsPrefetch(uri);
    _inflight[url] = future;
    return future.whenComplete(() {
      if (identical(_inflight[url], future)) _inflight.remove(url);
      _warmed[url] = DateTime.now();
      _trimWarmed();
    });
  }

  /// 让系统解析一次域名：真实请求时省掉 DNS 往返（移动网络下常见 50~300ms）。
  static Future<void> _dnsPrefetch(Uri uri) async {
    if (uri.host.isEmpty) return;
    try {
      await InternetAddress.lookup(
        uri.host,
      ).timeout(const Duration(milliseconds: 800));
    } catch (_) {
      // DNS 失败交给真正请求时的系统解析。
    }
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

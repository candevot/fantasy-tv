import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// 代理日志回调；默认写到 dart:developer（Flutter 控制台 / logcat 可见）。
typedef HlsProxyLogger = void Function(String message);

/// 落盘诊断日志：`<App 私有目录>/logs/proxy.log`，保留最近 [maxLines] 行。
///
/// - 每行自带毫秒级时间戳；
/// - 顺序追加写入，超期 / 超量时全量重写裁掉旧行，磁盘上不会无限增长；
/// - 拿不到私有目录（测试环境没有 path_provider 通道）时静默降级为
///   只写控制台，日志失败绝不影响播放。
class HlsProxyLog {
  HlsProxyLog._();

  /// 落盘保留行数。
  static const int maxLines = 500;

  /// 日志文件名。
  static const String fileName = 'proxy.log';

  static const Duration _flushInterval = Duration(seconds: 2);
  static const Duration _rewriteInterval = Duration(seconds: 30);

  static final List<String> _lines = <String>[];
  static final List<String> _pending = <String>[];
  static String? _path;
  static bool _resolved = false;
  static bool _disabled = false;
  static int _fileLines = 0;
  static DateTime _lastRewrite = DateTime.fromMillisecondsSinceEpoch(0);
  static Timer? _flushTimer;
  static bool _flushing = false;
  static bool _flushAgain = false;

  /// 日志文件绝对路径；尚未解析成功时为 null。
  static String? get path => _path;

  /// 追加一行（自动补时间戳），约 2 秒后落盘。
  static void write(String message) {
    if (_disabled || message.isEmpty) return;
    final line = '${_stamp()} $message';
    _lines.add(line);
    if (_lines.length > maxLines) {
      _lines.removeRange(0, _lines.length - maxLines);
    }
    _pending.add(line);
    if (_pending.length > maxLines * 2) {
      _pending.removeRange(0, _pending.length - maxLines);
    }
    if (_flushTimer != null) return;
    _flushTimer = Timer(_flushInterval, () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  /// 立即把待写内容落盘（幂等，可并发调用）。
  static Future<void> flush() async {
    if (_flushing) {
      _flushAgain = true;
      return;
    }
    if (_pending.isEmpty) return;
    _flushing = true;
    try {
      if (!_resolved) {
        _resolved = true;
        try {
          final dir = await getApplicationDocumentsDirectory();
          _path = '${dir.path}/logs/$fileName';
        } catch (_) {
          _path = null;
        }
      }
      final path = _path;
      if (path == null) {
        _disabled = true;
        _pending.clear();
        return;
      }
      final file = File(path);
      await file.parent.create(recursive: true);
      final rewrite =
          _fileLines == 0 ||
          _fileLines > maxLines + 100 ||
          DateTime.now().difference(_lastRewrite) > _rewriteInterval;
      if (rewrite) {
        await file.writeAsString('${_lines.join('\n')}\n');
        _fileLines = _lines.length;
        _lastRewrite = DateTime.now();
      } else if (_pending.isNotEmpty) {
        await file.writeAsString(
          '${_pending.join('\n')}\n',
          mode: FileMode.append,
        );
        _fileLines += _pending.length;
      }
      _pending.clear();
    } catch (_) {
      // 落盘失败不影响播放，留在内存里下轮再试。
    } finally {
      _flushing = false;
      if (_flushAgain) {
        _flushAgain = false;
        if (_pending.isNotEmpty) unawaited(flush());
      }
    }
  }

  static String _stamp() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
  }
}

/// 平台线路签名过期时，由宿主重新请求 `/api/play?...&fresh=1` 拿新地址。
/// 返回 null / 抛异常表示这次没拿到（代理按失败计数，连续 2 次通知换线）。
typedef PlayUrlRefresher = Future<String?> Function();

/// 平台线路彻底失效（连续刷新失败）时通知宿主提示用户切换线路。
typedef PlayExpiredCallback = void Function();

/// 客户端本地 HLS 分片代理。
///
/// 背景：部分直链（红牛等）对单条 TCP 连接限速，libmpv 顺序拉分片时
/// 每 30 秒左右就会卡一次。本代理在 127.0.0.1 起一个随机端口的 HTTP
/// 服务，把 m3u8 中的分片 / 密钥改写成本地地址，再由代理把每个分片切成
/// N 段并发 Range 下载后拼回完整分片；同时缓存并顺序预取。
///
/// 平台线路（腾讯 / 芒果等）的 m3u8 里常带几分钟过期的签名：
/// - 每 [playlistRefreshInterval] 重新拉一次 playlist，后续分片始终用
///   刷新后的新地址（本地 URL 保持不变，[index] 映射到新地址）；
/// - 分片失败（含 403 / 404）按 200/600/1500ms 指数退避重试 3 次，
///   平台线路每次重试前先 refreshPlay 换新签名，实现自愈；
/// - 播放器（libmpv）主动断开 / 取消的请求记为 cancelled，不算失败，
///   不计入并发降级，也不触发 onPlayExpired；
/// - 连续 2 次分片失败把该流的并行分段数 8→4→2 降级；
/// - 所有请求写入 `<App 私有目录>/logs/proxy.log`（保留 500 行）。
class LocalHlsProxy {
  LocalHlsProxy({
    this.parallelism = 8,
    // 整集预缓冲：不再只备 5 个分片。按缓存上限把当前这一集尽量都拉下来，
    // 播放时直接命中内存/磁盘，上游抖动或签名过期都影响不到已缓存部分。
    // 每片约 1~2MB，1800 片约 2~3 分钟量；具体条数由 _schedulePrefetch
    // 按 cacheLimitBytes 与预缓冲预算裁剪。
    // 预取条数上限。原来 512：红牛/量子一集 630 片时只能覆盖前 512 片，
    // 拖到后面就得现下。提到 4096 —— 覆盖任何常见一集的全部片数；
    // 真正的闸门是下面的缓存预算（装不下就停），不是这个数。
    this.prefetchCount = 4096,
    // 无限预加载：把整集尽量全部拉到本地，播放时全程读本地。
    //
    // 这是「随便拖进度都秒开」的关键（对标咕噜咕噜的 setInfinitePreload）。
    // 之前的限制是「按缓存预算 70% 折算片数」+「≥6MB 分片只备 3 片」，
    // 结果 4K 只预取 3 片、1080P 约 100 片，往后一拖就要现下。
    // 打开后：预取到缓存上限为止（缓存上限本身随内存自适应），
    // 而不是预先砍到很小；同时在拖进度时仍会立即让位给播放请求。
    this.infinitePreload = true,
    // 预取并发保持低值：整集预热是「后台慢慢存」，不能和当前播放
    // 抢带宽 —— 之前调到 6，seek 要等预取任务腾出连接，秒切就做不到。
    this.prefetchConcurrency = 2,
    this.cacheLimitBytes = 512 * 1024 * 1024,
    this.retries = 3,
    this.retryDelay = const Duration(milliseconds: 300),
    this.playlistRefreshInterval = const Duration(seconds: 90),
    this.platformRefreshTimeout = const Duration(seconds: 30),
    this.spoolThresholdBytes = 8 * 1024 * 1024,
    this.spillToDiskBytes = 4 * 1024 * 1024,
    HlsProxyLogger? log,
  }) : assert(parallelism > 0),
       assert(prefetchCount >= 0),
       assert(prefetchConcurrency > 0),
       assert(cacheLimitBytes >= 0),
       assert(retries >= 0),
       assert(!playlistRefreshInterval.isNegative),
       assert(platformRefreshTimeout > Duration.zero),
       _parallelLevel = parallelism,
       _logger = log ?? _defaultLog;

  static const Duration _connectTimeout = Duration(seconds: 8);
  /// 播放列表单次请求超时。
  ///
  /// 起播链路上这一步是**串行阻塞**的：拿不到完整列表就没法改写、没法起播。
  /// 原来 12 秒，实测上游 CDN 限速时（腾讯 apd-vlive 只有 ~1KB/s）
  /// 用户就是干等十几秒什么都看不到。压到 6 秒：正常列表 0.1~2 秒就回来了，
  /// 超过 6 秒基本可以判定这条链路当下不可用，让上层尽快回退直连。
  static const Duration _playlistTimeout = Duration(seconds: 6);
  static const Duration _segmentTimeout = Duration(seconds: 60);
  static const Duration _playlistTtl = Duration(seconds: 3);
  static const int _minParallelBytes = 128 * 1024;
  static const int _minChunkBytes = 128 * 1024;
  static const int _maxPlaylistBytes = 8 * 1024 * 1024;
  static const int _maxAliases = 50000;
  static const String _defaultUserAgent = 'Mozilla/5.0';

  /// 单个分片失败后的指数退避表：第 1/2/3 次重试分别等 200/600/1500ms。
  static const List<int> _retryBackoffMs = <int>[200, 600, 1500];

  /// 连续多少次「整片下载失败」后把并行分段数砍半（8→4→2，下限 2）。
  static const int _concurrencyDropAfter = 2;

  /// 单个分片并行 Range 的条数（默认 8）。
  final int parallelism;

  /// 播放列表就绪后向前预取的分片数（默认 5）。
  final int prefetchCount;

  /// 是否把整集尽量预加载到本地（默认开）。
  ///
  /// true：预取深度只受 [cacheLimitBytes] 约束，不再按 70% 折半、
  /// 也不再对 ≥6MB 的大分片砍到 3 片 —— 只要缓存装得下就一直往前备，
  /// 这样任意位置拖进度都是读本地。
  /// false：退回旧的保守策略（省内存/省流量）。
  final bool infinitePreload;

  /// 预取同时进行的下载数（默认 3）。
  final int prefetchConcurrency;

  /// 内存 LRU 缓存上限（默认 256MB）。
  final int cacheLimitBytes;

  /// 超过这个大小的分片转存磁盘，内存只留文件引用。
  /// 默认 4MB：常见点播分片 1~3MB，留在内存里缓存命中是同步的（更快），
  /// 只有真正的大分片才落盘，避免「整集预缓冲」把内存撑爆。
  final int spillToDiskBytes;

  /// 单段下载失败重试次数（默认 3，退避 200/600/1500ms）。
  final int retries;

  /// 重试退避基数（保留兼容；实际退避按 [_retryBackoffMs] 指数增长）。
  final Duration retryDelay;

  /// 定期重取 playlist 的间隔，默认 90 秒；传 [Duration.zero] 关闭。
  final Duration playlistRefreshInterval;

  /// Total platform refresh budget, including callback and loaded child tree.
  final Duration platformRefreshTimeout;

  /// 超过该大小的分片，并发下载时用临时文件拼装（默认 8MB）。
  final int spoolThresholdBytes;

  final HlsProxyLogger _logger;

  /// 当前生效的并行分段数：连续 2 次失败后按 8→4→2 降级。
  int _parallelLevel;

  /// 连续整片失败计数（成功即清零）。
  int _failStreak = 0;

  /// HttpClient 代际：切集 / 释放会推进它，旧代际的失败按 cancelled 处理。
  int _clientEpoch = 0;

  /// 平台签名刷新的共享 future：并发分片同时要刷新时只打一次 /api/play。
  Future<bool>? _refreshInflight;

  final LinkedHashMap<String, _CachedBody> _cache =
      LinkedHashMap<String, _CachedBody>();
  final Map<String, Future<_SegmentData>> _segmentInflight =
      <String, Future<_SegmentData>>{};
  final Map<String, Future<_CachedBody>> _keyInflight =
      <String, Future<_CachedBody>>{};
  final Map<String, _CachedPlaylist> _playlistCache =
      <String, _CachedPlaylist>{};
  final Map<String, Future<_RewrittenPlaylist>> _playlistInflight =
      <String, Future<_RewrittenPlaylist>>{};
  final LinkedHashMap<String, _SegmentAlias> _segmentAliases =
      LinkedHashMap<String, _SegmentAlias>();
  final Set<String> _primedPlaylists = <String>{};
  final Set<String> _activePlaylistKeys = <String>{};
  final List<_PrefetchTask> _prefetchQueue = <_PrefetchTask>[];
  final Set<String> _prefetchQueued = <String>{};

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _serverSub;
  HttpClient? _client;
  Directory? _tempDir;

  /// 分片落盘目录（懒创建）。
  Directory? _spoolDir;
  Timer? _refreshTimer;
  Future<void>? _starting;
  Map<String, String> _headers = const <String, String>{};
  String? _activePlaylistUrl;
  Uri? _activeRootUri;
  PlayUrlRefresher? _refreshPlay;
  PlayExpiredCallback? _onPlayExpired;
  final Map<String, Uri> _sourceOverrides = <String, Uri>{};
  int _platformRefreshFails = 0;
  bool _platformExpiredNotified = false;
  int _cacheBytes = 0;

  /// 最近若干次真实下载的吞吐（字节/秒），用于让播放器按实测网速
  /// 调整 demuxer 缓冲：网络好就多缓，网络一般就别等那么久才出画。
  final List<double> _recentSpeeds = <double>[];
  int _cacheHits = 0;
  int _cacheMisses = 0;
  int _prefetchActive = 0;

  /// 起播缓冲统计：本次播放已就绪的分片数与整集分片总数。
  /// 播放页用它算真实起播进度（0–100），而不是拿 mpv 的
  /// cache-buffering-state —— 那个值快满时会长期停在 99，
  /// 界面就会永远显示「缓冲中 99%」。
  int _readySegments = 0;
  int _totalSegments = 0;

  /// 最近一次实测的下载速度（字节/秒），单次下载即更新，
  /// 用于界面上显示「3.2 MB/s」。0 表示还没测到。
  double _liveSpeed = 0;

  /// 首帧是否已经出来（播放器已经成功取到并解码了第一个分片）。
  ///
  /// 首帧之前**不跑预取**：起播时播放器要抢第一个分片，预取一开就是
  /// 4~6 路并发抢连接，首片只能排队 —— 这就是「4K 起播比别家慢」的主因。
  /// 首帧出来后由 [markFirstFrameReady] 打开，才开始整集预热。
  bool _firstFrameReady = false;

  /// 播放器报告首帧已出：放开预取。
  ///
  /// 同时把「首屏要用的那几个分片」从队列里摘掉（它们已经在缓存里了），
  /// 让预取直接跳到播放位置之后，避免重复排队。
  void markFirstFrameReady() {
    if (_firstFrameReady) return;
    _firstFrameReady = true;
    _pumpPrefetch();
  }

  /// 最近一次播放器请求的分片序号，用于识别 seek。
  int _lastPlaybackIndex = -1;

  /// 最近一次播放器请求分片的时间，用于让预取避让。
  DateTime _lastPlaybackAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 正在跑的预取任务，seek 时统一标记取消。
  final Set<_PrefetchTask> _prefetchRunning = <_PrefetchTask>{};
  int _generation = 0;
  int _tempSerial = 0;
  bool _refreshing = false;
  bool _disposed = false;

  /// 本机代理监听端口；未启动时为 0。
  int get port => _server?.port ?? 0;

  /// 本地服务是否已启动。
  bool get running => _server != null;

  /// 缓存命中次数（测试 / 日志用）。
  int get cacheHits => _cacheHits;

  /// 缓存未命中次数。
  int get cacheMisses => _cacheMisses;

  /// 当前缓存字节数。
  int get cacheBytes => _cacheBytes;

  /// 起播进度（0–100）：已就绪分片 / 整集分片。
  ///
  /// 到 100 说明首屏要用的内容已经齐了，界面可以收起进度环。
  /// 拿不到总片数时返回 0（调用方退回不确定态圆环）。
  double get startupPercent {
    if (_totalSegments <= 0) return 0;
    final pct = _readySegments * 100 / _totalSegments;
    return pct.clamp(0, 100).toDouble();
  }

  /// 实时下载速度（字节/秒）；0 表示还没测到。
  double get liveSpeed => _liveSpeed;

  /// 近几次分片下载的中位吞吐（字节/秒）。样本不足返回 null，
  /// 调用方据此跳过自适应、保持默认缓冲。
  double? get recentThroughput {
    if (_recentSpeeds.length < 3) return null;
    final sorted = List<double>.of(_recentSpeeds)..sort();
    return sorted[sorted.length ~/ 2];
  }

  /// 当前缓存条目数。
  int get cacheEntryCount => _cache.length;

  /// 临时目录路径（仅用于测试 / 诊断）。
  String? get tempDirPath => _tempDir?.path;

  static void _defaultLog(String message) {
    developer.log(message, name: 'LocalHlsProxy');
  }

  void _log(String message) {
    // 控制台 + 落盘双写；任何一边失败都不影响播放。
    try {
      _logger('[HLS] $message');
    } catch (_) {
      // 日志失败不影响播放。
    }
    HlsProxyLog.write(message);
  }

  /// 请求日志行：时间由 [HlsProxyLog] 统一加，这里给
  /// URL / 状态 / 重试次数 / 并发级 / cancelled 区分。
  String _reqLine(
    String kind,
    Uri uri, {
    int? index,
    required String status,
    int retry = 0,
    bool cancelled = false,
    String? detail,
  }) {
    final buffer = StringBuffer(kind);
    if (index != null) buffer.write(' #$index');
    buffer
      ..write(' ${_short(uri)}')
      ..write(' status=$status')
      ..write(' retry=$retry')
      ..write(' conc=$_parallelLevel')
      ..write(' cancelled=${cancelled ? 1 : 0}');
    if (detail != null && detail.isNotEmpty) buffer.write(' $detail');
    return buffer.toString();
  }

  /// 第 [retryIndex] 次重试（1 起）前的退避时长：200 / 600 / 1500ms。
  Duration _backoff(int retryIndex) {
    final slot = retryIndex.clamp(1, _retryBackoffMs.length);
    return Duration(milliseconds: _retryBackoffMs[slot - 1]);
  }

  /// 失败是否属于「被取消」：我们自己重建 / 关闭了 HttpClient，
  /// 或者错误文案本身就是 cancel / abort。这类不算失败。
  bool _isCancelled(Object error, int epoch) {
    if (_disposed || epoch != _clientEpoch) return true;
    if (error is _CancelledException) return true;
    final text = error.toString().toLowerCase();
    return text.contains('cancel') || text.contains('abort');
  }

  /// 记一次成功的分片下载：清零连续失败计数，并推进起播进度。
  ///
  /// 缓存命中的分片也算「已就绪」—— 它们本来就在本地，播放不用等，
  /// 起播进度应该把它们计入，否则命中缓存时进度会虚低。
  void _noteSegmentSuccess([_SegmentData? data]) {
    if (_failStreak != 0) _failStreak = 0;
    if (data == null) return;
    if (data.cacheHit) {
      _readySegments++;
      return;
    }
    _readySegments++;
    final us = data.elapsed.inMicroseconds;
    if (us <= 0 || data.bytes.isEmpty) return;
    final speed = data.bytes.length * 1000000 / us;
    _liveSpeed = speed;
    _recentSpeeds.add(speed);
    if (_recentSpeeds.length > 8) _recentSpeeds.removeAt(0);
  }

  /// 记一次整片失败：连续 2 次就把该流的并行分段数砍半并记日志。
  void _noteSegmentFailure() {
    _failStreak++;
    if (_failStreak < _concurrencyDropAfter) return;
    _failStreak = 0;
    if (_parallelLevel <= 2) return;
    final old = _parallelLevel;
    _parallelLevel = math.max(2, old ~/ 2);
    _log('连续 $_concurrencyDropAfter 次分片失败：并发 $old → $_parallelLevel 路');
  }

  // ------------------------------------------------------------ lifecycle

  /// 启动本地 HTTP 服务（幂等）。代理地址在 [port]。
  Future<void> start() async {
    if (_disposed) throw StateError('LocalHlsProxy 已释放');
    if (_server != null) return;
    final pending = _starting;
    if (pending != null) return pending;
    final future = _start();
    _starting = future;
    try {
      await future;
    } finally {
      if (identical(_starting, future)) _starting = null;
    }
  }

  Future<void> _start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_disposed) {
      await server.close(force: true);
      throw StateError('LocalHlsProxy 已释放');
    }
    server.autoCompress = false;
    _server = server;
    _client = _newClient();
    _serverSub = server.listen(
      _handleRequest,
      onError: (Object error, StackTrace stack) {
        _log('本地服务错误: $error');
      },
    );
    try {
      _tempDir = await Directory.systemTemp.createTemp('fx_hls_proxy_');
    } catch (_) {
      _tempDir = null;
    }
    _log('本地分片代理已启动 http://127.0.0.1:${server.port}');
  }

  HttpClient _newClient() {
    return HttpClient()
      ..connectionTimeout = _connectTimeout
      ..idleTimeout = const Duration(seconds: 30)
      ..autoUncompress = true
      ..maxConnectionsPerHost = math.max(_parallelLevel * 2, 16);
  }

  /// 关闭本地服务、取消预取与定时刷新、清空内存缓存和临时文件。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _clientEpoch++;
    _prefetchQueue.clear();
    _prefetchQueued.clear();
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _clearCaches();
    _playlistCache.clear();
    _playlistInflight.clear();
    _segmentAliases.clear();
    _activePlaylistKeys.clear();
    _primedPlaylists.clear();

    final starting = _starting;
    if (starting != null) {
      try {
        await starting;
      } catch (_) {
        // 启动失败时无需再关闭。
      }
    }
    final sub = _serverSub;
    _serverSub = null;
    try {
      await sub?.cancel();
    } catch (_) {}
    final server = _server;
    _server = null;
    try {
      await server?.close(force: true);
    } catch (_) {}
    final client = _client;
    _client = null;
    client?.close(force: true);

    final dir = _tempDir;
    _tempDir = null;
    if (dir != null) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // 临时目录可能已被系统清理，忽略。
      }
    }
    _log('本地分片代理已关闭');
    // 退出前把 proxy.log 的尾部冲刷到磁盘。
    unawaited(HlsProxyLog.flush());
  }

  /// 切集 / 退出时取消预取队列。正在执行的下载会自然结束，
  /// 新一集调用 [proxy] 时会重建 HttpClient 中止旧连接。
  void cancelPrefetch() {
    _generation++;
    _clearPrefetchQueue();
  }

  void _clearPrefetchQueue() {
    _prefetchQueue.clear();
    _prefetchQueued.clear();
  }

  // --------------------------------------------------------------- public

  /// 拉取 [m3u8Url] 并返回可交给播放器的本地 m3u8 地址。
  ///
  /// [headers] 为原播放请求的 Referer / User-Agent 等，会透传给源站。
  /// 失败时抛异常，调用方应回退直连。
  Future<String> proxy(
    String m3u8Url,
    Map<String, String> headers, {
    PlayUrlRefresher? refreshPlay,
    PlayExpiredCallback? onPlayExpired,
  }) async {
    if (_disposed) throw StateError('LocalHlsProxy 已释放');
    final uri = Uri.tryParse(m3u8Url.trim());
    if (uri == null ||
        !uri.hasScheme ||
        !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw ArgumentError.value(m3u8Url, 'm3u8Url', '不是有效的 http(s) 地址');
    }
    // 同步占坑：快速连切线路时，后发起的 proxy() 一定拥有更大的 generation，
    // 先发起但更晚返回的请求会被判定为过期，不能覆盖新一集的 headers / 预取。
    final requestGeneration = ++_generation;
    await start();
    if (_disposed) throw StateError('LocalHlsProxy 已释放');
    if (requestGeneration != _generation) {
      throw StateError('本地代理请求已被新的播放地址替代');
    }

    // 切集：取消旧预取；旧连接可能还在下载，重建 client 让它们尽快退出。
    final hadWork = _prefetchActive > 0 || _prefetchQueue.isNotEmpty;
    _clearPrefetchQueue();
    if (hadWork) _resetClient();
    // 新的一集 / 新的线路：并发级与失败计数回到初始值（8 路起步）。
    if (_parallelLevel != parallelism || _failStreak != 0) {
      _log('新播放源：并发恢复 $_parallelLevel → $parallelism 路');
      _parallelLevel = parallelism;
      _failStreak = 0;
    }
    _refreshTimer?.cancel();
    _refreshTimer = null;

    _headers = _normalizeHeaders(headers);
    _refreshPlay = refreshPlay;
    _onPlayExpired = onPlayExpired;
    _activeRootUri = uri;
    _platformRefreshFails = 0;
    _platformExpiredNotified = false;
    final sourceKey = uri.toString();
    if (_activePlaylistUrl != null && _activePlaylistUrl != sourceKey) {
      // 换集时清掉上一集的缓存与映射，避免 256MB 被旧集占满。
      _clearCaches();
      _playlistCache.clear();
      _segmentAliases.clear();
      _activePlaylistKeys.clear();
      _primedPlaylists.clear();
      _sourceOverrides.clear();
    }
    _activePlaylistUrl = sourceKey;

    final rewritten = await _loadPlaylist(uri, ttl: Duration.zero);
    if (_disposed || requestGeneration != _generation) {
      throw StateError('本地代理请求已被新的播放地址替代');
    }
    if (rewritten.playlist.isMaster) {
      unawaited(_prefetchFirstVariant(rewritten.playlist));
    } else {
      _activePlaylistKeys.add(rewritten.playlist.key);
      // 记下整集分片总数，供起播进度用（真实百分比，不会卡在 99）。
      _totalSegments = rewritten.playlist.segments.length;
      _readySegments = 0;
      _primePrefetch(rewritten.playlist);
    }
    _startRefreshTimer();
    _log(
      '播放列表就绪 ${_short(uri)} '
      '(${rewritten.playlist.isMaster ? 'master' : 'media'}, '
      '${rewritten.playlist.segments.length} 个分片)',
    );
    return 'http://127.0.0.1:$port/playlist?u=${_encodeUrl(sourceKey)}';
  }

  /// 手动刷新所有活跃播放列表（测试 / 诊断用）。
  Future<void> refreshPlaylists() => _refreshActivePlaylists();

  // --------------------------------------------------------------- server

  Future<void> _handleRequest(HttpRequest request) async {
    if (_disposed) {
      try {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
      } catch (_) {}
      return;
    }
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        await _writeText(
          request,
          HttpStatus.methodNotAllowed,
          'method not allowed',
        );
        return;
      }
      switch (request.uri.path) {
        case '/playlist':
          await _servePlaylist(request);
          break;
        case '/seg':
          await _serveSegment(request);
          break;
        case '/key':
          await _serveKey(request);
          break;
        case '/health':
          await _writeText(request, HttpStatus.ok, 'ok');
          break;
        default:
          await _writeText(request, HttpStatus.notFound, 'not found');
      }
    } catch (error) {
      // mpv 取消请求（seek / 切集）导致的中断单独标记，不算代理故障。
      final cancelled = error is _CancelledException || _isLocalCancel(error);
      _log(
        '本地请求 ${request.uri.path} '
        '${cancelled ? 'cancelled(客户端已取消)' : '失败'}: $error',
      );
      if (cancelled) return;
      await _writeText(request, HttpStatus.badGateway, 'proxy error: $error');
    }
  }

  /// 本地回写阶段的「客户端已断开」类错误判定。
  static bool _isLocalCancel(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('cancel') ||
        text.contains('abort') ||
        text.contains('connection closed') ||
        text.contains('connection reset') ||
        text.contains('broken pipe') ||
        text.contains('socketexception');
  }

  Future<void> _servePlaylist(HttpRequest request) async {
    final source = _queryUri(request, 'u');
    if (source == null) {
      await _writeText(request, HttpStatus.badRequest, 'missing u');
      return;
    }
    _RewrittenPlaylist rewritten;
    try {
      rewritten = await _loadPlaylist(source, ttl: _playlistTtl);
    } catch (error) {
      final cached = _playlistCache[source.toString()];
      if (cached == null) rethrow;
      rewritten = cached.value;
      _log('播放列表刷新失败，使用上次缓存: $error');
    }
    final playlist = rewritten.playlist;
    if (playlist.isMaster) {
      // master 本身不预取，等播放器选中子列表后再预取。
    } else {
      _activePlaylistKeys.add(playlist.key);
      _primePrefetch(playlist);
    }
    final body = rewritten.body;
    final response = request.response;
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/vnd.apple.mpegurl; charset=utf-8',
    );
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.set(HttpHeaders.acceptRangesHeader, 'none');
    response.contentLength = body.length;
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    response.add(body);
    await response.close();
  }

  Future<void> _serveSegment(HttpRequest request) async {
    final source = _queryUri(request, 'u');
    if (source == null) {
      await _writeText(request, HttpStatus.badRequest, 'missing u');
      return;
    }
    final range = _parseRangeParam(request.uri.queryParameters['r']);
    final index = int.tryParse(request.uri.queryParameters['i'] ?? '');
    final ref = _SegmentRef(source, range);
    final alias = _segmentAliases[ref.cacheKey];

    // mpv 在 seek / 切集时会主动取消本地请求；连接断开后既不回写也
    // 不算这次分片失败（不计并发降级、不触发 refreshPlay / 过期回调）。
    var clientGone = false;
    unawaited(
      request.response.done.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {
          clientGone = true;
        },
      ),
    );

    // 播放器来要分片时，预缓冲必须让路：seek / 起播都是「等不起」的请求，
    // 之前 512 个预取任务把带宽和并发占满，seek 要排队等前面几片下完，
    // 表现就是「不能秒切进度」。
    // 这里先按播放位置重置预取（丢弃跑偏的旧任务），并把并发让给正片。
    if (alias != null) {
      _yieldPrefetchToPlayback(alias.index);
      final playlist = _playlistCache[alias.playlistKey]?.value.playlist;
      if (playlist != null) _schedulePrefetch(playlist, alias.index + 1);
    }

    final stopwatch = Stopwatch()..start();

    // ── 流式快路径：缓存未命中且不需要 Range 时，边下边转发给播放器 ──
    //
    // 之前所有分片都要「整片下完」才回给 mpv：4K 分片 2.8~4.4MB，
    // 首片要等 1.2 秒才拿到第一个字节，mpv 这期间完全没数据可解，
    // 用户看到的就是「首次加载十几秒」。
    //
    // 现在改成：上游来一块就往下游写一块，mpv 收到头几十 KB 就能开始
    // 解码出画；同时把字节攒在内存里，传完之后照常写进缓存 ——
    // 下次 seek 回来还是缓存命中，不牺牲后续体验。
    //
    // 只在不带 Range、且缓存未命中时走这条路：
    //   · 带 Range（seek）需要精确偏移，必须整片下载后再切片；
    //   · 缓存命中本来就是内存里现成的，直接走原路径更快。
    final rangeParam = request.uri.queryParameters['r'];
    if (rangeParam == null || rangeParam.isEmpty) {
      final cacheKey0 = _segmentAliases[ref.cacheKey]?.cacheKey ?? 'seg:${ref.cacheKey}';
      if (_cacheGet(cacheKey0) == null) {
        final streamed = await _tryServeSegmentStreamed(
          request,
          ref,
          alias,
          index: index,
          source: source,
          stopwatch: stopwatch,
          cacheKey: cacheKey0,
        );
        if (streamed) return;
      }
    }

    _SegmentData data;
    try {
      data = await _loadSegment(ref);
    } catch (error) {
      // 被取消（播放器放弃 / 切集）与真实失败分开记账。
      final cancelled = error is _CancelledException || clientGone;
      _log(
        _reqLine(
          'SEG',
          source,
          index: index,
          status: cancelled ? 'cancelled' : 'error',
          cancelled: cancelled,
          detail: cancelled ? '$error' : 'segment error: $error',
        ),
      );
      if (clientGone || error is _CancelledException) return;
      // 只有整条流重试全部用尽才会走到这里：播放器此时还在用已有缓冲。
      await _writeText(request, HttpStatus.badGateway, 'segment error: $error');
      return;
    }

    if (clientGone) {
      _log(
        _reqLine(
          'SEG',
          source,
          index: index,
          status: 'cancelled',
          cancelled: true,
          detail: 'mpv 已断开，跳过回写',
        ),
      );
      return;
    }

    _log(
      _reqLine(
        'SEG',
        source,
        index: index,
        status: '200',
        retry: data.retryCount,
        detail:
            '${stopwatch.elapsedMilliseconds}ms ${data.cacheHit ? 'cache-hit' : 'parallel=${data.parallelCount}'} '
            '${_formatBytes(data.bytes.length)}',
      ),
    );

    try {
      var body = data.bytes;
      var status = HttpStatus.ok;
      String? contentRange;
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      if (rangeHeader != null && rangeHeader.trim().isNotEmpty) {
        final requested = _parseHttpRange(rangeHeader, body.length);
        if (requested != null && requested.length <= 0) {
          await _writeText(
            request,
            HttpStatus.requestedRangeNotSatisfiable,
            'range not satisfiable',
          );
          return;
        }
        if (requested != null) {
          body = Uint8List.sublistView(
            data.bytes,
            requested.start,
            requested.start + requested.length,
          );
          status = HttpStatus.partialContent;
          contentRange =
              'bytes ${requested.start}-'
              '${requested.start + requested.length - 1}/${data.bytes.length}';
        }
      }

      final response = request.response;
      response.statusCode = status;
      response.headers.set(
        HttpHeaders.contentTypeHeader,
        _segmentContentType(source, data.contentType),
      );
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (contentRange != null) {
        response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
      }
      response.contentLength = body.length;
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }
      response.add(body);
      await response.close();
    } catch (error) {
      // 写回失败 = mpv 已经取消了这条请求（seek / 切集）：记 cancelled，
      // 不算分片失败，分片内容也已进缓存，下次 seek 回来直接命中。
      _log(
        _reqLine(
          'SEG',
          source,
          index: index,
          status: 'cancelled',
          cancelled: true,
          detail: '回写中断: $error',
        ),
      );
    }
  }

  Future<void> _serveKey(HttpRequest request) async {
    final source = _queryUri(request, 'u');
    if (source == null) {
      await _writeText(request, HttpStatus.badRequest, 'missing u');
      return;
    }
    final _CachedBody body;
    try {
      body = await _loadKey(source);
    } catch (error) {
      final cancelled = error is _CancelledException;
      _log(
        _reqLine(
          'KEY',
          source,
          status: cancelled ? 'cancelled' : 'error',
          cancelled: cancelled,
          detail: '$error',
        ),
      );
      if (cancelled) return;
      await _writeText(request, HttpStatus.badGateway, 'key error: $error');
      return;
    }
    final response = request.response;
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      body.contentType?.isNotEmpty == true
          ? body.contentType!
          : 'application/octet-stream',
    );
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.contentLength = body.bytes.length;
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    response.add(body.bytes);
    await response.close();
  }

  Future<void> _writeText(
    HttpRequest request,
    int status,
    String message,
  ) async {
    try {
      final response = request.response;
      response.statusCode = status;
      response.headers.set(
        HttpHeaders.contentTypeHeader,
        'text/plain; charset=utf-8',
      );
      response.write(message);
      await response.close();
    } catch (_) {
      // 客户端可能已断开，忽略。
    }
  }

  // ------------------------------------------------------------ playlist

  Future<_RewrittenPlaylist> _loadPlaylist(
    Uri uri, {
    Duration ttl = _playlistTtl,
  }) {
    final key = uri.toString();
    final cached = _playlistCache[key];
    if (cached != null &&
        ttl > Duration.zero &&
        DateTime.now().difference(cached.at) < ttl) {
      return Future<_RewrittenPlaylist>.value(cached.value);
    }
    final pending = _playlistInflight[key];
    if (pending != null) return pending;
    final future = _fetchAndRewrite(uri);
    _playlistInflight[key] = future;
    return future.whenComplete(() {
      if (identical(_playlistInflight[key], future)) {
        _playlistInflight.remove(key);
      }
    });
  }

  Future<_RewrittenPlaylist> _fetchAndRewrite(Uri uri) async {
    // 平台签名过期后，逻辑 key 仍是旧地址，实际请求走刷新后的新地址；
    // 这样播放器手里的本地 /playlist?u=旧地址 不用变，分片别名也能复用。
    final actual = _sourceOverrides[uri.toString()] ?? uri;
    final fetched = await _fetchPlaylistText(actual);
    final rewritten = _rewritePlaylist(
      fetched.text,
      fetched.finalUri,
      playlistKey: uri.toString(),
    );
    _storePlaylist(rewritten);
    return rewritten;
  }

  void _storePlaylist(_RewrittenPlaylist rewritten) {
    final playlist = rewritten.playlist;
    _playlistCache[playlist.key] = _CachedPlaylist(rewritten, DateTime.now());
    if (!playlist.isMaster && !playlist.isLive) {
      _activePlaylistKeys.add(playlist.key);
      // 用 index 建立稳定映射：签名换新后，旧本地分片地址仍能映射到
      // 同一位置的新地址；缓存也按这个逻辑 key 去重。
      for (var i = 0; i < playlist.segments.length; i++) {
        final segment = playlist.segments[i];
        _segmentAliases[segment.cacheKey] = _SegmentAlias(
          playlistKey: playlist.key,
          index: i,
          cacheKey: 'vod:${playlist.key}#$i',
        );
      }
      _trimAliases();
    }
  }

  Future<_FetchedPlaylist> _fetchPlaylistText(Uri uri) async {
    final response = await _get(
      uri,
      timeout: _playlistTimeout,
      accept:
          'application/vnd.apple.mpegurl,application/x-mpegURL,text/plain,*/*',
    );
    if (response.statusCode < 200 || response.statusCode >= 400) {
      final code = response.statusCode;
      await _drainQuietly(response);
      throw _HttpStatusException(code, uri);
    }
    final contentType =
        response.headers.value(HttpHeaders.contentTypeHeader)?.toLowerCase() ??
        '';
    if (contentType.startsWith('video/') || contentType.startsWith('audio/')) {
      try {
        await response.listen(null).cancel();
      } catch (_) {}
      throw HttpException(
        'not an m3u8 playlist (content-type: $contentType)',
        uri: uri,
      );
    }

    // 流式读取并尽早校验 #EXTM3U：平台线路的包装地址没有 .m3u8 后缀，
    // 万一误把 MP4 当列表拉，也不能把整部视频读进内存。
    final builder = BytesBuilder(copy: false);
    final head = <int>[];
    var checked = false;
    await for (final chunk in response.timeout(_playlistTimeout)) {
      builder.add(chunk);
      if (!checked) {
        final need = 12 - head.length;
        if (need > 0) head.addAll(chunk.take(need));
        if (head.length >= 7) {
          var preview = utf8.decode(head, allowMalformed: true);
          if (preview.startsWith('\uFEFF')) preview = preview.substring(1);
          if (!preview.startsWith('#EXTM3U')) {
            throw HttpException('not an m3u8 playlist', uri: uri);
          }
          checked = true;
        }
      }
      if (builder.length > _maxPlaylistBytes) {
        throw HttpException(
          'playlist too large (over $_maxPlaylistBytes bytes)',
          uri: uri,
        );
      }
    }
    final bytes = builder.takeBytes();
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    if (!text.contains('#EXTM3U')) {
      throw HttpException('not an m3u8 playlist', uri: uri);
    }
    return _FetchedPlaylist(text, _finalUri(uri, response.redirects));
  }

  _RewrittenPlaylist _rewritePlaylist(
    String text,
    Uri base, {
    required String playlistKey,
    bool preserveChildKeys = true,
  }) {
    final isMaster =
        text.contains('#EXT-X-STREAM-INF') ||
        text.contains('#EXT-X-I-FRAME-STREAM-INF') ||
        text.contains('#EXT-X-MEDIA:');
    // ENDLIST / PLAYLIST-TYPE:VOD 都表示点播；否则按直播处理，不做
    // 跨刷新的 index 映射（直播窗口会滑动，index 对应的内容会变）。
    final isLive =
        !text.contains('#EXT-X-ENDLIST') &&
        !text.contains('#EXT-X-PLAYLIST-TYPE:VOD');
    final lines = const LineSplitter().convert(text);
    final out = <String>[];
    final segments = <_SegmentRef>[];
    final variants = <Uri>[];
    Uri childKey(Uri actual) {
      if (preserveChildKeys) {
        final old = _playlistCache[playlistKey]?.value.playlist;
        for (final logical in old?.variants ?? <Uri>[]) {
          if (_sourceOverrides[logical.toString()] == actual) return logical;
        }
      }
      return actual;
    }

    final lastRangeEnd = <String, int>{};
    _RangeSpec? pendingRange;
    var segmentIndex = 0;

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) {
        out.add(raw);
        continue;
      }
      if (line.startsWith('#EXT-X-BYTERANGE:')) {
        final spec = _parseByteRange(
          line.substring('#EXT-X-BYTERANGE:'.length),
        );
        if (spec == null) {
          out.add(raw);
        } else {
          pendingRange = spec;
          // 代理返回的是切好的完整分片，不能再让播放器对本地地址二次
          // Range，否则字节区间会错位；这里直接丢掉该标签。
        }
        continue;
      }
      if (line.startsWith('#EXT-X-KEY:') ||
          line.startsWith('#EXT-X-SESSION-KEY:')) {
        out.add(
          _rewriteUriAttribute(line, base, (uri) => _localUrl('/key', uri)),
        );
        continue;
      }
      if (line.startsWith('#EXT-X-MAP:')) {
        out.add(
          _rewriteUriAttribute(line, base, (uri) => _localUrl('/seg', uri)),
        );
        continue;
      }
      if (line.startsWith('#EXT-X-MEDIA:') ||
          line.startsWith('#EXT-X-I-FRAME-STREAM-INF:')) {
        out.add(
          _rewriteUriAttribute(line, base, (uri) {
            final logical = childKey(uri);
            variants.add(logical);
            return _localUrl('/playlist', logical);
          }),
        );
        continue;
      }
      if (line.startsWith('#EXT-X-PART:')) {
        final parsed = pendingRange;
        pendingRange = null;
        final range = parsed == null
            ? null
            : _RangeSpec(parsed.effectiveStart, parsed.length);
        out.add(
          _rewriteUriAttribute(line, base, (uri) {
            final ref = _SegmentRef(uri, range);
            segments.add(ref);
            return _localUrl('/seg', uri, index: segmentIndex++, range: range);
          }),
        );
        continue;
      }
      if (line.startsWith('#EXT-X-PRELOAD-HINT:')) {
        out.add(
          _rewriteUriAttribute(line, base, (uri) => _localUrl('/seg', uri)),
        );
        continue;
      }
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        out.add(raw);
        continue;
      }
      if (line.startsWith('#')) {
        out.add(raw);
        continue;
      }

      final uri = _resolve(base, line);
      if (uri == null) {
        out.add(raw);
        continue;
      }
      if (isMaster) {
        final logical = childKey(uri);
        variants.add(logical);
        out.add(_localUrl('/playlist', logical));
        continue;
      }

      final parsedRange = pendingRange;
      pendingRange = null;
      _RangeSpec? range;
      if (parsedRange != null) {
        final urlKey = uri.toString();
        final start = parsedRange.start ?? lastRangeEnd[urlKey] ?? 0;
        range = _RangeSpec(start, parsedRange.length);
        lastRangeEnd[urlKey] = start + parsedRange.length;
      }
      final ref = _SegmentRef(uri, range);
      segments.add(ref);
      out.add(_localUrl('/seg', uri, index: segmentIndex++, range: range));
    }

    final playlist = _Playlist(
      key: playlistKey,
      base: base,
      isMaster: isMaster,
      isLive: isLive,
      segments: segments,
      variants: variants,
      timeline: lines
          .map((line) {
            final trimmed = line.trim();
            if (trimmed.startsWith('#EXT-X-KEY:') ||
                trimmed.startsWith('#EXT-X-SESSION-KEY:') ||
                trimmed.startsWith('#EXT-X-MAP:')) {
              return _rewriteUriAttribute(
                trimmed,
                base,
                (uri) => uri.toString(),
              );
            }
            return trimmed;
          })
          .where(
            (line) =>
                line.startsWith('#EXTINF:') ||
                line.startsWith('#EXT-X-MEDIA-SEQUENCE:') ||
                line.startsWith('#EXT-X-DISCONTINUITY') ||
                line.startsWith('#EXT-X-BYTERANGE:') ||
                line.startsWith('#EXT-X-KEY:') ||
                line.startsWith('#EXT-X-SESSION-KEY:') ||
                line.startsWith('#EXT-X-MAP:') ||
                // 这几个是**点播列表的结束标记**，漏掉它们播放器会当成直播：
                // 只播「当前窗口」里的分片，播完就停。
                // 用户报的「4K 只能播 19 秒」就是这里 —— 服务端列表有
                // #EXT-X-ENDLIST（152 片/2872 秒完整），但客户端重写时把它
                // 丢了，mpv 判成 live 流，播完头几个分片就结束。
                line.startsWith('#EXT-X-ENDLIST') ||
                line.startsWith('#EXT-X-PLAYLIST-TYPE:') ||
                line.startsWith('#EXT-X-TARGETDURATION:') ||
                line.startsWith('#EXT-X-VERSION:'),
          )
          .join('\n'),
    );
    final body = Uint8List.fromList(utf8.encode(out.join('\n')));
    return _RewrittenPlaylist(body, playlist);
  }

  String _rewriteUriAttribute(
    String line,
    Uri base,
    String Function(Uri uri) transform,
  ) {
    final pattern = RegExp(
      r'''URI\s*=\s*(?:"([^"]*)"|'([^']*)'|([^,\s]+))''',
      caseSensitive: false,
    );
    return line.replaceAllMapped(pattern, (match) {
      final raw = match.group(1) ?? match.group(2) ?? match.group(3) ?? '';
      final uri = _resolve(base, raw);
      if (uri == null ||
          uri.isScheme('data') ||
          !(uri.isScheme('http') || uri.isScheme('https'))) {
        return match.group(0)!;
      }
      return 'URI="${transform(uri)}"';
    });
  }

  String _localUrl(String path, Uri source, {int? index, _RangeSpec? range}) {
    final query = <String>[];
    if (index != null) query.add('i=$index');
    query.add('u=${_encodeUrl(source.toString())}');
    if (range != null) query.add('r=${range.start}-${range.length}');
    return 'http://127.0.0.1:$port$path?${query.join('&')}';
  }

  // ------------------------------------------------------------- segments

  Future<_SegmentData> _loadSegment(_SegmentRef ref) async {
    final alias = _segmentAliases[ref.cacheKey];
    final cacheKey = alias?.cacheKey ?? 'seg:${ref.cacheKey}';
    final cached = _cacheGet(cacheKey);
    if (cached != null) {
      _cacheHits++;
      // 内存缓存直接同步命中；只有落盘的大分片才读文件。
      final bytes =
          cached.file == null ? cached.bytes : await cached.readBytes();
      return _SegmentData(
        bytes,
        cached.contentType,
        0,
        Duration.zero,
        true,
      );
    }
    _cacheMisses++;
    final pending = _segmentInflight[cacheKey];
    if (pending != null) return pending;
    final future = _downloadSegmentWithRefresh(ref, alias);
    _segmentInflight[cacheKey] = future;
    try {
      final data = await future;
      _cachePut(cacheKey, _CachedBody(data.bytes, data.contentType));
      return data;
    } finally {
      if (identical(_segmentInflight[cacheKey], future)) {
        _segmentInflight.remove(cacheKey);
      }
    }
  }

  /// 边下边转发一个分片；成功接管响应时返回 true。
  ///
  /// 返回 false 表示「这条路走不通，请调用方回退到整片下载」—— 比如
  /// 上游状态码异常、客户端中途断开、或者这次请求本身被取消。
  Future<bool> _tryServeSegmentStreamed(
    HttpRequest request,
    _SegmentRef ref,
    _SegmentAlias? alias, {
    required int? index,
    required Uri source,
    required Stopwatch stopwatch,
    required String cacheKey,
  }) async {
    final target = _latestSegment(alias) ?? ref;
    HttpClientResponse response;
    try {
      response = await _get(target.uri);
    } catch (_) {
      return false; // 连不上就让整片下载路径带重试去处理
    }
    final status = response.statusCode;
    if (status != HttpStatus.ok) {
      await _drainQuietly(response);
      return false; // 403/404 需要 refreshPlay 自愈，交给整片路径
    }

    final contentType = response.headers.value(HttpHeaders.contentTypeHeader);
    final builder = BytesBuilder(copy: false);
    var started = false;
    var firstByteMs = -1;
    try {
      await for (final chunk in response) {
        builder.add(chunk);
        if (!started) {
          // 收到第一块才回表头：上游若提前报错，上面已经回退，
          // 不会出现「头已经发出去、正文却是空的」这种半截响应。
          started = true;
          firstByteMs = stopwatch.elapsedMilliseconds;
          final out = request.response;
          out.statusCode = HttpStatus.ok;
          out.headers.set(
            HttpHeaders.contentTypeHeader,
            _segmentContentType(source, contentType),
          );
          out.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
          // 不设 contentLength：长度未知时让 Dart 用 chunked 编码，
          // 播放器拿到就能解，不必等整片。
          await out.flush();
        }
        request.response.add(chunk);
        await request.response.flush();
      }
    } catch (error) {
      // 中途断了：已经给播放器发过数据就不能再回退重试，
      // 只能把这次传输记成失败，让它下一次请求重新拉。
      _log(
        _reqLine(
          'SEG',
          source,
          index: index,
          status: 'stream-abort',
          cancelled: _isLocalCancel(error),
          detail: '$error',
        ),
      );
      try {
        await request.response.close();
      } catch (_) {}
      return true;
    }

    if (!started) {
      await _drainQuietly(response);
      return false; // 上游 200 但一个字节都没有
    }

    final bytes = builder.takeBytes();
    await request.response.close();
    _cachePut(cacheKey, _CachedBody(bytes, contentType));
    _log(
      _reqLine(
        'SEG',
        source,
        index: index,
        status: '200',
        detail: '${firstByteMs}ms 首包 / ${stopwatch.elapsedMilliseconds}ms 完成 '
            'stream ${_formatBytes(bytes.length)}',
      ),
    );
    return true;
  }

  /// 下载分片（带自愈重试）：
  ///
  /// - 单分片失败按 200/600/1500ms 指数退避最多重试 [retries] 次；
  /// - 平台线路每次重试前先 refreshPlay 换新签名地址（并发时共享同一次
  ///   刷新），403 / 404 则立即刷新列表再试；
  /// - 被取消（切集 / 释放 / 播放器放弃）的请求不算失败，直接抛
  ///   [_CancelledException]，不计并发降级、不触发 onPlayExpired；
  /// - 全部重试用尽才把错误抛回给播放器。
  Future<_SegmentData> _downloadSegmentWithRefresh(
    _SegmentRef ref,
    _SegmentAlias? alias,
  ) async {
    var target = _latestSegment(alias) ?? ref;
    final index = alias?.index;
    var retry = 0;
    while (true) {
      final epoch = _clientEpoch;
      try {
        final data = await _downloadSegment(target);
        _noteSegmentSuccess(data);
        if (retry == 0) return data;
        return _SegmentData(
          data.bytes,
          data.contentType,
          data.parallelCount,
          data.elapsed,
          data.cacheHit,
          retryCount: retry,
        );
      } on _CancelledException {
        rethrow;
      } catch (error) {
        if (_isCancelled(error, epoch)) {
          _log(
            _reqLine(
              'SEG',
              target.uri,
              index: index,
              status: 'cancelled',
              retry: retry,
              cancelled: true,
              detail: 'err=$error',
            ),
          );
          throw _CancelledException(error);
        }
        final http = error is _HttpStatusException ? error.statusCode : null;
        final expired =
            http == HttpStatus.forbidden || http == HttpStatus.notFound;
        if (retry >= retries) {
          _noteSegmentFailure();
          _log(
            _reqLine(
              'SEG',
              target.uri,
              index: index,
              status: http == null ? 'error' : 'HTTP $http',
              retry: retry,
              detail: '重试用尽 err=$error',
            ),
          );
          rethrow;
        }
        retry++;
        final delay = _backoff(retry);
        // 平台线路（临时签名）：重试前 refreshPlay 拿新地址；
        // 403 / 404 是签名过期，任何线路都先刷新列表。
        var action = 'backoff';
        if (expired || (_refreshPlay != null && _isPlatformPlaylist)) {
          final refreshed = await _refreshForAlias(alias);
          final latest = _latestSegment(alias);
          if (latest != null) target = latest;
          action = refreshed ? 'refresh-ok' : 'refresh-fail';
        }
        _log(
          _reqLine(
            'SEG',
            target.uri,
            index: index,
            status: http == null ? 'retry' : 'HTTP $http',
            retry: retry,
            detail: 'err=$error backoff=${delay.inMilliseconds}ms $action',
          ),
        );
        await Future<void>.delayed(delay);
      }
    }
  }

  Future<_SegmentData> _downloadSegment(_SegmentRef ref) async {
    final stopwatch = Stopwatch()..start();
    final _Downloaded downloaded;
    // 这里的单连接下载不再自行退避：外层 [_downloadSegmentWithRefresh]
    // 统一负责 200/600/1500ms 重试与平台 refreshPlay，避免两层重试相乘。
    if (ref.range != null) {
      downloaded = await _downloadWhole(
        ref,
        expectedLength: ref.range!.length,
        attempts: 1,
      );
    } else {
      final head = await _head(ref.uri);
      final length = head?.contentLength;
      if (length != null &&
          length >= _minParallelBytes &&
          _supportsRanges(head?.acceptRanges)) {
        try {
          downloaded = await _downloadParallel(ref, length);
        } on _HttpStatusException catch (error) {
          if (error.statusCode == HttpStatus.forbidden ||
              error.statusCode == HttpStatus.notFound) {
            rethrow;
          }
          _log('并行下载失败回退单连接 ${_short(ref.uri)}: $error');
          return _finishDownload(
            ref,
            await _downloadWhole(ref, expectedLength: length, attempts: 1),
            stopwatch,
          );
        } catch (error) {
          _log('并行下载失败回退单连接 ${_short(ref.uri)}: $error');
          return _finishDownload(
            ref,
            await _downloadWhole(ref, expectedLength: length, attempts: 1),
            stopwatch,
          );
        }
      } else {
        downloaded = await _downloadWhole(
          ref,
          expectedLength: length,
          attempts: 1,
        );
      }
    }
    return _finishDownload(ref, downloaded, stopwatch);
  }

  _SegmentData _finishDownload(
    _SegmentRef ref,
    _Downloaded downloaded,
    Stopwatch stopwatch,
  ) {
    return _SegmentData(
      downloaded.bytes,
      downloaded.contentType,
      downloaded.parallelCount,
      stopwatch.elapsed,
      false,
    );
  }

  Future<_Downloaded> _downloadParallel(_SegmentRef ref, int length) async {
    // 并行分段数用自适应级别：连续 2 次失败后 8→4→2。
    //
    // 4K 片源的分片极大（实测单片 10~40MB，一集 97 片约 2.4GB），
    // 8 路 2.5MB 一块时单片的下载时间仍然远超播放消耗，表现就是
    // 「4K 经常卡」和「拖动要等很久」。这里按分片大小动态加路数：
    //   ≥16MB → 16 路（每块约 1~2MB，和普通 1080P 分片一个量级）
    //   ≥6MB  → 12 路
    //   其余   → 原自适应级别
    // 仍受 _parallelLevel 上限约束（连续失败会自动降级到 4/2，不会打爆）。
    // 大分片**不要**加并发：16 路同时打一个 CDN 会被限流，
    // 表现就是「一直卡在那几秒、反复重连」。实测下来 6 路是稳定上限，
    // 每块 2~7MB，单片仍能在播放耗尽前下完。
    var targetParallel = _parallelLevel;
    if (length >= 6 * 1024 * 1024) {
      targetParallel = math.min(_parallelLevel, 6);
    }
    final count = math.min(
      targetParallel,
      math.max(2, length ~/ _minChunkBytes),
    );
    if (count < 2) {
      return _downloadWhole(ref, expectedLength: length);
    }
    if (spoolThresholdBytes > 0 && length >= spoolThresholdBytes) {
      try {
        return await _downloadParallelSpooled(ref, length, count);
      } catch (error) {
        _log('临时文件拼装失败，回退内存: $error');
        return _downloadWhole(ref, expectedLength: length);
      }
    }

    final chunkSize = (length / count).ceil();
    final first = await _fetchRangeWithRetry(ref.uri, 0, chunkSize - 1);
    if (first.statusCode == HttpStatus.ok) {
      // 源站忽略 Range，返回了完整文件。
      if (first.bytes.length == length) {
        return _Downloaded(first.bytes, first.contentType, 1);
      }
      throw HttpException('range ignored, size mismatch', uri: ref.uri);
    }
    if (first.totalLength != null && first.totalLength != length) {
      throw HttpException(
        'content-length changed (${first.totalLength} != $length)',
        uri: ref.uri,
      );
    }

    final futures = <Future<_RangeFetch>>[];
    for (var i = 1; i < count; i++) {
      final start = i * chunkSize;
      if (start >= length) break;
      final end = math.min(length - 1, start + chunkSize - 1);
      futures.add(_fetchRangeWithRetry(ref.uri, start, end));
    }
    final rest = await Future.wait(futures, eagerError: true);
    final bytes = Uint8List(length);
    bytes.setRange(0, first.bytes.length, first.bytes);
    var offset = first.bytes.length;
    for (final chunk in rest) {
      bytes.setRange(offset, offset + chunk.bytes.length, chunk.bytes);
      offset += chunk.bytes.length;
    }
    if (offset != length) {
      throw HttpException(
        'parallel size mismatch ($offset != $length)',
        uri: ref.uri,
      );
    }
    return _Downloaded(bytes, first.contentType, 1 + rest.length);
  }

  /// 超大分片：每个 Range 直接落临时文件，再拼成完整字节。
  Future<_Downloaded> _downloadParallelSpooled(
    _SegmentRef ref,
    int length,
    int count,
  ) async {
    final tempDir = _tempDir;
    if (tempDir == null) {
      throw StateError('临时目录不可用');
    }
    final sessionDir = Directory(
      '${tempDir.path}/s${_tempSerial++}_${DateTime.now().microsecondsSinceEpoch}',
    );
    await sessionDir.create(recursive: true);
    try {
      final chunkSize = (length / count).ceil();
      final ranges = <_RangeSpec>[];
      for (var i = 0; i < count; i++) {
        final start = i * chunkSize;
        if (start >= length) break;
        ranges.add(_RangeSpec(start, math.min(chunkSize, length - start)));
      }
      final parts = await Future.wait(
        ranges.map((range) async {
          final fetch = await _fetchRangeWithRetry(
            ref.uri,
            range.effectiveStart,
            range.effectiveStart + range.length - 1,
          );
          final file = File(
            '${sessionDir.path}/part_${range.effectiveStart}.bin',
          );
          await file.writeAsBytes(fetch.bytes, flush: false);
          return _SpoolPart(file, fetch.bytes.length, fetch.contentType);
        }),
        eagerError: true,
      );
      final bytes = Uint8List(length);
      var offset = 0;
      for (final part in parts) {
        final chunk = await part.file.readAsBytes();
        if (chunk.length != part.length) {
          throw HttpException('spooled chunk size mismatch', uri: ref.uri);
        }
        bytes.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }
      if (offset != length) {
        throw HttpException('spooled size mismatch', uri: ref.uri);
      }
      return _Downloaded(
        bytes,
        parts.isEmpty ? null : parts.first.contentType,
        parts.length,
      );
    } finally {
      try {
        await sessionDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<_RangeFetch> _fetchRangeWithRetry(Uri uri, int start, int end) async {
    Object? lastError;
    for (var attempt = 0; attempt <= retries; attempt++) {
      final epoch = _clientEpoch;
      try {
        return await _fetchRange(uri, start, end);
      } on _HttpStatusException catch (error) {
        if (error.statusCode == HttpStatus.forbidden ||
            error.statusCode == HttpStatus.notFound) {
          rethrow; // 403/404 交给上层刷新 playlist，不做无意义重试。
        }
        if (_isCancelled(error, epoch)) throw _CancelledException(error);
        lastError = error;
      } on _CancelledException {
        rethrow;
      } catch (error) {
        if (_isCancelled(error, epoch)) throw _CancelledException(error);
        lastError = error;
      }
      if (attempt < retries) {
        final delay = _backoff(attempt + 1);
        _log(
          _reqLine(
            'CHUNK',
            uri,
            status: 'retry',
            retry: attempt + 1,
            detail:
                'range=$start-$end backoff=${delay.inMilliseconds}ms '
                'err=$lastError',
          ),
        );
        await Future<void>.delayed(delay);
      }
    }
    throw StateError('Range $start-$end 下载失败: $lastError');
  }

  Future<_RangeFetch> _fetchRange(Uri uri, int start, int end) async {
    final response = await _get(uri, range: 'bytes=$start-$end');
    final status = response.statusCode;
    final contentType = response.headers.value(HttpHeaders.contentTypeHeader);
    if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
      final code = status;
      await _drainQuietly(response);
      throw _HttpStatusException(code, uri);
    }
    final bytes = await _readAll(response).timeout(_segmentTimeout);
    if (status == HttpStatus.ok) {
      return _RangeFetch(bytes, 1, contentType, null);
    }
    final parsed = _parseContentRange(
      response.headers.value(HttpHeaders.contentRangeHeader),
    );
    final requestLength = end - start + 1;
    if (bytes.length != requestLength) {
      throw HttpException(
        'range size mismatch (${bytes.length} != $requestLength)',
        uri: uri,
      );
    }
    if (parsed != null && parsed.start != start) {
      throw HttpException('range start mismatch', uri: uri);
    }
    return _RangeFetch(bytes, status, contentType, parsed?.total);
  }

  Future<_Downloaded> _downloadWhole(
    _SegmentRef ref, {
    int? expectedLength,
    int? attempts,
  }) async {
    // [attempts] 允许调用方把退避交给外层（分片级重试）统一负责。
    final maxTries = attempts ?? (retries + 1);
    Object? lastError;
    for (var attempt = 0; attempt < maxTries; attempt++) {
      final epoch = _clientEpoch;
      try {
        final response = await _get(
          ref.uri,
          range: ref.range == null
              ? null
              : 'bytes=${ref.range!.effectiveStart}-${ref.range!.end}',
        );
        final status = response.statusCode;
        final contentType = response.headers.value(
          HttpHeaders.contentTypeHeader,
        );
        if (status != HttpStatus.ok && status != HttpStatus.partialContent) {
          final code = status;
          await _drainQuietly(response);
          throw _HttpStatusException(code, ref.uri);
        }
        final raw = await _readAll(response).timeout(_segmentTimeout);
        var bytes = raw;
        if (ref.range != null) {
          final spec = ref.range!;
          final start = spec.effectiveStart;
          if (status == HttpStatus.ok && raw.length >= start + spec.length) {
            bytes = Uint8List.sublistView(raw, start, start + spec.length);
          } else if (status == HttpStatus.ok && raw.length != spec.length) {
            throw HttpException(
              'byte-range response size mismatch',
              uri: ref.uri,
            );
          }
          if (bytes.length != spec.length) {
            throw HttpException('byte-range length mismatch', uri: ref.uri);
          }
        } else if (expectedLength != null && bytes.length != expectedLength) {
          throw HttpException(
            'size mismatch (${bytes.length} != $expectedLength)',
            uri: ref.uri,
          );
        }
        return _Downloaded(bytes, contentType, 1);
      } on _HttpStatusException catch (error) {
        if (error.statusCode == HttpStatus.forbidden ||
            error.statusCode == HttpStatus.notFound) {
          rethrow;
        }
        if (_isCancelled(error, epoch)) throw _CancelledException(error);
        lastError = error;
      } on _CancelledException {
        rethrow;
      } catch (error) {
        if (_isCancelled(error, epoch)) throw _CancelledException(error);
        lastError = error;
      }
      if (attempt < maxTries - 1) {
        final delay = _backoff(attempt + 1);
        _log(
          _reqLine(
            'SEG',
            ref.uri,
            status: 'retry',
            retry: attempt + 1,
            detail: 'whole backoff=${delay.inMilliseconds}ms err=$lastError',
          ),
        );
        await Future<void>.delayed(delay);
      }
    }
    throw StateError('分片下载失败: $lastError');
  }

  Future<_HeadInfo?> _head(Uri uri) async {
    final client = _client;
    if (client == null) return null;
    try {
      final request = await client.headUrl(uri).timeout(_connectTimeout);
      request.followRedirects = true;
      request.maxRedirects = 5;
      _applyHeaders(request, accept: '*/*');
      final response = await request.close().timeout(_connectTimeout);
      final status = response.statusCode;
      final length = response.contentLength;
      final acceptRanges = response.headers.value(
        HttpHeaders.acceptRangesHeader,
      );
      final contentType = response.headers.value(HttpHeaders.contentTypeHeader);
      await _drainQuietly(response);
      if (status < 200 || status >= 400 || length <= 0) return null;
      return _HeadInfo(length, acceptRanges, contentType);
    } catch (_) {
      return null;
    }
  }

  Future<_CachedBody> _loadKey(Uri uri) async {
    final cacheKey = 'key:${uri.toString()}';
    final cached = _cacheGet(cacheKey);
    if (cached != null) {
      _cacheHits++;
      return cached;
    }
    _cacheMisses++;
    final pending = _keyInflight[cacheKey];
    if (pending != null) return pending;
    final future = _downloadKey(uri);
    _keyInflight[cacheKey] = future;
    try {
      final body = await future;
      _cachePut(cacheKey, body);
      return body;
    } finally {
      if (identical(_keyInflight[cacheKey], future)) {
        _keyInflight.remove(cacheKey);
      }
    }
  }

  Future<_CachedBody> _downloadKey(Uri uri) async {
    Object? lastError;
    for (var attempt = 0; attempt <= retries; attempt++) {
      final epoch = _clientEpoch;
      try {
        final response = await _get(uri);
        if (response.statusCode < 200 || response.statusCode >= 400) {
          final code = response.statusCode;
          await _drainQuietly(response);
          throw _HttpStatusException(code, uri);
        }
        final bytes = await _readAll(response).timeout(_segmentTimeout);
        return _CachedBody(
          bytes,
          response.headers.value(HttpHeaders.contentTypeHeader),
        );
      } on _CancelledException {
        rethrow;
      } catch (error) {
        if (_isCancelled(error, epoch)) throw _CancelledException(error);
        lastError = error;
      }
      if (attempt < retries) {
        final delay = _backoff(attempt + 1);
        _log(
          _reqLine(
            'KEY',
            uri,
            status: 'retry',
            retry: attempt + 1,
            detail: 'backoff=${delay.inMilliseconds}ms err=$lastError',
          ),
        );
        await Future<void>.delayed(delay);
      }
    }
    throw StateError('密钥下载失败: $lastError');
  }

  // ------------------------------------------------------------- prefetch

  void _primePrefetch(_Playlist playlist) {
    if (playlist.isMaster || playlist.isLive) return;
    if (!_primedPlaylists.add(playlist.key)) return;
    // 打开播放列表就把整集排进预缓冲队列（受 prefetchCount / 缓存预算约束），
    // 不等播放推进：网络好时很快整集落地，之后播放全程只读本地。
    _schedulePrefetch(playlist, 0);
  }

  Future<void> _prefetchFirstVariant(_Playlist master) async {
    if (master.variants.isEmpty) return;
    final generation = _generation;
    try {
      final rewritten = await _loadPlaylist(master.variants.first);
      if (_disposed || generation != _generation) return;
      _activePlaylistKeys.add(rewritten.playlist.key);
      _primePrefetch(rewritten.playlist);
    } catch (error) {
      _log('子播放列表预取失败: $error');
    }
  }

  /// 预缓冲：把 [start] 之后的分片持续排进队列，直到集尾或缓存预算用尽。
  ///
  /// 之前只排 start+prefetchCount 这一批，播完就断了，等于「缓冲 5 个」；
  /// 现在每次分片命中都会再排后续，配合调大的 prefetchCount，
  /// 效果是整集边看边缓存，播放位置走到哪里缓存就跟到哪里。
  void _schedulePrefetch(_Playlist playlist, int start) {
    if (_disposed || prefetchCount <= 0 || playlist.isLive) return;
    // 预缓冲深度按「缓存能装多少」倒推，而不是固定条数：
    // 4K 一集 2.4GB，缓存上限 512MB，若还按 512 条排，前面的会被 LRU
    // 反复淘汰又重下 —— 既卡又费流量。这里按缓存预算的 70% 折算条数，
    // 保证「已预热的不会被自己挤掉」。
    final avgSegBytes = _estimateSegmentBytes(playlist);
    var depth = prefetchCount;
    if (infinitePreload) {
      // 无限预加载：按「缓存装得下多少」全量往前备。
      //
      // 分两种情况：
      //  · 整集装得下（1080P：一集 300~600MB < 缓存上限）→ 整集备齐，
      //    任意位置拖进度都是读本地，这是秒拖的关键。
      //  · 整集装不下（4K：一集 2.4GB > 1~2GB 缓存）→ 硬要全备只会
      //    把前面的挤掉、反复重下。这种就退化为「当前片 + 后续 N 片」，
      //    保证顺序播放不断流；拖到远处时走正常请求（首片会快，
      //    因为 4K 单片本来就 10~20MB，CDN 给得动）。
      if (avgSegBytes > 0 && cacheLimitBytes > 0) {
        final wholeFits = avgSegBytes * playlist.segments.length <= cacheLimitBytes;
        final affordable = (cacheLimitBytes / avgSegBytes).floor();
        depth = math.min(
          prefetchCount,
          math.max(8, wholeFits ? affordable : math.min(affordable, 48)),
        );
      }
    } else {
      if (avgSegBytes > 0 && cacheLimitBytes > 0) {
        final affordable = ((cacheLimitBytes * 0.7) / avgSegBytes).floor();
        depth = math.min(prefetchCount, math.max(8, affordable));
      }
      // 4K 大分片（>6MB/片）不做深度预取：一集 2.4GB 根本缓存不下，
      // 预取只会和正在播的那片抢带宽，反而制造卡顿。
      if (avgSegBytes >= 6 * 1024 * 1024) {
        depth = math.min(depth, 3);
      }
    }
    final end = math.min(playlist.segments.length, start + depth);
    // 预取顺序：紧邻播放位置的「下一片」最先，然后按顺序往后。
    //
    // 对标咕噜的「Rebalanced to deepen protected next preload」——
    // 它把「下一片」当成受保护对象优先拉。顺序播放时下一片必须已经在本地，
    // 否则每次换片都要等一次网络往返，看起来就是「一卡一卡」。
    // 这里把 start 之后的前 3 片插到队首，其余按顺序排在后面。
    final priorityEnd = math.min(end, math.max(0, start) + 3);
    for (var i = math.max(0, start); i < priorityEnd; i++) {
      // 缓存预算：留给正在播放的位置，避免把内存吃满导致整机卡顿。
      // 缓存刹车：留一点余量给正在播的分片和 mpv 自身，不要卡在 85% 就停 ——
      // 85% 会让「整集刚好装得下」的情况永远差最后一段。
      if (cacheLimitBytes > 0 && _cacheBytes >= cacheLimitBytes - 64 * 1024 * 1024) break;
      final segment = playlist.segments[i];
      final alias = _segmentAliases[segment.cacheKey];
      final cacheKey = alias?.cacheKey ?? 'seg:${segment.cacheKey}';
      if (_cache.containsKey(cacheKey) ||
          _prefetchQueued.contains(cacheKey) ||
          _segmentInflight.containsKey(cacheKey)) {
        continue;
      }
      _prefetchQueue.insert(0, _PrefetchTask(segment, _generation, cacheKey));
      _prefetchQueued.add(cacheKey);
    }
    // 其余分片按顺序排在后面
    for (var i = priorityEnd; i < end; i++) {
      if (cacheLimitBytes > 0 && _cacheBytes >= cacheLimitBytes - 64 * 1024 * 1024) break;
      final segment = playlist.segments[i];
      final alias = _segmentAliases[segment.cacheKey];
      final cacheKey = alias?.cacheKey ?? 'seg:${segment.cacheKey}';
      if (_cache.containsKey(cacheKey) ||
          _prefetchQueued.contains(cacheKey) ||
          _segmentInflight.containsKey(cacheKey)) {
        continue;
      }
      _prefetchQueue.add(_PrefetchTask(segment, _generation, cacheKey));
      _prefetchQueued.add(cacheKey);
    }
    _pumpPrefetch();
  }

  /// 估算该播放列表的平均分片字节数：优先用已下载样本，
  /// 其次用 EXTINF × 估算码率。拿不到就返回 0（走默认深度）。
  int _estimateSegmentBytes(_Playlist playlist) {
    final seen = <int>[];
    for (final seg in playlist.segments) {
      final alias = _segmentAliases[seg.cacheKey];
      final key = alias?.cacheKey ?? 'seg:${seg.cacheKey}';
      final entry = _cache[key];
      if (entry != null) seen.add(entry.size);
      if (seen.length >= 6) break;
    }
    if (seen.isNotEmpty) {
      final sum = seen.fold<int>(0, (a, b) => a + b);
      return sum ~/ seen.length;
    }
    return 0;
  }

  /// 播放取片时让路：清掉旧队列（它们基于上一个播放位置，多半已经用不上），
  /// 并记录最近播放位置，供预唤起时判断是否是 seek（跳变就重置）。
  void _yieldPrefetchToPlayback(int index) {
    if (_disposed) return;
    final jumped = _lastPlaybackIndex >= 0 && (index - _lastPlaybackIndex).abs() > 3;
    _lastPlaybackIndex = index;
    _lastPlaybackAt = DateTime.now();
    // 队列里排的是「顺着往下看」的分片；seek 之后大概率全废，直接清掉，
    // 把并发立刻腾给当前请求。非 seek 时保留队列（顺序播放继续预热）。
    if (jumped) {
      _prefetchQueue.clear();
      _prefetchQueued.clear();
      // 关键：把正在下载的预取也停掉。只清队列是不够的 —— 在跑的那几个
      // 仍占着连接和带宽，seek 的分片还得排在它们后面。
      for (final task in _prefetchRunning) {
        task.cancelled = true;
      }
    }
  }

  /// 预取并发按实测带宽动态定：网络快就多开几路把整集早点存完，
  /// 网络一般就少开，避免和播放抢带宽。用户环境差异大，不能写死。
  ///
  /// 无限预加载开启时上限更高（最高 6 路）：目标是在片头几十秒内把整集
  /// 拉到本地，之后任意拖进度都是读本地。播放请求永远优先 ——
  /// `_yieldPrefetchToPlayback` 会在 seek 时把预取全部让位。
  int get _effectivePrefetchConcurrency {
    final speed = recentThroughput;
    final cap = infinitePreload ? 6 : prefetchConcurrency;
    if (speed == null) return math.min(cap, 2);
    final mbps = speed / (1024 * 1024);
    if (mbps >= 8) return math.max(math.min(cap, 4), infinitePreload ? 6 : 4);
    if (mbps >= 3) return math.max(math.min(cap, 3), infinitePreload ? 4 : 3);
    return math.min(cap, 2);
  }

  void _pumpPrefetch() {
    if (_disposed) return;
    // 首帧之前一律不预取：把连接和带宽全部留给「起播要的那几个分片」。
    // 这是 4K 起播速度的关键 —— 之前一拿到播放列表就开 6 路预取，
    // 首片只能排在后面等。
    if (!_firstFrameReady) return;
    final limit = _effectivePrefetchConcurrency;
    while (_prefetchActive < limit && _prefetchQueue.isNotEmpty) {
      final task = _prefetchQueue.removeAt(0);
      _prefetchActive++;
      unawaited(_runPrefetch(task));
    }
  }

  Future<void> _runPrefetch(_PrefetchTask task) async {
    final stopwatch = Stopwatch()..start();
    _prefetchRunning.add(task);
    try {
      if (_disposed || task.cancelled || task.generation != _generation) return;
      // 播放刚请求过片子（最近 500ms 内有活动）：预取让一步，
      // 把连接和带宽优先留给正在播的位置。
      if (DateTime.now().difference(_lastPlaybackAt).inMilliseconds < 500) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        if (_disposed || task.cancelled || task.generation != _generation) {
          return;
        }
      }
      final data = await _loadSegment(task.segment);
      if (task.cancelled) return; // 下载完才发现已 seek：不进缓存也不记日志
      _log(
        '预取完成 ${_short(task.segment.uri)} '
        '${_formatBytes(data.bytes.length)} ${stopwatch.elapsedMilliseconds}ms',
      );
    } catch (error) {
      if (!task.cancelled) {
        _log('预取失败 ${_short(task.segment.uri)}: $error');
      }
    } finally {
      _prefetchRunning.remove(task);
      _prefetchQueued.remove(task.cacheKey);
      _prefetchActive--;
      _pumpPrefetch();
    }
  }

  // ------------------------------------------------------------- refresh

  void _startRefreshTimer() {
    if (playlistRefreshInterval <= Duration.zero) return;
    _refreshTimer?.cancel();
    // 平台线路（临时签名）用更短的间隔提前换地址：签名一般 5 分钟过期，
    // 90 秒一轮太慢，越拖到后面越容易正好跨过过期点导致断流。
    // 普通采集线路没有签名，保持原间隔即可，避免无谓回源。
    // 取 min(配置, 45s)：调用方显式设更短间隔时（测试 / 特例）以配置为准。
    const platformInterval = Duration(seconds: 45);
    final interval = _isPlatformPlaylist &&
            playlistRefreshInterval > platformInterval
        ? platformInterval
        : playlistRefreshInterval;
    _refreshTimer = Timer.periodic(
      interval,
      (_) => unawaited(_refreshActivePlaylists()),
    );
  }

  Future<void> _refreshActivePlaylists() async {
    if (_disposed || _refreshing) return;
    _refreshing = true;
    try {
      // 平台线路的 m3u8 是临时签名：重取同一个 URL 只会拿到同一份过期
      // 内容，必须回调宿主重新走 /api/play 拿新签名地址。
      //
      // 这里是「定期提前刷新」：不等分片 403 再补救。平台签名通常几分钟
      // 就过期，靠 403 触发时 mpv 已经断流并报「加载失败」，恢复也来不及。
      // 每 90 秒主动换一次地址，分片始终指向新鲜签名。
      if (_refreshPlay != null && _isPlatformPlaylist) {
        await _refreshPlatformShared();
        return;
      }
      final keys = List<String>.of(_activePlaylistKeys);
      for (final key in keys) {
        if (_disposed) return;
        final uri = Uri.tryParse(key);
        if (uri == null) continue;
        try {
          await _loadPlaylist(uri, ttl: Duration.zero);
          _log('播放列表定时刷新完成 ${_short(uri)}');
        } catch (error) {
          _log('播放列表定时刷新失败 ${_short(uri)}: $error');
        }
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<bool> _refreshForAlias(_SegmentAlias? alias) async {
    // 遇到 403/404 / 重试退避前先重新调用 /api/play 换新签名；
    // 拿不到再退回重取旧地址。并发分片共享同一次刷新。
    if (_refreshPlay != null && _isPlatformPlaylist) {
      if (await _refreshPlatformShared()) return true;
    }
    if (alias != null) {
      final uri = Uri.tryParse(alias.playlistKey);
      if (uri != null) {
        try {
          await _loadPlaylist(uri, ttl: Duration.zero);
          return true;
        } catch (error) {
          _log('403 后刷新播放列表失败: $error');
          return false;
        }
      }
    }
    // 没有 index 映射时，至少把所有活跃列表刷新一遍再试。
    await _refreshActivePlaylists();
    return _activePlaylistKeys.isNotEmpty;
  }

  /// 并发分片同时要换签名时共享同一次 refreshPlay：只打一次 /api/play，
  /// 避免 seek 突发重试把平台接口打爆，也避免重复累计刷新失败次数
  /// （被取消的请求根本不会走到这里，因此不会误触发 onPlayExpired）。
  Future<bool> _refreshPlatformShared() {
    final existing = _refreshInflight;
    if (existing != null) return existing;
    final future = _refreshPlatformPlaylist();
    _refreshInflight = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_refreshInflight, future)) _refreshInflight = null;
      }),
    );
    return future;
  }

  /// 平台线路（腾讯 / 芒果 / B 站等 CDN）的连续刷新失败次数达到 2 次后，
  /// 通知宿主提示「该平台线路已失效，请切换线路」。
  Future<bool> _refreshPlatformPlaylist() async {
    final refresher = _refreshPlay;
    if (_disposed || refresher == null) return false;
    final generation = _generation;
    final rootKey = _activeRootUri?.toString();
    final deadline = DateTime.now().add(platformRefreshTimeout);
    bool current() => !_disposed && generation == _generation;
    Future<T> bounded<T>(Future<T> operation) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero)
        throw TimeoutException('platform refresh deadline');
      return operation.timeout(remaining);
    }

    try {
      final raw = await bounded(refresher());
      if (!current()) return false;
      final fresh = Uri.tryParse(raw?.trim() ?? '');
      if (fresh == null ||
          !fresh.hasScheme ||
          !(fresh.isScheme('http') || fresh.isScheme('https')) ||
          fresh.host.isEmpty) {
        throw StateError('未取到新的平台播放地址');
      }
      final rootUri = rootKey == null ? null : Uri.tryParse(rootKey);
      if (rootKey == null || rootUri == null) {
        throw StateError('没有可刷新的播放列表');
      }
      // Stage the entire loaded playlist tree before publishing any override.
      // A master reload alone cannot renew the player's existing child aliases.
      final staged = <String, _RewrittenPlaylist>{};
      final overrides = <String, Uri>{};
      await bounded(
        _stagePlatformRefresh(
          rootKey,
          fresh,
          staged,
          overrides,
          <String>{},
          deadline,
          generation,
        ),
      );
      if (!current() || DateTime.now().isAfter(deadline)) return false;
      _sourceOverrides.addAll(overrides);
      for (final rewritten in staged.values) {
        _storePlaylist(rewritten);
      }
      _platformRefreshFails = 0;
      _platformExpiredNotified = false;
      _log('平台线路签名已刷新 ${_short(fresh)}');
      return true;
    } catch (error) {
      if (!current()) return false;
      _platformRefreshFails++;
      _log('平台线路签名刷新失败（第 $_platformRefreshFails 次）: $error');
      if (_platformRefreshFails >= 2 && !_platformExpiredNotified) {
        _platformExpiredNotified = true;
        _log('平台线路已失效，通知宿主提示切换线路');
        try {
          _onPlayExpired?.call();
        } catch (_) {
          // 宿主回调异常不能影响代理本身的清理。
        }
      }
      return false;
    }
  }

  String _playlistIdentity(Uri uri) {
    const signingFields = <String>{
      'sign',
      'signature',
      'expire',
      'expires',
      'deadline',
      'token',
      'auth_key',
      'wstime',
      'wssecret',
    };
    final names =
        uri.queryParametersAll.keys
            .where((key) => !signingFields.contains(key.toLowerCase()))
            .toList()
          ..sort();
    final query = <String, dynamic>{
      for (final name in names) name: uri.queryParametersAll[name],
    };
    return uri.replace(queryParameters: query, fragment: '').toString();
  }

  Future<void> _stagePlatformRefresh(
    String key,
    Uri fresh,
    Map<String, _RewrittenPlaylist> staged,
    Map<String, Uri> overrides,
    Set<String> visiting,
    DateTime deadline,
    int generation,
  ) async {
    void guard() {
      if (_disposed ||
          generation != _generation ||
          !DateTime.now().isBefore(deadline)) {
        throw StateError('platform refresh cancelled or deadline exceeded');
      }
    }

    guard();
    if (visiting.contains(key)) {
      throw StateError('unsupported playlist refresh: cyclic child tree');
    }
    if (staged.containsKey(key)) {
      if (overrides[key] != fresh)
        throw StateError('conflicting shared playlist');
      return;
    }
    if (staged.length >= 64 || visiting.length >= 8) {
      throw StateError('unsupported playlist refresh: tree limit exceeded');
    }
    visiting.add(key);
    final previous = _playlistCache[key]?.value.playlist;
    final fetched = await _fetchPlaylistText(
      fresh,
    ).timeout(deadline.difference(DateTime.now()));
    guard();
    final rewritten = _rewritePlaylist(
      fetched.text,
      fetched.finalUri,
      playlistKey: key,
      preserveChildKeys: false,
    );
    final next = rewritten.playlist;
    if (previous != null) {
      if (previous.isMaster != next.isMaster ||
          previous.isLive != next.isLive) {
        throw StateError('unsupported playlist refresh: changed playlist type');
      }
      String encryptionMetadata(_Playlist playlist) => playlist.timeline
          .split('\n')
          .where(
            (line) =>
                line.startsWith('#EXT-X-KEY:') ||
                line.startsWith('#EXT-X-SESSION-KEY:') ||
                line.startsWith('#EXT-X-MAP:'),
          )
          .join('\n');
      if (encryptionMetadata(previous) != encryptionMetadata(next)) {
        throw StateError(
          'unsupported playlist refresh: changed key or map metadata',
        );
      }
      if (!next.isMaster &&
          !next.isLive &&
          (previous.segments.length != next.segments.length ||
              previous.timeline != next.timeline)) {
        throw StateError(
          'unsupported playlist refresh: changed media timeline',
        );
      }
    }
    staged[key] = rewritten;
    overrides[key] = fresh;
    if (previous == null || !next.isMaster) {
      visiting.remove(key);
      return;
    }
    final oldChildren = <String, List<Uri>>{};
    final newChildren = <String, List<Uri>>{};
    for (final uri in previous.variants.toSet()) {
      // Logical children can already have a refreshed actual URI.
      final actual = _sourceOverrides[uri.toString()] ?? uri;
      oldChildren.putIfAbsent(_playlistIdentity(actual), () => []).add(uri);
    }
    for (final uri in next.variants.toSet()) {
      newChildren.putIfAbsent(_playlistIdentity(uri), () => []).add(uri);
    }
    var body = utf8.decode(rewritten.body);
    final stableChildren = <String, Uri>{};
    for (final entry in oldChildren.entries) {
      final matches = newChildren[entry.key];
      if (entry.value.length != 1 || matches == null || matches.length != 1) {
        throw StateError(
          'unsupported master refresh: ambiguous or changed child identity',
        );
      }
      final oldChild = entry.value.single;
      final newChild = matches.single;
      final priorOverride = overrides[oldChild.toString()];
      if (priorOverride != null && priorOverride != newChild) {
        throw StateError('conflicting shared playlist');
      }
      overrides[oldChild.toString()] = newChild;
      stableChildren[newChild.toString()] = oldChild;
      body = body.replaceAll(
        _localUrl('/playlist', newChild),
        _localUrl('/playlist', oldChild),
      );
      if (_playlistCache.containsKey(oldChild.toString())) {
        await _stagePlatformRefresh(
          oldChild.toString(),
          newChild,
          staged,
          overrides,
          visiting,
          deadline,
          generation,
        );
      }
    }
    visiting.remove(key);
    staged[key] = _RewrittenPlaylist(
      Uint8List.fromList(utf8.encode(body)),
      _Playlist(
        key: next.key,
        base: next.base,
        isMaster: next.isMaster,
        isLive: next.isLive,
        segments: next.segments,
        variants: next.variants
            .map((uri) => stableChildren[uri.toString()] ?? uri)
            .toList(),
        timeline: next.timeline,
      ),
    );
  }

  /// 当前播放列表是否属于平台 CDN（临时签名，必须重新走 /api/play）。
  bool get _isPlatformPlaylist {
    final uri = _activeRootUri;
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return false;
    // Server-hosted platform wrappers retain the API host, not the CDN host.
    // Re-fetching these stable endpoints alone may reuse resolved signed URLs;
    // when a refresher is available, renew through /api/play first.
    final isPlatformWrapper =
        uri.path == '/api/iqiyi.m3u8' || uri.path == '/api/fyplay';
    return isPlatformWrapper ||
        host == 'iqiyi.com' ||
        host.endsWith('.iqiyi.com') ||
        host == 'iqiyipic.com' ||
        host.endsWith('.iqiyipic.com') ||
        host == 'qiyipic.com' ||
        host.endsWith('.qiyipic.com') ||
        host == 'qq.com' ||
        host.endsWith('.qq.com') ||
        host.contains('mgtv') ||
        host.endsWith('mgtv.com') ||
        host.contains('bilivideo') ||
        host.endsWith('hdslb.com') ||
        host.endsWith('bilibili.com') ||
        host.contains('renren');
  }

  _SegmentRef? _latestSegment(_SegmentAlias? alias) {
    if (alias == null) return null;
    final playlist = _playlistCache[alias.playlistKey]?.value.playlist;
    if (playlist == null ||
        playlist.isMaster ||
        playlist.isLive ||
        alias.index >= playlist.segments.length) {
      return null;
    }
    return playlist.segments[alias.index];
  }

  void _trimAliases() {
    while (_segmentAliases.length > _maxAliases) {
      _segmentAliases.remove(_segmentAliases.keys.first);
    }
  }

  // -------------------------------------------------------------- network

  Future<HttpClientResponse> _get(
    Uri uri, {
    String? range,
    String accept = '*/*',
    Duration timeout = _segmentTimeout,
  }) async {
    final client = _client;
    if (client == null) throw StateError('本地代理未启动');
    final request = await client.getUrl(uri).timeout(_connectTimeout);
    request.followRedirects = true;
    request.maxRedirects = 5;
    _applyHeaders(request, range: range, accept: accept);
    return request.close().timeout(timeout);
  }

  void _applyHeaders(
    HttpClientRequest request, {
    String? range,
    String accept = '*/*',
  }) {
    for (final entry in _headers.entries) {
      final name = entry.key.toLowerCase();
      if (name == 'range' ||
          name == 'accept-encoding' ||
          name == 'host' ||
          name == 'content-length' ||
          name == 'connection') {
        continue;
      }
      request.headers.set(entry.key, entry.value);
    }
    if (request.headers.value(HttpHeaders.userAgentHeader) == null) {
      request.headers.set(HttpHeaders.userAgentHeader, _defaultUserAgent);
    }
    request.headers.set(HttpHeaders.acceptHeader, accept);
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (range != null) {
      request.headers.set(HttpHeaders.rangeHeader, range);
    }
  }

  Future<Uint8List> _readAll(HttpClientResponse response) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<void> _drainQuietly(HttpClientResponse response) async {
    try {
      await response.drain<void>().timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  // --------------------------------------------------------------- helpers

  void _clearCaches() {
    // 落盘的缓存文件一并清掉，避免切集后残留占满存储。
    for (final entry in _cache.values) {
      unawaited(_deleteCacheFile(entry));
    }
    _cache.clear();
    _cacheBytes = 0;
    _segmentInflight.clear();
    _keyInflight.clear();
  }

  _CachedBody? _cacheGet(String key) {
    final entry = _cache.remove(key);
    if (entry == null) return null;
    // 重新插到队尾，LinkedHashMap 头部即最久未使用。
    _cache[key] = entry;
    return entry;
  }

  /// 写入缓存。超过 [spillToDiskBytes] 的分片落盘，内存里只留文件引用：
  /// 整集预缓冲会有几百个分片（300~600MB），全放内存会撑爆手机，
  /// 落盘后播放读的是本地文件，上游抖动 / 签名过期都不再影响播放。
  void _cachePut(String key, _CachedBody body) {
    if (_disposed || cacheLimitBytes <= 0) return;
    if (body.file == null && body.bytes.isEmpty) return;
    final size = body.file != null ? body.size : body.bytes.length;
    if (size > cacheLimitBytes) return;
    final old = _cache.remove(key);
    if (old != null) {
      _cacheBytes -= old.size;
      unawaited(_deleteCacheFile(old));
    }
    // 大分片落盘；写盘失败就退回内存（内存预算不够时这条不进缓存）。
    var entry = body;
    if (body.file == null && body.bytes.length >= spillToDiskBytes) {
      final spooled = _spillToDiskSync(key, body);
      if (spooled != null) entry = spooled;
    }
    if (entry.file == null &&
        _cacheBytes + entry.bytes.length > cacheLimitBytes) {
      // 内存已达上限且无法落盘：放弃缓存这一片，不影响播放。
      return;
    }
    _cache[key] = entry;
    _cacheBytes += entry.size;
    while (_cacheBytes > cacheLimitBytes && _cache.isNotEmpty) {
      final oldestKey = _cache.keys.first;
      final removed = _cache.remove(oldestKey);
      if (removed != null) {
        _cacheBytes -= removed.size;
        unawaited(_deleteCacheFile(removed));
      }
    }
  }

  /// 大分片落盘。用同步写避免并发写入时把播放线程拖出太多 async 缝隙；
  /// 写入失败返回 null，调用方退回内存缓存。
  _CachedBody? _spillToDiskSync(String key, _CachedBody body) {
    var dir = _spoolDir;
    if (dir == null) {
      final temp = _tempDir;
      if (temp == null) return null;
      try {
        dir = Directory('${temp.path}/spool');
        if (!dir.existsSync()) dir.createSync(recursive: true);
        _spoolDir = dir;
      } catch (_) {
        return null;
      }
    }
    try {
      final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
      final file = File('${dir.path}/$safe.bin');
      file.writeAsBytesSync(body.bytes, flush: false);
      return _CachedBody(Uint8List(0), body.contentType, file: file);
    } catch (_) {
      return null;
    }
  }

  Future<void> _deleteCacheFile(_CachedBody body) async {
    final f = body.file;
    if (f == null) return;
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 清理失败不影响播放，下次启动会随临时目录一起清掉。
    }
  }

  void _resetClient() {
    // 旧 client 上还没跑完的请求全部作废：它们的失败按 cancelled 记，
    // 不算这条流的失败，也不会触发 refreshPlay / onPlayExpired。
    _clientEpoch++;
    final old = _client;
    _client = _newClient();
    old?.close(force: true);
  }

  Map<String, String> _normalizeHeaders(Map<String, String> headers) {
    final clean = <String, String>{};
    for (final entry in headers.entries) {
      if (entry.key.trim().isEmpty || entry.value.trim().isEmpty) continue;
      if (entry.key.toLowerCase() == 'range') continue;
      clean[entry.key] = entry.value;
    }
    return clean;
  }

  Uri? _queryUri(HttpRequest request, String name) {
    final raw = request.uri.queryParameters[name];
    if (raw == null || raw.isEmpty) return null;
    final decoded = _decodeUrl(raw);
    if (decoded == null) return null;
    final uri = Uri.tryParse(decoded);
    if (uri == null ||
        !uri.hasScheme ||
        !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }
    return uri;
  }

  static String _encodeUrl(String url) =>
      base64Url.encode(utf8.encode(url)).replaceAll('=', '');

  static String? _decodeUrl(String value) {
    try {
      final padding = (4 - value.length % 4) % 4;
      return utf8.decode(base64Url.decode(value + '=' * padding));
    } catch (_) {
      return null;
    }
  }

  static Uri? _resolve(Uri base, String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    try {
      return base.resolveUri(Uri.parse(value));
    } catch (_) {
      return null;
    }
  }

  static Uri _finalUri(Uri original, List<RedirectInfo> redirects) {
    var uri = original;
    for (final redirect in redirects) {
      uri = uri.resolveUri(redirect.location);
    }
    return uri;
  }

  static _RangeSpec? _parseByteRange(String value) {
    final match = RegExp(r'^(\d+)(?:@(\d+))?$').firstMatch(value.trim());
    if (match == null) return null;
    final length = int.tryParse(match.group(1)!);
    if (length == null || length <= 0) return null;
    final start = match.group(2) == null ? null : int.tryParse(match.group(2)!);
    return _RangeSpec(start, length);
  }

  static _RangeSpec? _parseRangeParam(String? value) {
    if (value == null || value.isEmpty) return null;
    final match = RegExp(r'^(\d+)-(\d+)$').firstMatch(value.trim());
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    final length = int.tryParse(match.group(2)!);
    if (start == null || length == null || start < 0 || length <= 0) {
      return null;
    }
    return _RangeSpec(start, length);
  }

  static _ContentRange? _parseContentRange(String? value) {
    if (value == null) return null;
    final match = RegExp(
      r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    final total = int.tryParse(match.group(3)!);
    if (start == null) return null;
    return _ContentRange(start, total);
  }

  static _HttpRange? _parseHttpRange(String value, int total) {
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value.trim());
    if (match == null) return null;
    final startRaw = match.group(1)!;
    final endRaw = match.group(2)!;
    if (startRaw.isEmpty && endRaw.isEmpty) return null;
    if (startRaw.isEmpty) {
      final suffix = int.tryParse(endRaw);
      if (suffix == null || suffix <= 0) return _HttpRange(total, 0);
      final start = math.max(0, total - suffix);
      return _HttpRange(start, total - start);
    }
    final start = int.tryParse(startRaw);
    if (start == null || start >= total) return _HttpRange(total, 0);
    var end = endRaw.isEmpty ? total - 1 : int.tryParse(endRaw) ?? total - 1;
    if (end >= total) end = total - 1;
    if (end < start) return _HttpRange(total, 0);
    return _HttpRange(start, end - start + 1);
  }

  static bool _supportsRanges(String? acceptRanges) {
    if (acceptRanges == null || acceptRanges.trim().isEmpty) return true;
    return acceptRanges.toLowerCase().contains('bytes');
  }

  static String _segmentContentType(Uri source, String? origin) {
    final value = origin?.split(';').first.trim() ?? '';
    final lower = value.toLowerCase();
    if (lower.isNotEmpty &&
        lower != 'application/octet-stream' &&
        lower != 'binary/octet-stream') {
      return value;
    }
    final path = source.path.toLowerCase();
    if (path.endsWith('.m4s') ||
        path.endsWith('.mp4') ||
        path.endsWith('.m4v')) {
      return 'video/mp4';
    }
    if (path.endsWith('.aac')) return 'audio/aac';
    if (path.endsWith('.m4a')) return 'audio/mp4';
    return 'video/mp2t';
  }

  static String _short(Uri uri) {
    final value = uri.toString();
    if (value.length <= 140) return value;
    return '${value.substring(0, 137)}...';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
}

class _CachedBody {
  const _CachedBody(this.bytes, this.contentType, {this.file});

  /// 内存中的字节；落盘后为空，改用 [file] 读回。
  final Uint8List bytes;
  final String? contentType;

  /// 落盘后的分片文件。整集预缓冲会把几百个分片写到磁盘，
  /// 全放内存会撑爆手机（一集 300~600MB），因此超过阈值的分片改存盘。
  final File? file;

  int get size => file != null ? file!.lengthSync() : bytes.length;

  Future<Uint8List> readBytes() async {
    final f = file;
    if (f != null) return await f.readAsBytes();
    return bytes;
  }
}

class _CachedPlaylist {
  const _CachedPlaylist(this.value, this.at);

  final _RewrittenPlaylist value;
  final DateTime at;
}

class _RewrittenPlaylist {
  const _RewrittenPlaylist(this.body, this.playlist);

  final Uint8List body;
  final _Playlist playlist;
}

class _Playlist {
  const _Playlist({
    required this.key,
    required this.base,
    required this.isMaster,
    required this.isLive,
    required this.segments,
    required this.variants,
    required this.timeline,
  });

  final String key;
  final Uri base;
  final bool isMaster;
  final bool isLive;
  final List<_SegmentRef> segments;
  final List<Uri> variants;
  final String timeline;
}

class _SegmentRef {
  const _SegmentRef(this.uri, this.range);

  final Uri uri;
  final _RangeSpec? range;

  String get cacheKey => range == null
      ? 'url:${uri.toString()}'
      : 'url:${uri.toString()}#${range!.start}+${range!.length}';
}

class _RangeSpec {
  const _RangeSpec(this.start, this.length);

  /// 为 null 表示 HLS 里没写 offset（紧接上一个 byterange）。
  final int? start;
  final int length;

  int get effectiveStart => start ?? 0;

  int get end => effectiveStart + length - 1;
}

class _SegmentAlias {
  const _SegmentAlias({
    required this.playlistKey,
    required this.index,
    required this.cacheKey,
  });

  final String playlistKey;
  final int index;

  /// 播放列表刷新后仍稳定的逻辑缓存 key（只用于 VOD）。
  final String cacheKey;
}

class _PrefetchTask {
  _PrefetchTask(this.segment, this.generation, this.cacheKey);

  final _SegmentRef segment;
  final int generation;
  final String cacheKey;

  /// seek 时把在跑的预取标废：它在下一次 await 后自行退出，
  /// 并立刻释放连接给正在播的分片。腾讯能做到「怎么拖都秒播」，
  /// 靠的就是拖动瞬间把非目标请求全部让路。
  bool cancelled = false;
}

class _SegmentData {
  const _SegmentData(
    this.bytes,
    this.contentType,
    this.parallelCount,
    this.elapsed,
    this.cacheHit, {
    this.retryCount = 0,
  });

  final Uint8List bytes;
  final String? contentType;
  final int parallelCount;
  final Duration elapsed;
  final bool cacheHit;

  /// 拿到这份数据前重试过几次（0 = 一次成功），写进 proxy.log。
  final int retryCount;

  int get elapsedMs => elapsed.inMilliseconds;
}

class _Downloaded {
  const _Downloaded(this.bytes, this.contentType, this.parallelCount);

  final Uint8List bytes;
  final String? contentType;
  final int parallelCount;
}

class _RangeFetch {
  const _RangeFetch(
    this.bytes,
    this.statusCode,
    this.contentType,
    this.totalLength,
  );

  final Uint8List bytes;
  final int statusCode;
  final String? contentType;
  final int? totalLength;
}

class _HeadInfo {
  const _HeadInfo(this.contentLength, this.acceptRanges, this.contentType);

  final int contentLength;
  final String? acceptRanges;
  final String? contentType;
}

class _FetchedPlaylist {
  const _FetchedPlaylist(this.text, this.finalUri);

  final String text;
  final Uri finalUri;
}

class _ContentRange {
  const _ContentRange(this.start, this.total);

  final int start;
  final int? total;
}

class _HttpRange {
  const _HttpRange(this.start, this.length);

  final int start;
  final int length;
}

class _SpoolPart {
  const _SpoolPart(this.file, this.length, this.contentType);

  final File file;
  final int length;
  final String? contentType;
}

class _HttpStatusException implements Exception {
  const _HttpStatusException(this.statusCode, this.uri);

  final int statusCode;
  final Uri uri;

  @override
  String toString() => 'HTTP $statusCode ($uri)';
}

/// 「请求被取消」：切集 / 释放重建了 HttpClient，或播放器主动放弃。
/// 这类不算这条流的失败，不计并发降级、不触发 refreshPlay / onPlayExpired。
class _CancelledException implements Exception {
  const _CancelledException(this.cause);

  final Object cause;

  @override
  String toString() => 'cancelled: $cause';
}

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// 代理日志回调；默认写到 dart:developer（Flutter 控制台 / logcat 可见）。
typedef HlsProxyLogger = void Function(String message);

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
/// - 分片返回 403 / 404 时立即刷新 playlist 并重试一次，实现自愈。
class LocalHlsProxy {
  LocalHlsProxy({
    this.parallelism = 8,
    this.prefetchCount = 5,
    this.prefetchConcurrency = 3,
    this.cacheLimitBytes = 256 * 1024 * 1024,
    this.retries = 2,
    this.retryDelay = const Duration(milliseconds: 300),
    this.playlistRefreshInterval = const Duration(seconds: 90),
    this.spoolThresholdBytes = 8 * 1024 * 1024,
    HlsProxyLogger? log,
  })  : assert(parallelism > 0),
        assert(prefetchCount >= 0),
        assert(prefetchConcurrency > 0),
        assert(cacheLimitBytes >= 0),
        assert(retries >= 0),
        assert(!playlistRefreshInterval.isNegative),
        _logger = log ?? _defaultLog;

  static const Duration _connectTimeout = Duration(seconds: 8);
  static const Duration _playlistTimeout = Duration(seconds: 12);
  static const Duration _segmentTimeout = Duration(seconds: 60);
  static const Duration _playlistTtl = Duration(seconds: 3);
  static const int _minParallelBytes = 128 * 1024;
  static const int _minChunkBytes = 128 * 1024;
  static const int _maxPlaylistBytes = 8 * 1024 * 1024;
  static const int _maxAliases = 50000;
  static const String _defaultUserAgent = 'Mozilla/5.0';

  /// 单个分片并行 Range 的条数（默认 8）。
  final int parallelism;

  /// 播放列表就绪后向前预取的分片数（默认 5）。
  final int prefetchCount;

  /// 预取同时进行的下载数（默认 3）。
  final int prefetchConcurrency;

  /// 内存 LRU 缓存上限（默认 256MB）。
  final int cacheLimitBytes;

  /// 单段下载失败重试次数（默认 2）。
  final int retries;

  /// 重试退避基数（默认 300ms，按次数线性增长）。
  final Duration retryDelay;

  /// 定期重取 playlist 的间隔，默认 90 秒；传 [Duration.zero] 关闭。
  final Duration playlistRefreshInterval;

  /// 超过该大小的分片，并发下载时用临时文件拼装（默认 8MB）。
  final int spoolThresholdBytes;

  final HlsProxyLogger _logger;

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
  Timer? _refreshTimer;
  Future<void>? _starting;
  Map<String, String> _headers = const <String, String>{};
  String? _activePlaylistUrl;
  int _cacheBytes = 0;
  int _cacheHits = 0;
  int _cacheMisses = 0;
  int _prefetchActive = 0;
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

  /// 当前缓存条目数。
  int get cacheEntryCount => _cache.length;

  /// 临时目录路径（仅用于测试 / 诊断）。
  String? get tempDirPath => _tempDir?.path;

  static void _defaultLog(String message) {
    developer.log(message, name: 'LocalHlsProxy');
  }

  void _log(String message) {
    try {
      _logger('[HLS] $message');
    } catch (_) {
      // 日志失败不影响播放。
    }
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
      ..maxConnectionsPerHost = math.max(parallelism * 2, 16);
  }

  /// 关闭本地服务、取消预取与定时刷新、清空内存缓存和临时文件。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
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
    Map<String, String> headers,
  ) async {
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
    _refreshTimer?.cancel();
    _refreshTimer = null;

    _headers = _normalizeHeaders(headers);
    final sourceKey = uri.toString();
    if (_activePlaylistUrl != null && _activePlaylistUrl != sourceKey) {
      // 换集时清掉上一集的缓存与映射，避免 256MB 被旧集占满。
      _clearCaches();
      _playlistCache.clear();
      _segmentAliases.clear();
      _activePlaylistKeys.clear();
      _primedPlaylists.clear();
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
            request, HttpStatus.methodNotAllowed, 'method not allowed');
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
      _log('本地请求失败 ${request.uri.path}: $error');
      await _writeText(request, HttpStatus.badGateway, 'proxy error: $error');
    }
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

    // 先把接下来 5 个分片排进预取队列（当前分片可能还在下载）。
    if (alias != null) {
      final playlist = _playlistCache[alias.playlistKey]?.value.playlist;
      if (playlist != null) _schedulePrefetch(playlist, alias.index + 1);
    }

    final stopwatch = Stopwatch()..start();
    _SegmentData data;
    try {
      data = await _loadSegment(ref);
    } catch (error) {
      _log(
        '分片失败 ${index == null ? '' : '#$index '}'
        '${_short(source)}: $error',
      );
      await _writeText(request, HttpStatus.badGateway, 'segment error: $error');
      return;
    }

    final cacheText = data.cacheHit ? '命中缓存' : '未命中缓存';
    _log(
      '分片${index == null ? '' : ' #$index'}：'
      '${data.cacheHit ? '命中缓存' : '并行下载 ${data.parallelCount} 段'}，'
      '耗时 ${data.cacheHit ? stopwatch.elapsedMilliseconds : data.elapsedMs}ms，'
      '$cacheText，大小 ${_formatBytes(data.bytes.length)}',
    );

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
        contentRange = 'bytes ${requested.start}-'
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
      _log('密钥获取失败 ${_short(source)}: $error');
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
    final fetched = await _fetchPlaylistText(uri);
    final rewritten = _rewritePlaylist(
      fetched.text,
      fetched.finalUri,
      playlistKey: uri.toString(),
    );
    _playlistCache[uri.toString()] = _CachedPlaylist(
      rewritten,
      DateTime.now(),
    );
    final playlist = rewritten.playlist;
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
    return rewritten;
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
  }) {
    final isMaster = text.contains('#EXT-X-STREAM-INF') ||
        text.contains('#EXT-X-I-FRAME-STREAM-INF') ||
        text.contains('#EXT-X-MEDIA:');
    // ENDLIST / PLAYLIST-TYPE:VOD 都表示点播；否则按直播处理，不做
    // 跨刷新的 index 映射（直播窗口会滑动，index 对应的内容会变）。
    final isLive = !text.contains('#EXT-X-ENDLIST') &&
        !text.contains('#EXT-X-PLAYLIST-TYPE:VOD');
    final lines = const LineSplitter().convert(text);
    final out = <String>[];
    final segments = <_SegmentRef>[];
    final variants = <Uri>[];
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
        final spec =
            _parseByteRange(line.substring('#EXT-X-BYTERANGE:'.length));
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
          _rewriteUriAttribute(
            line,
            base,
            (uri) => _localUrl('/key', uri),
          ),
        );
        continue;
      }
      if (line.startsWith('#EXT-X-MAP:')) {
        out.add(
          _rewriteUriAttribute(
            line,
            base,
            (uri) => _localUrl('/seg', uri),
          ),
        );
        continue;
      }
      if (line.startsWith('#EXT-X-MEDIA:') ||
          line.startsWith('#EXT-X-I-FRAME-STREAM-INF:')) {
        out.add(
          _rewriteUriAttribute(
            line,
            base,
            (uri) => _localUrl('/playlist', uri),
          ),
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
            return _localUrl(
              '/seg',
              uri,
              index: segmentIndex++,
              range: range,
            );
          }),
        );
        continue;
      }
      if (line.startsWith('#EXT-X-PRELOAD-HINT:')) {
        out.add(
          _rewriteUriAttribute(
            line,
            base,
            (uri) => _localUrl('/seg', uri),
          ),
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
        variants.add(uri);
        out.add(_localUrl('/playlist', uri));
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
      out.add(
        _localUrl(
          '/seg',
          uri,
          index: segmentIndex++,
          range: range,
        ),
      );
    }

    final playlist = _Playlist(
      key: playlistKey,
      base: base,
      isMaster: isMaster,
      isLive: isLive,
      segments: segments,
      variants: variants,
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

  String _localUrl(
    String path,
    Uri source, {
    int? index,
    _RangeSpec? range,
  }) {
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
      return _SegmentData(
        cached.bytes,
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

  Future<_SegmentData> _downloadSegmentWithRefresh(
    _SegmentRef ref,
    _SegmentAlias? alias,
  ) async {
    var target = _latestSegment(alias) ?? ref;
    try {
      return await _downloadSegment(target);
    } on _HttpStatusException catch (error) {
      if (error.statusCode != HttpStatus.forbidden &&
          error.statusCode != HttpStatus.notFound) {
        rethrow;
      }
      // 签名过期：立即重取 playlist，用同位置的新地址再试一次。
      final refreshed = await _refreshForAlias(alias);
      if (!refreshed) rethrow;
      target = _latestSegment(alias) ?? target;
      _log('分片 ${_short(ref.uri)} 返回 ${error.statusCode}，'
          '已刷新列表并重试新地址');
      return _downloadSegment(target);
    }
  }

  Future<_SegmentData> _downloadSegment(_SegmentRef ref) async {
    final stopwatch = Stopwatch()..start();
    final _Downloaded downloaded;
    if (ref.range != null) {
      downloaded = await _downloadWhole(ref, expectedLength: ref.range!.length);
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
            await _downloadWhole(ref, expectedLength: length),
            stopwatch,
          );
        } catch (error) {
          _log('并行下载失败回退单连接 ${_short(ref.uri)}: $error');
          return _finishDownload(
            ref,
            await _downloadWhole(ref, expectedLength: length),
            stopwatch,
          );
        }
      } else {
        downloaded = await _downloadWhole(ref, expectedLength: length);
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
    final count = math.min(
      parallelism,
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
      throw HttpException('parallel size mismatch ($offset != $length)',
          uri: ref.uri);
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

  Future<_RangeFetch> _fetchRangeWithRetry(
    Uri uri,
    int start,
    int end,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        return await _fetchRange(uri, start, end);
      } on _HttpStatusException catch (error) {
        if (error.statusCode == HttpStatus.forbidden ||
            error.statusCode == HttpStatus.notFound) {
          rethrow; // 403/404 交给上层刷新 playlist，不做无意义重试。
        }
        lastError = error;
      } catch (error) {
        lastError = error;
      }
      if (attempt < retries) {
        await Future<void>.delayed(
          Duration(
            milliseconds: retryDelay.inMilliseconds * (attempt + 1),
          ),
        );
      }
    }
    throw StateError('Range $start-$end 下载失败: $lastError');
  }

  Future<_RangeFetch> _fetchRange(Uri uri, int start, int end) async {
    final response = await _get(
      uri,
      range: 'bytes=$start-$end',
    );
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
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        final response = await _get(
          ref.uri,
          range: ref.range == null
              ? null
              : 'bytes=${ref.range!.effectiveStart}-${ref.range!.end}',
        );
        final status = response.statusCode;
        final contentType =
            response.headers.value(HttpHeaders.contentTypeHeader);
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
            bytes = Uint8List.sublistView(
              raw,
              start,
              start + spec.length,
            );
          } else if (status == HttpStatus.ok && raw.length != spec.length) {
            throw HttpException('byte-range response size mismatch',
                uri: ref.uri);
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
        lastError = error;
      } catch (error) {
        lastError = error;
      }
      if (attempt < retries) {
        await Future<void>.delayed(
          Duration(
            milliseconds: retryDelay.inMilliseconds * (attempt + 1),
          ),
        );
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
      final acceptRanges =
          response.headers.value(HttpHeaders.acceptRangesHeader);
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
      } catch (error) {
        lastError = error;
      }
      if (attempt < retries) {
        await Future<void>.delayed(
          Duration(
            milliseconds: retryDelay.inMilliseconds * (attempt + 1),
          ),
        );
      }
    }
    throw StateError('密钥下载失败: $lastError');
  }

  // ------------------------------------------------------------- prefetch

  void _primePrefetch(_Playlist playlist) {
    if (playlist.isMaster || playlist.isLive) return;
    if (!_primedPlaylists.add(playlist.key)) return;
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

  void _schedulePrefetch(_Playlist playlist, int start) {
    if (_disposed || prefetchCount <= 0 || playlist.isLive) return;
    final end = math.min(playlist.segments.length, start + prefetchCount);
    for (var i = math.max(0, start); i < end; i++) {
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

  void _pumpPrefetch() {
    if (_disposed) return;
    while (_prefetchActive < prefetchConcurrency && _prefetchQueue.isNotEmpty) {
      final task = _prefetchQueue.removeAt(0);
      _prefetchActive++;
      unawaited(_runPrefetch(task));
    }
  }

  Future<void> _runPrefetch(_PrefetchTask task) async {
    final stopwatch = Stopwatch()..start();
    try {
      if (_disposed || task.generation != _generation) return;
      final data = await _loadSegment(task.segment);
      _log(
        '预取完成 ${_short(task.segment.uri)} '
        '${_formatBytes(data.bytes.length)} ${stopwatch.elapsedMilliseconds}ms',
      );
    } catch (error) {
      _log('预取失败 ${_short(task.segment.uri)}: $error');
    } finally {
      _prefetchQueued.remove(task.cacheKey);
      _prefetchActive--;
      _pumpPrefetch();
    }
  }

  // ------------------------------------------------------------- refresh

  void _startRefreshTimer() {
    if (playlistRefreshInterval <= Duration.zero) return;
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(
      playlistRefreshInterval,
      (_) => unawaited(_refreshActivePlaylists()),
    );
  }

  Future<void> _refreshActivePlaylists() async {
    if (_disposed || _refreshing) return;
    _refreshing = true;
    try {
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

  void _cachePut(String key, _CachedBody body) {
    if (_disposed || cacheLimitBytes <= 0 || body.bytes.isEmpty) return;
    if (body.bytes.length > cacheLimitBytes) return;
    final old = _cache.remove(key);
    if (old != null) _cacheBytes -= old.bytes.length;
    _cache[key] = body;
    _cacheBytes += body.bytes.length;
    while (_cacheBytes > cacheLimitBytes && _cache.isNotEmpty) {
      final oldestKey = _cache.keys.first;
      final removed = _cache.remove(oldestKey);
      if (removed != null) _cacheBytes -= removed.bytes.length;
    }
  }

  void _resetClient() {
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
      return utf8.decode(
        base64Url.decode(value + '=' * padding),
      );
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
    final match =
        RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+|\*)$').firstMatch(value.trim());
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
  const _CachedBody(this.bytes, this.contentType);

  final Uint8List bytes;
  final String? contentType;
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
  });

  final String key;
  final Uri base;
  final bool isMaster;
  final bool isLive;
  final List<_SegmentRef> segments;
  final List<Uri> variants;
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
  const _PrefetchTask(this.segment, this.generation, this.cacheKey);

  final _SegmentRef segment;
  final int generation;
  final String cacheKey;
}

class _SegmentData {
  const _SegmentData(
    this.bytes,
    this.contentType,
    this.parallelCount,
    this.elapsed,
    this.cacheHit,
  );

  final Uint8List bytes;
  final String? contentType;
  final int parallelCount;
  final Duration elapsed;
  final bool cacheHit;

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

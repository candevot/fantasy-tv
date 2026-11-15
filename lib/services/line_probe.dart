/// 线路健康预检（PROBE 2026-11-15，用户口径）。
///
/// 「该不该切下一条」必须分得清**线路坏了**和**网慢**，所以起播前先探这条
/// 线路本身：
/// ```
/// ① 能连上（TCP / TLS 不断）
/// ② 能拿到清单（HTTP 2xx + 内容是 #EXTM3U）
/// ③ 清单里第一个分片能下（拿到至少 1 个字节）
/// 三项全过 = 线路健康
/// ```
/// 每项最多 3 秒、总共 8 秒 —— 预检自己也不许卡住。预检失败 = 这条线路
/// 坏了（不是网慢）→ 立刻切下一条；预检通过但首帧一直出不来 → 按慢网处理，
/// 最多等 30 秒再切。
///
/// 只用 `dart:io`，不 import 任何包：这样 `tools/test_line_probe.dart` 能
/// 用 `dart run` 直接跑（不需要 Flutter SDK），也和 `fallback_match.dart`
/// 那套「纯判定层」保持一致。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 单阶段超时：连接 / 清单 / 首片各自最多 3 秒。
const Duration fxProbeStageTimeout = Duration(seconds: 3);

/// 预检总预算：三项加起来最多 8 秒（预检本身不许拖住起播）。
const Duration fxProbeTotalBudget = Duration(seconds: 8);

/// 清单最多读这么多（master / 媒体清单都是几十 KB，256KB 已经很宽松）。
const int fxProbeMaxManifestBytes = 256 * 1024;

/// 首片只读这么多就够判定「能下」。
const int fxProbeSegmentBytes = 8 * 1024;

/// 预检时用的 UA（和 PlayerHttp.defaultUa 同一档，避免源站按 UA 判机器）。
const String fxProbeUserAgent =
    'com.android.chrome/120.0.6099.230 (Linux;Android 14) AndroidXMedia3/1.4.1';

/// 预检阶段名（日志里的 `stage=`）。
class FxProbeStage {
  FxProbeStage._();

  /// 连上了（TCP / TLS 握手成功，拿到了响应头）。
  static const String connect = 'connect';

  /// 清单拿到了、校验通过（#EXTM3U + 至少 1 个分片）。
  static const String manifest = 'manifest';

  /// 第一个分片下到了字节 —— 三项全过的最终阶段。
  static const String segment = 'segment';

  /// 没有预检（直链 / 一次性令牌 / 已缓存健康）。
  static const String skip = 'skip';
}

/// 预检失败原因（日志里的 `reason=`）。
class FxProbeReason {
  FxProbeReason._();

  static const String dns = 'dns';
  static const String connectRefused = 'connect_refused';
  static const String tls = 'tls';
  static const String timeout = 'timeout';
  static const String notM3u8 = 'not_m3u8';
  static const String noSegment = 'no_segment';
  static const String emptySegment = 'empty_segment';
  static const String badUrl = 'bad_url';
  static const String socket = 'socket_error';
}

/// 一次预检的结果。
class FxLineProbeResult {
  const FxLineProbeResult({
    required this.ok,
    required this.stage,
    this.reason = '',
    this.httpStatus = 0,
    this.segments = 0,
    this.elapsed = Duration.zero,
  });

  /// 没有预检（跳过）：视为健康。
  const FxLineProbeResult.skipped({this.elapsed = Duration.zero})
    : ok = true,
      stage = FxProbeStage.skip,
      reason = '',
      httpStatus = 0,
      segments = 0;

  /// 三项全过 = true。
  final bool ok;

  /// 最后完成的阶段；失败时是**失败的那个阶段**。
  final String stage;

  /// 失败原因；成功时为空串。
  final String reason;

  /// 失败时的 HTTP 状态码（拿不到就是 0）。
  final int httpStatus;

  /// 清单里的分片数（媒体清单的分片行数）。
  final int segments;

  /// 预检总共花了多久。
  final Duration elapsed;

  /// 是否是「跳过预检」。
  bool get skipped => stage == FxProbeStage.skip;

  /// 失败码，和原生 `fatalError` / `playback_progress.dart` 用**同一份词表**：
  /// `http_404` / `dns_error` / `connect_refused` / `tls_error` /
  /// `manifest_invalid` / `no_segments`。
  String get failureCode {
    switch (reason) {
      case FxProbeReason.dns:
        return 'dns_error';
      case FxProbeReason.connectRefused:
        return 'connect_refused';
      case FxProbeReason.tls:
        return 'tls_error';
      case FxProbeReason.noSegment:
        return 'no_segments';
      case FxProbeReason.notM3u8:
        return 'manifest_invalid';
      case FxProbeReason.emptySegment:
        return 'no_segments';
      case FxProbeReason.badUrl:
        return 'manifest_invalid';
      default:
        if (httpStatus > 0) return 'http_$httpStatus';
        return reason.isEmpty ? 'probe_failed' : reason;
    }
  }

  @override
  String toString() =>
      'FxLineProbeResult(ok=$ok, stage=$stage, reason=$reason, '
      'http=$httpStatus, segs=$segments, ${elapsed.inMilliseconds}ms)';
}

/// 成功预检的缓存（10 分钟）。
///
/// 救援链「同地址重开」、换集重开同一个清单都会再来一次 open：再探一遍
/// 等于多打一次清单请求（有的源一次性令牌就这么被烧掉），所以探通就记住。
class FxLineProbeCache {
  FxLineProbeCache._();

  /// 缓存有效期。
  static const Duration ttl = Duration(minutes: 10);

  /// 总开关：关掉之后完全不预检（排障用）。
  static bool enabled = true;

  static final Map<String, DateTime> _healthy = <String, DateTime>{};

  /// 这个地址最近探通过吗？
  static bool isHealthy(String url, {DateTime? now}) {
    final key = url.trim();
    if (key.isEmpty) return false;
    final at = _healthy[key];
    if (at == null) return false;
    final gap = (now ?? DateTime.now()).difference(at);
    if (gap.isNegative || gap >= ttl) {
      _healthy.remove(key);
      return false;
    }
    return true;
  }

  /// 记一条「这条地址健康」。
  static void markHealthy(String url, {DateTime? now}) {
    final key = url.trim();
    if (key.isEmpty) return;
    if (_healthy.length > 64) _healthy.remove(_healthy.keys.first);
    _healthy[key] = now ?? DateTime.now();
  }

  /// 清空（测试 / 换源）。
  static void clear() => _healthy.clear();
}

/// 探一条线路。永不抛异常：所有失败都变成 [FxLineProbeResult]。
///
/// [headers] 必须和播放时同一套请求头（Referer / UA）：否则有的源站
/// 403 防盗链，会被误判成「线路坏了」。
Future<FxLineProbeResult> probeLine(
  String url, {
  Map<String, String> headers = const <String, String>{},
  Duration stageTimeout = fxProbeStageTimeout,
  Duration totalBudget = fxProbeTotalBudget,
  String userAgent = fxProbeUserAgent,
  HttpClient? client,
  /// 只探到清单为止（不下载首片）。
  ///
  /// 纯移动网络下用这一档：分片才是流量大头，清单只有几十 KB。
  /// 这样「启动时检查线路」不会明显吃用户流量。
  bool manifestOnly = false,
}) async {
  final watch = Stopwatch()..start();
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return FxLineProbeResult(
      ok: false,
      stage: FxProbeStage.connect,
      reason: FxProbeReason.badUrl,
      elapsed: watch.elapsed,
    );
  }
  final owned = client == null;
  final http =
      client ??
      (HttpClient()
        ..connectionTimeout = stageTimeout
        ..userAgent = userAgent
        // 影视源自签 / 域名不符 / 过期证书是常态，原生也全是 trust-all；
        // 预检要是比播放器严格，就会出现「预检说坏、其实能播」。
        ..badCertificateCallback = (cert, host, port) => true);
  try {
    Duration remaining() {
      final left = totalBudget - watch.elapsed;
      if (left <= Duration.zero) return Duration.zero;
      return left < stageTimeout ? left : stageTimeout;
    }

    // ① + ② 清单：连得上 + 拿得到 + 是 #EXTM3U + 有分片。
    final manifest = await _fetchManifest(
      http,
      uri,
      headers,
      remaining,
      followVariant: true,
      userAgent: userAgent,
    );
    if (manifest.failure != null) {
      return _stamp(manifest.failure!, watch);
    }
    if (manifest.segments.isEmpty) {
      return _stamp(
        const FxLineProbeResult(
          ok: false,
          stage: FxProbeStage.manifest,
          reason: FxProbeReason.noSegment,
        ),
        watch,
      );
    }

    if (manifestOnly) {
      // 只探清单：拿到 #EXTM3U 且分片数 > 0 就算这条线路活着。
      return _stamp(
        FxLineProbeResult(
          ok: true,
          stage: FxProbeStage.manifest,
          segments: manifest.segments.length,
        ),
        watch,
      );
    }

    // ③ 首片：拿到至少 1 个字节。
    final segment = await _probeFirstSegment(
      http,
      manifest.segments.first,
      headers,
      remaining(),
      userAgent,
    );
    if (segment != null) return _stamp(segment, watch);
    return _stamp(
      FxLineProbeResult(
        ok: true,
        stage: FxProbeStage.segment,
        segments: manifest.segments.length,
      ),
      watch,
    );
  } finally {
    if (owned) http.close(force: true);
  }
}

FxLineProbeResult _stamp(FxLineProbeResult result, Stopwatch watch) =>
    FxLineProbeResult(
      ok: result.ok,
      stage: result.stage,
      reason: result.reason,
      httpStatus: result.httpStatus,
      segments: result.segments,
      elapsed: watch.elapsed,
    );

/// 清单抓取结果：要么 [failure] 有值，要么 [segments] 是可播分片。
class _ManifestFetch {
  const _ManifestFetch({this.failure, this.segments = const <Uri>[]});
  final FxLineProbeResult? failure;
  final List<Uri> segments;
}

Future<_ManifestFetch> _fetchManifest(
  HttpClient client,
  Uri uri,
  Map<String, String> headers,
  Duration Function() remaining, {
  required bool followVariant,
  required String userAgent,
}) async {
  final timeout = remaining();
  if (timeout <= Duration.zero) {
    return const _ManifestFetch(
      failure: FxLineProbeResult(
        ok: false,
        stage: FxProbeStage.connect,
        reason: FxProbeReason.timeout,
      ),
    );
  }
  final fetched = await _getText(
    client,
    uri,
    headers,
    timeout,
    userAgent: userAgent,
  );
  if (fetched.failure != null) return _ManifestFetch(failure: fetched.failure);
  final status = fetched.status;
  if (status < 200 || status >= 300) {
    return _ManifestFetch(
      failure: FxLineProbeResult(
        ok: false,
        stage: FxProbeStage.manifest,
        reason: 'http_$status',
        httpStatus: status,
      ),
    );
  }
  final body = (fetched.body ?? '').trimLeft();
  if (!body.startsWith('#EXTM3U')) {
    return const _ManifestFetch(
      failure: FxLineProbeResult(
        ok: false,
        stage: FxProbeStage.manifest,
        reason: FxProbeReason.notM3u8,
      ),
    );
  }
  // master 清单：取第一个 variant 继续看（和播放器的做法一致）。
  if (followVariant && body.contains('#EXT-X-STREAM-INF')) {
    final variant = _firstUri(body, fetched.finalUri);
    if (variant != null) {
      return _fetchManifest(
        client,
        variant,
        headers,
        remaining,
        followVariant: false,
        userAgent: userAgent,
      );
    }
  }
  return _ManifestFetch(segments: _segmentUris(body, fetched.finalUri));
}

/// 抓第一个分片的前几 KB；成功（读到字节）返回 null，否则返回失败结果。
Future<FxLineProbeResult?> _probeFirstSegment(
  HttpClient client,
  Uri uri,
  Map<String, String> headers,
  Duration timeout,
  String userAgent,
) async {
  if (timeout <= Duration.zero) {
    return const FxLineProbeResult(
      ok: false,
      stage: FxProbeStage.segment,
      reason: FxProbeReason.timeout,
    );
  }
  final outcome = await _readSomeBytes(
    client,
    uri,
    headers,
    timeout,
    userAgent,
  );
  if (outcome.failure != null) return outcome.failure;
  if (outcome.status < 200 || outcome.status >= 300) {
    return FxLineProbeResult(
      ok: false,
      stage: FxProbeStage.segment,
      reason: 'http_${outcome.status}',
      httpStatus: outcome.status,
    );
  }
  // 读到字节 = 分片能下（返回 null 表示通过）。
  if (outcome.bytes > 0) return null;
  // 2xx 但一个字节都没读到：源站返回空体 / 截断，也算分片不可用。
  return const FxLineProbeResult(
    ok: false,
    stage: FxProbeStage.segment,
    reason: FxProbeReason.emptySegment,
  );
}

/// 文本 GET 的结果。
class _TextFetch {
  const _TextFetch({
    this.status = 0,
    this.body,
    this.failure,
    required this.finalUri,
  });

  final int status;
  final String? body;
  final FxLineProbeResult? failure;
  final Uri finalUri;
}

Future<_TextFetch> _getText(
  HttpClient client,
  Uri uri,
  Map<String, String> headers,
  Duration timeout, {
  required String userAgent,
}) async {
  try {
    final request = await client.openUrl('GET', uri).timeout(timeout);
    request.followRedirects = true;
    _applyHeaders(request, headers, userAgent);
    final response = await request.close().timeout(timeout);
    final buffer = <int>[];
    await for (final chunk in response.timeout(timeout)) {
      final room = fxProbeMaxManifestBytes - buffer.length;
      if (room <= 0) break;
      buffer.addAll(chunk.length > room ? chunk.sublist(0, room) : chunk);
      if (buffer.length >= fxProbeMaxManifestBytes) break;
    }
    return _TextFetch(
      status: response.statusCode,
      body: utf8.decode(buffer, allowMalformed: true),
      finalUri: _finalUri(response, uri),
    );
  } catch (error) {
    return _TextFetch(
      failure: _classify(error, FxProbeStage.connect),
      finalUri: uri,
    );
  }
}

/// 分片 GET 的结果：要么 [failure]，要么 [status]（2xx 且读到过字节）。
class _ByteFetch {
  const _ByteFetch({this.status = 0, this.bytes = 0, this.failure});

  final int status;

  /// 实际读到的字节数：>0 = 分片能下。
  final int bytes;
  final FxLineProbeResult? failure;
}

Future<_ByteFetch> _readSomeBytes(
  HttpClient client,
  Uri uri,
  Map<String, String> headers,
  Duration timeout,
  String userAgent,
) async {
  try {
    final request = await client.openUrl('GET', uri).timeout(timeout);
    request.followRedirects = true;
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${fxProbeSegmentBytes - 1}');
    _applyHeaders(request, headers, userAgent);
    final response = await request.close().timeout(timeout);
    final status = response.statusCode;
    if (status < 200 || status >= 300) return _ByteFetch(status: status);
    // 只等第一块字节：源站不支持 Range 也到此为止（订阅立刻取消）。
    try {
      final first = await response.first.timeout(timeout);
      return _ByteFetch(status: status, bytes: first.length);
    } on StateError {
      // 空响应体。
      return _ByteFetch(status: status);
    }
  } catch (error) {
    return _ByteFetch(failure: _classify(error, FxProbeStage.segment));
  }
}

void _applyHeaders(
  HttpClientRequest request,
  Map<String, String> headers,
  String userAgent,
) {
  var ua = userAgent;
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'user-agent') {
      if (entry.value.trim().isNotEmpty) ua = entry.value.trim();
      continue;
    }
    if (entry.key.trim().isEmpty || entry.value.trim().isEmpty) continue;
    if (entry.key.toLowerCase() == 'range') continue;
    request.headers.set(entry.key, entry.value);
  }
  request.headers.set(HttpHeaders.userAgentHeader, ua);
}

Uri _finalUri(HttpClientResponse response, Uri fallback) {
  if (response.redirects.isEmpty) return fallback;
  return response.redirects.last.location;
}

/// 异常 → 失败结果（DNS / 连接被拒 / TLS / 超时）。
FxLineProbeResult _classify(Object error, String stage) {
  if (error is TimeoutException) {
    return FxLineProbeResult(
      ok: false,
      stage: stage,
      reason: FxProbeReason.timeout,
    );
  }
  if (error is HandshakeException || error is TlsException) {
    return FxLineProbeResult(
      ok: false,
      stage: stage,
      reason: FxProbeReason.tls,
    );
  }
  if (error is SocketException) {
    return FxLineProbeResult(
      ok: false,
      stage: stage,
      reason: _socketReason(error),
    );
  }
  return FxLineProbeResult(
    ok: false,
    stage: stage,
    reason: FxProbeReason.socket,
  );
}

/// dart:io 的 SocketException 归类：DNS 还是「连不上」。
String _socketReason(SocketException error) {
  final message =
      '${error.message} ${error.osError?.message ?? ''}'.toLowerCase();
  if (message.contains('failed host lookup') ||
      message.contains('name or service not known') ||
      message.contains('nodename nor servname') ||
      message.contains('no address associated') ||
      message.contains('temporary failure in name resolution')) {
    return FxProbeReason.dns;
  }
  return FxProbeReason.connectRefused;
}

/// 清单里的第一个 variant 地址（master 清单）。
Uri? _firstUri(String body, Uri base) {
  final lines = body.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].trim().startsWith('#EXT-X-STREAM-INF')) continue;
    for (var j = i + 1; j < lines.length; j++) {
      final text = lines[j].trim();
      if (text.isEmpty || text.startsWith('#')) continue;
      final uri = Uri.tryParse(text);
      if (uri == null) return null;
      return base.resolveUri(uri);
    }
  }
  return null;
}

/// 媒体清单里的分片地址（按出现顺序）。
List<Uri> _segmentUris(String body, Uri base) {
  final out = <Uri>[];
  for (final raw in body.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final uri = Uri.tryParse(line);
    if (uri == null) continue;
    out.add(base.resolveUri(uri));
  }
  return out;
}

/// 预检日志：`probe line=幻想4K ok=true stage=segment` /
/// `probe line=mgtv ok=false stage=manifest reason=http_404 → switch`。
///
/// 纯字符串（不带 `[FxPlay]` 前缀）：调用方套 `fxPlayLog` 打出来即可。
String fxProbeLogMessage({
  required String line,
  required FxLineProbeResult probe,
}) {
  final name = line.trim().isEmpty ? '未知线路' : line.trim();
  final head = 'probe line=$name ok=${probe.ok} stage=${probe.stage}';
  if (probe.ok) return head;
  final reason = probe.reason.trim().isEmpty ? 'unknown' : probe.reason.trim();
  return '$head reason=$reason → switch';
}

/// 慢网到硬上限被切的日志：
/// `slow line=量子 waited=30s buffered=2.1s → switch`。
String fxSlowSwitchLogMessage({
  required String line,
  required int waitedSeconds,
  required Duration buffered,
}) {
  final name = line.trim().isEmpty ? '未知线路' : line.trim();
  final secs = waitedSeconds < 0 ? 0 : waitedSeconds;
  final buf = (buffered.inMilliseconds / 1000).toStringAsFixed(1);
  return 'slow line=$name waited=${secs}s buffered=${buf}s → switch';
}

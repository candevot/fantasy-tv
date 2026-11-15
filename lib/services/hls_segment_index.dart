import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

/// HLS 清单本地时间索引 + 分片大小校验（按逆向报告 §10 改动 4）。
///
/// 为什么要有这一层：
///   · **索引**：清单里 `#EXTINF` 一秒一秒累加出来的「分片 ↔ 时间」映射，
///     播放器解析器是黑盒，拖动时我们无法知道「拖到 3:41 该预取哪一片」。
///     这里自己解析一次、缓存起来，seek 时就能直接定位目标分片。
///   · **校验**：分片拉下来先核对大小（`#EXT-X-BYTERANGE` 声明 / `Content-Range`
///     总长 / 实收字节），对不上就**立刻回源直连**重新取这一片，而不是对着
///     同一个坏地址重试 —— 对应的就是对方 App 里的
///     `HLS segment bytes mismatch: actual=` → `hls_segment_proxy_fallback`。
///
/// 这一层是跨内核的：libmpv 现在直连，ExoPlayer 侧另有自己的预取器；
/// 这里只做「清单解析 + 校验 + 回源」，不碰播放内核，也不改任何响应字节。
class HlsSegmentRef {
  const HlsSegmentRef({
    required this.uri,
    required this.startMs,
    required this.durationMs,
    this.declaredBytes = 0,
  });

  final Uri uri;

  /// 该分片在时间轴上的起点（毫秒）。
  final int startMs;

  /// `#EXTINF` 声明的时长（毫秒）。
  final int durationMs;

  /// `#EXT-X-BYTERANGE` 声明的字节数；0 = 未声明（整片）。
  final int declaredBytes;

  int get endMs => startMs + durationMs;

  @override
  String toString() =>
      'HlsSegmentRef(start=${startMs}ms, dur=${durationMs}ms, '
      'bytes=$declaredBytes, uri=$uri)';
}

/// 一份媒体 playlist 的本地索引。
class HlsPlaylistIndex {
  HlsPlaylistIndex({required this.playlist, required this.segments})
      : totalDurationMs =
            segments.isEmpty ? 0 : segments.last.endMs;

  final Uri playlist;
  final List<HlsSegmentRef> segments;

  /// 全部 `#EXTINF` 累加出来的总时长（毫秒）；进度条/拖动定位用它。
  final int totalDurationMs;

  /// 命中某时刻所在的分片（起点 <= positionMs 的最后一片）。
  ///
  /// 返回 null 表示索引为空或时刻在第一个分片之前。
  HlsSegmentRef? segmentAtMs(int positionMs) {
    if (segments.isEmpty) return null;
    if (positionMs < segments.first.startMs) return segments.first;
    var lo = 0;
    var hi = segments.length - 1;
    var hit = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (segments[mid].startMs <= positionMs) {
        hit = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return segments[hit];
  }

  /// [Duration] 版本。
  HlsSegmentRef? segmentAt(Duration position) =>
      segmentAtMs(position.inMilliseconds);

  @override
  String toString() =>
      'HlsPlaylistIndex(segments=${segments.length}, '
      'total=${totalDurationMs}ms, playlist=$playlist)';
}

/// 分片校验结论。
enum HlsSegmentCheck {
  /// 大小与声明一致（或无法判定但没有异常）。
  ok,

  /// 大小与声明不一致：要回源直连。
  sizeMismatch,

  /// 请求本身失败（4xx/5xx/超时）。
  failed,
}

/// 一次分片校验的结果。
class HlsSegmentProbe {
  const HlsSegmentProbe({
    required this.result,
    required this.receivedBytes,
    this.expectedBytes,
    this.fromOrigin = false,
    this.note = '',
  });

  final HlsSegmentCheck result;

  /// 实际收到的字节数（探针最多读到 probeBytes）。
  final int receivedBytes;

  /// 声明的大小（EXT-X-BYTERANGE 优先，其次 Content-Range/Content-Length）。
  final int? expectedBytes;

  /// 是否是「回源直连」这一次的结果。
  final bool fromOrigin;

  final String note;

  @override
  String toString() =>
      'HlsSegmentProbe($result, received=$receivedBytes, '
      'expected=$expectedBytes, origin=$fromOrigin, $note)';
}

/// 清单索引 / 分片校验的全局入口（进程内缓存，按 URL 复用）。
class HlsSegmentIndex {
  HlsSegmentIndex._();

  static final HlsSegmentIndex instance = HlsSegmentIndex._();

  /// 索引有效期：临时签名（平台线路）几分钟就会变，10 分钟足够。
  static const Duration _ttl = Duration(minutes: 10);

  /// 最多缓存几份索引（一部剧来回切集不会爆内存）。
  static const int _maxIndexes = 6;

  /// 拉清单的预算；超时当作「没有索引」，绝不影响播放。
  static const Duration _fetchBudget = Duration(seconds: 3);

  /// 单次分片探针的超时。
  static const Duration _probeTimeout = Duration(seconds: 6);

  /// 本站解析服务包装出来的清单地址（`/hxparse/xo?u=…`、
  /// `/hxparse/play/…/index.m3u8`）。
  ///
  /// TOKEN_ONCE（2026-11-15）：这类地址背后是**一次性令牌**——
  /// 同一条 `/hxparse/xo?u=shvip-xxx` 第二次请求直接 403。
  /// 所以它**绝对不能**被第二次抓取：否则索引这一路把令牌用掉，
  /// 播放器随后那条请求就是 403，用户看到的是「清单拿到了、0 KB/s」。
  static final RegExp _wrappedPlaylist = RegExp(
    // lz = 量子分享页解析（/hxparse/lz?u=...），同样是一次一解析，
    // 预载或重复抓清单会把这一次配额烧掉。
    r'/hxparse/(?:xo|play|parse|lz)(?:/|\?|$)',
    caseSensitive: false,
  );

  /// [url] 是否是一次性令牌包装地址（不允许重复抓清单）。
  static bool isOneTimePlaylist(String url) {
    final text = url.trim().toLowerCase();
    if (text.isEmpty) return false;
    return _wrappedPlaylist.hasMatch(text);
  }

  /// 校验时最多读多少字节就够判定（4K 大分片不必整片拉两遍）。
  static const int _probeBytes = 96 * 1024;

  final Map<String, HlsPlaylistIndex> _cache = <String, HlsPlaylistIndex>{};
  final Map<String, DateTime> _cachedAt = <String, DateTime>{};
  final Map<String, Future<HlsPlaylistIndex?>> _inflight =
      <String, Future<HlsPlaylistIndex?>>{};

  /// 只看缓存（不请求）。
  HlsPlaylistIndex? peek(String url) {
    final cached = _cache[url];
    final at = _cachedAt[url];
    if (cached == null || at == null) return null;
    if (DateTime.now().difference(at) > _ttl) {
      _cache.remove(url);
      _cachedAt.remove(url);
      return null;
    }
    return cached;
  }

  /// 建（或复用）[url] 的本地时间索引。
  ///
  /// 失败 / 超时返回 null，调用方静默跳过 —— 没有索引只是少了拖动预取，
  /// 不影响播放。
  Future<HlsPlaylistIndex?> indexOf(
    String url,
    Map<String, String> headers, {
    Duration budget = _fetchBudget,
  }) {
    final cached = peek(url);
    if (cached != null) return Future<HlsPlaylistIndex?>.value(cached);
    final pending = _inflight[url];
    if (pending != null) return pending;
    final future = _build(url, headers).timeout(
      budget,
      onTimeout: () => null,
    );
    _inflight[url] = future;
    return future.whenComplete(() {
      if (identical(_inflight[url], future)) _inflight.remove(url);
    });
  }

  Future<HlsPlaylistIndex?> _build(
    String url,
    Map<String, String> headers,
  ) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) return null;
    final scheme = uri.scheme;
    if (scheme != 'http' && scheme != 'https') return null;
    // TOKEN_ONCE：一次性令牌清单不许为了「建拖动索引」再抓一遍 ——
    // 抓完播放器那条就 403 了。索引只是 seek 的加速器，没有它照样能播，
    // 令牌却是用完即焚，优先级完全不对等。
    if (isOneTimePlaylist(url)) {
      _log('HlsSegmentIndex: 一次性令牌清单，跳过索引抓取 $url');
      return null;
    }
    final body = await _fetchText(uri, headers);
    if (body == null || !body.contains('#EXTM3U')) return null;
    // master playlist：取第一个变体继续往下解析。
    final variant = _firstVariant(body, uri);
    var mediaUri = uri;
    var mediaBody = body;
    if (variant != null) {
      final sub = await _fetchText(variant, headers);
      if (sub == null || !sub.contains('#EXTM3U')) return null;
      mediaUri = variant;
      mediaBody = sub;
    }
    final segments = parseMediaPlaylist(mediaBody, mediaUri);
    if (segments.isEmpty) return null;
    final index = HlsPlaylistIndex(playlist: mediaUri, segments: segments);
    _cache[url] = index;
    _cachedAt[url] = DateTime.now();
    _trim();
    _log(
      'HlsSegmentIndex: $url → ${segments.length} 片，'
      '总时长 ${index.totalDurationMs}ms',
    );
    return index;
  }

  /// 校验一个分片：大小对不上就回源直连重取一次。
  Future<HlsSegmentProbe> verify(
    HlsSegmentRef ref, {
    required Map<String, String> headers,
    int probeBytes = _probeBytes,
  }) async {
    final first = await _probe(
      ref,
      headers: headers,
      probeBytes: probeBytes,
      fromOrigin: false,
    );
    if (first.result == HlsSegmentCheck.ok) return first;
    // 尺寸不符 / 取不到：不重试同一个地址，直接回源直连。
    final origin = originUri(ref.uri);
    if (origin == ref.uri && first.result == HlsSegmentCheck.failed) {
      return first;
    }
    _log('HlsSegmentIndex: 分片校验失败(${first.note})，回源直连 $origin');
    final second = await _probe(
      ref,
      headers: headers,
      probeBytes: probeBytes,
      fromOrigin: true,
      uriOverride: origin,
    );
    return second;
  }

  Future<HlsSegmentProbe> _probe(
    HlsSegmentRef ref, {
    required Map<String, String> headers,
    required int probeBytes,
    required bool fromOrigin,
    Uri? uriOverride,
  }) async {
    final uri = uriOverride ?? ref.uri;
    final client = http.Client();
    try {
      final request = http.Request('GET', uri)..headers.addAll(headers);
      // 探针只取开头一段：够判断「声明长度 vs 实收长度」，不整片拉两遍。
      request.headers['Range'] = 'bytes=0-${probeBytes - 1}';
      if (fromOrigin) {
        // 回源：绕开一切中间缓存（CDN / 本地代理 / 系统 HTTP 缓存）。
        request.headers['Cache-Control'] = 'no-cache, no-store';
        request.headers['Pragma'] = 'no-cache';
      }
      final response = await client.send(request).timeout(_probeTimeout);
      if (response.statusCode >= 400) {
        return HlsSegmentProbe(
          result: HlsSegmentCheck.failed,
          receivedBytes: 0,
          fromOrigin: fromOrigin,
          note: 'HTTP ${response.statusCode}',
        );
      }
      final total = _totalBytes(response.headers, probeBytes);
      var received = 0;
      var endedEarly = false;
      await for (final chunk in response.stream.timeout(_probeTimeout)) {
        received += chunk.length;
        if (received >= probeBytes) break;
        if (total != null && total > 0 && received >= total) {
          endedEarly = true;
          break;
        }
      }
      // 判定优先级：清单声明的字节数 > 响应里的总长声明。
      final expected = ref.declaredBytes > 0 ? ref.declaredBytes : total;
      if (expected != null && expected > 0) {
        // EXT-X-BYTERANGE 与响应总长不一致 → 清单和实际不是同一份。
        if (ref.declaredBytes > 0 && total != null && total != ref.declaredBytes) {
          return HlsSegmentProbe(
            result: HlsSegmentCheck.sizeMismatch,
            receivedBytes: received,
            expectedBytes: ref.declaredBytes,
            fromOrigin: fromOrigin,
            note: '清单声明 ${ref.declaredBytes}B，响应声称 ${total}B',
          );
        }
        // 流提前结束且没读满探针长度 → 被截断。
        if (!endedEarly && received < probeBytes && received < expected) {
          return HlsSegmentProbe(
            result: HlsSegmentCheck.sizeMismatch,
            receivedBytes: received,
            expectedBytes: expected,
            fromOrigin: fromOrigin,
            note: '实收 ${received}B < 声明 ${expected}B',
          );
        }
      }
      return HlsSegmentProbe(
        result: HlsSegmentCheck.ok,
        receivedBytes: received,
        expectedBytes: expected,
        fromOrigin: fromOrigin,
        note: 'ok',
      );
    } catch (error) {
      return HlsSegmentProbe(
        result: HlsSegmentCheck.failed,
        receivedBytes: 0,
        fromOrigin: fromOrigin,
        note: '$error',
      );
    } finally {
      client.close();
    }
  }

  /// 统一日志出口：走 dart:developer，不依赖 Flutter，
  /// 这样这一层能被纯 Dart 测试脚本直接跑（tools/test_hls_segment_index.dart）。
  static void _log(String message) {
    developer.log(message, name: 'HlsSegmentIndex');
  }

  /// 从响应头里取分片总长：`Content-Range: bytes 0-96255/96256` 的第二段，
  /// 没有就退回 `Content-Length`（200 全量响应时它就是总长）。
  static int? _totalBytes(Map<String, String> headers, int probeBytes) {
    final range = headers['content-range'] ?? headers['Content-Range'];
    if (range != null) {
      final slash = range.lastIndexOf('/');
      if (slash >= 0 && slash + 1 < range.length) {
        final raw = range.substring(slash + 1).trim();
        if (raw != '*') {
          final total = int.tryParse(raw);
          if (total != null && total > 0) return total;
        }
      }
    }
    final length = headers['content-length'] ?? headers['Content-Length'];
    if (length != null) {
      final parsed = int.tryParse(length.trim());
      // 206 的 Content-Length 是「这一段」的长度，不是整片总长。
      if (parsed != null && parsed > 0 && parsed != probeBytes) return parsed;
    }
    return null;
  }

  /// 本地代理地址（127.0.0.1 带 `?url=`）→ 还原成源站地址。
  ///
  /// 直连模式下这是恒等变换；留着是为了让「回源」在代理开着时也指向源站，
  /// 而不是又打回本地代理。
  static Uri originUri(Uri uri) {
    final host = uri.host.toLowerCase();
    final loopback =
        host == '127.0.0.1' || host == 'localhost' || host == '::1';
    if (!loopback) return uri;
    final inner = uri.queryParameters['url'];
    if (inner == null || inner.isEmpty) return uri;
    final parsed = Uri.tryParse(inner);
    if (parsed == null || !parsed.hasScheme) return uri;
    return parsed;
  }

  /// 解析媒体 playlist 的 `#EXTINF` / `#EXT-X-BYTERANGE`，建时间索引。
  ///
  /// 只读不改：返回的是索引数据，不会生成新的清单文件。
  static List<HlsSegmentRef> parseMediaPlaylist(String body, Uri base) {
    final segments = <HlsSegmentRef>[];
    var startMs = 0;
    var pendingDurationMs = 0;
    var pendingBytes = 0;
    for (final raw in const LineSplitter().convert(body)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXTINF:')) {
        final value = line.substring(8);
        final comma = value.indexOf(',');
        final seconds = double.tryParse(
              comma >= 0 ? value.substring(0, comma) : value,
            ) ??
            0;
        pendingDurationMs = (seconds * 1000).round();
        continue;
      }
      if (line.startsWith('#EXT-X-BYTERANGE:')) {
        final value = line.substring(17);
        final at = value.indexOf('@');
        pendingBytes = int.tryParse(at >= 0 ? value.substring(0, at) : value) ?? 0;
        continue;
      }
      if (line.startsWith('#')) continue;
      final uri = Uri.tryParse(base.resolve(line).toString());
      if (uri == null) continue;
      segments.add(
        HlsSegmentRef(
          uri: uri,
          startMs: startMs,
          durationMs: pendingDurationMs,
          declaredBytes: pendingBytes,
        ),
      );
      startMs += pendingDurationMs;
      pendingDurationMs = 0;
      pendingBytes = 0;
    }
    return segments;
  }

  Future<String?> _fetchText(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final client = http.Client();
    try {
      final response =
          await client.get(uri, headers: headers).timeout(_fetchBudget);
      if (response.statusCode < 200 || response.statusCode >= 400) return null;
      return utf8.decode(response.bodyBytes, allowMalformed: true);
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  /// master playlist 的第一个变体地址；不是 master 则返回 null。
  static Uri? _firstVariant(String body, Uri base) {
    final lines = const LineSplitter().convert(body);
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].trimLeft().startsWith('#EXT-X-STREAM-INF')) continue;
      for (var j = i + 1; j < lines.length; j++) {
        final line = lines[j].trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        final uri = Uri.tryParse(base.resolve(line).toString());
        return uri;
      }
    }
    return null;
  }

  void _trim() {
    if (_cache.length <= _maxIndexes) return;
    final now = DateTime.now();
    _cache.removeWhere((key, _) {
      final at = _cachedAt[key];
      return at == null || now.difference(at) > _ttl;
    });
    while (_cache.length > _maxIndexes) {
      final oldest = _cachedAt.entries.reduce(
        (a, b) => a.value.isBefore(b.value) ? a : b,
      );
      _cache.remove(oldest.key);
      _cachedAt.remove(oldest.key);
    }
  }
}

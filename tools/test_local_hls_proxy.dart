// 本地 HLS 分片代理验证（纯 Dart，不依赖 Flutter）：
//   /root/dartsdk-arm64/dart-sdk/bin/dart tools/test_local_hls_proxy.dart
//
// 覆盖：master / media 改写、EXT-X-KEY / EXT-X-MAP、Range 并行下载、
// 完整字节一致性、二次请求缓存命中 <20ms、预取并发、LRU 上限、
// 签名 403 自动刷新 playlist、定时刷新、临时文件清理、关闭服务。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../lib/services/local_hls_proxy.dart';

int _passed = 0;

void check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
  _passed++;
  print('  ok - $message');
}

Future<void> waitFor(
  bool Function() condition,
  String message, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('FAIL(timeout): $message');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

Future<void> main() async {
  final origin = await _Origin.start();
  final proxies = <LocalHlsProxy>[];
  final client = HttpClient();
  try {
    await _testMasterAndSegment(origin, proxies, client);
    await _testWrapperPlaylist(origin, proxies, client);
    await _testPrefetch(origin, proxies, client);
    await _testRangePlaylist(origin, proxies, client);
    await _testSignedSegmentSelfHeal(origin, proxies, client);
    await _testPeriodicRefresh(origin, proxies, client);
    await _testPlatformWrapperRefresh(origin, proxies, client);
    await _testMasterPlatformRefresh(origin, proxies, client);
    await _testRefreshGuards(origin, proxies, client);
    await _testLru(origin, proxies, client);
    await _testTempSpoolAndDispose(origin, proxies, client);
    print('\nALL PASS ($_passed checks)');
  } finally {
    for (final proxy in proxies) {
      await proxy.dispose();
    }
    client.close(force: true);
    await origin.close();
  }
}

Future<void> _testMasterAndSegment(
  _Origin origin,
  List<LocalHlsProxy> proxies,
  HttpClient client,
) async {
  print('\n[1] master/media 改写 + 并行下载 + 缓存');
  origin.resetStats();
  final logs = <String>[];
  final proxy = LocalHlsProxy(
    parallelism: 8,
    prefetchCount: 0,
    retries: 1,
    playlistRefreshInterval: const Duration(minutes: 5),
    log: logs.add,
  );
  proxies.add(proxy);

  final localMaster = await proxy.proxy(
    '${origin.base}/master.m3u8',
    <String, String>{
      'Referer': 'https://example.com/',
      'User-Agent': 'Mozilla/5.0 test',
    },
  );
  check(
    localMaster.startsWith('http://127.0.0.1:${proxy.port}/playlist?u='),
    'proxy 返回 127.0.0.1 本地 m3u8 地址',
  );

  final masterText = await _getText(client, localMaster);
  check(masterText.contains('#EXT-X-STREAM-INF'), 'master 保留 STREAM-INF');
  check(masterText.contains('/playlist?u='), 'master 变体改写为本地 /playlist');
  final variants = _httpLines(masterText);
  check(variants.length == 1, 'master 只有一个变体');
  check(origin.masterRequests == 1, 'master 只向源站拉取一次');

  final mediaText = await _getText(client, variants.first);
  check(mediaText.contains('#EXTM3U'), '子列表仍是合法 m3u8');
  final segLines = _httpLines(mediaText);
  check(segLines.length == 3, '3 个分片全部改写为本地地址');
  check(segLines.every((line) => line.contains('/seg?i=')), '/seg 地址带 i 序号');
  check(mediaText.contains('/key?u='), 'EXT-X-KEY 改写为本地 /key');
  check(
    mediaText.contains('#EXT-X-MAP:URI="http://127.0.0.1:'),
    'EXT-X-MAP 改写为本地 /seg',
  );
  check(!mediaText.contains('seg/0.ts'), '播放列表里不再暴露源分片地址');

  final keyUrl = _firstUriAttribute(mediaText, '#EXT-X-KEY:');
  final key = await _getBytes(client, keyUrl);
  check(key.length == 16, 'AES key 长度 16 字节');
  check(origin.keyRequests == 1, 'key 只取一次');

  final mapUrl = _firstUriAttribute(mediaText, '#EXT-X-MAP:');
  final init = await _getBytes(client, mapUrl);
  check(init.length == 1024, 'EXT-X-MAP 初始化段完整返回');

  final firstUrl = segLines.first;
  final firstStarted = DateTime.now();
  final first = await _getBytes(client, firstUrl);
  final firstMs = DateTime.now().difference(firstStarted).inMilliseconds;
  check(first.length == 2 * 1024 * 1024, '首个 2MB 分片长度与源一致');
  check(_bytesEqual(first, origin.segmentBytes(0)), '首个分片内容与源逐字节一致');
  check(
    origin.maxConcurrentSegmentGets >= 2,
    '分片使用多连接 Range 并行下载（max=${origin.maxConcurrentSegmentGets}）',
  );
  check(origin.rangeRequests >= 2, '源站收到多个 Range 请求');
  check(firstMs < 1000, '首个分片下载耗时正常 ($firstMs ms)');
  check(logs.any((line) => line.contains('parallel=8')), '日志包含 8 路并行下载统计');
  check(
    logs.any(
      (line) =>
          line.contains('SEG') &&
          line.contains('200') &&
          line.contains('parallel=8') &&
          !line.contains('cache-hit'),
    ),
    '首次分片日志标记实际下载而非缓存命中',
  );

  final hitsBefore = proxy.cacheHits;
  final secondStarted = DateTime.now();
  final second = await _getBytes(client, firstUrl);
  final secondMs = DateTime.now().difference(secondStarted).inMilliseconds;
  check(_bytesEqual(second, origin.segmentBytes(0)), '二次请求字节仍完整');
  check(proxy.cacheHits > hitsBefore, '二次请求命中内存缓存');
  check(proxy.cacheMisses >= 1, '首次请求计入 miss');
  check(secondMs < 20, '二次请求命中缓存 <20ms (${secondMs}ms)');
  check(logs.any((line) => line.contains('cache-hit')), '日志包含命中缓存');

  final firstHitMs = DateTime.now().millisecondsSinceEpoch;
  await _getBytes(client, firstUrl);
  check(
    DateTime.now().millisecondsSinceEpoch - firstHitMs < 40,
    '缓存命中稳定（<40ms 含调度）',
  );
}

Future<void> _testWrapperPlaylist(
  _Origin origin,
  List<LocalHlsProxy> proxies,
  HttpClient client,
) async {
  print('\n[1b] 无 .m3u8 后缀的平台包装地址 + 误判 MP4 的快速失败');
  origin.resetStats();
  final proxy = LocalHlsProxy(
    prefetchCount: 0,
    playlistRefreshInterval: const Duration(minutes: 5),
    log: _ignore,
  );
  proxies.add(proxy);
  // 平台线路常见形态：/api/fyplay?u=… 本身没有 .m3u8 后缀。
  final local = await proxy.proxy(
    '${origin.base}/fyplay?u=FY-TX-4K',
    <String, String>{'Referer': 'https://example.com/'},
  );
  final media = await _getText(client, local);
  final segs = _httpLines(media);
  check(segs.length >= 2, '包装地址仍能解析出分片');
  final bytes = await _getBytes(client, segs.first);
  check(bytes.length == 64 * 1024, '包装地址分片返回完整字节');
  check(origin.fyRequests == 1, '包装地址只拉取一次');

  var mp4RejectedQuickly = false;
  final sw = Stopwatch()..start();
  try {
    await proxy.proxy('${origin.base}/movie.mp4', <String, String>{});
  } catch (_) {
    mp4RejectedQuickly = sw.elapsedMilliseconds < 1000;
  }
  check(mp4RejectedQuickly, '非 m3u8 内容快速失败并回退直连（<1s）');
}

Future<void> _testPrefetch(
  _Origin origin,
  List<LocalHlsProxy> proxies,
  HttpClient client,
) async {
  print('\n[2] 顺序预取 5 个分片、并发 3');
  origin.resetStats();
  final proxy = LocalHlsProxy(
    parallelism: 8,
    prefetchCount: 5,
    prefetchConcurrency: 3,
    playlistRefreshInterval: const Duration(minutes: 5),
    log: _ignore,
  );
  proxies.add(proxy);
  final local = await proxy.proxy(
    '${origin.base}/prefetch.m3u8',
    <String, String>{'User-Agent': 'Mozilla/5.0 test'},
  );
  await waitFor(
    () => origin.segmentRequests >= 5 && proxy.cacheEntryCount >= 5,
    '后台预取至少 5 个分片',
  );
  check(proxy.cacheEntryCount >= 5, '预取写入了 5 个分片缓存');
  check(
    origin.maxConcurrentSegmentGets <= 3,
    '预取并发不超过 3（max=${origin.maxConcurrentSegmentGets}）',
  );
  final media = await _getText(client, local);
  final first = _httpLines(media).first;
  final cached = await _getBytes(client, first);
  check(cached.length == 64 * 1024, '预取分片长度正确');
  check(proxy.cacheHits >= 1, '播放到已预取分片时直接命中缓存');
}

Future<void> _testRangePlaylist(
  _Origin origin,
  List<LocalHlsProxy> proxies,
  HttpClient client,
) async {
  print('\n[3] EXT-X-BYTERANGE 改写与区间内容');
  origin.resetStats();
  final proxy = LocalHlsProxy(
    prefetchCount: 0,
    playlistRefreshInterval: const Duration(minutes: 5),
    log: _ignore,
  );
  proxies.add(proxy);
  final local = await proxy.proxy(
    '${origin.base}/range.m3u8',
    <String, String>{},
  );
  final media = await _getText(client, local);
  check(!media.contains('#EXT-X-BYTERANGE'), 'BYTERANGE 标签已移除');
  final lines = _httpLines(media);
  check(lines.length == 2, '两个 byterange 分片均改写');
  check(lines.first.contains('r=50000-100000'), '本地地址带区间参数');
  final first = await _getBytes(client, lines.first);
  final blob = origin.blob;
  check(first.length == 100000, 'byterange 分片长度正确');
  check(
    _bytesEqual(first, Uint8List.sublistView(blob, 50000, 150000)),
    'byterange 分片内容为源文件对应区间',
  );
  final second = await _getBytes(client, lines[1]);
  check(
    _bytesEqual(second, Uint8List.sublistView(blob, 150000, 200000)),
    '第二个 byterange 分片内容正确',
  );
  check(origin.rangeRequests >= 2, '按 Range 拉取源文件');
}

Future<void> _testSignedSegmentSelfHeal(
  _Origin origin,
  List<LocalHlsProxy> proxies,
  HttpClient client,
) async {
  print('\n[4] 分片 403：刷新 playlist 后重试成功');
  origin.resetStats();
  final logs = <String>[];
  final proxy = LocalHlsProxy(
    prefetchCount: 0,
    playlistRefreshInterval: const Duration(minutes: 5),
    log: logs.add,
  );
  proxies.add(proxy);
  final local = await proxy.proxy(
    '${origin.base}/rotating.m3u8',
    <String, String>{'Referer': 'https://example.com/'},
  );
  final media = await _getText(client, local);
  final segUrl = _httpLines(media).first;
  // 模拟签名过期：旧 token 全部 403。
  origin.expireTokens();
  final bytes = await _getBytes(client, segUrl);
  check(bytes.length == 64 * 1024, '403 后仍拿到完整分片');
  check(origin.forbidden >= 1, '源站确实返回过 403');
  check(origin.playlistRequests >= 2, '403 后重新拉取了 playlist');
  check(
    logs.any(
      (line) => line.contains('HTTP 403') && line.contains('refresh-ok'),
    ),
    '日志记录 403 自愈过程',
  );

  // 新本地地址（刷新后）也可用，并命中稳定 key 缓存。
  final media2 = await _getText(client, local);
  final seg2 = _httpLines(media2).first;
  final hitsBefore = proxy.cacheHits;
  final again = await _getBytes(client, seg2);
  check(_bytesEqual(again, bytes), '刷新后再次请求内容一致');
  check(proxy.cacheHits > hitsBefore, '刷新前后同一分片命中同一缓存 key');
}

Future<void> _testPeriodicRefresh(
  _Origin origin,
  List<LocalHlsProxy> proxies,
  HttpClient client,
) async {
  print('\n[5] 定时重取 playlist（60–120s 机制的短间隔验证）');
  origin.resetStats();
  final proxy = LocalHlsProxy(
    prefetchCount: 0,
    playlistRefreshInterval: const Duration(milliseconds: 150),
    log: _ignore,
  );
  proxies.add(proxy);
  final local = await proxy.proxy(
    '${origin.base}/rotating.m3u8',
    <String, String>{},
  );
  final initial = await _getText(client, local);
  final segUrl = _httpLines(initial).first;
  final requestsAtStart = origin.playlistRequests;
  await waitFor(
    () => origin.playlistRequests >= requestsAtStart + 1,
    '定时器重新拉取 playlist',
    timeout: const Duration(seconds: 3),
  );
  check(origin.playlistRequests >= 2, '定时刷新至少发生一次');

  // 定时刷新后，旧本地分片地址应映射到新 token 并可播放。
  origin.forbidden = 0;
  final bytes = await _getBytes(client, segUrl);
  check(bytes.length == 64 * 1024, '定时刷新后旧本地地址仍可播放');
  await proxy.dispose();
  proxies.remove(proxy);
}

Future<void> _testPlatformWrapperRefresh(
  _Origin origin,
  List<LocalHlsProxy> proxies,
  HttpClient client,
) async {
  print('\n[5b] 自有 API 平台包装地址：定时器调用签名刷新回调');
  for (final path in <String>['/api/iqiyi.m3u8', '/api/fyplay']) {
    origin.resetStats();
    var refreshCalls = 0;
    final logs = <String>[];
    final proxy = LocalHlsProxy(
      prefetchCount: 0,
      playlistRefreshInterval: const Duration(milliseconds: 150),
      log: logs.add,
    );
    proxies.add(proxy);
    final local = await proxy.proxy(
      '${origin.base}$path',
      <String, String>{},
      refreshPlay: () async {
        refreshCalls++;
        return '${origin.base}/rotating.m3u8';
      },
    );
    final oldSegment = _httpLines(await _getText(client, local)).first;
    origin.expireTokens();
    await waitFor(
      () => logs.any((line) => line.contains('平台线路签名已刷新')),
      '$path 定时器走平台刷新而非仅重取原列表',
    );
    check(refreshCalls >= 1, '$path 定时调用 refreshPlay');
    check(origin.playlistRequests >= 2, '$path 拉取回调返回的新播放列表');
    final bytes = await _getBytes(client, oldSegment);
    check(bytes.length == 64 * 1024, '$path 刷新后旧分片别名可播放');
    check(origin.forbidden == 0, '$path 定时换签成功，无需等分片 403');
    await proxy.dispose();
    proxies.remove(proxy);

    // 没有回调时仍应普通重取，不把包装地址变成不可刷新的特殊情况。
    final plain = LocalHlsProxy(
      prefetchCount: 0,
      playlistRefreshInterval: const Duration(milliseconds: 150),
      log: _ignore,
    );
    proxies.add(plain);
    await plain.proxy('${origin.base}$path', <String, String>{});
    final before = origin.playlistRequests;
    await waitFor(
      () => origin.playlistRequests > before,
      '$path 没有 refreshPlay 时仍普通定时刷新',
    );
    check(origin.playlistRequests > before, '$path 无回调保留普通刷新');
    await plain.dispose();
    proxies.remove(plain);
  }
}

Future<void> _testMasterPlatformRefresh(
  _Origin origin,
  List<LocalHlsProxy> proxies,
  HttpClient client,
) async {
  print('\n[5c] master 刷新：子列表按身份匹配，歧义/时间轴变化拒绝提交');
  var version = 1;
  var mode = 'ok';
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.headers.contentType = ContentType(
      'application',
      'vnd.apple.mpegurl',
    );
    if (request.uri.path == '/api/fyplay') {
      final children = version == 1 ? <String>['a', 'b'] : <String>['b', 'a'];
      request.response.write('#EXTM3U\n');
      for (final child in children) {
        final quality = mode == 'unknown' ? '${child}changed' : child;
        request.response.write(
          '#EXT-X-STREAM-INF:BANDWIDTH=${child == 'a' ? 100 : 200}\n'
          '/$child.m3u8?quality=$quality&token=$version\n',
        );
      }
      if (mode == 'ambiguous') {
        request.response.write(
          '#EXT-X-STREAM-INF:BANDWIDTH=300\n'
          '/a.m3u8?quality=a&token=duplicate\n',
        );
      }
    } else {
      final duration = mode == 'timeline' ? 11 : 10;
      request.response.write(
        '#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:0\n'
        '#EXTINF:$duration,\n${origin.base}/seg/10.ts?token=$version\n#EXT-X-ENDLIST\n',
      );
    }
    await request.response.close();
  });
  final logs = <String>[];
  var expired = 0;
  final proxy = LocalHlsProxy(
    prefetchCount: 0,
    playlistRefreshInterval: Duration.zero,
    log: logs.add,
  );
  proxies.add(proxy);
  try {
    final root = 'http://127.0.0.1:${server.port}/api/fyplay';
    final local = await proxy.proxy(
      root,
      <String, String>{},
      refreshPlay: () async => root,
      onPlayExpired: () => expired++,
    );
    final children = _httpLines(await _getText(client, local));
    final oldChild = children.first;
    final oldSegment = _httpLines(await _getText(client, oldChild)).first;
    version = 2;
    await proxy.refreshPlaylists();
    final text = await _getText(client, oldChild);
    final source = Uri.parse(_httpLines(text).first).queryParameters['u']!;
    final decoded = utf8.decode(base64Url.decode(base64Url.normalize(source)));
    check(decoded.contains('token=2'), '重排后旧子列表逻辑 key 指向新签名');
    origin.accepted = 2;
    final bytes = await _getBytes(client, oldSegment);
    check(bytes.length == 64 * 1024, 'master 刷新后旧分片别名仍可播放');
    mode = 'ambiguous';
    version = 3;
    await proxy.refreshPlaylists();
    check(
      logs.any((line) => line.contains('ambiguous or changed child identity')),
      '重复子列表身份拒绝刷新',
    );
    check(await _getText(client, oldChild) == text, '拒绝刷新保留旧播放列表');
    mode = 'timeline';
    await proxy.refreshPlaylists();
    check(
      logs.any((line) => line.contains('changed media timeline')),
      '时间轴变化拒绝刷新',
    );
    check(expired == 1, '连续失败通知宿主救援而不伪报成功');
    mode = 'unknown';
    final failures = logs.where((line) => line.contains('签名刷新失败')).length;
    await proxy.refreshPlaylists();
    check(
      logs.where((line) => line.contains('签名刷新失败')).length == failures + 1,
      '未知 query 字段变化拒绝映射，不误切其他清晰度',
    );
    mode = 'ok';
    await proxy.refreshPlaylists();
    final refreshedRoot = _httpLines(await _getText(client, local));
    check(refreshedRoot.contains(oldChild), '连续刷新保留旧逻辑子列表 key');
  } finally {
    await proxy.dispose();
    proxies.remove(proxy);
    await server.close(force: true);
  }
}

Future<void> _testRefreshGuards(
  _Origin origin,
  List<LocalHlsProxy> proxies,
  HttpClient client,
) async {
  print('\n[5d] 刷新保护：代际/期限/DAG/live/KEY/MAP');
  var mode = 'plain';
  var revision = 1;
  var slow = false;
  final requests = <String, int>{};
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final path = request.uri.path;
    requests[path] = (requests[path] ?? 0) + 1;
    if (slow) await Future<void>.delayed(const Duration(milliseconds: 250));
    String body;
    if (mode == 'cycle') {
      body = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\n/api/fyplay\n';
    } else if (mode == 'dag' &&
        (path == '/api/fyplay' || path == '/one' || path == '/two')) {
      final children = path == '/api/fyplay'
          ? <String>['one', 'two']
          : <String>['shared'];
      body =
          '#EXTM3U\n' +
          children
              .map((child) => '#EXT-X-STREAM-INF:BANDWIDTH=100\n/$child\n')
              .join();
    } else {
      final extra = (mode == 'key' || mode == 'iv')
          ? '#EXT-X-KEY:METHOD=AES-128,URI="/key?token=${mode == 'iv' ? 1 : revision}",IV=0x$revision\n'
          : mode == 'map'
          ? '#EXT-X-MAP:URI="/init?token=$revision"\n'
          : '';
      body =
          '#EXTM3U\n$extra#EXTINF:10,\n${origin.base}/seg/10.ts\n'
          '${mode == 'live' ? '' : '#EXT-X-ENDLIST\n'}';
    }
    try {
      request.response.write(body);
      await request.response.close();
    } catch (_) {}
  });
  final root = 'http://127.0.0.1:${server.port}/api/fyplay';
  try {
    for (final guardedMode in <String>['key', 'iv', 'map']) {
      mode = guardedMode;
      revision = 1;
      final logs = <String>[];
      final proxy = LocalHlsProxy(
        prefetchCount: 0,
        playlistRefreshInterval: Duration.zero,
        log: logs.add,
      );
      proxies.add(proxy);
      final local = await proxy.proxy(
        root,
        <String, String>{},
        refreshPlay: () async => root,
      );
      final old = await _getText(client, local);
      revision = 2;
      await proxy.refreshPlaylists();
      check(
        logs.any((line) => line.contains('changed key or map metadata')),
        '$guardedMode 变化明确拒绝刷新',
      );
      check(await _getText(client, local) == old, '$guardedMode 拒绝后旧缓存未被污染');
      await proxy.dispose();
      proxies.remove(proxy);
    }
    mode = 'live';
    final liveLogs = <String>[];
    final live = LocalHlsProxy(
      prefetchCount: 0,
      playlistRefreshInterval: Duration.zero,
      log: liveLogs.add,
    );
    proxies.add(live);
    await live.proxy(root, <String, String>{}, refreshPlay: () async => root);
    await live.refreshPlaylists();
    check(
      liveLogs.any((line) => line.contains('签名已刷新')),
      'live 根列表仍正常刷新，无 index 别名交换',
    );
    await live.dispose();
    proxies.remove(live);

    mode = 'dag';
    final dagLogs = <String>[];
    final dag = LocalHlsProxy(
      prefetchCount: 0,
      playlistRefreshInterval: Duration.zero,
      log: dagLogs.add,
    );
    proxies.add(dag);
    final dagRoot = await dag.proxy(
      root,
      <String, String>{},
      refreshPlay: () async => root,
    );
    for (final parent in _httpLines(await _getText(client, dagRoot))) {
      for (final child in _httpLines(await _getText(client, parent))) {
        await _getText(client, child);
      }
    }
    final before = requests['/shared'] ?? 0;
    await dag.refreshPlaylists();
    check(dagLogs.any((line) => line.contains('签名已刷新')), '共享子列表 DAG 不误判循环');
    check(requests['/shared'] == before + 1, 'DAG 共享子列表只拉取一次');
    await dag.dispose();
    proxies.remove(dag);

    mode = 'cycle';
    final cycleLogs = <String>[];
    final cycle = LocalHlsProxy(
      prefetchCount: 0,
      playlistRefreshInterval: Duration.zero,
      log: cycleLogs.add,
    );
    proxies.add(cycle);
    await cycle.proxy(root, <String, String>{}, refreshPlay: () async => root);
    await cycle.refreshPlaylists();
    check(
      cycleLogs.any((line) => line.contains('cyclic child tree')),
      '真正循环明确拒绝，无无限递归',
    );
    await cycle.dispose();
    proxies.remove(cycle);

    mode = 'plain';
    final pending = Completer<String?>();
    final genLogs = <String>[];
    final gen = LocalHlsProxy(
      prefetchCount: 0,
      playlistRefreshInterval: Duration.zero,
      log: genLogs.add,
    );
    proxies.add(gen);
    await gen.proxy(
      root,
      <String, String>{},
      refreshPlay: () => pending.future,
    );
    final oldRefresh = gen.refreshPlaylists();
    await gen.proxy('${origin.base}/rotating.m3u8', <String, String>{});
    pending.complete(root);
    await oldRefresh;
    check(
      !genLogs.any((line) => line.contains('签名已刷新') || line.contains('签名刷新失败')),
      '切源后旧回调不提交也不累计新源失败',
    );
    await gen.dispose();
    proxies.remove(gen);

    final deadlineLogs = <String>[];
    final deadlineProxy = LocalHlsProxy(
      prefetchCount: 0,
      playlistRefreshInterval: Duration.zero,
      platformRefreshTimeout: const Duration(milliseconds: 60),
      log: deadlineLogs.add,
    );
    proxies.add(deadlineProxy);
    final local = await deadlineProxy.proxy(
      root,
      <String, String>{},
      refreshPlay: () async => root,
    );
    final original = await _getText(client, local);
    slow = true;
    final watch = Stopwatch()..start();
    await deadlineProxy.refreshPlaylists();
    check(watch.elapsedMilliseconds < 200, '总刷新期限限制整个阶段');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    check(!deadlineLogs.any((line) => line.contains('签名已刷新')), '超时操作稍后返回也不提交');
    check(await _getText(client, local) == original, '超时后旧播放列表保持不变');
    await deadlineProxy.dispose();
    proxies.remove(deadlineProxy);
  } finally {
    await server.close(force: true);
  }
}

Future<void> _testLru(
  _Origin origin,
  List<LocalHlsProxy> proxies,
  HttpClient client,
) async {
  print('\n[6] 缓存上限（LRU 淘汰）');
  origin.resetStats();
  final proxy = LocalHlsProxy(
    prefetchCount: 0,
    cacheLimitBytes: 150 * 1024,
    playlistRefreshInterval: const Duration(minutes: 5),
    log: _ignore,
  );
  proxies.add(proxy);
  final local = await proxy.proxy(
    '${origin.base}/prefetch.m3u8',
    <String, String>{},
  );
  final media = await _getText(client, local);
  final segs = _httpLines(media);
  for (var i = 0; i < 3; i++) {
    await _getBytes(client, segs[i]);
  }
  check(proxy.cacheBytes <= 150 * 1024, '缓存字节不超过上限 (${proxy.cacheBytes})');
  check(proxy.cacheEntryCount <= 2, '旧分片被 LRU 淘汰');
}

Future<void> _testTempSpoolAndDispose(
  _Origin origin,
  List<LocalHlsProxy> proxies,
  HttpClient client,
) async {
  print('\n[7] 临时文件拼装 + dispose 清理/关闭服务');
  origin.resetStats();
  final proxy = LocalHlsProxy(
    prefetchCount: 0,
    spoolThresholdBytes: 64 * 1024,
    playlistRefreshInterval: const Duration(minutes: 5),
    log: _ignore,
  );
  proxies.add(proxy);
  final local = await proxy.proxy(
    '${origin.base}/media.m3u8',
    <String, String>{},
  );
  final media = await _getText(client, local);
  final first = _httpLines(media).first;
  final bytes = await _getBytes(client, first);
  check(_bytesEqual(bytes, origin.segmentBytes(0)), '大分片经临时文件拼装后内容正确');
  final tempPath = proxy.tempDirPath;
  check(tempPath != null && Directory(tempPath).existsSync(), '代理持有临时目录');
  final port = proxy.port;
  await proxy.dispose();
  check(
    tempPath == null || !Directory(tempPath).existsSync(),
    'dispose 删除临时文件目录',
  );
  var refused = false;
  try {
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/health'));
    final res = await req.close();
    await res.drain<void>();
  } catch (_) {
    refused = true;
  }
  check(refused, 'dispose 后本地端口已关闭');
  proxies.remove(proxy);
}

// ----------------------------------------------------------------- helpers

Future<Uint8List> _getBytes(HttpClient client, String url) async {
  final request = await client.getUrl(Uri.parse(url));
  final response = await request.close();
  if (response.statusCode < 200 || response.statusCode >= 400) {
    await response.drain<void>();
    throw StateError('GET $url -> HTTP ${response.statusCode}');
  }
  return _readAll(response);
}

Future<String> _getText(HttpClient client, String url) async {
  final bytes = await _getBytes(client, url);
  return utf8.decode(bytes, allowMalformed: true);
}

Future<Uint8List> _readAll(HttpClientResponse response) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in response) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

List<String> _httpLines(String playlist) {
  return const LineSplitter()
      .convert(playlist)
      .map((line) => line.trim())
      .where(
        (line) => line.startsWith('http://127.0.0.1') && !line.startsWith('#'),
      )
      .toList();
}

String _firstUriAttribute(String playlist, String tag) {
  for (final line in const LineSplitter().convert(playlist)) {
    if (!line.startsWith(tag)) continue;
    final match = RegExp(r'''URI="([^"]+)"''').firstMatch(line);
    if (match != null) return match.group(1)!;
  }
  throw StateError('缺少 $tag 的 URI');
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void _ignore(String message) {}

Uint8List _makeBytes(int length, int seed) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (seed * 31 + i * 7) % 251;
  }
  return bytes;
}

class _Origin {
  _Origin._(this.server);

  final HttpServer server;
  final Map<int, Uint8List> _segments = <int, Uint8List>{};
  final Map<int, int> _segmentSizes = <int, int>{
    0: 2 * 1024 * 1024,
    1: 300 * 1024,
    2: 300 * 1024,
  };
  late final Uint8List blob = _makeBytes(300000, 11);
  late final Uint8List keyBytes = _makeBytes(16, 5);
  late final Uint8List initBytes = _makeBytes(1024, 9);

  int issued = 0;
  int accepted = 0;
  int masterRequests = 0;
  int playlistRequests = 0;
  int segmentRequests = 0;
  int keyRequests = 0;
  int fyRequests = 0;
  int movieBytesSent = 0;
  int rangeRequests = 0;
  int forbidden = 0;
  int activeSegmentGets = 0;
  int maxConcurrentSegmentGets = 0;

  String get base => 'http://127.0.0.1:${server.port}';

  static Future<_Origin> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = _Origin._(server);
    server.listen(origin._handle);
    return origin;
  }

  void resetStats() {
    masterRequests = 0;
    playlistRequests = 0;
    segmentRequests = 0;
    keyRequests = 0;
    fyRequests = 0;
    movieBytesSent = 0;
    rangeRequests = 0;
    forbidden = 0;
    activeSegmentGets = 0;
    maxConcurrentSegmentGets = 0;
  }

  void expireTokens() {
    accepted = -1;
  }

  Uint8List segmentBytes(int index) {
    return _segments.putIfAbsent(
      index,
      () => _makeBytes(_segmentSizes[index] ?? 64 * 1024, index + 1),
    );
  }

  Future<void> close() => server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    try {
      final path = request.uri.path;
      switch (path) {
        case '/master.m3u8':
          masterRequests++;
          await _text(request, '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
media.m3u8?token=${issued + 1}
''');
          break;
        case '/media.m3u8':
          await _mediaPlaylist(request, _mediaBody);
          break;
        case '/prefetch.m3u8':
          await _text(request, _prefetchBody);
          break;
        case '/range.m3u8':
          await _text(request, _rangeBody);
          break;
        case '/api/iqiyi.m3u8':
        case '/api/fyplay':
        case '/rotating.m3u8':
          await _mediaPlaylist(request, _rotatingBody);
          break;
        case '/fyplay':
          fyRequests++;
          await _text(request, _wrapperBody);
          break;
        case '/movie.mp4':
          await _serveMovie(request);
          break;
        case '/key.bin':
          keyRequests++;
          await _serveBytes(request, keyBytes, 'application/octet-stream');
          break;
        case '/init.mp4':
          await _serveBytes(request, initBytes, 'video/mp4');
          break;
        case '/blob.bin':
          await _serveBytes(request, blob, 'video/mp2t');
          break;
        default:
          if (path.startsWith('/seg/') || path.startsWith('/small/')) {
            final raw = path.startsWith('/small/')
                ? path.substring('/small/'.length)
                : path.substring('/seg/'.length);
            final index = int.tryParse(raw.split('.').first);
            if (index == null || index < 0 || index > 200) {
              await _status(request, 404);
              return;
            }
            await _serveSegment(request, index);
            return;
          }
          await _status(request, 404);
      }
    } catch (error) {
      try {
        await _status(request, 500);
      } catch (_) {}
      stderr.writeln('origin error: $error');
    }
  }

  Future<void> _mediaPlaylist(
    HttpRequest request,
    String Function(int token) body,
  ) async {
    playlistRequests++;
    final token = ++issued;
    accepted = token;
    await _text(request, body(token));
  }

  String _mediaBody(int token) =>
      '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x00000000000000000000000000000001
#EXT-X-MAP:URI="init.mp4"
#EXTINF:10,
seg/0.ts?token=$token
#EXTINF:10,
seg/1.ts?token=$token
#EXTINF:10,
seg/2.ts?token=$token
#EXT-X-ENDLIST
''';

  String _rotatingBody(int token) =>
      '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:10,
seg/10.ts?token=$token
#EXTINF:10,
seg/11.ts?token=$token
#EXT-X-ENDLIST
''';

  String get _prefetchBody {
    final buffer = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:3')
      ..writeln('#EXT-X-TARGETDURATION:10')
      ..writeln('#EXT-X-MEDIA-SEQUENCE:0');
    for (var i = 0; i < 6; i++) {
      buffer
        ..writeln('#EXTINF:10,')
        ..writeln('small/${100 + i}.ts');
    }
    buffer.writeln('#EXT-X-ENDLIST');
    return buffer.toString();
  }

  String get _wrapperBody => '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:10,
seg/100.ts
#EXTINF:10,
seg/101.ts
#EXT-X-ENDLIST
''';

  String get _rangeBody => '''
#EXTM3U
#EXT-X-VERSION:4
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-BYTERANGE:100000@50000
blob.bin
#EXT-X-BYTERANGE:50000@150000
blob.bin
#EXT-X-ENDLIST
''';

  Future<void> _serveSegment(HttpRequest request, int index) async {
    final token = int.tryParse(request.uri.queryParameters['token'] ?? '');
    segmentRequests++;
    activeSegmentGets++;
    maxConcurrentSegmentGets = math.max(
      maxConcurrentSegmentGets,
      activeSegmentGets,
    );
    try {
      if (token != null && token != accepted) {
        forbidden++;
        await _status(request, 403);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await _serveBytes(request, segmentBytes(index), 'video/mp2t');
    } finally {
      activeSegmentGets--;
    }
  }

  Future<void> _serveBytes(
    HttpRequest request,
    Uint8List bytes,
    String contentType,
  ) async {
    final response = request.response;
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.set(HttpHeaders.contentTypeHeader, contentType);
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    var start = 0;
    var end = bytes.length - 1;
    var partial = false;
    if (rangeHeader != null) {
      final match = RegExp(
        r'^bytes=(\d+)-(\d*)$',
      ).firstMatch(rangeHeader.trim());
      if (match != null) {
        start = int.parse(match.group(1)!);
        if (match.group(2)!.isNotEmpty) {
          end = math.min(int.parse(match.group(2)!), bytes.length - 1);
        }
        if (start >= bytes.length) {
          response.statusCode = 416;
          await response.close();
          return;
        }
        partial = true;
        rangeRequests++;
      }
    }
    final body = Uint8List.sublistView(bytes, start, end + 1);
    response.statusCode = partial ? 206 : 200;
    if (partial) {
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${bytes.length}',
      );
    }
    response.contentLength = body.length;
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    response.add(body);
    await response.close();
  }

  Future<void> _serveMovie(HttpRequest request) async {
    final response = request.response;
    response.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
    response.headers.set(HttpHeaders.contentLengthHeader, '${8 * 1024 * 1024}');
    final chunk = Uint8List(64 * 1024);
    for (var i = 0; i < 128; i++) {
      if (request.method == 'HEAD') break;
      response.add(chunk);
      movieBytesSent += chunk.length;
      if (i == 0) await response.flush();
    }
    await response.close();
  }

  Future<void> _text(HttpRequest request, String text) async {
    final body = utf8.encode(text);
    final response = request.response;
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/vnd.apple.mpegurl',
    );
    response.contentLength = body.length;
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    response.add(body);
    await response.close();
  }

  Future<void> _status(HttpRequest request, int status) async {
    request.response.statusCode = status;
    await request.response.close();
  }
}

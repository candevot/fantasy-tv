// HLS 清单索引 / 分片校验验证（纯 Dart，不依赖 Flutter）：
//   /root/dartsdk-arm64/dart-sdk/bin/dart tools/test_hls_segment_index.dart
//
// 覆盖：master → 媒体 playlist 解析、#EXTINF 累加建索引、#EXT-X-BYTERANGE、
// 二分定位当前分片、分片大小不符 → 回源直连、源站 500 → 判失败、
// 本地代理地址还原成源站地址。
import 'dart:io';

import '../lib/services/hls_segment_index.dart';

int _passed = 0;

void check(bool condition, String message) {
  if (!condition) throw StateError('FAIL: $message');
  _passed++;
  print('  ok - $message');
}

const String _mediaPlaylist = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:6.000,
seg00001.ts
#EXTINF:6.000,
seg00002.ts
#EXTINF:4.500,
seg00003.ts
#EXTINF:6.000,
seg00004.ts
#EXT-X-ENDLIST
''';

const String _masterPlaylist = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080
high/index.m3u8
''';

Future<void> main() async {
  print('HLS 时间索引');
  final base = Uri.parse('https://cdn.example.com/vod/ep01/index.m3u8');
  final segments = HlsSegmentIndex.parseMediaPlaylist(_mediaPlaylist, base);
  check(segments.length == 4, '解析出 4 个分片');
  check(segments[0].startMs == 0 && segments[0].durationMs == 6000,
      '第 1 片起点 0ms / 时长 6000ms');
  check(segments[1].startMs == 6000, '第 2 片起点 6000ms');
  check(segments[2].startMs == 12000 && segments[2].durationMs == 4500,
      '第 3 片 12000ms / 4500ms（非整秒）');
  check(segments[3].startMs == 16500, '第 4 片起点 16500ms');
  check(segments[0].uri.toString() == 'https://cdn.example.com/vod/ep01/seg00001.ts',
      '相对路径按清单地址解析成绝对地址');

  final index = HlsPlaylistIndex(playlist: base, segments: segments);
  check(index.totalDurationMs == 22500, '总时长 22500ms');
  check(index.segmentAt(const Duration(milliseconds: 0))?.startMs == 0,
      '0ms 命中第 1 片');
  check(index.segmentAt(const Duration(milliseconds: 5999))?.startMs == 0,
      '5999ms 仍命中第 1 片');
  check(index.segmentAt(const Duration(milliseconds: 6000))?.startMs == 6000,
      '6000ms 命中第 2 片');
  check(index.segmentAt(const Duration(seconds: 15))?.startMs == 12000,
      '15s 命中第 3 片');
  check(index.segmentAt(const Duration(seconds: 99))?.startMs == 16500,
      '超出总时长按最后一片');

  print('BYTERANGE / 空清单');
  final ranged = HlsSegmentIndex.parseMediaPlaylist(
    '#EXTM3U\n#EXTINF:6.0,\n#EXT-X-BYTERANGE:96256@0\nmain.ts\n'
    '#EXTINF:6.0,\n#EXT-X-BYTERANGE:80000\nmain.ts\n',
    base,
  );
  check(ranged.length == 2, 'BYTERANGE 清单解析出 2 片');
  check(ranged[0].declaredBytes == 96256, '第 1 片声明 96256B');
  check(ranged[1].declaredBytes == 80000 && ranged[1].startMs == 6000,
      '第 2 片声明 80000B 且起点正确');
  check(HlsSegmentIndex.parseMediaPlaylist('', base).isEmpty, '空清单返回空索引');

  print('本地代理地址 → 源站地址');
  final local = Uri.parse(
    'http://127.0.0.1:9/ts.ts?url=https%3A%2F%2Fcdn.example.com%2Fseg1.ts',
  );
  check(
    HlsSegmentIndex.originUri(local).toString() == 'https://cdn.example.com/seg1.ts',
    '127.0.0.1 代理地址还原出源站地址',
  );
  final remote = Uri.parse('https://cdn.example.com/seg1.ts');
  check(HlsSegmentIndex.originUri(remote) == remote, '源站地址原样返回');

  print('分片大小校验与回源');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var mismatchHits = 0;
  var originHits = 0;
  server.listen((request) async {
    final path = request.uri.path;
    if (path == '/good.ts') {
      // 声明的总长 = 实收，正常。
      final body = List<int>.filled(2048, 7);
      request.response.headers.set('Content-Range', 'bytes 0-2047/2048');
      request.response.statusCode = 206;
      request.response.contentLength = body.length;
      request.response.add(body);
    } else if (path == '/short.ts') {
      // 先来 1 次「说 4096 字节、只给 512 字节」的截断响应，
      // 回源（带 no-cache）之后给出完整分片。
      final noCache = (request.headers.value('cache-control') ?? '')
          .contains('no-cache');
      if (!noCache) {
        mismatchHits++;
        request.response.headers.set('Content-Range', 'bytes 0-4095/4096');
        request.response.statusCode = 206;
        request.response.contentLength = 512;
        request.response.add(List<int>.filled(512, 1));
      } else {
        originHits++;
        final body = List<int>.filled(4096, 1);
        request.response.headers.set('Content-Range', 'bytes 0-4095/4096');
        request.response.statusCode = 206;
        request.response.contentLength = body.length;
        request.response.add(body);
      }
    } else {
      request.response.statusCode = 500;
    }
    await request.response.close();
  });
  final port = server.port;

  final goodRef = HlsSegmentRef(
    uri: Uri.parse('http://127.0.0.1:$port/good.ts'),
    startMs: 0,
    durationMs: 6000,
  );
  final goodProbe = await HlsSegmentIndex.instance.verify(goodRef, headers: {});
  check(goodProbe.result == HlsSegmentCheck.ok, '大小一致判 ok');
  check(!goodProbe.fromOrigin, '大小一致不需要回源');

  final shortRef = HlsSegmentRef(
    uri: Uri.parse('http://127.0.0.1:$port/short.ts'),
    startMs: 0,
    durationMs: 6000,
  );
  final shortProbe = await HlsSegmentIndex.instance.verify(shortRef, headers: {});
  check(shortProbe.result == HlsSegmentCheck.ok, '回源之后拿到完整分片判 ok');
  check(mismatchHits >= 1, '第一次请求被识别为截断（触发了回源）');
  check(originHits >= 1, '回源请求带了 no-cache');
  check(shortProbe.fromOrigin, '结果标记为「回源取得」');

  final badRef = HlsSegmentRef(
    uri: Uri.parse('http://127.0.0.1:$port/missing.ts'),
    startMs: 0,
    durationMs: 6000,
  );
  final badProbe = await HlsSegmentIndex.instance.verify(badRef, headers: {});
  check(badProbe.result != HlsSegmentCheck.ok, '源站 500 时判失败');

  print('清单索引缓存');
  final indexServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final indexPort = indexServer.port;
  var playlistHits = 0;
  indexServer.listen((request) async {
    final path = request.uri.path;
    if (path.endsWith('master.m3u8')) {
      request.response.write(_masterPlaylist);
    } else if (path.endsWith('low/index.m3u8')) {
      playlistHits++;
      request.response.write(_mediaPlaylist);
    } else {
      request.response.statusCode = 404;
    }
    await request.response.close();
  });
  final masterUrl = 'http://127.0.0.1:$indexPort/master.m3u8';
  final built = await HlsSegmentIndex.instance.indexOf(masterUrl, {});
  check(built != null, 'master 清单能建出索引');
  check(built!.segments.length == 4, 'master 下游走到第一个变体（4 片）');
  check(built.totalDurationMs == 22500, '索引总时长正确');
  check(playlistHits == 1, '只拉了 1 次子清单');
  final again = await HlsSegmentIndex.instance.indexOf(masterUrl, {});
  check(identical(again, built), '第二次直接命中缓存，不再请求');
  check(playlistHits == 1, '缓存命中后子清单仍只拉过 1 次');

  await server.close(force: true);
  await indexServer.close(force: true);
  print('全部通过：$_passed 项');
}

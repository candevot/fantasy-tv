/// 线路健康预检的回归（PROBE 2026-11-15）。
///
/// 用本机 HTTP mock 源站把三级预检逐条钉住 —— 预检判错的后果是用户视角的
/// 「本来能播的线路被跳过了」或「坏线路一直转圈」，两种都不能靠肉眼验：
///
/// ```
/// ① 能连上（TCP / TLS 不断）
/// ② 清单 HTTP 2xx 且是 #EXTM3U 且有分片
/// ③ 第一个分片能下到至少 1 个字节
/// ```
///
/// 跑法：`dart run tools/test_line_probe.dart`（纯 dart:io，不需要 Flutter SDK）
library;

import 'dart:async';
import 'dart:io';

import '../lib/services/fallback_match.dart';
import '../lib/services/line_probe.dart';
import '../lib/services/playback_progress.dart';

var _checks = 0;

void _check(bool ok, String name) {
  if (!ok) {
    throw StateError(name);
  }
  _checks++;
  print('PASS $name');
}

/// 本地 mock 源站：好线路 / 慢线路（200KB/s）/ 404 / 不是 m3u8 / 0 分片。
Future<HttpServer> _startOrigin() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final path = request.uri.path;
    final response = request.response;
    Future<void> sendText(String text, {int status = 200}) async {
      response.statusCode = status;
      response.headers.contentType = ContentType(
        'application',
        'vnd.apple.mpegurl',
        charset: 'utf-8',
      );
      response.write(text);
      await response.close();
    }

    // 按 200KB/s 吐：8KB / 40ms。
    Future<void> sendSlow(List<int> bytes) async {
      response.statusCode = 200;
      response.headers.contentType = ContentType('video', 'mp2t');
      response.contentLength = bytes.length;
      for (var offset = 0; offset < bytes.length; offset += 8192) {
        final end = offset + 8192 > bytes.length ? bytes.length : offset + 8192;
        response.add(bytes.sublist(offset, end));
        await response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      await response.close();
    }

    switch (path) {
      case '/ok/master.m3u8':
        await sendText(
          '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720\n'
          'index.m3u8\n',
        );
      case '/ok/index.m3u8':
        await sendText(
          '#EXTM3U\n'
          '#EXT-X-TARGETDURATION:4\n'
          '#EXTINF:4.0,\n'
          'seg0.ts\n'
          '#EXTINF:4.0,\n'
          'seg1.ts\n'
          '#EXTINF:4.0,\n'
          'seg2.ts\n'
          '#EXT-X-ENDLIST\n',
        );
      case '/ok/seg0.ts':
      case '/ok/seg1.ts':
      case '/ok/seg2.ts':
        await sendSlow(List<int>.filled(32768, 7));
      case '/slow/index.m3u8':
        await sendText(
          '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\nseg0.ts\n'
          '#EXT-X-ENDLIST\n',
        );
      case '/slow/seg0.ts':
        // 256KB @200KB/s ≈ 1.3 秒。
        await sendSlow(List<int>.filled(256 * 1024, 9));
      case '/notm3u8.m3u8':
        await sendText('<html>nope</html>');
      case '/empty.m3u8':
        await sendText('#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-ENDLIST\n');
      default:
        await sendText('not found', status: 404);
    }
  });
  return server;
}

Future<void> main() async {
  final server = await _startOrigin();
  final base = 'http://127.0.0.1:${server.port}';
  try {
    // ① 健康线路：三级全过，最终 stage=segment。
    final ok = await probeLine('$base/ok/master.m3u8');
    _check(ok.ok, '健康线路：三项全过');
    _check(ok.stage == FxProbeStage.segment, '健康线路：stage=segment');
    _check(ok.segments == 3, '健康线路：清单里数到 3 个分片');
    _check(ok.elapsed < fxProbeTotalBudget, '健康线路：在 8 秒预算内');

    // ② 404：真失败，**立即**返回（不等任何窗口）。
    final watch = Stopwatch()..start();
    final dead = await probeLine('$base/404.m3u8');
    watch.stop();
    _check(!dead.ok, '404：预检失败');
    _check(dead.stage == FxProbeStage.manifest, '404：卡在清单阶段');
    _check(dead.httpStatus == 404, '404：状态码原样带回');
    _check(dead.reason == 'http_404', '404：reason=http_404');
    _check(
      watch.elapsed < const Duration(seconds: 2),
      '404：立即失败（不拖到 8 秒）',
    );

    // ③ 不是 m3u8：清单非法。
    final notM3u8 = await probeLine('$base/notm3u8.m3u8');
    _check(!notM3u8.ok, '非 m3u8：预检失败');
    _check(
      notM3u8.failureCode == 'manifest_invalid',
      '非 m3u8：失败码 manifest_invalid',
    );

    // ④ 0 个分片：也算线路坏了（拿得到清单但没内容）。
    final empty = await probeLine('$base/empty.m3u8');
    _check(!empty.ok, '0 分片：预检失败');
    _check(empty.failureCode == 'no_segments', '0 分片：失败码 no_segments');

    // ⑤ 慢线路（200KB/s）：不是坏线路 —— 预检必须放过它。
    final slow = await probeLine('$base/slow/index.m3u8');
    _check(slow.ok, '200KB/s 慢线路：预检通过（慢不是坏）');
    _check(
      slow.elapsed < fxProbeTotalBudget,
      '200KB/s 慢线路：仍在 8 秒预算内',
    );

    // ⑥ 纯流量档：只探清单，不探分片（省流量）。
    final manifestOnly = await probeLine(
      '$base/slow/index.m3u8',
      manifestOnly: true,
    );
    _check(manifestOnly.ok, '只探清单：通过');
    _check(
      manifestOnly.stage == FxProbeStage.manifest,
      '只探清单：stage=manifest（没下分片）',
    );

    // ⑦ DNS 失败：真失败，错误分类要准（不是「网慢」）。
    final dns = await probeLine('http://no-such-host.invalid/index.m3u8');
    _check(!dns.ok, 'DNS 失败：预检失败');
    _check(
      dns.failureCode == 'dns_error' ||
          dns.failureCode == 'connect_refused' ||
          dns.reason == FxProbeReason.timeout,
      'DNS 失败：归到 dns_error / connect_refused',
    );

    // ⑧ 失败原因词表：和原生 fatalError 用同一套码（页面日志的 reason=）。
    _check(
      fxOpenFailReason(elapsedMs: 120, error: '线路预检失败(http_404)') ==
          'http_404',
      '失败码：预检失败原样报回 http_404',
    );
    _check(
      fxOpenFailReason(elapsedMs: 30000, error: '慢网超时(30s)') ==
          'slow_network',
      '失败码：慢网超时归 slow_network（不是卡死）',
    );
  } finally {
    await server.close(force: true);
  }
  print('ALL PASS ($_checks checks)');
}

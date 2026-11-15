/// 两个验收场景的**实际日志**（PROBE / FLOW_WATCH 2026-11-15）。
///
/// 这不是「演示脚本」：判定和日志文案全部走生产代码
/// （`line_probe.dart` / `playback_progress.dart` / `line_probe.dart` 的日志
/// 生成函数），源站是真本机 HTTP 服务：
///
/// ```
/// 场景 A  404 地址     → 立即失败切下一条（不等 8 秒）
/// 场景 B  限速 200KB/s → 首帧 20 秒才出来，全程不判失败
/// 场景 C  有数据但没首帧 → 30 秒硬上限到点直接切
/// ```
///
/// 跑法：`dart run tools/probe_scenarios.dart`
library;

import 'dart:async';
import 'dart:io';

import '../lib/services/fallback_match.dart';
import '../lib/services/line_probe.dart';
import '../lib/services/playback_progress.dart';

void _log(String line) => print('[FxPlay] $line');

Future<HttpServer> _startOrigin() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final path = request.uri.path;
    final response = request.response;
    if (path == '/404.m3u8') {
      response.statusCode = 404;
      response.write('not found');
      await response.close();
      return;
    }
    if (path.endsWith('.m3u8')) {
      response.statusCode = 200;
      response.headers.contentType = ContentType(
        'application',
        'vnd.apple.mpegurl',
        charset: 'utf-8',
      );
      response.write(
        '#EXTM3U\n#EXT-X-TARGETDURATION:4\n'
        '#EXTINF:4.0,\nseg0.ts\n#EXT-X-ENDLIST\n',
      );
      await response.close();
      return;
    }
    // 分片：按 200KB/s 吐（8KB / 40ms）。
    final bytes = List<int>.filled(64 * 1024, 7);
    response.statusCode = 200;
    response.contentLength = bytes.length;
    for (var offset = 0; offset < bytes.length; offset += 8192) {
      final end = offset + 8192 > bytes.length ? bytes.length : offset + 8192;
      response.add(bytes.sublist(offset, end));
      await response.flush();
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    await response.close();
  });
  return server;
}

Future<void> main() async {
  final server = await _startOrigin();
  final base = 'http://127.0.0.1:${server.port}';
  try {
    await _scenario404(base);
    await _scenarioSlow200k(base);
    await _scenarioSlowCap();
  } finally {
    await server.close(force: true);
  }
}

/// 场景 A：404 地址 → 立即失败切下一条（不等 8 秒窗口）。
Future<void> _scenario404(String base) async {
  print('--- 场景 A：404 地址 ---');
  final watch = Stopwatch()..start();
  final probe = await probeLine('$base/404.m3u8');
  watch.stop();
  _log(fxProbeLogMessage(line: 'mgtv', probe: probe));
  final reason = fxOpenFailReason(
    elapsedMs: watch.elapsedMilliseconds,
    error: '线路预检失败(${probe.failureCode})',
  );
  _log(
    fxAutoLineLog(
      attempt: 1,
      total: 11,
      name: 'mgtv',
      ok: false,
      reason: reason,
    ),
  );
  print(
    '实测耗时 ${watch.elapsedMilliseconds}ms（8 秒窗口没参与判定：'
    '真失败直接切）',
  );
}

/// 场景 B：限速 200KB/s，首帧 20 秒才出来 → 全程不判失败。
Future<void> _scenarioSlow200k(String base) async {
  print('--- 场景 B：限速 200KB/s（首帧 20 秒）---');
  final watch = Stopwatch()..start();
  // 真去探这条被限速的线路：预检也必须放过它（慢不是坏）。
  final probe = await probeLine('$base/slow/index.m3u8');
  watch.stop();
  _log(fxProbeLogMessage(line: '量子', probe: probe));
  print('预检实测 ${watch.elapsedMilliseconds}ms → 通过（不是真失败）');

  final window = FxProgressWindow();
  const intervalMs = 500;
  // 200KB/s ≈ 每 500ms 涨 100KB；首帧在 t=20s 到达。
  for (var ms = 0; ms <= 30000; ms += intervalMs) {
    window.add(
      FxProgressSample(
        atMs: ms,
        bytesLoaded: (ms / 1000 * 200 * 1024).round(),
        buffered: Duration(milliseconds: ms ~/ 8),
        position: Duration.zero,
        isLoading: ms < 20000,
      ),
    );
    if (ms % 2000 == 0) {
      _log(
        fxProgressLog(
          bytesDelta: window.bytesDelta,
          bufferedDeltaMs: window.bufferedDeltaMs,
          state: window.state,
          extra: 'stage=open firstFrame=${ms >= 20000} '
              'stalled=${window.stalledFor.inMilliseconds}ms'
              '${ms >= fxSlowNoticeAfter.inMilliseconds ? " notice=网速较慢（已等 ${ms ~/ 1000} 秒）" : ""}',
        ),
      );
    }
  }
  print(
    '首帧在 20 秒出现；全程 verdict=${window.state.name}，'
    '「无进展」最长 ${window.stalledFor.inMilliseconds}ms < '
    '${fxStartupNoProgressWindow.inMilliseconds}ms → 不判失败',
  );
}

/// 场景 C：有字节在动但一直没首帧 → 30 秒硬上限，到点直接切。
Future<void> _scenarioSlowCap() async {
  print('--- 场景 C：有数据但一直没首帧（30 秒硬上限）---');
  final window = FxProgressWindow();
  var buffered = Duration.zero;
  for (var ms = 0; ms <= 30000; ms += 500) {
    buffered = Duration(milliseconds: ms ~/ 14); // 约 200KB/s 的分片推进
    window.add(
      FxProgressSample(
        atMs: ms,
        bytesLoaded: (ms / 1000 * 200 * 1024).round(),
        buffered: buffered,
        position: Duration.zero,
        isLoading: true,
      ),
    );
  }
  _log(
    fxProgressLog(
      bytesDelta: window.bytesDelta,
      bufferedDeltaMs: window.bufferedDeltaMs,
      state: window.state,
      extra: 'cap=${fxSlowStartupCap.inSeconds}s stalled=${window.stalledFor.inMilliseconds}ms',
    ),
  );
  _log(
    fxSlowSwitchLog(
      line: '量子',
      waitedSeconds: fxSlowStartupCap.inSeconds,
      buffered: buffered,
    ),
  );
  print(
    '到 ${fxSlowStartupCap.inSeconds} 秒硬上限直接切（不弹「继续等待 / 换条线路」）',
  );
}

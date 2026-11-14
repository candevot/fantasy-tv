import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tools/test_hls_segment_index.dart' as hlsIndex;
import '../tools/test_local_hls_proxy.dart' as proxy;
import '../tools/test_playback_recovery.dart' as recovery;
import '../tools/test_together_sync.dart' as sync;

void main() {
  // HLS 代理测试需要真实的本机 mock 源站。flutter_test 一旦初始化 widget
  // 绑定就会装上 HttpOverrides，把所有 HttpClient 请求拦成 400；这里显式
  // 清掉它，保证三个用例都在真实网络栈上跑。
  setUp(() {
    HttpOverrides.global = null;
  });

  test(
    'HLS retries, signature rotation and stable child aliases',
    () async {
      HttpOverrides.global = null;
      await proxy.main();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test('HLS manifest index, segment size check and origin fallback',
      hlsIndex.main);
  test('recovery protects progress and verifies seek landing', recovery.main);
  test('room member drift, stall hold and offline synchronization', sync.main);
}

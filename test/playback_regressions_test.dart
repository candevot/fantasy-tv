import 'package:flutter_test/flutter_test.dart';

import '../tools/test_local_hls_proxy.dart' as proxy;
import '../tools/test_playback_recovery.dart' as recovery;
import '../tools/test_together_sync.dart' as sync;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'HLS retries, signature rotation and stable child aliases',
    () async {
      await proxy.main();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test('recovery protects progress and verifies seek landing', recovery.main);
  test('room member drift, stall hold and offline synchronization', sync.main);
}

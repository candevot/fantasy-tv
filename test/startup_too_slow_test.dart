// TOO_SLOW（2026-11-22 真机）：字节在动但慢到 0.4 KB/s 的线路必须判死。
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/services/playback_progress.dart';

void main() {
  test('观察期内的慢不算数（刚建连不能被误杀）', () {
    expect(
      fxStartupTooSlow(
        elapsed: const Duration(seconds: 5),
        bytesLoaded: 0,
      ),
      isFalse,
    );
  });

  test('12 秒后 0.4 KB/s 判太慢', () {
    expect(
      fxStartupTooSlow(
        elapsed: const Duration(seconds: 12),
        bytesLoaded: (0.4 * 1024 * 12).round(),
      ),
      isTrue,
    );
  });

  test('12 秒后 2 MB（约 170 KB/s）不算慢', () {
    expect(
      fxStartupTooSlow(
        elapsed: const Duration(seconds: 12),
        bytesLoaded: 2 * 1024 * 1024,
      ),
      isFalse,
    );
  });

  test('零字节 12 秒也算太慢', () {
    expect(
      fxStartupTooSlow(elapsed: const Duration(seconds: 13), bytesLoaded: 0),
      isTrue,
    );
  });
}

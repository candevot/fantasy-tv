// STALL_FROM_START（2026-11-22 真机）：从第一个字节就没到的线路必须能判死。
//
// 真机症状：点咕噜线路 → 0 KB/s 一直转，切别的线路也没反应，失败不自动切。
// 根因是 FxProgressWindow.stalledFor 在「一次都没动过」时返回 0，
// 8 秒判死形同虚设，只能等 30 秒慢网硬上限（再叠加 2 次重解析 = 60~90 秒）。
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/services/playback_progress.dart';

void main() {
  test('零字节从开始就停：stalledFor 按第一次采样起算', () {
    final w = FxProgressWindow(window: const Duration(seconds: 8));
    for (var ms = 0; ms <= 10000; ms += 500) {
      w.add(FxProgressSample(
        atMs: ms,
        bytesLoaded: 0,
        buffered: Duration.zero,
        position: Duration.zero,
        isLoading: true,
      ));
    }
    expect(w.stalledFor.inMilliseconds, greaterThanOrEqualTo(8000));
    expect(w.state, FxProgressState.stuck);
  });

  test('中间有过进展就不算卡死', () {
    final w = FxProgressWindow(window: const Duration(seconds: 8));
    for (var ms = 0; ms <= 10000; ms += 500) {
      w.add(FxProgressSample(
        atMs: ms,
        // 每秒都在涨：不能判死
        bytesLoaded: ms * 100,
        buffered: Duration(milliseconds: ms),
        position: Duration.zero,
        isLoading: true,
      ));
    }
    expect(w.stalledFor.inMilliseconds, lessThan(8000));
    expect(w.state, isNot(FxProgressState.stuck));
  });
}

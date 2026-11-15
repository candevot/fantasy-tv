import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/services/exo_player.dart';
import 'package:fantasy_tv/widgets/player_theme.dart';

/// 实时网速文案的回归（NET_SPEED 2026-11-15）。
///
/// 用户实测：缓冲时转圈下面一直显示「0 KB/s」，从来没变过。根因在原生
/// （`PlayerHttp` 把「窗口起点快照」和「本窗口新增字节」用同一个计数器，
/// 差值恒 0），原生已经改成 media3 官方的按块回调 + 每秒增量，这里钉住
/// Dart 这一侧不再把它丢掉：字段要读进来、文案要按要求格式化。
void main() {
  group('fxSpeedLabel', () {
    test('0 必须显示「0 KB/s」，不能返回空串', () {
      expect(fxSpeedLabel(0), '0 KB/s');
      expect(fxSpeedLabel(-1), '0 KB/s');
      expect(fxSpeedLabel(double.nan), '0 KB/s');
    });

    test('小于 1 KB/s 也保留一位小数，不再是「<1 KB/s」', () {
      expect(fxSpeedLabel(300), '0.3 KB/s');
      expect(fxSpeedLabel(1023), '1.0 KB/s');
    });

    test('KB 档：10 以上取整（320 KB/s），10 以下带一位小数', () {
      expect(fxSpeedLabel(320 * 1024), '320 KB/s');
      expect(fxSpeedLabel(3.5 * 1024), '3.5 KB/s');
      expect(fxSpeedLabel(1024), '1.0 KB/s');
    });

    test('MB 档保留一位小数（1.8 MB/s）', () {
      expect(fxSpeedLabel(1.8 * 1024 * 1024), '1.8 MB/s');
      expect(fxSpeedLabel(12 * 1024 * 1024), '12.0 MB/s');
      // 1023.9 KB 还没到 1 MB，不能提前进位成「1.0 MB/s」。
      expect(fxSpeedLabel(1023.9 * 1024), '1024 KB/s');
    });
  });

  group('ExoPlayerState.fromMap', () {
    test('bytesLoaded / bytesLoadedPerSec 要读进快照（不能被丢掉）', () {
      final s = ExoPlayerState.fromMap(<String, dynamic>{
        'bytesLoaded': 7340032,
        'bytesLoadedPerSec': 1887436,
        'isLoading': true,
        'buffering': true,
      });
      expect(s.bytesLoaded, 7340032);
      expect(s.bytesLoadedPerSec, 1887436);
      expect(s.isLoading, true);
    });

    test('老原生包没有这两个键时退回 -1 / 0', () {
      final s = ExoPlayerState.fromMap(<String, dynamic>{});
      expect(s.bytesLoaded, -1);
      expect(s.bytesLoadedPerSec, 0);
      expect(s.isLoading, true);
    });
  });
}

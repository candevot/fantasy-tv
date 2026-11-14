import 'package:flutter/services.dart';

/// 亮度 / 音量：走自建原生通道（fantasy_tv/display）。
///
/// 为什么不用插件：`screen_brightness` 的平台接口要等 Android 实现先注册、
/// `volume_controller` 每次调用还走一遍插件层，实测表现就是
/// 「拖亮度完全没反应、拖音量有延迟」。这里直接操作 Activity 窗口
/// 与 AudioManager，调用即生效。
class DisplayControl {
  DisplayControl._();

  static const MethodChannel _ch = MethodChannel('fantasy_tv/display');

  /// 当前窗口亮度；返回负值表示跟随系统。
  static Future<double> brightness() async {
    try {
      final v = await _ch.invokeMethod<double>('getBrightness');
      return v ?? -1;
    } catch (_) {
      return -1;
    }
  }

  /// 设置窗口亮度（0~1）。
  static Future<void> setBrightness(double value) async {
    try {
      await _ch.invokeMethod<bool>('setBrightness', <String, Object?>{
        'value': value.clamp(0.01, 1.0),
      });
    } catch (_) {}
  }

  /// 恢复系统亮度。
  static Future<void> resetBrightness() async {
    try {
      await _ch.invokeMethod<bool>('resetBrightness');
    } catch (_) {}
  }

  /// 当前媒体音量（0~1）。
  static Future<double> volume() async {
    try {
      final v = await _ch.invokeMethod<double>('getVolume');
      return v ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 设置媒体音量（0~1）。`flags=0`，不弹系统音量条。
  static Future<void> setVolume(double value) async {
    try {
      await _ch.invokeMethod<bool>('setVolume', <String, Object?>{
        'value': value.clamp(0.0, 1.0),
      });
    } catch (_) {}
  }
}

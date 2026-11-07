import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 屏幕方向控制：优先走原生 `fantasy_tv/orientation` 通道。
///
/// 为什么不用 `SystemChrome.setPreferredOrientations`：Flutter 引擎把
/// `landscapeLeft / landscapeRight` 映射成 `SCREEN_ORIENTATION_USER_LANDSCAPE`，
/// 该值**遵守系统「自动旋转」开关**——用户把系统旋转锁打开（竖屏锁定）后，
/// 播放器就转不到横屏。腾讯视频等用的是 `SENSOR_LANDSCAPE`，它不看系统
/// 旋转锁，所以「别家能转、我们不能」。
///
/// 原生通道不可用（桌面 / 旧包）时自动退回 [SystemChrome]，行为与旧版一致。
class ScreenOrientation {
  const ScreenOrientation._();

  static const MethodChannel _channel =
      MethodChannel('fantasy_tv/orientation');

  /// 进入横屏播放：SENSOR_LANDSCAPE，忽略系统旋转锁。
  static Future<void> landscape() async {
    if (!Platform.isAndroid) {
      await _fallback(const <DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      return;
    }
    try {
      await _channel.invokeMethod<void>('sensorLandscape');
    } catch (error) {
      debugPrint('ScreenOrientation: 原生横屏不可用，退回 SystemChrome: $error');
      await _fallback(const <DeviceOrientation>[
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  /// 退出播放回到竖屏。
  static Future<void> portrait() async {
    if (!Platform.isAndroid) {
      await _fallback(const <DeviceOrientation>[DeviceOrientation.portraitUp]);
      return;
    }
    try {
      await _channel.invokeMethod<void>('portrait');
    } catch (error) {
      debugPrint('ScreenOrientation: 原生竖屏不可用，退回 SystemChrome: $error');
      await _fallback(const <DeviceOrientation>[DeviceOrientation.portraitUp]);
    }
  }

  static Future<void> _fallback(List<DeviceOrientation> orientations) async {
    try {
      await SystemChrome.setPreferredOrientations(orientations);
    } catch (_) {
      // 桌面 / 模拟器不支持也无所谓。
    }
  }
}

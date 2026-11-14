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

  /// 全屏竖屏播放：`SENSOR_PORTRAIT`，系统旋转锁开着也不会被系统翻成横屏。
  ///
  /// 与 [portrait] 的区别：[portrait] 是「退出播放回竖屏」用的固定竖屏
  /// （SCREEN_ORIENTATION_PORTRAIT），全屏竖屏片用 SENSOR_PORTRAIT，
  /// 用户自己正握 / 反握手机都能正常显示。旧包的原生通道没有这个分支，
  /// 退回 [portrait]，行为与之前一致。
  static Future<void> sensorPortrait() async {
    if (!Platform.isAndroid) {
      await _fallback(const <DeviceOrientation>[DeviceOrientation.portraitUp]);
      return;
    }
    try {
      await _channel.invokeMethod<void>('sensorPortrait');
    } catch (error) {
      debugPrint(
        'ScreenOrientation: 原生 sensorPortrait 不可用，退回 portrait: $error',
      );
      await portrait();
    }
  }

  /// 全屏播放按方向定档：竖屏片锁竖屏，其余一律横屏。
  static Future<void> applyPlayback({required bool portraitMode}) {
    return portraitMode ? sensorPortrait() : landscape();
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

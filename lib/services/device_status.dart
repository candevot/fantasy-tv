import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';

/// 设备状态：电量 + 充电状态。
///
/// 全屏播放时顶栏显示（和 B站/腾讯一样，用户不用退出就能看电量）。
/// 用 ChangeNotifier 广播，多个播放页共用一份订阅。
class DeviceStatus extends ChangeNotifier {
  DeviceStatus._();
  static final DeviceStatus instance = DeviceStatus._();

  final Battery _battery = Battery();

  int _level = -1; // -1 = 未知
  bool _charging = false;
  Timer? _timer;
  StreamSubscription<BatteryState>? _sub;
  int _refs = 0;

  int get level => _level;
  bool get charging => _charging;

  /// 播放页进入时订阅，退出时释放。引用计数避免多页互相干扰。
  Future<void> attach() async {
    _refs++;
    if (_refs > 1) return;
    await _refresh();
    _sub = _battery.onBatteryStateChanged.listen((st) {
      _charging = st == BatteryState.charging || st == BatteryState.full;
      _refresh();
      notifyListeners();
    });
    // 30s 轮询一次（onBatteryStateChanged 只在充放电切换时触发，不报电量变化）
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  void detach() {
    _refs = (_refs - 1).clamp(0, 1 << 30);
    if (_refs > 0) return;
    _timer?.cancel();
    _timer = null;
    _sub?.cancel();
    _sub = null;
  }

  Future<void> _refresh() async {
    try {
      final lv = await _battery.batteryLevel;
      final st = await _battery.batteryState;
      _level = lv;
      _charging = st == BatteryState.charging || st == BatteryState.full;
      notifyListeners();
    } catch (_) {
      // 部分机型/模拟器不支持，静默忽略
    }
  }
}

import 'package:flutter/services.dart';

/// 与 CI 生成的 MainActivity 里 `fantasy_tv/cast` 通道对应。
///
/// `ACCESS_WIFI_STATE` / `CHANGE_WIFI_MULTICAST_STATE` 都是 normal 权限：
/// 安装时自动授予，没有运行时弹窗。真正需要「使用时申请」的是 Android
/// 的 MulticastLock —— 不少电视 / 路由器会过滤未持锁的组播包，SSDP 就
/// 搜不到设备。这里在每次搜索前后 acquire / release，权限缺失或非
/// Android 平台时降级为普通 UDP 搜索，不阻断投屏。
const MethodChannel _castChannel = MethodChannel('fantasy_tv/cast');

Future<T> runWithCastMulticastLock<T>(Future<T> Function() body) async {
  var locked = false;
  try {
    await _castChannel.invokeMethod<bool>('acquireMulticastLock');
    locked = true;
  } on MissingPluginException {
    // 桌面 / 非 Android，或旧安装包没有该通道。
  } on PlatformException {
    // 系统拒绝时降级：部分设备仍能收到 M-SEARCH 的单播响应。
  }
  try {
    return await body();
  } finally {
    if (locked) {
      try {
        await _castChannel.invokeMethod<bool>('releaseMulticastLock');
      } catch (_) {
        // 释放失败不覆盖搜索异常。
      }
    }
  }
}

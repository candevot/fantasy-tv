import 'package:flutter/services.dart';

/// 「所有文件访问」权限（Android 11+）。
///
/// 为什么需要：默认缓存目录是 `手机存储/Download/幻想影视`，而 Android 11
/// 起分区存储不允许普通应用直接往公共 Download 写文件。没有这个权限时，
/// 写入探测会失败，下载只能回退到 `Android/data/<包名>/…`，
/// 文件管理器里看不到，用户就以为「没下下来」。
///
/// 原生实现由 tools/patch_edge_to_edge.py 注入（通道 fantasy_tv/storage），
/// 不依赖任何第三方插件。
class StorageAccess {
  StorageAccess._();

  static const MethodChannel _channel = MethodChannel('fantasy_tv/storage');

  /// 是否已经拿到「所有文件访问」。
  ///
  /// Android 10 及以下恒为 true（写公共目录只需要旧版存储权限）。
  static Future<bool> isManager() async {
    try {
      final ok = await _channel.invokeMethod<bool>('isManager');
      return ok ?? false;
    } catch (_) {
      // 通道不存在（非 Android / 旧版本）时按「能用」处理，别卡住下载。
      return true;
    }
  }

  /// 跳到系统的「所有文件访问」授权页。
  ///
  /// 返回 true 只代表已经拉起设置页，用户在页面上点了什么这里拿不到，
  /// 所以调用方应该在用户回到 App 后再查一次 [isManager]。
  static Future<void> requestManager() async {
    try {
      await _channel.invokeMethod<bool>('requestManager');
    } catch (_) {
      // 拉不起来就算了，下载会自动回退到应用专属目录。
    }
  }

  /// 目标路径是否需要「所有文件访问」才可写。
  ///
  /// 只有落在公共存储（`/storage/emulated/0/…`）且不是应用专属目录
  /// （`Android/data|obb/…`）时才需要。
  static bool needsManager(String path) {
    if (!path.startsWith('/storage/emulated/0/')) return false;
    if (path.contains('/Android/data/')) return false;
    if (path.contains('/Android/obb/')) return false;
    return true;
  }
}

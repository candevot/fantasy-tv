import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// App 的真实版本信息。
///
/// 版本号来自 Android 打包时注入的 versionName / versionCode（CI 用
/// `--build-name` / `--build-number` 生成），不再手写死在界面里。
/// 读取失败时退回 pubspec.yaml 里的兜底值，保证界面不会空白。
class AppInfo {
  AppInfo._();

  static const String appName = '幻想影视';
  static const String introduction = '纯净无广告的高清追剧应用，支持多线路播放、4K 画质与离线缓存。';
  static const String contactEmail = 'support@huanxiang.tv';
  static const String fallbackVersion = '1.0.0';
  static const int fallbackVersionCode = 1;

  static String _versionName = fallbackVersion;
  static int _versionCode = fallbackVersionCode;
  static String _packageName = 'com.huanxiang.fantasy_tv';
  static bool _loaded = false;
  static Future<void>? _loading;

  static bool get loaded => _loaded;
  static String get versionName => _versionName;
  static int get versionCode => _versionCode;
  static String get packageName => _packageName;

  /// 例：v1.0.12
  static String get displayVersion => 'v$_versionName';

  /// 例：v1.0.12（versionCode 12）
  static String get fullVersion => 'v$_versionName（$versionCode）';

  static Future<void> load() => _loading ??= _load();

  static Future<void> _load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final name = info.version.trim();
      final code = int.tryParse(info.buildNumber.trim());
      if (name.isNotEmpty) _versionName = name;
      if (code != null && code > 0) _versionCode = code;
      if (info.packageName.trim().isNotEmpty) {
        _packageName = info.packageName.trim();
      }
      _loaded = true;
    } catch (e) {
      debugPrint('AppInfo: PackageInfo.fromPlatform failed: $e');
    }
  }
}

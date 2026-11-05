import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'download_storage.dart';

/// 可选的默认清晰度。与全屏播放器里的清晰度 key 保持一致，播放器后续
/// 可以直接用 [AppSettings.defaultQuality] 去匹配片源清晰度列表。
class FxQualityOption {
  const FxQualityOption(this.key, this.label, this.hint);

  final String key;
  final String label;
  final String hint;
}

/// 本地设置：播放偏好、下载偏好。全部持久化到 SharedPreferences，
/// 通过 [ChangeNotifier] 让设置页和下载服务实时刷新。
class AppSettings extends ChangeNotifier {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  static const String _kDefaultQuality = 'fx_settings_default_quality';
  static const String _kAutoNext = 'fx_settings_auto_next';
  static const String _kSkipIntroOutro = 'fx_settings_skip_intro_outro';
  static const String _kWifiOnlyDownload = 'fx_settings_wifi_only_download';
  static const String _kDownloadLocation = 'fx_settings_download_location';

  static const String defaultQualityKey = 'auto';
  static const bool defaultAutoNext = true;

  /// 产品硬性要求：跳过片头片尾默认关。
  static const bool defaultSkipIntroOutro = false;
  static const bool defaultWifiOnlyDownload = false;

  static const List<FxQualityOption> qualityOptions = <FxQualityOption>[
    FxQualityOption('auto', '自动', '跟随片源默认清晰度'),
    FxQualityOption('4k', '蓝光 4K', '优先 4K，画质最好、最占流量'),
    FxQualityOption('1080p', '超清 1080P', '优先 1080P'),
    FxQualityOption('720p', '高清 720P', '节省流量'),
    FxQualityOption('480p', '标清 480P', '流量最省'),
  ];

  String _defaultQuality = defaultQualityKey;
  bool _autoNext = defaultAutoNext;
  bool _skipIntroOutro = defaultSkipIntroOutro;
  bool _wifiOnlyDownload = defaultWifiOnlyDownload;
  DownloadLocation _downloadLocation = DownloadLocation.phone;

  bool _ready = false;
  Future<void>? _initFuture;

  bool get ready => _ready;
  String get defaultQuality => _defaultQuality;
  bool get autoNext => _autoNext;
  bool get skipIntroOutro => _skipIntroOutro;
  bool get wifiOnlyDownload => _wifiOnlyDownload;
  DownloadLocation get downloadLocation => _downloadLocation;

  String get defaultQualityLabel {
    for (final option in qualityOptions) {
      if (option.key == _defaultQuality) return option.label;
    }
    return qualityOptions.first.label;
  }

  /// 幂等加载：设置页、下载页、下载服务都可以安全调用。
  Future<void> init() => _initFuture ??= _load();

  Future<void> _load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      _defaultQuality = _validQuality(sp.getString(_kDefaultQuality));
      _autoNext = sp.getBool(_kAutoNext) ?? defaultAutoNext;
      _skipIntroOutro = sp.getBool(_kSkipIntroOutro) ?? defaultSkipIntroOutro;
      _wifiOnlyDownload =
          sp.getBool(_kWifiOnlyDownload) ?? defaultWifiOnlyDownload;
      _downloadLocation = downloadLocationFromKey(
        sp.getString(_kDownloadLocation),
      );
    } catch (e) {
      debugPrint('AppSettings: load failed: $e');
    } finally {
      _ready = true;
      notifyListeners();
    }
  }

  String _validQuality(String? value) {
    for (final option in qualityOptions) {
      if (option.key == value) return option.key;
    }
    return defaultQualityKey;
  }

  Future<void> setDefaultQuality(String key) async {
    final valid = _validQuality(key);
    if (_defaultQuality == valid) return;
    _defaultQuality = valid;
    notifyListeners();
    await _saveString(_kDefaultQuality, valid);
  }

  Future<void> setAutoNext(bool value) async {
    if (_autoNext == value) return;
    _autoNext = value;
    notifyListeners();
    await _saveBool(_kAutoNext, value);
  }

  Future<void> setSkipIntroOutro(bool value) async {
    if (_skipIntroOutro == value) return;
    _skipIntroOutro = value;
    notifyListeners();
    await _saveBool(_kSkipIntroOutro, value);
  }

  Future<void> setWifiOnlyDownload(bool value) async {
    if (_wifiOnlyDownload == value) return;
    _wifiOnlyDownload = value;
    notifyListeners();
    await _saveBool(_kWifiOnlyDownload, value);
  }

  Future<void> setDownloadLocation(DownloadLocation value) async {
    if (_downloadLocation == value) return;
    _downloadLocation = value;
    notifyListeners();
    await _saveString(_kDownloadLocation, value.key);
  }

  Future<void> _saveBool(String key, bool value) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(key, value);
    } catch (e) {
      debugPrint('AppSettings: save $key failed: $e');
    }
  }

  Future<void> _saveString(String key, String value) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(key, value);
    } catch (e) {
      debugPrint('AppSettings: save $key failed: $e');
    }
  }
}

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'download_storage.dart';

/// 定时关闭模式：
/// - [FxSleepMode.off] 不开启（默认）
/// - [FxSleepMode.episode] 播完当前集后暂停，不连播
/// - [FxSleepMode.minutes] N 分钟后暂停
enum FxSleepMode {
  off,
  episode,
  minutes;

  static FxSleepMode parse(String? raw) =>
      FxSleepMode.values.firstWhere((m) => m.name == raw, orElse: () => off);
}

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

  /// 定时关闭：模式 + 分钟数 + 结束时间戳（毫秒，仅分钟模式）。
  /// 片头 / 片尾不再是全局秒数：改由播放页按 videoId 标记（见 VideoMarks），
  /// 旧的 `fx_settings_skip_intro_outro` 布尔开关已废弃，不再读取。
  static const String _kSleepMode = 'fx_settings_sleep_timer_mode';
  static const String _kSleepMinutes = 'fx_settings_sleep_timer_minutes';
  static const String _kSleepEndsAt = 'fx_settings_sleep_timer_ends_at';

  /// 播放诊断浮层开关（默认关）：用户自己打开才显示分段耗时，
  /// 平时不往画面上加任何东西。
  static const String _kPlaybackDiagnostics =
      'fx_settings_playback_diagnostics';

  static const String _kWifiOnlyDownload = 'fx_settings_wifi_only_download';
  static const String _kDownloadLocation = 'fx_settings_download_location';
  static const String _kDownloadCustomRoot = 'fx_settings_download_custom_root';
  static const String _kDownloadConcurrency =
      'fx_settings_download_concurrency';

  /// JAR 插件（TVBox type 3 的 spider.jar）：
  ///   · 下载地址（默认指向我们自己的服务器）
  ///   · 可选 md5（填了就强校验，防下到错误页面）
  ///   · 首次使用自动后台安装（默认开）
  static const String _kJarUrl = 'fx_settings_jar_url';
  static const String _kJarMd5 = 'fx_settings_jar_md5';
  static const String _kJarAutoInstall = 'fx_settings_jar_auto_install';

  /// 服务器上那份 spider.jar 的 md5（2026-11-15 实测 1,929,492 B）。
  ///
  /// 默认就校验：拉到的内容 md5 不一致说明下到了错误页面 / 被 CDN 换了内容，
  /// 直接重下（见 [JarPluginManager] 的重试循环），不会把坏 jar 装上。
  static const String defaultJarMd5 = 'cbe016eb3cb002ae62058604843f5106';

  /// jar 插件默认下载地址（服务器上放的肥猫 spider.jar）。
  ///
  /// 用户可在「设置 → jar 插件」里改成别的镜像；改空 = 不自动下载，
  /// 只用内置 / 手动安装的 jar。
  static const String defaultJarUrl = 'http://125.94.244.87/spider.jar';

  static const String defaultQualityKey = 'auto';

  static const bool defaultAutoNext = true;

  /// 定时关闭的可选分钟数。
  static const List<int> sleepTimerOptions = <int>[30, 60, 90];

  static const bool defaultWifiOnlyDownload = false;

  static const bool defaultPlaybackDiagnostics = false;

  /// 下载并发数：HLS 分片 / MP4 Range 分块同时下载的路数。
  /// 产品范围 2–8，默认 6；多集之间仍然是串行队列，避免把源站打满。
  static const int minDownloadConcurrency = 2;
  static const int maxDownloadConcurrency = 8;
  static const int defaultDownloadConcurrency = 6;

  static const List<FxQualityOption> qualityOptions = <FxQualityOption>[
    FxQualityOption('auto', '自动', '跟随片源默认清晰度'),
    FxQualityOption('4k', '蓝光 4K', '优先 4K，画质最好、最占流量'),
    FxQualityOption('1080p', '超清 1080P', '优先 1080P'),
    FxQualityOption('720p', '高清 720P', '节省流量'),
    FxQualityOption('480p', '标清 480P', '流量最省'),
  ];

  String _defaultQuality = defaultQualityKey;
  bool _autoNext = defaultAutoNext;
  FxSleepMode _sleepMode = FxSleepMode.off;
  int _sleepMinutes = sleepTimerOptions.first;
  int _sleepEndsAt = 0;
  bool _wifiOnlyDownload = defaultWifiOnlyDownload;
  bool _playbackDiagnostics = defaultPlaybackDiagnostics;
  bool _jarAutoInstall = true;
  String _jarUrl = defaultJarUrl;
  String _jarMd5 = defaultJarMd5;
  DownloadLocation _downloadLocation = DownloadLocation.phone;

  /// 用户自选的下载基目录（真正写入 `<它>/幻想影视`）；null = 用默认 Download。
  String? _downloadCustomRoot;

  String? get downloadCustomRoot => _downloadCustomRoot;
  int _downloadConcurrency = defaultDownloadConcurrency;

  bool _ready = false;
  Future<void>? _initFuture;

  bool get ready => _ready;
  String get defaultQuality => _defaultQuality;
  bool get autoNext => _autoNext;

  FxSleepMode get sleepMode => _sleepMode;
  int get sleepMinutes => _sleepMinutes;

  /// 定时关闭（分钟模式）的结束时间戳，毫秒；0 = 未设置。
  int get sleepEndsAt => _sleepEndsAt;
  bool get wifiOnlyDownload => _wifiOnlyDownload;

  /// 播放诊断浮层是否打开（默认关，见 [_kPlaybackDiagnostics]）。
  bool get playbackDiagnostics => _playbackDiagnostics;

  /// jar 插件下载地址（空串 = 不自动下载）。
  String get jarUrl => _jarUrl;

  /// jar 期望 md5（空串 = 不校验；填了就强校验）。
  String get jarMd5 => _jarMd5;

  /// 首次使用是否自动后台安装 jar 插件。
  bool get jarAutoInstall => _jarAutoInstall;
  DownloadLocation get downloadLocation => _downloadLocation;
  int get downloadConcurrency => _downloadConcurrency;

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
      _sleepMode = FxSleepMode.parse(sp.getString(_kSleepMode));
      _sleepMinutes = _validSleepMinutes(sp.getInt(_kSleepMinutes));
      _sleepEndsAt = sp.getInt(_kSleepEndsAt) ?? 0;
      // 应用被关掉期间定时已过期：直接回落「不开启」，不再保留一个死计时。
      if (_sleepMode == FxSleepMode.minutes &&
          (_sleepEndsAt <= 0 ||
              _sleepEndsAt <= DateTime.now().millisecondsSinceEpoch)) {
        _sleepMode = FxSleepMode.off;
        _sleepEndsAt = 0;
      }
      _wifiOnlyDownload =
          sp.getBool(_kWifiOnlyDownload) ?? defaultWifiOnlyDownload;
      _playbackDiagnostics =
          sp.getBool(_kPlaybackDiagnostics) ?? defaultPlaybackDiagnostics;
      _jarAutoInstall = sp.getBool(_kJarAutoInstall) ?? true;
      final jarUrl = sp.getString(_kJarUrl)?.trim();
      _jarUrl = jarUrl == null ? defaultJarUrl : jarUrl;
      // 没存过 = 用默认 md5；用户主动清空（存了空串）= 不校验。
      final jarMd5 = sp.getString(_kJarMd5);
      _jarMd5 = (jarMd5 ?? defaultJarMd5).trim().toLowerCase();
      _downloadLocation = downloadLocationFromKey(
        sp.getString(_kDownloadLocation),
      );
      final custom = sp.getString(_kDownloadCustomRoot)?.trim();
      _downloadCustomRoot = (custom == null || custom.isEmpty) ? null : custom;
      _downloadConcurrency = _validConcurrency(
        sp.getInt(_kDownloadConcurrency),
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

  /// 自定义定时分钟数：合法区间 1–1440（24 小时）。
  /// null / 0 / 负数视为没填，回落到预设第一项（[sleepTimerOptions].first）；
  /// 超过 1440 只夹到 1440，不再按白名单把 45 分钟改回 30 分钟。
  int _validSleepMinutes(int? value) {
    if (value == null || value <= 0) return sleepTimerOptions.first;
    return value.clamp(1, 1440).toInt();
  }

  int _validConcurrency(int? value) {
    if (value == null) return defaultDownloadConcurrency;
    return value.clamp(minDownloadConcurrency, maxDownloadConcurrency).toInt();
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

  /// 定时关闭：[FxSleepMode.off] / [FxSleepMode.episode] /
  /// [FxSleepMode.minutes]（分钟数为用户自定义值，夹在 1–1440，未填才回落
  /// [sleepTimerOptions] 第一项；同时记下结束时间戳，杀掉进程再进来也能续上
  /// 剩余时间）。
  Future<void> setSleepTimer(
    FxSleepMode mode, {
    int minutes = 0,
    int endsAt = 0,
  }) async {
    var next = mode;
    var nextMinutes = _sleepMinutes;
    var nextEndsAt = 0;
    if (mode == FxSleepMode.minutes) {
      // 自定义分钟数不再走 sleepTimerOptions 白名单，否则 45 分钟会被改回 30。
      nextMinutes = _validSleepMinutes(minutes);
      nextEndsAt = endsAt > 0
          ? endsAt
          : DateTime.now().millisecondsSinceEpoch + nextMinutes * 60000;
    }
    if (next == _sleepMode &&
        nextMinutes == _sleepMinutes &&
        nextEndsAt == _sleepEndsAt) {
      return;
    }
    _sleepMode = next;
    _sleepMinutes = nextMinutes;
    _sleepEndsAt = nextEndsAt;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kSleepMode, next.name);
      await sp.setInt(_kSleepMinutes, nextMinutes);
      await sp.setInt(_kSleepEndsAt, nextEndsAt);
    } catch (e) {
      debugPrint('AppSettings: save $_kSleepMode failed: $e');
    }
  }

  Future<void> setWifiOnlyDownload(bool value) async {
    if (_wifiOnlyDownload == value) return;
    _wifiOnlyDownload = value;
    notifyListeners();
    await _saveBool(_kWifiOnlyDownload, value);
  }

  Future<void> setJarUrl(String value) async {
    final next = value.trim();
    if (_jarUrl == next) return;
    _jarUrl = next;
    notifyListeners();
    await _saveString(_kJarUrl, next);
  }

  Future<void> setJarMd5(String value) async {
    final next = value.trim().toLowerCase();
    if (_jarMd5 == next) return;
    _jarMd5 = next;
    notifyListeners();
    await _saveString(_kJarMd5, next);
  }

  Future<void> setJarAutoInstall(bool value) async {
    if (_jarAutoInstall == value) return;
    _jarAutoInstall = value;
    notifyListeners();
    await _saveBool(_kJarAutoInstall, value);
  }

  /// 恢复默认 jar 地址（设置页的「恢复默认」用）。
  Future<void> resetJarUrl() => setJarUrl(defaultJarUrl);

  Future<void> setPlaybackDiagnostics(bool value) async {
    if (_playbackDiagnostics == value) return;
    _playbackDiagnostics = value;
    notifyListeners();
    await _saveBool(_kPlaybackDiagnostics, value);
  }

  Future<void> setDownloadCustomRoot(String? value) async {
    final next = value?.trim();
    final normalized = (next == null || next.isEmpty) ? null : next;
    if (_downloadCustomRoot == normalized) return;
    _downloadCustomRoot = normalized;
    notifyListeners();
    if (normalized == null) {
      await _remove(_kDownloadCustomRoot);
    } else {
      await _saveString(_kDownloadCustomRoot, normalized);
    }
  }

  Future<void> setDownloadLocation(DownloadLocation value) async {
    if (_downloadLocation == value) return;
    _downloadLocation = value;
    notifyListeners();
    await _saveString(_kDownloadLocation, value.key);
  }

  Future<void> setDownloadConcurrency(int value) async {
    final valid = _validConcurrency(value);
    if (_downloadConcurrency == valid) return;
    _downloadConcurrency = valid;
    notifyListeners();
    await _saveInt(_kDownloadConcurrency, valid);
  }

  Future<void> _saveBool(String key, bool value) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(key, value);
    } catch (e) {
      debugPrint('AppSettings: save $key failed: $e');
    }
  }

  Future<void> _remove(String key) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(key);
    } catch (e) {
      debugPrint('AppSettings: remove $key failed: $e');
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

  Future<void> _saveInt(String key, int value) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(key, value);
    } catch (e) {
      debugPrint('AppSettings: save $key failed: $e');
    }
  }
}

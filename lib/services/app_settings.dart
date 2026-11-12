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

  static const String _kWifiOnlyDownload = 'fx_settings_wifi_only_download';
  static const String _kDownloadLocation = 'fx_settings_download_location';
  static const String _kDownloadConcurrency =
      'fx_settings_download_concurrency';

  /// 弹幕：开关 / 透明度 / 字号。
  static const String _kDanmuEnabled = 'fx_settings_danmu_enabled';
  static const String _kDanmuOpacity = 'fx_settings_danmu_opacity';
  static const String _kDanmuFontSize = 'fx_settings_danmu_font_size';
  static const String _kDanmuSpeed = 'fx_settings_danmu_speed';
  static const String _kDanmuArea = 'fx_settings_danmu_area';

  static const String defaultQualityKey = 'auto';

  /* ---------------------------------------------------------------- 弹幕 */

  /// 异步落盘：设置页的其它项都是「用的时候再 getInstance」，
  /// 这里保持同一套写法，避免在 ChangeNotifier 里长期持有实例。
  void _persist(Future<void> Function(SharedPreferences sp) write) {
    SharedPreferences.getInstance().then(write).catchError((_) {});
  }

  bool _danmuEnabled = true;
  double _danmuOpacity = 0.92;
  double _danmuFontSize = 15;
  double _danmuSpeed = 1.0;
  double _danmuArea = 0.7;

  /// 弹幕开关。
  bool get danmuEnabled => _danmuEnabled;
  set danmuEnabled(bool v) {
    if (_danmuEnabled == v) return;
    _danmuEnabled = v;
    _persist((sp) => sp.setBool(_kDanmuEnabled, v));
    notifyListeners();
  }

  /// 弹幕透明度（0.2 - 1.0）。
  double get danmuOpacity => _danmuOpacity;
  set danmuOpacity(double v) {
    final n = v.clamp(0.2, 1.0);
    if ((_danmuOpacity - n).abs() < 0.001) return;
    _danmuOpacity = n;
    _persist((sp) => sp.setDouble(_kDanmuOpacity, n));
    notifyListeners();
  }

  /// 弹幕字号（11 - 24）。
  double get danmuFontSize => _danmuFontSize;
  set danmuFontSize(double v) {
    final n = v.clamp(11.0, 24.0);
    if ((_danmuFontSize - n).abs() < 0.001) return;
    _danmuFontSize = n;
    _persist((sp) => sp.setDouble(_kDanmuFontSize, n));
    notifyListeners();
  }

  /// 弹幕滚动速度倍率（0.5 - 2.0）。
  double get danmuSpeed => _danmuSpeed;
  set danmuSpeed(double v) {
    final n = v.clamp(0.5, 2.0);
    if ((_danmuSpeed - n).abs() < 0.001) return;
    _danmuSpeed = n;
    _persist((sp) => sp.setDouble(_kDanmuSpeed, n));
    notifyListeners();
  }

  /// 弹幕显示区域占画面高度的比例（0.3 - 1.0）。
  double get danmuArea => _danmuArea;
  set danmuArea(double v) {
    final n = v.clamp(0.3, 1.0);
    if ((_danmuArea - n).abs() < 0.001) return;
    _danmuArea = n;
    _persist((sp) => sp.setDouble(_kDanmuArea, n));
    notifyListeners();
  }
  static const bool defaultAutoNext = true;

  /// 定时关闭的可选分钟数。
  static const List<int> sleepTimerOptions = <int>[30, 60, 90];

  static const bool defaultWifiOnlyDownload = false;

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
  DownloadLocation _downloadLocation = DownloadLocation.phone;
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
      _danmuEnabled = sp.getBool(_kDanmuEnabled) ?? true;
      _danmuOpacity = (sp.getDouble(_kDanmuOpacity) ?? 0.92).clamp(0.2, 1.0);
      _danmuFontSize = (sp.getDouble(_kDanmuFontSize) ?? 15).clamp(11.0, 24.0);
      _danmuSpeed = (sp.getDouble(_kDanmuSpeed) ?? 1.0).clamp(0.5, 2.0);
      _danmuArea = (sp.getDouble(_kDanmuArea) ?? 0.7).clamp(0.3, 1.0);
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
      _downloadLocation = downloadLocationFromKey(
        sp.getString(_kDownloadLocation),
      );
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

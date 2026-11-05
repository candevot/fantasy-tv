import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import 'app_settings.dart';
import 'download_storage.dart';
import 'network_status.dart';

/// 离线缓存任务状态。
enum DownloadStatus { queued, downloading, paused, completed, failed }

extension DownloadStatusText on DownloadStatus {
  String get label => switch (this) {
        DownloadStatus.queued => '排队中',
        DownloadStatus.downloading => '下载中',
        DownloadStatus.paused => '已暂停',
        DownloadStatus.completed => '已下载',
        DownloadStatus.failed => '下载失败',
      };
}

/// 一次「加入下载」请求：只带展示信息，真正的播放地址在开始下载时再向
/// [Api.play] 换取，避免把会过期的直链持久化到本地。
class DownloadRequest {
  const DownloadRequest({
    required this.id,
    required this.title,
    required this.cover,
    required this.ep,
    required this.epName,
    required this.line,
    required this.lineName,
    this.year = 0,
    this.isMovie = false,
    this.totalEpisodes = 0,
  });

  final String id;
  final String title;
  final String cover;
  final int ep;
  final String epName;
  final String line;
  final String lineName;

  /// 年份，用于目录 `剧名 (年份)` 与电影文件名。
  final int year;

  /// 电影使用 `剧名.年份.1080P.mp4`，剧集使用
  /// `剧名.SxxExx.第N集.mp4`。
  final bool isMovie;

  /// 该剧总集数（下载面板里的集数），用于「已缓存 12/58 集」统计；
  /// 0 表示未知，按任务数兜底。
  final int totalEpisodes;
}

/// 单集缓存任务（可变状态由 [DownloadService] 统一维护）。
class DownloadTask {
  DownloadTask({
    required this.id,
    required this.title,
    required this.cover,
    required this.ep,
    required this.epName,
    required this.line,
    required this.lineName,
    required this.createdAt,
    this.year = 0,
    this.isMovie = false,
    this.totalEpisodes = 0,
    this.status = DownloadStatus.queued,
  }) : updatedAt = createdAt;

  final String id;
  final String title;
  final String cover;
  final int ep;
  final String epName;
  String line;
  String lineName;
  final int createdAt;
  final int year;
  final bool isMovie;

  /// 该剧总集数；0 表示旧任务未知，统计时按任务数 / 最大集号兜底。
  int totalEpisodes;

  DownloadStatus status;
  double progress = 0;
  int bytes = 0;
  int totalBytes = 0;
  int doneSegments = 0;
  int totalSegments = 0;
  String ext = 'mp4';
  String signature = '';
  String? filePath;
  String? error;
  int updatedAt;

  /// 瞬时下载速度（字节/秒），只用于 UI，不持久化。
  int speed = 0;

  /// 速度采样的内部状态，不持久化。
  int _speedBytes = 0;
  int _speedAt = 0;

  String get key => '$id#$ep';

  /// 新版本 HLS 缓存：成品是 `epNN/index.m3u8 + 分片`，不是单个 mp4。
  bool get isHlsLocal => ext == 'm3u8';

  String get epLabel => epName.trim().isEmpty ? '第 $ep 集' : epName.trim();

  String get statusLabel => status.label;

  double get progressValue {
    if (status == DownloadStatus.completed) return 1;
    if (progress.isNaN || progress.isInfinite) return 0;
    return progress.clamp(0.0, 1.0).toDouble();
  }

  String get sizeLabel {
    if (bytes <= 0) return '0 B';
    const units = <String>['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final digits = unit == 0 ? 0 : (unit == 1 ? 0 : 1);
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }

  String get speedLabel => status == DownloadStatus.downloading && speed > 0
      ? formatDownloadSpeed(speed)
      : '';

  /// 下载中的副标题：HLS 显示「已完成/总片数 · 速度」，MP4 显示
  /// 「已下载/总大小 · 速度」。
  String get progressDetail {
    if (status == DownloadStatus.completed) return sizeLabel;
    final rate = speedLabel;
    if (totalSegments > 0) {
      final done = doneSegments.clamp(0, totalSegments);
      return rate.isEmpty
          ? '$done/$totalSegments 片 · ${sizeLabel}'
          : '$done/$totalSegments 片 · $rate';
    }
    if (totalBytes > 0) {
      final base = '${sizeLabel} / ${_fmtBytes(totalBytes)}';
      return rate.isEmpty ? base : '$base · $rate';
    }
    return rate.isEmpty ? sizeLabel : '$sizeLabel · $rate';
  }

  /// 开始下载 / 恢复下载时重置速度采样，避免沿用上一次的字节数。
  void resetSpeed() {
    speed = 0;
    _speedBytes = bytes;
    _speedAt = DateTime.now().millisecondsSinceEpoch;
  }

  /// 按时间窗口从 [bytes] 的增量计算速度；由下载 worker 高频调用。
  void sampleSpeed() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_speedAt <= 0) {
      _speedAt = now;
      _speedBytes = bytes;
      return;
    }
    final dt = now - _speedAt;
    if (dt < 400) return;
    final delta = bytes - _speedBytes;
    speed = delta > 0 ? (delta * 1000 / dt).round() : 0;
    _speedBytes = bytes;
    _speedAt = now;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'cover': cover,
        'ep': ep,
        'epName': epName,
        'line': line,
        'lineName': lineName,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'year': year,
        'isMovie': isMovie,
        'totalEpisodes': totalEpisodes,
        'status': status.name,
        'progress': progress,
        'bytes': bytes,
        'totalBytes': totalBytes,
        'doneSegments': doneSegments,
        'totalSegments': totalSegments,
        'ext': ext,
        'signature': signature,
        'filePath': filePath,
        'error': error,
      };

  factory DownloadTask.fromJson(Map<String, dynamic> j) {
    final rawStatus = '${j['status'] ?? ''}';
    final status = DownloadStatus.values.firstWhere(
      (e) => e.name == rawStatus,
      orElse: () => DownloadStatus.paused,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    return DownloadTask(
      id: '${j['id'] ?? ''}',
      title: '${j['title'] ?? '未命名影片'}',
      cover: '${j['cover'] ?? ''}',
      ep: _asInt(j['ep'], 1),
      epName: '${j['epName'] ?? ''}',
      line: '${j['line'] ?? ''}',
      lineName: '${j['lineName'] ?? ''}',
      createdAt: _asInt(j['createdAt'], now),
      year: _asInt(j['year']),
      isMovie: j['isMovie'] == true,
      totalEpisodes: _asInt(j['totalEpisodes']),
      status: status,
    )
      ..updatedAt = _asInt(j['updatedAt'], now)
      ..progress = _asDouble(j['progress'])
      ..bytes = _asInt(j['bytes'])
      ..totalBytes = _asInt(j['totalBytes'])
      ..doneSegments = _asInt(j['doneSegments'])
      ..totalSegments = _asInt(j['totalSegments'])
      ..ext = '${j['ext'] ?? 'mp4'}'
      ..signature = '${j['signature'] ?? ''}'
      ..filePath = j['filePath'] == null ? null : '${j['filePath']}'
      ..error = j['error'] == null ? null : '${j['error']}';
  }
}

int _asInt(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v == null) return fallback;
  return int.tryParse('$v') ?? fallback;
}

double _asDouble(Object? v) {
  if (v is double) return v;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}

String _fmtBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = <String>['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : (unit == 1 ? 0 : 1))} ${units[unit]}';
}

/// 下载速度文案，例如 `3.2MB/s`。
String formatDownloadSpeed(int bytesPerSecond) {
  if (bytesPerSecond <= 0) return '0 B/s';
  const units = <String>['B', 'KB', 'MB', 'GB'];
  var value = bytesPerSecond.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(digits)}${units[unit]}/s';
}

/// 清洗文件名 / 目录名里的非法字符。
///
/// Android 与桌面文件管理器都不允许 `/ \ : * ? " < > |` 和控制字符；
/// 尾部空格 / 点会让部分文件系统拒绝创建，一并清掉。
String sanitizeDownloadName(String raw, {String fallback = '未命名'}) {
  var name = raw
      .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  name = name.replaceFirst(RegExp(r'^[. ]+'), '');
  name = name.replaceFirst(RegExp(r'[. ]+$'), '');
  if (name.isEmpty) name = fallback;
  if (name.length > 80) {
    name = name.substring(0, 80).replaceFirst(RegExp(r'[. ]+$'), '');
  }
  if (name.isEmpty || name == '.' || name == '..') return fallback;
  return name;
}

String _safeSegment(String value) {
  final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return cleaned.isEmpty ? 'video' : cleaned;
}

/* ========================================================================== */
/*  下载服务                                                                   */
/* ========================================================================== */

/// 本地离线缓存：顺序下载 HLS 分片 / MP4 直链，队列持久化到
/// SharedPreferences，UI 通过 [ChangeNotifier] 实时刷新。
///
/// 目录策略（见 [DownloadStorage]）：默认「手机存储」优先写
/// `/storage/emulated/0/Download/幻想影视`；Android 分区存储不允许直接
/// 写入时自动退回 `getExternalStorageDirectory()`，也可在设置里切换到
/// 应用私有目录。任何情况下都不再使用 systemTemp 存放新缓存。
///
/// 线程模型：多集之间严格串行（[_pump] 一次只跑一个任务），单集内部由
/// [AppSettings.downloadConcurrency] 控制并发（2–8，默认 6）。因此全局
/// 下载连接数不会超过 8，既能把单集带宽打满，也不会并发请求多集把源站
/// 打限速。
class DownloadService extends ChangeNotifier {
  DownloadService._();

  static final DownloadService instance = DownloadService._();

  static const String queuePrefsKey = 'fx_download_queue_v1';
  static const String legacyPrefsKey = 'fx_downloads_v1';

  static const Duration _requestTimeout = Duration(seconds: 30);
  static const Duration _streamTimeout = Duration(seconds: 60);
  static const Duration _notifyGap = Duration(milliseconds: 220);
  static const Duration _retryBackoff = Duration(milliseconds: 300);
  static const int _retryCount = 2;

  /// 校验时认为「不可能是完整视频」的阈值；ffprobe 可用时以时长为准。
  static const int _minValidBytes = 1024 * 1024;

  final List<DownloadTask> _tasks = <DownloadTask>[];
  final http.Client _client = http.Client();

  bool _ready = false;
  bool _pumping = false;
  bool _persisting = false;
  bool _persistAgain = false;
  bool _disposed = false;
  Future<void>? _initFuture;
  Timer? _persistTimer;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  AppLifecycleState? _lifecycle;

  DownloadLocation _location = DownloadLocation.phone;
  DownloadStorageInfo? _storageInfo;
  Directory? _rootDirCache;
  int _usedBytes = 0;
  bool _usageLoading = false;

  /// ffprobe 是否存在。Android 上没有 ffprobe 时只做大小校验。
  static bool _ffprobeUnavailable = false;

  /// 服务是否已从 SharedPreferences 恢复完成。
  bool get ready => _ready;

  /// 当前下载位置（设置里的选择）。
  DownloadLocation get location => _location;

  /// 当前下载位置的展示名。
  String get locationLabel => _location.label;

  /// 当前实际使用的缓存根目录；尚未解析完成时返回公共目录常量。
  String get rootPath => _storageInfo?.path ?? DownloadStorage.publicRootPath;

  /// 实际目录的可读展示（把 /storage/emulated/0 换成「手机存储」）。
  String get displayRootPath => DownloadStorage.displayPath(rootPath);

  /// 选择「手机存储」但系统不允许写公共 Download，已退回应用专属目录。
  bool get storageFallback => _storageInfo?.fallback ?? false;

  /// 所有缓存目录的真实占用（含旧版本 systemTemp 遗留文件）。
  int get usedBytes => _usedBytes;

  bool get usageLoading => _usageLoading;

  /// 最近一次 App 生命周期状态（下载在主 isolate 中，不随前后台暂停）。
  AppLifecycleState? get lifecycle => _lifecycle;

  /// 只读任务列表（按加入时间排序，与持久化顺序一致）。
  List<DownloadTask> get tasks => List<DownloadTask>.unmodifiable(_tasks);

  /// 启动恢复：加载队列；未完成的标记为暂停；已完成但文件丢失的标记失败。
  ///
  /// 幂等：App 启动、下载页、设置页、详情页都会调用，只执行一次。
  Future<void> init() => _initFuture ??= _load();

  Future<void> _load() async {
    try {
      await AppSettings.instance.init();
      _location = AppSettings.instance.downloadLocation;
      _storageInfo = await DownloadStorage.resolve(_location);
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(queuePrefsKey);
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        final List<dynamic> list;
        if (decoded is Map && decoded['tasks'] is List) {
          list = decoded['tasks'] as List<dynamic>;
        } else if (decoded is List) {
          list = decoded;
        } else {
          list = const <dynamic>[];
        }
        for (final item in list) {
          if (item is! Map) continue;
          try {
            final task = DownloadTask.fromJson(Map<String, dynamic>.from(item));
            if (task.id.isEmpty || task.ep <= 0) continue;
            _tasks.add(task);
          } catch (e) {
            debugPrint('DownloadService: bad task json: $e');
          }
        }
      }
      await _rootDir();
      await _reconcile();
      await _persist();
    } catch (e) {
      debugPrint('DownloadService: load failed: $e');
    } finally {
      _ready = true;
      notifyListeners();
      unawaited(refreshUsage());
      _kick();
    }
  }

  /// App 生命周期只做记录：下载跑在主 isolate 里，切后台不会主动暂停。
  ///
  /// 没有引入 WorkManager / 前台服务：WorkManager 的周期任务无法承载一条
  /// 持续数十分钟的 HTTP 下载流，前台服务则需要额外的 Android 原生插件与
  /// 通知权限。当前实现依赖「App 进程在后台仍然存活」这一 Android 默认
  /// 行为；若系统回收进程，已完成分片会保留在 `.hls_parts` / `.mp4_parts`
  /// 目录，下次启动按暂停恢复（见 [_reconcile]），用户点继续即可接着下。
  void handleLifecycle(AppLifecycleState state) {
    _lifecycle = state;
    if (state == AppLifecycleState.detached) {
      _persistSoon();
    }
  }

  /// 释放服务：取消持久化定时器、关闭 HTTP 连接，避免测试 / 热重载后
  /// 残留后台任务。真正的下载循环通过 [_shouldStop] 感知并退出。
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _persistTimer?.cancel();
    _persistTimer = null;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final task in _tasks) {
      if (task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.queued) {
        task
          ..status = DownloadStatus.paused
          ..speed = 0
          ..updatedAt = now;
      }
    }
    _client.close();
    unawaited(_persist());
    super.dispose();
  }

  /// 切换下载目录。已经在下载的任务会继续写入原目录，新任务使用新目录；
  /// 已完成的文件按绝对路径记录，切换后依旧可以播放。
  Future<void> setLocation(DownloadLocation value) async {
    await init();
    if (_location == value) return;
    _location = value;
    _rootDirCache = null;
    _storageInfo = null;
    await AppSettings.instance.setDownloadLocation(value);
    _storageInfo = await DownloadStorage.resolve(value);
    await _rootDir();
    _notifyNow();
    await refreshUsage();
  }

  /// 重新统计真实磁盘占用；设置页进入或清理后调用。
  Future<void> refreshUsage() async {
    if (_usageLoading) return;
    _usageLoading = true;
    try {
      final bytes = await DownloadStorage.usedBytes();
      _usageLoading = false;
      if (_usedBytes == bytes) {
        _notifyNow();
        return;
      }
      _usedBytes = bytes;
      _notifyNow();
    } catch (e) {
      _usageLoading = false;
      debugPrint('DownloadService: refreshUsage failed: $e');
    }
  }

  Future<void> _reconcile() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final task in _tasks) {
      task.resetSpeed();
      if (task.status == DownloadStatus.queued ||
          task.status == DownloadStatus.downloading) {
        // App 重启后不自动续传，统一恢复成「已暂停」由用户决定。
        task.status = DownloadStatus.paused;
        task.error = null;
        task.updatedAt = now;
      }
      if (task.status == DownloadStatus.completed) {
        final file = await _existingFile(task);
        if (file == null) {
          task
            ..status = DownloadStatus.failed
            ..error = '缓存文件已被系统清理，请重新下载'
            ..filePath = null
            ..speed = 0
            ..updatedAt = now;
        } else {
          // 目录式 HLS 缓存的成品是 index.m3u8，体积要按整个目录统计。
          var length = await file.length();
          if (task.isHlsLocal) {
            length = task.bytes > 0
                ? task.bytes
                : await DownloadStorage.directoryBytes(file.parent.path);
          }
          if (length <= 0) {
            await _deleteQuietly(file);
            task
              ..status = DownloadStatus.failed
              ..error = '缓存文件为空，请重新下载'
              ..filePath = null
              ..speed = 0
              ..updatedAt = now;
          } else {
            task
              ..filePath = file.path
              ..bytes = length
              ..progress = 1
              ..speed = 0;
          }
        }
      }
    }
  }

  /// 已缓存的集（同剧同集不区分线路）。同时确认本地文件真的还在，
  /// 避免外部清理后详情页仍显示「已下载」。
  bool isCached(String id, int ep) {
    for (final task in _tasks) {
      if (task.id != id || task.ep != ep) continue;
      if (task.status != DownloadStatus.completed) return false;
      final path = task.filePath;
      if (path == null || path.isEmpty) return false;
      try {
        return File(path).existsSync();
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  DownloadTask? taskFor(String id, int ep) {
    for (final t in _tasks) {
      if (t.id == id && t.ep == ep) return t;
    }
    return null;
  }

  /// 同一部剧的全部任务（用于「删除整剧」与系列目录清理）。
  List<DownloadTask> tasksForSeries(String id) =>
      _tasks.where((t) => t.id == id).toList(growable: false);

  /// 该剧总集数：优先用下载面板记录的总集数，旧任务按最大集号兜底。
  int seriesTotalEpisodes(String id) {
    var total = 0;
    var count = 0;
    for (final t in _tasks) {
      if (t.id != id) continue;
      count++;
      if (t.totalEpisodes > total) total = t.totalEpisodes;
      if (t.ep > total) total = t.ep;
    }
    if (total <= 0) total = count;
    return total < 1 ? 1 : total;
  }

  int seriesCachedCount(String id) {
    var cached = 0;
    for (final t in _tasks) {
      if (t.id == id && t.status == DownloadStatus.completed) cached++;
    }
    return cached;
  }

  int seriesCachedBytes(String id) {
    var bytes = 0;
    for (final t in _tasks) {
      if (t.id == id) bytes += t.bytes;
    }
    return bytes;
  }

  /// 整剧缓存进度 = 所有任务进度之和 / 总集数；只下了一部分时进度条
  /// 停在「已缓存比例」上，和「已缓存 12/58 集」文案一致。
  double seriesProgress(String id) {
    final list = tasksForSeries(id);
    if (list.isEmpty) return 0;
    var sum = 0.0;
    for (final t in list) {
      sum += t.progressValue;
    }
    final total = seriesTotalEpisodes(id);
    if (total <= 0) return 0;
    return (sum / total).clamp(0.0, 1.0);
  }

  DownloadStatus seriesStatus(String id) {
    final list = tasksForSeries(id);
    if (list.isEmpty) return DownloadStatus.completed;
    if (list.any((t) => t.status == DownloadStatus.downloading)) {
      return DownloadStatus.downloading;
    }
    if (list.any((t) => t.status == DownloadStatus.queued)) {
      return DownloadStatus.queued;
    }
    if (list.any((t) => t.status == DownloadStatus.paused)) {
      return DownloadStatus.paused;
    }
    if (list.any((t) => t.status == DownloadStatus.failed)) {
      return DownloadStatus.failed;
    }
    return DownloadStatus.completed;
  }

  /// 整部剧里正在下载（或排队最前）的集，用于「第 12/58 集」文案。
  DownloadTask? seriesCurrentTask(String id) {
    DownloadTask? queued;
    DownloadTask? paused;
    for (final t in _tasks) {
      if (t.id != id) continue;
      if (t.status == DownloadStatus.downloading) return t;
      if (queued == null && t.status == DownloadStatus.queued) queued = t;
      if (paused == null && t.status == DownloadStatus.paused) paused = t;
    }
    return queued ?? paused;
  }

  /// 该剧还没有任务记录（未缓存、未排队）的集号，用于「继续补下」。
  List<int> seriesMissingEpisodes(String id) {
    final total = seriesTotalEpisodes(id);
    final existing = <int>{for (final t in tasksForSeries(id)) t.ep};
    return <int>[
      for (var n = 1; n <= total; n++)
        if (!existing.contains(n)) n,
    ];
  }

  /// 解析任务对应的真实本地文件；文件已被清理时返回 null。
  Future<File?> fileFor(DownloadTask task) async {
    if (task.status != DownloadStatus.completed) return null;
    final file = await _existingFile(task);
    if (file != null) task.filePath = file.path;
    return file;
  }

  List<DownloadTask> get activeTasks => _tasks
      .where((t) => t.status != DownloadStatus.completed)
      .toList(growable: false);

  List<DownloadTask> get completedTasks => _tasks
      .where((t) => t.status == DownloadStatus.completed)
      .toList(growable: false);

  int get totalCachedBytes => _tasks
      .where((t) => t.status == DownloadStatus.completed)
      .fold<int>(0, (sum, t) => sum + t.bytes);

  /* ------------------------------------------------------------- enqueue */

  /// 批量加入队列，返回真正新增/重置的任务数。
  ///
  /// 已缓存、排队中、下载中、已暂停的同集会被跳过；失败任务会被重置重试。
  Future<int> enqueue(List<DownloadRequest> requests) async {
    await init();
    if (requests.isEmpty || _disposed) return 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    var added = 0;
    for (final req in requests) {
      if (req.id.isEmpty || req.ep <= 0) continue;
      final existing = taskFor(req.id, req.ep);
      if (existing != null) {
        if (existing.status != DownloadStatus.failed) continue;
        existing
          // 重试时用户可能已经换了线路：跟着用这次请求的线路，别沿用旧线路。
          ..line = req.line.isEmpty ? existing.line : req.line
          ..lineName = req.lineName.isEmpty ? existing.lineName : req.lineName
          ..totalEpisodes = math.max(existing.totalEpisodes, req.totalEpisodes)
          ..status = DownloadStatus.queued
          ..progress = 0
          ..bytes = 0
          ..totalBytes = 0
          ..doneSegments = 0
          ..totalSegments = 0
          ..signature = ''
          ..filePath = null
          ..error = null
          ..speed = 0
          ..updatedAt = now;
        existing.resetSpeed();
        added++;
        continue;
      }
      _tasks.add(DownloadTask(
        id: req.id,
        title: req.title,
        cover: req.cover,
        ep: req.ep,
        epName: req.epName,
        line: req.line,
        lineName: req.lineName,
        createdAt: now,
        year: req.year,
        isMovie: req.isMovie,
        totalEpisodes: req.totalEpisodes,
      ));
      added++;
    }
    if (added > 0) {
      await _persist();
      _notifyNow();
      _kick();
    }
    return added;
  }

  /* ------------------------------------------------------------ controls */

  Future<void> pause(DownloadTask task) async {
    if (task.status != DownloadStatus.downloading &&
        task.status != DownloadStatus.queued) {
      return;
    }
    task
      ..status = DownloadStatus.paused
      ..speed = 0
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    _notifyNow();
    await _persist();
  }

  Future<void> resume(DownloadTask task) async {
    if (!_tasks.contains(task)) return;
    if (task.status != DownloadStatus.paused &&
        task.status != DownloadStatus.failed) {
      return;
    }
    task
      ..status = DownloadStatus.queued
      ..error = null
      ..speed = 0
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    task.resetSpeed();
    _notifyNow();
    await _persist();
    _kick();
  }

  Future<void> retry(DownloadTask task) => resume(task);

  Future<void> pauseAll() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = false;
    for (final task in _tasks) {
      if (task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.queued) {
        task
          ..status = DownloadStatus.paused
          ..speed = 0
          ..updatedAt = now;
        changed = true;
      }
    }
    if (!changed) return;
    _notifyNow();
    await _persist();
  }

  Future<void> resumeAll() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = false;
    for (final task in _tasks) {
      if (task.status == DownloadStatus.paused) {
        task
          ..status = DownloadStatus.queued
          ..error = null
          ..speed = 0
          ..updatedAt = now;
        task.resetSpeed();
        changed = true;
      }
    }
    if (!changed) return;
    _notifyNow();
    await _persist();
    _kick();
  }

  /// 整部剧暂停：下载中的集立即中断，排队的集不再开始。
  Future<void> pauseSeries(String id) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = false;
    for (final task in _tasks) {
      if (task.id != id) continue;
      if (task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.queued) {
        task
          ..status = DownloadStatus.paused
          ..speed = 0
          ..updatedAt = now;
        changed = true;
      }
    }
    if (!changed) return;
    _notifyNow();
    await _persist();
  }

  /// 整部剧继续：暂停 / 失败的集重新排队，等当前集跑完再串行开始。
  Future<void> resumeSeries(String id) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = false;
    for (final task in _tasks) {
      if (task.id != id) continue;
      if (task.status == DownloadStatus.paused ||
          task.status == DownloadStatus.failed) {
        task
          ..status = DownloadStatus.queued
          ..error = null
          ..speed = 0
          ..updatedAt = now;
        task.resetSpeed();
        changed = true;
      }
    }
    if (!changed) return;
    _notifyNow();
    await _persist();
    _kick();
  }

  /// 删除单集记录并清理缓存文件。
  Future<void> remove(DownloadTask task) async {
    final wasActive = task.status == DownloadStatus.downloading ||
        task.status == DownloadStatus.queued;
    _tasks.remove(task);
    _notifyNow();
    await _persist();
    // 下载中的 worker 还在写临时分片：稍微等它看到任务已被移除，
    // 再删目录，避免删完又被写回一个残留文件。
    if (wasActive) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await _deleteTaskFiles(task);
    await refreshUsage();
  }

  /// 删除整部剧：清理该 id 下所有任务记录与本地文件。
  Future<int> removeSeries(String id) async {
    final removed = _tasks.where((t) => t.id == id).toList(growable: false);
    if (removed.isEmpty) return 0;
    final wasActive = removed.any((t) =>
        t.status == DownloadStatus.downloading ||
        t.status == DownloadStatus.queued);
    _tasks.removeWhere((t) => t.id == id);
    _notifyNow();
    await _persist();
    if (wasActive) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    for (final task in removed) {
      await _deleteTaskFiles(task);
    }
    // 整剧删除：把系列目录里的孤儿分片 / 旧临时文件也一并清掉。
    final seriesDirs = <String>{};
    for (final task in removed) {
      try {
        seriesDirs.add((await _seriesDirectory(task)).path);
      } catch (_) {}
    }
    for (final path in seriesDirs) {
      await _deleteDirQuietly(Directory(path));
    }
    await refreshUsage();
    return removed.length;
  }

  /// 清空全部任务与缓存文件。
  Future<void> clearAll() async {
    for (final task in _tasks) {
      if (task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.queued) {
        task
          ..status = DownloadStatus.paused
          ..speed = 0;
      }
    }
    final old = List<DownloadTask>.from(_tasks);
    _tasks.clear();
    _notifyNow();
    await _persist();
    if (old.any((t) => t.progress > 0 && t.progress < 1)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    for (final task in old) {
      await _deleteTaskFiles(task);
    }
    // 删除所有已知缓存目录里的残留（包括下载中断留下的分片目录）。
    await DownloadStorage.clearAllCaches();
    _rootDirCache = null;
    _storageInfo = await DownloadStorage.resolve(_location);
    await _rootDir();
    await refreshUsage();
  }

  /* -------------------------------------------------------------- worker */

  void _kick() {
    if (!_ready || _disposed) return;
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_pumping || !_ready || _disposed) return;
    _pumping = true;
    try {
      String? abortKey;
      var abortStreak = 0;
      while (!_disposed) {
        DownloadTask? next;
        for (final task in _tasks) {
          if (task.status == DownloadStatus.queued) {
            next = task;
            break;
          }
        }
        if (next == null) break;
        final aborted = await _runTask(next);
        if (!aborted) {
          abortKey = null;
          abortStreak = 0;
          continue;
        }
        // 同一任务连续 abort 说明它一直在「下载→中断→重新排队」打转，
        // 超过 2 次直接置失败，避免队列空转。
        if (next.key == abortKey) {
          abortStreak++;
        } else {
          abortKey = next.key;
          abortStreak = 1;
        }
        if (abortStreak > 2) {
          if (_tasks.contains(next) && next.status == DownloadStatus.queued) {
            next
              ..status = DownloadStatus.failed
              ..speed = 0
              ..error = '下载多次中断，请点击重试'
              ..updatedAt = DateTime.now().millisecondsSinceEpoch;
            _notifyNow();
            await _persist();
          }
          abortKey = null;
          abortStreak = 0;
        }
      }
    } finally {
      _pumping = false;
      if (!_disposed && _tasks.any((t) => t.status == DownloadStatus.queued)) {
        unawaited(_pump());
      }
    }
  }

  Future<bool> _runTask(DownloadTask task) async {
    if (!_tasks.contains(task) || task.status != DownloadStatus.queued) {
      return false;
    }
    var aborted = false;
    try {
      await _ensureNetworkAllowed();
      final play = await _withRetry(
        () => Api.play(task.id, task.ep, task.line),
      );
      if (_shouldStop(task)) throw const _AbortDownload();

      final rawUrl = play.url.trim();
      if (rawUrl.isEmpty) {
        throw const _CacheException('接口未返回播放地址');
      }
      final type = play.type.toLowerCase();
      final uri = _ensureAuthorized(Uri.tryParse(Api.abs(rawUrl)));
      final lowerPath = uri.path.toLowerCase();
      final looksHls = lowerPath.contains('.m3u8');
      final looksMp4 = lowerPath.endsWith('.mp4');
      // 解析线路只有拿到直链时才可缓存；普通网页地址不做缓存，避免写入 HTML。
      if ((type == 'parse' || type == 'unresolved' || type == 'iframe') &&
          !looksHls &&
          !looksMp4) {
        throw const _CacheException('该线路暂不支持离线缓存，请切换线路');
      }
      if (play.lineName.trim().isNotEmpty) {
        task.lineName = play.lineName.trim();
      }

      task
        ..status = DownloadStatus.downloading
        ..error = null
        ..speed = 0
        ..updatedAt = DateTime.now().millisecondsSinceEpoch;
      task.resetSpeed();
      _notifyNow();
      await _persist();

      // 地址后缀优先于接口的 type：部分接口会把 m3u8 误标成 mp4。
      final isMp4 =
          looksMp4 || (!looksHls && (type == 'mp4' || type == 'direct_mp4'));
      if (isMp4) {
        await _downloadMp4(task, uri, play.headers);
      } else {
        await _downloadHls(task, uri, play.headers);
      }
    } on _AbortDownload {
      // 暂停 / 删除 / 清空：状态已由控制方法处理，这里不再改状态。
      aborted = true;
    } catch (e) {
      if (_tasks.contains(task) &&
          (task.status == DownloadStatus.downloading ||
              task.status == DownloadStatus.queued)) {
        task
          ..status = DownloadStatus.failed
          ..speed = 0
          ..error = _friendlyError(e)
          ..updatedAt = DateTime.now().millisecondsSinceEpoch;
        await _persist();
      }
    } finally {
      task.speed = 0;
      _notifyNow();
      unawaited(refreshUsage());
    }
    return aborted;
  }

  /// 只有任务被删除、暂停、服务释放或 App 退出才中断下载；排队（queued）
  /// 不算停止，否则刚拿到播放地址就会误 abort，任务永远原地重排。
  bool _shouldStop(DownloadTask task) =>
      _disposed ||
      !_tasks.contains(task) ||
      task.status == DownloadStatus.paused ||
      task.status == DownloadStatus.failed;

  /// 下载前检查真实网络类型：仅 Wi-Fi 开关打开时，移动网络直接失败并
  /// 给出可读原因，连上 Wi-Fi 后可点重试。
  Future<void> _ensureNetworkAllowed() async {
    final kind = await NetworkStatus.detect();
    if (kind == FxNetworkKind.offline) {
      throw const _CacheException('网络不可用，请检查网络连接后重试');
    }
    if (AppSettings.instance.wifiOnlyDownload && kind.isMobile) {
      throw const _CacheException(
        '已开启「仅 Wi-Fi 下载」，当前为移动网络，连接 Wi-Fi 后可重试',
      );
    }
  }

  /// 给下载选集面板做预检；返回 null 表示允许下载，否则返回提示文案。
  Future<String?> networkBlockReason() async {
    final kind = await NetworkStatus.detect();
    if (kind == FxNetworkKind.offline) return '当前无网络，请连接网络后重试';
    if (AppSettings.instance.wifiOnlyDownload && kind.isMobile) {
      return '已开启「仅 Wi-Fi 下载」，当前为移动网络';
    }
    return null;
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> _deleteDirQuietly(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  Uri _ensureAuthorized(Uri? uri) {
    // 合规：只缓存接口给出的 http/https 直链，拒绝 file:/data:/其他协议。
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const _CacheException('播放地址未获授权，仅支持 http/https 直链');
    }
    return uri;
  }

  int get _concurrency => AppSettings.instance.downloadConcurrency
      .clamp(AppSettings.minDownloadConcurrency,
          AppSettings.maxDownloadConcurrency)
      .toInt();

  /* ------------------------------------------------------------- hls dl */

  Future<void> _downloadHls(
    DownloadTask task,
    Uri playlistUri,
    Map<String, String> headers,
  ) async {
    var fetched = await _fetchPlaylist(playlistUri, headers);
    var mediaUri = fetched.uri;
    var playlist = fetched.text;

    if (playlist.contains('#EXT-X-STREAM-INF')) {
      final variants = _parseVariants(playlist, mediaUri);
      if (variants.isEmpty) {
        throw const _CacheException('播放列表没有可下载的清晰度');
      }
      variants.sort((a, b) => a.bandwidth.compareTo(b.bandwidth));
      fetched = await _fetchPlaylist(variants.last.uri, headers);
      mediaUri = fetched.uri;
      playlist = fetched.text;
    }

    if (playlist.contains('#EXT-X-STREAM-INF')) {
      throw const _CacheException('播放列表嵌套层级过多，暂不支持');
    }
    if (!playlist.contains('#EXT-X-ENDLIST')) {
      throw const _CacheException('直播或未完结的 HLS 暂不支持离线缓存');
    }

    final parsed = _parseHlsPlaylist(playlist, mediaUri);
    if (parsed.encrypted) {
      // AES-128 加密片源（可带 EXT-X-MAP）：落成
      // `epNN/index.m3u8 + seg00001.ts + key.bin`，交给 mpv 本地解密。
      await _downloadHlsLocal(task, parsed, headers);
      return;
    }
    if (parsed.segments.isEmpty) {
      throw const _CacheException('播放列表里没有分片');
    }

    final mapUri = parsed.firstMapUri;
    final segments = parsed.segmentUris;

    final steps = <Uri>[
      if (mapUri != null) mapUri,
      ...segments,
    ];
    final total = steps.length;
    final signature = _signature(segments);
    final target = await _targetFile(task);
    final partsDir = Directory('${target.path}.hls_parts');

    // 新任务 / 失败重试：上一次可能留下损坏的成品或其它格式的临时目录。
    await _deleteQuietly(target);
    await _deleteDirQuietly(Directory('${target.path}.mp4_parts'));
    await _deleteDirQuietly(Directory('${target.path}.stream_parts'));
    await _deleteQuietly(File('${target.path}.stream_parts.part'));
    // 换线路后可能从加密 HLS 目录切回单文件，清掉旧目录。
    try {
      await _deleteDirQuietly(await _episodeDirectory(task));
    } catch (_) {}

    final reuse = await _hlsPartsMatch(partsDir, signature, total);
    if (!reuse) {
      await _deleteDirQuietly(partsDir);
      await partsDir.create(recursive: true);
      await File('${partsDir.path}/manifest.json').writeAsString(jsonEncode(
        <String, dynamic>{
          'version': 1,
          'signature': signature,
          'total': total,
        },
      ));
    }

    final done = <int>{};
    var bytes = 0;
    for (var i = 0; i < total; i++) {
      final file = File(_hlsSegmentPath(partsDir, i));
      if (!await file.exists()) continue;
      final length = await file.length();
      if (length <= 0) {
        await _deleteQuietly(file);
        continue;
      }
      done.add(i);
      bytes += length;
    }

    task
      ..ext = 'mp4'
      ..signature = signature
      ..totalSegments = total
      ..doneSegments = done.length
      ..totalBytes = 0
      ..bytes = bytes
      ..progress = total <= 0 ? 0 : done.length / total
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    task.resetSpeed();
    _notifyNow();
    _persistSoon();

    await _downloadHlsSegments(
      task,
      steps,
      headers,
      done,
      total,
      pathOf: (i) => _hlsSegmentPath(partsDir, i),
    );

    if (_shouldStop(task)) throw const _AbortDownload();
    final missing = total - done.length;
    if (missing > 0) {
      throw _CacheException('还有 $missing 个分片未下载完成，请重试');
    }

    final part = File('${target.path}.part');
    await _deleteQuietly(part);
    final sink = part.openWrite();
    try {
      for (var i = 0; i < total; i++) {
        if (_shouldStop(task)) throw const _AbortDownload();
        final segment = File(_hlsSegmentPath(partsDir, i));
        if (!await segment.exists() || await segment.length() <= 0) {
          throw _CacheException('分片 $i 缺失，请重试');
        }
        await sink.addStream(segment.openRead());
      }
      await sink.flush();
      await sink.close();
    } finally {
      try {
        await sink.close();
      } catch (_) {}
    }

    if (_shouldStop(task)) {
      await _deleteQuietly(part);
      throw const _AbortDownload();
    }
    await _finalize(
      task,
      part,
      target,
      cleanup: () => _deleteDirQuietly(partsDir),
    );
    await _deleteDirQuietly(partsDir);
  }

  /* --------------------------------------------- hls local (aes-128) */

  /// 集目录：`<剧名 (年份)>/ep01`。
  Future<Directory> _episodeDirectory(DownloadTask task) async {
    final series = await _seriesDirectory(task);
    final ep = task.ep < 1 ? 1 : task.ep;
    return Directory('${series.path}/ep${ep.toString().padLeft(2, '0')}');
  }

  /// 本地分片名：`seg00001.ts`（从 1 开始，和 m3u8 里的顺序一致）。
  String _hlsLocalSegmentPath(Directory dir, int index) =>
      '${dir.path}/seg${(index + 1).toString().padLeft(5, '0')}.ts';

  /// 加密 HLS 的离线缓存：key / init / 分片全部落到同一目录，再写一份
  /// 只有相对路径的 `index.m3u8`。离线播放直接打开 index.m3u8，由
  /// libmpv（ffmpeg）负责用同目录的 key.bin 解密，App 不实现 AES。
  Future<void> _downloadHlsLocal(
    DownloadTask task,
    _HlsPlaylist playlist,
    Map<String, String> headers,
  ) async {
    final total = playlist.segments.length;
    if (total <= 0) {
      throw const _CacheException('播放列表里没有分片');
    }
    final dir = await _episodeDirectory(task);
    final indexFile = File('${dir.path}/index.m3u8');
    final manifestFile = File('${dir.path}/.fx_hls.json');
    final signature = playlist.signature;

    // 先撤掉可能半残的 index，避免播放器读到缺分片的播放列表；旧版本
    // 拼接出来的 mp4 也一并清掉，避免同一集同时存在两种成品。
    await _deleteQuietly(indexFile);
    try {
      await _deleteQuietly(await _expectedTarget(task));
    } catch (_) {}

    var reuse = false;
    if (await manifestFile.exists()) {
      try {
        final decoded = jsonDecode(await manifestFile.readAsString());
        reuse = decoded is Map &&
            '${decoded['signature']}' == signature &&
            _asInt(decoded['total']) == total;
      } catch (_) {
        reuse = false;
      }
    }
    if (!reuse) {
      await _deleteDirQuietly(dir);
      await dir.create(recursive: true);
      await manifestFile.writeAsString(jsonEncode(<String, dynamic>{
        'version': 1,
        'signature': signature,
        'total': total,
      }));
    } else {
      await dir.create(recursive: true);
    }

    // 1) 密钥：单 key 存 key.bin；轮换 key 依次 key1.bin / key2.bin。
    final keyNames = <String, String>{};
    final keyUris = playlist.keyUris;
    for (var i = 0; i < keyUris.length; i++) {
      final name = keyUris.length == 1 ? 'key.bin' : 'key${i + 1}.bin';
      keyNames[keyUris[i].toString()] = name;
      final file = File('${dir.path}/$name');
      if (await file.exists() && await file.length() > 0) continue;
      final bytes = await _fetchSegmentWithRetry(keyUris[i], headers);
      await file.writeAsBytes(bytes, flush: true);
      task
        ..bytes += bytes.length
        ..updatedAt = DateTime.now().millisecondsSinceEpoch;
      _notifyProgress();
    }

    // 2) EXT-X-MAP（fMP4 init）：下载到同目录，index 里指向本地文件。
    final mapNames = <String, String>{};
    final mapUris = playlist.mapUris;
    for (var i = 0; i < mapUris.length; i++) {
      final name = mapUris.length == 1 ? 'init.mp4' : 'init${i + 1}.mp4';
      mapNames[mapUris[i].toString()] = name;
      final file = File('${dir.path}/$name');
      if (await file.exists() && await file.length() > 0) continue;
      final bytes = await _fetchSegmentWithRetry(mapUris[i], headers);
      await file.writeAsBytes(bytes, flush: true);
      task
        ..bytes += bytes.length
        ..updatedAt = DateTime.now().millisecondsSinceEpoch;
      _notifyProgress();
    }

    // 3) 断点续传：已有且非空的分片直接复用。
    final done = <int>{};
    var bytes = 0;
    for (var i = 0; i < total; i++) {
      final file = File(_hlsLocalSegmentPath(dir, i));
      if (!await file.exists()) continue;
      final length = await file.length();
      if (length <= 0) {
        await _deleteQuietly(file);
        continue;
      }
      done.add(i);
      bytes += length;
    }

    task
      ..ext = 'm3u8'
      ..signature = signature
      ..totalSegments = total
      ..doneSegments = done.length
      ..totalBytes = 0
      ..bytes = bytes
      ..progress = total <= 0 ? 0 : done.length / total
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    task.resetSpeed();
    _notifyNow();
    _persistSoon();

    await _downloadHlsSegments(
      task,
      playlist.segmentUris,
      headers,
      done,
      total,
      pathOf: (i) => _hlsLocalSegmentPath(dir, i),
    );

    if (_shouldStop(task)) throw const _AbortDownload();

    // 4) 校验：分片数量与 m3u8 一致、每个文件 >0；不一致整集清理并失败。
    final broken = <int>[];
    for (var i = 0; i < total; i++) {
      final file = File(_hlsLocalSegmentPath(dir, i));
      if (!await file.exists() || await file.length() <= 0) broken.add(i + 1);
    }
    if (broken.isNotEmpty) {
      await _deleteDirQuietly(dir);
      throw _CacheException(
        '分片校验失败（${broken.length}/$total 个缺失），已清理缓存，请重试',
      );
    }

    // 5) 写本地播放列表：全部相对路径，mpv 自己读 key.bin 解密。
    if (_shouldStop(task)) throw const _AbortDownload();
    final text = playlist.buildLocalPlaylist(
      keyNames: keyNames,
      mapNames: mapNames,
    );
    final tmp = File('${dir.path}/.index.m3u8.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(indexFile.path);

    var totalBytes = 0;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        totalBytes += await entity.length();
      } catch (_) {}
    }
    task
      ..filePath = indexFile.path
      ..status = DownloadStatus.completed
      ..progress = 1
      ..doneSegments = total
      ..totalSegments = total
      ..bytes = totalBytes
      ..totalBytes = totalBytes
      ..speed = 0
      ..error = null
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    _notifyNow();
    await _persist();
    await _deleteQuietly(manifestFile);
    unawaited(refreshUsage());
  }

  Future<bool> _hlsPartsMatch(
    Directory dir,
    String signature,
    int total,
  ) async {
    final manifest = File('${dir.path}/manifest.json');
    if (!await manifest.exists()) return false;
    try {
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is! Map) return false;
      return '${decoded['signature']}' == signature &&
          _asInt(decoded['total']) == total;
    } catch (_) {
      return false;
    }
  }

  String _hlsSegmentPath(Directory dir, int index) =>
      '${dir.path}/seg_${index.toString().padLeft(5, '0')}.bin';

  Future<void> _downloadHlsSegments(
    DownloadTask task,
    List<Uri> steps,
    Map<String, String> headers,
    Set<int> done,
    int total, {
    required String Function(int index) pathOf,
  }) async {
    final missing = <int>[
      for (var i = 0; i < total; i++)
        if (!done.contains(i)) i,
    ];
    if (missing.isEmpty) return;

    final workers = math.min(_concurrency, missing.length);
    var cursor = 0;
    var failed = false;
    Object? firstError;

    Future<void> worker() async {
      while (true) {
        if (failed || _shouldStop(task)) return;
        final index = cursor++;
        if (index >= missing.length) return;
        final i = missing[index];
        try {
          final chunk = await _fetchSegmentWithRetry(steps[i], headers);
          if (!_tasks.contains(task)) return;
          final file = File(pathOf(i));
          await file.writeAsBytes(chunk, flush: true);
          done.add(i);
          task
            ..doneSegments = done.length
            ..bytes += chunk.length
            ..progress = total <= 0 ? 0 : done.length / total
            ..updatedAt = DateTime.now().millisecondsSinceEpoch;
          task.sampleSpeed();
          _notifyProgress();
          _persistSoon();
          if (_shouldStop(task)) return;
        } catch (e) {
          failed = true;
          firstError ??= e;
          return;
        }
      }
    }

    await Future.wait<void>([
      for (var i = 0; i < workers; i++) worker(),
    ]);
    if (failed && firstError != null) {
      throw firstError!;
    }
  }

  /* ------------------------------------------------------------ mp4 dl */

  Future<void> _downloadMp4(
    DownloadTask task,
    Uri uri,
    Map<String, String> headers,
  ) async {
    final target = await _targetFile(task);
    await _deleteQuietly(target);
    await _deleteDirQuietly(Directory('${target.path}.hls_parts'));
    await _deleteDirQuietly(Directory('${target.path}.stream_parts'));
    await _deleteQuietly(File('${target.path}.stream_parts.part'));
    try {
      await _deleteDirQuietly(await _episodeDirectory(task));
    } catch (_) {}

    final remote = await _probeRemote(uri, headers);
    if (remote.supportsRanges && remote.totalBytes > 0) {
      await _downloadMp4Chunks(task, uri, headers, target, remote);
      return;
    }
    await _downloadMp4Stream(task, uri, headers, target, remote);
  }

  Future<_RemoteFileInfo> _probeRemote(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final request = http.Request('GET', uri)
      ..headers.addAll(_headersFor(headers))
      ..headers['Range'] = 'bytes=0-0';
    final response = await _client.send(request).timeout(_requestTimeout);
    final status = response.statusCode;
    final etag = response.headers['etag'] ?? '';
    final lastModified = response.headers['last-modified'] ?? '';
    try {
      if (status == 206) {
        final total = _totalFromContentRange(
          response.headers['content-range'] ?? '',
        );
        return _RemoteFileInfo(
          totalBytes: total,
          supportsRanges: total > 0,
          etag: etag,
          lastModified: lastModified,
        );
      }
      if (status == 200) {
        return _RemoteFileInfo(
          totalBytes: response.contentLength ?? 0,
          supportsRanges: false,
          etag: etag,
          lastModified: lastModified,
        );
      }
      if (status == 416) {
        throw const _CacheException('片源返回 HTTP 416，链接可能已失效');
      }
      throw _CacheException(
        '片源返回 HTTP $status，链接可能已失效或未授权',
      );
    } finally {
      await _discardResponse(response);
    }
  }

  Future<void> _discardResponse(http.StreamedResponse response) async {
    try {
      final subscription = response.stream.listen(null);
      await subscription.cancel();
    } catch (_) {}
  }

  int _totalFromContentRange(String value) {
    final match = RegExp(r'bytes\s+\d+-\d+/(\d+)').firstMatch(value);
    return int.tryParse(match?.group(1) ?? '') ?? 0;
  }

  Future<void> _downloadMp4Chunks(
    DownloadTask task,
    Uri uri,
    Map<String, String> headers,
    File target,
    _RemoteFileInfo remote,
  ) async {
    final total = remote.totalBytes;
    final partsDir = Directory('${target.path}.mp4_parts');
    final signature = '$total|${remote.etag}|${remote.lastModified}';
    final chunkCount = math.min(_concurrency, total);
    final chunkSize = (total / chunkCount).ceil();
    final chunks = <_Mp4Chunk>[];
    for (var start = 0, i = 0; start < total; start += chunkSize, i++) {
      final end = math.min(start + chunkSize, total) - 1;
      chunks.add(_Mp4Chunk(i, start, end));
    }

    final manifest = File('${partsDir.path}/manifest.json');
    var reuse = false;
    if (await manifest.exists()) {
      try {
        final decoded = jsonDecode(await manifest.readAsString());
        reuse = decoded is Map &&
            '${decoded['signature']}' == signature &&
            _asInt(decoded['total']) == total;
      } catch (_) {
        reuse = false;
      }
    }
    if (!reuse) {
      await _deleteDirQuietly(partsDir);
      await partsDir.create(recursive: true);
      await manifest.writeAsString(jsonEncode(<String, dynamic>{
        'version': 1,
        'signature': signature,
        'total': total,
        'chunkSize': chunkSize,
      }));
    }

    var bytes = 0;
    final missing = <_Mp4Chunk>[];
    for (final chunk in chunks) {
      final file = File(_mp4ChunkPath(partsDir, chunk));
      if (!await file.exists()) {
        missing.add(chunk);
        continue;
      }
      final length = await file.length();
      if (length > chunk.length) {
        await _deleteQuietly(file);
        missing.add(chunk);
        continue;
      }
      bytes += length;
      if (length < chunk.length) missing.add(chunk);
    }

    task
      ..ext = 'mp4'
      ..signature = signature
      ..totalSegments = 0
      ..doneSegments = chunks.length - missing.length
      ..totalBytes = total
      ..bytes = bytes
      ..progress = total <= 0 ? 0 : bytes / total
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    task.resetSpeed();
    _notifyNow();
    _persistSoon();

    if (missing.isNotEmpty) {
      final workers = math.min(_concurrency, missing.length);
      var cursor = 0;
      var failed = false;
      Object? firstError;

      Future<void> worker() async {
        while (true) {
          if (failed || _shouldStop(task)) return;
          final index = cursor++;
          if (index >= missing.length) return;
          try {
            await _downloadMp4ChunkWithRetry(
              task,
              uri,
              headers,
              partsDir,
              missing[index],
            );
            if (_shouldStop(task)) return;
          } catch (e) {
            failed = true;
            firstError ??= e;
            return;
          }
        }
      }

      await Future.wait<void>([
        for (var i = 0; i < workers; i++) worker(),
      ]);
      if (failed && firstError != null) throw firstError!;
    }

    if (_shouldStop(task)) throw const _AbortDownload();

    // 校验每个分块长度与总大小，任何一块缺失都保留已下分块供重试。
    var verifiedBytes = 0;
    for (final chunk in chunks) {
      final file = File(_mp4ChunkPath(partsDir, chunk));
      if (!await file.exists()) {
        throw _CacheException('分块 ${chunk.index + 1} 缺失，请重试');
      }
      final length = await file.length();
      if (length != chunk.length) {
        throw _CacheException('分块 ${chunk.index + 1} 大小不符，请重试');
      }
      verifiedBytes += length;
    }
    if (verifiedBytes != total) {
      throw _CacheException('分块总大小校验失败，请重试');
    }

    final part = File('${target.path}.part');
    await _deleteQuietly(part);
    final sink = part.openWrite();
    try {
      for (final chunk in chunks) {
        if (_shouldStop(task)) throw const _AbortDownload();
        await sink.addStream(File(_mp4ChunkPath(partsDir, chunk)).openRead());
      }
      await sink.flush();
      await sink.close();
    } finally {
      try {
        await sink.close();
      } catch (_) {}
    }

    if (await part.length() != total) {
      await _deleteQuietly(part);
      throw _CacheException('拼接后文件大小校验失败，请重试');
    }
    if (_shouldStop(task)) {
      await _deleteQuietly(part);
      throw const _AbortDownload();
    }
    await _finalize(
      task,
      part,
      target,
      cleanup: () => _deleteDirQuietly(partsDir),
    );
    await _deleteDirQuietly(partsDir);
  }

  String _mp4ChunkPath(Directory dir, _Mp4Chunk chunk) =>
      '${dir.path}/chunk_${chunk.index.toString().padLeft(3, '0')}.bin';

  Future<void> _downloadMp4ChunkWithRetry(
    DownloadTask task,
    Uri uri,
    Map<String, String> headers,
    Directory partsDir,
    _Mp4Chunk chunk,
  ) async {
    Object? last;
    for (var attempt = 0; attempt <= _retryCount; attempt++) {
      try {
        await _downloadMp4ChunkOnce(
          task,
          uri,
          headers,
          partsDir,
          chunk,
        );
        return;
      } on _AbortDownload {
        rethrow;
      } catch (e) {
        if (_shouldStop(task)) rethrow;
        last = e;
        if (attempt < _retryCount) {
          await Future<void>.delayed(_retryBackoff);
        }
      }
    }
    throw _RetriesExhausted(last ?? const _CacheException('分块下载失败'));
  }

  Future<void> _downloadMp4ChunkOnce(
    DownloadTask task,
    Uri uri,
    Map<String, String> headers,
    Directory partsDir,
    _Mp4Chunk chunk,
  ) async {
    final file = File(_mp4ChunkPath(partsDir, chunk));
    var existing = await file.exists() ? await file.length() : 0;
    if (existing > chunk.length) {
      await _deleteQuietly(file);
      existing = 0;
    }
    if (existing == chunk.length) return;

    final start = chunk.start + existing;
    final request = http.Request('GET', uri)
      ..headers.addAll(_headersFor(headers))
      ..headers['Range'] = 'bytes=$start-${chunk.end}';
    final response = await _client.send(request).timeout(_requestTimeout);
    if (response.statusCode == 416 && existing == chunk.length) {
      await _discardResponse(response);
      return;
    }
    if (response.statusCode != 206) {
      final code = response.statusCode;
      await _discardResponse(response);
      throw _CacheException('服务器不支持分块下载（HTTP $code）');
    }
    final rangeStart = RegExp(r'bytes\s+(\d+)-').firstMatch(
      response.headers['content-range'] ?? '',
    );
    if (rangeStart != null && int.tryParse(rangeStart.group(1)!) != start) {
      await _discardResponse(response);
      throw const _CacheException('服务器返回的分块范围不一致');
    }

    IOSink? sink;
    try {
      sink = file.openWrite(
        mode: existing > 0 ? FileMode.append : FileMode.write,
      );
      await for (final bytes in response.stream.timeout(_streamTimeout)) {
        if (_shouldStop(task)) throw const _AbortDownload();
        sink.add(bytes);
        task
          ..bytes += bytes.length
          ..progress = task.totalBytes > 0
              ? (task.bytes / task.totalBytes).clamp(0.0, 1.0).toDouble()
              : 0
          ..updatedAt = DateTime.now().millisecondsSinceEpoch;
        task.sampleSpeed();
        _notifyProgress();
        _persistSoon();
      }
      await sink.flush();
      await sink.close();
      sink = null;
    } finally {
      if (sink != null) {
        try {
          await sink.flush();
        } catch (_) {}
        try {
          await sink.close();
        } catch (_) {}
      }
    }
    final length = await file.length();
    if (length != chunk.length) {
      // 保留已写入的部分，下次从断点继续；这里只报告本次未完成。
      if (length < chunk.length) {
        throw _CacheException('分块下载不完整（${chunk.index + 1}）');
      }
      await _deleteQuietly(file);
      throw _CacheException('分块大小异常（${chunk.index + 1}）');
    }
  }

  /// 不支持 Range 的服务端兜底：单连接整文件下载，无法断点续传。
  Future<void> _downloadMp4Stream(
    DownloadTask task,
    Uri uri,
    Map<String, String> headers,
    File target,
    _RemoteFileInfo remote,
  ) async {
    final part = File('${target.path}.stream_parts.part');
    await _deleteQuietly(part);
    final request = http.Request('GET', uri);
    request.headers.addAll(_headersFor(headers));
    final response = await _client.send(request).timeout(_requestTimeout);
    if (response.statusCode != 200) {
      final code = response.statusCode;
      await _discardResponse(response);
      throw _CacheException('片源返回 HTTP $code，链接可能已失效');
    }
    final total = response.contentLength ?? remote.totalBytes;
    task
      ..ext = 'mp4'
      ..signature = 'stream|$total'
      ..totalSegments = 0
      ..doneSegments = 0
      ..totalBytes = total
      ..bytes = 0
      ..progress = 0
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    task.resetSpeed();
    _notifyNow();

    IOSink? sink;
    try {
      sink = part.openWrite();
      await for (final bytes in response.stream.timeout(_streamTimeout)) {
        if (_shouldStop(task)) throw const _AbortDownload();
        sink.add(bytes);
        task
          ..bytes += bytes.length
          ..progress =
              total > 0 ? (task.bytes / total).clamp(0.0, 1.0).toDouble() : 0
          ..updatedAt = DateTime.now().millisecondsSinceEpoch;
        task.sampleSpeed();
        _notifyProgress();
        _persistSoon();
      }
      await sink.flush();
      await sink.close();
      sink = null;
    } finally {
      if (sink != null) {
        try {
          await sink.flush();
        } catch (_) {}
        try {
          await sink.close();
        } catch (_) {}
      }
    }
    if (_shouldStop(task)) throw const _AbortDownload();
    if (total > 0 && await part.length() != total) {
      await _deleteQuietly(part);
      throw _CacheException('文件大小校验失败，请重试');
    }
    await _finalize(task, part, target);
  }

  /* --------------------------------------------------------- finalize */

  /// 把临时文件改名为成品并校验；校验失败删除损坏文件并抛
  /// [_CorruptFileException]。调用方会把任务标为失败。
  Future<void> _finalize(
    DownloadTask task,
    File part,
    File target, {
    Future<void> Function()? cleanup,
  }) async {
    if (_shouldStop(task)) {
      await _deleteQuietly(part);
      throw const _AbortDownload();
    }
    await _deleteQuietly(target);
    final file = await part.rename(target.path);
    final error = await _validateMediaFile(file);
    if (error != null) {
      await _deleteQuietly(file);
      if (cleanup != null) await cleanup();
      task
        ..filePath = null
        ..bytes = 0
        ..totalBytes = 0
        ..doneSegments = 0
        ..totalSegments = 0
        ..progress = 0
        ..speed = 0
        ..updatedAt = DateTime.now().millisecondsSinceEpoch;
      throw _CorruptFileException('缓存校验失败：$error');
    }
    task
      ..filePath = file.path
      ..status = DownloadStatus.completed
      ..progress = 1
      ..bytes = await file.length()
      ..speed = 0
      ..error = null
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    _notifyNow();
    await _persist();
    unawaited(refreshUsage());
  }

  /// 下载完成校验：文件必须 >0；ffprobe 可用时以时长 >0 为准，否则
  /// 至少要求大于 1MB（避免把错误页 / 空分片拼成的文件当成功）。
  Future<String?> _validateMediaFile(File file) async {
    if (!await file.exists()) return '文件不存在';
    final length = await file.length();
    if (length <= 0) return '文件为空';
    final probe = await _probeDuration(file);
    if (probe.available) {
      final duration = probe.duration;
      if (duration != null && duration > Duration.zero) return null;
      return '无法解析视频时长，文件可能已损坏';
    }
    if (length > _minValidBytes) return null;
    return '文件仅 ${_fmtBytes(length)}，可能未下载完整';
  }

  Future<_ProbeResult> _probeDuration(File file) async {
    if (_ffprobeUnavailable) {
      return const _ProbeResult(available: false, duration: null);
    }
    try {
      final result = await Process.run(
        'ffprobe',
        <String>[
          '-v',
          'error',
          '-select_streams',
          'v:0',
          '-show_entries',
          'format=duration',
          '-of',
          'default=noprint_wrappers=1:nokey=1',
          file.path,
        ],
      ).timeout(const Duration(seconds: 8));
      if (result.exitCode != 0) {
        return const _ProbeResult(available: true, duration: null);
      }
      final text = '${result.stdout}'.trim();
      final seconds = double.tryParse(text);
      return _ProbeResult(
        available: true,
        duration: seconds == null || seconds <= 0
            ? null
            : Duration(milliseconds: (seconds * 1000).round()),
      );
    } on ProcessException {
      _ffprobeUnavailable = true;
      debugPrint('DownloadService: ffprobe 不可用，退化为文件大小校验');
      return const _ProbeResult(available: false, duration: null);
    } on TimeoutException {
      // 探测超时不代表文件损坏，交给大小校验兜底。
      return const _ProbeResult(available: false, duration: null);
    } catch (e) {
      debugPrint('DownloadService: ffprobe failed: $e');
      return const _ProbeResult(available: false, duration: null);
    }
  }

  /* ------------------------------------------------------------- fetch */

  Future<List<int>> _fetchSegmentWithRetry(
    Uri uri,
    Map<String, String> headers,
  ) async {
    Object? last;
    for (var attempt = 0; attempt <= _retryCount; attempt++) {
      try {
        return await _fetchBytesOnce(uri, headers);
      } catch (e) {
        // 每个分片最多重试 2 次，固定 300ms 退避；4xx 也重试一次，
        // 部分 CDN 会在限流时短暂返回 403。
        last = e;
        if (attempt < _retryCount) {
          await Future<void>.delayed(_retryBackoff);
        }
      }
    }
    throw _RetriesExhausted(last ?? const _CacheException('分片下载失败'));
  }

  Future<List<int>> _fetchBytesOnce(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final response = await _client
        .get(uri, headers: _headersFor(headers))
        .timeout(_requestTimeout);
    if (response.statusCode == 200 || response.statusCode == 206) {
      final bytes = response.bodyBytes;
      if (bytes.isEmpty) {
        throw const _CacheException('片源返回空分片');
      }
      return bytes;
    }
    if (response.statusCode >= 500) {
      throw http.ClientException('HTTP ${response.statusCode}', uri);
    }
    throw _CacheException(
      '片源返回 HTTP ${response.statusCode}，链接可能已失效或未授权',
    );
  }

  Future<_PlaylistData> _fetchPlaylist(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final response = await _withRetry(() async {
      final res = await _client
          .get(uri, headers: _headersFor(headers))
          .timeout(_requestTimeout);
      if (res.statusCode == 200 || res.statusCode == 206) {
        if (res.bodyBytes.isEmpty) {
          throw const _CacheException('播放列表为空');
        }
        return res;
      }
      if (res.statusCode >= 500) {
        throw http.ClientException('HTTP ${res.statusCode}', uri);
      }
      throw _CacheException(
        '片源返回 HTTP ${res.statusCode}，链接可能已失效或未授权',
      );
    });
    final text = utf8
        .decode(response.bodyBytes, allowMalformed: true)
        .replaceFirst('\uFEFF', '');
    if (!text.trimLeft().startsWith('#EXTM3U')) {
      throw const _CacheException('片源不是有效的 HLS 播放列表');
    }
    // 跟随 302 后，相对分片地址应相对最终地址解析。
    return _PlaylistData(text, response.request?.url ?? uri);
  }

  Future<T> _withRetry<T>(Future<T> Function() action) async {
    Object? last;
    for (var attempt = 0; attempt <= _retryCount; attempt++) {
      try {
        return await action();
      } catch (e) {
        if (e is _CacheException) rethrow;
        last = e;
        if (attempt < _retryCount) {
          await Future<void>.delayed(_retryBackoff);
        }
      }
    }
    throw _RetriesExhausted(last!);
  }

  List<_Variant> _parseVariants(String playlist, Uri base) {
    final lines = playlist.split(RegExp(r'\r?\n'));
    final out = <_Variant>[];
    int? bandwidth;
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#EXT-X-STREAM-INF')) {
        final match = RegExp(r'BANDWIDTH\s*=\s*(\d+)').firstMatch(line);
        bandwidth = int.tryParse(match?.group(1) ?? '') ?? 0;
        continue;
      }
      if (line.startsWith('#')) continue;
      if (bandwidth != null) {
        out.add(_Variant(bandwidth, base.resolve(line)));
        bandwidth = null;
      }
    }
    return out;
  }

  /// 解析媒体播放列表：保留头部标签、分片顺序、EXTINF、KEY / MAP 变化。
  _HlsPlaylist _parseHlsPlaylist(String playlist, Uri base) {
    final headerLines = <String>[];
    final segments = <_HlsSegment>[];
    final keys = <_HlsKey>[];
    final maps = <_HlsMap>[];
    final keyMap = <String, _HlsKey>{};
    final mapMap = <String, _HlsMap>{};

    _HlsKey? currentKey;
    _HlsMap? currentMap;
    var pendingExtinf = '';
    var pendingDiscontinuity = false;

    for (final raw in playlist.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        if (line.startsWith('#EXT-X-BYTERANGE')) {
          throw const _CacheException('按字节范围切片的 HLS 暂不支持离线缓存');
        }
        if (line.startsWith('#EXT-X-KEY:')) {
          final parsed = _parseHlsKey(line, base);
          if (parsed == null) {
            currentKey = null;
          } else {
            final id = '${parsed.method}|${parsed.uri}|${parsed.iv ?? ''}';
            currentKey = keyMap.putIfAbsent(id, () {
              keys.add(parsed);
              return parsed;
            });
          }
          continue;
        }
        if (line.startsWith('#EXT-X-MAP:')) {
          final parsed = _parseHlsMap(line, base);
          if (parsed != null) {
            final id = parsed.uri.toString();
            currentMap = mapMap.putIfAbsent(id, () {
              maps.add(parsed);
              return parsed;
            });
          }
          continue;
        }
        if (line == '#EXT-X-DISCONTINUITY') {
          pendingDiscontinuity = true;
          continue;
        }
        if (line.startsWith('#EXTINF:')) {
          pendingExtinf = line;
          continue;
        }
        if (_isPreservedHlsTag(line)) headerLines.add(line);
        continue;
      }

      final uri = base.resolve(line);
      if (uri.scheme != 'http' && uri.scheme != 'https') {
        throw const _CacheException('分片地址不是 http/https 直链，暂不支持离线缓存');
      }
      segments.add(_HlsSegment(
        uri: uri,
        extinf: pendingExtinf,
        duration: _extinfDuration(pendingExtinf),
        key: currentKey,
        map: currentMap,
        discontinuity: pendingDiscontinuity,
      ));
      pendingExtinf = '';
      pendingDiscontinuity = false;
    }

    return _HlsPlaylist(
      headerLines: headerLines,
      segments: segments,
      keys: keys,
      maps: maps,
    );
  }

  _HlsKey? _parseHlsKey(String line, Uri base) {
    final colon = line.indexOf(':');
    if (colon < 0) return null;
    final attrs = _hlsAttributes(line.substring(colon + 1));
    final method = (attrs['METHOD'] ?? 'NONE').toUpperCase();
    if (method.isEmpty || method == 'NONE') return null;
    if (method != 'AES-128') {
      throw _CacheException('暂不支持 $method 加密的 HLS 离线缓存');
    }
    final format = (attrs['KEYFORMAT'] ?? 'identity').toLowerCase();
    if (format.isNotEmpty && format != 'identity') {
      throw _CacheException('暂不支持 $format 密钥格式的 HLS 离线缓存');
    }
    final raw = attrs['URI'] ?? '';
    if (raw.isEmpty) {
      throw const _CacheException('加密播放列表缺少密钥地址');
    }
    final uri = base.resolve(raw);
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const _CacheException('密钥地址不是 http/https 直链，暂不支持离线缓存');
    }
    return _HlsKey(method: method, uri: uri, iv: attrs['IV']);
  }

  _HlsMap? _parseHlsMap(String line, Uri base) {
    final colon = line.indexOf(':');
    if (colon < 0) return null;
    final attrs = _hlsAttributes(line.substring(colon + 1));
    if ((attrs['BYTERANGE'] ?? '').isNotEmpty) {
      throw const _CacheException('按字节范围切片的 HLS 暂不支持离线缓存');
    }
    final raw = attrs['URI'] ?? '';
    if (raw.isEmpty) return null;
    final uri = base.resolve(raw);
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const _CacheException('初始化分片地址不是 http/https 直链，暂不支持离线缓存');
    }
    return _HlsMap(uri);
  }

  Map<String, String> _hlsAttributes(String text) {
    final out = <String, String>{};
    final pattern = RegExp(r'([A-Za-z0-9-]+)=("[^"]*"|[^,]*)');
    for (final match in pattern.allMatches(text)) {
      final name = match.group(1)!.toUpperCase();
      var value = match.group(2) ?? '';
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      out[name] = value.trim();
    }
    return out;
  }

  double _extinfDuration(String extinf) {
    final colon = extinf.indexOf(':');
    if (colon < 0) return 0;
    final comma = extinf.indexOf(',', colon);
    final raw = comma < 0
        ? extinf.substring(colon + 1)
        : extinf.substring(colon + 1, comma);
    return double.tryParse(raw.trim()) ?? 0;
  }

  bool _isPreservedHlsTag(String line) {
    for (final tag in _hlsHeaderTags) {
      if (line.startsWith(tag)) return true;
    }
    return false;
  }

  String _signature(List<Uri> segments) {
    final first = segments.isEmpty ? '' : segments.first.toString();
    final last = segments.isEmpty ? '' : segments.last.toString();
    return '${segments.length}|$first|$last';
  }

  Map<String, String> _headersFor(Map<String, String> extra) {
    final headers = <String, String>{
      'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
      'Accept': '*/*',
      'Accept-Encoding': 'identity',
    };
    extra.forEach((key, value) {
      final name = key.trim();
      if (name.isEmpty) return;
      headers.removeWhere((k, _) => k.toLowerCase() == name.toLowerCase());
      headers[name] = value;
    });
    return headers;
  }

  /* --------------------------------------------------------- storage */

  /// 目录由 [DownloadStorage] 解析：默认公共 Download，系统限制时回退到
  /// 应用专属外部目录；也可在设置里切换为应用私有目录。
  Future<Directory> _rootDir() async {
    final cached = _rootDirCache;
    if (cached != null) return cached;
    _storageInfo ??= await DownloadStorage.resolve(_location);
    final dir = Directory(_storageInfo!.path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _rootDirCache = dir;
    return dir;
  }

  /// 目录名：`剧名 (年份)`；没有年份时退化为 `剧名`。
  String seriesFolderName(DownloadTask task) {
    final title = sanitizeDownloadName(task.title, fallback: '未命名影片');
    return task.year > 0 ? '$title (${task.year})' : title;
  }

  /// 文件名：电影 `剧名.年份.1080P.mp4`；
  /// 剧集 `剧名.SxxExx.第N集.mp4`（S01 为默认季）。
  String episodeFileName(DownloadTask task) {
    final title = sanitizeDownloadName(task.title, fallback: '未命名影片');
    if (task.isMovie) {
      final year = task.year > 0 ? '.${task.year}' : '';
      return '$title$year.1080P.mp4';
    }
    final ep = task.ep < 1 ? 1 : task.ep;
    final episode = ep.toString().padLeft(2, '0');
    return '$title.S01E$episode.第$ep集.mp4';
  }

  Future<Directory> _seriesDirectory(DownloadTask task) async {
    final root = await _rootDir();
    return Directory('${root.path}/${seriesFolderName(task)}');
  }

  Future<Directory> _seriesDir(DownloadTask task) async {
    final dir = await _seriesDirectory(task);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 按当前目录规则计算成品路径；不创建目录，可用于只读检查 / 删除。
  Future<File> _expectedTarget(DownloadTask task) async {
    final root = await _rootDir();
    return File(
      '${root.path}/${seriesFolderName(task)}/${episodeFileName(task)}',
    );
  }

  /// 任务的成品路径；优先使用已记录的绝对路径（兼容换目录 / 旧版本）。
  Future<File> _targetFile(DownloadTask task) async {
    final recorded = task.filePath;
    if (recorded != null && recorded.isNotEmpty) {
      final file = File(recorded);
      if (await file.exists()) return file;
    }
    await _seriesDir(task);
    return _expectedTarget(task);
  }

  /// 旧版本每个任务一个 `<id>_<ep>` 目录，读取时兼容一下。
  Future<File?> _legacyFile(DownloadTask task) async {
    final roots = <String>{};
    try {
      roots.add((await _rootDir()).path);
    } catch (_) {}
    try {
      roots.addAll(await DownloadStorage.knownRootPaths());
    } catch (_) {}
    final exts = <String>[
      if (task.ext.trim().isNotEmpty) task.ext.trim(),
      'ts',
      'mp4',
    ];
    for (final rootPath in roots) {
      final dir = Directory('$rootPath/${_safeSegment(task.id)}_${task.ep}');
      for (final ext in exts.toSet()) {
        final file = File('${dir.path}/ep_${task.ep}.$ext');
        if (await file.exists()) return file;
      }
    }
    return null;
  }

  Future<File?> _existingFile(DownloadTask task) async {
    final path = task.filePath;
    if (path != null && path.isNotEmpty) {
      final file = File(path);
      if (await file.exists()) return file;
    }
    try {
      if (task.isHlsLocal) {
        final index =
            File('${(await _episodeDirectory(task)).path}/index.m3u8');
        if (await index.exists()) return index;
      }
      final expected = await _expectedTarget(task);
      if (await expected.exists()) return expected;
    } catch (_) {}
    return _legacyFile(task);
  }

  Future<void> _deleteTaskFiles(DownloadTask task) async {
    final target = await _expectedTarget(task);
    await _deleteQuietly(target);
    await _deleteQuietly(File('${target.path}.part'));
    await _deleteDirQuietly(Directory('${target.path}.hls_parts'));
    await _deleteDirQuietly(Directory('${target.path}.mp4_parts'));
    await _deleteQuietly(File('${target.path}.stream_parts.part'));

    // 目录式 HLS：`epNN/` 里是 index.m3u8 + 分片 + key，整目录删除。
    try {
      await _deleteDirQuietly(await _episodeDirectory(task));
    } catch (_) {}

    final filePath = task.filePath;
    if (filePath != null && filePath.isNotEmpty) {
      final file = File(filePath);
      await _deleteQuietly(file);
      await _deleteQuietly(File('${file.path}.part'));
      await _deleteDirQuietly(Directory('${file.path}.hls_parts'));
      await _deleteDirQuietly(Directory('${file.path}.mp4_parts'));
      await _deleteQuietly(File('${file.path}.stream_parts.part'));
      // 换过下载目录时，filePath 的父目录就是实际集目录。
      if (file.path.endsWith('/index.m3u8')) {
        await _deleteDirQuietly(file.parent);
      }
    }

    // 旧版每集一个目录：整个目录可以安全删除。
    try {
      final root = await _rootDir();
      await _deleteDirQuietly(
        Directory('${root.path}/${_safeSegment(task.id)}_${task.ep}'),
      );
    } catch (_) {}
    try {
      for (final rootPath in await DownloadStorage.knownRootPaths()) {
        await _deleteDirQuietly(
          Directory('$rootPath/${_safeSegment(task.id)}_${task.ep}'),
        );
      }
    } catch (_) {}

    // 系列目录只有在空了以后才删除，不能误删同剧其它集。
    try {
      final dir = await _seriesDirectory(task);
      if (await dir.exists()) {
        final left = await dir.list(followLinks: false).isEmpty;
        if (left) await dir.delete();
      }
    } catch (_) {}
  }

  /* --------------------------------------------------------- persistence */

  void _notifyNow() {
    if (_disposed) return;
    _lastNotify = DateTime.now();
    notifyListeners();
  }

  void _notifyProgress() {
    if (_disposed) return;
    final now = DateTime.now();
    if (now.difference(_lastNotify) < _notifyGap) return;
    _lastNotify = now;
    notifyListeners();
  }

  void _persistSoon() {
    if (_disposed) return;
    _persistTimer ??= Timer(const Duration(milliseconds: 900), () {
      _persistTimer = null;
      unawaited(_persist());
    });
  }

  Future<void> _persist() async {
    if (_persisting) {
      _persistAgain = true;
      return;
    }
    _persisting = true;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
        queuePrefsKey,
        jsonEncode(<String, dynamic>{
          'version': 1,
          'tasks': _tasks.map((t) => t.toJson()).toList(),
        }),
      );
      // 兼容「我的」页面的缓存计数读取旧 key。
      await sp.setStringList(
        legacyPrefsKey,
        _tasks.map((t) => jsonEncode(_legacyMap(t))).toList(),
      );
    } catch (e) {
      debugPrint('DownloadService: persist failed: $e');
    } finally {
      _persisting = false;
      if (_persistAgain) {
        _persistAgain = false;
        await _persist();
      }
    }
  }

  Map<String, dynamic> _legacyMap(DownloadTask task) => <String, dynamic>{
        'id': task.id,
        'title': task.title,
        'cover': task.cover,
        'ep': task.ep,
        'epName': task.epName,
        'size': task.bytes,
        'status':
            task.status == DownloadStatus.completed ? '已下载' : task.status.label,
        'line': task.lineName,
        'updatedAt': task.updatedAt,
      };

  String _friendlyError(Object? error) {
    if (error is _RetriesExhausted) {
      final base = _friendlyError(error.cause);
      return base.endsWith('（已重试 2 次）') ? base : '$base（已重试 2 次）';
    }
    if (error is _CacheException) return error.message;
    if (error is ApiException) return '获取播放地址失败：${error.message}';
    if (error is TimeoutException) return '连接超时，请检查网络后重试';
    if (error is SocketException) return '网络不可用，请检查网络连接';
    if (error is http.ClientException) return '网络请求失败，片源暂时不可用';
    if (error is FileSystemException) {
      return '写入缓存失败，请检查存储空间是否充足';
    }
    if (error is FormatException) return '播放列表解析失败';
    final text = '$error';
    final short = text.length > 80 ? '${text.substring(0, 80)}…' : text;
    return '缓存失败：$short';
  }
}

class _Variant {
  const _Variant(this.bandwidth, this.uri);
  final int bandwidth;
  final Uri uri;
}

/// 生成离线 index.m3u8 时需要原样保留的头部标签。
const List<String> _hlsHeaderTags = <String>[
  '#EXT-X-VERSION:',
  '#EXT-X-TARGETDURATION:',
  '#EXT-X-MEDIA-SEQUENCE:',
  '#EXT-X-DISCONTINUITY-SEQUENCE:',
  '#EXT-X-PLAYLIST-TYPE:',
  '#EXT-X-INDEPENDENT-SEGMENTS',
  '#EXT-X-START:',
  '#EXT-X-ALLOW-CACHE:',
];

/// 解析后的媒体播放列表；KEY / MAP 只保留不重复的对象。
class _HlsPlaylist {
  _HlsPlaylist({
    required this.headerLines,
    required this.segments,
    required this.keys,
    required this.maps,
  });

  final List<String> headerLines;
  final List<_HlsSegment> segments;
  final List<_HlsKey> keys;
  final List<_HlsMap> maps;

  bool get encrypted => keys.isNotEmpty;

  Uri? get firstMapUri => maps.isEmpty ? null : maps.first.uri;

  List<Uri> get segmentUris => <Uri>[for (final s in segments) s.uri];

  /// 密钥文件去重：同一 key 地址配不同 IV 时只下载一份。
  List<Uri> get keyUris {
    final seen = <String>{};
    return <Uri>[
      for (final key in keys)
        if (seen.add(key.uri.toString())) key.uri,
    ];
  }

  List<Uri> get mapUris => <Uri>[for (final m in maps) m.uri];

  /// 断点续传指纹：分片数量 / 首尾分片 / 密钥 / init 变化都会失效。
  String get signature {
    final first = segments.isEmpty ? '' : segments.first.uri.toString();
    final last = segments.isEmpty ? '' : segments.last.uri.toString();
    final keyList = keyUris.map((u) => u.toString()).join(',');
    final mapList = mapUris.map((u) => u.toString()).join(',');
    return '${segments.length}|$first|$last|$keyList|$mapList';
  }

  /// 生成本地播放列表：分片 / key / init 全部使用同目录相对路径。
  String buildLocalPlaylist({
    required Map<String, String> keyNames,
    required Map<String, String> mapNames,
  }) {
    final out = StringBuffer('#EXTM3U\n');
    for (final line in headerLines) {
      out.writeln(line);
    }
    if (!headerLines.any((l) => l.startsWith('#EXT-X-TARGETDURATION'))) {
      var longest = 0.0;
      for (final segment in segments) {
        if (segment.duration > longest) longest = segment.duration;
      }
      final target = longest.ceil();
      out.writeln('#EXT-X-TARGETDURATION:${target < 1 ? 1 : target}');
    }

    _HlsKey? lastKey;
    _HlsMap? lastMap;
    var wroteKey = false;
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      if (segment.key != lastKey) {
        final key = segment.key;
        if (key == null) {
          if (wroteKey) out.writeln('#EXT-X-KEY:METHOD=NONE');
        } else {
          final name = keyNames[key.uri.toString()];
          if (name == null) {
            throw const _CacheException('密钥文件缺失，请重新下载');
          }
          out.writeln(key.tag(name));
        }
        lastKey = key;
        wroteKey = true;
      }
      if (segment.map != null && segment.map != lastMap) {
        final name = mapNames[segment.map!.uri.toString()];
        if (name != null) {
          out.writeln('#EXT-X-MAP:URI="$name"');
          lastMap = segment.map;
        }
      }
      if (segment.discontinuity) out.writeln('#EXT-X-DISCONTINUITY');
      if (segment.extinf.isNotEmpty) out.writeln(segment.extinf);
      out.writeln('seg${(i + 1).toString().padLeft(5, '0')}.ts');
    }
    out.writeln('#EXT-X-ENDLIST');
    return out.toString();
  }
}

class _HlsSegment {
  const _HlsSegment({
    required this.uri,
    required this.extinf,
    required this.duration,
    required this.key,
    required this.map,
    required this.discontinuity,
  });

  final Uri uri;
  final String extinf;
  final double duration;
  final _HlsKey? key;
  final _HlsMap? map;
  final bool discontinuity;
}

class _HlsKey {
  const _HlsKey({
    required this.method,
    required this.uri,
    required this.iv,
  });

  final String method;
  final Uri uri;
  final String? iv;

  String tag(String localName) {
    final out = StringBuffer('#EXT-X-KEY:METHOD=$method,URI="$localName"');
    final value = iv;
    if (value != null && value.isNotEmpty) out.write(',IV=$value');
    return out.toString();
  }
}

class _HlsMap {
  const _HlsMap(this.uri);
  final Uri uri;
}

class _PlaylistData {
  const _PlaylistData(this.text, this.uri);
  final String text;
  final Uri uri;
}

class _RemoteFileInfo {
  const _RemoteFileInfo({
    required this.totalBytes,
    required this.supportsRanges,
    required this.etag,
    required this.lastModified,
  });

  final int totalBytes;
  final bool supportsRanges;
  final String etag;
  final String lastModified;
}

class _Mp4Chunk {
  const _Mp4Chunk(this.index, this.start, this.end);

  final int index;
  final int start;
  final int end;

  int get length => end - start + 1;
}

class _ProbeResult {
  const _ProbeResult({required this.available, required this.duration});

  /// ffprobe 是否存在：false 表示环境里没有 ffprobe，需要退回大小校验。
  final bool available;

  /// ffprobe 解析出的时长；available 为 true 但这里为 null 表示文件损坏。
  final Duration? duration;
}

class _CacheException implements Exception {
  const _CacheException(this.message);
  final String message;

  @override
  String toString() => message;
}

class _CorruptFileException extends _CacheException {
  const _CorruptFileException(super.message);
}

class _RetriesExhausted implements Exception {
  _RetriesExhausted(this.cause);
  final Object cause;

  @override
  String toString() => '$cause';
}

class _AbortDownload implements Exception {
  const _AbortDownload();
}

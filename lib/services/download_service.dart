import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
        DownloadStatus.completed => '已缓存',
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
  });

  final String id;
  final String title;
  final String cover;
  final int ep;
  final String epName;
  final String line;
  final String lineName;
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

  DownloadStatus status;
  double progress = 0;
  int bytes = 0;
  int totalBytes = 0;
  int doneSegments = 0;
  int totalSegments = 0;
  String ext = 'ts';
  String signature = '';
  String? filePath;
  String? error;
  int updatedAt;

  String get key => '$id#$ep';

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

  /// 下载中的副标题：HLS 显示片数，MP4 显示已下载/总大小。
  String get progressDetail {
    if (status == DownloadStatus.completed) return sizeLabel;
    if (totalSegments > 0) {
      final done = doneSegments.clamp(0, totalSegments);
      return '$done/$totalSegments 片 · ${sizeLabel}';
    }
    if (totalBytes > 0) {
      return '${sizeLabel} / ${_fmtBytes(totalBytes)}';
    }
    return sizeLabel;
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
      status: status,
    )
      ..updatedAt = _asInt(j['updatedAt'], now)
      ..progress = _asDouble(j['progress'])
      ..bytes = _asInt(j['bytes'])
      ..totalBytes = _asInt(j['totalBytes'])
      ..doneSegments = _asInt(j['doneSegments'])
      ..totalSegments = _asInt(j['totalSegments'])
      ..ext = '${j['ext'] ?? 'ts'}'
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
class DownloadService extends ChangeNotifier {
  DownloadService._();

  static final DownloadService instance = DownloadService._();

  static const String queuePrefsKey = 'fx_download_queue_v1';
  static const String legacyPrefsKey = 'fx_downloads_v1';

  static const Duration _requestTimeout = Duration(seconds: 30);
  static const Duration _notifyGap = Duration(milliseconds: 220);

  final List<DownloadTask> _tasks = <DownloadTask>[];
  final http.Client _client = http.Client();

  bool _ready = false;
  bool _pumping = false;
  bool _persisting = false;
  bool _persistAgain = false;
  Future<void>? _initFuture;
  Timer? _persistTimer;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  DownloadLocation _location = DownloadLocation.phone;
  DownloadStorageInfo? _storageInfo;
  Directory? _rootDirCache;
  int _usedBytes = 0;
  bool _usageLoading = false;

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

  /// 只读任务列表（按加入时间排序，与持久化顺序一致）。
  List<DownloadTask> get tasks => List<DownloadTask>.unmodifiable(_tasks);

  /// 启动恢复：加载队列；未完成的标记为暂停；已完成但文件丢失的标记失败。
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
          task.status = DownloadStatus.failed;
          task.error = '缓存文件已被系统清理，请重新下载';
          task.filePath = null;
          task.updatedAt = now;
        } else {
          task.filePath = file.path;
          task.bytes = await file.length();
          task.progress = 1;
        }
      }
    }
  }

  /// 已缓存的集（同剧同集不区分线路）。
  bool isCached(String id, int ep) => _tasks.any(
      (t) => t.id == id && t.ep == ep && t.status == DownloadStatus.completed);

  DownloadTask? taskFor(String id, int ep) {
    for (final t in _tasks) {
      if (t.id == id && t.ep == ep) return t;
    }
    return null;
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
    if (requests.isEmpty) return 0;
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
          ..status = DownloadStatus.queued
          ..progress = 0
          ..bytes = 0
          ..totalBytes = 0
          ..doneSegments = 0
          ..totalSegments = 0
          ..signature = ''
          ..filePath = null
          ..error = null
          ..updatedAt = now;
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
    task.status = DownloadStatus.paused;
    task.updatedAt = DateTime.now().millisecondsSinceEpoch;
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
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
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
          ..updatedAt = now;
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
    _tasks.remove(task);
    _notifyNow();
    await _persist();
    await _deleteTaskFiles(task);
    await refreshUsage();
  }

  /// 清空全部任务与缓存文件。
  Future<void> clearAll() async {
    final old = List<DownloadTask>.from(_tasks);
    _tasks.clear();
    _notifyNow();
    await _persist();
    for (final task in old) {
      await _deleteTaskFiles(task);
    }
    // 删除所有已知缓存目录里的残留（包括下载中断留下的 .part）。
    await DownloadStorage.clearAllCaches();
    _rootDirCache = null;
    _storageInfo = await DownloadStorage.resolve(_location);
    await _rootDir();
    await refreshUsage();
  }

  /* -------------------------------------------------------------- worker */

  void _kick() {
    if (!_ready) return;
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_pumping || !_ready) return;
    _pumping = true;
    try {
      String? abortKey;
      var abortStreak = 0;
      while (true) {
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
      if (_tasks.any((t) => t.status == DownloadStatus.queued)) {
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
        ..updatedAt = DateTime.now().millisecondsSinceEpoch;
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
          ..error = _friendlyError(e)
          ..updatedAt = DateTime.now().millisecondsSinceEpoch;
        await _persist();
      }
    } finally {
      _notifyNow();
      unawaited(refreshUsage());
    }
    return aborted;
  }

  /// 只有任务被删除或被暂停才中断下载；排队（queued）不算停止，
  /// 否则刚拿到播放地址就会误 abort，任务永远原地重排。
  bool _shouldStop(DownloadTask task) =>
      !_tasks.contains(task) || task.status == DownloadStatus.paused;

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

  Uri _ensureAuthorized(Uri? uri) {
    // 合规：只缓存接口给出的 http/https 直链，拒绝 file:/data:/其他协议。
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw const _CacheException('播放地址未获授权，仅支持 http/https 直链');
    }
    return uri;
  }

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

    final lines = playlist.split(RegExp(r'\r?\n'));
    for (final line in lines) {
      final value = line.trim();
      if (value.startsWith('#EXT-X-KEY')) {
        final match = RegExp(r'METHOD\s*=\s*([A-Za-z0-9-]+)').firstMatch(value);
        final method = (match?.group(1) ?? '').toUpperCase();
        if (method.isNotEmpty && method != 'NONE') {
          throw const _CacheException('加密 HLS 暂不支持离线缓存');
        }
      }
      if (value.startsWith('#EXT-X-BYTERANGE')) {
        throw const _CacheException('按字节范围切片的 HLS 暂不支持离线缓存');
      }
    }
    if (playlist.contains('#EXT-X-STREAM-INF')) {
      throw const _CacheException('播放列表嵌套层级过多，暂不支持');
    }
    if (!playlist.contains('#EXT-X-ENDLIST')) {
      throw const _CacheException('直播或未完结的 HLS 暂不支持离线缓存');
    }

    final mapUri = _parseMapUri(playlist, mediaUri);
    final segments = _parseSegments(playlist, mediaUri);
    if (segments.isEmpty) {
      throw const _CacheException('播放列表里没有分片');
    }

    final steps = <Uri>[
      if (mapUri != null) mapUri,
      ...segments,
    ];
    final total = steps.length;
    final ext = mapUri == null ? 'ts' : 'mp4';
    final signature = _signature(segments);

    final dir = await _taskDir(task);
    // 分片按类型分名：HLS 与 MP4 的字节格式不同，不能共用同一个 .part。
    final part = File('${dir.path}/ep_${task.ep}.hls.part');
    final target = File('${dir.path}/ep_${task.ep}.$ext');
    // 类型不一致（上次是 MP4 直链）或旧版命名：删掉重下，避免拼接损坏。
    await _deleteQuietly(File('${dir.path}/ep_${task.ep}.mp4.part'));
    await _deleteQuietly(File('${dir.path}/ep_${task.ep}.part'));

    var start = 0;
    if (task.ext == ext &&
        task.totalSegments == total &&
        task.signature == signature &&
        task.doneSegments > 0 &&
        task.doneSegments <= total &&
        await part.exists() &&
        await part.length() == task.bytes) {
      // 断点续传：.part 里只会有完整分片，跳过已写入的部分。
      start = task.doneSegments;
    } else {
      if (await part.exists()) {
        try {
          await part.delete();
        } catch (_) {}
      }
      start = 0;
    }

    task
      ..ext = ext
      ..signature = signature
      ..totalSegments = total
      ..doneSegments = start
      ..totalBytes = 0
      ..progress = total <= 0 ? 0 : start / total
      ..bytes = start == 0 ? 0 : task.bytes
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    _notifyNow();
    _persistSoon();

    IOSink? sink;
    try {
      sink = part.openWrite(
        mode: start > 0 ? FileMode.append : FileMode.write,
      );
      for (var i = start; i < total; i++) {
        if (_shouldStop(task)) throw const _AbortDownload();
        final chunk = await _fetchBytes(steps[i], headers);
        sink.add(chunk);
        task
          ..doneSegments = i + 1
          ..bytes += chunk.length
          ..progress = (i + 1) / total
          ..updatedAt = DateTime.now().millisecondsSinceEpoch;
        _notifyProgress();
        _persistSoon();
      }
      if (_shouldStop(task)) throw const _AbortDownload();
      await sink.flush();
      await sink.close();
      sink = null;

      if (_shouldStop(task)) throw const _AbortDownload();
      if (await target.exists()) {
        try {
          await target.delete();
        } catch (_) {}
      }
      final file = await part.rename(target.path);
      task
        ..filePath = file.path
        ..status = DownloadStatus.completed
        ..progress = 1
        ..bytes = await file.length()
        ..error = null
        ..updatedAt = DateTime.now().millisecondsSinceEpoch;
      _notifyNow();
      await _persist();
      unawaited(refreshUsage());
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
  }

  /* ------------------------------------------------------------ mp4 dl */

  Future<void> _downloadMp4(
    DownloadTask task,
    Uri uri,
    Map<String, String> headers,
  ) async {
    final dir = await _taskDir(task);
    final part = File('${dir.path}/ep_${task.ep}.mp4.part');
    final target = File('${dir.path}/ep_${task.ep}.mp4');

    // 类型不一致（上次是 HLS 或旧版命名）的 .part 必须删除重下，
    // 否则会把 TS 分片与 MP4 Range 响应拼成一个损坏文件。
    await _deleteQuietly(File('${dir.path}/ep_${task.ep}.hls.part'));
    await _deleteQuietly(File('${dir.path}/ep_${task.ep}.part'));

    // 以本地 .part 的真实长度作为断点，避免上次异常退出时 task.bytes
    // 比实际写入多，Range 跳过尚未落盘的数据导致文件损坏。
    var received = 0;
    if (task.ext.toLowerCase() == 'mp4' && await part.exists()) {
      received = await part.length();
    } else if (await part.exists()) {
      await _deleteQuietly(part);
    }

    task
      ..ext = 'mp4'
      ..totalSegments = 0
      ..doneSegments = 0
      ..bytes = received
      ..totalBytes = 0
      ..progress = 0
      ..updatedAt = DateTime.now().millisecondsSinceEpoch;
    _notifyNow();

    final request = http.Request('GET', uri);
    request.headers.addAll(_headersFor(headers));
    if (received > 0) {
      request.headers['Range'] = 'bytes=$received-';
    }

    IOSink? sink;
    try {
      final response = await _client.send(request).timeout(_requestTimeout);
      if (response.statusCode == 416) {
        // 断点已失效：清掉本地分片，让用户下次从头下载。
        if (await part.exists()) {
          try {
            await part.delete();
          } catch (_) {}
        }
        task
          ..bytes = 0
          ..totalBytes = 0
          ..progress = 0;
        throw const _CacheException('本地断点已失效，请重新下载');
      }
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw _CacheException('片源返回 HTTP ${response.statusCode}，链接可能已失效');
      }

      final append = response.statusCode == 206 && received > 0;
      if (!append) {
        received = 0;
        task.bytes = 0;
        if (await part.exists()) {
          try {
            await part.delete();
          } catch (_) {}
        }
      }
      final length = response.contentLength ?? 0;
      task.totalBytes = length > 0 ? received + length : 0;
      _notifyNow();

      sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
      await for (final chunk in response.stream) {
        if (_shouldStop(task)) throw const _AbortDownload();
        sink.add(chunk);
        received += chunk.length;
        task
          ..bytes = received
          ..progress = task.totalBytes > 0 ? received / task.totalBytes : 0
          ..updatedAt = DateTime.now().millisecondsSinceEpoch;
        _notifyProgress();
        _persistSoon();
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (_shouldStop(task)) throw const _AbortDownload();
      if (await target.exists()) {
        try {
          await target.delete();
        } catch (_) {}
      }
      final file = await part.rename(target.path);
      task
        ..filePath = file.path
        ..status = DownloadStatus.completed
        ..progress = 1
        ..bytes = await file.length()
        ..error = null
        ..updatedAt = DateTime.now().millisecondsSinceEpoch;
      _notifyNow();
      await _persist();
      unawaited(refreshUsage());
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
  }

  /* ------------------------------------------------------------- fetch */

  Future<List<int>> _fetchBytes(Uri uri, Map<String, String> headers) {
    return _withRetry(() async {
      final response = await http
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
    });
  }

  Future<_PlaylistData> _fetchPlaylist(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final response = await _withRetry(() async {
      final res = await http
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
    for (var attempt = 0; attempt <= 2; attempt++) {
      try {
        return await action();
      } catch (e) {
        if (e is _CacheException) rethrow;
        last = e;
        if (attempt < 2) {
          await Future<void>.delayed(
              Duration(milliseconds: 400 * (attempt + 1)));
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

  Uri? _parseMapUri(String playlist, Uri base) {
    final match = RegExp(r'#EXT-X-MAP:.*?URI="([^"]+)"').firstMatch(playlist);
    if (match == null) return null;
    return base.resolve(match.group(1)!);
  }

  List<Uri> _parseSegments(String playlist, Uri base) {
    final out = <Uri>[];
    for (final raw in playlist.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      out.add(base.resolve(line));
    }
    return out;
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

  String _taskDirName(DownloadTask task) =>
      '${_safeSegment(task.id)}_${task.ep}';

  Future<Directory> _taskDir(DownloadTask task) async {
    final root = await _rootDir();
    final dir = Directory('${root.path}/${_taskDirName(task)}');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File?> _existingFile(DownloadTask task) async {
    if (task.filePath != null) {
      final file = File(task.filePath!);
      if (await file.exists()) return file;
    }
    final root = await _rootDir();
    final roots = <String>{root.path};
    // 切换目录或升级前下载的文件可能留在旧目录里，逐个位置找回来。
    try {
      roots.addAll(await DownloadStorage.knownRootPaths());
    } catch (_) {}
    final exts = <String>[
      if (task.ext.trim().isNotEmpty) task.ext.trim(),
      'ts',
      'mp4',
    ];
    for (final rootPath in roots) {
      final dir = Directory('$rootPath/${_taskDirName(task)}');
      for (final ext in exts.toSet()) {
        final file = File('${dir.path}/ep_${task.ep}.$ext');
        if (await file.exists()) return file;
      }
    }
    return null;
  }

  Future<void> _deleteTaskFiles(DownloadTask task) async {
    final dirs = <Directory>{};
    try {
      final root = await _rootDir();
      dirs.add(Directory('${root.path}/${_taskDirName(task)}'));
    } catch (_) {}
    try {
      for (final rootPath in await DownloadStorage.knownRootPaths()) {
        dirs.add(Directory('$rootPath/${_taskDirName(task)}'));
      }
    } catch (_) {}
    final filePath = task.filePath;
    if (filePath != null && filePath.isNotEmpty) {
      dirs.add(File(filePath).parent);
    }
    for (final dir in dirs) {
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (e) {
        debugPrint('DownloadService: delete ${dir.path} failed: $e');
      }
    }
  }

  /* --------------------------------------------------------- persistence */

  void _notifyNow() {
    _lastNotify = DateTime.now();
    notifyListeners();
  }

  void _notifyProgress() {
    final now = DateTime.now();
    if (now.difference(_lastNotify) < _notifyGap) return;
    _lastNotify = now;
    notifyListeners();
  }

  void _persistSoon() {
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
            task.status == DownloadStatus.completed ? '已缓存' : task.status.label,
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

class _PlaylistData {
  const _PlaylistData(this.text, this.uri);
  final String text;
  final Uri uri;
}

class _CacheException implements Exception {
  const _CacheException(this.message);
  final String message;

  @override
  String toString() => message;
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

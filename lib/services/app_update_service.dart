import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show MethodChannel, MissingPluginException, PlatformException;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../api.dart';
import 'app_info.dart';

/// `GET /api/app/version` 的返回。
///
/// 接口不存在（HTTP 404 / 业务 code=404）时返回 [none]：版本号 0.0.0，
/// 不会误报「有新版本」。
class AppUpdateInfo {
  const AppUpdateInfo({
    required this.versionName,
    required this.versionCode,
    required this.downloadUrl,
    required this.notes,
    this.hasVersionCode = false,
  });

  static const String fallbackDownloadUrl =
      'https://github.com/candevot/fantasy-tv/releases/latest';

  static const AppUpdateInfo none = AppUpdateInfo(
    versionName: '0.0.0',
    versionCode: 0,
    downloadUrl: fallbackDownloadUrl,
    notes: '',
  );

  final String versionName;
  final int versionCode;
  final String downloadUrl;
  final String notes;

  /// 接口 payload 里是否真的给了 versionCode（含显式 `versionCode: 0`）。
  final bool hasVersionCode;

  /// 有新版本吗。
  ///
  /// 给了 versionCode 就**只做数值比较**（服务端 `versionCode: 0` = 无更新，
  /// 永远不会误报）；只有版本名时才退化为点分版本号比较。
  bool get hasUpdate {
    if (hasVersionCode) return versionCode > AppInfo.versionCode;
    return compareVersion(versionName, AppInfo.versionName) > 0;
  }

  String get displayVersion =>
      versionName.trim().isEmpty ? '0.0.0' : versionName.trim();
}

class AppUpdateException implements Exception {
  AppUpdateException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 检查更新：真实请求后端，不等待假进度。
class AppUpdateService {
  AppUpdateService._();

  static const Duration _timeout = Duration(seconds: 10);

  /// 启动后自动检查用的更短超时：5 秒内没结果就当没网，静默放弃。
  static const Duration startupTimeout = Duration(seconds: 5);

  static Future<AppUpdateInfo> check({
    Duration timeout = _timeout,
  }) async {
    await AppInfo.load();
    final uri = Uri.parse('${Api.base}/app/version');
    http.Response response;
    try {
      response = await http.get(
        uri,
        headers: <String, String>{
          'Accept': 'application/json',
          if (Api.token.isNotEmpty) 'Authorization': 'Bearer ${Api.token}',
        },
      ).timeout(timeout);
    } catch (_) {
      throw AppUpdateException('网络连接失败，请检查网络后重试');
    }

    if (response.statusCode == 404) return AppUpdateInfo.none;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AppUpdateException('检查更新失败（HTTP ${response.statusCode}）');
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw AppUpdateException('服务器返回格式异常，请稍后重试');
    }
    if (decoded is! Map) {
      throw AppUpdateException('服务器返回格式异常，请稍后重试');
    }

    final code = decoded['code'];
    final ok = code == 0 || code == '0';
    if (!ok) {
      // 后端尚未部署该接口时可能返回 {code:404}，按「没有新版本」处理。
      if (code == 404 || code == '404') return AppUpdateInfo.none;
      throw AppUpdateException(
        '${decoded['msg'] ?? '检查更新失败'}',
      );
    }

    final raw = decoded['data'];
    if (raw is! Map) return AppUpdateInfo.none;
    final data = Map<String, dynamic>.from(raw);

    final versionName = _firstString(<Object?>[
      data['versionName'],
      data['latestVersion'],
      data['version'],
      data['name'],
    ]);
    // versionCode 的候选键：只要出现过数字（含显式 0）就走数值比较。
    const codeKeys = <String>[
      'versionCode',
      'buildNumber',
      'build',
      'version_code',
    ];
    final hasVersionCode = codeKeys.any((key) {
      final value = data[key];
      if (value is int) return true;
      if (value is String && int.tryParse(value.trim()) != null) return true;
      return false;
    });
    final versionCode = _firstInt(<Object?>[
      for (final key in codeKeys) data[key],
    ]);
    final downloadUrl = _firstString(<Object?>[
      data['downloadUrl'],
      data['download_url'],
      data['apkUrl'],
      data['url'],
      data['link'],
    ]);
    final notes = _firstString(<Object?>[
      data['notes'],
      data['changelog'],
      data['description'],
      data['releaseNotes'],
    ]);

    if (versionName.isEmpty && versionCode <= 0) {
      return AppUpdateInfo.none;
    }

    return AppUpdateInfo(
      versionName: versionName.isEmpty ? '0.0.0' : versionName,
      versionCode: versionCode,
      downloadUrl:
          downloadUrl.isEmpty ? AppUpdateInfo.fallbackDownloadUrl : downloadUrl,
      notes: notes,
      hasVersionCode: hasVersionCode,
    );
  }

  /// 启动后的自动检查：5 秒超时，任何失败（网络 / 超时 / 接口异常）都返回
  /// null，绝不打扰启动动画。只在「确实有新版本」时返回 info。
  static Future<AppUpdateInfo?> checkQuietly() async {
    try {
      final info = await check(timeout: startupTimeout);
      return info.hasUpdate ? info : null;
    } catch (_) {
      return null;
    }
  }

  /// 本次进程（会话）内已经提示过的 versionCode。
  ///
  /// 同一 versionCode 只弹一次；服务端把 versionCode 改了才允许再弹。
  static int? _promptedVersionCode;

  /// 启动检查整个进程只跑一次（RootShell 重建也不会重复请求）。
  static bool _startupChecked = false;

  /// 领取一次启动检查机会；已领过返回 false。
  static bool claimStartupCheck() {
    if (_startupChecked) return false;
    _startupChecked = true;
    return true;
  }

  /// 这个 versionCode 还需要弹吗（本会话已弹过 → false）。
  static bool shouldPrompt(int versionCode) =>
      _promptedVersionCode != versionCode;

  /// 记下已经弹过的 versionCode（点「暂不更新」或开始下载都算弹过）。
  static void markPrompted(int versionCode) =>
      _promptedVersionCode = versionCode;

  /// 下载 APK 到应用缓存目录 `updates/`，返回本地文件。
  ///
  /// 失败抛 [AppUpdateException]；[onProgress] 收到 0–1 的进度，
  /// 服务端没给 content-length 时回 null（进度条走不确定态）。
  static Future<File> downloadApk(
    String url, {
    void Function(double? progress)? onProgress,
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.isEmpty) {
      throw AppUpdateException('下载链接无效，请复制链接手动下载');
    }

    final client = http.Client();
    try {
      final request = http.Request('GET', uri);
      request.headers['Accept'] = 'application/vnd.android.package-archive, */*';
      final response =
          await client.send(request).timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AppUpdateException('下载失败（HTTP ${response.statusCode}）');
      }
      // github releases 打不开时经常回一个 HTML 错误页，别当 APK 存下来。
      final contentType = (response.headers['content-type'] ?? '').toLowerCase();
      if (contentType.contains('text/html')) {
        throw AppUpdateException('下载失败：服务器返回的不是安装包');
      }

      // 直接下到用户能找到的地方：优先公共 Download 目录
      // （/sdcard/Download/幻想影视/），拿不到权限再退回应用私有目录。
      // 之前下到应用缓存 updates/ 里，用户在文件管理器里根本找不到，
      // 更新完就没法再手动安装 / 转发给别人。
      final dir = await _updateDownloadDir();
      await dir.create(recursive: true);
      final file = File(
        '${dir.path}${Platform.pathSeparator}${_updateFileName()}',
      );
      final sink = file.openWrite();
      final clen = response.contentLength;
      final total = (clen != null && clen > 0) ? clen : null;
      var received = 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total != null) {
            onProgress?.call((received / total).clamp(0.0, 1.0).toDouble());
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (received <= 0) {
        unawaited(file.delete().catchError((_) => file));
        throw AppUpdateException('下载失败：安装包是空的');
      }
      // 拿不到总长度时也上报一次 100%，让进度条走完。
      onProgress?.call(1.0);
      return file;
    } on AppUpdateException {
      rethrow;
    } on TimeoutException {
      throw AppUpdateException('下载超时，请检查网络后重试');
    } catch (e) {
      throw AppUpdateException('下载失败，请检查网络后重试');
    } finally {
      client.close();
    }
  }

  /// 更新包的落盘目录。
  ///
  /// Android 的公共下载目录是 `/storage/emulated/0/Download`；App 通过
  /// 系统提供的 Download 目录 API 拿到的通常是应用专属子目录，
  /// 这里优先用 `/sdcard/Download/幻想影视`，写不进去再退回私有目录。
  static Future<Directory> _updateDownloadDir() async {
    if (Platform.isAndroid) {
      for (final path in const <String>[
        '/sdcard/Download/幻想影视',
        '/storage/emulated/0/Download/幻想影视',
      ]) {
        try {
          final dir = Directory(path);
          await dir.create(recursive: true);
          // 试写一个探针文件确认真的有权限（create 成功不代表可写）。
          final probe = File('${dir.path}/.w');
          await probe.writeAsString('1', flush: false);
          await probe.delete();
          return dir;
        } catch (_) {
          // 没权限就试下一个。
        }
      }
    }
    return Directory(
      '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}updates',
    );
  }

  /// 安装包文件名带版本号和时间，用户一眼能看出是哪个版本、什么时候下的。
  /// 形如：幻想影视-v4.4-20261107-2315.apk
  static String _updateFileName() {
    final now = DateTime.now();
    String two(int v) => v < 10 ? '0$v' : '$v';
    final stamp = '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}';
    final version = AppInfo.displayVersion.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '');
    return '幻想影视-v$version-$stamp.apk';
  }

  /// 给用户看的短路径：/sdcard/Download/... 显示成 Download/...，
  /// 私有目录则显示成「应用缓存」。
  static String shortPath(String path) {
    if (path.contains('/Download/')) {
      final i = path.indexOf('/Download/');
      return path.substring(i + 1);
    }
    return '应用缓存目录';
  }

  /// 调起系统安装器安装本地 APK（Android 8+ 走 FileProvider）。
  static const MethodChannel _installChannel =
      MethodChannel('fantasy_tv/update');

  static Future<void> installApk(File file) async {
    if (!await file.exists()) {
      throw AppUpdateException('安装包不存在，请重新下载');
    }
    try {
      await _installChannel.invokeMethod<void>(
        'installApk',
        <String, Object?>{'path': file.path},
      );
    } on MissingPluginException {
      throw AppUpdateException('当前构建不支持应用内安装，请复制链接手动下载');
    } on PlatformException catch (e) {
      throw AppUpdateException(e.message ?? '调起安装失败，请手动安装');
    }
  }

  static String _firstString(List<Object?> values) {
    for (final value in values) {
      final text = '${value ?? ''}'.trim();
      if (text.isNotEmpty && text != 'null') return text;
    }
    return '';
  }

  static int _firstInt(List<Object?> values) {
    for (final value in values) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      final parsed = int.tryParse('${value ?? ''}');
      if (parsed != null && parsed > 0) return parsed;
    }
    return 0;
  }
}

/// 比较两个点分版本号：1.0.10 > 1.0.9。
int compareVersion(String a, String b) {
  List<int> parse(String value) {
    final cleaned = value.trim().replaceFirst(RegExp(r'^[vV]'), '');
    return cleaned
        .split(RegExp(r'[.\-+]'))
        .map(
            (part) => int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList(growable: false);
  }

  final left = parse(a);
  final right = parse(b);
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final x = i < left.length ? left[i] : 0;
    final y = i < right.length ? right[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

import 'dart:convert';

import 'package:http/http.dart' as http;

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

  /// 优先比较 versionCode；后端只给版本名时退化为版本号字符串比较。
  bool get hasUpdate {
    if (versionCode > 0) return versionCode > AppInfo.versionCode;
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

  static Future<AppUpdateInfo> check() async {
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
      ).timeout(_timeout);
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
    final versionCode = _firstInt(<Object?>[
      data['versionCode'],
      data['buildNumber'],
      data['build'],
      data['version_code'],
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
    );
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

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 离线缓存目录位置。
///
/// DOWNLOAD_DIR（2026-11-14 用户要求）：
///   · 去掉「应用私有」这个选项 —— 用户要能在文件管理器里直接看到缓存
///   · 默认落在 `手机存储/Download/幻想影视`
///   · 允许自己选目录（系统文件管理器），选中后仍然套一层 `幻想影视`
///
/// 缓存结构统一为 `<根目录>/幻想影视/<剧名>/<剧集>`。
enum DownloadLocation { phone, custom }

extension DownloadLocationText on DownloadLocation {
  String get key => switch (this) {
        DownloadLocation.phone => 'phone',
        DownloadLocation.custom => 'custom',
      };

  String get label => switch (this) {
        DownloadLocation.phone => '手机存储',
        DownloadLocation.custom => '自定义目录',
      };

  String get description => switch (this) {
        DownloadLocation.phone => 'Download/幻想影视，文件管理器可直接找到',
        DownloadLocation.custom => '自己选位置，同样会建「幻想影视」子目录',
      };
}

DownloadLocation downloadLocationFromKey(String? key) {
  return key == DownloadLocation.custom.key
      ? DownloadLocation.custom
      : DownloadLocation.phone;
}

/// 一次目录解析的结果。
class DownloadStorageInfo {
  const DownloadStorageInfo({
    required this.path,
    required this.location,
    required this.isPublic,
    required this.fallback,
  });

  final String path;
  final DownloadLocation location;

  /// 是否真的落在公共 `Download` 目录（否则是应用专属目录）。
  final bool isPublic;

  /// 选择的「手机存储」因系统限制无法写入，已经回退到应用专属目录。
  final bool fallback;

  String get displayPath => DownloadStorage.displayPath(path);
}

/// 离线缓存目录解析 + 磁盘占用统计。
///
/// Android 10+ 的分区存储不允许普通应用直接写公共 Download 根目录；
/// 这里会先做一次真实写入探测，失败后退到 `getExternalStorageDirectory()`
/// （应用专属外部目录，无需额外权限）。任何情况下都不再使用 systemTemp。
class DownloadStorage {
  DownloadStorage._();

  static const String publicRootPath = '/storage/emulated/0/Download/幻想影视';
  static const String folderName = '幻想影视';

  /// 公共目录不可写时使用的应用专属外部目录。
  static Future<String?> _appExternalPath() async {
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) return null;
      return '${dir.path}/Download/$folderName';
    } catch (e) {
      debugPrint('DownloadStorage: getExternalStorageDirectory failed: $e');
      return null;
    }
  }

  static Future<String> _privatePath() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return '${dir.path}/downloads';
    } catch (e) {
      debugPrint('DownloadStorage: getApplicationSupportDirectory failed: $e');
      final dir = await getApplicationDocumentsDirectory();
      return '${dir.path}/downloads';
    }
  }

  /// 默认基目录：公共下载目录。
  static const String defaultBasePath = '/storage/emulated/0/Download';

  /// 解析当前设置对应的真实目录，并确保目录可写。
  ///
  /// [customBase] 是用户自选的基目录；真正的缓存根永远是
  /// `<基目录>/幻想影视`，保证文件管理器里一眼能认出来。
  static Future<DownloadStorageInfo> resolve(
    DownloadLocation location, {
    String? customBase,
  }) async {
    // 1) 自定义目录优先：用户自己选的基目录 + 「幻想影视」
    if (location == DownloadLocation.custom &&
        customBase != null &&
        customBase.trim().isNotEmpty) {
      final base = customBase.trim();
      final root = base.endsWith('/$folderName') ? base : '$base/$folderName';
      if (await _ensureWritable(Directory(root))) {
        return DownloadStorageInfo(
          path: root,
          location: DownloadLocation.custom,
          isPublic: base.startsWith('/storage/emulated/0/'),
          fallback: false,
        );
      }
    }

    // 2) 公共下载目录（默认；自定义目录不可写时也回落到这里）
    if (await _ensureWritable(Directory(publicRootPath))) {
      return const DownloadStorageInfo(
        path: publicRootPath,
        location: DownloadLocation.phone,
        isPublic: true,
        fallback: false,
      );
    }

    // 3) 应用专属外部目录：分区存储不让写公共 Download 时用这个
    final external = await _appExternalPath();
    if (external != null && await _ensureWritable(Directory(external))) {
      return DownloadStorageInfo(
        path: external,
        location: location,
        isPublic: false,
        fallback: true,
      );
    }

    // 4) 最后兜底：应用私有目录，至少保证能下载
    final private = Directory(await _privatePath());
    await _ensureWritable(private);
    return DownloadStorageInfo(
      path: private.path,
      location: location,
      isPublic: false,
      fallback: true,
    );
  }

  /// 真实写入探测：只创建一个临时探针文件，马上删除。
  static Future<bool> _ensureWritable(Directory dir) async {
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final probe = File('${dir.path}/.fx_write_probe');
      await probe.writeAsString('ok', flush: true);
      if (await probe.exists()) await probe.delete();
      return true;
    } catch (e) {
      debugPrint('DownloadStorage: not writable ${dir.path}: $e');
      return false;
    }
  }

  /// 所有可能存放离线缓存的目录（用于「已用空间」统计与一键清理）。
  ///
  /// 最后一项是旧版本使用的 `systemTemp/fxdl`，只读统计/清理，不再写入。
  static Future<List<String>> knownRootPaths() async {
    final paths = <String>{publicRootPath};
    final external = await _appExternalPath();
    if (external != null) paths.add(external);
    try {
      paths.add(await _privatePath());
    } catch (_) {
      // 忽略：拿不到私有目录时只统计其它位置。
    }
    paths.add('${Directory.systemTemp.path}/fxdl');
    return paths.toList(growable: false);
  }

  /// 递归统计所有缓存目录的真实大小。
  static Future<int> usedBytes() async {
    var total = 0;
    for (final path in await knownRootPaths()) {
      total += await directoryBytes(path);
    }
    return total;
  }

  static Future<int> directoryBytes(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) return 0;
    var total = 0;
    try {
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        try {
          total += await entity.length();
        } catch (_) {
          // 文件在统计过程中被删除时忽略。
        }
      }
    } catch (e) {
      debugPrint('DownloadStorage: stat $path failed: $e');
    }
    return total;
  }

  /// 清空全部离线缓存目录（包括旧版本遗留的 systemTemp 缓存）。
  static Future<void> clearAllCaches() async {
    for (final path in await knownRootPaths()) {
      final dir = Directory(path);
      try {
        if (await dir.exists()) await dir.delete(recursive: true);
      } catch (e) {
        debugPrint('DownloadStorage: clear $path failed: $e');
        // 删不掉整个目录时至少把里面的内容逐项删掉。
        try {
          await for (final entity in dir.list(followLinks: false)) {
            await entity.delete(recursive: true);
          }
        } catch (_) {}
      }
    }
  }

  /// `/storage/emulated/0/Download/x` → `手机存储/Download/x`，界面更易读。
  static String displayPath(String path) {
    const prefix = '/storage/emulated/0/';
    if (path.startsWith(prefix)) {
      return '手机存储/${path.substring(prefix.length)}';
    }
    return path;
  }
}

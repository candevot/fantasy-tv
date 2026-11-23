import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 线路显示配置（LINE_CONFIG 2026-11-23，用户口径：**不要再为了改线路发版**）。
///
/// 以前「加一条线路 / 调一下顺序 / 删一条死线」都要改 Dart 常量再出一个 APK，
/// 用户为此反复等构建。现在这些规则全部由服务端一份 JSON 决定：
///
///   http://125.94.244.87/hx_lines.json
///   {
///     "head":       ["幻想腾讯", "咕噜4K", "SH4K", "幻想爱奇艺"],  // 固定头部顺序
///     "jar_dead":   ["玫瑰4K", "量子资源", ...],                  // jar 里必死的子线路名
///     "jar_prefer": ["咕噜4K", "暴风资源"]                        // jar 默认子线路优先
///   }
///
/// 客户端只做两件事：启动时拉一次（失败就用内置默认值），把结果交给
/// `jar_sources.dart` 的几个纯函数。改顺序 = 改服务器上这个文件，
/// **App 不用重新发版**。
class FxLineConfig {
  FxLineConfig._();

  static const String url = 'http://125.94.244.87/hx_lines.json';

  /// 固定头部顺序（越靠前越前）。
  static List<String> head = const <String>[
    '幻想腾讯',
    '咕噜4K',
    'SH4K',
    '幻想爱奇艺',
  ];

  /// jar 里一定播不了、要直接从列表删掉的子线路名。
  static List<String> jarDead = const <String>[
    '爱奇艺',
    '腾讯视频',
    '优酷',
    'bilibili',
    'mgtv',
    '芒果',
    '咖啡4K超清',
    '咖啡4K',
    '玫瑰4K',
    '金牌极速',
    '电影天堂',
    '量子资源',
    '非凡资源',
    '蚂蚁资源',
    '旋风VIP',
  ];

  /// jar 默认子线路优先顺序。
  static List<String> jarPrefer = const <String>['咕噜4K', '暴风资源'];

  static bool _loaded = false;

  /// 启动时调一次；任何失败都保持内置默认值（不能让配置服务挂掉影响播放）。
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final resp = await http.get(Uri.parse(url)).timeout(
            const Duration(seconds: 4),
          );
      if (resp.statusCode != 200) return;
      final map = jsonDecode(utf8.decode(resp.bodyBytes));
      if (map is! Map) return;
      final h = _strList(map['head']);
      final d = _strList(map['jar_dead']);
      final p = _strList(map['jar_prefer']);
      if (h.isNotEmpty) head = h;
      if (d.isNotEmpty) jarDead = d;
      if (p.isNotEmpty) jarPrefer = p;
      debugPrint('[LineConfig] 已应用服务端配置 head=$head dead=${d.length}');
    } catch (e) {
      debugPrint('[LineConfig] 拉取失败，用内置默认值: $e');
    }
  }

  static List<String> _strList(Object? raw) => <String>[
        if (raw is List)
          for (final e in raw)
            if (e is String && e.trim().isNotEmpty) e.trim(),
      ];
}

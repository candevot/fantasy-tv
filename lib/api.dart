import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// 服务器接口（默认已部署：阿里云 47.96.0.112:8787）
class Api {
  static String base = 'http://47.96.0.112:8787/api';
  static String wsBase = 'ws://47.96.0.112:8787/ws/together';
  static const Duration _timeout = Duration(seconds: 8);

  static Future<void> init() async {
    final sp = await SharedPreferences.getInstance();
    base = sp.getString('apiBase') ?? base;
    wsBase = sp.getString('wsBase') ?? wsBase;
  }

  static Future<void> setBase(String api, String ws) async {
    base = api;
    wsBase = ws;
    final sp = await SharedPreferences.getInstance();
    await sp.setString('apiBase', api);
    await sp.setString('wsBase', ws);
  }

  static Uri _u(String path, [Map<String, dynamic>? q]) {
    final m = <String, String>{};
    q?.forEach((k, v) {
      if (v != null) m[k] = '$v';
    });
    return Uri.parse('$base$path').replace(queryParameters: m.isEmpty ? null : m);
  }

  static Future<Map<String, dynamic>> _get(String path,
      [Map<String, dynamic>? q]) async {
    final r = await http.get(_u(path, q)).timeout(_timeout);
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    if ((j['code'] ?? -1) != 0) {
      throw ApiException('${j['msg'] ?? '请求失败'}');
    }
    final d = j['data'];
    return d is Map<String, dynamic> ? d : <String, dynamic>{'data': d};
  }

  static Future<HomeData> home(String channel) async {
    final d = await _get('/home', {'channel': channel});
    final banners = ((d['banners'] ?? []) as List)
        .map((e) => BannerItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final sections = ((d['sections'] ?? []) as List).map((e) {
      final m = Map<String, dynamic>.from(e);
      return HomeSection(
        '${m['title'] ?? ''}',
        ((m['items'] ?? []) as List)
            .map((x) => VideoCard.fromJson(Map<String, dynamic>.from(x)))
            .toList(),
      );
    }).toList();
    return HomeData(banners, sections);
  }

  static Future<List<VideoCard>> search(String q, int page) async {
    final d = await _get('/search', {'q': q, 'page': page});
    return ((d['items'] ?? []) as List)
        .map((e) => VideoCard.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  static Future<List<VideoCard>> aiFind(String prompt) async {
    final d = await _get('/search/ai', {'prompt': prompt});
    return ((d['items'] ?? []) as List)
        .map((e) => VideoCard.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  static Future<List<VideoCard>> category(
      {String type = '', String area = '', String year = '', String sort = 'latest', int page = 1}) async {
    final d = await _get('/category', {
      'type': type,
      'area': area,
      'year': year,
      'sort': sort,
      'page': page,
    });
    return ((d['items'] ?? []) as List)
        .map((e) => VideoCard.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  static Future<List<VideoCard>> rank(String type) async {
    final d = await _get('/rank', {'type': type});
    return ((d['items'] ?? []) as List)
        .map((e) => VideoCard.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  static Future<VideoDetail> detail(String id) async {
    final d = await _get('/detail', {'id': id});
    return VideoDetail.fromJson(d);
  }

  static Future<PlayInfo> play(String id, int ep, String line) async {
    final d = await _get('/play', {'id': id, 'ep': ep, 'line': line});
    return PlayInfo.fromJson(d);
  }

  static Future<List<DanmuItem>> danmu(String id, int ep) async {
    try {
      final r = await http
          .get(_u('/danmu', {'id': id, 'ep': ep}))
          .timeout(_timeout);
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      final list = j is Map ? (j['data'] ?? []) : j;
      return (list as List)
          .map((e) => DanmuItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<List<CommentItem>> comments(String id, int page) async {
    final d = await _get('/comment', {'id': id, 'page': page});
    final list = (d['items'] ?? d['data'] ?? []) as List;
    return list
        .map((e) => CommentItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 绝对地址：服务器可能返回相对代理地址 /api/proxy?u=...
  static String abs(String url) {
    if (url.isEmpty) return url;
    if (url.startsWith('http')) return url;
    final root = base.replaceFirst(RegExp(r'/api$'), '');
    return '$root$url';
  }
}

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

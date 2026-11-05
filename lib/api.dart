import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// 服务器接口（默认已部署：阿里云 47.96.0.112:8787）
class Api {
  static String base = 'http://47.96.0.112:8787/api';
  static String wsBase = 'ws://47.96.0.112:8787/ws/together';
  static const Duration _timeout = Duration(seconds: 10);

  /// 登录 token（由 Auth 维护）；存在时所有请求都带 Bearer。
  static String token = '';

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
    return Uri.parse('$base$path')
        .replace(queryParameters: m.isEmpty ? null : m);
  }

  static Map<String, String> _headers({bool json = false}) => <String, String>{
        'Accept': 'application/json',
        if (json) 'Content-Type': 'application/json',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

  static Map<String, dynamic> _decode(http.Response r) {
    dynamic j;
    try {
      j = jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      throw ApiException('服务器返回异常（HTTP ${r.statusCode}）',
          code: r.statusCode);
    }
    if (j is! Map) {
      throw ApiException('服务器返回异常（HTTP ${r.statusCode}）',
          code: r.statusCode);
    }
    final code = j['code'];
    final ok = code == 0 || code == '0';
    if (!ok) {
      throw ApiException('${j['msg'] ?? '请求失败'}',
          code: code is num ? code.toInt() : r.statusCode);
    }
    final d = j['data'];
    return d is Map<String, dynamic> ? d : <String, dynamic>{'data': d};
  }

  static Future<Map<String, dynamic>> _get(String path,
      [Map<String, dynamic>? q]) async {
    final r = await http.get(_u(path, q), headers: _headers()).timeout(_timeout);
    return _decode(r);
  }

  /// [timeout] 只给上传头像这类大 body 用，普通接口沿用 [_timeout]。
  static Future<Map<String, dynamic>> _post(String path,
      [Map<String, dynamic>? body, Duration? timeout]) async {
    final r = await http
        .post(_u(path),
            headers: _headers(json: true),
            body: jsonEncode(body ?? const <String, dynamic>{}))
        .timeout(timeout ?? _timeout);
    return _decode(r);
  }

  static Future<Map<String, dynamic>> _put(String path,
      [Map<String, dynamic>? body]) async {
    final r = await http
        .put(_u(path),
            headers: _headers(json: true),
            body: jsonEncode(body ?? const <String, dynamic>{}))
        .timeout(_timeout);
    return _decode(r);
  }

  /* ------------------------------------------------------------ 内容 */

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
      {String type = '',
      String area = '',
      String year = '',
      String sort = 'latest',
      int page = 1}) async {
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
    // 这里不走 _get/_decode：需要解析的线路会返回
    // `{code:1, msg:'unresolved', data:{url, type:'parse', ...}}`，
    // 它是正常的业务响应而不是请求失败，必须单独取原始 body 再判断。
    final r = await http
        .get(_u('/play', {'id': id, 'ep': ep, 'line': line}),
            headers: _headers())
        .timeout(_timeout);
    Map<String, dynamic> body = const <String, dynamic>{};
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map) body = Map<String, dynamic>.from(j);
    } catch (_) {
      throw ApiException('服务器返回异常（HTTP ${r.statusCode}）',
          code: r.statusCode);
    }
    final code = body['code'];
    final msg = '${body['msg'] ?? ''}'.trim().toLowerCase();
    final data = body['data'];
    final d = data is Map ? Map<String, dynamic>.from(data) : null;

    if (code != 0 && code != '0') {
      if ((code == 1 || code == '1') &&
          msg == 'unresolved' &&
          d != null &&
          '${d['url'] ?? ''}'.trim().isNotEmpty) {
        // 解析线路：播放页地址交给上层提示「该线路需解析」，不当作异常。
        return _playInfo(d, type: 'parse');
      }
      throw ApiException('${body['msg'] ?? '请求失败'}',
          code: code is num ? code.toInt() : r.statusCode);
    }
    if (d == null) {
      throw ApiException('服务器返回异常（HTTP ${r.statusCode}）',
          code: r.statusCode);
    }
    return _playInfo(d);
  }

  /// 播放地址统一转绝对地址（/api/proxy?u=… 是相对路径），并透传 headers。
  static PlayInfo _playInfo(Map<String, dynamic> d, {String? type}) {
    final info = <String, dynamic>{...d};
    info['url'] = abs('${d['url'] ?? ''}');
    info['backup'] = <String>[
      for (final u in (d['backup'] ?? []) as List) abs('$u'),
    ];
    // 清晰度地址同样是相对代理地址，不转绝对播放器会打不开。
    info['quality'] = <Map<String, dynamic>>[
      for (final q in (d['quality'] ?? []) as List)
        if (q is Map)
          <String, dynamic>{
            ...Map<String, dynamic>.from(q),
            'url': abs('${q['url'] ?? ''}'),
          },
    ];
    if (type != null) info['type'] = type;
    return PlayInfo.fromJson(info);
  }

  static Future<List<CommentItem>> comments(String id, int page) async {
    final d = await _get('/comment', {'id': id, 'page': page});
    final list = (d['items'] ?? d['data'] ?? []) as List;
    return list
        .map((e) => CommentItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /* ------------------------------------------------------------ 账号 */

  /// `POST /api/auth/register` → `{token,user}`；注册成功即自动登录。
  static Future<Map<String, dynamic>> register({
    required String account,
    required String password,
    String? nickname,
  }) async {
    final d = await _post('/auth/register', <String, dynamic>{
      'account': account,
      'password': password,
      if (nickname != null && nickname.trim().isNotEmpty)
        'nickname': nickname.trim(),
    });
    if ('${d['token'] ?? ''}'.isEmpty) {
      throw ApiException('服务器未返回登录凭证');
    }
    return d;
  }

  /// `POST /api/auth/login` → `{token,user}`。
  static Future<Map<String, dynamic>> login({
    required String account,
    required String password,
  }) async {
    final d = await _post('/auth/login', <String, dynamic>{
      'account': account,
      'password': password,
    });
    if ('${d['token'] ?? ''}'.isEmpty) {
      throw ApiException('服务器未返回登录凭证');
    }
    return d;
  }

  static Future<Map<String, dynamic>> me() => _get('/user/me');

  /// `PUT /api/user/profile` → `{ok,user}`。
  static Future<AuthUser> updateProfile({
    String? nickname,
    String? avatar,
    String? signature,
  }) async {
    final d = await _put('/user/profile', <String, dynamic>{
      if (nickname != null) 'nickname': nickname,
      if (avatar != null) 'avatar': avatar,
      if (signature != null) 'signature': signature,
    });
    final raw = d['user'];
    if (raw is Map) return AuthUser.fromJson(Map<String, dynamic>.from(raw));
    return AuthUser.fromJson(d);
  }

  /// `POST /api/user/avatar`：`{dataBase64}` → 服务器落盘后返回绝对头像地址。
  /// 只接受 jpg/png，解码后 ≤ 2MB（客户端上传前已压缩到 200KB 以内）。
  static Future<String> uploadAvatar(String dataBase64) async {
    final d = await _post(
      '/user/avatar',
      <String, dynamic>{'dataBase64': dataBase64},
      // 200KB 图片转 base64 后约 270KB，弱网下 10s 不够。
      const Duration(seconds: 30),
    );
    final url = '${d['avatar'] ?? d['url'] ?? ''}'.trim();
    if (url.isEmpty) throw ApiException('服务器未返回头像地址');
    return abs(url);
  }

  /// `POST /api/user/password`：`{oldPassword,newPassword}` → `{ok}`。
  /// POST 契约下旧 token 继续有效，不需要重新登录。
  static Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    await _post('/user/password', <String, dynamic>{
      'oldPassword': oldPassword,
      'newPassword': newPassword,
    });
  }

  static Future<void> logout() async {
    await _post('/auth/logout');
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
  ApiException(this.message, {this.code = 0});
  final String message;
  final int code;
  @override
  String toString() => message;
}

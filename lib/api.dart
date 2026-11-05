import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// 服务器接口（默认已部署：阿里云 47.96.0.112:8787）
class Api {
  static String base = 'http://47.96.0.112:8787/api';
  static String wsBase = 'ws://47.96.0.112:8787/ws/together';

  /// 所有接口统一 8 秒超时；失败最多重试 1 次。
  static const Duration _timeout = Duration(seconds: 8);
  static const Duration _retryDelay = Duration(milliseconds: 500);

  /// 登录 token（由 Auth 维护）；存在时所有请求都带 Bearer。
  static String token = '';

  /// token 失效（HTTP 401）时的全局回调，由 [Auth] 注册：
  /// 统一清本地登录态并提示，页面不需要各自处理。
  static void Function()? onUnauthorized;

  /// 401 通知去重：同一批并发请求只处理一次。
  static int _unauthorizedAt = 0;

  static void _notifyUnauthorized() {
    // 登录接口本身也可能回 401（账号密码错误），没带 token 时不算会话过期。
    if (token.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _unauthorizedAt < 3000) return;
    _unauthorizedAt = now;
    try {
      onUnauthorized?.call();
    } catch (_) {}
  }

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

  /// HTTP 层统一兜底：8 秒超时，失败按指数退避重试 1 次。
  /// 超时 / 断网 / 5xx 都转成带友好文案的 [ApiException]，
  /// 页面只需要展示 `e.message` 并提供重试入口，不会因为异常崩掉。
  static Future<http.Response> _send(
    Future<http.Response> Function() request,
  ) async {
    ApiException? failure;
    for (var attempt = 0; attempt <= 1; attempt++) {
      if (attempt > 0) {
        // 指数退避：唯一一次重试前等 500ms。
        await Future<void>.delayed(
          Duration(
              milliseconds: _retryDelay.inMilliseconds * (1 << (attempt - 1))),
        );
      }
      try {
        final r = await request().timeout(_timeout);
        if (r.statusCode >= 500) {
          failure = ApiException.server(r.statusCode);
          continue;
        }
        if (r.statusCode == 401) _notifyUnauthorized();
        return r;
      } on TimeoutException {
        failure = ApiException.timeout();
      } on SocketException {
        failure = ApiException.network();
      } on HandshakeException {
        failure = ApiException.network(message: '安全连接失败，请检查网络后重试');
      } on http.ClientException {
        failure = ApiException.network();
      } catch (e) {
        if (e is ApiException) rethrow;
        failure = ApiException('网络请求失败，请稍后重试', kind: ApiErrorKind.network);
      }
    }
    throw failure ?? ApiException.network();
  }

  static Map<String, dynamic> _decode(http.Response r) {
    if (r.statusCode >= 500) throw ApiException.server(r.statusCode);
    dynamic j;
    try {
      j = jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      throw _httpException(r.statusCode);
    }
    if (j is! Map) {
      throw _httpException(r.statusCode);
    }
    final code = j['code'];
    final ok = code == 0 || code == '0';
    if (!ok) {
      final codeValue = code is num ? code.toInt() : r.statusCode;
      // 服务端也可能用业务 code 返回 401；_send 已通知过状态码 401 的情况，
      // _notifyUnauthorized 内部按时间窗口去重。
      if (codeValue == 401) _notifyUnauthorized();
      throw ApiException('${j['msg'] ?? '请求失败'}', code: codeValue);
    }
    final d = j['data'];
    return d is Map<String, dynamic> ? d : <String, dynamic>{'data': d};
  }

  /// 非业务错误（4xx / 脏数据 / 空响应）的统一友好文案。
  static ApiException _httpException(int status) {
    if (status == 401) {
      return ApiException('登录已过期，请重新登录', code: status);
    }
    if (status >= 500) return ApiException.server(status);
    if (status >= 200 && status < 300) {
      return ApiException('服务器返回异常，请稍后重试',
          code: status, kind: ApiErrorKind.server);
    }
    return ApiException('请求失败（HTTP $status），请稍后重试',
        code: status, kind: ApiErrorKind.server);
  }

  static Future<Map<String, dynamic>> _get(String path,
      [Map<String, dynamic>? q]) async {
    final r = await _send(() => http.get(_u(path, q), headers: _headers()));
    return _decode(r);
  }

  static Future<Map<String, dynamic>> _post(String path,
      [Map<String, dynamic>? body]) async {
    final r = await _send(() => http.post(_u(path),
        headers: _headers(json: true),
        body: jsonEncode(body ?? const <String, dynamic>{})));
    return _decode(r);
  }

  static Future<Map<String, dynamic>> _put(String path,
      [Map<String, dynamic>? body]) async {
    final r = await _send(() => http.put(_u(path),
        headers: _headers(json: true),
        body: jsonEncode(body ?? const <String, dynamic>{})));
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

  /// `GET /api/live` → `{groups:[{id,name,cover,channels:[{id,name,url,cover}]}]}`。
  /// 兼容两种历史结构：顶层 `items` 扁平数组、`data.items`。
  /// 404 / 空结构 / 脏数据一律返回空列表，由页面展示空态。
  static Future<List<LiveGroup>> liveGroups() async {
    final r = await _send(() => http.get(_u('/live'), headers: _headers()));
    if (r.statusCode == 404) return const <LiveGroup>[];
    dynamic j;
    try {
      j = jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      return const <LiveGroup>[];
    }
    if (j is! Map) return const <LiveGroup>[];
    final data = j['data'];
    final body = data is Map ? data : j;
    final rawGroups = body['groups'];
    if (rawGroups is List) {
      final out = <LiveGroup>[];
      for (final e in rawGroups) {
        if (e is! Map) continue;
        final g = LiveGroup.fromJson(Map<String, dynamic>.from(e));
        if (g.name.trim().isEmpty || g.channels.isEmpty) continue;
        out.add(g);
      }
      return out;
    }

    // 旧结构：扁平 items，按 group 字段现场分组（保持首次出现顺序）。
    dynamic raw = body['items'];
    if (raw is! List) raw = body;
    if (raw is! List) return const <LiveGroup>[];
    final order = <String>[];
    final map = <String, List<LiveChannel>>{};
    for (final e in raw) {
      if (e is! Map) continue;
      final c = LiveChannel.fromJson(Map<String, dynamic>.from(e));
      if (c.title.isEmpty || c.url.isEmpty) continue;
      final key = c.group.trim().isEmpty ? '其他' : c.group.trim();
      if (!map.containsKey(key)) {
        map[key] = <LiveChannel>[];
        order.add(key);
      }
      map[key]!.add(c);
    }
    return <LiveGroup>[
      for (final k in order)
        LiveGroup(id: k, name: k, cover: '', channels: map[k]!),
    ];
  }

  /// 扁平频道列表：直播页/搜索等只需要频道时使用。
  static Future<List<LiveChannel>> live() async {
    final groups = await liveGroups();
    return <LiveChannel>[for (final g in groups) ...g.channels];
  }

  /// 单频道详情：优先 `GET /api/live/channel?id=`（新服务端可选接口），
  /// 404 / 老服务端没有该接口时退回 `/api/live` 全文里按 id 查。
  static Future<LiveChannel?> liveChannel(String id) async {
    final key = id.trim();
    if (key.isEmpty) return null;
    try {
      final r = await _send(
        () => http.get(_u('/live/channel', {'id': key}), headers: _headers()),
      );
      if (r.statusCode != 404) {
        dynamic j;
        try {
          j = jsonDecode(utf8.decode(r.bodyBytes));
        } catch (_) {}
        if (j is Map) {
          final data = j['data'];
          final raw =
              data is Map ? (data['channel'] ?? data) : (j['channel'] ?? j);
          if (raw is Map) {
            final c = LiveChannel.fromJson(Map<String, dynamic>.from(raw));
            if (c.id.isNotEmpty && c.lines.isNotEmpty) return c;
          }
        }
      }
    } catch (_) {
      // 老服务端直接 404 / 断网：继续走列表兜底。
    }
    try {
      for (final group in await liveGroups()) {
        for (final channel in group.channels) {
          if (channel.id == key) return channel;
        }
      }
    } catch (_) {}
    return null;
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
    final r = await _send(() => http.get(
        _u('/play', {'id': id, 'ep': ep, 'line': line}),
        headers: _headers()));
    Map<String, dynamic> body = const <String, dynamic>{};
    try {
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map) body = Map<String, dynamic>.from(j);
    } catch (_) {
      throw _httpException(r.statusCode);
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
    if (d == null) throw _httpException(r.statusCode);
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
    // 统一走 8 秒超时；压缩后 ≤200KB，弱网超时会提示重试。
    final d = await _post(
      '/user/avatar',
      <String, dynamic>{'dataBase64': dataBase64},
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

  /// 图片代理：远程封面统一走 `/api/img?u=<原始地址>`（绝对地址），
  /// 由服务端补 Referer / UA 后回传，解决图床防盗链和跨域。
  /// 已是本站（或本机 / 局域网）http 地址的图片直接返回，避免二次代理。
  /// 空串 / data URI / 非 http(s) 地址返回空串，调用方显示灰底占位。
  static String imgProxy(String url) {
    var u = url.trim();
    if (u.isEmpty || u.startsWith('data:')) return '';
    final lower = u.toLowerCase();
    if (lower.startsWith('//')) {
      u = 'https:$u';
    } else if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      u = abs(u.startsWith('/') ? u : '/$u');
    }
    final uri = Uri.tryParse(u);
    if (uri == null || uri.host.isEmpty) return '';
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return '';
    // 归一化协议 / 主机大小写并转义空格，ImageProvider 的缓存键才稳定。
    final absolute = uri.toString();
    if (_isLocalImageHost(uri)) return absolute;
    var root = base.replaceFirst(RegExp(r'/api/?$'), '');
    while (root.endsWith('/')) {
      root = root.substring(0, root.length - 1);
    }
    return '$root/api/img?u=${Uri.encodeComponent(absolute)}';
  }

  /// 本站 / 本机 / 局域网地址：头像、上传图这类图片直连即可。
  static bool _isLocalImageHost(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host == '::1' || host == '0.0.0.0') return true;
    if (host.startsWith('127.') || host.startsWith('10.')) return true;
    if (host.startsWith('192.168.')) return true;
    if (RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(host)) return true;
    final api = Uri.tryParse(base);
    return api != null && api.host.isNotEmpty && api.host.toLowerCase() == host;
  }
}

/// 请求失败的类型，页面可据此决定是否展示「重试」。
enum ApiErrorKind { network, timeout, server, business }

class ApiException implements Exception {
  ApiException(this.message,
      {this.code = 0, this.kind = ApiErrorKind.business});

  /// 无网络 / 连接失败：文案必须能直接引导用户检查网络。
  factory ApiException.network({String message = '请检查网络连接'}) =>
      ApiException(message, kind: ApiErrorKind.network);

  factory ApiException.timeout() =>
      ApiException('请求超时，请稍后重试', kind: ApiErrorKind.timeout);

  factory ApiException.server(int status) => ApiException(
        '服务器开小差了（HTTP $status），请稍后重试',
        code: status,
        kind: ApiErrorKind.server,
      );

  final String message;
  final int code;
  final ApiErrorKind kind;

  /// 网络 / 超时 / 服务端错误都可以让用户点重试。
  bool get retryable =>
      kind == ApiErrorKind.network ||
      kind == ApiErrorKind.timeout ||
      kind == ApiErrorKind.server;

  @override
  String toString() => message;
}

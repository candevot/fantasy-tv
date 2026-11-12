import 'dart:convert';

import 'package:http/http.dart' as http;

/// 弹幕数据层 —— 对接自建 danmu_api（弹弹play 兼容接口）。
///
/// 服务端：http://47.96.0.112:9321
///   搜索  GET /api/v2/search/episodes?anime=<剧名>&token=<token>
///   弹幕  GET /api/v2/comment/<episodeId>?withRelated=true&format=json
///
/// 为什么不自己爬各平台：danmu_api 已经覆盖爱优腾芒哔咪人等 14 个平台，
/// 而且输出弹弹play 标准格式，客户端只需实现一次解析。
class DanmuService {
  DanmuService._();
  static final DanmuService instance = DanmuService._();

  /// danmu_api 服务地址（和服务端同机，走 9321 端口）。
  static String host = 'http://47.96.0.112:9321';

  /// 服务端配置的访问 token（danmu_api 的 TOKEN 环境变量）。
  static const String token = '87654321';

  /// 按剧名搜到的分集列表（缓存 30 分钟）。
  final Map<String, _SearchHit?> _searchCache = {};
  final Map<String, DateTime> _searchAt = {};

  /// 已取到的弹幕（按 episodeId 缓存 1 小时）。
  final Map<int, List<DanmuItem>> _commentCache = {};
  final Map<int, DateTime> _commentAt = {};

  static const Duration _searchTtl = Duration(minutes: 30);
  static const Duration _commentTtl = Duration(hours: 1);

  /// 按剧名 + 集数搜弹幕。
  ///
  /// 返回 null 表示这个平台没有该剧的弹幕库；返回空列表表示有库但这集没弹幕。
  Future<List<DanmuItem>?> load({
    required String title,
    required int ep,
    String epName = '',
  }) async {
    final t = title.trim();
    if (t.isEmpty) return null;
    try {
      final hit = await _search(t);
      if (hit == null) return null;
      final epId = hit.episodeIdFor(ep, epName);
      if (epId == null) return const <DanmuItem>[];
      return await _comments(epId);
    } catch (_) {
      return null;
    }
  }

  Future<_SearchHit?> _search(String title) async {
    final cached = _searchAt[title];
    if (cached != null &&
        DateTime.now().difference(cached) < _searchTtl &&
        _searchCache.containsKey(title)) {
      return _searchCache[title];
    }
    final uri = Uri.parse('$host/api/v2/search/episodes')
        .replace(queryParameters: {'anime': title, 'token': token});
    final res = await http.get(uri).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return null;
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    final animes = (body is Map ? body['animes'] : null) as List?;
    if (animes == null || animes.isEmpty) {
      _searchCache[title] = null;
      _searchAt[title] = DateTime.now();
      return null;
    }
    // 取第一条（danmu_api 已按匹配度排好）
    final a = Map<String, dynamic>.from(animes.first as Map);
    final eps = <_SearchEp>[];
    for (final e in (a['episodes'] as List? ?? const [])) {
      final m = Map<String, dynamic>.from(e as Map);
      eps.add(_SearchEp(
        id: _asInt(m['episodeId']),
        title: '${m['episodeTitle'] ?? ''}',
      ));
    }
    final hit = _SearchHit(
      title: '${a['animeTitle'] ?? title}',
      episodes: eps,
    );
    _searchCache[title] = hit;
    _searchAt[title] = DateTime.now();
    return hit;
  }

  Future<List<DanmuItem>> _comments(int episodeId) async {
    final at = _commentAt[episodeId];
    if (at != null &&
        DateTime.now().difference(at) < _commentTtl &&
        _commentCache.containsKey(episodeId)) {
      return _commentCache[episodeId]!;
    }
    final uri = Uri.parse('$host/api/v2/comment/$episodeId')
        .replace(queryParameters: {'withRelated': 'true', 'format': 'json'});
    final res = await http.get(uri).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return const <DanmuItem>[];
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    final list = (body is Map ? body['comments'] : null) as List?;
    final out = <DanmuItem>[];
    for (final c in (list ?? const [])) {
      final m = Map<String, dynamic>.from(c as Map);
      final p = '${m['p'] ?? ''}';
      if (p.isEmpty) continue;
      final parts = p.split(',');
      if (parts.length < 2) continue;
      final time = double.tryParse(parts[0]) ?? 0;
      final mode = int.tryParse(parts[1]) ?? 1;
      final color = parts.length > 2 ? (int.tryParse(parts[2]) ?? 0xFFFFFF) : 0xFFFFFF;
      final text = '${m['m'] ?? ''}'.trim();
      if (text.isEmpty) continue;
      out.add(DanmuItem(
        time: Duration(milliseconds: (time * 1000).round()),
        text: text,
        mode: mode,
        color: color,
      ));
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    _commentCache[episodeId] = out;
    _commentAt[episodeId] = DateTime.now();
    return out;
  }

  static int _asInt(Object? v) {
    if (v is int) return v;
    return int.tryParse('$v') ?? 0;
  }
}

/// 单条弹幕。
class DanmuItem {
  const DanmuItem({
    required this.time,
    required this.text,
    this.mode = 1,
    this.color = 0xFFFFFF,
  });

  /// 出现时间（相对片头）。
  final Duration time;

  final String text;

  /// 1=滚动 4=底部 5=顶部
  final int mode;

  /// RGB 整数（0xFFFFFF = 白）。
  final int color;
}

class _SearchEp {
  const _SearchEp({required this.id, required this.title});
  final int id;
  final String title;
}

class _SearchHit {
  const _SearchHit({required this.title, required this.episodes});
  final String title;
  final List<_SearchEp> episodes;

  /// 按集号取 episodeId：优先按标题里的「第N集」匹配，退化为数组下标。
  int? episodeIdFor(int ep, String epName) {
    if (episodes.isEmpty) return null;
    // 1) 标题里带「第N集」
    for (final e in episodes) {
      final m = RegExp(r'第\s*(\d+)\s*集').firstMatch(e.title);
      if (m != null && int.tryParse(m.group(1)!) == ep) return e.id;
    }
    // 2) 标题里带裸数字（「xxx 02」这种）
    for (final e in episodes) {
      final m = RegExp(r'(?:^|\s)(\d{1,4})(?:\s|$)').firstMatch(e.title);
      if (m != null && int.tryParse(m.group(1)!) == ep) return e.id;
    }
    // 3) 退化为下标
    if (ep >= 1 && ep <= episodes.length) return episodes[ep - 1].id;
    return episodes.first.id;
  }
}

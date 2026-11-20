import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../models.dart';
import 'source_hub.dart';

/// 直播播放列表的三种形态（后台配哪个都行，自动识别）。
enum LiveFormat {
  /// `#EXTM3U` + `#EXTINF:-1,频道名` + URL
  m3u,

  /// `频道名,URL`（也支持 `#genre#` 分组行）
  txt,

  /// `{"lives":[…]}` / `{"groups":[…]}` 这类 JSON
  json,

  /// 认不出来（空内容 / 纯注释）
  unknown,
}

/// 一次直播列表的解析结果。
class LiveCatalog {
  const LiveCatalog({
    required this.groups,
    required this.format,
    required this.sourceUrl,
    this.fromCache = false,
    this.fetchedAt,
  });

  /// 已按「央视频道 / 卫视频道 / 少儿频道 / 地方频道 / 港澳台 / 体育频道 / 其他」
  /// 分好组的频道（分组名直接就是直播页的分区名）。
  final List<LiveGroup> groups;
  final LiveFormat format;
  final String sourceUrl;

  /// true 表示本次网络拉取失败、用的是本地缓存。
  final bool fromCache;
  final DateTime? fetchedAt;

  int get channelCount {
    var n = 0;
    for (final g in groups) {
      n += g.channels.length;
    }
    return n;
  }

  bool get isEmpty => channelCount == 0;

  String get formatLabel {
    switch (format) {
      case LiveFormat.m3u:
        return 'M3U';
      case LiveFormat.txt:
        return 'TXT';
      case LiveFormat.json:
        return 'JSON';
      case LiveFormat.unknown:
        return '未知格式';
    }
  }
}

/// 云端直播源：拉取 + 三种格式解析 + 本地缓存。
///
/// 地址来自 [SourceHub.liveUrl]（后台 `/api/config` 的 `live_url`，
/// 或者云端 `type: "live"` 的片源地址），App 不写死任何频道。
///
/// 解析只产出 models.dart 的 [LiveGroup] / [LiveChannel] / [LiveLine]，
/// 播放页（LiveDetailPage）拿到的就是它一直在用的结构：直播没有 duration，
/// 播放器本来就不画进度条、不允许拖动，这里不需要改播放内核。
class LiveSourceService {
  LiveSourceService._();

  static const String _kCache = 'fx_live_cache_v1';

  /// 缓存允许的最大字符数（2MB）：超大列表没必要整个塞进 SharedPreferences。
  static const int cacheLimit = 2 * 1024 * 1024;

  static const Duration timeout = Duration(seconds: 12);

  static LiveCatalog? _last;
  static Future<LiveCatalog>? _running;

  /// 上一次成功加载的结果（页面重建时先画它，不用再转圈）。
  static LiveCatalog? get last => _last;

  /// 拉取直播列表：网络优先，失败用缓存，地址都没配就抛错让页面提示。
  static Future<LiveCatalog> load({bool force = false}) async {
    await SourceHub.instance.ensureReady();
    // LIVE_SCAN（2026-11-20）：云端下发的 live_url 优先（后台还能换源），
    // 没配时默认读本服务器的 `/api/live` —— 那份清单是 ffprobe 实测过的，
    // 每条都是真能连通的台，还带真实分辨率。
    final cloudUrl = SourceHub.instance.liveUrl.trim();
    final url = cloudUrl.isEmpty ? Api.liveEndpoint : cloudUrl;
    if (!force && _last != null && _last?.sourceUrl == url) return _last!;
    final running = _running;
    if (running != null) return running;
    final task = _fetch(url);
    _running = task;
    try {
      return await task;
    } finally {
      _running = null;
    }
  }

  static Future<LiveCatalog> _fetch(String url) async {
    try {
      final r = await http
          .get(Uri.parse(url), headers: const <String, String>{'accept': '*/*'})
          .timeout(timeout);
      if (r.statusCode >= 400) throw ApiException.server(r.statusCode);
      final body = utf8.decode(r.bodyBytes, allowMalformed: true);
      final catalog = _build(body, url: url, fromCache: false, at: DateTime.now());
      if (catalog.isEmpty) throw ApiException('直播列表是空的，检查一下后台配置');
      _last = catalog;
      unawaited(_writeCache(url, body));
      return catalog;
    } on TimeoutException {
      return _fallback(url, ApiException.timeout());
    } on http.ClientException {
      return _fallback(url, ApiException.network());
    } catch (e) {
      return _fallback(url, e);
    }
  }

  /// 网络失败：同地址的缓存还能用就先用，完全没缓存才把错误抛给页面。
  static Future<LiveCatalog> _fallback(String url, Object error) async {
    final cached = await _readCache();
    if (cached != null && cached.body.trim().isNotEmpty) {
      final catalog = _build(
        cached.body,
        url: cached.url.isEmpty ? url : cached.url,
        fromCache: true,
        at: cached.at,
      );
      if (!catalog.isEmpty) {
        _last = catalog;
        return catalog;
      }
    }
    if (error is ApiException) throw error;
    throw ApiException('$error');
  }

  static LiveCatalog _build(
    String body, {
    required String url,
    required bool fromCache,
    DateTime? at,
  }) {
    final format = detect(body);
    final channels = <LiveChannel>[];
    switch (format) {
      case LiveFormat.m3u:
        channels.addAll(_parseM3u(body));
        break;
      case LiveFormat.txt:
        channels.addAll(_parseTxt(body));
        break;
      case LiveFormat.json:
        channels.addAll(_parseJson(body));
        break;
      case LiveFormat.unknown:
        break;
    }
    return LiveCatalog(
      groups: groupChannels(channels),
      format: format,
      sourceUrl: url,
      fromCache: fromCache,
      fetchedAt: at,
    );
  }

  /// 直接解析一段文本（调试 / 单元测试用）。
  static LiveCatalog parse(String text, {String url = ''}) =>
      _build(text, url: url, fromCache: false, at: null);

  /* ------------------------------------------------------------ 格式识别 */

  static LiveFormat detect(String text) {
    final head = text.trimLeft();
    if (head.isEmpty) return LiveFormat.unknown;
    if (head.startsWith('#EXTM3U') || head.contains('#EXTINF')) {
      return LiveFormat.m3u;
    }
    if (head.startsWith('{') || head.startsWith('[')) return LiveFormat.json;
    if (head.startsWith('<')) return LiveFormat.unknown;
    if (head.contains('#genre#')) return LiveFormat.txt;
    // 头几行里只要有一行是「台名,地址」就按 TXT 处理：
    // 首行可能是注释或分组标记，不能只看第一行。
    //
    // TXT_HEADER（2026-11-15）：注释行（`#` 开头）不占扫描配额。
    // 原来注释也计数，源站头部放一段「声明 / 更新日志」超过 20 行时，
    // 整个列表被判成「未知格式」→ 频道 0 个 → 直播页报「列表是空的」，
    // 明明源是好的，排查方向还会被带到后台配置上。
    var scanned = 0;
    for (final raw in head.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      if (_splitPair(line) != null) return LiveFormat.txt;
      scanned++;
      if (scanned >= 20) break;
    }
    return LiveFormat.unknown;
  }

  /* ------------------------------------------------------------ M3U */

  static List<LiveChannel> _parseM3u(String text) {
    final out = <LiveChannel>[];
    final lines = text.split('\n');
    Map<String, String> meta = const <String, String>{};
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      // `#EXTGRP:央视` 只补分组：它既没有 tvg-* 属性也没有逗号后的台名，
      // 按 EXTINF 解析会得到空 map，把上一条 `#EXTINF` 的台名/分组全清掉
      // （表现就是台名退化成域名、分组丢失）。
      if (line.startsWith('#EXTGRP')) {
        final group = line.substring('#EXTGRP'.length).trim().replaceFirst(':', '').trim();
        if (group.isNotEmpty) {
          meta = <String, String>{...meta, 'group': group};
        }
        continue;
      }
      if (line.startsWith('#EXTINF')) {
        meta = _extInfo(line);
        continue;
      }
      if (line.startsWith('#')) continue;
      if (!_looksLikeUrl(line)) continue;
      final name = (meta['name'] ?? '').trim();
      final channel = _channel(
        name.isEmpty ? _hostOf(line) : name,
        line,
        group: meta['group'] ?? '',
        cover: meta['logo'] ?? '',
      );
      if (channel != null) out.add(channel);
      meta = const <String, String>{};
    }
    return out;
  }

  /// `#EXTINF:-1 tvg-name="CCTV1" tvg-logo="…" group-title="央视",CCTV-1 综合`
  static Map<String, String> _extInfo(String line) {
    final map = <String, String>{};
    for (final key in const <String>['tvg-name', 'tvg-logo', 'group-title', 'tvg-id']) {
      final value = _attr(line, key);
      if (value.isEmpty) continue;
      if (key == 'tvg-name') map['name'] = value;
      if (key == 'tvg-logo') map['logo'] = value;
      if (key == 'group-title') map['group'] = value;
    }
    final comma = line.lastIndexOf(',');
    if (comma >= 0) {
      final tail = line.substring(comma + 1).trim();
      if (tail.isNotEmpty && !tail.startsWith('#')) map['name'] = tail;
    }
    return map;
  }

  static String _attr(String line, String key) {
    final match = RegExp('$key\\s*=\\s*"([^"]*)"', caseSensitive: false).firstMatch(line);
    if (match != null) return match.group(1)?.trim() ?? '';
    final loose = RegExp('$key\\s*=\\s*([^\\s,]+)', caseSensitive: false).firstMatch(line);
    return loose?.group(1)?.trim() ?? '';
  }

  /* ------------------------------------------------------------ TXT */

  static List<LiveChannel> _parseTxt(String text) {
    final out = <LiveChannel>[];
    var group = '';
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      // TVBox 的分组标记：`央视频道,#genre#`
      final genre = line.indexOf('#genre#');
      if (genre >= 0) {
        group = line.substring(0, genre).replaceAll(',', '').trim();
        continue;
      }
      final pair = _splitPair(line);
      if (pair == null) continue;
      final channel = _channel(pair.$1, pair.$2, group: group);
      if (channel != null) out.add(channel);
    }
    return out;
  }

  /// `频道名,URL`（也接受中文逗号 / 竖线 / 制表符）。
  static (String, String)? _splitPair(String line) {
    final text = line.trim();
    if (text.isEmpty || text.startsWith('#')) return null;
    var cut = -1;
    for (final sep in const <String>[',', '，', '|', '\t']) {
      final at = text.indexOf(sep);
      if (at > 0 && (cut < 0 || at < cut)) cut = at;
    }
    if (cut <= 0) return null;
    final name = text.substring(0, cut).trim();
    final url = text.substring(cut + 1).trim();
    if (name.isEmpty || !_looksLikeUrl(url)) return null;
    return (name, url);
  }

  /* ------------------------------------------------------------ JSON */

  static List<LiveChannel> _parseJson(String text) {
    Object? raw;
    try {
      raw = jsonDecode(text);
    } catch (_) {
      return const <LiveChannel>[];
    }
    final out = <LiveChannel>[];
    void walk(Object? node, String group) {
      if (node is List) {
        for (final e in node) {
          walk(e, group);
        }
        return;
      }
      if (node is String) {
        final pair = _splitPair(node);
        if (pair == null) return;
        final channel = _channel(pair.$1, pair.$2, group: group);
        if (channel != null) out.add(channel);
        return;
      }
      if (node is! Map) return;
      final m = Map<String, dynamic>.from(node);
      final name = _firstText(<Object?>[
        m['name'],
        m['title'],
        m['channel'],
        m['tvg_name'],
        m['tvg-name'],
      ]);
      final url = _firstText(<Object?>[
        m['url'],
        m['address'],
        m['playurl'],
        m['play_url'],
        m['live_url'],
        m['link'],
      ]);
      final groupName = _firstText(<Object?>[
        m['group'],
        m['group-title'],
        m['group_name'],
        m['category'],
      ]);
      final cover = _firstText(<Object?>[
        m['logo'],
        m['pic'],
        m['icon'],
        m['cover'],
        m['tvg_logo'],
      ]);
      if (_looksLikeUrl(url)) {
        final channel = _channel(
          name.isEmpty ? _hostOf(url) : name,
          url,
          group: groupName.isEmpty ? group : groupName,
          cover: cover,
          height: _intOf(m['height']),
        );
        if (channel != null) out.add(channel);
        // 有的源把备用地址放在 urls / lines 里，一并收下。
        for (final key in const <String>['urls', 'lines', 'backup']) {
          final extra = m[key];
          if (extra is List) {
            for (final e in extra) {
              if (e is String && _looksLikeUrl(e)) walk(e, groupName);
            }
          }
        }
        return;
      }
      // 分组容器：`{"name":"央视","channels":[…]}`。
      final nextGroup = groupName.isEmpty ? name : groupName;
      var walked = false;
      for (final entry in m.entries) {
        if (entry.value is! List) continue;
        walked = true;
        walk(entry.value, nextGroup.isEmpty ? group : nextGroup);
      }
      if (!walked) {
        for (final entry in m.entries) {
          if (entry.value is Map) walk(entry.value, nextGroup.isEmpty ? group : nextGroup);
        }
      }
    }

    walk(raw, '');
    return out;
  }

  /* ------------------------------------------------------------ 组装 */

  /// 频道 → 按分区名分组的 [LiveGroup]（分组名即直播页分区名）。
  static List<LiveGroup> groupChannels(List<LiveChannel> channels) {
    final buckets = <String, List<LiveChannel>>{};
    final seen = <String>{};
    for (final channel in channels) {
      if (!seen.add(channel.id)) continue;
      final section = sectionOfName(
        channel.group.isEmpty ? channel.title : channel.group,
      );
      buckets.putIfAbsent(section, () => <LiveChannel>[]).add(channel);
    }
    final out = <LiveGroup>[];
    for (final entry in buckets.entries) {
      out.add(LiveGroup(
        id: entry.key,
        name: entry.key,
        cover: entry.value.first.cover,
        channels: List<LiveChannel>.unmodifiable(entry.value),
      ));
    }
    return out;
  }

  /// 分组 / 台名 → 直播页的分区名（与 live_groups_page 的固定顺序对齐）。
  static String sectionOfName(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return '其他';
    final upper = text.toUpperCase();
    if (text.contains('少儿') || text.contains('卡酷') || text.contains('卡通')) {
      return '少儿频道';
    }
    if (text.contains('港澳台') ||
        text.contains('香港') ||
        text.contains('澳门') ||
        text.contains('台湾')) {
      return '港澳台';
    }
    if (text.contains('海外') || text.contains('国际')) {
      return '海外频道';
    }
    if (text.contains('体育') || text.contains('赛事') || upper.contains('CCTV-5')) {
      return '体育频道';
    }
    if (text.contains('卫视')) return '卫视频道';
    if (text.contains('央视') || upper.contains('CCTV') || text.contains('中央')) {
      return '央视频道';
    }
    if (text.contains('地方') ||
        text.contains('城市') ||
        text.contains('都市') ||
        RegExp(r'[\u4e00-\u9fa5]{2,}(频道|台)$').hasMatch(text)) {
      return '地方频道';
    }
    return '其他';
  }

  static LiveChannel? _channel(
    String name, String url, {
    String group = '',
    String cover = '',
    int height = 0,
  }) {
    final title = name.trim();
    final address = url.trim();
    if (title.isEmpty || !_looksLikeUrl(address)) return null;
    final id = _idOf(title, address);
    return LiveChannel(
      id: id,
      title: title,
      cover: cover.trim(),
      url: address,
      group: group.trim(),
      lines: <LiveLine>[
        // 服务端实测的分辨率（hx_live.json 的 height）：卡片靠它打 1080P 标签。
        LiveLine(id: '${id}_1', name: '', url: address, height: height),
      ],
    );
  }

  /// 频道 id：台名 + 地址，跨分组去重和收藏都用它。
  static String _idOf(String name, String url) {
    final text = '$name|$url';
    if (text.length <= 120) return text;
    return text.substring(0, 60) + text.substring(text.length - 56);
  }

  static bool _looksLikeUrl(String raw) {
    final text = raw.trim().toLowerCase();
    if (text.isEmpty) return false;
    if (text.contains(' ')) return false;
    return text.startsWith('http://') ||
        text.startsWith('https://') ||
        text.startsWith('rtmp://') ||
        text.startsWith('rtsp://') ||
        text.startsWith('udp://') ||
        text.startsWith('p3p://') ||
        text.startsWith('rtp://');
  }

  static String _hostOf(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? '未命名频道' : host;
  }

  static int _intOf(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? 0;
    return 0;
  }

  static String _firstText(List<Object?> values) {
    for (final value in values) {
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  /* ------------------------------------------------------------ 缓存 */

  static Future<_Cached?> _readCache() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_kCache);
      if (raw == null || raw.trim().isEmpty) return null;
      final body = jsonDecode(raw);
      if (body is! Map) return null;
      final map = Map<String, dynamic>.from(body);
      final text = '${map['body'] ?? ''}';
      if (text.trim().isEmpty) return null;
      final at = map['at'];
      return _Cached(
        url: '${map['url'] ?? ''}',
        body: text,
        at: at is int && at > 0
            ? DateTime.fromMillisecondsSinceEpoch(at)
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeCache(String url, String body) async {
    try {
      final text = body.length > cacheLimit
          ? body.substring(0, cacheLimit)
          : body;
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
        _kCache,
        jsonEncode(<String, dynamic>{
          'url': url,
          'at': DateTime.now().millisecondsSinceEpoch,
          'body': text,
        }),
      );
    } catch (_) {}
  }
}

class _Cached {
  const _Cached({required this.url, required this.body, this.at});

  final String url;
  final String body;
  final DateTime? at;
}

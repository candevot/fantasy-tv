// ---------------------------------------------------------------------------
// JSON 安全取值：服务端数据脏（null、数字混进字符串、对象冒充数组）时，
// 宁可让单个字段退化成默认值、单个条目跳过，也不让整个页面解析失败。
// ---------------------------------------------------------------------------

String _asStr(Object? v, {String fallback = ''}) {
  if (v is String) return v;
  if (v is num || v is bool) return '$v';
  return fallback;
}

num _asNum(Object? v, {num fallback = 0}) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v.trim()) ?? fallback;
  if (v is bool) return v ? 1 : 0;
  return fallback;
}

int _asInt(Object? v, {int fallback = 0}) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) {
    final s = v.trim();
    return int.tryParse(s) ?? double.tryParse(s)?.toInt() ?? fallback;
  }
  return fallback;
}

/// 评分：服务端可能给 null / 0 / 越界值。只保留 (0, 10]，其余按「无评分」处理，
/// 卡片和详情都不再渲染评分角标（不要把 null 显示成 0.0 或 10.0）。
num _asRating(Object? v) {
  final r = _asNum(v);
  if (!r.isFinite || r <= 0 || r > 10) return 0;
  return r;
}

/// 年份：null / 0 / <1900 / >当前年+1 一律视为未知（0），UI 用 `year > 0` 隐藏。
int _asYear(Object? v) {
  final y = _asInt(v);
  final maxYear = DateTime.now().year + 1;
  return (y >= 1900 && y <= maxYear) ? y : 0;
}

const Map<String, String> _htmlEntities = <String, String>{
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': ' ',
  '#39': "'",
  '#34': '"',
  'mdash': '—',
  'ndash': '–',
  'hellip': '…',
  'middot': '·',
};

String _entityChar(int code) {
  if (code <= 0 || code > 0x10FFFF) return '';
  try {
    return String.fromCharCode(code);
  } catch (_) {
    return '';
  }
}

/// 简介兜底：老数据里可能还有 HTML 实体 / <p> 标签，展示前再解一次。
String _decodeEntities(String input) {
  var s = input;
  if (!s.contains('&')) return s;
  s = s.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);?'), (m) {
    final code = int.tryParse(m.group(1) ?? '', radix: 16);
    return code == null ? m.group(0)! : _entityChar(code);
  });
  s = s.replaceAllMapped(RegExp(r'&#(\d+);?'), (m) {
    final code = int.tryParse(m.group(1) ?? '');
    return code == null ? m.group(0)! : _entityChar(code);
  });
  s = s.replaceAllMapped(RegExp(r'&([a-zA-Z]+|#\d+);'), (m) {
    final key = (m.group(1) ?? '').toLowerCase();
    return _htmlEntities[key] ?? m.group(0)!;
  });
  return s;
}

String _cleanDescription(Object? v) {
  var s = _asStr(v);
  if (s.isEmpty) return '';
  // 双重转义（&amp;lt;p&amp;gt;）也一起处理。
  s = _decodeEntities(_decodeEntities(s));
  s = s
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll('\u00a0', ' ')
      .replaceAll(RegExp(r'[ \t\f\v]+'), ' ')
      .replaceAll(RegExp(r'\s*\n\s*'), '\n')
      .trim();
  return s;
}

/// 不是列表就当作空列表（对象 / 字符串 / null 都不再抛 cast 异常）。
List<Object?> _asList(Object? v) => v is List ? v : const <Object?>[];

/// 不是 Map 就当作空 Map；键统一转成 String。
Map<String, dynamic> _asMap(Object? v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) {
    return <String, dynamic>{
      for (final e in v.entries) _asStr(e.key): e.value,
    };
  }
  return <String, dynamic>{};
}

/// 字符串数组：跳过对象 / 数组 / null 条目，空串也丢掉。
List<String> _asStrList(Object? v) => <String>[
      for (final e in _asList(v))
        if (e is String || e is num || e is bool) _asStr(e),
    ].where((t) => t.trim().isNotEmpty).toList();

class VideoCard {
  final String id, title, cover, status, category;
  final num rating;
  final int year, episodes;

  /// 列表接口附带的展示字段：类型（电视剧）、地区（内地）、热度文案（9.5万）。
  /// 接口没给时保持空串，UI 自动隐藏对应信息。
  final String type, area, heat;

  /// 简介：短列表接口通常不带（空串），排行榜按需再拉详情补齐。
  final String desc;

  /// 榜单排名（列表接口给 1 起的名次），非榜单数据为 0。
  final int rank;
  final List<String> tags;

  VideoCard({
    required this.id,
    required this.title,
    required this.cover,
    this.rating = 0,
    this.year = 0,
    this.status = '',
    this.episodes = 0,
    this.category = '',
    this.type = '',
    this.area = '',
    this.heat = '',
    this.desc = '',
    this.rank = 0,
    this.tags = const [],
  });

  factory VideoCard.fromJson(Map<String, dynamic> j) => VideoCard(
        id: _asStr(j['id']),
        title: _asStr(j['title']),
        cover: _asStr(j['cover']),
        rating: _asRating(j['rating']),
        year: _asYear(j['year']),
        status: _asStr(j['status']),
        episodes: _asInt(j['episodes']),
        category: _asStr(j['category']),
        type: _asStr(j['type']),
        area: _asStr(j['area']),
        heat: _asStr(j['heat']),
        desc: _cleanDescription(j['desc']),
        rank: _asInt(j['rank']),
        tags: _asStrList(j['tags']),
      );
}

class BannerItem {
  final String id, title, cover, desc;
  final num rating;
  BannerItem(this.id, this.title, this.cover, this.desc, this.rating);
  factory BannerItem.fromJson(Map<String, dynamic> j) => BannerItem(
      _asStr(j['id']),
      _asStr(j['title']),
      _asStr(j['cover']),
      _asStr(j['desc']),
      _asRating(j['rating']));
}

class HomeSection {
  final String title;
  final List<VideoCard> items;
  HomeSection(this.title, this.items);
}

class HomeData {
  final List<BannerItem> banners;
  final List<HomeSection> sections;
  HomeData(this.banners, this.sections);
}

class LineInfo {
  final String id, name, type;
  final int priority;

  /// 来源站名（如「红牛」）与原始 vod_play_from（如「hnm3u8」），旧接口可能为空。
  final String? source, from;
  LineInfo(this.id, this.name, this.type, this.priority,
      {this.source, this.from});
  factory LineInfo.fromJson(Map<String, dynamic> j) => LineInfo(
      _asStr(j['id']),
      _asStr(j['name']),
      _asStr(j['type'], fallback: 'hls'),
      _asInt(j['priority']),
      source: _lineOptStr(j['source']),
      from: _lineOptStr(j['from']));

  bool get needsParse => type.trim().toLowerCase() == 'parse';

  /// 卡片文案：只显示线路名，name 为空时才退回来源站名。
  String get displayName => name.isNotEmpty ? name : (source?.trim() ?? '');
}

String? _lineOptStr(Object? v) {
  if (v == null) return null;
  final s = '$v'.trim();
  return s.isEmpty ? null : s;
}

/// 线路名去掉「·高清」「-线路2」这类后缀后的基础名。
String _lineBaseName(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return '';
  final base = name.split(RegExp(r'\s*[·・•|｜/\\\-–—_:：]\s*')).first.trim();
  return base.isEmpty ? name : base;
}

/// 同名 / 前缀相同的线路视为同一来源的不同镜像。
bool _lineNamesMatch(String a, String b) {
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  if (a.length < 2 || b.length < 2) return false;
  return a.startsWith(b) || b.startsWith(a);
}

/// 合并「高清线路」「高清线路·线路2」这类同源线路：
/// 只保留一条可播放线路（优先非 parse），剧集仍按整部剧合并展示。
/// 不同 source 的线路即使名称前缀相同也不合并。
List<LineInfo> mergeLines(List<LineInfo> lines) {
  final groups = <List<LineInfo>>[];
  final bases = <String>[];
  final sources = <String>[];

  for (final line in lines) {
    final base = _lineBaseName(line.name);
    final source = line.source?.trim() ?? '';
    var hit = -1;
    if (base.isNotEmpty) {
      for (var i = 0; i < groups.length; i++) {
        if (sources[i] == source && _lineNamesMatch(bases[i], base)) {
          hit = i;
          break;
        }
      }
    }
    if (hit < 0) {
      groups.add(<LineInfo>[line]);
      bases.add(base);
      sources.add(source);
    } else {
      groups[hit].add(line);
      if (base.length < bases[hit].length) bases[hit] = base;
    }
  }

  LineInfo pick(List<LineInfo> group) {
    for (final line in group) {
      if (!line.needsParse) return line;
    }
    return group.first;
  }

  return <LineInfo>[for (final group in groups) pick(group)];
}

class Episode {
  final int n, duration;
  final String name;
  Episode(this.n, this.name, this.duration);
  factory Episode.fromJson(Map<String, dynamic> j) =>
      Episode(_asInt(j['n']), _asStr(j['name']), _asInt(j['duration']));
}

class EpisodeGroup {
  final String name;
  final List<Episode> episodes;
  EpisodeGroup(this.name, this.episodes);
}

class VideoDetail {
  final String id, title, cover, backdrop, area, category, status, desc;
  final num rating;
  final int year, episodes;
  final List<String> tags, director, cast;
  final List<LineInfo> lines;
  final List<EpisodeGroup> groups;
  final List<VideoCard> related;

  /// 猜你喜欢的 id（服务端 `related` 返回的是 id 数组），
  /// 详情页据此补卡片；老接口的 `relatedCards` 仍然兼容。
  final List<String> relatedIds;

  VideoDetail({
    required this.id,
    required this.title,
    required this.cover,
    required this.backdrop,
    required this.rating,
    required this.year,
    required this.area,
    required this.category,
    required this.status,
    required this.episodes,
    required this.desc,
    required this.tags,
    required this.director,
    required this.cast,
    required this.lines,
    required this.groups,
    required this.related,
    this.relatedIds = const <String>[],
  });

  List<Episode> get allEpisodes => [for (final g in groups) ...g.episodes];

  factory VideoDetail.fromJson(Map<String, dynamic> j) {
    // `related` 是 id 数组（也兼容直接给卡片对象），`relatedCards` 是旧字段。
    final cards = <VideoCard>[];
    final ids = <String>[];
    void readRelated(Object? raw) {
      for (final e in _asList(raw)) {
        if (e is Map) {
          cards.add(VideoCard.fromJson(_asMap(e)));
          continue;
        }
        final id = _asStr(e).trim();
        if (id.isNotEmpty && !ids.contains(id)) ids.add(id);
      }
    }

    readRelated(j['related']);
    readRelated(j['relatedCards']);

    // 线路 / 分组 / 单集里的坏条目直接跳过，不让整页解析失败。
    final lines = <LineInfo>[
      for (final e in _asList(j['lines']))
        if (e is Map) LineInfo.fromJson(_asMap(e)),
    ];
    final groups = <EpisodeGroup>[];
    for (final raw in _asList(j['episodeGroups'])) {
      if (raw is! Map) continue;
      final m = _asMap(raw);
      groups.add(EpisodeGroup(
        _asStr(m['name'], fallback: '正片'),
        <Episode>[
          for (final x in _asList(m['episodes']))
            if (x is Map) Episode.fromJson(_asMap(x)),
        ],
      ));
    }

    final cover = _asStr(j['cover']);
    return VideoDetail(
      id: _asStr(j['id']),
      title: _asStr(j['title']),
      cover: cover,
      backdrop: _asStr(j['backdrop'], fallback: cover),
      rating: _asRating(j['rating']),
      year: _asYear(j['year']),
      area: _asStr(j['area']),
      category: _asStr(j['category']),
      status: _asStr(j['status']),
      episodes: _asInt(j['episodes']),
      desc: _cleanDescription(j['desc']),
      tags: _asStrList(j['tags']),
      director: _asStrList(j['director']),
      cast: _asStrList(j['cast']),
      lines: mergeLines(lines),
      groups: groups,
      related: cards,
      relatedIds: ids,
    );
  }
}

class QualityItem {
  final String key, name, url;

  /// 该清晰度地址自己的请求头（服务端可能只给某一路带 Referer/UA）。
  final Map<String, String> headers;

  QualityItem(this.key, this.name, this.url, [this.headers = const {}]);
}

/// 部分苹果CMS/采集源会校验 UA；bfvvs 系播放地址还必须带站内 Referer。
const String kMaccmsReferer = 'https://hn.bfvvs.com/';
const String kDefaultVideoUserAgent = 'Mozilla/5.0';

Map<String, String> _playHeaders(String url, Map<String, dynamic> raw) {
  final headers = <String, String>{};
  for (final e in raw.entries) {
    final v = _asStr(e.value);
    if (v.trim().isNotEmpty) headers['${e.key}'] = v;
  }
  bool has(String name) =>
      headers.keys.any((k) => k.toLowerCase() == name.toLowerCase());

  if (!has('User-Agent')) headers['User-Agent'] = kDefaultVideoUserAgent;
  final host = (Uri.tryParse(url)?.host ?? '').toLowerCase();
  if ((host == 'bfvvs.com' || host.endsWith('.bfvvs.com')) && !has('Referer')) {
    headers['Referer'] = kMaccmsReferer;
  }
  return headers;
}

class PlayInfo {
  final String url, type, parsePage, lineName;
  final List<QualityItem> quality;
  final List<String> backup;
  final Map<String, String> headers;

  PlayInfo({
    required this.url,
    required this.type,
    required this.quality,
    required this.backup,
    required this.headers,
    required this.parsePage,
    required this.lineName,
  });

  factory PlayInfo.fromJson(Map<String, dynamic> j) {
    final url = _asStr(j['url']);
    final quality = <QualityItem>[];
    for (final e in _asList(j['quality'])) {
      if (e is! Map) continue;
      final q = _asMap(e);
      final qUrl = _asStr(q['url']);
      // 没有地址的清晰度没有意义，跳过即可。
      if (qUrl.trim().isEmpty) continue;
      quality.add(QualityItem(
        _asStr(q['key']),
        _asStr(q['name']),
        qUrl,
        _playHeaders(qUrl, _asMap(q['headers'])),
      ));
    }
    return PlayInfo(
      url: url,
      type: _asStr(j['type'], fallback: 'hls'),
      lineName: _asStr(j['lineName']),
      parsePage: _asStr(j['parsePage']),
      quality: quality,
      backup: _asStrList(j['backup']),
      headers: _playHeaders(url, _asMap(j['headers'])),
    );
  }
}

class CommentItem {
  final String user, avatar, content, time;
  final num score;
  final int likes, replies;
  CommentItem(this.user, this.avatar, this.content, this.time, this.score,
      this.likes, this.replies);
  factory CommentItem.fromJson(Map<String, dynamic> j) {
    final u = _asMap(j['user']);
    return CommentItem(
        _asStr(u['name'], fallback: '影迷'),
        _asStr(u['avatar']),
        _asStr(j['content']),
        _asStr(j['time']),
        _asNum(j['score']),
        _asInt(j['likes']),
        _asList(j['replies']).length);
  }
}

class TogetherRoom {
  final String code, title, videoTitle, cover, host;
  final int members;
  TogetherRoom(this.code, this.title, this.videoTitle, this.cover, this.host,
      this.members);
  factory TogetherRoom.fromJson(Map<String, dynamic> j) => TogetherRoom(
        _asStr(j['code']),
        _asStr(j['title']),
        _asStr(j['videoTitle']),
        _asStr(j['cover']),
        _asStr(j['host']),
        _asInt(j['members'], fallback: 1),
      );
}

/// 登录用户（服务器 `/api/user/me`、`/api/user/profile` 的 user 字段）。
class AuthUser {
  const AuthUser({
    required this.id,
    required this.account,
    required this.nickname,
    required this.avatar,
    required this.signature,
  });

  final String id, account, nickname, avatar, signature;

  factory AuthUser.fromJson(Map<String, dynamic> j) => AuthUser(
        id: _asStr(j['id']),
        account: _asStr(j['account']),
        nickname: _asStr(j['nickname']),
        avatar: _asStr(j['avatar']),
        signature: _asStr(j['signature']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'account': account,
        'nickname': nickname,
        'avatar': avatar,
        'signature': signature,
      };

  AuthUser copyWith({String? nickname, String? avatar, String? signature}) =>
      AuthUser(
        id: id,
        account: account,
        nickname: nickname ?? this.nickname,
        avatar: avatar ?? this.avatar,
        signature: signature ?? this.signature,
      );
}

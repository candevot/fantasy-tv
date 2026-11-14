import 'dart:convert';

import 'api.dart';

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

  /// 片名下的来源标记（当前主线路的线路名，如「红牛」「幻想4K」）。
  /// 列表接口可直接给 `source`；没给时用 `lines[0].name` 兜底，
  /// 两者都没有就留空，卡片不渲染这一行。
  final String sourceLabel;

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
    this.sourceLabel = '',
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
        sourceLabel: _cardSourceLabel(
          j['sourceLabel'] ?? j['source'],
          j['lines'],
        ),
      );
}

/// 卡片来源标记：优先接口 `source`，其次 `lines[0]` 的线路名 / 来源站名。
/// 列表接口两者都没给时返回空串，UI 不显示、也不占高度。
String _cardSourceLabel(Object? source, Object? lines) {
  final direct = _asStr(source).trim();
  if (direct.isNotEmpty) return direct;
  for (final e in _asList(lines)) {
    if (e is Map) {
      final m = _asMap(e);
      final name = _asStr(m['name']).trim();
      if (name.isNotEmpty) return name;
      final src = _asStr(m['source']).trim();
      if (src.isNotEmpty) return src;
    } else if (e is String) {
      final name = e.trim();
      if (name.isNotEmpty) return name;
    }
  }
  return '';
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

/// 直播线路：同一频道可能有 4K / 1080P / 720P 多条流。
///
/// 服务端（`GET /api/live`）只给 `{label,url,height}`，没有 id：
/// 解析时按高度降序排序后补 `l1…lN`，保证同房间的成员拿到相同 lineId。
class LiveLine {
  final String id, name, url;
  final int height;

  /// 服务端实测结果（/api/live/tested）：false 表示这条线路探测失败。
  /// 老接口没这个字段时按「未知」处理（true），行为与升级前一致。
  final bool ok;

  /// 失效原因（如 http-404 / timeout），仅用于展示与排障。
  final String deadReason;

  const LiveLine({
    required this.id,
    required this.name,
    required this.url,
    this.height = 0,
    this.ok = true,
    this.deadReason = '',
  });

  /// 展示用清晰度：优先真实分辨率 `宽x高`（如 `1920x1080`）——
  /// 线路名里直接带宽高就用它，否则按服务端给的高度反推宽度；
  /// 完全拿不到数值时才退回通俗标签（4K / 1080P / 直播）。
  String get qualityLabel {
    final dims = _dimsFromName(name) ?? _dimsFromHeight(height);
    if (dims != null) return '${dims.$1}x${dims.$2}';
    return plainQualityLabel;
  }

  /// 通俗标签（旧分档 4K / 1080P / 720P / 标清）：
  /// 拿不到真实宽高时的兜底，另给 [subtitle] 判断线路名是否与画质重复。
  String get plainQualityLabel {
    final raw = name.trim().toUpperCase();
    if (raw == '4K' || raw == '1080P' || raw == '720P' || raw == 'SD') {
      return raw == 'SD' ? '标清' : raw;
    }
    final label = _liveTierLabel(height);
    return label.isEmpty ? (raw.isEmpty ? '直播' : name.trim()) : label;
  }

  /// 线路卡副标题：服务端 label 与清晰度重复时退回线路序号。
  String subtitle(int index) {
    final n = name.trim();
    if (n.isEmpty ||
        n.toUpperCase() == qualityLabel.toUpperCase() ||
        n.toUpperCase() == plainQualityLabel.toUpperCase()) {
      return '线路 ${index + 1}';
    }
    return n;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'url': url,
        if (height > 0) 'height': height,
      };

  factory LiveLine.fromJson(Map<String, dynamic> j) {
    final name = _asStr(j['label']).trim().isNotEmpty
        ? _asStr(j['label'])
        : (_asStr(j['name']).trim().isNotEmpty
            ? _asStr(j['name'])
            : _asStr(j['resolution']));
    var height = _asInt(j['height']);
    if (height <= 0) height = _heightFromLabel(name);
    return LiveLine(
      id: _asStr(j['id']),
      name: name,
      url: _asStr(j['url']).trim().isNotEmpty
          ? _asStr(j['url'])
          : _asStr(j['playUrl']),
      height: height,
      ok: j['ok'] is bool ? j['ok'] as bool : true,
      deadReason: _asStr(j['dead']),
    );
  }
}

/// 直播清晰度 → 真实分辨率文案 `宽x高`（1080 → `1920x1080`）；
/// 0 高度返回空串（旧接口没有分辨率，调用方自行隐藏）。
String liveQualityLabel(int height) {
  final dims = _dimsFromHeight(height);
  return dims == null ? '' : '${dims.$1}x${dims.$2}';
}

/// 通俗分档标签：4K / 1080P / 720P / 标清；0 高度返回空串。
/// 仅在拿不到真实宽高时兜底显示。
String _liveTierLabel(int height) {
  if (height >= 2160) return '4K';
  if (height >= 1080) return '1080P';
  if (height >= 720) return '720P';
  if (height > 0) return '标清';
  return '';
}

/// 线路名 / label 里抠 `1920x1080` 这类真实宽高，抠不到返回 null。
(int, int)? _dimsFromName(String raw) {
  final m = RegExp(r'(\d{3,4})\s*[x×*]\s*(\d{3,4})').firstMatch(raw);
  if (m == null) return null;
  final w = int.tryParse(m.group(1)!) ?? 0;
  final h = int.tryParse(m.group(2)!) ?? 0;
  if (w <= 0 || h <= 0) return null;
  return (w, h);
}

/// 只有高度时按 16:9 反推宽度（直播线路常见 1080 → 1920），
/// 宽度取偶数，得到 1920x1080 / 1280x720 这类标准值。
(int, int)? _dimsFromHeight(int height) {
  if (height <= 0) return null;
  final w = (height * 16 / 9).round();
  return (w.isEven ? w : w + 1, height);
}

int _heightFromLabel(String raw) {
  final s = raw.trim().toUpperCase();
  if (s.contains('4K') || s.contains('2160')) return 2160;
  if (s.contains('1080')) return 1080;
  if (s.contains('720')) return 720;
  if (s.contains('576') || s.contains('480') || s.contains('SD')) return 480;
  return 0;
}

List<LiveLine> _parseLiveLines(Object? raw, String fallbackUrl) {
  final input = <LiveLine>[];
  for (final e in _asList(raw)) {
    if (e is String) {
      final url = e.trim();
      if (url.isEmpty) continue;
      input.add(LiveLine(id: '', name: '', url: url));
    } else if (e is Map) {
      final line = LiveLine.fromJson(_asMap(e));
      if (line.url.trim().isEmpty) continue;
      input.add(line);
    }
  }
  if (input.isEmpty && fallbackUrl.trim().isNotEmpty) {
    input.add(LiveLine(id: 'l1', name: '', url: fallbackUrl.trim()));
  }
  // 按高度降序；高度相同时保持服务端顺序，避免成员之间排序不一致。
  final indexed = <MapEntry<int, LiveLine>>[
    for (var i = 0; i < input.length; i++) MapEntry<int, LiveLine>(i, input[i]),
  ];
  indexed.sort((a, b) {
    final byHeight = b.value.height.compareTo(a.value.height);
    return byHeight != 0 ? byHeight : a.key.compareTo(b.key);
  });
  final seen = <String>{};
  final out = <LiveLine>[];
  for (var i = 0; i < indexed.length; i++) {
    final line = indexed[i].value;
    if (!seen.add(line.url)) continue;
    out.add(LiveLine(
      id: line.id.trim().isEmpty ? 'l${out.length + 1}' : line.id.trim(),
      name: line.name,
      url: line.url,
      height: line.height,
    ));
  }
  return out;
}

/// 直播频道条目：`GET /api/live` → `groups[].channels[]`
/// （兼容旧版扁平 `items`）。`lines` 为空时用 url 兜底成单线路。
class LiveChannel {
  final String id, title, cover, url, group;
  final List<LiveLine> lines;

  const LiveChannel({
    required this.id,
    required this.title,
    required this.cover,
    this.url = '',
    this.group = '',
    this.lines = const <LiveLine>[],
  });

  factory LiveChannel.fromJson(Map<String, dynamic> j) {
    final title = _asStr(j['title']).trim().isNotEmpty
        ? _asStr(j['title'])
        : _asStr(j['name']);
    final url = _asStr(j['url']);
    return LiveChannel(
      id: _asStr(j['id']),
      title: title,
      cover: _asStr(j['cover']).trim().isNotEmpty
          ? _asStr(j['cover'])
          : _asStr(j['logo']),
      url: url,
      group: _asStr(j['group']),
      lines: _parseLiveLines(j['lines'], url),
    );
  }

  LiveChannel copyWith({String? group}) => LiveChannel(
        id: id,
        title: title,
        cover: cover,
        url: url,
        group: group ?? this.group,
        lines: lines,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'id': id,
        'title': title,
        'cover': cover,
        'url': url,
        'group': group,
        'lines': [for (final line in lines) line.toJson()],
      };

  /// 从收藏 / 房间标题里还原频道；数据不合法时返回 null。
  static LiveChannel? tryFrom(Object? raw) {
    if (raw is Map) {
      final c = LiveChannel.fromJson(_asMap(raw));
      return c.id.isEmpty || c.lines.isEmpty ? null : c;
    }
    return null;
  }
}

/// 一起看房间标题里携带直播频道的标记。
///
/// 旧服务端只回传 `title` 文本，不会透传 `kind/channelId/lines`；把频道
/// 压缩进标题后，成员加入时仍能解析出频道和线路。新服务端若透传了
/// `kind/channelId/lines`，则优先使用结构化字段，这里只是兼容兜底。
const String liveRoomMarker = '#FXLV#';

String encodeLiveRoomTitle(LiveChannel channel) {
  try {
    final raw = jsonEncode(channel.toMap());
    final code = base64Url.encode(utf8.encode(raw)).replaceAll('=', '');
    final name = channel.title.trim().isEmpty ? '电视直播' : channel.title.trim();
    return '$name · 一起看$liveRoomMarker$code';
  } catch (_) {
    return '${channel.title} · 一起看';
  }
}

/// 从房间标题里拆出频道；不是直播房 / 数据损坏时返回 null。
LiveChannel? decodeLiveRoomTitle(String title) {
  final at = title.lastIndexOf(liveRoomMarker);
  if (at < 0) return null;
  final code = title.substring(at + liveRoomMarker.length).trim();
  if (code.isEmpty) return null;
  try {
    final normalized = base64Url.normalize(code);
    final json = jsonDecode(utf8.decode(base64Url.decode(normalized)));
    final channel = LiveChannel.tryFrom(json);
    if (channel == null) return null;
    return channel;
  } catch (_) {
    return null;
  }
}

/// 房间列表 / 标题展示时去掉编码尾巴。
String stripLiveRoomTitle(String title) {
  final at = title.lastIndexOf(liveRoomMarker);
  return at < 0 ? title : title.substring(0, at).trim();
}

/// 直播分组：`GET /api/live` → `{groups:[{id,name,cover,channels:[…]}]}`。
/// 首页直播 Tab 显示分组卡，点开后进入该组的频道列表。
class LiveGroup {
  final String id, name, cover;
  final List<LiveChannel> channels;

  const LiveGroup({
    required this.id,
    required this.name,
    required this.cover,
    required this.channels,
  });

  int get count => channels.length;

  factory LiveGroup.fromJson(Map<String, dynamic> j) {
    final name = _asStr(j['name']);
    final raw = j['channels'] is List ? j['channels'] : j['items'];
    final list = <LiveChannel>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        final c = LiveChannel.fromJson(Map<String, dynamic>.from(e));
        if (c.title.isEmpty || c.lines.isEmpty) continue;
        list.add(c.copyWith(group: c.group.isEmpty ? name : c.group));
      }
    }
    return LiveGroup(
      id: _asStr(j['id']),
      name: name,
      cover: _asStr(j['cover']),
      channels: list,
    );
  }
}

class LineInfo {
  final String id, name, type;
  final int priority;

  /// 来源站名（如「红牛」）与原始 vod_play_from（如「hnm3u8」），旧接口可能为空。
  final String? source, from;

  /// 服务端线路健康度：近 N 次抽样成功率低于阈值时标 degraded。
  /// 只用于展示提示与排到最后，不隐藏线路（服务端仍会照常返回）。
  final bool degraded;

  /// 健康度成功率（0–1），服务端未给时为 0。
  final double healthRate;

  /// 这条线路**自己**的集名（如「正片」「粤语版」「国语中字」）。
  ///
  /// LINE_EPNAMES：以前所有线路共用「合并后最长那条线路」的集名，
  /// 于是三条线路都显示同一套 5 集，可有些线路根本没这些集，
  /// 点进去就播不出来。现在按线路显示该线路真实的集。
  final List<String> epNames;

  LineInfo(
    this.id,
    this.name,
    this.type,
    this.priority, {
    this.source,
    this.from,
    this.degraded = false,
    this.healthRate = 0,
    this.epNames = const <String>[],
  });

  factory LineInfo.fromJson(Map<String, dynamic> j) {
    final health = j['health'];
    final rate = health is Map ? _asNum(health['rate']) : 0;
    return LineInfo(
      _asStr(j['id']),
      _asStr(j['name']),
      _asStr(j['type'], fallback: 'hls'),
      _asInt(j['priority']),
      source: _lineOptStr(j['source']),
      from: _lineOptStr(j['from']),
      degraded: j['degraded'] == true,
      healthRate: rate.toDouble(),
      epNames: _asStrList(j['epnames']),
    );
  }

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

/// 是否为服务端异步补算的平台线路（腾讯 / 芒果 / B 站 …）。
///
/// 服务端平台匹配改成异步后，首屏 /api/detail 可能暂时只返回采集线路，
/// 客户端据此决定要不要再拉几次 detail 把平台线补齐。
/// 这条线路是否需要经过「客户端本地代理」。
///
/// 只有平台会员线路（腾讯 / 爱奇艺 / 芒果，地址是 /api/fyplay、
/// /api/iqiyi.m3u8 这类需要服务端签名、会过期的包装地址）才需要：
/// 代理负责重写分片签名、定时换新地址。
///
/// 采集线路（红牛 / 量子 / 幻想蓝光 / 幻想4K）不要走代理 ——
/// 服务端返回的播放列表里分片已经是绝对地址（指向服务器 /api/proxy），
/// mpv 自己就能边下边播。走客户端代理时是「整片下完再交给 mpv」，
/// 1080P 分片 1~2MB 看不出来，4K 分片 10~40MB 就会一直卡、一直转圈。
bool fxNeedsClientProxy(String lineId) {
  final raw = lineId.toLowerCase();
  return raw.startsWith('pt_') ||
      raw.contains('tencent') ||
      raw.contains('iqiyi') ||
      raw.contains('mgtv');
}

/// 按「实际播放地址」判断是否需要客户端代理，比按线路 id 准确得多。
///
/// 实测（2026-11-07）：
///  · 腾讯独家直连返回的是 https://apd-vlive.apdcdn.tc.qq.com/... 这类
///    CDN 绝对地址，278 个分片全是相对路径、不经我们的服务器，
///    签名也不会变（两次请求 URL 完全相同）→ 不需要代理；
///  · 爱奇艺返回 /api/iqiyi.m3u8?tvid=... 这种站内包装地址，
///    必须由服务端拼 dash 并回源 → 需要代理；
///  · 采集线路返回绝对地址（指向服务器 /api/proxy），也不需要客户端代理。
///
/// 走客户端代理是「整片下完再交给 mpv」，4K 分片 10~40MB 时会一直卡；
/// 能直连就直连，让 mpv 自己边下边播。
/// 把服务端给的站内地址补成绝对地址，让 mpv 能直接拉。
///
/// 服务端有些线路返回 `/api/fyplay?u=...`、`/api/iqiyi.m3u8?...`
/// 这种没有主机名的相对路径。App 能靠 Api.base 补全，但**如果先交给
/// 客户端代理，代理就会整片下完再给 mpv** —— 4K 分片 10~40MB 时
/// 这就是卡顿来源。补全后 mpv 自己就能边下边播。
String fxAbsolutePlayUrl(String url) {
  final raw = url.trim();
  if (raw.isEmpty) return raw;
  if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
  final base = Api.base.trim();
  if (base.isEmpty) return raw;
  // Api.base 形如 http://host:8787/api → 取根 http://host:8787
  final root = base.replaceFirst(RegExp(r'/api/?$'), '');
  if (raw.startsWith('/')) return '$root$raw';
  return '$root/$raw';
}

/// 这条播放地址是否仍然需要客户端代理。
///
/// 实测（2026-11-07）：腾讯独家、爱奇艺、幻想4K、幻想蓝光、红牛、量子
/// 的播放列表**都能被 mpv 直接拉**（爱奇艺 692 个分片全绝对地址；
/// 4K 上游 m3u8.meilinvps.com 直连 200 / 22.8MB）。所以补全成绝对地址后
/// 一律直连，只有 mpv 完全无法解析的地址才退回代理。
///
/// 判定放在补全**之后**：补全完还不是 http(s) 的才走代理。
bool fxUrlNeedsClientProxy(String url) {
  final raw = url.trim();
  if (raw.isEmpty) return false;
  final lower = raw.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    // 指向本机回环的地址：电视 / 代理链路上不可达，仍走客户端代理兜底。
    return lower.startsWith('http://127.0.0.1') ||
        lower.startsWith('http://localhost');
  }
  return true;
}

/// 这条地址是否应该交给「本地 HLS 代理」接管。
///
/// 和 [fxUrlNeedsClientProxy] 的区别：那个判断的是「mpv 自己能不能拉」，
/// 这个判断的是「要不要为了让预加载生效而接管」。
///
/// 为什么要接管：整集预加载、预取让位播放、下一片保护这些优化全都做在
/// 本地代理里。之前只有站内包装地址（/api/fyplay、/api/iqyiyi.m3u8）走代理，
/// 采集线路（红牛 / 量子 / 蓝光 / 4K）是公网直链，被判定为「不需要代理」，
/// 于是**完全享受不到预加载** —— 用户看到的差距就在这里。
///
/// 现在凡是 http(s) 的 m3u8 都交给代理：mpv 拿到的仍是本地地址，
/// 代理负责下载、缓存、预取，分片仍然是直连 CDN（不额外消耗服务器带宽）。
bool fxShouldUseHlsProxy(String url, {required bool isHls}) {
  // PROXY_ON（2026-11-14 修正）
  //
  // 上一版我把它关掉，方向是错的。按逆向结论（咕噜咕噜 = Flutter + libmpv
  // + libtcpdownloadproxy，秒拖来自 setInfinitePreload + 动态加深预取 +
  // 分片缓存共享），这一层必须保留；我们的 LocalHlsProxy 也已经实现了
  // 流式快路径（大分片边下边发）与预取让位。
  //
  // 关掉它只会丢掉预取和缓存，起播反而更慢。
  if (!isHls) return false;
  final raw = url.trim().toLowerCase();
  if (raw.isEmpty) return false;
  if (!raw.startsWith('http://') && !raw.startsWith('https://')) return false;
  return true;
}

bool fxIsPlatformLine(LineInfo line) {
  final raw = '${line.id} ${line.name} ${line.source ?? ''} ${line.from ?? ''} ${line.type}';
  final lower = raw.toLowerCase();
  return line.type.trim().toLowerCase() == 'platform' ||
      lower.contains('tencent') ||
      lower.contains('mgtv') ||
      lower.contains('bilibili') ||
      // 爱奇艺会员线路：id 是 pt_iqiyi，之前没识别出来，
      // 客户端会误判「还没有平台线路」并反复重拉详情。
      lower.contains('iqiyi') ||
      lower.contains('pt_iqiyi') ||
      raw.contains('腾讯') ||
      raw.contains('芒果') ||
      raw.contains('爱奇艺');
}

/// 合并两次 /api/detail 的线路表：以新返回的顺序为准（平台线路在服务端
/// 已置顶），旧表里新返回没带的线路追加在后面，避免刷新反而少线路；
/// 最后按 priority 稳定排序 + degraded 压底，后补的平台线只在自己该在的
/// 位置出现，不整列表闪动。
List<LineInfo> fxMergeLines(List<LineInfo> oldLines, List<LineInfo> fresh) {
  final seen = <String>{};
  final merged = <LineInfo>[];
  void add(LineInfo line) {
    final key = line.id.trim();
    if (key.isEmpty || !seen.add(key)) return;
    merged.add(line);
  }

  for (final line in fresh) {
    add(line);
  }
  for (final line in oldLines) {
    add(line);
  }
  // Dart 的 sort 不稳定：带上原始下标做 tie-break，同 priority 保持接口顺序。
  final indexed = merged.asMap().entries.toList()
    ..sort((a, b) {
      final byPriority = a.value.priority.compareTo(b.value.priority);
      return byPriority != 0 ? byPriority : a.key.compareTo(b.key);
    });
  return sortDegradedLast([for (final e in indexed) e.value]);
}

/// degraded 线路仍然展示，但统一排到最后（稳定排序，其余线路保持接口顺序）。
List<LineInfo> sortDegradedLast(List<LineInfo> lines) {
  if (!lines.any((l) => l.degraded)) return lines;
  return <LineInfo>[
    for (final line in lines)
      if (!line.degraded) line,
    for (final line in lines)
      if (line.degraded) line,
  ];
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

  /// 线路异步补全后只替换 lines：集数 / 简介 / 相关推荐都沿用原对象，
  /// 播放器拿到的 detail 仍是同一部片，不会因为刷新线路而重新加载。
  VideoDetail copyWith({List<LineInfo>? lines}) {
    return VideoDetail(
      id: id,
      title: title,
      cover: cover,
      backdrop: backdrop,
      rating: rating,
      year: year,
      area: area,
      category: category,
      status: status,
      episodes: episodes,
      desc: desc,
      tags: tags,
      director: director,
      cast: cast,
      lines: lines ?? this.lines,
      groups: groups,
      related: related,
      relatedIds: relatedIds,
    );
  }

  /// 详情主线路的来源标记（线路名优先，空则退回 source），
  /// 供榜单这类懒加载详情的卡片补上来源小字。
  String get sourceLabel {
    for (final line in lines) {
      final name = line.displayName.trim();
      if (name.isNotEmpty) return name;
    }
    return '';
  }

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
      lines: sortDegradedLast(mergeLines(lines)),
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

  /// 服务端是否已解析出可直接播放的直链（此时 m3u8 才能走本地分片代理）；
  /// 老服务端没这个字段时保持 false，行为与升级前一致。
  final bool direct;

  PlayInfo({
    required this.url,
    required this.type,
    required this.quality,
    required this.backup,
    required this.headers,
    required this.parsePage,
    required this.lineName,
    this.direct = false,
  });

  /// 是否是 HLS 播放列表（平台线路的地址常是 /api/fyplay 这类无 .m3u8
  /// 后缀的包装地址，必须看 type，不能只看 URL）。
  bool get isHls => type.trim().toLowerCase() == 'hls';

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
      direct: j['direct'] == true,
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

class VideoCard {
  final String id, title, cover, status, category;
  final num rating;
  final int year, episodes;
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
    this.tags = const [],
  });

  factory VideoCard.fromJson(Map<String, dynamic> j) => VideoCard(
        id: '${j['id'] ?? ''}',
        title: '${j['title'] ?? ''}',
        cover: '${j['cover'] ?? ''}',
        rating: (j['rating'] ?? 0) as num,
        year: (j['year'] ?? 0) as int,
        status: '${j['status'] ?? ''}',
        episodes: (j['episodes'] ?? 0) as int,
        category: '${j['category'] ?? ''}',
        tags: ((j['tags'] ?? []) as List).map((e) => '$e').toList(),
      );
}

class BannerItem {
  final String id, title, cover, desc;
  final num rating;
  BannerItem(this.id, this.title, this.cover, this.desc, this.rating);
  factory BannerItem.fromJson(Map<String, dynamic> j) => BannerItem(
      '${j['id'] ?? ''}',
      '${j['title'] ?? ''}',
      '${j['cover'] ?? ''}',
      '${j['desc'] ?? ''}',
      (j['rating'] ?? 0) as num);
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
  LineInfo(this.id, this.name, this.type, this.priority);
  factory LineInfo.fromJson(Map<String, dynamic> j) => LineInfo('${j['id']}',
      '${j['name']}', '${j['type'] ?? 'hls'}', (j['priority'] ?? 0) as int);

  bool get needsParse => type.trim().toLowerCase() == 'parse';
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

/// 合并「量子线路」「量子线路·线路2」这类同源线路：
/// 只保留一条可播放线路（优先非 parse），剧集仍按整部剧合并展示。
List<LineInfo> mergeLines(List<LineInfo> lines) {
  final groups = <List<LineInfo>>[];
  final bases = <String>[];

  for (final line in lines) {
    final base = _lineBaseName(line.name);
    var hit = -1;
    if (base.isNotEmpty) {
      for (var i = 0; i < groups.length; i++) {
        if (_lineNamesMatch(bases[i], base)) {
          hit = i;
          break;
        }
      }
    }
    if (hit < 0) {
      groups.add(<LineInfo>[line]);
      bases.add(base);
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
  factory Episode.fromJson(Map<String, dynamic> j) => Episode(
      (j['n'] ?? 0) as int, '${j['name'] ?? ''}', (j['duration'] ?? 0) as int);
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
  });

  List<Episode> get allEpisodes => [for (final g in groups) ...g.episodes];

  factory VideoDetail.fromJson(Map<String, dynamic> j) => VideoDetail(
        id: '${j['id'] ?? ''}',
        title: '${j['title'] ?? ''}',
        cover: '${j['cover'] ?? ''}',
        backdrop: '${j['backdrop'] ?? j['cover'] ?? ''}',
        rating: (j['rating'] ?? 0) as num,
        year: (j['year'] ?? 0) as int,
        area: '${j['area'] ?? ''}',
        category: '${j['category'] ?? ''}',
        status: '${j['status'] ?? ''}',
        episodes: (j['episodes'] ?? 0) as int,
        desc: '${j['desc'] ?? ''}',
        tags: ((j['tags'] ?? []) as List).map((e) => '$e').toList(),
        director: ((j['director'] ?? []) as List).map((e) => '$e').toList(),
        cast: ((j['cast'] ?? []) as List).map((e) => '$e').toList(),
        lines: mergeLines(((j['lines'] ?? []) as List)
            .map((e) => LineInfo.fromJson(Map<String, dynamic>.from(e)))
            .toList()),
        groups: ((j['episodeGroups'] ?? []) as List).map((e) {
          final m = Map<String, dynamic>.from(e);
          return EpisodeGroup(
            '${m['name'] ?? '正片'}',
            ((m['episodes'] ?? []) as List)
                .map((x) => Episode.fromJson(Map<String, dynamic>.from(x)))
                .toList(),
          );
        }).toList(),
        related: ((j['relatedCards'] ?? []) as List)
            .map((e) => VideoCard.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

class QualityItem {
  final String key, name, url;
  QualityItem(this.key, this.name, this.url);
}

/// 部分苹果CMS/采集源会校验 UA；bfvvs 系播放地址还必须带站内 Referer。
const String kMaccmsReferer = 'https://hn.bfvvs.com/';
const String kDefaultVideoUserAgent = 'Mozilla/5.0';

Map<String, String> _playHeaders(String url, Map raw) {
  final headers = <String, String>{
    for (final e in raw.entries) '${e.key}': '${e.value}',
  };
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
  final String url, type, danmu, parsePage, lineName;
  final List<QualityItem> quality;
  final List<String> backup;
  final Map<String, String> headers;

  PlayInfo({
    required this.url,
    required this.type,
    required this.quality,
    required this.backup,
    required this.headers,
    required this.danmu,
    required this.parsePage,
    required this.lineName,
  });

  factory PlayInfo.fromJson(Map<String, dynamic> j) {
    final url = '${j['url'] ?? ''}';
    return PlayInfo(
      url: url,
      type: '${j['type'] ?? 'hls'}',
      lineName: '${j['lineName'] ?? ''}',
      danmu: '${j['danmu'] ?? ''}',
      parsePage: '${j['parsePage'] ?? ''}',
      quality: ((j['quality'] ?? []) as List)
          .map((e) => QualityItem('${e['key']}', '${e['name']}', '${e['url']}'))
          .toList(),
      backup: ((j['backup'] ?? []) as List).map((e) => '$e').toList(),
      headers: _playHeaders(url, (j['headers'] ?? {}) as Map),
    );
  }
}

class DanmuItem {
  final double t;
  final String text, color;
  final int mode;
  DanmuItem(this.t, this.text, this.color, this.mode);
  factory DanmuItem.fromJson(Map<String, dynamic> j) => DanmuItem(
      (j['t'] ?? 0).toDouble(),
      '${j['text'] ?? ''}',
      '${j['color'] ?? '#FFFFFF'}',
      (j['mode'] ?? 1) as int);
}

class CommentItem {
  final String user, avatar, content, time;
  final num score;
  final int likes, replies;
  CommentItem(this.user, this.avatar, this.content, this.time, this.score,
      this.likes, this.replies);
  factory CommentItem.fromJson(Map<String, dynamic> j) {
    final u = Map<String, dynamic>.from(j['user'] ?? {});
    return CommentItem(
        '${u['name'] ?? '影迷'}',
        '${u['avatar'] ?? ''}',
        '${j['content'] ?? ''}',
        '${j['time'] ?? ''}',
        (j['score'] ?? 0) as num,
        (j['likes'] ?? 0) as int,
        ((j['replies'] ?? []) as List).length);
  }
}

class TogetherRoom {
  final String code, title, videoTitle, cover, host;
  final int members;
  TogetherRoom(this.code, this.title, this.videoTitle, this.cover, this.host,
      this.members);
  factory TogetherRoom.fromJson(Map<String, dynamic> j) => TogetherRoom(
        '${j['code'] ?? ''}',
        '${j['title'] ?? ''}',
        '${j['videoTitle'] ?? ''}',
        '${j['cover'] ?? ''}',
        '${j['host'] ?? ''}',
        (j['members'] ?? 1) as int,
      );
}

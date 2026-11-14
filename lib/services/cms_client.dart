import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api.dart';
import '../models.dart';
import 'cms_api.dart';
import 'cms_source.dart';

/// 单个片源客户端的分类（源自己的 type_id + 名字）。
class SourceClass {
  const SourceClass(this.id, this.name);

  final int id;
  final String name;
}

/// 我们自己的七个分类键（与 [CmsBridge.channels] 的 key 一致）。
const List<String> kSourceChannelKeys = <String>[
  'movie',
  'tv',
  'anime',
  'zongyi',
  'duanju',
  'kids',
  'other',
];

/// 分类名归一化：把任意采集源的 `type_name` 映射到我们的七个分类键。
///
/// 采集源的栏目名千奇百怪（「动作片 / 国产剧 / 番剧 / 真人秀 / 微短剧 /
/// 亲子动画 / 纪录片」），硬编码一份名单永远追不上，所以按关键词分组，
/// 顺序按「越具体的越先判」：短剧要在「剧」之前、少儿要在「剧」之前，
/// 否则「国产少儿动画」会被判成电视剧。
String channelKeyOfClassName(String raw) {
  final name = raw.trim().toLowerCase();
  if (name.isEmpty) return '';
  if (_has(name, const <String>['短剧', '微短', '竖屏', '泡面番'])) return 'duanju';
  if (_has(name, const <String>['少儿', '儿童', '亲子', '益智', '早教', '儿歌'])) {
    return 'kids';
  }
  if (_has(name, const <String>['动漫', '动画', '番剧', '国漫', '日漫', '漫改'])) {
    return 'anime';
  }
  if (_has(name, const <String>['综艺', '真人秀', '脱口秀', '晚会', '选秀', '访谈'])) {
    return 'zongyi';
  }
  if (_has(name, const <String>[
    '电视剧',
    '连续剧',
    '国产剧',
    '美剧',
    '韩剧',
    '日剧',
    '港剧',
    '台剧',
    '泰剧',
    '剧集',
    '剧情片',
    '短剧集',
  ])) {
    return 'tv';
  }
  if (_has(name, const <String>[
    '纪录',
    '体育',
    '资讯',
    '新闻',
    '其他',
    '其它',
    '未分类',
    '直播',
    '福利',
    '解说',
  ])) {
    return 'other';
  }
  if (_has(name, const <String>[
    '电影',
    '片',
    '影院',
    '动作',
    '喜剧',
    '爱情',
    '科幻',
    '恐怖',
    '惊悚',
    '悬疑',
    '战争',
    '犯罪',
    '冒险',
    '武侠',
  ])) {
    return 'movie';
  }
  return '';
}

bool _has(String text, List<String> words) {
  for (final word in words) {
    if (text.contains(word)) return true;
  }
  return false;
}

/// 一个外部片源（云端下发 / 用户自加 / TVBox 导入）的请求客户端。
///
/// 只负责「按这个源的地址去要数据」，解析全部复用既有两层：
///   · `cms_source.dart` 的纯函数 → `vod_play_url` 切线路
///   · `cms_api.dart` 的 `cardOf` / `detailOf` → 老形状的模型
/// 页面拿到的仍然是 `VideoCard` / `VideoDetail` / `PlayInfo`，UI 不用改。
///
/// 缓存：同一个地址共用一个实例（[of]），分类列表只拉一次（[classes]），
/// 详情按 vod_id 缓存 [detailCacheLimit] 条，避免来回翻页重复请求。
class CmsClient {
  CmsClient(this.api);

  final String api;

  /// 接口超时：外部源可能在天南海北，给 8 秒。
  static const Duration timeout = Duration(seconds: 8);

  /// 详情缓存条数上限。
  static const int detailCacheLimit = 120;

  static final Map<String, CmsClient> _pool = <String, CmsClient>{};

  /// 按地址取实例（同址共用分类 / 详情缓存）。
  static CmsClient of(String api) {
    final key = api.trim();
    final hit = _pool[key];
    if (hit != null) return hit;
    final made = CmsClient(key);
    _pool[key] = made;
    return made;
  }

  static void clearPool() {
    _pool.clear();
  }

  final List<SourceClass> _classes = <SourceClass>[];
  bool _classesLoaded = false;
  Future<List<SourceClass>>? _classing;

  final Map<String, _CachedVod> _details = <String, _CachedVod>{};

  bool get hasClasses => _classesLoaded && _classes.isNotEmpty;

  /* ------------------------------------------------------------ 请求 */

  Uri _uri(Map<String, String> query) {
    var text = api.trim();
    if (text.isEmpty) throw ApiException('片源地址为空');
    if (!text.contains('?')) {
      if (!text.endsWith('/')) text = '$text/';
    }
    final base = Uri.parse(text);
    return base.replace(
      queryParameters: <String, String>{
        ...base.queryParameters,
        'at': 'json',
        ...query,
      },
    );
  }

  Future<Map<String, dynamic>> _fetch(Map<String, String> query) async {
    final uri = _uri(query);
    try {
      final r = await http
          .get(uri, headers: const <String, String>{'accept': '*/*'})
          .timeout(timeout);
      if (r.statusCode >= 400) throw ApiException.server(r.statusCode);
      final body = jsonDecode(utf8.decode(r.bodyBytes, allowMalformed: true));
      if (body is! Map) {
        throw ApiException('片源返回的数据格式不对', kind: ApiErrorKind.server);
      }
      final map = Map<String, dynamic>.from(body);
      final code = map['code'];
      final ok = code == null || code == 1 || code == '1';
      if (!ok && map['list'] is! List) {
        final msg = _text(map['msg']);
        throw ApiException(msg.isEmpty ? '片源接口请求失败' : msg);
      }
      return map;
    } on TimeoutException {
      throw ApiException.timeout();
    } on FormatException {
      throw ApiException('片源返回的数据无法解析', kind: ApiErrorKind.server);
    } on http.ClientException {
      throw ApiException.network();
    }
  }

  /* ------------------------------------------------------------ 列表 */

  Future<List<VideoCard>> list({int type = 0, int page = 1}) async {
    final map = await _fetch(<String, String>{
      'ac': 'list',
      if (type > 0) 't': '$type',
      'pg': '$page',
    });
    return _cards(map);
  }

  Future<List<VideoCard>> search(String keyword, int page) async {
    final q = keyword.trim();
    if (q.isEmpty) return const <VideoCard>[];
    final map = await _fetch(<String, String>{
      'ac': 'detail',
      'wd': q,
      'pg': '$page',
    });
    return _cards(map);
  }

  List<VideoCard> _cards(Map<String, dynamic> map) {
    final raw = map['list'];
    if (raw is! List) return const <VideoCard>[];
    final out = <VideoCard>[];
    final seen = <String>{};
    for (final e in raw) {
      if (e is! Map) continue;
      final vod = Map<String, dynamic>.from(e);
      final card = CmsApi.cardOf(vod);
      if (card.id.trim().isEmpty || card.title.trim().isEmpty) continue;
      if (!seen.add('${card.id}')) continue;
      out.add(card);
    }
    return out;
  }

  /* ------------------------------------------------------------ 分类 */

  /// 源自己的栏目列表：先拉一次并缓存（[fresh] 强制重拉）。
  ///
  /// 拿不到不抛错：分类只是「能不能按分类浏览」的问题，
  /// 抛出去会让整页变成错误态，而搜索 / 详情其实还能用。
  Future<List<SourceClass>> classes({bool fresh = false}) async {
    if (!fresh && _classesLoaded) return _classes;
    final running = _classing;
    if (running != null) return running;
    final task = _loadClasses();
    _classing = task;
    try {
      return await task;
    } finally {
      _classing = null;
    }
  }

  Future<List<SourceClass>> _loadClasses() async {
    try {
      final map = await _fetch(const <String, String>{'ac': 'list'});
      final raw = map['class'];
      final list = raw is List ? raw : const <Object?>[];
      final out = <SourceClass>[];
      for (final e in list) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        final id = _int(m['type_id']);
        final name = _text(m['type_name']);
        if (id <= 0 || name.isEmpty) continue;
        out.add(SourceClass(id, name));
      }
      if (out.isNotEmpty) {
        _classes
          ..clear()
          ..addAll(out);
        _classesLoaded = true;
      }
    } catch (_) {
      // 分类拉不到：保持空表，下次再试。
    }
    _classesLoaded = true;
    return _classes;
  }

  /// 我们的分类键 → 这个源的 type_id（映射不上返回 0）。
  int typeIdOfChannel(String channelKey) {
    final want = channelKey.trim();
    if (want.isEmpty) return 0;
    for (final item in _classes) {
      if (channelKeyOfClassName(item.name) == want) return item.id;
    }
    return 0;
  }

  /* ------------------------------------------------------------ 详情 / 播放 */

  Future<Map<String, dynamic>> _vod(String id) async {
    final key = id.trim();
    if (key.isEmpty) throw ApiException('缺少影片 id');
    final hit = _details.remove(key);
    if (hit != null) {
      // 命中后移到队尾，保持「最近用过的留下」。
      _details[key] = hit;
      return hit.vod;
    }
    final map = await _fetch(<String, String>{'ac': 'detail', 'ids': key});
    final raw = map['list'];
    if (raw is! List || raw.isEmpty || raw.first is! Map) {
      throw ApiException('片源里没有这部影片');
    }
    final vod = Map<String, dynamic>.from(raw.first as Map);
    _details[key] = _CachedVod(vod);
    while (_details.length > detailCacheLimit) {
      _details.remove(_details.keys.first);
    }
    return vod;
  }

  Future<VideoDetail> detail(String id) async {
    final vod = await _vod(id);
    return CmsApi.detailOf(vod, CmsApi.linesOf(vod));
  }

  /// 播放：从本源的 `vod_play_url` 取地址（复用 cms_source.dart 的解析）。
  ///
  /// 真 m3u8 / mp4 直链直接用；令牌 / 平台页面这类需要 hxparse 的地址
  /// 只认主站那套解析器，跨源解析会把主站的账号体系带串，所以这里明确
  /// 提示「换主站线路播放」，而不是悄悄播错。
  Future<PlayInfo> play(String vodId, String line, int ep) async {
    final vod = await _vod(vodId);
    final lines = CmsApi.linesOf(vod);
    if (lines.isEmpty) throw ApiException('该影片暂无播放地址');
    final target = findLine(lines, line) ?? lines.first;
    if (target.count == 0) throw ApiException('该线路没有可用播放地址');
    final index = ep < 1 ? 1 : (ep > target.count ? target.count : ep);
    final address = target.urlAt(index);
    if (address == null || address.trim().isEmpty) {
      throw ApiException('该线路没有可用播放地址');
    }
    if (!isMediaUrl(address)) {
      throw ApiException('这条线路需要解析，请换本站采集库线路播放');
    }
    final lower = address.toLowerCase();
    return PlayInfo(
      url: address,
      type: lower.contains('.m3u8') ? 'hls' : 'mp4',
      quality: const <QualityItem>[],
      backup: const <String>[],
      headers: const <String, String>{},
      parsePage: '',
      lineName: target.info.displayName,
      direct: true,
    );
  }

  /* ------------------------------------------------------------ 小工具 */

  static String _text(Object? raw) {
    if (raw == null) return '';
    return raw.toString().trim();
  }

  static int _int(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse(_text(raw)) ?? 0;
  }
}

class _CachedVod {
  _CachedVod(this.vod);

  final Map<String, dynamic> vod;
}

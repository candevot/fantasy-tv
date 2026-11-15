import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api.dart';
import '../models.dart';
import 'cms_api.dart';
import 'cms_request.dart';
import 'cms_source.dart';
import 'parse_registry.dart';
import 'tvbox_config.dart';

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
  ///
  /// PROTOCOL_FACE（2026-11-15 · 第 3 条）：站点自己配了 `timeout` 时用它的
  /// （见 [CmsSiteProfile.timeout]）。壳那边单源超时是 `Site.getTimeout()`
  /// （默认 15 秒，可 1..N 秒），我们原来是全局 12 秒一刀切 —— 慢源被误杀。
  static const Duration timeout = Duration(seconds: 8);

  /* ------------------------------------------------------ 站点级画像 */

  /// 地址 → 站点画像（`header` / `ext` / `timeout` / `playUrl`）。
  ///
  /// 为什么按地址存而不是把站点对象传进来：调用方有四处（搜索 / 分类 /
  /// 详情 / 播放），其中详情和播放走的是 `cms_bridge.dart`，那里手里只有
  /// 「源地址」；让每个调用点都记得带画像，迟早会漏一处 —— 漏了就是
  /// 「要 Referer 的源 403」「慢源被误杀」这类只在真机上才看得见的问题。
  static final Map<String, CmsSiteProfile> _profiles =
      <String, CmsSiteProfile>{};

  /// 安装一批站点画像（配置解析完 / 源列表变更时调一次）。
  static void installProfiles(Map<String, CmsSiteProfile> profiles) {
    _profiles
      ..clear()
      ..addAll(profiles);
  }

  /// 取某个地址的画像（没有就是「无站点级配置」）。
  static CmsSiteProfile profileOf(String api) =>
      _profiles[api.trim()] ?? CmsSiteProfile.empty;

  /// 单测用：清空画像。
  static void resetProfilesForTest() => _profiles.clear();

  CmsSiteProfile get profile => profileOf(api);

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

  /// 组装这次请求（`ac=` / `extend` / GET-or-POST 全在 [CmsRequest] 里）。
  ///
  /// PROTOCOL_FACE（2026-11-15 · 第 7 条）：壳是
  /// `site.ext.length() <= 1000 ? GET : POST(表单)`，且 `ac` 只有
  /// `videolist` / `detail` 两个取值 —— 见 `cms_request.dart`。
  CmsRequest _request(CmsCall call, Map<String, String> params) {
    if (api.trim().isEmpty) throw ApiException('片源地址为空');
    final site = profile;
    return CmsRequest.build(
      api: api,
      params: <String, String>{
        'at': 'json',
        'ac': CmsRequest.acFor(call, directKind: site.directKind),
        ...params,
      },
      profile: site,
    );
  }

  /// 这个源实际该等多久：站点级 `timeout` 优先。
  Duration get effectiveTimeout => profile.timeout ?? timeout;

  Future<Map<String, dynamic>> _fetch(
    CmsCall call,
    Map<String, String> params,
  ) async {
    final request = _request(call, params);
    final uri = request.uri;
    try {
      final r = request.isPost
          ? await http
              .post(uri, headers: request.header, body: request.body)
              .timeout(effectiveTimeout)
          : await http
              .get(uri, headers: request.header)
              .timeout(effectiveTimeout);
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
    final map = await _fetch(CmsCall.categoryList, <String, String>{
      if (type > 0) 't': '$type',
      'pg': '$page',
    });
    return _cards(map);
  }

  /// 搜索：参数就是壳 `SearchTask` 那一套（`wd` + `quick` + `extend` + `pg`）。
  Future<List<VideoCard>> search(String keyword, int page) async {
    final q = keyword.trim();
    if (q.isEmpty) return const <VideoCard>[];
    final map = await _fetch(CmsCall.search, <String, String>{
      'wd': q,
      if (profile.quickSearch) 'quick': 'true',
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
      final map = await _fetch(CmsCall.classes, const <String, String>{});
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
    final map = await _fetch(CmsCall.detail, <String, String>{'ids': key});
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
  /// PARSE_REGISTRY（2026-11-15 · 移植阶段 1 第 2 条）：**不再硬报错**。
  ///
  /// 以前这里是 `if (!isMediaUrl(address)) throw '这条线路需要解析，请换本站
  /// 采集库线路播放'` —— 外部 CMS 里凡是解析线路（壳那边交给解析器出地址的
  /// 那些）在我们这儿整批作废。现在按壳的寻址协议走（`ParseJob.setParse()`）：
  ///
  ///   1. 直链（含 `rules` 嗅探命中）→ 原样返回，与改造前一致；
  ///   2. 站点级 `playUrl`（`parse:名字` / `json:地址`）→ 优先；
  ///   3. 地址本身带 `json:` / `parse:` 前缀 → 按前缀寻址；
  ///   4. 其余 → 默认解析器（`parses[0]`）。
  ///
  /// 能真正执行的形态：`json`（type 1，拿 `{url: "…"}`）与 `sniff`（type 0 的
  /// HTTP 版，从页面里抠视频地址）。type 2/3/4 依赖壳自己的 loader，
  /// 本阶段**明确报「暂不支持」并带上解析器名字** —— 报错也要能看出换哪个。
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
    final direct = isMediaUrl(address);
    final site = profile;
    final route = ParseRegistry.active.route(
      address,
      sitePlayUrl: site.playUrl,
      header: site.header,
      click: site.click,
      isDirect: (a) => direct,
    );
    var resolved = address;
    if (route.needsParse) {
      resolved = await _resolveByRoute(route, address);
    }
    final lower = resolved.toLowerCase();
    return PlayInfo(
      url: resolved,
      type: lower.contains('.m3u8') ? 'hls' : 'mp4',
      quality: const <QualityItem>[],
      backup: const <String>[],
      headers: route.needsParse ? route.header : site.header,
      parsePage: '',
      lineName: target.info.displayName,
      direct: true,
    );
  }

  /// 按路由执行一次解析，返回可直接播放的地址。
  ///
  /// 两种执行形态（都不需要 WebView）：
  ///   · [FxParseKind.json]：`url + 播放地址` → `{url: "…"}`；
  ///   · [FxParseKind.sniff]：取页面 → 从 HTML / JSON 里抠第一个媒体地址。
  ///
  /// WebView 嗅探（壳 `ParseJob.startWeb`）属于后续阶段，这里只做 HTTP 层，
  /// 抠不到就报「解析器没给出地址」，不假装成功。
  Future<String> _resolveByRoute(ParseRoute route, String address) async {
    final name = route.name.trim();
    final label = name.isEmpty ? '默认解析器' : '解析器「$name」';
    if (route.kind == FxParseKind.unsupported) {
      throw ApiException(
        '这条线路要$label（type ${route.type}）解析，当前版本还不支持，换一条线路试试',
      );
    }
    final requestUrl = route.requestUrlFor(address);
    final uri = Uri.tryParse(requestUrl);
    if (uri == null || !uri.hasScheme) {
      throw ApiException('$label 的地址不合法：$requestUrl');
    }
    String body;
    try {
      final r = await http
          .get(uri, headers: <String, String>{
            'accept': '*/*',
            'user-agent': _defaultParseUa,
            ...route.header,
          })
          .timeout(_parseTimeout);
      if (r.statusCode >= 400) throw ApiException.server(r.statusCode);
      body = utf8.decode(r.bodyBytes, allowMalformed: true);
    } on TimeoutException {
      throw ApiException.timeout();
    } on http.ClientException {
      throw ApiException.network();
    }
    if (route.kind == FxParseKind.json) {
      final url = _jsonUrlOf(body);
      if (url.isEmpty) throw ApiException('$label 没有返回播放地址');
      return _absolute(uri, url);
    }
    // sniff：从页面里找第一个像媒体地址的串（相对地址按页面地址补全）。
    final hit = _firstMediaUrl(body);
    if (hit.isEmpty) throw ApiException('$label 没在页面里找到播放地址');
    return _absolute(uri, hit);
  }

  /// 解析器请求的默认超时（站点级 timeout 优先）。
  static const Duration _parseFallbackTimeout = Duration(seconds: 10);

  Duration get _parseTimeout => profile.timeout ?? _parseFallbackTimeout;

  /// 解析器的默认 UA（壳 `Parse` 用的是整套 WebView UA）。
  static const String _defaultParseUa =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Version/4.0 Chrome/116.0.0.0 Mobile Safari/537.36';

  /// 从解析器返回的 JSON 里取播放地址（`url`，其次 `data.url`）。
  static String _jsonUrlOf(String body) {
    Object? raw;
    try {
      raw = jsonDecode(body);
    } catch (_) {
      // 有的解析器给的是 JSONP / 前后带杂字符，抠第一个 `{…}` 再试一次。
      final start = body.indexOf('{');
      final end = body.lastIndexOf('}');
      if (start < 0 || end <= start) return '';
      try {
        raw = jsonDecode(body.substring(start, end + 1));
      } catch (_) {
        return '';
      }
    }
    if (raw is! Map) return '';
    final direct = raw['url'];
    if (direct is String && direct.trim().isNotEmpty) return direct.trim();
    final data = raw['data'];
    if (data is Map) {
      final inner = data['url'];
      if (inner is String && inner.trim().isNotEmpty) return inner.trim();
    }
    return '';
  }

  /// 从页面文本里抠第一个媒体地址（跳过落在 `ads` 广告域上的候选）。
  ///
  /// 广告域名表来自配置的 `ads`（壳同名字段）：解析页里常常同时埋着正片和
  /// 广告片的地址，取第一个就可能取到广告 —— 用户看到的是「播的不是这一集」。
  static String _firstMediaUrl(String body) {
    final pattern = RegExp(
      r'''(?:https?:)?//[^"'\s\\]{10,}?\.(?:m3u8|mp4|flv|mkv)(?:\?[^"'\s\\]*)?''',
      caseSensitive: false,
    );
    final ads = FxAds.active;
    for (final match in pattern.allMatches(body)) {
      final url = match.group(0)?.trim() ?? '';
      if (url.isEmpty) continue;
      if (ads.matches(url)) continue;
      return url;
    }
    return '';
  }

  /// 解析器给的地址可能是相对的（`//cdn…` / `/path/x.m3u8`），按页面地址补全。
  static String _absolute(Uri base, String url) {
    final text = url.trim();
    if (text.isEmpty) return text;
    final parsed = Uri.tryParse(text);
    if (parsed != null && parsed.hasScheme) return text;
    if (text.startsWith('//')) return '${base.scheme}:$text';
    return base.resolveUri(parsed ?? Uri(path: text)).toString();
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

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api.dart';
import '../models.dart';
import 'cms_source.dart';

/// 苹果CMS（maccms10）数据层 —— CMS_LAYER（2026-11-14 第一阶段）。
///
/// 目标：内容数据源从「我们自己的 /api」切到站点自带的
/// `/api.php/provide/vod/`，**对外仍然只产出 models.dart 里那几个模型**
/// （VideoCard / VideoDetail / LineInfo / Episode / PlayInfo），
/// 模型定义一个字都不动，UI 也不用改。
///
/// 三层结构：
///   1. 请求：[_vod] 统一超时 / 重试 / 编码兜底，四种接口只差一组查询参数
///   2. 转换：[cardJson] / [detailJson] 先把 CMS 字段翻成**老接口的 JSON 形状**，
///      再交给 `VideoCard.fromJson` / `VideoDetail.fromJson` —— 评分区间、
///      年份上限、HTML 清洗、同名线路合并这些既有规则全部复用，不重写一遍
///   3. 兜底：列表 / 搜索 / 分类失败时回落旧的 [Api]（弱网不至于整页空白）；
///      详情 / 播放**不回落**，因为旧接口的影片 id 和 CMS 的 vod_id 是两套
///      完全不同的编号，回落会拿错片子，宁可报错让用户重试
///
/// 播放地址：
///   · 真 m3u8 直链（有的采集源直接给）：直接用，不解析
///   · 令牌 / 页面地址（`幻想4K` 的 `FY-SH4K-<md5>`、`量子` 的 `/share/<md5>`）：
///     现场调 hxparse 换直链，失败提示「该线路解析失败」，不崩
///   · `幻想爱奇艺`：不来自采集，没有集地址，按「剧名 + 年份 + 第几集」现查
class CmsApi {
  /* ------------------------------------------------------------ 地址 */

  /// 站点根（后台 `http://125.94.244.87/admin.php`）。
  /// 换服务器时可以用 `--dart-define=CMS_ROOT=…` 覆盖，不用改代码。
  static const String root = String.fromEnvironment(
    'CMS_ROOT',
    defaultValue: 'http://125.94.244.87',
  );

  static const String vodPath = '/api.php/provide/vod/';

  /// 解析服务根：默认和站点同一个 host（nginx 反代到 hxparse 服务）。
  static const String parseRoot = String.fromEnvironment(
    'CMS_PARSE',
    defaultValue: root,
  );

  /// 解析用的分类路径（`fuying` / `iqiyi` 挂在这里）。
  ///
  /// 站点实测是 `/hxparse/parse/fuying`；文档写的是 `/hxparse/fuying`，
  /// 两套都在线上的可能性不小，所以 [_resolve] 按顺序都试一遍。
  static const String parsePath = '/hxparse/parse';

  static const String parsePathShort = '/hxparse';

  /// 接口超时：CMS 是本机同机房，8 秒足够；失败最多重试 1 次。
  static const Duration timeout = Duration(seconds: 8);

  /// 解析服务要现抓上游，给足 15 秒。
  static const Duration parseTimeout = Duration(seconds: 15);

  /// CMS 出错时是否回落旧接口。
  ///
  /// 只作用于 [list] / [search] / [categories]：这三处的数据语义两边一致，
  /// 回落只是换了数据源，不会让用户看到别的片子。
  static bool fallback = true;

  /* ------------------------------------------------------------ 分类 */

  /// 固定分类（CMS 后台建的那 8 个栏目）：首页导航 / 分类页复用这套。
  static const List<CmsCategory> nav = <CmsCategory>[
    CmsCategory(1, '电影'),
    CmsCategory(2, '电视剧'),
    CmsCategory(3, '动漫'),
    CmsCategory(4, '综艺'),
    CmsCategory(5, '短剧'),
    CmsCategory(6, '少儿'),
    CmsCategory(7, '直播'),
    CmsCategory(9, '其他'),
  ];

  /// 老接口的分类键 / 中文名 → CMS 的 type_id。
  static const Map<String, int> _typeAlias = <String, int>{
    'movie': 1,
    'film': 1,
    '电影': 1,
    'tv': 2,
    'juji': 2,
    'drama': 2,
    'series': 2,
    '电视剧': 2,
    '剧集': 2,
    'anime': 3,
    'manhua': 3,
    'dongman': 3,
    '动漫': 3,
    '动画': 3,
    'zongyi': 4,
    'variety': 4,
    '综艺': 4,
    'duanju': 5,
    'short': 5,
    '短剧': 5,
    'kids': 6,
    'child': 6,
    '少儿': 6,
    '儿童': 6,
    'live': 7,
    '直播': 7,
    'other': 9,
    '其他': 9,
  };

  /// 老接口的分类键 ← CMS type_id（回落旧接口时用）。
  static String legacyTypeOf(int typeId) {
    switch (typeId) {
      case 1:
        return 'movie';
      case 2:
        return 'juji';
      case 3:
        return 'manhua';
      case 4:
        return 'zongyi';
      case 5:
        return 'juji';
      case 6:
        return 'manhua';
      case 7:
        return 'live';
      default:
        return '';
    }
  }

  /// 分类 ID：接受 CMS 数字 id、老接口键（movie / juji …）、中文名，
  /// 认不出来返回 0（调用方按「全部」处理）。
  static int typeIdOf(Object? raw) {
    final text = _str(raw);
    if (text.isEmpty) return 0;
    final id = int.tryParse(text);
    if (id != null) return id;
    final alias = _typeAlias[text.toLowerCase()];
    if (alias != null) return alias;
    for (final category in nav) {
      if (category.name == text) return category.id;
    }
    return 0;
  }

  /* ------------------------------------------------------------ 四个接口 */

  /// 列表：`ac=detail&t=<分类id>&pg=<页>`。
  ///
  /// **为什么不是 `ac=list`**：实测本站 `ac=list` 只回 9 个字段
  /// （`vod_id / vod_name / vod_play_from / vod_remarks / vod_time / type_*`），
  /// 没有 `vod_pic / vod_year / vod_area / vod_score / vod_hits / vod_total /
  /// vod_play_url`。后果是一串连锁问题：
  ///   · 卡片的「年份 / 地区 / 评分 / 热度 / 更新至 N 集」全是空的；
  ///   · 分类页的年份筛选（前端过滤）拿不到 `year`，一筛就整页清空。
  /// `ac=detail` 的 `t` + `pg` 是同语义分页（实测 20 条/页、`total` 正常），
  /// 单条 ~2KB、整页 ~41KB，换回上面那些字段是值的。
  static Future<List<VideoCard>> list({
    int type = 0,
    int page = 1,
    String sort = '',
  }) async {
    try {
      final body = await _vod(<String, String>{
        'ac': 'detail',
        if (type > 0) 't': '$type',
        'pg': '$page',
        // HOT_ORDER（2026-11-15）：服务端 `order=` 已经修好且真生效
        // （实测 `order=vod_hits` 是严格递减），所以热播行必须把 `order`
        // 和 `by=desc` 一起带上 —— 只带 order 时后台按升序给「最冷」的那批。
        if (sort.isNotEmpty) ...<String, String>{
          'order': _orderOf(sort),
          'by': 'desc',
        },
      });
      return <VideoCard>[for (final vod in _items(body)) cardOf(vod)];
    } catch (e) {
      final original = e;
      if (fallback) {
        try {
          return await Api.category(
            type: legacyTypeOf(type),
            sort: sort.isEmpty ? 'latest' : sort,
            page: page,
          );
        } catch (_) {
          // 旧接口也不通：抛 CMS 的原始错误，文案更贴近真实原因。
        }
      }
      throw original;
    }
  }

  /// 分类列表（首页横向卡片行 / 分类页用的入口）：`categoryList(typeId, page)`。
  ///
  /// 等价于 [list]，只是把「分类 id + 页码」的调用形态固定下来 ——
  /// 首页每一行、分类页每一页都只传这两个参数，排序统一按更新时间。
  static Future<List<VideoCard>> categoryList(int typeId, int page) =>
      list(type: typeId, page: page);

  /// 搜索：`ac=detail&wd=<关键词>&pg=<页>`。
  ///
  /// 用 detail 而不是 list：搜索面板要显示简介 / 集数，list 给不全这些字段。
  static Future<List<VideoCard>> search(String keyword, int page) async {
    final q = keyword.trim();
    if (q.isEmpty) return const <VideoCard>[];
    try {
      final body = await _vod(<String, String>{
        'ac': 'detail',
        'wd': q,
        'pg': '$page',
      });
      return <VideoCard>[for (final vod in _items(body)) cardOf(vod)];
    } catch (e) {
      final original = e;
      if (fallback) {
        try {
          return await Api.search(q, page);
        } catch (_) {
          // 旧接口也不通：抛 CMS 的原始错误。
        }
      }
      throw original;
    }
  }

  /// 详情：`ac=detail&ids=<vod_id>`。
  ///
  /// [fresh] = true 时跳过本地缓存（下拉刷新、线路变化后重新拉）。
  static Future<VideoDetail> detail(String id, {bool fresh = false}) async {
    final key = id.trim();
    if (key.isEmpty) throw ApiException('缺少影片 id');
    final entry = await _entry(key, fresh: fresh);
    final related = await _relatedCards(entry.vod);
    return detailOf(entry.vod, entry.lines, related: related);
  }

  /// 分类：`ac=list` 的返回里带 class 数组（type_id / type_name / type_pid）。
  ///
  /// 拿不到就用固定的 [nav]，导航不能因为一个接口抖动变空。
  static Future<List<CmsCategory>> categories() async {
    try {
      final body = await _vod(const <String, String>{'ac': 'list'});
      final raw = body['class'];
      final list = raw is List ? raw : const <Object?>[];
      final out = <CmsCategory>[];
      for (final e in list) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        final id = _intOf(m['type_id']);
        final name = _str(m['type_name']);
        // 只取一级栏目：二级分类（type_pid != 0）不上导航。
        if (id <= 0 || name.isEmpty || _intOf(m['type_pid']) != 0) continue;
        out.add(CmsCategory(id, name));
      }
      return out.isEmpty ? nav : out;
    } catch (_) {
      // 分类不是关键路径：失败就用固定那套。
      return nav;
    }
  }

  /* ------------------------------------------------------------ 播放地址 */

  /// 播放：`play(vod_id, 第几集, 线路 id)` → [PlayInfo]。
  ///
  /// 线路 id / 集号都来自本层 [detailOf] / [linesOf] 产出，UI 只管原样回传。
  static Future<PlayInfo> play(String vodId, int ep, String lineId) async {
    final entry = await _entry(vodId);
    final line = findLine(entry.lines, lineId);
    if (line == null) throw ApiException('线路不存在，请刷新后重试');
    return _play(entry, line, ep);
  }

  /// 播放：按**线路名**定位线路（PLAY_LINE_NAME）。
  ///
  /// 播放页 / 一起看存的是线路名而不是内部 id（用户看得到的只有「幻想4K」），
  /// 换设备、换会话后 id 已经对不上；这里按名字找，找不到才退回第一条线路。
  /// [epIndex] 从 1 开始，越界自动夹到首集 / 末集。
  static Future<PlayInfo> playEpisode(
    String vodId,
    String lineName,
    int epIndex,
  ) async {
    final entry = await _entry(vodId);
    if (entry.lines.isEmpty) throw ApiException('该影片暂无播放地址');
    final line = findLine(entry.lines, lineName) ?? entry.lines.first;
    return _play(entry, line, epIndex);
  }

  /// 只要可播地址（给下载 / 外挂播放 / 投屏用），失败照常抛 [ApiException]。
  static Future<String> playUrl(
    String vodId,
    String lineName,
    int epIndex,
  ) async =>
      (await playEpisode(vodId, lineName, epIndex)).url;

  static Future<PlayInfo> _play(_CmsEntry entry, CmsLine line, int ep) async {
    if (line.count == 0) throw ApiException('该线路没有可用播放地址');
    final index = ep < 1 ? 1 : (ep > line.count ? line.count : ep);
    final address = line.urlAt(index);
    if (address == null || address.trim().isEmpty) {
      throw ApiException('该线路没有可用播放地址');
    }
    if (!needsParse(address)) {
      // 真 m3u8 直链：直接用，少一次解析请求。
      return _playInfo(address, line.info.displayName);
    }
    // 令牌 / 页面地址 / 爱奇艺占位：现场找 hxparse 换直链。
    final url = await _resolve(entry, line.info, address, index);
    if (url.isEmpty) throw _parseFailed();
    return _playInfo(url, line.info.displayName);
  }

  /// 福盈解析：把令牌 / 平台页面地址交给解析服务换成 m3u8。
  static Uri fuyingUri(String page, {String base = parsePath}) =>
      Uri.parse('$parseRoot$base/fuying')
          .replace(queryParameters: <String, String>{'u': page});

  /// 爱奇艺解析：服务端按「剧名 + 年份 + 第几集」自己去站内找。
  static Uri iqiyiUri({
    required String title,
    int year = 0,
    int ep = 1,
    String base = parsePath,
  }) =>
      Uri.parse('$parseRoot$base/iqiyi').replace(
        queryParameters: <String, String>{
          'title': title,
          'year': year > 0 ? '$year' : '',
          'ep': ep < 1 ? '1' : '$ep',
        },
      );

  /// 排序键 → 服务端的 `order` 字段名（纯函数，单测直接断言）。
  static String orderOf(String sort) => _orderOf(sort);

  /// 清掉详情缓存（切换站点 / 调试用）。
  static void clearCache() => _cache.clear();

  /// 是否已经解析过这条线路（给「重新解析」按钮判断要不要 warning）。
  static bool isResolved(String vodId) => _cache.containsKey(vodId.trim());

  /* ------------------------------------------------------------ 转换 */

  /// 一条 CMS 记录 → [VideoCard]。
  static VideoCard cardOf(Map<String, dynamic> vod) =>
      VideoCard.fromJson(cardJson(vod));

  /// CMS 记录 → **老接口形状**的卡片 JSON（`VideoCard.fromJson` 直接吃）。
  static Map<String, dynamic> cardJson(Map<String, dynamic> vod) {
    final froms = splitRaw(_str(vod['vod_play_from']), kLineSep);
    // 集数取所有线路的最大值：列表接口经常只把第一块写全，
    // 有的采集源第一块还是空的，按第一块算会把 40 集的剧显示成 0 集。
    var episodes = _intOf(vod['vod_total']);
    for (final block in splitRaw(_str(vod['vod_play_url']), kLineSep)) {
      final n = epPairs(block).length;
      if (n > episodes) episodes = n;
    }
    return <String, dynamic>{
      'id': _str(vod['vod_id']),
      'title': _str(vod['vod_name']),
      'cover': _str(vod['vod_pic']),
      'rating': _str(vod['vod_score']),
      'year': _str(vod['vod_year']),
      'status': _str(vod['vod_remarks']),
      'episodes': episodes,
      'category': _str(vod['type_name']),
      'type': _str(vod['type_name']),
      'area': _str(vod['vod_area']),
      'heat': _heatOf(vod['vod_hits']),
      'time': _str(vod['vod_time']),
      'desc': _descOf(vod),
      'tags': _tagsOf(vod),
      'sourceLabel': froms.isEmpty ? '' : froms.first,
    };
  }

  /// 一条 CMS 记录 → [VideoDetail]（列表页 / 简单场景用，不补相关推荐）。
  static VideoDetail detailOf(
    Map<String, dynamic> vod,
    List<CmsLine> lines, {
    List<VideoCard> related = const <VideoCard>[],
  }) =>
      VideoDetail.fromJson(detailJson(vod, lines, related: related));

  /// CMS 记录 + 解析好的线路 → **老接口形状**的详情 JSON。
  static Map<String, dynamic> detailJson(
    Map<String, dynamic> vod,
    List<CmsLine> lines, {
    List<VideoCard> related = const <VideoCard>[],
  }) {
    final card = cardJson(vod);
    // 集数以最长的那条线路为准（有的线路只更到第 20 集），
    // 集名也取最长那条 —— 否则 40 集的剧会按 20 集的线路列出前 20 集。
    CmsLine? longest;
    for (final line in lines) {
      if (longest == null || line.count > longest.count) longest = line;
    }
    final count = longest?.count ?? 0;
    final primary = longest?.names ?? const <String>[];
    final episodes = <Map<String, dynamic>>[
      for (var i = 0; i < primary.length; i++)
        <String, dynamic>{'n': i + 1, 'name': primary[i], 'duration': 0},
    ];
    final pic = _str(vod['vod_pic']);
    final thumb = _str(vod['vod_pic_thumb']);
    return <String, dynamic>{
      ...card,
      'backdrop': thumb.isEmpty ? pic : thumb,
      // 详情用完整简介，HTML 清洗交给 VideoDetail.fromJson。
      'desc': _str(vod['vod_content']),
      'director': _splitList(vod['vod_director']),
      'cast': _splitList(vod['vod_actor']),
      'episodes': count,
      'lines': <Map<String, dynamic>>[for (final line in lines) lineJson(line)],
      'episodeGroups': <Map<String, dynamic>>[
        <String, dynamic>{'name': '正片', 'episodes': episodes},
      ],
      'related': <Map<String, dynamic>>[for (final c in related) _cardMap(c)],
    };
  }

  /// [CmsLine] → 老接口形状的线路 JSON（`LineInfo.fromJson` 直接吃）。
  static Map<String, dynamic> lineJson(CmsLine line) => <String, dynamic>{
        'id': line.info.id,
        'name': line.info.name,
        'type': line.info.type,
        'priority': line.info.priority,
        'source': line.info.source,
        'from': line.info.from,
        'epnames': line.info.epNames,
        'status': line.info.status,
      };

  /// `vod_play_from` + `vod_play_url` → 线路表（含每条线路自己的集名 / 集地址）。
  ///
  /// 真正的切分与判定在 cms_source.dart（纯函数，可单测）：
  ///   · `幻想4K` 的 `FY-SH4K-<md5>` 令牌 / `量子` 的 `/share/<md5>` 页面 → parse
  ///   · 带媒体后缀的 http(s) 地址 → 直链，不需要解析
  ///   · 只有线路名没有地址块的 `幻想爱奇艺` → 按最长集数补占位集
  static List<CmsLine> linesOf(Map<String, dynamic> vod) => parseLines(vod);

  /* ------------------------------------------------------------ 请求 */

  static Future<Map<String, dynamic>> _vod(Map<String, String> query) async {
    final uri = Uri.parse('$root$vodPath').replace(
      queryParameters: <String, String>{'at': 'json', ...query},
    );
    ApiException? failure;
    for (var attempt = 0; attempt <= 1; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      try {
        final r = await http.get(uri, headers: _acceptJson).timeout(timeout);
        if (r.statusCode >= 500) {
          failure = ApiException.server(r.statusCode);
          continue;
        }
        // CMS 的 json 不保证带 charset，统一按 UTF-8 解，坏字节不抛。
        final body = jsonDecode(utf8.decode(r.bodyBytes, allowMalformed: true));
        if (body is! Map) {
          failure = ApiException('接口返回的数据格式不对', kind: ApiErrorKind.server);
          continue;
        }
        final map = Map<String, dynamic>.from(body);
        final code = map['code'];
        final ok = code == null || code == 1 || code == '1';
        if (!ok && map['list'] is! List) {
          failure = ApiException(
              _str(map['msg']).isEmpty ? '接口请求失败' : _str(map['msg']));
          continue;
        }
        return map;
      } on TimeoutException {
        failure = ApiException.timeout();
      } on FormatException {
        failure = ApiException('接口返回的数据无法解析', kind: ApiErrorKind.server);
      } on http.ClientException {
        failure = ApiException.network();
      } catch (_) {
        failure = ApiException.network();
      }
    }
    throw failure ?? ApiException.network();
  }

  static const Map<String, String> _acceptJson = <String, String>{
    'Accept': 'application/json',
  };

  static const Map<String, String> _acceptAny = <String, String>{
    'Accept': '*/*',
  };

  /// 详情里的记录（`ids=` 只回一条；`wd=` 回一批，取第一条）。
  static Future<Map<String, dynamic>> _detailVod(String id) async {
    final body = await _vod(<String, String>{'ac': 'detail', 'ids': id});
    final items = _items(body);
    if (items.isEmpty) throw ApiException('没有找到这部影片');
    return items.first;
  }

  static List<Map<String, dynamic>> _items(Map<String, dynamic> body) {
    final raw = body['list'];
    if (raw is! List) return const <Map<String, dynamic>>[];
    return <Map<String, dynamic>>[
      for (final e in raw)
        if (e is Map) Map<String, dynamic>.from(e),
    ];
  }

  /// 相关推荐：后台绑了「关联影片」（vod_rel_vod）就用那批 id，
  /// 否则取同分类最新 8 部。取不到返回空 —— 详情页对空 related 整块不渲染。
  static Future<List<VideoCard>> _relatedCards(Map<String, dynamic> vod) async {
    final own = _str(vod['vod_id']);
    try {
      final ids = splitRaw(_str(vod['vod_rel_vod']), ',').take(8).toList();
      if (ids.isNotEmpty) {
        final body =
            await _vod(<String, String>{'ac': 'detail', 'ids': ids.join(',')});
        return <VideoCard>[
          for (final item in _items(body))
            if (_str(item['vod_id']) != own) cardOf(item),
        ];
      }
      final type = _intOf(vod['type_id']);
      if (type <= 0) return const <VideoCard>[];
      final body =
          await _vod(<String, String>{'ac': 'list', 't': '$type', 'pg': '1'});
      return <VideoCard>[
        for (final item in _items(body))
          if (_str(item['vod_id']) != own) cardOf(item),
      ].take(8).toList();
    } catch (_) {
      // 推荐只是锦上添花：接口抖动时详情照常显示。
      return const <VideoCard>[];
    }
  }

  /* ------------------------------------------------------------ 解析服务 */

  /// 需要解析的线路：令牌 / 页面地址 → hxparse → m3u8 直链。
  ///
  /// 解析服务的回包实测是
  /// `{"url":"…m3u8","type":"hls","quality":"","source":"fuying"}`；
  /// 也兼容「m3u8 文本 / 纯链接 / 带链接的 HTML」四种形态，
  /// 认不出来就返回空串，由 [play] 统一报「该线路解析失败」。
  ///
  /// 路径两套都试：站点线上是 `/hxparse/parse/fuying`，
  /// 文档写的是 `/hxparse/fuying`，404 时自动换下一条候选。
  static Future<String> _resolve(
    _CmsEntry entry,
    LineInfo line,
    String page,
    int ep,
  ) async {
    final iqiyi = parseKindOf(line.name, page) == 'iqiyi';
    final bases = <String>[parsePath, parsePathShort];
    Object? lastError;
    for (final base in bases) {
      final uri = iqiyi
          ? iqiyiUri(
              title: entry.title,
              year: entry.year,
              ep: ep,
              base: base,
            )
          : fuyingUri(page, base: base);
      try {
        final r =
            await http.get(uri, headers: _acceptAny).timeout(parseTimeout);
        if (r.statusCode != 200) {
          lastError = _parseFailed();
          continue;
        }
        final text = utf8.decode(r.bodyBytes, allowMalformed: true);
        final url = _extractUrl(text, uri);
        if (url.isNotEmpty) return url;
        lastError = _parseFailed();
      } on TimeoutException {
        lastError = _parseFailed();
      } on http.ClientException {
        lastError = _parseFailed();
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError is ApiException) throw lastError;
    throw _parseFailed();
  }

  /// 解析服务没起 / 上游不可用：统一一条文案，UI 直接展示。
  static ApiException _parseFailed() => ApiException('该线路解析失败');

  static final RegExp _linkRe = RegExp(r'''https?://[^\s"'<>\\]+''');

  static String _extractUrl(String body, Uri request) {
    final text = body.trim();
    if (text.isEmpty) return '';
    if (text.startsWith('{') || text.startsWith('[')) {
      try {
        final found = _findLink(jsonDecode(text));
        if (found.isNotEmpty) return found;
      } on FormatException {
        // 不是合法 JSON：当纯文本继续往下找。
      }
    }
    // 解析服务自己就吐 m3u8 播放列表：请求地址本身就是可播地址。
    if (text.contains('#EXTM3U')) return request.toString();
    final links = <String>[
      for (final m in _linkRe.allMatches(text)) m.group(0)!,
    ];
    for (final link in links) {
      if (link.contains('.m3u8')) return link;
    }
    return links.isEmpty ? '' : links.first;
  }

  static String _findLink(Object? raw) {
    if (raw is String) {
      final s = raw.trim();
      return s.startsWith('http') ? s : '';
    }
    if (raw is List) {
      for (final e in raw) {
        final s = _findLink(e);
        if (s.isNotEmpty) return s;
      }
      return '';
    }
    if (raw is Map) {
      for (final key in const <String>['url', 'm3u8', 'play_url', 'src']) {
        final s = _findLink(raw[key]);
        if (s.isNotEmpty) return s;
      }
      for (final v in raw.values) {
        final s = _findLink(v);
        if (s.isNotEmpty) return s;
      }
    }
    return '';
  }

  static PlayInfo _playInfo(String url, String lineName) =>
      PlayInfo.fromJson(<String, dynamic>{
        'url': url,
        'type': 'hls',
        'lineName': lineName,
        'direct': true,
        'headers': const <String, dynamic>{
          'User-Agent': kDefaultVideoUserAgent,
        },
      });

  /* ------------------------------------------------------------ 缓存 */

  static final Map<String, _CmsEntry> _cache = <String, _CmsEntry>{};

  static const int _cacheLimit = 12;

  /// 详情按 vod_id 缓存：播放时线路地址只在详情里给，命中缓存就不重复请求。
  static Future<_CmsEntry> _entry(String vodId, {bool fresh = false}) async {
    final key = vodId.trim();
    if (key.isEmpty) throw ApiException('缺少影片 id');
    final hit = _cache[key];
    if (hit != null && !fresh) return hit;
    final vod = await _detailVod(key);
    final entry = _CmsEntry(vod, linesOf(vod));
    if (_cache.length >= _cacheLimit) _cache.remove(_cache.keys.first);
    _cache[key] = entry;
    return entry;
  }
}

/// 苹果CMS 的栏目（后台「视频 → 分类」里的一条）。
class CmsCategory {
  const CmsCategory(this.id, this.name);

  final int id;
  final String name;

  @override
  String toString() => '$id:$name';
}

class _CmsEntry {
  _CmsEntry(this.vod, this.lines);

  final Map<String, dynamic> vod;
  final List<CmsLine> lines;

  String get title => _str(vod['vod_name']);

  int get year => _intOf(vod['vod_year']);
}

/* -------------------------------------------------------------- 取值 */

String _str(Object? raw) {
  if (raw == null) return '';
  if (raw is String) return raw.trim();
  return '$raw'.trim();
}

int _intOf(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(_str(raw)) ?? 0;
}

/// 逗号 / 顿号 / 斜杠 / 分号分隔的字段（演员、导演、标签）拆成列表。
List<String> _splitList(Object? raw) {
  final text = _str(raw);
  if (text.isEmpty) return const <String>[];
  return <String>[
    for (final part in text.split(RegExp(r'[,，、/;；|]')))
      if (part.trim().isNotEmpty) part.trim(),
  ];
}

/// 卡片简介：短简介优先，没有再退回完整简介。
String _descOf(Map<String, dynamic> vod) {
  final blurb = _str(vod['vod_blurb']);
  return blurb.isNotEmpty ? blurb : _str(vod['vod_content']);
}

/// 卡片 → 老接口形状的 JSON（相关推荐要再交给 VideoCard.fromJson 过一遍）。
Map<String, dynamic> _cardMap(VideoCard card) => <String, dynamic>{
      'id': card.id,
      'title': card.title,
      'cover': card.cover,
      'rating': card.rating,
      'year': card.year,
      'status': card.status,
      'episodes': card.episodes,
      'category': card.category,
      'type': card.type,
      'area': card.area,
      'heat': card.heat,
      'desc': card.desc,
      'time': card.time,
      'tags': card.tags,
      'sourceLabel': card.sourceLabel,
    };

List<String> _tagsOf(Map<String, dynamic> vod) {
  final out = <String>[];
  for (final raw in <Object?>[vod['vod_class'], vod['vod_tag']]) {
    for (final tag in _splitList(raw)) {
      if (!out.contains(tag)) out.add(tag);
    }
  }
  return out;
}

/// 热度文案：1.2万 / 9500；没有点击量就不显示（返回空串）。
String _heatOf(Object? raw) {
  final hits = _intOf(raw);
  if (hits <= 0) return '';
  if (hits < 10000) return '$hits';
  final wan = hits / 10000;
  final text = wan >= 100 ? wan.toStringAsFixed(0) : wan.toStringAsFixed(1);
  final trimmed =
      text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  return '$trimmed万';
}

/// 分类排序键 → CMS 的 order 字段。
///
/// HOT_ORDER（2026-11-15）：`hot` / `hits` → `vod_hits`。服务端 `Provide.php`
/// 已经修好、`order=vod_hits&by=desc` 实测严格递减，所以首页与榜单现在真的
/// 按热播排，不再是「按入库时间」。
String _orderOf(String sort) {
  switch (sort.toLowerCase()) {
    case 'rating':
    case 'score':
      return 'vod_score';
    case 'hot':
    case 'hits':
      return 'vod_hits';
    default:
      return 'vod_time';
  }
}

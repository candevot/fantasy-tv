import '../api.dart';
import '../models.dart';
import 'cms_api.dart';
import 'cms_client.dart';
import 'source_hub.dart';

/// CMS 数据层 ↔ 现有 UI 的接线层（CMS_WIRING，2026-11-14）。
///
/// 上层（首页 / 分类 / 搜索 / 排行 / 详情 / 播放）只跟这一层打交道，
/// 拿到的仍然是 models.dart 里的 [HomeData] / [VideoCard] / [VideoDetail] /
/// [PlayInfo]，所以页面组件一行都不用改。
///
/// 三件事：
///   1. **翻译**：`CmsApi` 的 `type_id` ↔ 页面用的频道键；分类列表 → 首页分区行
///   2. **兜底**：列表 / 搜索 / 排行 / 分类失败或空结果回落旧的 [Api]，
///      弱网不会白屏。为了让「哪条数据来自哪一边」说得清，这里把数据层自带的
///      回落关掉（[CmsApi.fallback]），回落统一由本层决定 —— 否则旧接口返回的
///      id 会被当成 CMS 的 vod_id，点进详情会拿到另一部片子。
///   3. **编号记账**：CMS 的 `vod_id` 和旧接口的影片 id 是两套完全不同的编号。
///      列表 / 搜索 / 排行 / 详情拿到的 id 都记一笔来源，详情和播放按来源路由；
///      没见过的 id 默认先当 CMS（迁移后新内容都是 CMS），失败才试旧接口。
///
/// 采集线路（`幻想4K` / `量子` / `幻想爱奇艺`）的解析状态由
/// cms_source.dart 的 `needsParse` 判定，播放时现场走 hxparse；
/// 失败抛「该线路解析失败」，由详情页提示并留在原线路。
class CmsBridge {
  CmsBridge._();

  /* ------------------------------------------------------------ 频道 */

  /// 首页顶部导航 / 分类入口：推荐 + 六个一级分类。
  ///
  /// 直播是独立入口（底部导航「直播」），这一轮不接 CMS，
  /// 所以不出现在这里 —— 见 [CmsApi.nav] 里 `7:直播` 的说明。
  ///
  /// [CmsChannel.legacy] 是回落旧接口时用的分类键（旧接口只有
  /// movie / juji / manhua / zongyi / live 这一套）。
  static const List<CmsChannel> channels = <CmsChannel>[
    CmsChannel('recommend', '推荐', 0, 'recommend'),
    CmsChannel('movie', '电影', 1, 'movie'),
    CmsChannel('tv', '电视剧', 2, 'juji'),
    CmsChannel('anime', '动漫', 3, 'manhua'),
    CmsChannel('zongyi', '综艺', 4, 'zongyi'),
    CmsChannel('duanju', '短剧', 5, 'juji'),
    CmsChannel('kids', '少儿', 6, 'manhua'),
  ];

  /// 「推荐」页要铺的六个分类行（顺序即首页从上到下的顺序）。
  static const List<CmsChannel> _homeRows = <CmsChannel>[
    CmsChannel('movie', '电影', 1, 'movie'),
    CmsChannel('tv', '电视剧', 2, 'juji'),
    CmsChannel('anime', '动漫', 3, 'manhua'),
    CmsChannel('zongyi', '综艺', 4, 'zongyi'),
    CmsChannel('duanju', '短剧', 5, 'juji'),
    CmsChannel('kids', '少儿', 6, 'manhua'),
  ];

  /// 每行最多给 12 条（首页只显示 10 条，多两条留给横滑）。
  static const int _rowCount = 12;

  /// 首页 banner 取推荐页第一组有数据的分类的前 5 条。
  static const int _bannerCount = 5;

  /// 分区标题 → 频道：旧接口的「剧集 / 动画 / 儿童」和 CMS 的
  /// 「电视剧 / 动漫 / 少儿」说的是同一个栏目，都要能认出来。
  static const Map<String, String> _labelAlias = <String, String>{
    '剧集': 'tv',
    '电视剧': 'tv',
    '连续剧': 'tv',
    '电影': 'movie',
    '动漫': 'anime',
    '动画': 'anime',
    '番剧': 'anime',
    '综艺': 'zongyi',
    '短剧': 'duanju',
    '少儿': 'kids',
    '儿童': 'kids',
  };

  /// 按频道键找频道（`movie` / `tv` / `anime` …；也认 CMS 数字 id）。
  static CmsChannel? channelOf(String key) {
    final want = key.trim();
    if (want.isEmpty) return null;
    for (final ch in channels) {
      if (ch.key == want) return ch;
    }
    final typeId = CmsApi.typeIdOf(want);
    if (typeId <= 0) return null;
    for (final ch in channels) {
      if (ch.typeId == typeId) return ch;
    }
    return null;
  }

  /// 按中文标题找频道（首页分区「更多」按钮用：标题是人看的，键不是）。
  static CmsChannel? channelOfLabel(String label) {
    final text = label.trim();
    if (text.isEmpty) return null;
    for (final entry in _labelAlias.entries) {
      if (text.startsWith(entry.key)) return channelOf(entry.value);
    }
    return null;
  }

  /* ------------------------------------------------------------ 首页 */

  /// 首页数据：推荐页按分类铺 6 行，单分类频道只铺这一行。
  ///
  /// 先用第一行探一次接口：接口整体不通时立刻走旧接口兜底，
  /// 不用等六个请求各自超时再失败（那样首屏要空十几秒）。
  static Future<HomeData> home(String channel) async {
    _boot();
    final ch = channelOf(channel);
    final rows =
        (ch == null || ch.typeId <= 0) ? _homeRows : <CmsChannel>[ch];
    final first = await _tryRow(rows.first.typeId);
    if (first == null) return _legacyHome(ch);

    final rest = rows.length <= 1
        ? const <List<VideoCard>?>[]
        : await Future.wait(<Future<List<VideoCard>?>>[
            for (final row in rows.skip(1)) _tryRow(row.typeId),
          ]);
    final lists = <List<VideoCard>?>[first, ...rest];

    final sections = <HomeSection>[];
    for (var i = 0; i < rows.length; i++) {
      final items = lists[i];
      if (items == null || items.isEmpty) continue;
      sections.add(
        HomeSection(rows[i].label, items.take(_rowCount).toList()),
      );
    }
    if (sections.isEmpty) return _legacyHome(ch);

    // banner 用第一条有数据的分类：封面空的片子交给 FxCover 的
    // 首字渐变占位块，不会出现灰块或白屏。
    var bannerSource = const <VideoCard>[];
    for (final list in lists) {
      if (list != null && list.isNotEmpty) {
        bannerSource = list;
        break;
      }
    }
    final banners = <BannerItem>[
      for (final card in bannerSource.take(_bannerCount))
        BannerItem(card.id, card.title, card.cover, card.desc, card.rating),
    ];
    return HomeData(banners, sections);
  }

  /// 取一行；失败返回 null（首页按「这一行没有」处理，不影响其它行）。
  static Future<List<VideoCard>?> _tryRow(int typeId) async {
    try {
      final list = _withoutLive(await CmsApi.categoryList(typeId, 1));
      _markAll(list, _Origin.cms);
      return list;
    } catch (_) {
      return null;
    }
  }

  /// 旧接口兜底：直播有独立入口，首页不铺直播分区（分区名含「直播」或
  /// 卡片本身是直播频道都丢掉）。
  static Future<HomeData> _legacyHome(CmsChannel? ch) async {
    final data = await Api.home(ch?.legacy ?? 'recommend');
    _markAll(<VideoCard>[
      for (final s in data.sections) ...s.items,
    ], _Origin.legacy);
    _markIds(<String>[for (final b in data.banners) b.id], _Origin.legacy);
    final sections = <HomeSection>[];
    for (final section in data.sections) {
      if (section.title.contains('直播')) continue;
      final items = _withoutLive(section.items);
      if (items.isEmpty) continue;
      sections.add(HomeSection(section.title, items));
    }
    return HomeData(data.banners, sections);
  }

  /* ------------------------------------------------------------ 分类页 */

  /// 分类列表：`type` 接受频道键 / CMS 数字 id / 中文名。
  ///
  /// 地区 / 年份是旧接口的服务端筛选，CMS 的 `ac=list` 不支持 ——
  /// 这里按当前页做一次客户端过滤，筛选胶囊不会变成「点了没反应」。
  static Future<List<VideoCard>> category({
    String type = '',
    String area = '',
    String year = '',
    String sort = 'latest',
    int page = 1,
  }) async {
    _boot();
    final typeId = CmsApi.typeIdOf(type);
    // 外部源（云端 / 自加）与主站并行查：外部源内部也是并行的，
    // 这里先发车再等主站，两边的耗时取长的那个，不是相加。
    final extraFuture = SourceHub.instance.categoryAll(type, page);
    List<VideoCard> raw = const <VideoCard>[];
    var ok = false;
    try {
      raw = _withoutLive(await CmsApi.list(
        type: typeId,
        page: page,
        sort: sort,
      ));
      ok = raw.isNotEmpty || page > 1;
      if (ok) _markAll(raw, _Origin.cms);
    } catch (_) {
      ok = false;
    }
    final extra = await _safe(extraFuture);
    if (ok) return _mergeWith(_filter(raw, area: area, year: year), extra);

    List<VideoCard> legacy = const <VideoCard>[];
    try {
      legacy = _withoutLive(await Api.category(
        type: CmsApi.legacyTypeOf(typeId),
        area: area,
        year: year,
        sort: sort,
        page: page,
      ));
      _markAll(legacy, _Origin.legacy);
    } catch (e) {
      // 两边都不通：外部源有结果就先给结果，否则把错误抛给页面。
      if (extra.isNotEmpty) return extra;
      throw e;
    }
    return _mergeWith(legacy, extra);
  }

  static List<VideoCard> _filter(
    List<VideoCard> src, {
    String area = '',
    String year = '',
  }) {
    final wantArea = area.trim();
    final wantYear = year.trim();
    if (wantArea.isEmpty && wantYear.isEmpty) return src;
    return <VideoCard>[
      for (final card in src)
        if ((wantArea.isEmpty || card.area.contains(wantArea)) &&
            (wantYear.isEmpty || '${card.year}' == wantYear))
          card,
    ];
  }

  /* ------------------------------------------------------------ 搜索 */

  static Future<List<VideoCard>> search(String keyword, int page) async {
    _boot();
    final q = keyword.trim();
    if (q.isEmpty) return const <VideoCard>[];
    // 主站采集库 + 所有启用的云端 / 自加源并行查，结果按「片名 + 年份」合并去重。
    final extraFuture = SourceHub.instance.searchAll(q, page);
    List<VideoCard> primary = const <VideoCard>[];
    var primaryOk = false;
    try {
      primary = _withoutLive(await CmsApi.search(q, page));
      primaryOk = primary.isNotEmpty || page > 1;
      if (primaryOk) _markAll(primary, _Origin.cms);
    } catch (_) {
      primaryOk = false;
    }
    final extra = await _safe(extraFuture);
    if (extra.isNotEmpty) return _mergeWith(primary, extra);
    if (primaryOk) return primary;
    // 主站空结果按「这条路走不通」处理：交给旧接口再试一次。
    final legacy = _withoutLive(await Api.search(q, page));
    _markAll(legacy, _Origin.legacy);
    return legacy;
  }

  /// 外部源检索的结果统一带 `云端 / 自加` 标记；只要有多源参与，
  /// 主站采集库的卡片也统一标成 `采集库`，让「这条来自哪个源」一眼可辨。
  static List<VideoCard> _mergeWith(
    List<VideoCard> primary,
    List<VideoCard> extra,
  ) {
    if (extra.isEmpty) return primary;
    final seen = <String>{};
    final out = <VideoCard>[];
    for (final card in primary) {
      if (!seen.add(SourceHub.dedupeKey(card))) continue;
      out.add(SourceHub.relabel(card, label: '采集库'));
    }
    for (final card in extra) {
      if (!seen.add(SourceHub.dedupeKey(card))) continue;
      out.add(card);
    }
    return out;
  }

  /// 直播内容不进搜索 / 分类 / 排行（直播有独立入口）。
  static List<VideoCard> _withoutLive(List<VideoCard> list) {
    var clean = true;
    for (final card in list) {
      if (SourceHub.isLiveCard(card)) {
        clean = false;
        break;
      }
    }
    if (clean) return list;
    return <VideoCard>[
      for (final card in list)
        if (!SourceHub.isLiveCard(card)) card,
    ];
  }

  /// 外部源失败不能拖垮整页：当作「这个源没结果」。
  static Future<List<VideoCard>> _safe(
    Future<List<VideoCard>> task,
  ) async {
    try {
      return await task;
    } catch (_) {
      return const <VideoCard>[];
    }
  }

  /// 热搜词：CMS 按点击量排的片名；拿不到再用旧接口的日榜。
  static Future<List<String>> hotWords({int limit = 12}) async {
    _boot();
    final out = <String>[];
    void take(List<VideoCard> list) {
      for (final card in list) {
        final title = card.title.trim();
        if (title.isEmpty || out.contains(title)) continue;
        out.add(title);
        if (out.length >= limit) return;
      }
    }

    try {
      final list = await CmsApi.list(sort: 'hot');
      _markAll(list, _Origin.cms);
      take(list);
    } catch (_) {
      // 下面回落旧接口。
    }
    if (out.isNotEmpty) return out;
    final legacy = await Api.rank('hot');
    _markAll(legacy, _Origin.legacy);
    take(legacy);
    return out;
  }

  /* ------------------------------------------------------------ 排行榜 */

  /// 榜单：CMS 按点击量排（`order=vod_hits`），失败回落旧的榜单接口。
  static Future<List<VideoCard>> rank(String type) async {
    _boot();
    final typeId = CmsApi.typeIdOf(type);
    try {
      final list = _withoutLive(await CmsApi.list(type: typeId, sort: 'hot'));
      if (list.isNotEmpty) {
        _markAll(list, _Origin.cms);
        return list;
      }
    } catch (_) {
      // 下面回落。
    }
    final legacy = _withoutLive(await Api.rank(type));
    _markAll(legacy, _Origin.legacy);
    return legacy;
  }

  /* ------------------------------------------------------------ 详情 */

  /// 详情：CMS `ac=detail&ids=<vod_id>` → [VideoDetail]（线路 / 选集 / 剧集
  /// 判断全部沿用 models.dart 的既有规则）。
  ///
  /// 已知来自旧接口的 id 直接走旧接口；来源未知的 id 先试 CMS，
  /// 失败再试旧接口 —— 两套编号不通用，所以不做「无脑互换」。
  static Future<VideoDetail> detail(String id) async {
    _boot();
    final external = await _externalSource(id);
    if (external != null) {
      final detail = await CmsClient.of(external.api).detail(
        SourceHub.rawIdOf(id),
      );
      _mark(id, _Origin.cms);
      return detail;
    }
    final origin = _originOf(id);
    if (origin == _Origin.legacy) return _legacyDetail(id);
    try {
      final detail = await CmsApi.detail(id);
      _mark(id, _Origin.cms);
      return detail;
    } catch (_) {
      if (origin == _Origin.unknown) {
        try {
          return await _legacyDetail(id);
        } catch (_) {
          // 旧接口也没有：把 CMS 的错误抛给页面（文案更贴近真实原因）。
        }
      }
      rethrow;
    }
  }

  static Future<VideoDetail> _legacyDetail(String id) async {
    final detail = await Api.detail(id);
    _mark(id, _Origin.legacy);
    return detail;
  }

  /* ------------------------------------------------------------ 播放 */

  /// 播放地址：CMS 影片走 `cms_api` 的 playEpisode（线路名 / 线路 id 都认，
  /// 需要解析的线路现场调 hxparse），失败抛「该线路解析失败」。
  ///
  /// [fresh] 只对旧接口有意义（平台线路签名要绕过服务端缓存）；
  /// CMS 的令牌线路每次解析都是新地址，不依赖这个参数。
  static Future<PlayInfo> play(
    String vodId,
    int ep,
    String line, {
    bool fresh = false,
  }) async {
    _boot();
    final external = await _externalSource(vodId);
    if (external != null) {
      final info = await CmsClient.of(external.api).play(
        SourceHub.rawIdOf(vodId),
        line,
        ep,
      );
      _mark(vodId, _Origin.cms);
      return info;
    }
    final origin = _originOf(vodId);
    if (origin == _Origin.legacy) return Api.play(vodId, ep, line, fresh: fresh);
    try {
      final info = await CmsApi.playEpisode(vodId, line, ep);
      _mark(vodId, _Origin.cms);
      return info;
    } catch (_) {
      if (origin == _Origin.unknown) {
        try {
          final info = await Api.play(vodId, ep, line, fresh: fresh);
          _mark(vodId, _Origin.legacy);
          return info;
        } catch (_) {
          // 旧接口也没有：抛 CMS 的错误。
        }
      }
      rethrow;
    }
  }

  /// 只要直链（下载 / 投屏 / 外挂播放）。
  static Future<String> playUrl(String vodId, String line, int ep) async {
    final external = await _externalSource(vodId);
    if (external != null) {
      final info = await CmsClient.of(external.api).play(
        SourceHub.rawIdOf(vodId),
        line,
        ep,
      );
      return info.url;
    }
    return CmsApi.playUrl(vodId, line, ep);
  }

  /// 这个 id 是不是 CMS 的 `vod_id`（详情页据此跳过旧接口的平台线路逻辑）。
  ///
  /// 外部源（云端 / 自加）的卡片 id 带 `@src:` 前缀，同样按 CMS 处理，
  /// 否则详情页会为它去查旧接口的平台线路。
  static bool isCms(String id) =>
      id.trim().startsWith(SourceHub.idMark) || _originOf(id) == _Origin.cms;

  /// 带 `@src:` 前缀的 id → 它所属的源；不是外部 id 返回 null。
  static Future<KSource?> _externalSource(String id) async {
    if (!id.trim().startsWith(SourceHub.idMark)) return null;
    await SourceHub.instance.ensureReady();
    return SourceHub.instance.decodeSource(id);
  }

  /* ------------------------------------------------------------ 来源记账 */

  static bool _booted = false;

  /// 回落统一由本层做，关掉数据层自带的回落（见类注释第 2 条）。
  static void _boot() {
    if (_booted) return;
    _booted = true;
    CmsApi.fallback = false;
  }

  static final Map<String, _Origin> _origins = <String, _Origin>{};

  static const int _originLimit = 4000;

  static _Origin _originOf(String id) =>
      _origins[id.trim()] ?? _Origin.unknown;

  static void _mark(String id, _Origin origin) {
    final key = id.trim();
    if (key.isEmpty) return;
    if (_origins.length >= _originLimit && !_origins.containsKey(key)) {
      _origins.remove(_origins.keys.first);
    }
    _origins[key] = origin;
  }

  static void _markAll(List<VideoCard> cards, _Origin origin) {
    for (final card in cards) {
      _mark(card.id, origin);
    }
  }

  static void _markIds(List<String> ids, _Origin origin) {
    for (final id in ids) {
      _mark(id, origin);
    }
  }

  /// 清掉来源账本（切换站点 / 调试用）。
  static void clearCache() {
    _origins.clear();
    CmsApi.clearCache();
  }
}

/// CMS 的一级栏目：页面用的键、导航显示名、`type_id`、旧接口的分类键。
class CmsChannel {
  const CmsChannel(this.key, this.label, this.typeId, this.legacy);

  /// 页面内部用的频道键（和 [CmsApi.typeIdOf] 的别名表一致）。
  final String key;

  /// 导航上显示的中文名。
  final String label;

  /// 苹果CMS 的 `type_id`；0 表示「推荐」这种聚合频道。
  final int typeId;

  /// 回落旧接口时用的分类键（movie / juji / manhua / zongyi …）。
  final String legacy;

  @override
  String toString() => key;
}

enum _Origin { unknown, cms, legacy }

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

  /* ------------------------------------------------------------ 旧接口开关 */

  /// 旧 `/api` 服务是否还当兜底用。
  ///
  /// 2026-11-14 迁移后旧接口所在的 8787 端口整体下线（新机 `125.94.244.87:8787`
  /// 直接不可达，旧机 `47.96.0.112:8787` 还在但 `/api/*` 全部 404），而
  /// [Api] 的兜底是「8 秒超时 ×2 次重试」，于是每一次回落都要白等 16 秒，
  /// 或者拿到一个 404 的 `not found` 当错误文案 —— 表现就是：
  /// 搜一个库里没有的词，转 16 秒然后报「not found」，而不是「没有找到」。
  ///
  /// 所以默认关掉：CMS 请求成功但**结果为空**时，就老老实实当空结果；
  /// CMS 请求**失败**时，直接把 CMS 的错误抛给页面（文案更准、也不用等）。
  /// 旧接口将来恢复时用 `--dart-define=FX_LEGACY=1` 打开，代码路径都在。
  static const bool legacyEnabled = bool.fromEnvironment(
    'FX_LEGACY',
    defaultValue: false,
  );

  /// 一条历史记录来自旧接口、而旧接口已经下线 —— 用 404 语义，
  /// 详情页的「该视频已失效」会接管，并给出「删除这条记录」的入口。
  static ApiException _legacyGone() => ApiException(
        '这条记录来自旧版片源，已无法打开，请重新搜索',
        code: 404,
      );

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
    final rows = (ch == null || ch.typeId <= 0) ? _homeRows : <CmsChannel>[ch];
    // 先用第一行探一次接口：整体不通时要么回落旧接口，要么把 CMS 的错误
    // 原样抛给首页 —— 不能吞成「空首页」，那样用户只会看到一片白。
    Object? failure;
    List<VideoCard>? first;
    try {
      first = await _row(rows.first.typeId);
    } catch (e) {
      failure = e;
    }
    if (first == null) {
      if (!legacyEnabled) throw failure ?? ApiException.network();
      return _legacyHome(ch);
    }

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
    if (sections.isEmpty) {
      if (!legacyEnabled) {
        return HomeData(const <BannerItem>[], const <HomeSection>[]);
      }
      return _legacyHome(ch);
    }

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

  /// 取一行；失败抛出去，由 [home] 决定是回落还是报错。
  static Future<List<VideoCard>> _row(int typeId) async {
    final list = _withoutLive(await CmsApi.categoryList(typeId, 1));
    _markAll(list, _Origin.cms);
    return list;
  }

  /// 取一行；失败返回 null（首页按「这一行没有」处理，不影响其它行）。
  static Future<List<VideoCard>?> _tryRow(int typeId) async {
    try {
      return await _row(typeId);
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

  /// 一页列表的结果。
  ///
  /// [hasMore] 由「原始接口这一页是不是给满了 20 条」决定，**不能**用过滤后的
  /// 条数判断：带年份筛选时一页 20 条里可能只剩 2 条，按过滤后条数算就会立刻
  /// 判定「没有更多」，后面的页永远拉不出来。
  static const int _pageSize = 20;

  /// 带筛选时一次连读多少页原始列表。
  ///
  /// CMS 的 `ac=detail` 不支持 `area` / `year` 服务端筛选（实测传了也原样返回），
  /// 只能前端过滤。只滤一页的话「年份 2023」可能一条都不剩，用户会以为全站
  /// 没有 2023 年的片子；连读 3 页（60 条）再滤，样本足够看出效果。
  static const int _scanPages = 3;

  static bool _filterWanted({String area = '', String year = ''}) =>
      area.trim().isNotEmpty || year.trim().isNotEmpty;

  /// 分类列表：`type` 接受频道键 / CMS 数字 id / 中文名。
  ///
  /// 地区 / 年份是旧接口的服务端筛选，CMS 的接口不支持 —— 这里按当前页做一次
  /// 客户端过滤，筛选胶囊不会变成「点了没反应」。
  static Future<List<VideoCard>> category({
    String type = '',
    String area = '',
    String year = '',
    String sort = 'latest',
    int page = 1,
  }) async {
    final result = await categoryPage(
      type: type,
      area: area,
      year: year,
      sort: sort,
      page: page,
    );
    return result.items;
  }

  /// [category] 的完整版：多带一个 `hasMore` 给上拉分页用。
  static Future<CmsPage> categoryPage({
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
    final wanted = _filterWanted(area: area, year: year);
    final scan = wanted ? _scanPages : 1;

    final raw = <VideoCard>[];
    var hasMore = false;
    Object? failure;
    for (var i = 0; i < scan; i++) {
      final rawPage = (page - 1) * scan + i + 1;
      List<VideoCard> chunk;
      try {
        chunk = _withoutLive(
          await CmsApi.list(type: typeId, page: rawPage, sort: sort),
        );
      } catch (e) {
        failure = e;
        break;
      }
      _markAll(chunk, _Origin.cms);
      hasMore = chunk.length >= _pageSize;
      raw.addAll(chunk);
      if (!hasMore) break;
      // 没筛选就只取一页；有筛选且已经够一页了也不用再扫。
      if (!wanted || raw.length >= _pageSize) break;
    }

    final extra = await _safe(extraFuture);
    if (failure == null) {
      return CmsPage(
        _mergeWith(
            _sortCards(_filter(raw, area: area, year: year), sort), extra),
        hasMore: hasMore,
      );
    }

    // 主站这一页彻底失败（不是「空结果」）：先看外部源有没有货。
    if (!legacyEnabled) {
      if (extra.isNotEmpty) return CmsPage(_sortCards(extra, sort));
      throw failure;
    }

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
    } catch (_) {
      // 两边都不通：外部源有结果就先给结果，否则把主站的错误抛给页面。
      if (extra.isNotEmpty) return CmsPage(_sortCards(extra, sort));
      throw failure;
    }
    return CmsPage(
      _mergeWith(legacy, extra),
      hasMore: legacy.length >= _pageSize,
    );
  }

  /// 地区 / 年份的前端过滤。
  ///
  /// 关键点：**字段本身没有值的时候不要拿它去过滤**。实测本站 `vod_area`
  /// 全站为空、`vod_year` 也有一批空值，如果照字段硬滤，用户一选「地区」就
  /// 得到空列表，还以为是筛得太严；正确的解读是「这个维度后端没给数据，
  /// 没法筛」，保持原列表并如实提示（见分类页的筛选说明）。
  static List<VideoCard> _filter(
    List<VideoCard> src, {
    String area = '',
    String year = '',
  }) {
    final wantArea = area.trim();
    final wantYear = year.trim();
    if (wantArea.isEmpty && wantYear.isEmpty) return src;
    final hasArea = src.any((card) => card.area.trim().isNotEmpty);
    final hasYear = src.any((card) => card.year > 0);
    final useArea = wantArea.isNotEmpty && hasArea;
    final useYear = wantYear.isNotEmpty && hasYear;
    if (!useArea && !useYear) return src;
    return <VideoCard>[
      for (final card in src)
        if ((!useArea || card.area.contains(wantArea)) &&
            (!useYear || '${card.year}' == wantYear))
          card,
    ];
  }

  /// 排序：服务端 `order=` 实测被忽略（`vod_time` / `vod_score` / `vod_hits`
  /// 三种取值返回的是同一个序列），所以在客户端补一次稳定排序。
  ///
  /// 本站 `vod_score` / `vod_hits` 目前全站为 0，按它们排和按更新时间排结果
  /// 一样 —— 这不是没执行，是没有可比的数据；等后台把评分 / 点击量补上，
  /// 这里自动就生效了。稳定排序（同分保持服务端原序）保证顺序不会跳。
  static List<VideoCard> _sortCards(List<VideoCard> src, String sort) {
    final key = sort.trim().toLowerCase();
    if (src.length < 2) return src;
    num Function(VideoCard) metric;
    switch (key) {
      case 'rating':
      case 'score':
        metric = (card) => card.rating;
        break;
      case 'hot':
      case 'hits':
        metric = (card) => _heatValue(card.heat);
        break;
      default:
        return src;
    }
    final indexed = <MapEntry<int, VideoCard>>[
      for (var i = 0; i < src.length; i++) MapEntry<int, VideoCard>(i, src[i]),
    ];
    indexed.sort((a, b) {
      final byMetric = metric(b.value).compareTo(metric(a.value));
      return byMetric != 0 ? byMetric : a.key.compareTo(b.key);
    });
    return <VideoCard>[for (final entry in indexed) entry.value];
  }

  /// 卡片上的热度文案（`9500` / `1.2万` / 空串）→ 可比较的数值。
  static num _heatValue(String heat) {
    final text = heat.trim();
    if (text.isEmpty) return 0;
    if (text.endsWith('万')) {
      final n = double.tryParse(text.substring(0, text.length - 1));
      return n == null ? 0 : n * 10000;
    }
    return num.tryParse(text) ?? 0;
  }

  /* ------------------------------------------------------------ 搜索 */

  static Future<List<VideoCard>> search(String keyword, int page) async {
    _boot();
    final q = keyword.trim();
    if (q.isEmpty) return const <VideoCard>[];
    // 主站采集库 + 所有启用的云端 / 自加源并行查，结果按「片名 + 年份」合并去重。
    final extraFuture = SourceHub.instance.searchAll(q, page);
    List<VideoCard> primary = const <VideoCard>[];
    Object? failure;
    try {
      primary = _withoutLive(await CmsApi.search(q, page));
      _markAll(primary, _Origin.cms);
    } catch (e) {
      failure = e;
    }
    final extra = await _safe(extraFuture);
    if (extra.isNotEmpty) return _mergeWith(primary, extra);
    // 请求成功就等于「有结果」，空列表也是结果。旧实现在这里把「空」当成
    // 「这条路走不通」再去打一次旧接口 —— 搜一个库里没有的词要白等 16 秒
    // （8 秒超时 ×2），最后还拿旧机的 404 `not found` 当错误文案。
    if (failure == null) return primary;
    if (!legacyEnabled) throw failure;
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
    if (!legacyEnabled) return out;
    final legacy = await Api.rank('hot');
    _markAll(legacy, _Origin.legacy);
    take(legacy);
    return out;
  }

  /* ------------------------------------------------------------ 排行榜 */

  /// 榜单：CMS 按点击量排（`order=vod_hits`），失败回落旧的榜单接口。
  ///
  /// 注意：本站 `order=` 被服务端忽略、`vod_hits` 也全站为 0，所以榜单目前
  /// 实际就是「最新」序 —— 这是后台数据缺失，不是这里没传参（见 `_sortCards`）。
  static Future<List<VideoCard>> rank(String type) async {
    _boot();
    final typeId = CmsApi.typeIdOf(type);
    Object? failure;
    try {
      final list = _withoutLive(await CmsApi.list(type: typeId, sort: 'hot'));
      _markAll(list, _Origin.cms);
      // 请求成功就是结果，空列表也是结果（旧接口已下线，不再拿空当失败）。
      if (list.isNotEmpty || !legacyEnabled) return list;
    } catch (e) {
      failure = e;
    }
    if (!legacyEnabled) throw failure ?? ApiException.network();
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
    } catch (e) {
      if (origin == _Origin.unknown) {
        if (!legacyEnabled) {
          // 来源未知的 id 才可能是旧接口编号（老历史 / 老收藏）。CMS 里
          // 查不到就说明这条记录已经没有对应片源了，用 404 语义让详情页
          // 走「该视频已失效 → 删除这条记录」，别让用户对着重试按钮干等。
          throw _isNotFound(e) ? _legacyGone() : e;
        }
        try {
          return await _legacyDetail(id);
        } catch (_) {
          // 旧接口也没有：把 CMS 的错误抛给页面（文案更贴近真实原因）。
        }
      }
      rethrow;
    }
  }

  /// CMS / 旧接口都表示「这部片不存在」。
  static bool _isNotFound(Object error) {
    if (error is! ApiException) return false;
    return error.code == 404 ||
        error.message.contains('没有找到') ||
        error.message.contains('作品不存在');
  }

  static Future<VideoDetail> _legacyDetail(String id) async {
    if (!legacyEnabled) throw _legacyGone();
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
    if (origin == _Origin.legacy) {
      if (!legacyEnabled) throw _legacyGone();
      return Api.play(vodId, ep, line, fresh: fresh);
    }
    try {
      final info = await CmsApi.playEpisode(vodId, line, ep);
      _mark(vodId, _Origin.cms);
      return info;
    } catch (e) {
      if (origin == _Origin.unknown) {
        if (!legacyEnabled) throw _isNotFound(e) ? _legacyGone() : e;
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

  static _Origin _originOf(String id) => _origins[id.trim()] ?? _Origin.unknown;

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

/// 一页分类列表：条目 + 还有没有下一页。
class CmsPage {
  const CmsPage(this.items, {this.hasMore = false});

  final List<VideoCard> items;

  /// 后端这一页是否给满（给满才代表后面还有）。
  final bool hasMore;
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

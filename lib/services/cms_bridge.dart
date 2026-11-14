import 'dart:async';

import '../api.dart';
import '../models.dart';
import 'cms_api.dart';
import 'cms_client.dart';
import 'jar_spider.dart';
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
  /// 六行**并行**取，某一行失败只当「这一行没有」，绝不让整页变成「加载
  /// 失败」——这正是用户看到的「分类行空白 / 加载失败」的来源：以前先拿第一
  /// 行探路，第一行一挂就整页抛错。只有六行**全部失败**才当接口不通，
  /// 那时才回落旧接口或者把错误交给页面。
  static Future<HomeData> home(String channel) async {
    _boot();
    final ch = channelOf(channel);
    final rows = (ch == null || ch.typeId <= 0) ? _homeRows : <CmsChannel>[ch];
    Object? failure;
    final lists = await Future.wait(<Future<List<VideoCard>?>>[
      for (final row in rows)
        _tryRow(row.typeId, onError: (Object e) => failure ??= e),
    ]);

    final sections = <HomeSection>[];
    for (var i = 0; i < rows.length; i++) {
      final items = lists[i];
      if (items == null || items.isEmpty) continue;
      sections.add(
        HomeSection(rows[i].label, items.take(_rowCount).toList()),
      );
    }
    final allFailed = lists.every((list) => list == null);
    if (sections.isEmpty) {
      if (allFailed && failure != null) {
        if (!legacyEnabled) throw failure!;
        return _legacyHome(ch);
      }
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

  /// 取一行；失败返回 null（首页按「这一行没有」处理，不影响其它行），
  /// 同时把错误记给 [onError] —— 六行全挂时才知道是真不通。
  static Future<List<VideoCard>?> _tryRow(
    int typeId, {
    void Function(Object error)? onError,
  }) async {
    try {
      return await _row(typeId);
    } catch (e) {
      onError?.call(e);
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

  /// 一次性拿到全部结果（老的调用方：一起看选片、外挂取片等）。
  ///
  /// 内部就是收 [searchStream] 的流：我们自己的结果在前，外部源的结果在后。
  static Future<List<VideoCard>> search(String keyword, int page) async {
    final own = <VideoCard>[];
    final external = <VideoCard>[];
    await for (final batch in searchStream(keyword, page)) {
      (batch.external ? external : own).addAll(batch.items);
    }
    return <VideoCard>[...own, ...external];
  }

  /// 只查我们自己那一批（主站采集库 + 幻想线路），一次拿全。
  ///
  /// 上拉「加载更多」用它：同一个词的第 2 页把 41 个 jar 源再全跑一遍没有意义
  /// （外部源的分页质量参差，翻页常常把第 1 页原样再返回一遍），分页只续我们
  /// 自己那批。
  static Future<List<VideoCard>> searchOwn(String keyword, int page) async {
    _boot();
    final q = keyword.trim();
    if (q.isEmpty) return const <VideoCard>[];
    final hub = SourceHub.instance;
    await hub.ensureReady();
    final plan = hub.searchPlan;
    final lists = await Future.wait(<Future<List<VideoCard>>>[
      _primarySearch(q, page),
      for (final source in plan.own) hub.searchPrepared(source, q, page),
    ]);
    final dedupe = _Dedupe();
    final out = <VideoCard>[];
    for (final list in lists) {
      for (final card in list) {
        if (SourceHub.isLiveCard(card)) continue;
        if (!dedupe.fresh(card)) continue;
        out.add(card);
      }
    }
    return out;
  }

  /// 主站采集库（本地 CMS）：失败不抛，交给上层按「这个源没结果」处理。
  static Future<List<VideoCard>> _primarySearch(String q, int page) async {
    try {
      final list = _withoutLive(await CmsApi.search(q, page));
      _markAll(list, _Origin.cms);
      return list;
    } catch (_) {
      return const <VideoCard>[];
    }
  }

  /// 渐进检索：谁先回来谁先渲染，不再等 48 个源全部返回。
  ///
  /// 发车顺序（全部同时开跑，互不等待）：
  ///   1. 主站采集库（本地 CMS）—— 通常几十毫秒，第一批就它；
  ///   2. 我们自己的幻想线路（云端下发的 7 条）—— 同一个接口，也很快；
  ///   3. 外部源（肥猫的 41 个 jar 源 + 用户自加）—— 慢，回来一批追加一批。
  ///
  /// 每个源单独 8 秒超时（[SourceHub.sourceTimeout]），超时按「没结果」算，
  /// 不会阻塞别的源。每批都带 `done / total`，页面据此显示「已查 12/48 个源」。
  ///
  /// 所有源都空、而主站采集库是**报错**（不是空结果）时，最后补一个错误：
  /// 页面就能给出「重新搜索」，而不是含糊的「没有找到」。
  static Stream<SearchBatch> searchStream(String keyword, int page) {
    _boot();
    final q = keyword.trim();
    if (q.isEmpty) {
      return Stream<SearchBatch>.value(
        const SearchBatch(
          items: <VideoCard>[],
          external: false,
          done: 0,
          total: 0,
          finished: true,
        ),
      );
    }
    final hub = SourceHub.instance;
    final dedupe = _Dedupe();
    final ctrl = StreamController<SearchBatch>();
    var done = 0;
    var total = 0;
    var emitted = 0;
    var closed = false;
    Object? primaryFailure;

    void emit(List<VideoCard> cards, {required bool external}) {
      if (closed) return;
      final kept = <VideoCard>[];
      for (final card in cards) {
        if (SourceHub.isLiveCard(card)) continue;
        if (!dedupe.fresh(card)) continue;
        kept.add(card);
      }
      emitted += kept.length;
      ctrl.add(
        SearchBatch(
          items: kept,
          external: external,
          done: done,
          total: total,
          finished: false,
        ),
      );
    }

    Future<void> run() async {
      await hub.ensureReady();
      if (closed) return;
      final plan = hub.searchPlan;
      total = plan.total;
      final tasks = <Future<void>>[];

      // 1. 本地 CMS：第一批发车，回来就渲染。
      tasks.add(() async {
        try {
          final list = _withoutLive(await CmsApi.search(q, page));
          _markAll(list, _Origin.cms);
          emit(list, external: false);
        } catch (e) {
          primaryFailure = e;
        }
      }());

      // 2. 我们自己的线路（幻想 7 条）。
      for (final source in plan.own) {
        tasks.add(() async {
          final cards = await hub.searchPrepared(source, q, page);
          done++;
          emit(cards, external: false);
        }());
      }

      // 3. 外部源（肥猫 41 个 jar 源 + 自加）：并行后台查，逐批追加。
      for (final source in plan.external) {
        tasks.add(() async {
          final cards = await hub.searchPrepared(source, q, page);
          done++;
          emit(cards, external: true);
        }());
      }

      await Future.wait(tasks);
      if (closed) return;
      if (emitted == 0 && primaryFailure != null) {
        ctrl.addError(primaryFailure!);
      } else {
        ctrl.add(
          SearchBatch(
            items: const <VideoCard>[],
            external: false,
            done: total,
            total: total,
            finished: true,
          ),
        );
      }
      closed = true;
      await ctrl.close();
    }

    ctrl.onCancel = () {
      closed = true;
    };
    unawaited(run());
    return ctrl.stream;
  }

  /// 合并主站 / 外部源两份结果（分类页还在用；搜索走 [searchStream]）。
  ///
  /// 去重按片名分桶记年份：主站的卡片带年份（`ac=detail`），外部源走通用的
  /// `ac=list`（第三方接口不一定给 `vod_year`），同一个片名一边是
  /// `头号玩家|2018`、一边是 `头号玩家|0`，拼串比对会把同一部片留两条。
  static List<VideoCard> _mergeWith(
    List<VideoCard> primary,
    List<VideoCard> extra,
  ) {
    if (extra.isEmpty) return primary;
    final dedupe = _Dedupe();
    final out = <VideoCard>[];
    for (final card in primary) {
      if (!dedupe.fresh(card)) continue;
      out.add(SourceHub.relabel(card, label: '采集库'));
    }
    for (final card in extra) {
      if (!dedupe.fresh(card)) continue;
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

  /// 榜单：热度 → 评分 → 更新时间（见 [_sortRank]）。
  ///
  /// 服务端 `order=` 实测被忽略（`vod_hits` / `vod_score` / `vod_time` 传啥都
  /// 返回同一个序列），所以真排序只能在客户端做；[pages] 决定一次读几页样本
  /// —— 日榜读 1 页、总榜读 8 页，样本越大越像真榜。
  ///
  /// 「不要空」：指定分类里一条数据都没有时退到全站再读一次，不把空列表交给
  /// 页面；两边都空、且是真报错，才把错误抛给页面（页面有重试）。
  static Future<List<VideoCard>> rank(String type, {int pages = 1}) async {
    _boot();
    final typeId = CmsApi.typeIdOf(type);
    final n = pages < 1 ? 1 : pages;
    Object? failure;

    Future<List<VideoCard>> scan(int t) async {
      final lists = await Future.wait(<Future<List<VideoCard>>>[
        for (var p = 1; p <= n; p++)
          CmsApi.list(type: t, page: p, sort: 'hot').catchError(
            (Object e) {
              failure ??= e;
              return const <VideoCard>[];
            },
          ),
      ]);
      final out = <VideoCard>[];
      final seen = <String>{};
      for (final list in lists) {
        _markAll(list, _Origin.cms);
        for (final card in list) {
          if (SourceHub.isLiveCard(card)) continue;
          if (!seen.add(card.id)) continue;
          out.add(card);
        }
      }
      return out;
    }

    var list = await scan(typeId);
    if (list.isEmpty && typeId != 0) list = await scan(0);
    if (list.isNotEmpty) return _sortRank(list);
    if (!legacyEnabled) {
      throw failure ?? ApiException('榜单暂时没有数据，稍后刷新试试');
    }
    final legacy = _withoutLive(await Api.rank(type));
    _markAll(legacy, _Origin.legacy);
    return _sortRank(legacy);
  }

  /// 榜单排序：热度 → 评分 → 更新时间 → 年份。
  ///
  /// 稳定排序（同分保持服务端原序），所以刷新不会让顺序乱跳；任何时候都
  /// **不按 id 排** —— id 是采集库的自增编号，按它排出来的是「谁先进库」，
  /// 和热度、评分、更新一点关系都没有。
  static List<VideoCard> _sortRank(List<VideoCard> src) {
    if (src.length < 2) return src;
    final indexed = <MapEntry<int, VideoCard>>[
      for (var i = 0; i < src.length; i++) MapEntry<int, VideoCard>(i, src[i]),
    ];
    indexed.sort((x, y) {
      final a = x.value;
      final b = y.value;
      var r = _heatValue(b.heat).compareTo(_heatValue(a.heat));
      if (r != 0) return r;
      r = b.rating.compareTo(a.rating);
      if (r != 0) return r;
      r = b.time.compareTo(a.time);
      if (r != 0) return r;
      r = b.year.compareTo(a.year);
      if (r != 0) return r;
      return x.key.compareTo(y.key);
    });
    return <VideoCard>[for (final entry in indexed) entry.value];
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
      // jar 源（TVBox type 3）：详情走 JarSpider，模型出口与 CMS 一致。
      if (external.kind == KSourceKind.jar) {
        final detail = await JarSpider.detail(
          api: external.api,
          ext: external.ext,
          vodId: SourceHub.rawIdOf(id),
        );
        _mark(id, _Origin.cms);
        return detail;
      }
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
      if (external.kind == KSourceKind.jar) {
        // jar 源：拿详情里的集地址交给 playerContent（解析在 jar 内部完成）。
        final info = await JarSpider.play(
          api: external.api,
          ext: external.ext,
          vodId: SourceHub.rawIdOf(vodId),
          lineName: line,
          ep: ep,
        );
        _mark(vodId, _Origin.cms);
        return info;
      }
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
      if (external.kind == KSourceKind.jar) {
        final info = await JarSpider.play(
          api: external.api,
          ext: external.ext,
          vodId: SourceHub.rawIdOf(vodId),
          lineName: line,
          ep: ep,
        );
        return info.url;
      }
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

/// 渐进检索的一批结果。
///
/// [external] 为 false 表示「我们自己那一批」（主站采集库 + 幻想线路），
/// 页面要把它排在上面；true 表示外部源（肥猫 / 自加），排在下面的
/// 「外部源结果」分区里，边到边显示。
class SearchBatch {
  const SearchBatch({
    required this.items,
    required this.external,
    required this.done,
    required this.total,
    required this.finished,
  });

  /// 这一批新增的结果（已去重、已带来源标记与 `@src:` id）。
  final List<VideoCard> items;

  /// 是否来自外部源。
  final bool external;

  /// 已经查完的源数（进度文案「已查 12/48 个源」的分子）。
  final int done;

  /// 这一轮要查的源总数（分子分母的分母）。
  final int total;

  /// 所有源都结束了（这一批的 items 一定是空的）。
  final bool finished;
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

/// 跨源去重的记账本：片名分桶 + 年份比对。
///
/// 年份未知（0）的那条只要同名片已经出现过就算重复；年份已知的按年份比，
/// 同名不同年（翻拍版）仍然各留一条。渐进检索要把这个账本一路带下去，
/// 每批都过一遍，才能保证「外部源结果」里不会冒出上面已经有的片子。
class _Dedupe {
  final Map<String, Set<int>> _seen = <String, Set<int>>{};

  bool fresh(VideoCard card) {
    final key = SourceHub.normTitle(card.title);
    if (key.isEmpty) return true;
    final years = _seen.putIfAbsent(key, () => <int>{});
    if (card.year <= 0) {
      if (years.isNotEmpty) return false;
      years.add(0);
      return true;
    }
    if (years.contains(card.year) || years.contains(0)) return false;
    years.add(card.year);
    return true;
  }
}

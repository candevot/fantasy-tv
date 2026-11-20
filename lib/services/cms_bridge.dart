import 'dart:async';

import '../api.dart';
import '../models.dart';
import 'cms_api.dart';
import 'cms_client.dart';
import 'jar_log.dart';
import 'jar_sources.dart';
import 'jar_spider.dart';
import 'source_log.dart';
import 'play_log.dart';
import 'play_path.dart';
import 'search_rank.dart';
import 'search_relevance.dart';
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
    CmsChannel('kids', '少儿', 6, 'manhua'),
  ];

  /// 「推荐」页要铺的六个分类行（顺序即首页从上到下的顺序）。
  static const List<CmsChannel> _homeRows = <CmsChannel>[
    CmsChannel('movie', '电影', 1, 'movie'),
    CmsChannel('tv', '电视剧', 2, 'juji'),
    CmsChannel('anime', '动漫', 3, 'manhua'),
    CmsChannel('zongyi', '综艺', 4, 'zongyi'),
    CmsChannel('kids', '少儿', 6, 'manhua'),
  ];

  /// 每行最多给 12 条（首页只显示 10 条，多两条留给横滑）。
  static const int _rowCount = 40;

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
    // HOME_OWN_ONLY（2026-11-17）：首页**永远只用我们自己的片源**。
    // 用户口径：「主页和界面还是自己的片源线路，要看肥猫的人只有搜索」。
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
      // HOME_NOFAIL（2026-11-21）：首页推荐**不再整体报「加载失败」**。
      // 用户实测：分类页正常、只有推荐页挂 —— 只要任一行成功就必须出内容；
      // 全部失败也先返回空数据让页面显示自己的重试态，不要再把异常抛给页面。
      if (allFailed && failure != null) {
        if (legacyEnabled) return _legacyHome(ch);
        return HomeData(const <BannerItem>[], const <HomeSection>[]);
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
  ///
  /// HOT_ORDER（2026-11-15）：首页每一行要的是**热播**，不是「刚更新」。
  /// 服务端 `Provide.php` 已经修好、`order=vod_hits&by=desc` 实测严格递减
  /// （1,200,000 → 1,187,000…），所以这里直接把排序交给服务端：
  /// 之前按 `vod_time` 拉，首页展示的其实是「最近入库」，用户看到的当然
  /// 不是热播剧。
  static Future<List<VideoCard>> _row(int typeId) async {
    // HOME_PLAYABLE（2026-11-15）：**没有播放地址的记录不进首页**。
    // 热播榜只写 `vod_hits`，按它排出来的第一批里混着 `vod_play_url` 为空 /
    // 只有占位的记录 —— 点进去必然没有线路，用户看到的是「点开播不了」。
    // 这里在转模型之前就滤掉，宁可少一条卡片，也不给一条点不开的。
    // RULE_SRC（2026-11-15）：首页只铺我们自己的片源（hx）。
    // 不带 `src` 时服务端把 hx / xo 两条同名片一起给回来，首页第一行就会
    // 出现「八仙（幻想）」和「八仙（官采切片）」并排。
    // HOME_MORE（2026-11-20）：用户要求推荐多给几条。一页只有 20 条，
    // 这里拉两页合并成 40 条（同一部片按 id 去重）。
    // HOME_MORE_SAFE：第 1 页必须有，第 2 页只是「多给点」——
    // 第 2 页失败（越界 / 接口偶发 500）不能把整行、进而整页首页拖垮。
    final first = await CmsApi.listVod(
        type: typeId, page: 1, sort: 'hot', src: CmsApi.ownSrc);
    List<dynamic> second = const <dynamic>[];
    try {
      second = await CmsApi.listVod(
          type: typeId, page: 2, sort: 'hot', src: CmsApi.ownSrc);
    } catch (_) {
      second = const <dynamic>[];
    }
    final pages = <List<dynamic>>[first, second];
    final seen = <String>{};
    final vods = <dynamic>[];
    for (final pg in pages) {
      for (final v in pg) {
        final id = '${(v as dynamic).vodId ?? v.vod_id ?? v}';
        if (!seen.add(id)) continue;
        vods.add(v);
      }
    }
    final list = <VideoCard>[];
    for (final vod in vods) {
      if (!CmsApi.hasPlayUrl(vod)) continue;
      try {
        list.add(CmsApi.cardOf(vod));
      } catch (_) {
        // 单条坏数据不影响整行。
      }
    }
    final clean = _withoutLive(list);
    _markAll(clean, CmsOrigin.cms);
    return clean;
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
    ], CmsOrigin.legacy);
    _markIds(<String>[for (final b in data.banners) b.id], CmsOrigin.legacy);
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
    String sort = 'hot',
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
    String sort = 'hot',
    int page = 1,
  }) async {
    _boot();
    // HOME_OWN_ONLY（2026-11-17）：分类页同样只用我们自己的片源。
    final typeId = CmsApi.typeIdOf(type);
    // RULE_SRC（2026-11-15）：分类页只用**我们自己的片源**。
    //
    // 产品规则：首页 / 各分类 = 我们自己的片源（hx），肥猫只在搜索里出现。
    // 这里原来还把 `SourceHub.categoryAll`（肥猫 41 个 jar 源 + 用户自加）
    // 合并进分类列表，两个后果：
    //   · 破了「肥猫只在搜索里出现」这条规则；
    //   · 主站同一部剧的 hx / xo 两条记录加上外部源的同名片，分类页里
    //     一部剧能出现三次，用户看到的就是「重复卡片」。
    final wanted = _filterWanted(area: area, year: year);
    final scan = wanted ? _scanPages : 1;

    final raw = <VideoCard>[];
    var hasMore = false;
    Object? failure;
    for (var i = 0; i < scan; i++) {
      final rawPage = (page - 1) * scan + i + 1;
      CmsVodPage rawChunk;
      try {
        rawChunk = await CmsApi.listVodPage(
          type: typeId,
          page: rawPage,
          sort: sort,
          src: CmsApi.ownSrc,
        );
      } catch (e) {
        failure = e;
        break;
      }
      final cards = <VideoCard>[];
      for (final vod in rawChunk.vods) {
        final card = _cardOrNull(vod);
        if (card != null) cards.add(card);
      }
      // PAGES_ALIGN（2026-11-15）：用**过滤前**的整页结果判断后面还有没有，
      // 而不是 `_withoutLive` 之后的条数 —— 首页少一条直播卡就会让整条分类
      // 永久判定「到底」。
      //
      // PAGE_META（2026-11-15）：服务端给了 `pagecount` 就直接按它算，
      // 「第 8 页 / 共 8 页」之后才亮「已经到底啦」；没给 pagecount 时
      // CmsVodPage.hasMore 退回「这一页给满了没有」。
      final chunk = _withoutLive(cards);
      _markAll(chunk, CmsOrigin.cms);
      raw.addAll(chunk);
      hasMore = rawChunk.hasMore;
      if (!hasMore) break;
    }

    if (failure == null) {
      final items = _filter(raw, area: area, year: year);
      // 带筛选时一个逻辑页由 [_scanPages] 个原始页组成（rawPage 从
      // `(page-1)*scan+1` 起跳），窗口之间不重叠，所以这一整批过滤结果
      // **必须全部交出去**。
      //
      // PAGE_TRUNC（2026-11-15）：原来这里还按 `_pageSize` 切成 20 条，
      // 剩下的 40 条既不在本页、也不会出现在后面的页里（下一逻辑页从头开始
      // 读原始第 4 页）—— 筛选后 50 条命中的分类，用户只能看到 20 条，
      // 越翻越少，属于静默丢数据。
      return CmsPage(items, hasMore: hasMore);
    }
    // 主站这一页彻底失败（不是「空结果」）：旧接口开关打开时再试一次。
    if (!legacyEnabled) throw failure;

    List<VideoCard> legacy = const <VideoCard>[];
    try {
      legacy = _withoutLive(await Api.category(
        type: CmsApi.legacyTypeOf(typeId),
        area: area,
        year: year,
        sort: sort,
        page: page,
      ));
      _markAll(legacy, CmsOrigin.legacy);
    } catch (_) {
      // 两边都不通：把主站的错误抛给页面（页面有自己的重试入口）。
      throw failure;
    }
    return CmsPage(
      _filter(legacy, area: area, year: year),
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
  /// 内部就是收 [searchStream] 的流，收到首屏那一轮收尾就返回。
  static Future<List<VideoCard>> search(String keyword, int page) async {
    final own = <VideoCard>[];
    final external = <VideoCard>[];
    await for (final batch in searchStream(keyword, page)) {
      (batch.external ? external : own).addAll(batch.items);
      // SOFT_FINISH（2026-11-16）：`finished` 现在是「首屏这一轮结束」的信号
      // （4 秒软收尾），流之后还会继续追加后台补全的结果。聚合调用方要的是
      // 「尽快拿到一批能用的结果」（一起看选片、AI 推荐），不能等 60 秒硬收尾
      // —— 收到第一条 finished 就收工，拿到的就是首屏那批。
      if (batch.finished) break;
    }
    return <VideoCard>[...own, ...external];
  }

  /// 只查我们自己那一批（主站采集库 + 幻想线路），一次拿全。
  ///
  /// 上拉「加载更多」用它：第 2 页只续我们自己那批（主站采集库 + 幻想线路
  /// 切片），不必把同一轮的全部源重跑一遍。
  static Future<List<VideoCard>> searchOwn(String keyword, int page) async {
    _boot();
    final q = keyword.trim();
    if (q.isEmpty) return const <VideoCard>[];
    final hub = SourceHub.instance;
    // 和 searchStream 一样给 `ensureReady` 兜超时：这一步只是读本地缓存 +
    // 片源表，卡住时不能让「上拉加载更多」永远转圈。
    try {
      await hub.ensureReady().timeout(
        const Duration(seconds: 3),
        onTimeout: () => null,
      );
    } catch (_) {
      // 索引坏了也要能搜：plan 为空表就只查主站。
    }
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

  /// 主站按线路切片的内置源（SEARCH_WAVES 2026-11-15）。
  ///
  /// 为什么要单独发这几路：用户反馈「搜索不慢慢加载，壳是一个源一个源出来」。
  /// 采集库那一次 `wd=` 搜索实测 3.5~4.2 秒（服务端全库 LIKE），如果只等它，
  /// 页面上就是「转 4 秒 → 一坨全出来」。而按线路切片查同一个关键词，
  /// 幻想爱奇艺约 0.6 秒就有结果，其余 3.5~3.8 秒陆续回来 —— 首批早到，
  /// 后面几批陆续追加，观感和壳一致。
  ///
  /// 云端的 `cloud_sources` 里通常也有这几条（key 带 api 里的 `?line=`），
  /// 这里按 api 去重，不会查两遍。
  static const List<(String, String)> _linePresets = <(String, String)>[
    ('幻想4K', '幻想4K'),
    ('幻想蓝光', '幻想蓝光'),
    ('幻想爱奇艺', '幻想爱奇艺'),
    ('量子', '量子'),
    ('红牛', '红牛'),
  ];

  /// 内置线路切片的地址：`…/api.php/provide/vod/?line=幻想4K`。
  static String _lineApi(String line) =>
      '${CmsApi.root}${CmsApi.vodPath}?line=${Uri.encodeQueryComponent(line)}';

  /// 主站采集库（本地 CMS）：失败不抛，交给上层按「这个源没结果」处理。
  ///
  /// 来源标注统一成「幻想」（[KSource.ownResultLabel]）：主站采集库就是
  /// 我们自己的 hx 库，和云端下发的幻想线路是同一个站，搜索结果里不能一半
  /// 标「云端」一半标「幻想」（SOURCE_LABEL 2026-11-15）。
  static Future<List<VideoCard>> _primarySearch(String q, int page) async {
    try {
      return _ownLabeled(_withoutLive(await CmsApi.search(q, page)));
    } catch (_) {
      return const <VideoCard>[];
    }
  }

  /// 我们自己那批卡片统一标「幻想」。
  ///
  /// [stripSourceId] = true 时把 `@src:<key>::` 前缀去掉 —— 线路切片查的是
  /// 同一个主站，卡片必须用裸 `vod_id` 走主站接口，不能带着外部源前缀。
  static List<VideoCard> _ownLabeled(
    List<VideoCard> cards, {
    bool stripSourceId = false,
    String sliceLine = '',
  }) {
    final out = <VideoCard>[];
    for (final card in cards) {
      var id = stripSourceId ? SourceHub.rawIdOf(card.id) : card.id;
      // LINE_SLICE：线路切片的卡片必须记住「这条是哪个切片查出来的」，
      // 否则点进详情就丢了 line 参数，平台线（爱奇艺）的记录必然查不到。
      if (sliceLine.trim().isNotEmpty) {
        id = sliceId(sliceLine, SourceHub.rawIdOf(id));
      }
      _mark(id, CmsOrigin.cms);
      out.add(SourceHub.relabel(
        card,
        label: KSource.ownResultLabel,
        id: id,
      ));
    }
    return out;
  }

  /// 渐进检索：谁先回来谁先渲染，不等所有源都回来。
  ///
  /// 发车顺序（全部同时开跑，互不等待）：
  ///   1. 主站采集库（本地 CMS）—— 通常几十毫秒，第一批就它；
  ///   2. 我们自己的幻想线路切片 —— 同一个接口，0.6~4 秒陆续回来；
  ///   3. 云端下发的幻想源 —— 同上。
  ///
  /// 每个源单独 12 秒超时（[SourceHub.sourceTimeout]），超时按「没结果」算，
  /// 不会阻塞别的源。每批都带 `done / total`，页面据此显示「已查 3/6 个源」。
  ///
  /// 所有源都空、而主站采集库是**报错**（不是空结果）时，最后补一个错误：
  /// 页面就能给出「重新搜索」，而不是含糊的「没有找到」。
  static Stream<SearchBatch> searchStream(
    String keyword,
    int page, {
    /// 同一部片的不同版本**不合并**（一起看建房要按版本分别列出）。
    ///
    /// 默认 false 保持原来的去重口径（片名+片源）；置 true 时只按卡片 id
    /// 去重。
    bool keepDuplicates = false,
  }) {
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
    final dedupe = _Dedupe(byId: keepDuplicates);
    final ctrl = StreamController<SearchBatch>();
    var done = 0;
    var total = 0;
    var emitted = 0;
    var closed = false;

    /// 软收尾是否已经发过（SOFT_FINISH 2026-11-16）。
    var softClosed = false;
    Object? primaryFailure;


    /// 主站第一页给了多少条（用来判断要不要补第二页那一波）。
    var firstPageCount = 0;

    /// 收尾：把「查完了」这一批发出去并关流。
    ///
    /// **必须幂等、必须一定被执行**（STREAM_TERMINATE 2026-11-15）。
    /// 原来这里只写在 `run()` 的最后一行：`run()` 中间任何一个 await 抛出来
    /// （最典型的是 `hub.ensureReady()` —— 那个 Future 一旦失败会被 SourceHub
    /// 缓存下来，之后每次搜索都在同一个地方炸），流既不 error 也不 close，
    /// 页面那边既收不到结果也收不到 done，`_loading` / `_skeleton` 永远是 true,
    /// 用户看到的就是「骨架屏一直转」。现在用 finally 兜住。
    ///
    /// SOFT_FINISH（2026-11-16）：拆成「软收尾」和「硬收尾」两档，见 [softFinish]。
    void finish() {
      if (closed) return;
      closed = true;
      if (emitted == 0 && primaryFailure != null) {
        ctrl.addError(primaryFailure!);
      } else if (!softClosed) {
        // 软收尾没发过（4 秒内就跑完了 / 一开始就空）：这里补一条 finished。
        ctrl.add(
          SearchBatch(
            items: const <VideoCard>[],
            external: false,
            done: total == 0 ? done : total,
            total: total == 0 ? done : total,
            finished: true,
          ),
        );
      }
      unawaited(ctrl.close());
    }

    /// 软收尾：告诉页面「首屏这一轮结束了」，**但不关流**（SOFT_FINISH 2026-11-16）。
    ///
    /// 为什么要有它：壳（FongMi）的多源搜索是「谁回来算谁、永远增量追加」，
    /// 页面从来没有「整轮收尾」这个概念 —— 用户看到的是结果一直在长。
    /// 我们之前只有一个「整体收尾」上限（40 秒），那 40 秒里页面只能一直转圈
    /// 等最后一个慢源，用户感受就是「壳也没这么慢」。
    ///
    /// 现在分两档：
    ///   · **4 秒软收尾**：发一条 `finished: true` 让页面停掉转圈 / 骨架 /
    ///     进度条（用户这时已经能看到 14 个源的结果），流继续开着；
    ///   · **后台继续追加**：还没回来的源照样 `emit`，页面照样往列表里长；
    ///   · **硬收尾**：`run()` 自然结束（所有源都回来了）或 60 秒兜底，才真正 close。
    ///
    /// 幂等：重复调用只发一次。
    void softFinish() {
      if (closed || softClosed) return;
      softClosed = true;
      ctrl.add(
        SearchBatch(
          items: const <VideoCard>[],
          external: false,
          done: total == 0 ? done : total,
          total: total == 0 ? done : total,
          finished: true,
        ),
      );
      fxSourceLog(
        'soft-finish key=$q 已回 $done/$total 源 · 后台继续补其余源',
      );
    }

    void emit(
      List<VideoCard> cards, {
      required bool external,
      int page = 1,
      String source = '',
      SourceSearchStatus status = SourceSearchStatus.ok,
    }) {
      if (closed) return;
      final kept = <VideoCard>[];
      // SEARCH_RELEVANCE（2026-11-15）：外部接口不保证按关键词搜 —— 有的直接
      // 把关键词当分类 id（见 search_relevance.dart 头注释），返回的是源站首页
      // 那批片。片名和关键词无关的一律丢掉（自家源也走同一道闸门，行为一致）。
      //
      // GATE_LOG（2026-11-15）：**每个源单独判、单独记**。整批判的话只知道
      // 「41 个源一共丢了 30 条」，不知道是哪个源在灌首页数据。
      final gate = external
          ? fxSearchGate(cards, q)
          : FxSearchGate(kept: cards, dropped: 0, extraClips: 0);
      if (external && (gate.dropped > 0 || gate.kept.isNotEmpty)) {
        fxSourceGateLog(source, gate);
      }
      for (final card in gate.kept) {
        if (SourceHub.isLiveCard(card)) continue;
        // 按 id 去重：线条切片 / 主库各自出的卡片 id 不同，不能被「片名+年份」
        // 合并丢掉（那会只剩一条，用户以为别的线路没结果）。
        if (!dedupe.fresh(card, perSource: external)) continue;
        kept.add(card);
      }
      emitted += kept.length;
      // SEARCH_RANK：每一批都按「分辨率优先」排好再交给页面 —— 先到的一批
      // 也已经是正确顺序，不会出现「低画质先占位、高画质后到被压在下面」。
      final ranked = SearchRank.sort(kept);
      ctrl.add(
        SearchBatch(
          items: ranked,
          external: external,
          done: done,
          total: total,
          finished: false,
          page: page,
          source: source,
          status: status,
          dropped: gate.dropped,
        ),
      );
    }

    Future<void> run() async {
      // 索引准备（读本地缓存 + 片源表）单独兜超时：这一步不该把整轮搜索
      // 拖死，超时就按「只有主站采集库」继续查。
      try {
        await hub.ensureReady().timeout(
          const Duration(seconds: 3),
          onTimeout: () => null,
        );
      } catch (_) {
        // 索引坏了也要能搜：下面的 plan 为空表就只查主站。
      }
      if (closed) return;
      final plan = hub.searchPlan;
      // 分母：主站 1 + 内置线路切片 + 云端源 + 外部源。
      final ownApis = <String>{
        for (final source in plan.own) source.api.trim(),
      };
      final lineQueries = <(String, String)>[
        for (final preset in _linePresets)
          if (!ownApis.contains(_lineApi(preset.$2))) preset,
      ];
      // +1：第一页满页时还会追加「第二页」那一波。
      total = 2 + lineQueries.length + plan.total;
      final tasks = <Future<void>>[];

      // 1. 本地 CMS：第一批发车，回来就渲染。
      tasks.add(() async {
        try {
          final list = _withoutLive(await CmsApi.search(q, page));
          firstPageCount = list.length;
          done++;
          emit(_ownLabeled(list), external: false);
        } catch (e) {
          primaryFailure = e;
        }
      }());

      // 1b. 内置线路切片：谁先回来谁先上屏（幻想爱奇艺通常 0.6 秒）。
      for (final preset in lineQueries) {
        final label = preset.$1;
        final api = _lineApi(preset.$2);
        tasks.add(() async {
          final cards = await SourceHub.instance
              .searchPrepared(
                KSource(
                  key: 'line_${preset.$2}',
                  name: label,
                  api: api,
                  kind: KSourceKind.cms,
                  origin: KSourceOrigin.cloud,
                ),
                q,
                page,
              )
              .catchError((Object _) => const <VideoCard>[]);
          done++;
          // 线路切片查的是**同一个主站**：id 用裸 vod_id + 切片线路名
          // （`@line:<线路>::<vod_id>`，见 [sliceId]）。不能只用裸 id ——
          // 平台线切片（幻想爱奇艺）的 id 主库不认，点进去必然加载失败。
          emit(
            _ownLabeled(cards, stripSourceId: true, sliceLine: label),
            external: false,
          );
        }());
      }

      // 2. 我们自己的线路（云端下发的幻想源）。
      for (final source in plan.own) {
        tasks.add(() async {
          final cards = await hub.searchPrepared(source, q, page);
          done++;
          emit(cards, external: false);
        }());
      }

      await Future.wait(tasks);
      if (closed) return;
      // SEARCH_WAVES（2026-11-15）：最后再加一波「第二页」。
      //
      // 单页满 20 条说明后面还有内容，把它取回来作为**独立的一批**追加，
      // 用户会看到结果在第一批之后又长出一截（壳也是这么滚动的），
      // 而不是「一坨到底、拉到底就没有了」。
      final firstPageFull = firstPageCount >= _pageSize;
      if (firstPageFull) {
        try {
          final more = _withoutLive(await CmsApi.search(q, page + 1));
          if (more.isNotEmpty && !closed) {
            done++;
            emit(_ownLabeled(more), external: false, page: page + 1);
          }
        } catch (_) {
          // 第二页失败不影响第一批结果。
        }
      }
    }

    ctrl.onCancel = () {
      closed = true;
    };
    // 兜底：不管 run() 怎么结束（正常 / 抛异常 / 单源卡住），都要收尾一次。
    unawaited(
      run().then<void>(
        (_) {},
        onError: (Object e) {
          primaryFailure ??= e;
        },
      ).whenComplete(finish),
    );
    // 硬上限：单源 12 秒（[SourceHub.sourceTimeout]），这里再兜一层整体上限。
    //
    // 单源 12 秒预算 + 整轮 30 秒兜底：用户早就在逐条看到结果了，
    // 这个上限只是兜「绝不允许无限转圈」。
    //
    // SOFT_FINISH（2026-11-16 · 对齐壳）：壳（FongMi `App.searchExecutor` 20 条
    // 线程 + 每个源一个 Future）根本没有「整体收尾」—— 谁回来算谁，页面一直
    // 增量追加。我们原来只有一个 40 秒的整体上限，那 40 秒里页面一直转圈等
    // 最后一个慢源，用户感受就是「壳也没这么慢」。
    //
    // 现在两档：
    //   · **4 秒软收尾**（[softFinish]）：停掉页面转圈/骨架/进度条 —— 实测 86 个
    //     可搜源 / 20 并发，3 秒就有 14 个源出结果、5 秒 20 个源，用户这时
    //     已经有得看了；
    //   · **60 秒硬收尾**（[finish]）：真正 close。慢源（金牌 9.1s init、
    //     骚火 5.9s、听友 6.5s 才回）照样能在后台补进列表。
    Timer(const Duration(seconds: 4), softFinish);
    Timer(const Duration(seconds: 60), finish);
    return ctrl.stream;
  }

  /// SEARCH_ORDER（2026-11-17）：搜索**不对源做任何优先级 / 排序干预**。
  ///
  /// 用户口径：「搜索不管顺序、谁先返回谁先上屏」，所以这里不对源做任何
  /// 优先级排序。页面按**到达顺序**渲染（见 `SearchPage._arrived`）。

  /// 单条记录转卡片；坏数据返回 null，**不能**让一条脏记录炸掉整页。
  ///
  /// 分类页现在直接吃 [CmsApi.listVodPage] 的原始记录（要拿分页元数据），
  /// 转换就落在这一层，所以这里自己兜异常。
  static VideoCard? _cardOrNull(Map<String, dynamic> vod) {
    try {
      return CmsApi.cardOf(vod);
    } catch (_) {
      return null;
    }
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

  /// 本地兜底热搜词（HOTWORDS 2026-11-20）。
  ///
  /// 只在 `/api/hotwords` 拉不到时用：宁可少、也要是「人人都在看」的片子。
  /// 这份表跟热播榜同一口径抄下来（爱奇艺 + 腾讯两边都在榜的），
  /// 所以不会再出现旧表里「已经是冷门片」的词。要改随版本发。
  static const List<String> defaultHotWords = <String>[
    '八仙',
    '空枪',
    '四渡',
    '哪吒之魔童闹海',
    '罗小黑战记',
    '蜘蛛侠：崭新之日',
    '伟大的长征',
    '功夫女足',
    '蒸蒸日上',
    '给阿嬷的情书',
    '捕风追影',
    '飞驰人生3',
  ];

  /// 热搜词：**跟着热播榜走**（HOTWORDS 2026-11-20）。
  ///
  /// 以前这里是「CMS 按点击量排的片名」，实测下发的是一张早就不会变的词表
  /// （八仙 / 繁华落尽第二季 / 空枪 / 大主宰年番 / 小城良方 / 穿普拉达的女王2 …），
  /// 里面混着已经下榜的冷门片。现在改成直接问服务端：
  ///   `GET /api/hotwords` → mac_hot_rank（爱奇艺 + 腾讯热播榜，每 3 小时刷新）
  ///   → 两平台都在榜的优先，其次按名次加权 → 前 12 个（服务端缓存 60 秒）。
  /// 拿不到（离线 / 5xx / 空列表）就回退 [defaultHotWords]，搜索页永远有词可点。
  static Future<List<String>> hotWords({int limit = 12}) async {
    _boot();
    final words = await Api.hotWords(limit: limit);
    if (words.isNotEmpty) {
      return words.take(limit).toList(growable: false);
    }
    return defaultHotWords.take(limit).toList(growable: false);
  }

  /* ------------------------------------------------------------ 排行榜 */

  /// 榜单：**服务端 `order=vod_hits&by=desc` 为主**，[_sortRank] 只做二次稳定
  /// 排序（同热度时按评分 / 更新时间兜底），不再自己造一套热度算法。
  ///
  /// HOT_ORDER（2026-11-15）：`order=` 现在真生效（热播榜脚本已把 `vod_hits`
  /// 写成 100.1 万~120 万，实测严格递减），所以排序交给服务端就够；
  /// 客户端那一层保留是为了「同分不跳」—— 榜单刷新时顺序不该乱动。
  /// [pages] 决定一次读几页样本 —— 日榜读 1 页、总榜读 8 页。
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
          CmsApi.list(type: t, page: p, sort: 'hot', src: CmsApi.ownSrc)
              .catchError(
            (Object e) {
              failure ??= e;
              return const <VideoCard>[];
            },
          ),
      ]);
      final out = <VideoCard>[];
      final seen = <String>{};
      for (final list in lists) {
        _markAll(list, CmsOrigin.cms);
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
    _markAll(legacy, CmsOrigin.legacy);
    return _sortRank(legacy);
  }

  /// 榜单二次排序：热度 → 评分 → 更新时间 → 年份。
  ///
  /// 服务端已经按 `vod_hits` 降序给了（主排序），这里只保证「同分不乱跳」：
  /// 稳定排序（同分保持服务端原序）。任何时候都
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

  /* -------------------------------------------------- 线路切片 id（LINE_SLICE） */

  /// 平台线路切片的卡片 id 前缀。
  ///
  /// LINE_SLICE（2026-11-15）：搜索会并行查「幻想爱奇艺 / 量子 / 红牛」这些
  /// **线路切片**（`?line=<线路名>`）。切片返回的是该线路自己的记录，其中
  /// 平台线（爱奇艺）用的是**切片空间的 vod_id** —— 实测 `济公传` 的
  /// `900000003` 只在 `?line=幻想爱奇艺&ac=detail&ids=900000003` 下存在，
  /// 拿掉 `line` 参数去主库查，服务端返回空列表，用户看到的就是
  /// 「搜索结果里有一条我们自己的记录，点进去必加载失败」。
  ///
  /// 修法：切片卡片保留线路名（编码进 id），详情 / 播放都带同一个 `line`
  /// 回同一个切片库；主库查得到时仍然走主库（`_sliceOf` 为 null 的普通 id）。
  static const String sliceMark = '@line:';

  /// 编码一张切片卡片的 id：`@line:幻想爱奇艺::900000003`。
  static String sliceId(String lineName, String vodId) {
    final name = lineName.trim();
    final id = vodId.trim();
    if (name.isEmpty || id.isEmpty) return id;
    return '$sliceMark$name::$id';
  }

  /// 拆出切片 id：返回 `(线路名, vod_id)`；不是切片 id 返回 null。
  static (String, String)? sliceOf(String id) {
    final raw = id.trim();
    if (!raw.startsWith(sliceMark)) return null;
    final rest = raw.substring(sliceMark.length);
    final at = rest.indexOf('::');
    if (at <= 0) return null;
    final line = rest.substring(0, at).trim();
    final vodId = rest.substring(at + 2).trim();
    if (line.isEmpty || vodId.isEmpty) return null;
    return (line, vodId);
  }

  /// 带切片 id 的调用：**主库优先，切片库兜底**。
  ///
  /// 切片记录的 id 有两种：量子 / 红牛这类切片给的是**主库真实 id**
  /// （主库能查到，而且线路更全），幻想爱奇艺这类平台线给的是**切片空间
  /// 的 id**（主库查不到）。所以顺序必须是「先主库、失败再带 line 参数」——
  /// 反过来（直接带 line）会让本来有 2 条线路的记录只剩切片那 1 条。
  static Future<T> _withSlice<T>(
    String id,
    Future<T> Function(String vodId) main,
    Future<T> Function(String vodId, String line) sliced,
  ) async {
    final slice = sliceOf(id);
    if (slice == null) return main(id);
    try {
      return await main(slice.$2);
    } catch (_) {
      return sliced(slice.$2, slice.$1);
    }
  }

  /// 去掉切片前缀后的裸 vod_id（历史 / 收藏 / 播放缓存都按它存）。
  static String bareIdOf(String id) {
    final slice = sliceOf(id);
    if (slice != null) return slice.$2;
    return SourceHub.rawIdOf(id);
  }

  /* ------------------------------------------------------------ 详情 */

  /// 详情：CMS `ac=detail&ids=<vod_id>` → [VideoDetail]（线路 / 选集 / 剧集
  /// 判断全部沿用 models.dart 的既有规则）。
  ///
  /// 已知来自旧接口的 id 直接走旧接口；来源未知的 id 先试 CMS，
  /// 失败再试旧接口 —— 两套编号不通用，所以不做「无脑互换」。
  /// [fresh] = true 时跳过主站的详情缓存（下拉刷新 / 重试用）：
  /// 线路变更、平台线路 `pending → ready`、集数补齐都只体现在新响应里，
  /// 命中旧快照就永远刷不出来。
  static Future<VideoDetail> detail(String id, {bool fresh = false}) async {
    _boot();
    final jar = await _jarSourceOf(id);
    if (jar != null) {
      return _jarGuard(
        jarLabelOf: SourceHub.jarLabelOf(jar),
        run: () async {
          final detail = await JarSpider.detail(
            api: jar.api,
            ext: jar.ext,
            vodId: SourceHub.rawIdOf(id),
          );
          return _withJarLines(detail, jar, SourceHub.rawIdOf(id));
        },
        wait: jarDetailTimeout,
      );
    }
    final external = await _externalSource(id);
    if (external != null) {
      final detail = await CmsClient.of(external.api).detail(
        SourceHub.rawIdOf(id),
      );
      _mark(id, CmsOrigin.cms);
      return detail;
    }
    final origin = _originOf(id);
    if (origin == CmsOrigin.legacy) return _legacyDetail(id);
    // 切片 id：先用主库查（多数切片 id 主库也有、线路更全），失败再带
    // line 参数去切片库查 —— 这正是「那一条点进去必失败」的修法。
    try {
      final detail = await _withSlice(
        id,
        (vodId) => CmsApi.detail(vodId, fresh: fresh),
        (vodId, line) => CmsApi.detail(vodId, fresh: fresh, line: line),
      );
      _mark(id, CmsOrigin.cms);
      return detail;
    } catch (e) {
      if (origin == CmsOrigin.unknown) {
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
    _mark(id, CmsOrigin.legacy);
    return detail;
  }

  /// 按「片名 + 年份」重新找一条记录：id 失效后的自愈入口（ID_RETRY）。
  ///
  /// 为什么需要：服务端刚做完去重合并（旧副本被并进主记录并删掉），App 的
  /// 历史 / 收藏里还存着已经不存在的 `vod_id`。详情 404 时先用这里重查，
  /// 查到就直接跳到新记录，而不是甩一句「该视频已失效」让用户自己重搜。
  ///
  /// 匹配规则：
  ///   · 片名归一化后必须完全一致（不做模糊，宁可不跳也不跳错片子）；
  ///   · 年份已知时优先同年的那条（翻拍版不会串）；
  ///   · 同名记录里只有年份未知的那一条时也认它（服务端年份常空着）；
  ///   · 一条都没有 → null，页面才显示「该视频已失效」。
  static Future<VideoCard?> findByTitle(String title, {int year = 0}) async {
    _boot();
    final name = title.trim();
    if (name.isEmpty) return null;
    final want = SourceHub.normTitle(name);
    if (want.isEmpty) return null;
    List<VideoCard> list;
    try {
      list = _withoutLive(await CmsApi.search(name, 1));
    } catch (_) {
      // 重查失败只是不能自愈，页面照常走「已失效」，不抛给调用方。
      return null;
    }
    if (list.isEmpty) return null;
    _markAll(list, CmsOrigin.cms);
    VideoCard? yearUnknown;
    for (final card in list) {
      if (SourceHub.normTitle(card.title) != want) continue;
      if (year > 0 && card.year == year) return card;
      if (year > 0 && card.year > 0) continue;
      yearUnknown ??= card;
    }
    return yearUnknown;
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
    // jar 源线路：**播放时现场解析**（playerContent），库里不存地址。
    final jarRef = fxParseJarLineId(line);
    if (jarRef != null) {
      final source = await _jarSourceByLabel(jarRef.label);
      if (source == null) {
        throw ApiException('${jarRef.label} 源已停用，换条线路试试');
      }
      return _jarGuard(
        jarLabelOf: jarRef.label,
        run: () => JarSpider.play(
          api: source.api,
          ext: source.ext,
          vodId: jarRef.vodId,
          lineName: jarRef.from,
          ep: ep,
        ),
      );
    }
    final external = await _externalSource(vodId);
    if (external != null) {
      final info = await CmsClient.of(external.api).play(
        SourceHub.rawIdOf(vodId),
        line,
        ep,
      );
      _mark(vodId, CmsOrigin.cms);
      return info;
    }
    final origin = _originOf(vodId);
    // DELEGACY（2026-11-15）：**只有明确来自旧接口的记录**才允许问 8787。
    //
    // 原来这里对「来源未知」的 id 还有一条回落：CMS 播放失败 → `Api.play`。
    // 那条路是起播卡死的直接原因之一：8787 上的 Node 服务根本不认识
    // 「幻想爱奇艺 / 量子 / 红牛 / SH4K」这批新线路，请求要么失败、要么挂到
    // 超时（8 秒 × 2 次重试），而用户在这十几秒里看到的就是「正在加载」
    // 一动不动；CMS 那边真正的原因（比如「该线路解析失败」）也被这条回落
    // 盖住了。CMS 的 vod_id 与旧接口的编号还是两套，拿 CMS id 去问 8787
    // 本来就不可能查对。
    //
    // 现在的规则：CMS 记录（含来源未知）**只走 CMS**，失败就把 CMS 的错误
    // 原样抛给页面；`Api.play` 只服务 `CmsOrigin.legacy`（历史遗留记录）。
    if (legacyPlayAllowed(legacyEnabled: legacyEnabled, origin: origin)) {
      fxPlayLog('line=$line source=legacy url=8787/api/play ep=$ep');
      return Api.play(vodId, ep, line, fresh: fresh);
    }
    final info = await _withSlice(
      vodId,
      (id) => CmsApi.playEpisode(id, line, ep),
      (id, sliceLine) => CmsApi.playEpisode(
        id,
        line,
        ep,
        sliceLine: sliceLine,
      ),
    );
    _mark(vodId, CmsOrigin.cms);
    return info;
  }

  /// 只要直链（下载 / 投屏 / 外挂播放）。
  static Future<String> playUrl(String vodId, String line, int ep) async {
    final jarRef = fxParseJarLineId(line);
    if (jarRef != null) {
      final info = await play(vodId, ep, line);
      return info.url;
    }
    final external = await _externalSource(vodId);
    if (external != null) {
      final info = await CmsClient.of(external.api).play(
        SourceHub.rawIdOf(vodId),
        line,
        ep,
      );
      return info.url;
    }
    // PLAY_URL 走同一条闸门：旧接口记录才问 8787，其它一律 CMS。
    if (legacyPlayAllowed(
      legacyEnabled: legacyEnabled,
      origin: _originOf(vodId),
    )) {
      return Api.play(vodId, ep, line).then((info) => info.url);
    }
    return _withSlice(
      vodId,
      (id) => CmsApi.playUrl(id, line, ep),
      (id, sliceLine) => CmsApi.playUrl(
        id,
        line,
        ep,
        sliceLine: sliceLine,
      ),
    );
  }

  /// 把站内相对地址补成绝对地址（播放 / 投屏 / 下载共用）。
  ///
  /// DELEGACY（2026-11-15）：根必须跟着**记录来源**走。
  /// `fxAbsolutePlayUrl` 原来只会补 `Api.base`（8787），CMS 记录一旦拿到
  /// 相对地址就会被补到旧后端宿主上 —— 地址看起来正常，实际 404，
  /// 用户看到的就是「一直正在加载」。CMS 记录一律补 CMS 站点根。
  static String absolutePlayUrl(String id, String url) =>
      fxAbsolutePlayUrl(url, root: isCms(id) ? CmsApi.root : Api.base);

  /// 这个 id 是不是 CMS 的 `vod_id`（详情页据此跳过旧接口的平台线路逻辑）。
  ///
  /// 老记录可能带 `@src:` 前缀，同样按 CMS 处理，
  /// 否则详情页会为它去查旧接口的平台线路。
  static bool isCms(String id) =>
      id.trim().startsWith(SourceHub.idMark) ||
      id.trim().startsWith(sliceMark) ||
      _originOf(id) == CmsOrigin.cms;

  /* ------------------------------------------------------ 详情超时预算 */

  /// **外部源详情**的单次上限：20 秒（DETAIL_TIMEOUT 2026-11-15）。
  ///
  /// 现场：点进外部源那条 → 整整 8 秒后直接报「该源暂不可用」。
  /// 8 秒从来不够 —— 外部源的详情接口自身带「3 次重试 + 500/1000/2000ms
  /// 退避」（光睡眠 3.5 秒），一次成功的详情经常落在 9～15 秒。这里给到 20 秒。
  static const Duration externalDetailTimeout = Duration(seconds: 20);

  /// 本站 CMS 详情的上限：保持 12 秒（它快，慢了就是真有问题）。
  static const Duration ownDetailTimeout = Duration(seconds: 12);

  /// 详情整条链的**页面级**总超时：外部源 20 秒 / 本站 12 秒。
  ///
  /// 页面用这个值包 `CmsBridge.detail`，保证「外部源有它自己的耐心」，
  /// 而本站源不会被拖到 20 秒 —— 用户点开站内片子还是 12 秒内出结果。
  static Duration detailTimeout(String id) =>
      isExternalId(id) ? externalDetailTimeout : ownDetailTimeout;

  /// 这个 id 是不是**外部源**（历史遗留的 `@src:` 记录）的 id。
  ///
  /// 外部源没有「本站线路」这个退路，页面文案和超时预算都要跟本站区别开。
  static bool isExternalId(String id) =>
      id.trim().startsWith(SourceHub.idMark);

  /// 外部源的展示名（咕噜 / 玩偶 / 自加源名）；本站记录或配置还没载入时
  /// 返回空串。页面把它拼进「<源名> 暂时没响应，换一个源试试」。
  static String externalLabelOf(String id) {
    if (!isExternalId(id)) return '';
    try {
      return SourceHub.instance.decodeSource(id)?.resultLabel ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 详情页「取不到」时的文案（按来源区分，SOURCE_TEXT 2026-11-15）。
  ///
  /// - 本站源：`该线路暂时取不到，换条线路试试` —— 用户手里还有别的线路；
  /// - 外部源：`<源名> 暂时没响应，换一个源试试` —— 用户手里还有别的源，
  ///   没有「本站线路」这回事。
  static String detailErrorText(String id, {String label = ''}) {
    if (!isExternalId(id)) return '该线路暂时取不到，换条线路试试';
    final who = label.trim().isEmpty ? externalLabelOf(id) : label.trim();
    return who.isEmpty
        ? '这个源暂时没响应，换一个源试试'
        : '$who 暂时没响应，换一个源试试';
  }

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
    // RES_LEARNED：把「播放器真正出过的分辨率」读回来（第三层缓存）。
    // 读不到就是空表，排序退回线路名推断，不影响任何流程。
    unawaited(LearnedResolution.load());
  }

  static final Map<String, CmsOrigin> _origins = <String, CmsOrigin>{};

  static const int _originLimit = 4000;

  static CmsOrigin _originOf(String id) => _origins[id.trim()] ?? CmsOrigin.unknown;

  static void _mark(String id, CmsOrigin origin) {
    final key = id.trim();
    if (key.isEmpty) return;
    if (_origins.length >= _originLimit && !_origins.containsKey(key)) {
      _origins.remove(_origins.keys.first);
    }
    _origins[key] = origin;
  }

  static void _markAll(List<VideoCard> cards, CmsOrigin origin) {
    for (final card in cards) {
      _mark(card.id, origin);
    }
  }

  static void _markIds(List<String> ids, CmsOrigin origin) {
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
    this.page = 1,
    this.source = '',
    this.status = SourceSearchStatus.ok,
    this.dropped = 0,
  });

  /// 这一批对应接口的第几页（1 起）。
  ///
  /// 为什么要带页码：一轮搜索里除了第 1 页，还会额外补一波「第 2 页」
  /// （见 searchStream 末尾）。页面如果只把 `_page` 记成 1，上拉时又会
  /// 请求一次第 2 页，同一批结果被追加两遍。页面用它把 `_page` 推进到
  /// 真实已经拿到的那一页。
  final int page;

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

  /// 这一批来自哪个源（只对外部源有意义：`咕噜` / `剧圈` / 自加源的短名）。
  ///
  /// JAR_PROGRESS（2026-11-15）：外部源是**一个源一批**地回来的，页面要能
  /// 说出「第 12 个源是哪个、它给了几条」，而不是只有一个总数。
  final String source;

  /// 这个源的结局（有结果 / 空 / 超时 / 出错）。页面进度条用它分类计数。
  final SourceSearchStatus status;

  /// 被相关性闸门丢掉的条数（外部源才有；日志里已经写过一行）。
  final int dropped;
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


/// 跨源去重的记账本：片名分桶 + 年份比对。
///
/// 年份未知（0）的那条只要同名片已经出现过就算重复；年份已知的按年份比，
/// 同名不同年（翻拍版）仍然各留一条。渐进检索要把这个账本一路带下去，
/// 每批都过一遍，才能保证「外部源结果」里不会冒出上面已经有的片子。
/// 搜索结果的跨批去重（渐进检索：一批一批来，去重必须跨批记住）。
///
/// DEDUPE_LINES（2026-11-15）：
///   · 身份 = 「片名（归一化） + 年份 + 片源分组」，同一身份只留一条；
///   · **片源分组为空的是通配**（线路切片 / 外部源 / 老数据）：它没有
///     `vod_from`，会并进同名的任一条片源记录里 —— 搜索「济公传」时
///     主库给的是 `济公传`（hx，2 条线路），`?line=幻想爱奇艺` 又给一条
///     `济公传`（无片源、1 条线路、切片 id 主库不认），合并后只留主库那条，
///     那条「点进去必失败」的重复记录就不会再占位置；
///   · 同名记录撞车时**保留线路多的那条**（`lineCount`），少的直接丢掉。
class _Dedupe {
  _Dedupe({this.byId = false});

  /// 身份 → 已收录的卡片（同一身份下按年份分开，翻拍剧不算重复）。
  final Map<String, List<VideoCard>> _seen = <String, List<VideoCard>>{};

  /// 按卡片 id 去重（跨源不合并）：一起看建房要列出「同一部片在各个源」。
  final bool byId;

  /// [perSource] = 这一批单独按 id 去重（不参与跨源片名合并）。
  bool fresh(VideoCard card, {bool perSource = false}) {
    if (byId || perSource) {
      final hit = _seen.putIfAbsent('id:${card.id}', () => <VideoCard>[]);
      if (hit.isNotEmpty) return false;
      hit.add(card);
      return true;
    }
    final title = SourceHub.normTitle(card.title);
    if (title.isEmpty) return true;
    final from = card.fromSource.trim();
    final wild = '$title|';
    final exact = '$title|$from';
    // 通配桶：同名的全部记录（不分片源分组），碰撞判定都用它。
    final all = _seen.putIfAbsent(wild, () => <VideoCard>[]);
    final mine = exact == wild ? all : _seen.putIfAbsent(exact, () => <VideoCard>[]);

    VideoCard? collide;
    for (final other in all) {
      final otherFrom = other.fromSource.trim();
      // 片源分组相同、或任一方为空（通配）才算同一条；
      // hx 与 xo 两条**不同片源**的记录要继续并存（SOURCE_SPLIT）。
      final sameFrom =
          otherFrom == from || otherFrom.isEmpty || from.isEmpty;
      if (!sameFrom) continue;
      // 年份都已知且不同 → 重拍 / 同名不同剧，不算重复；
      // 有一方年份未知就按同一条处理（宁可少一条，不留点不开的重复）。
      if (card.year > 0 && other.year > 0 && other.year != card.year) continue;
      collide = other;
      break;
    }
    if (collide == null) {
      all.add(card);
      if (exact != wild) mine.add(card);
      return true;
    }
    // 撞车：线路多的胜出（一样多时主库记录胜出，见 SourceHub.betterRecord）。
    // 新人更优 → 放行（页面按身份替换旧卡片，见 SearchPage._appendUnique），
    // 否则丢掉，列表里不再多出点不开的一条。
    if (SourceHub.betterRecord(card, collide)) {
      all.remove(collide);
      mine.remove(collide);
      all.add(card);
      if (exact != wild) mine.add(card);
      return true;
    }
    return false;
  }
}

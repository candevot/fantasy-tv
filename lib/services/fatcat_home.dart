/// 肥猫首页 / 分类（FATCAT_HOME，2026-11-15）。
///
/// 配置和「影视壳」对齐：**壳用肥猫首页 + 我们的搜索，App 也这样**。
/// 所以首页推荐、各分类页的内容全部来自肥猫那批 jar 源（TVBox type 3），
/// 我们自己的采集库只在搜索里出现；jar 没装 / 肥猫一个分区都没给的时候，
/// 回落我们自己热播内容的决定放在 cms_bridge 里做（这一层不认识 CMS，
/// 避免 cms_bridge ↔ fatcat_home 互相依赖）。
///
/// 这一层只做三件事：
///   1. **选源**：肥猫配置里靠前的可用 jar 源（咕噜 / 热播 / 下饭 / 快映 /
///      一起 优先），最多试 [fatcatMaxCandidates] 个 —— 41 个源全拉一遍，
///      首屏就死了；
///   2. **取数**：`homeContent` / `categoryContent`，每个源 8 秒超时，
///      [fatcatParallel] 路并行，谁先回谁先上屏；
///   3. **当日缓存**：同一天内复用，进首页不再重爬。
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import 'cms_client.dart' show channelKeyOfClassName;
import 'jar_spider.dart';
import 'source_hub.dart';

/// 首页最多铺几个分区（= 最多用几个源），避免一次拉太多源。
const int fatcatMaxSections = 6;

/// 每个分区最多多少条。
const int fatcatSectionLimit = 20;

/// 首屏同时拉几个源：并行发车，谁先回谁先渲染。
const int fatcatParallel = 4;

/// 单源超时：`JarSpider.timeout` 也是 8 秒，这里兜整个「取这个源」的过程
/// （homeContent 空 → 再拿它第一个分类），超时按「这个源没内容」处理。
const Duration fatcatTimeout = Duration(seconds: 8);

/// 一次最多试几个候选源。
const int fatcatMaxCandidates = 8;

/// banner 条数。
const int fatcatBannerCount = 5;

/// 肥猫里配置靠前的常用源：按这个顺序优先尝试。
///
/// 这几个在肥猫那份配置里排在最前面、首页内容也最全（咕噜 / 热播 / 下饭 /
/// 快映 / 一起），先把它们排进候选，剩下的 jar 源按配置顺序补位。
const List<String> fatcatPreferred = <String>[
  '咕噜',
  '热播',
  '下饭',
  '快映',
  '一起',
];

/// 首页的一份数据（流式：每个源回来就发一版）。
class FatcatFeed {
  const FatcatFeed({
    this.banners = const <BannerItem>[],
    this.sections = const <HomeSection>[],
    this.finished = false,
    this.fromCache = false,
  });

  /// 首个有内容的源的第一批（[fatcatBannerCount] 条）。
  final List<BannerItem> banners;

  /// 每个源一个分区，标题是源名。
  final List<HomeSection> sections;

  /// 所有源都结束了（这一版之后不会再有新分区）。
  final bool finished;

  /// 这一版来自本地缓存（页面可以少一次「刚加载」的跳动）。
  final bool fromCache;

  bool get hasContent => banners.isNotEmpty || sections.isNotEmpty;
}

/// 分类页的一页结果。
class FatcatCategory {
  const FatcatCategory(
    this.items, {
    this.hasMore = false,
    this.sources = 0,
  });

  final List<VideoCard> items;

  /// 有源这一页给满了 [fatcatSectionLimit] 条，后面大概率还有。
  final bool hasMore;

  /// 实际给了内容的源数（0 = 一个都没给，调用方据此回落）。
  final int sources;

  bool get hasContent => items.isNotEmpty;
}

/// 肥猫 jar 源的首页 / 分类数据层。
class FatcatHome {
  FatcatHome._();

  /// 当日缓存的键（`fx_fatcat_home_v1`）。
  static const String cacheKey = 'fx_fatcat_home_v1';

  /// 分类页缓存最多留几页（内存级）。
  static const int _categoryCacheLimit = 24;

  /* ------------------------------------------------ 单测注入点（生产默认值不变） */

  /// 候选源从哪来：默认问片源中心（肥猫那批 jar 源）。
  ///
  /// 单测把它换成固定几张源，就不用去动 SharedPreferences / 云端配置。
  static List<KSource> Function() poolProvider = _pool;

  /// 取一个源的首页内容：默认真的调 jar 通道（[JarSpider.home]）。
  static Future<List<VideoCard>> Function(KSource source) homeFetcher =
      _fetchHome;

  /// 取一个源的分类列表：默认真的调 jar 通道（`categoryContent`）。
  static Future<List<VideoCard>> Function(
    KSource source,
    String channelKey,
    int page,
  ) categoryFetcher = _fetchCategory;

  /// 把上面三个注入点恢复成默认实现（单测 `tearDown` 用）。
  static void resetFetchers() {
    poolProvider = _pool;
    homeFetcher = _fetchHome;
    categoryFetcher = _fetchCategory;
  }

  static FatcatFeed? _mem;
  static String _memDay = '';

  static final Map<String, FatcatCategory> _categoryCache =
      <String, FatcatCategory>{};
  static String _categoryDay = '';

  /* ------------------------------------------------------------ 选源 */

  /// 候选源：优先名单在前，其余按肥猫配置顺序补位（同一类 + ext 只留一次）。
  ///
  /// [pool] 只给单测用：传进来就用这份，不去问片源中心。
  static List<KSource> candidates({List<KSource>? pool}) {
    final all = pool ?? poolProvider();
    final ordered = <KSource>[];
    final taken = <String>{};
    for (final name in fatcatPreferred) {
      for (final source in all) {
        if (!source.name.contains(name)) continue;
        if (!taken.add(_sourceKey(source))) continue;
        ordered.add(source);
      }
    }
    for (final source in all) {
      if (!taken.add(_sourceKey(source))) continue;
      ordered.add(source);
    }
    return ordered;
  }

  /// 设备上能用的 jar 源：优先「肥猫」那批，没有就用全部 jar 源。
  static List<KSource> _pool() {
    final hub = SourceHub.instance;
    final bundled = <KSource>[
      for (final source in hub.bundledSources)
        if (source.kind == KSourceKind.jar && source.usable) source,
    ];
    if (bundled.isNotEmpty) return bundled;
    return <KSource>[
      for (final source in hub.querySources)
        if (source.kind == KSourceKind.jar) source,
    ];
  }

  /// jar 源的唯一键：类名 + ext（同一个类靠 ext 区分不同站点）。
  static String _sourceKey(KSource source) =>
      '${source.api.trim()}|${source.ext}';

  /* ------------------------------------------------------------ 卡片加工 */

  /// 把 jar 源给的卡片加工成能直接上首页 / 分类页的样子：
  ///
  ///   · id 编码成 `@src:<源key>::<vod_id>` —— 不编码的话点进详情 / 播放
  ///     就路由不回原来的 jar 源，直接「没有找到这部影片」；
  ///   · 来源标记换成源名（分区标题和卡片角标对得上）；
  ///   · 直播条目、空 id / 空片名丢掉。
  static List<VideoCard> prepare(KSource source, List<VideoCard> cards) {
    final out = <VideoCard>[];
    final seen = <String>{};
    for (final card in cards) {
      if (SourceHub.isLiveCard(card)) continue;
      if (card.id.trim().isEmpty || card.title.trim().isEmpty) continue;
      final id = SourceHub.encodeId(source.key, card.id);
      if (!seen.add(id)) continue;
      out.add(SourceHub.relabel(card, label: source.name, id: id));
    }
    return out;
  }

  /* ------------------------------------------------------------ 首页 */

  /// 首页推荐：并行拉前几个肥猫源，谁先回先发一版。
  ///
  /// 事件顺序：
  ///   1. 当日缓存（有就立刻给一版，首页不用等网络）；
  ///   2. 每个源回来一版 —— 分区按到达顺序追加 / 按源名原位替换；
  ///   3. `finished: true` 收尾。
  ///
  /// [force] 为 true 时跳过缓存（下拉刷新用）。
  static Stream<FatcatFeed> homeStream({bool force = false}) {
    final ctrl = StreamController<FatcatFeed>();
    final slots = <String, List<VideoCard>>{};
    final banners = <BannerItem>[];
    var bannerFromNetwork = false;
    var closed = false;
    var finished = false;
    var fromCache = false;
    Timer? guard;

    FatcatFeed snapshot({bool done = false, bool cached = false}) => FatcatFeed(
          banners: List<BannerItem>.unmodifiable(banners),
          sections: List<HomeSection>.unmodifiable(<HomeSection>[
            for (final entry in slots.entries)
              HomeSection(entry.key, entry.value),
          ]),
          finished: done,
          fromCache: cached,
        );

    void emit({bool done = false, bool cached = false}) {
      if (closed) return;
      ctrl.add(snapshot(done: done, cached: cached));
    }

    void finish() {
      if (closed || finished) return;
      finished = true;
      guard?.cancel();
      emit(done: true, cached: fromCache);
      closed = true;
      unawaited(ctrl.close());
    }

    void takeSection(KSource source, List<VideoCard> cards) {
      if (cards.isEmpty) return;
      if (slots.length >= fatcatMaxSections &&
          !slots.containsKey(source.name)) {
        return;
      }
      final items = cards.take(fatcatSectionLimit).toList();
      slots[source.name] = items;
      if (!bannerFromNetwork) {
        bannerFromNetwork = true;
        banners.clear();
        for (final card in items.take(fatcatBannerCount)) {
          banners.add(BannerItem(
            card.id,
            card.title,
            card.cover,
            card.desc,
            card.rating,
          ));
        }
      }
      emit();
    }

    Future<void> run() async {
      // 1) 内存里的当日缓存：直接给一版收尾，不再重爬。
      final hot = force ? null : memoryCache();
      if (hot != null && hot.hasContent) {
        for (final section in hot.sections) {
          slots[section.title] = section.items;
        }
        banners.addAll(hot.banners);
        fromCache = true;
        finish();
        return;
      }
      // 2) 冷启动：磁盘里的当日缓存先铺一版，网络结果回来再覆盖。
      if (!force) {
        final disk = await readDiskCache();
        if (closed) return;
        if (disk != null && disk.hasContent) {
          for (final section in disk.sections) {
            slots[section.title] = section.items;
          }
          banners.addAll(disk.banners);
          emit(cached: true);
        }
      }
      // 3) 并行拉源：4 路发车，谁先回谁先渲染，最多试 8 个候选。
      final list = candidates().take(fatcatMaxCandidates).toList();
      var next = 0;
      var landed = 0;

      Future<void> worker() async {
        while (true) {
          if (closed || landed >= fatcatMaxSections) return;
          final index = next++;
          if (index >= list.length) return;
          final source = list[index];
          final cards = await _guard(() => homeFetcher(source));
          if (closed) return;
          if (cards.isEmpty) continue;
          if (landed >= fatcatMaxSections && !slots.containsKey(source.name)) {
            return;
          }
          landed++;
          takeSection(source, cards);
        }
      }

      await Future.wait(<Future<void>>[
        for (var i = 0; i < fatcatParallel; i++) worker(),
      ]);
      if (closed) return;
      // 4) 收尾 + 写当日缓存（全空不写，别把一次失败缓存一整天）。
      final feed = snapshot(done: true);
      if (feed.hasContent) {
        _remember(feed);
        await writeDiskCache(feed);
      }
      finish();
    }

    ctrl.onCancel = () {
      closed = true;
      guard?.cancel();
    };
    unawaited(
      run().catchError((Object _) {
        // 任何一步炸了都要收尾：页面不能停在骨架屏。
        finish();
      }),
    );
    // 硬上限：8 路各 8 秒 + 排队，正常 16 秒内一定收工；这里再兜一层。
    guard = Timer(const Duration(seconds: 20), finish);
    return ctrl.stream;
  }

  /// 一个源的「首页内容」：`homeContent` 的 list；只给 class 的源退一步
  /// 拿它第一个分类当首页内容（TVBox 里这类源首页也是空的）。
  static Future<List<VideoCard>> _fetchHome(KSource source) async {
    Map<String, dynamic> body = const <String, dynamic>{};
    try {
      body = await JarSpider.home(api: source.api, ext: source.ext);
    } catch (_) {
      body = const <String, dynamic>{};
    }
    final cards = prepare(source, JarSpider.cardsOf(body));
    if (cards.isNotEmpty) return cards;
    return _firstClassCards(source);
  }

  static Future<List<VideoCard>> _firstClassCards(KSource source) async {
    final classes = await JarSpider.homeClasses(
      api: source.api,
      ext: source.ext,
    );
    for (final item in classes.take(3)) {
      if (item.name.contains('直播')) continue;
      final cards = await JarSpider.category(
        api: source.api,
        ext: source.ext,
        tid: item.tid,
        page: 1,
      );
      final ready = prepare(source, cards);
      if (ready.isNotEmpty) return ready;
    }
    return const <VideoCard>[];
  }

  /* ------------------------------------------------------------ 分类 */

  /// 分类页：肥猫源的同名分类（`categoryContent`），前几个源并行取。
  ///
  /// [channelKey] 是我们的频道键（movie / tv / anime / zongyi /
  /// duanju / kids）；空串表示「全部」，用每个源的第一个分类。
  static Future<FatcatCategory> category(
    String channelKey,
    int page, {
    bool force = false,
  }) async {
    final key = channelKey.trim();
    final slot = '$key|${page < 1 ? 1 : page}';
    if (!force) {
      final hit = _categoryCache[slot];
      if (hit != null && _categoryDay == dayKey(DateTime.now())) return hit;
    }
    final list = candidates().take(fatcatMaxSections).toList();
    final pages = await Future.wait(<Future<List<VideoCard>>>[
      for (final source in list)
        _guard(() => categoryFetcher(source, key, page < 1 ? 1 : page)),
    ]);

    final items = <VideoCard>[];
    final seen = <String>{};
    var hasMore = false;
    var sources = 0;
    for (final cards in pages) {
      if (cards.isEmpty) continue;
      sources++;
      if (cards.length >= fatcatSectionLimit) hasMore = true;
      for (final card in cards) {
        if (!seen.add(SourceHub.dedupeKey(card))) continue;
        items.add(card);
      }
    }
    final result = FatcatCategory(items, hasMore: hasMore, sources: sources);
    if (result.hasContent) {
      _categoryDay = dayKey(DateTime.now());
      if (_categoryCache.length >= _categoryCacheLimit) _categoryCache.clear();
      _categoryCache[slot] = result;
    }
    return result;
  }

  static Future<List<VideoCard>> _fetchCategory(
    KSource source,
    String channelKey,
    int page,
  ) async {
    final classes = await JarSpider.homeClasses(
      api: source.api,
      ext: source.ext,
    );
    final tid =
        channelKey.isEmpty ? _firstTid(classes) : _tidOf(classes, channelKey);
    if (tid.isEmpty) return const <VideoCard>[];
    final cards = await JarSpider.category(
      api: source.api,
      ext: source.ext,
      tid: tid,
      page: page,
    );
    return prepare(source, cards);
  }

  /// 我们的频道键 → 这个源自己的 `type_id`（认不出来返回空串）。
  static String _tidOf(List<JarClass> classes, String channelKey) {
    for (final item in classes) {
      if (channelKeyOfClassName(item.name) == channelKey) return item.tid;
    }
    return '';
  }

  static String _firstTid(List<JarClass> classes) {
    for (final item in classes) {
      if (item.name.contains('直播')) continue;
      return item.tid;
    }
    return '';
  }

  /// 取一个源的内容，失败 / 超时都算「这个源没内容」。
  static Future<List<VideoCard>> _guard(
    Future<List<VideoCard>> Function() task,
  ) async {
    try {
      return await task().timeout(
        fatcatTimeout,
        onTimeout: () => const <VideoCard>[],
      );
    } catch (_) {
      return const <VideoCard>[];
    }
  }

  /* ------------------------------------------------------------ 当日缓存 */

  /// 缓存的天：同一天内复用（`2026-11-15`）。
  static String dayKey(DateTime at) {
    final month = at.month.toString().padLeft(2, '0');
    final day = at.day.toString().padLeft(2, '0');
    return '${at.year}-$month-$day';
  }

  /// 内存里的当日首页（进首页时不用碰磁盘）。
  static FatcatFeed? memoryCache() =>
      _memDay == dayKey(DateTime.now()) ? _mem : null;

  static void _remember(FatcatFeed feed) {
    _memDay = dayKey(DateTime.now());
    _mem = feed;
  }

  /// 清掉缓存（片源变更 / jar 装好后重拉用）。
  static void clearCache() {
    _mem = null;
    _memDay = '';
    _categoryCache.clear();
    _categoryDay = '';
    unawaited(_dropDisk());
  }

  /// 连磁盘上的那份一起删掉：装好 jar 之后旧的「没内容」不能留着。
  static Future<void> _dropDisk() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(cacheKey);
    } catch (_) {
      // 删不掉也没关系，第二天自然过期。
    }
  }

  /// 读磁盘上的当日首页缓存；不是今天的 / 坏数据都返回 null。
  static Future<FatcatFeed?> readDiskCache() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(cacheKey);
      if (raw == null || raw.trim().isEmpty) return null;
      return decodeFeed(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  static Future<void> writeDiskCache(FatcatFeed feed) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(cacheKey, jsonEncode(encodeFeed(feed)));
    } catch (_) {
      // 写缓存失败不影响这一屏。
    }
  }

  /// 首页快照 → 可存的 JSON。
  static Map<String, dynamic> encodeFeed(FatcatFeed feed) => <String, dynamic>{
        'day': dayKey(DateTime.now()),
        'banners': <Map<String, dynamic>>[
          for (final banner in feed.banners)
            <String, dynamic>{
              'id': banner.id,
              'title': banner.title,
              'cover': banner.cover,
              'desc': banner.desc,
              'rating': banner.rating,
            },
        ],
        'sections': <Map<String, dynamic>>[
          for (final section in feed.sections)
            <String, dynamic>{
              'title': section.title,
              'items': <Map<String, dynamic>>[
                for (final card in section.items) cardJson(card),
              ],
            },
        ],
      };

  /// 存的 JSON → 首页快照；不是今天的直接当没有。
  static FatcatFeed? decodeFeed(Object? raw, {DateTime? now}) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    if (_text(map['day']) != dayKey(now ?? DateTime.now())) return null;
    final banners = <BannerItem>[];
    for (final entry in _listOf(map['banners'])) {
      if (entry is! Map) continue;
      final banner = Map<String, dynamic>.from(entry);
      final title = _text(banner['title']);
      if (title.isEmpty) continue;
      final rating = banner['rating'];
      banners.add(BannerItem(
        _text(banner['id']),
        title,
        _text(banner['cover']),
        _text(banner['desc']),
        rating is num ? rating : 0,
      ));
    }
    final sections = <HomeSection>[];
    for (final entry in _listOf(map['sections'])) {
      if (entry is! Map) continue;
      final section = Map<String, dynamic>.from(entry);
      final title = _text(section['title']);
      if (title.isEmpty) continue;
      final items = <VideoCard>[];
      for (final item in _listOf(section['items'])) {
        if (item is! Map) continue;
        try {
          final card = VideoCard.fromJson(Map<String, dynamic>.from(item));
          if (card.id.trim().isEmpty || card.title.trim().isEmpty) continue;
          items.add(card);
        } catch (_) {
          // 单条坏数据不影响整个分区。
        }
      }
      if (items.isEmpty) continue;
      sections.add(HomeSection(title, items));
    }
    if (banners.isEmpty && sections.isEmpty) return null;
    return FatcatFeed(
      banners: banners,
      sections: sections,
      finished: true,
      fromCache: true,
    );
  }

  /// 卡片 → 可存的 JSON（读回来走 [VideoCard.fromJson]）。
  static Map<String, dynamic> cardJson(VideoCard card) => <String, dynamic>{
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
        'rank': card.rank,
        'tags': card.tags,
        'sourceLabel': card.sourceLabel,
        'fromSource': card.fromSource,
      };

  static List<Object?> _listOf(Object? raw) =>
      raw is List ? raw : const <Object?>[];

  static String _text(Object? raw) {
    if (raw == null) return '';
    return raw.toString().trim();
  }
}

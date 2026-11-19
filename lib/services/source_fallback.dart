/// 播放失败后的三段降级 —— **第 2 / 3 段的执行层**（FX_FALLBACK，2026-11-15）。
///
/// 第 1 段（本片其他线路）一直是详情页在做（`_switchNextLine`）。这里补的是
/// 本片所有线路都播不了之后的两段：
///
/// ```
/// 第 2 段  同源其他版本  同片名 + 年份差 ≤1 的**另一条记录**
///                        （服务端把同一部剧按片源拆成 hx / xo 两条，各带自己的线路）
/// 第 3 段  跨源找同名    拿片名去外部源（肥猫的 jar 源 + 自加源）搜，命中就跳过去
/// ```
///
/// 三条硬约束：
///   · **只切一次**：`switched` 一旦为真就不再换（防止源之间来回跳成死循环）；
///   · **每个源只试一次**：`triedSources` 记已试过的源 key（第 3 段按它跳过）；
///   · **jar 没装 / 外部源不可用 → 跳过第 3 段**，直接给最终提示。
///
/// 匹配规则全部在 `fallback_match.dart`（纯判定，单测钉住）；这一层只管
/// 「查谁、按什么顺序查、取哪条线路」，不做模糊匹配。
library;

import '../models.dart';
import 'cms_bridge.dart';
import 'fallback_match.dart';
import 'play_log.dart';
import 'source_hub.dart';

/// 一条可换的目标：另一个源 / 另一条记录上的「同一集」。
class FxFallbackCandidate {
  const FxFallbackCandidate({
    required this.videoId,
    required this.title,
    required this.sourceName,
    required this.lineId,
    required this.lineName,
    required this.ep,
    required this.episodes,
    required this.level,
  });

  /// 目标记录的 id（外部源带 `@src:` 前缀，详情 / 播放按它路由）。
  final String videoId;
  final String title;

  /// 源显示名（「幻想」/「咕噜」…），用于 toast 与日志。
  final String sourceName;
  final String lineId;
  final String lineName;

  /// 对齐后的集号（与当前集号一致；对方集数不够时不会产生候选）。
  final int ep;

  /// 目标记录这一集的集数（用于进度夹取与提示）。
  final int episodes;

  /// 2 = 同源其他版本，3 = 跨源同名。
  final int level;

  @override
  String toString() =>
      'FxFallbackCandidate($level $sourceName $videoId ep=$ep/$episodes)';
}

/// 一次降级尝试的结果。
class FxFallbackOutcome {
  const FxFallbackOutcome({
    this.candidate,
    this.note = '',
    this.jarSkipped = false,
    this.reason = '',
  });

  /// 没找到（或不该换）时的空结果。
  const FxFallbackOutcome.miss({
    String note = '',
    bool jarSkipped = false,
    String reason = '',
  }) : this(
          note: note,
              reason: reason,
        );

  final FxFallbackCandidate? candidate;

  /// 需要透给用户的一句话（「该源只有 8 集」），没有就空串。
  final String note;

  /// 第 3 段因为 jar 没装被跳过了（页面据此跳过而不是装作查过）。
  final bool jarSkipped;

  /// 没命中的原因（写日志 / 排查用）。
  final String reason;

  bool get hit => candidate != null;
}

/// 外部源的一条命中：卡片 + 它属于哪个源（toast / 日志里的 `to=`）。
class FxExternalHit {
  const FxExternalHit({
    required this.card,
    required this.sourceName,
    required this.sourceKey,
    this.priority = 0,
  });

  final VideoCard card;
  final String sourceName;

  /// 源的优先序号（0 = 最优先）。第 3 段先查「咕噜」，其次才是别的源，
  /// 所以排序时 priority 先于年份差 —— 咕噜有同名就先用咕噜的。
  final int priority;

  /// 源的身份 key（jar 源是 `api|ext`，CMS 源是 `api`）：进 [triedSources]。
  final String sourceKey;

  @override
  String toString() => 'FxExternalHit($sourceName ${card.id})';
}

/// 一轮外部源检索的产出。
class FxExternalHits {
  const FxExternalHits({
    this.hits = const <FxExternalHit>[],
    this.jarSkipped = false,
    this.triedKeys = const <String>[],
    this.reason = '',
  });

  final List<FxExternalHit> hits;

  /// 有 jar 源但插件没装：第 3 段被跳过（页面要说清是「没装插件」）。
  final bool jarSkipped;

  /// 这一轮**查过**的源 key：进 [triedSources]，保证同一个源只查一次。
  final List<String> triedKeys;

  final String reason;
}

/// 一次播放会话的降级状态机：**跨源只切一次**，每个源只试一次。
///
/// 详情页在「本片线路全部失败」时调用 [find]，命中就整页换到目标记录；
/// 同一次播放会话里再次失败时 [switched] 已经为真，直接给最终提示。
class FxSourceFallback {
  /// 三个可注入的钩子都有默认实现（真的走网络）；单测用假的替身，
  /// 这样「换源决策」本身可以在没有网络的情况下逐条钉住。
  FxSourceFallback({
    required String title,
    required int year,
    required String currentId,
    required String sourceName,
    Future<List<VideoCard>> Function(String keyword)? searchOwn,
    Future<VideoDetail> Function(String id)? fetchDetail,
    Future<FxExternalHits> Function(String keyword, Set<String> tried)?
        searchExternal,
  })  : title = title.trim(),
        year = year,
        currentId = currentId.trim(),
        sourceName = sourceName.trim(),
        _searchOwn = searchOwn ?? _realSearchOwn,
        _fetchDetail = fetchDetail ?? _realFetchDetail,
        _searchExternal = searchExternal ?? _realExternalSearch;

  /// 第 2 段：查我们自己那批（主站采集库 + 幻想线路）。
  final Future<List<VideoCard>> Function(String keyword) _searchOwn;

  /// 拉一条候选记录的详情（挑线路 / 判断集数都靠它）。
  final Future<VideoDetail> Function(String id) _fetchDetail;

  /// 第 3 段：外部源检索。第二个参数是「已经试过的源 key」——
  /// 同一个源在一次播放会话里只查一次。
  final Future<FxExternalHits> Function(String keyword, Set<String> tried)
      _searchExternal;

  /// 片名 / 年份：第 2、3 段的搜索词与匹配基准。
  final String title;
  final int year;

  /// 当前这条记录的 id（第 2 段要把它排除掉）。
  final String currentId;

  /// 当前源显示名（日志里的 `from=`）。
  final String sourceName;

  /// 已经试过的源（外部源的 key：jar 源是 `api|ext`，CMS 源是 `api`）。
  ///
  /// 第 3 段只查不在集合里的源 —— 这是「不要在源之间来回跳」的硬保证。
  final Set<String> triedSources = <String>{};

  /// 已经试过的记录 id（第 2 段排除自己、也排除上次跳过去的那一条）。
  final Set<String> triedIds = <String>{};

  /// 已经跨源切过一次：再失败就不再切（防死循环）。
  bool switched = false;

  /// 单个源的检索超时（和搜索页一致：超时按「这个源没结果」算）。
  static const Duration sourceTimeout = SourceHub.sourceTimeout;

  /// 第 3 段最多查几个「优先源」（咕噜那一类）。正常情况下就是 1 个。
  static const int maxPreferredSources = 1;

  /// 优先源没命中时，按配置顺序最多再补几个外部源。
  ///
  /// 不按 41 个源的顺序挨个试：用户已经等了一轮换线路，跨源这一轮必须快。
  /// 1 + 2 = 3 个源、每个 8 秒超时，最坏也就二十几秒，并且是并行发。
  static const int maxExtraSources = 2;

  /// 一轮外部检索最多几个源（兜底上限，防止配置异常时把源全拉起来）。
  static const int maxExternalSources = 3;

  /// 最多给几条命中结果拉详情（详情是逐个串行的，串太多就慢）。
  static const int maxDetailProbes = 4;

  /// 找一条能接着播的目标。
  ///
  /// [ep] 是当前集号（换源后必须还是这一集）；
  /// [position] 是当前进度（秒），只用于日志与进度接续的判断。
  Future<FxFallbackOutcome> find({
    required int ep,
    double position = 0,
  }) async {
    if (title.isEmpty) {
      return const FxFallbackOutcome.miss(reason: 'no_title');
    }
    if (ep < 1) {
      return const FxFallbackOutcome.miss(reason: 'bad_ep');
    }
    if (switched) {
      return const FxFallbackOutcome.miss(reason: 'already_switched');
    }
    if (currentId.isNotEmpty) triedIds.add(currentId);

    // 第 2 段：同一个库里同片名的另一条记录。
    final own = await _findOwn(ep: ep);
    if (own.hit) {
      switched = true;
      return own;
    }
    // 没命中也要留痕：真机上「为什么没换源」只能靠这两行日志回答。
    fxPlayLog(
      fxFallbackSkipLog(
        level: 2,
        from: sourceName,
        reason: own.reason.isEmpty ? 'no_match' : own.reason,
      ),
    );

    // 第 3 段：外部源（jar / 自加）。
    final external = await _findExternal(ep: ep);
    if (external.hit) {
      switched = true;
      return external;
    }
    if (!external.jarSkipped) {
      fxPlayLog(
        fxFallbackSkipLog(
          level: 3,
          from: sourceName,
          reason: external.reason.isEmpty ? 'no_match' : external.reason,
        ),
      );
    }
    return FxFallbackOutcome.miss(
      note: own.note.isNotEmpty ? own.note : external.note,
      jarSkipped: external.jarSkipped,
      reason: external.reason.isEmpty ? 'no_match' : external.reason,
    );
  }

  /* -------------------------------------------------------- 第 2 段：同源 */

  /// 第 2 段：同片名 + 年份差 ≤1 的**另一条记录**。
  Future<FxFallbackOutcome> _findOwn({required int ep}) async {
    List<VideoCard> cards;
    try {
      cards = await _searchOwn(title).timeout(
        const Duration(seconds: 8),
        onTimeout: () => const <VideoCard>[],
      );
    } catch (_) {
      return const FxFallbackOutcome.miss(reason: 'own_search_failed');
    }
    var note = '';
    final matches = <VideoCard>[];
    for (final card in cards) {
      if (card.id.trim().isEmpty) continue;
      if (triedIds.contains(card.id.trim())) continue;
      if (SourceHub.isLiveCard(card)) continue;
      if (!fxSameTitle(card.title, title)) continue;
      if (fxIsExtraClip(card.title)) continue;
      if (!fxYearCompatible(year, card.year)) continue;
      matches.add(card);
    }
    if (matches.isEmpty) return const FxFallbackOutcome.miss(reason: 'own_empty');
    // 同年优先，其次集数够的（集数未知的排中间）。
    matches.sort((a, b) {
      final ga = fxYearGap(year, a.year);
      final gb = fxYearGap(year, b.year);
      final ra = ga < 0 ? 1 : ga;
      final rb = gb < 0 ? 1 : gb;
      return ra.compareTo(rb);
    });
    var probed = 0;
    for (final card in matches) {
      // 拉详情是串行的（每次都可能 12 秒），同源这一轮最多探 4 条，
      // 否则一条片名下挂十条记录时，用户要对着「正在尝试其他源」等一分多钟。
      if (probed >= maxDetailProbes) break;
      probed++;
      final probe = await _plan(
        id: card.id.trim(),
        cardTitle: card.title,
        sourceName: KSource.ownResultLabel,
        ep: ep,
        level: 2,
      );
      if (probe.candidate != null) {
        final hit = probe.candidate!;
        fxPlayLog(fxFallbackLog(level: 2, from: sourceName, to: hit.sourceName));
        return probe;
      }
      if (probe.note.isNotEmpty) note = probe.note;
    }
    return FxFallbackOutcome.miss(
      note: note,
      reason: 'own_no_playable_line',
    );
  }

  /* -------------------------------------------------------- 第 3 段：跨源 */

  /// 第 3 段：外部源里找同名（接入层已拆，正常恒为「没有外部源」）。
  Future<FxFallbackOutcome> _findExternal({required int ep}) async {
    FxExternalHits found;
    try {
      found = await _searchExternal(title, triedSources).timeout(
        sourceTimeout * maxExternalSources,
        onTimeout: () => const FxExternalHits(reason: 'external_timeout'),
      );
    } catch (_) {
      return const FxFallbackOutcome.miss(reason: 'external_failed');
    }
    // 这一轮查过的源记进 triedSources：下一轮（同一次播放会话里）不会再查。
    for (final key in found.triedKeys) {
      triedSources.add(key);
    }
    if (found.hits.isEmpty) {
      return FxFallbackOutcome.miss(
        // jarSkipped 由检索层上报（老记录可能带 jar 源、但这些源已不再接入）。
        jarSkipped: found.jarSkipped,
        reason: found.reason.isEmpty ? 'external_empty' : found.reason,
      );
    }

    final picks = <FxExternalHit>[];
    for (final hit in found.hits) {
      final card = hit.card;
      if (card.id.trim().isEmpty) continue;
      if (triedIds.contains(card.id.trim())) continue;
      if (SourceHub.isLiveCard(card)) continue;
      if (!fxSameTitle(card.title, title)) continue;
      if (fxIsExtraClip(card.title)) continue;
      if (!fxYearCompatible(year, card.year)) continue;
      picks.add(hit);
    }
    if (picks.isEmpty) {
      return FxFallbackOutcome.miss(
          reason: 'external_empty',
      );
    }
    // 源优先级先于年份差：咕噜（priority 0）有同名就先用咕噜的。
    picks.sort((a, b) {
      if (a.priority != b.priority) return a.priority.compareTo(b.priority);
      final ga = fxYearGap(year, a.card.year);
      final gb = fxYearGap(year, b.card.year);
      final ra = ga < 0 ? 1 : ga;
      final rb = gb < 0 ? 1 : gb;
      return ra.compareTo(rb);
    });

    var note = '';
    var probed = 0;
    for (final hit in picks) {
      if (probed >= maxDetailProbes) break;
      probed++;
      final probe = await _plan(
        id: hit.card.id.trim(),
        cardTitle: hit.card.title,
        sourceName: hit.sourceName,
        ep: ep,
        level: 3,
      );
      // 逐源留痕：`fallback source=咕噜 hit=true/false`。
      fxPlayLog(
        fxFallbackSourceLog(
          source: hit.sourceName,
          hit: probe.candidate != null,
        ),
      );
      if (probe.candidate != null) {
        final got = probe.candidate!;
        fxPlayLog(fxFallbackLog(level: 3, from: sourceName, to: got.sourceName));
        return probe;
      }
      if (probe.note.isNotEmpty) note = probe.note;
    }
    return FxFallbackOutcome.miss(
      note: note,
      reason: 'external_no_playable_line',
    );
  }

  /* ------------------------------------------------ 第 3 段的真实实现（网络） */

  /// 真的去查外部源：一轮最多 [maxExternalSources] 个，每个 8 秒超时。
  static Future<FxExternalHits> _realExternalSearch(
    String keyword,
    Set<String> tried,
  ) async {
    final hub = SourceHub.instance;
    try {
      await hub.ensureReady().timeout(const Duration(seconds: 3));
    } catch (_) {
      // 索引坏了也照样能查外部源；只是可能少几个。
    }
    final plan = hub.searchPlan;
    // 外部源接入层已经整层拆掉：第 3 段没有可查的源，如实上报「没有外部源」，
    // 页面据此给「所有线路都试过了」的最终提示。
    final usable = <KSource>[];
    for (final source in plan.external) {
      // 这个源上一轮已经查过了：不再查第二遍（「不要在源之间来回跳」）。
      if (tried.contains(sourceKeyOf(source))) continue;
      usable.add(source);
    }
    if (usable.isEmpty) {
      return const FxExternalHits(reason: 'no_external_source');
    }

    // 顺序：**先查「咕噜」**（内容最全、速度也快），咕噜没有 / 失败再按配置
    // 顺序最多补 2 个别的外部源。不按 41 个源的顺序挨个试 —— 那是搜索页的活，
    // 换源要的是「尽快找到一部能播的同名片」。
    final preferred = <KSource>[
      for (final source in usable)
        if (fxIsPreferredSource(source.resultLabel) ||
            fxIsPreferredSource(source.shortName))
          source,
    ].take(maxPreferredSources).toList(growable: false);
    final others = <KSource>[
      for (final source in usable)
        if (!preferred.contains(source)) source,
    ].take(maxExtraSources).toList(growable: false);
    final queue = <KSource>[...preferred, ...others]
        .take(maxExternalSources)
        .toList(growable: false);
    if (queue.isEmpty) {
      return const FxExternalHits(reason: 'no_external_source');
    }

    // 并行查这一轮（每个源自己 8 秒超时），全部回来后统一交给上层挑；
    // 上层按 priority（咕噜在前）再排一次。
    final lists = await Future.wait(<Future<List<VideoCard>>>[
      for (final source in queue)
        hub
            .searchPrepared(source, keyword, 1)
            .timeout(sourceTimeout, onTimeout: () => const <VideoCard>[])
            .catchError((Object _) => const <VideoCard>[]),
    ]);
    final hits = <FxExternalHit>[];
    for (var i = 0; i < queue.length && i < lists.length; i++) {
      final source = queue[i];
      for (final card in lists[i]) {
        hits.add(
          FxExternalHit(
            card: card,
            sourceName: sourceLabelOf(card, source),
            sourceKey: sourceKeyOf(source),
            priority: i,
          ),
        );
      }
    }
    return FxExternalHits(
      hits: hits,
      triedKeys: <String>[for (final source in queue) sourceKeyOf(source)],
    );
  }

  /* ------------------------------------------------------------ 记录探针 */

  /// 给一条候选记录挑一条能播的线路，凑成可换的目标。
  ///
  /// 集数不够（对方只有 8 集、当前第 12 集）直接放弃这条记录并带出
  /// 「该源只有 8 集」的提示 —— 不把用户丢回第 1 集。
  Future<FxFallbackOutcome> _plan({
    required String id,
    required String cardTitle,
    required String sourceName,
    required int ep,
    required int level,
  }) async {
    VideoDetail detail;
    try {
      // 外部 jar 源自己还有 8 秒 guard；这里再加一层，别让一次降级挂太久。
      detail = await _fetchDetail(id).timeout(const Duration(seconds: 12));
    } catch (_) {
      return const FxFallbackOutcome.miss(reason: 'detail_failed');
    }
    final episodes = _epCountOf(detail);
    final aligned = fxFallbackEp(wantEp: ep, availableEps: episodes);
    if (aligned < 1) {
      return FxFallbackOutcome.miss(
        note: fxFallbackShortEpText(episodes),
        reason: 'short_episodes',
      );
    }
    final line = _pickLine(detail, aligned);
    if (line == null) {
      return const FxFallbackOutcome.miss(reason: 'no_line');
    }
    triedIds.add(id);
    return FxFallbackOutcome(
      candidate: FxFallbackCandidate(
        videoId: id,
        title: detail.title.trim().isEmpty ? cardTitle : detail.title.trim(),
        sourceName: sourceName,
        lineId: line.id,
        lineName: line.displayName,
        ep: aligned,
        episodes: episodes,
        level: level,
      ),
    );
  }

  /// 目标记录的集数（服务端声明 / 各线路集名数 / 剧集列表取最大）。
  int _epCountOf(VideoDetail detail) => fxEpisodeCount(
        declared: detail.episodes,
        lineCounts: <int>[for (final line in detail.lines) line.epNames.length],
        episodeListCount: detail.allEpisodes.length,
      );

  /// 挑一条能播第 [ep] 集的线路（口径见 [fxPickLineIndex]，由单测钉住）。
  LineInfo? _pickLine(VideoDetail detail, int ep) {
    final probes = <FxLineProbe>[
      for (final line in detail.lines)
        FxLineProbe(
          id: line.id,
          type: line.type,
          degraded: line.degraded,
          epCount: line.epNames.length,
        ),
    ];
    final index = fxPickLineIndex(probes, ep);
    if (index < 0) return null;
    return detail.lines[index];
  }

  /// 默认的第 2 段检索：主站采集库 + 幻想线路（`CmsBridge.searchOwn`）。
  static Future<List<VideoCard>> _realSearchOwn(String keyword) =>
      CmsBridge.searchOwn(keyword, 1);

  /// 默认的详情拉取：`@src:` 前缀的 id 会自动路由到它自己的源。
  static Future<VideoDetail> _realFetchDetail(String id) =>
      CmsBridge.detail(id);

  /// 源的身份 key（与 [SourceHub.searchPlan] 的去重口径一致）。
  static String sourceKeyOf(KSource source) => source.api.trim();

  /// 卡片上要显示的源名：优先用卡片自己的来源标注，其次源对象的名字。
  static String sourceLabelOf(VideoCard card, KSource source) {
    final label = card.sourceLabel.trim();
    if (label.isNotEmpty) return label;
    final name = source.resultLabel.trim();
    return name.isEmpty ? source.shortName : name;
  }
}

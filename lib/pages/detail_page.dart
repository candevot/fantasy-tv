import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../main.dart' show Nav;
import '../models.dart';
import '../services/cms_bridge.dart';
import '../services/download_service.dart';
import '../services/jar_sources.dart';
import '../services/fallback_match.dart';
import '../services/fx_player.dart';
import '../services/line_enrich.dart';
import '../services/line_fallback_order.dart';
import '../services/line_health.dart';
import '../services/play_log.dart';
import '../services/play_path.dart';
import '../services/source_fallback.dart';
import '../services/source_hub.dart';
import '../services/fx_video_geometry.dart';
import '../widgets/detail_widgets.dart';
import '../widgets/fx_cards.dart' show FxCover, FxSkeletonPulse;
import '../widgets/fx_line_group_selector.dart';
import '../widgets/download_sheet.dart';
import '../widgets/player_theme.dart';
import 'category_page.dart'
    show FxEmptyView, FxErrorView, FxPosterCard, fxErrorText, fxInt, fxStr;
import 'feedback_page.dart' show FeedbackPage;
import 'history_page.dart' show FxStore;
import 'offline_player_page.dart';
import 'player_page.dart';
import 'together_page.dart' show TogetherExitResult;
import '../utils/fx_route.dart';

/// 详情播放页：顶部内嵌 PlayerView（自动播放当前线路当前集），
/// 下方「视频 / 评论」双 Tab、公告、简介、5 圆钮、线路、选集、相关推荐。
class DetailPage extends StatefulWidget {
  const DetailPage({
    super.key,
    required this.id,
    this.ep = 1,
    this.line = '',
    this.title = '',
    this.year = 0,
    this.cover = '',
    this.sourceLabel = '',
    this.retried = false,
    this.startSeconds,
    this.fallbackHops = 0,
    this.onInvalid,
  });

  final String id;
  final int ep;
  final String line;

  /// 片名 / 年份（ID_RETRY 2026-11-15）。
  ///
  /// 服务端去重合并后旧 `vod_id` 会失效，详情 404 时要靠「片名 + 年份」重查
  /// 一次而不是直接报「该视频已失效」。入口能带就带上（搜索结果、历史、
  /// 收藏都带）；没带时详情页会退回本地缓存记录里的片名/年份。
  final String title;
  final int year;

  /// 搜索阶段已经知道的封面（DETAIL_SKELETON 2026-11-15）。
  ///
  /// 外部源的详情接口要握手 + 重试，第一次成功经常在 9～15 秒。
  /// 这段时间里页面原来是一整块转圈的白/黑屏；把搜索结果里的封面带进来，
  /// 首帧就能画出「海报 + 片名 + 骨架」，用户不会以为页面死了。
  final String cover;

  /// 搜索阶段那条记录的来源名（咕噜 / 玩偶 / 幻想 …）。
  ///
  /// SOURCE_TEXT（2026-11-15）：外部源失败时文案要说「<源名> 暂时没响应，
  /// 换一个源试试」——「换本站线路试试」在肥猫的片子上是不成立的。
  final String sourceLabel;

  /// 已经按片名重查过一次（换到新记录的那个页面不再重查，避免来回跳）。
  final bool retried;

  /// 起播位置（秒），null = 按本地保存的进度续播。
  ///
  /// FX_FALLBACK（2026-11-15）：跨源换源会 pushReplacement 到这个页面打开
  /// **另一条记录**；当前集号由 [ep] 带入，播放进度由它带入 ——
  /// 「第 5 集看到 12:34，换源后还是第 5 集 12:34」。
  final double? startSeconds;

  /// 这条记录被判定失效时回调一次（参数是进入页面时的 id）。
  ///
  /// DEAD_CARD（2026-11-15）：搜索结果里可能混进一条打不开的记录（空壳 /
  /// 服务端已删），详情页确认失效后要告诉来源页把它摘掉 —— 否则它会一直
  /// 占着位置，用户下次还会点到。只在 [id] 上生效，不涉及导航。
  final ValueChanged<String>? onInvalid;

  /// 这次页面是「跨源换源」跳过来的第几次（FX_FALLBACK）。
  ///
  /// 只切一次：跳到目标记录时 +1，超过 [fxFallbackMaxHops] 时那条记录的
  /// 线路也全失败就直接给最终提示，不会继续 A → B → C 地跳。
  final int fallbackHops;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage>
    with SingleTickerProviderStateMixin {
  final GlobalKey<PlayerViewState> _playerKey = GlobalKey<PlayerViewState>();

  /// 内嵌播放画面的真实宽高比（默认 16:9，页面自绘的黑色留边即它的高度差）。
  ///
  /// 见 [fxPlayerStageHeight]：1920×800 的电影容器收窄、1080×1920 的竖屏
  /// 短剧停在 16:9 高度左右留黑 —— 都不再被硬拉成 16:9。
  double _videoAspect = kFxFallbackVideoAspect;
  final ScrollController _scroll = ScrollController();
  late final AnimationController _fade;

  VideoDetail? _detail;
  String? _error;

  int _tab = 0;
  int _ep = 1;
  String _lineId = '';
  bool _descOpen = false;
  bool _fav = false;
  bool _openingTogether = false;
  bool _openingRelated = false;
  int _autoLineTries = 0;
  int _relatedOffset = 0;

  /// 详情请求序号：晚到的旧响应不许覆盖新数据（下拉刷新 / 重试 / 补线并发）。
  int _detailReq = 0;

  /// 选集分组下标（正片 / 花絮 …）；切换分组只影响下方横滑列表。
  int _groupIndex = 0;

  /// 播放器正在切线路：禁用线路卡片，避免重复点击并发 open。
  bool _playerSwitchingLine = false;

  /// 真正播放成功后才允许回写历史集数/进度；只打开详情页不算。
  bool _played = false;

  /// 服务端 `related` 只有 id，按 id 补出来的「猜你喜欢」卡片。
  List<VideoCard> _related = const <VideoCard>[];
  bool _relatedLoading = false;
  bool _relatedFetched = false;

  /// 本轮自动切线路已经失败过的线路，避免 A/B 反复乒乓。
  final Set<String> _failedLines = <String>{};

  /// 这部片是 CMS（`vod_id`）还是旧接口的 id。
  ///
  /// CMS 的内容没有「服务端异步补算的平台线路」，也不该再去调旧接口的
  /// `resolveLine` / 反复重拉详情，所以平台线路那一整套逻辑按这个开关跳过；
  /// 采集线路的解析改由 [_ensureParsed] 现场做（hxparse）。
  bool _cmsBacked = false;

  /// 已经在原线路上重试过的线路 id：第一次失败先原线重试一次
  /// （带缓冲态），重试单独计数、不占 _autoLineTries 的换线预算；
  /// 重试仍失败才记入 _failedLines 换下一条。稳定播放后清零。
  String? _retriedLine;

  /// 稳定播放 3 秒后才清零重试预算与失败集合。
  Timer? _stableTimer;

  /// CHAIN_WATCHDOG（2026-11-15）：自动换线链的哨兵。
  ///
  /// 用户实测「失败直接显示错误页，不往下一线路走」。除了播放器自己把
  /// 「播放中断」当终点（已修），详情页这边还有一个真实缺口：
  /// 第一次失败走的是「原线重试」（`player.reload()`），而 reload 有多条
  /// 早退（正在切线路 / 已把全部线路试完 / 被新的 open 取代）—— 任何一条
  /// 都会让这次「重试」变成什么都没发生，`_retriedLine` 却已经被占掉，
  /// 于是既不会再重试，也不会进入换线路 → 停在错误页。
  ///
  /// 哨兵的作用只有一句：**5 秒后还在错误层、而且没有任何一轮在跑，
  /// 就直接把整轮线路轮起来**。宁可多试一次，也不能让用户对着死页面。
  Timer? _lineChainWatchdog;

  /// 服务端平台线路是异步计算的：首屏没有平台线时，2.5 秒后再拉一次
  /// /api/detail 把平台线补上，最多补 2 次；只合并 lines，不重载页面、
  /// 不重建播放器。补线期间线路区一直占着固定高度，布局不跳动。
  Timer? _lineRefreshTimer;
  int _lineRefreshTries = 0;

  /// jar 源子线路合并是否正在进行（防重入）。
  bool _jarMerging = false;

  /// JAR_PENDING（2026-11-22）：咕噜大类正在「加载中」占位。
  ///
  /// 进详情页时 jar 就绪 → 这部片在咕噜里有没有还得异步搜一次（几百毫秒到
  /// 十几秒）。这段时间第一行先按 `咕噜 · 加载中` 占位（顺序固定咕噜在前），
  /// 拿到线路原地填充；没拿到就整条消失、回落到幻想。
  bool _jarPending = false;

  /// 已经跑过一轮 jar 合并（成功 / 空都算）：刷新详情时不再重复挂占位。
  bool _jarMergeDone = false;

  /// JAR_SINGLE_OPEN（2026-11-22）：等咕噜线路到齐再起播。
  ///
  /// 用户实测「点进去自动播放会加载两下，然后 0 KB 不动，手点刷新才播」。
  /// 两次加载来自这里：播放器一挂上就 bootstrap **自有线路**（幻想4K…），
  /// 等 jar 合并完再把默认线路改成咕噜，播放器又切一次 —— 第二次起播正好
  /// 赶在第一次的销毁/接管窗口里，落成 0 KB。
  ///
  /// 现在 jar 可用且还没合并完时，播放区先显示占位（最多 [_jarBootWaitMs]），
  /// 合并一结束就带着咕噜线路**只起播一次**。jar 不可用时一行都不等。

  /// 用户亲手点过线路：之后到达的 jar 线路**不许**再改默认选中。
  bool _linePickedByUser = false;

  /// 占位的兜底计时器：jar 源再慢也不能让「加载中」一直转。
  Timer? _jarPendingTimer;

  /// 见 [_jarBootWait] 的注释；超时回落自有线路，绝不把播放卡死在这里。
  bool _jarBootWait = false;
  Timer? _jarBootWaitTimer;

  /// 等 jar 线路的最长时间：jar 搜索一般 1~3 秒，超过就直接用自有线路起播。
  static const int _jarBootWaitMs = 2600;

  /// 上一次看到的「jar 已就绪」状态：false → true 那一刻要补一次 jar 线路
  /// （JAR_BOOT 2026-11-21：冷启动边装边用，装好的时候详情页可能已经开着）。
  bool _jarWasReady = false;

  /// 上一次看到的「jar 缺插件」状态：只有它变了才 setState（提示条显隐），
  /// 免得片源中心每通知一次都整页重绘。
  bool _jarMissingShown = false;

  /// PLATFORM_PENDING：平台线路永远显示，解析在后台进行。
  /// 正在现场解析的线路 id（同一条只发一次请求）。
  final Set<String> _resolvingLines = <String>{};

  /// 详情页进入后已经自动触发过后台解析的平台线，避免来回切页重复打服务端。
  final Set<String> _autoResolved = <String>{};

  /// 平台线补线的节奏：服务端匹配窗口 2.5 秒，两次重试足够等到结果。
  static const int _lineRefreshMax = 2;
  static const Duration _lineRefreshDelay = Duration(milliseconds: 2500);

  /// 作品已被服务端删除 / 下架：首屏拿到 404「作品不存在」时，
  /// 给友好提示 + 删除这条历史记录的入口，不再走通用错误页的重试。
  bool _invalid = false;

  /// 正在按「片名 + 年份」重查（ID_RETRY）：同一时刻只查一次。
  bool _retrying = false;

  /// 这次加载已经自动重试过一次（DETAIL_RETRY 2026-11-15）。
  ///
  /// 用户实测「点进咕噜那条直接就是错误页，得自己点重试才有结果」——
  /// 一次超时不该让用户看到一个错误页。规则：**超时 / 网络类失败自动再试
  /// 一次**（第二次跳过详情缓存），仍然失败才把错误页交出去；
  /// 手点「重试」/ 下拉刷新会把额度重新充满。
  bool _autoRetried = false;

  /// 自动重试前的间隔：给握手 / 上一次未收尾的通道调用留一点时间。
  static const Duration _autoRetryDelay = Duration(milliseconds: 400);

  /// 来源名：入口带进来的优先，没有就按 id 从片源表里查。
  ///
  /// SOURCE_TEXT（2026-11-15）：外部源失败文案需要它。
  String get _sourceName {
    final seeded = widget.sourceLabel.trim();
    if (seeded.isNotEmpty) return seeded;
    return CmsBridge.externalLabelOf(widget.id);
  }

  List<CommentItem> _comments = const <CommentItem>[];
  final Set<String> _liked = <String>{};
  bool _commentsLoading = false;
  bool _commentsLoaded = false;
  bool _commentsHasMore = true;
  int _commentPage = 0;
  String? _commentError;

  /// 下载队列变化时刷新选集上的「已下载」标记。
  final DownloadService _downloads = DownloadService.instance;

  @override
  void initState() {
    super.initState();
    _ep = widget.ep <= 0 ? 1 : widget.ep;
    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: 1,
    );
    _downloads.addListener(_onDownloadsChanged);
    unawaited(_downloads.init());
    // JAR_BOOT：进页面就问一次 jar 状态（幂等、只读），并监听「装好了」那一刻。
    _jarWasReady = SourceHub.instance.jarReady;
    _jarMissingShown = SourceHub.instance.jarMissing;
    SourceHub.instance.addListener(_onHubChanged);
    unawaited(SourceHub.instance.ensureJarStatus());
    _init();
  }

  void _onDownloadsChanged() {
    if (mounted) setState(() {});
  }

  /// jar 插件状态变化：从「未装」翻到「已装」时**现场补一次 jar 线路**。
  ///
  /// 不做这件事的话，冷启动（边装边用）或用户刚点完「安装 / 更新」时，
  /// 已经开着的详情页会一直停在「四个 jar 大类全灰」——得退出重进才生效。
  void _onHubChanged() {
    if (!mounted) return;
    final hub = SourceHub.instance;
    final ready = hub.jarReady;
    final flipped = ready && !_jarWasReady;
    _jarWasReady = ready;
    // 只有「缺 jar 提示条」的显隐真的变了才重绘（片源中心会频繁通知）。
    if (hub.jarMissing != _jarMissingShown) {
      _jarMissingShown = hub.jarMissing;
      setState(() {});
    }
    if (!flipped) return;
    // jar 刚装好：上一轮合并是「没装 jar 时」跑的（空手而归），
    // 这一轮要重新走一遍，占位也重新挂上。
    _jarMergeDone = false;
    // JAR_PENDING：jar 刚刚就绪 → 先把咕噜大类占位显示出来，再去取线路。
    // 否则用户会先看到「只有幻想」，几秒后咕噜整条冒出来、顺序右移。
    _startJarPending();
    final d = _detail;
    if (d == null) return;
    unawaited(_mergeJarLines(d, fillHits: true));
  }

  /// jar 能不能给这部片补线路：插件已装 + 有启用的 jar 源。
  ///
  /// JAR_PENDING：**没装 jar 就不许有占位** —— 否则第一行会永远挂着一个
  /// 转圈的「咕噜」，比不显示更糟。
  bool get _jarUsable {
    final hub = SourceHub.instance;
    return hub.hasJarSources && hub.jarReady;
  }

  /// 把咕噜大类挂成「加载中」占位（幂等；已经合并过就不再挂）。
  /// 开「等 jar 线路再起播」的窗口（幂等，超时自动放行）。
  void _startJarBootWait() {
    if (!mounted || !_jarUsable || _jarMergeDone) return;
    _jarBootWaitTimer?.cancel();
    _jarBootWaitTimer = Timer(const Duration(milliseconds: _jarBootWaitMs), () {
      if (!mounted || !_jarBootWait) return;
      setState(() => _jarBootWait = false);
      debugPrint('[JAR_SINGLE_OPEN] 等 jar 超时，回落自有线路起播');
    });
    if (_jarBootWait) return;
    setState(() => _jarBootWait = true);
  }

  void _stopJarBootWait() {
    _jarBootWaitTimer?.cancel();
    _jarBootWaitTimer = null;
    if (!_jarBootWait) return;
    if (!mounted) {
      _jarBootWait = false;
      return;
    }
    setState(() => _jarBootWait = false);
  }

  void _startJarPending() {
    _startJarBootWait();
    if (!mounted || !_jarUsable || _jarMergeDone) return;
    _jarPendingTimer?.cancel();
    _jarBootWaitTimer?.cancel();
    _jarPendingTimer = Timer(const Duration(seconds: 20), () {
      if (!mounted || !_jarPending) return;
      setState(() => _jarPending = false);
      debugPrint('[JAR_PENDING] 占位超时，回落到自有线路');
    });
    if (_jarPending) return;
    setState(() => _jarPending = true);
  }

  /// 收起「加载中」占位（线路到了 / 没有 / 超时都走这里）。
  void _stopJarPending() {
    _jarPendingTimer?.cancel();
    _jarPendingTimer = null;
    if (!_jarPending) return;
    if (!mounted) {
      _jarPending = false;
      return;
    }
    setState(() => _jarPending = false);
  }

  Future<void> _init() async {
    // 先续上历史里的集数，再开始加载/播放，避免先用第 1 集播一下再切。
    await _restoreSavedEp();
    if (!mounted) return;
    _loadDetail();
  }

  /// 打开详情页时读 `his_<id>` / 历史记录里的集数作为当前集。
  Future<void> _restoreSavedEp() async {
    if (widget.ep > 1) return;
    var saved = 0;
    // 历史记录由详情页和独立播放页共同回写，比只写详情页的 his_ 更新，
    // 所以优先读它；旧数据没有记录时再退回 his_<id>。
    try {
      for (final m in await FxStore.read(FxStore.historyKey)) {
        if ('${m['id']}' == widget.id) {
          saved = fxInt(m['ep'], 0);
          break;
        }
      }
    } catch (_) {}
    if (saved <= 0) {
      try {
        final sp = await SharedPreferences.getInstance();
        saved = sp.getInt('his_${widget.id}') ?? 0;
      } catch (_) {}
    }
    if (!mounted || saved <= 0 || saved == _ep) return;
    setState(() => _ep = saved);
  }

  @override
  void dispose() {
    SourceHub.instance.removeListener(_onHubChanged);
    _downloads.removeListener(_onDownloadsChanged);
    _stableTimer?.cancel();
    _lineChainWatchdog?.cancel();
    _lineRefreshTimer?.cancel();
    _jarPendingTimer?.cancel();
    _scroll.dispose();
    _fade.dispose();
    super.dispose();
  }

  /* --------------------------------------------------------------- data */

  Future<void> _loadDetail({bool silent = false, bool fresh = false}) async {
    // DETAIL_REQ（2026-11-15）：详情也有请求序号。
    //
    // 下拉刷新 / 重试 / 后台补线三路都会改 `_detail` / `_lineId` / `_ep`，
    // 没有序号时晚到的旧响应会把新数据整体覆盖（刚补上的线路、刚 ready 的
    // 平台线路都能被「回退」掉）。和分类页 `_req` 一个口径。
    final req = ++_detailReq;
    if (!silent && mounted) setState(() => _error = null);
    // DETAIL_TIMEOUT（2026-11-15）：详情整条链都必须有一个总上限 ——
    // 页面不能一直转圈。
    //
    // 上限**按来源区分**：
    //   · 外部源（历史 `@src:` 记录）：20 秒。8 秒 / 12 秒都不够 ——
    //     它自身带「3 次重试 + 500/1000/2000ms 退避」（光睡眠 3.5 秒），
    //     一次成功的详情经常落在 9～15 秒。
    //   · 本站 CMS：保持 12 秒（它快，慢了说明真有问题，不该让用户干等）。
    final budget = CmsBridge.detailTimeout(widget.id);
    try {
      final d = await CmsBridge.detail(widget.id, fresh: fresh).timeout(
        budget,
        onTimeout: () => throw ApiException(
          _detailErrorText(),
          kind: ApiErrorKind.timeout,
        ),
      );
      if (!mounted || req != _detailReq) return;
      _cmsBacked = CmsBridge.isCms(widget.id);

      final lines = d.lines;
      var lineId = _lineId;
      // 当前线路本身就是死线路（历史 / 路由 / 老详情缓存带进来的名字）：
      // 当作「没选」，让下面的默认线路重挑一条能播的。
      var currentDead = false;
      for (final l in lines) {
        if (l.id == lineId) {
          currentDead = isDeadLineName(l.displayName);
          break;
        }
      }
      if (lineId.isEmpty || currentDead || !lines.any((l) => l.id == lineId)) {
        // KNOWN_BAD（2026-11-15）：**死线路 / 已知坏线路不许当默认**。
        //
        // 用户实测：「换一部剧默认还是幻想蓝光 → 直接闪退」。原因就是这里：
        // 以前只在历史/路由带进来的线路上找，找不到就用
        // `FxLineCooldown.sortLines(...).first` —— 那个排序只认「10 分钟内
        // 失败过」，全新装的 App 冷却表是空的，于是原样取服务端的第一条；
        // 而服务端按「线路名推断分辨率」把幻想蓝光（1080P）排在了量子/红牛
        // （720P）前面，FY-PAN1 令牌解析又必然 404 → 一进页面就播不了。
        //
        // 现在统一走 [LineHealth.defaultLine]：死线路沉到最后且不选，
        // 冷却中 / 预检判坏 / 服务端 degraded 的排在健康线路后面。
        // 历史里带进来的线路同样过一遍这道闸（老记录可能存着死线路名）。
        LineInfo? fromRoute;
        for (final l in lines) {
          if (l.id == widget.line) {
            fromRoute = l;
            break;
          }
        }
        if (fromRoute != null && !isDeadLineName(fromRoute.displayName)) {
          lineId = widget.line;
        } else {
          // JAR_FIRST（2026-11-22 用户口径）：**优先咕噜**。
          // 这次详情如果已经把 jar 子线路带回来了（索引命中 / 外部 jar 记录），
          // 默认就选咕噜的第一条子线路；没有咕噜才用原来的健康度默认线。
          final jarPick = fxJarDefaultLine(lines);
          final LineInfo? pick =
              (jarPick != null && !isDeadLineName(jarPick.displayName))
                  ? jarPick
                  : LineHealth.instance.defaultLine(widget.id, lines);
          lineId = pick?.id ?? '';
          if (pick != null) {
            fxPlayLog(
              'default line=${pick.displayName} '
              'from=${fromRoute?.displayName ?? '-'} '
              'jar=${jarPick != null} '
              'total=${lines.length} skip=${lines.length - 1}',
            );
          }
        }
      }

      final eps = _episodesOf(d, lineId);
      var ep = _clampEpisode(eps, _ep);

      // NO_LINES（2026-11-15）：这条记录一条线路都没有（热播榜脚本只写了
      // vod_hits，有些记录的 vod_play_url 是空的）。播放器拿不到线路就什么
      // 都开不了，所以这里直接把原因说清楚，而不是留一个黑框。
      if (lines.isEmpty) {
        fxToast(context, '这部片暂无可播放地址，换一部试试');
      }
      // 这期间又发起了新的详情请求：这一份是旧的，直接丢掉。
      if (!mounted || req != _detailReq) return;
      setState(() {
        // LINE_HEALTH（2026-11-15）：健康度高的线路排前面，已知坏的沉后。
        // 只调顺序、不隐藏：探测也可能误判，用户想点坏的照样能点
        // （播放页里它会被自动跳过）。这里和服务端的 degraded 排序叠加，
        // 服务端标记 degraded 的仍然在最后。
        _detail = d.copyWith(
          lines: fxOwnLinesFirst(
            LineHealth.instance.rankLines(widget.id, d.lines),
          ),
        );
        _lineId = lineId;
        _ep = ep;
        _error = lines.isEmpty ? '这部片暂无可播放地址' : null;
        // JAR_PENDING（2026-11-22）：jar 就绪时**这一帧就把咕噜挂成
        // 「加载中」**——不能等合并开始时再挂，那会先闪一帧「只有幻想」，
        // 正是用户说的「先显示幻想再突然跳成咕噜」。
        _jarPending =
            _jarUsable && !_jarMergeDone && !CmsBridge.isJarLine(lineId);
        // JAR_SINGLE_OPEN：这一帧就开始等 jar 线路（最多 2.6 秒），
        // 免得播放器先起播自有线路、再被切到咕噜造成两次起播。
        _jarBootWait = _jarUsable && !_jarMergeDone;
        // 从历史 / 播放器带集数进来时，选集条要切到能看见这一集的分组，
        // 才能高亮并滚动到对应集数。
        _groupIndex = _groupIndexOf(_episodeGroups, ep);
      });
      _startJarBootWait();
      // ENRICH（2026-11-15）：搜索命中后补线路（幻想爱奇艺 / SH4K）。
      // 后台跑，不阻塞详情页；命中就追加到线路列表，并参与现有排序
      // （付费线在前、按实测分辨率）与自动切线。
      unawaited(_enrichLines(d));
      // FUSION（2026-11-21）：这部片在启用的 jar 源里也有时，把它们的子线路
      // 并进来（`咕噜·4K` 这种），不新增记录、也不阻塞首屏。
      //
      // JAR_BOOT：带上 fillHits —— 从首页 / 收藏直接点进来的详情页没有搜索
      // 期的索引，只有现场补一次命中，四个 jar 大类才不会一直灰着。
      // jar 没装时这一步什么都不发（`fillJarHitsFor` 先看 jarReady）。
      unawaited(_mergeJarLines(d, fillHits: true));
      _scheduleLineRefresh();
      // PLATFORM_PENDING：平台线路进页面就先在后台解析一次（fire-and-forget），
      // 用户点之前大概率已经 ready，点下去不用等。
      _autoResolvePlatformLines();
      // 详情页一打开就后台预热当前线路 / 集（上次看的集优先）：
      // PlayerView 的 open / 用户稍后点播放都能直接复用缓存，
      // 不再从 0 等 /api/play 和 m3u8。
      if (lineId.isNotEmpty) {
        FxPlayCache.warm(widget.id, ep, lineId);
      }

      if (d.related.isEmpty && d.relatedIds.isNotEmpty) {
        unawaited(_loadRelatedCards(d.relatedIds));
      }
      await _loadFavState();
      if (!mounted) return;
      await _saveHistory();
      if (!mounted) return;
      if (!_commentsLoaded && !_commentsLoading) {
        await _loadComments(reset: true, silent: true);
      }
      // 成功了就把自动重试额度还回去（下次下拉刷新 / 重新进页面照样能自愈）。
      _autoRetried = false;
    } catch (e) {
      if (!mounted) return;
      if (_isGoneError(e)) {
        // ID_RETRY（2026-11-15）：先按「片名 + 年份」重查一次。
        //
        // 服务端刚把同名片做了去重合并（旧副本并进主记录并删除），App 缓存
        // 的历史 / 收藏里还留着已经不存在的 vod_id。这种情况片还在，直接甩
        // 「该视频已失效」是错的 —— 重查到就跳到新记录。
        if (!widget.retried && await _retryByTitle()) return;
        if (!mounted) return;
        // 重查也找不到，才算真的失效：只提示一次，并给出删除这条记录的入口。
        // 不走「重试」错误页（重试必然再失败），播放器也没机会再报一次，
        // 避免用户看到两层错误弹窗。
        fxToast(context, '该视频已失效');
        if (_detail == null) {
          setState(() {
            _invalid = true;
            _error = '该视频已失效';
          });
          // 通知来源页（搜索结果）把这条摘掉，别再占位置。
          widget.onInvalid?.call(widget.id);
        }
        return;
      }
      // DETAIL_RETRY（2026-11-15）：超时 / 网络类失败**自动再试一次**。
      //
      // 用户要的体验是「能进详情」，不是「看到一个错误页再去点重试」。
      // 只重试一次（第二次 fresh=true，绕开详情缓存），而且只在还没拿到
      // 任何详情时重试 —— 页面已经有内容时重试会白闪；这时直接把这次的
      // 失败提示成 toast，页面继续可用。
      if (_detail == null && !_autoRetried && _retryableError(e)) {
        _autoRetried = true;
        await Future<void>.delayed(_autoRetryDelay);
        if (!mounted || req != _detailReq) return;
        return _loadDetail(silent: silent, fresh: true);
      }
      final msg = _detailErrorText(e);
      setState(() => _error = msg);
      if (_detail != null) fxToast(context, msg);
    }
  }

  /// 这次失败值不值得自动重试：超时 / 网络 / 5xx 抖动是可以重试的；
  /// 「作品不存在」「没给播放地址」这类业务结论重试一万次也一样。
  bool _retryableError(Object e) {
    if (e is TimeoutException) return true;
    if (e is ApiException) {
      switch (e.kind) {
        case ApiErrorKind.timeout:
        case ApiErrorKind.network:
        case ApiErrorKind.server:
          return true;
        case ApiErrorKind.business:
          return false;
      }
    }
    // 非 ApiException 的多半是解析 / 通道异常，值得一次重试。
    return true;
  }

  /// 详情取不到时的文案（SOURCE_TEXT 2026-11-15）。
  ///
  /// 超时 / 网络类一律用**按来源区分**的引导语：
  ///   · 本站源 → `该线路暂时取不到，换条线路试试`
  ///   · 外部源 → `<源名> 暂时没响应，换一个源试试`
  /// 业务类错误（源没给播放地址 / 需要网页解析…）保留源站原话，
  /// 那句话比我们的通用文案更有用。
  String _detailErrorText([Object? error]) {
    final friendly = CmsBridge.detailErrorText(widget.id, label: _sourceName);
    if (error == null) return friendly;
    if (error is ApiException && error.kind == ApiErrorKind.business) {
      final raw = error.message.trim();
      return raw.isEmpty ? friendly : raw;
    }
    if (error is ApiException) return friendly;
    if (error is TimeoutException) return friendly;
    final raw = fxErrorText(error);
    return raw.isEmpty ? friendly : raw;
  }

  /// 详情 404 后的自愈：用「片名 + 年份」重查，命中就直接换到新记录。
  ///
  /// 片名 / 年份的来源顺序：入口传进来的（搜索结果、历史、收藏）→ 本地缓存
  /// 记录里的（[FxStore.historyKey] / [FxStore.favoriteKey] 都存了
  /// 片名 + 年份）→ 都没有就只能算失效。
  ///
  /// 返回 true 表示「已经跳到新记录」，调用方不要再走失效页。
  Future<bool> _retryByTitle() async {
    if (_retrying) return false;
    _retrying = true;
    try {
      final cached = await _cachedRecord();
      final name =
          widget.title.trim().isNotEmpty ? widget.title.trim() : cached.$1;
      final year = widget.year > 0 ? widget.year : cached.$2;
      if (name.isEmpty) return false;
      // 重查期间保持「加载中」，别让用户先看到一帧「已失效」。
      if (mounted) {
        setState(() => _error = null);
      }
      VideoCard? hit;
      try {
        hit = await CmsBridge.findByTitle(name, year: year).timeout(
          const Duration(seconds: 8),
        );
      } catch (_) {
        hit = null;
      }
      if (!mounted || hit == null) return false;
      final card = hit;
      if (card.id.isEmpty || card.id == widget.id) return false;
      fxToast(context, '记录已更新，正在打开《${card.title}》');
      await Navigator.of(context).pushReplacement(
        FxPageRoute(
          builder: (_) => DetailPage(
            id: card.id,
            ep: _ep,
            line: _lineId,
            title: card.title,
            year: card.year,
            retried: true,
          ),
        ),
      );
      return true;
    } finally {
      _retrying = false;
    }
  }

  /// 本地缓存记录里的「片名 + 年份」：观看历史优先，其次收藏。
  Future<(String, int)> _cachedRecord() async {
    try {
      for (final m in await FxStore.read(FxStore.historyKey)) {
        if ('${m['id']}' == widget.id) {
          return (fxStr(m['title']).trim(), fxInt(m['year'], 0));
        }
      }
    } catch (_) {}
    try {
      for (final m in await FxStore.read(FxStore.favoriteKey)) {
        if ('${m['id']}' == widget.id) {
          return (fxStr(m['title']).trim(), fxInt(m['year'], 0));
        }
      }
    } catch (_) {}
    return ('', 0);
  }

  /// 服务端已删掉这个作品：/api/detail 以 404「作品不存在」返回。
  bool _isGoneError(Object e) {
    if (e is! ApiException) return false;
    return e.code == 404 || e.message.contains('作品不存在');
  }

  /// 失效作品：删掉本地这条观看记录后返回上一页；历史页回来会重新加载。
  Future<void> _deleteGoneRecord() async {
    try {
      final list = await FxStore.read(FxStore.historyKey);
      list.removeWhere((e) => '${e['id']}' == widget.id);
      await FxStore.writeQueued(FxStore.historyKey, list);
    } catch (_) {}
    try {
      // 从收藏进来时，「这条记录」也在收藏里，一并清掉。
      final favs = await FxStore.read(FxStore.favoriteKey);
      final before = favs.length;
      favs.removeWhere((e) => '${e['id']}' == widget.id);
      if (favs.length != before) {
        await FxStore.writeQueued(FxStore.favoriteKey, favs);
      }
    } catch (_) {}
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove('his_${widget.id}');
      await sp.remove('fav_${widget.id}');
    } catch (_) {}
    if (!mounted) return;
    fxToast(context, '已删除这条记录');
    await Navigator.of(context).maybePop();
  }

  /// 首屏线路里没有平台线（腾讯 / 芒果 / B 站…）时，2.5 秒后再取一次详情，
  /// 把服务端异步补上的平台线路显示出来；最多补 2 次。服务端确实还没算完
  /// 也会把结果写进缓存，下次进入详情页就能直接带上。
  void _scheduleLineRefresh() {
    // CMS 线路一次给全，没有「服务端稍后补平台线」这回事。
    if (_cmsBacked) return;
    if (_lineRefreshTimer != null || _lineRefreshTries >= _lineRefreshMax) {
      return;
    }
    final d = _detail;
    if (d == null || d.lines.any(fxIsPlatformLine)) return;
    _lineRefreshTries++;
    _lineRefreshTimer?.cancel();
    _lineRefreshTimer = Timer(_lineRefreshDelay, () {
      _lineRefreshTimer = null;
      unawaited(_refreshLines());
    });
  }

  /// 只刷新线路表：不动当前集数、评论区、历史与播放器实例。
  ///
  /// [force] = true 用于「强制拿到最新线路状态」：平台线解析完成后即使
  /// 线路条数没变，也要把 status / 集名更新进来（PLATFORM_PENDING）。
  Future<void> _refreshLines({bool force = false}) async {
    if (!mounted || _cmsBacked) return;
    final current = _detail;
    if (current == null) return;
    if (!force && current.lines.any(fxIsPlatformLine)) return;
    VideoDetail fresh;
    try {
      fresh = await CmsBridge.detail(widget.id);
    } catch (_) {
      // 这次没取到（服务端还在算 / 网络抖动）：还有重试额度就继续排。
      if (mounted) _scheduleLineRefresh();
      return;
    }
    if (!mounted) return;
    final latest = _detail;
    if (latest == null) return;
    if (!force && latest.lines.any(fxIsPlatformLine)) return;

    final merged = fxMergeLines(latest.lines, fresh.lines);
    // 线路条数一样也要比状态：pending → ready 只变 status 和集名，长度不变。
    final changed = force ||
        merged.length != latest.lines.length ||
        merged.asMap().entries.any((entry) {
          if (entry.key >= latest.lines.length) return true;
          final a = entry.value;
          final b = latest.lines[entry.key];
          return a.id != b.id ||
              a.status != b.status ||
              a.epNames.length != b.epNames.length;
        });
    if (changed) {
      var lineId = _lineId;
      if (lineId.isEmpty || !merged.any((line) => line.id == lineId)) {
        if (merged.any((line) => line.id == widget.line)) {
          lineId = widget.line;
        } else {
          lineId = merged.isEmpty ? '' : merged.first.id;
        }
      }
      setState(() {
        _detail = latest.copyWith(lines: merged);
        _lineId = lineId;
      });
      if (lineId.isNotEmpty) FxPlayCache.warm(widget.id, _ep, lineId);
    }
    // 还是没有平台线：排下一轮重试（最多 2 次）。
    _scheduleLineRefresh();
  }

  /* ------------------------------------------------ 平台线按需解析 */

  /// PLATFORM_PENDING：详情页进入时，对还在解析的平台线自动触发一次后台解析
  /// （fire-and-forget，不阻塞 UI、不切当前线路）。
  void _autoResolvePlatformLines() {
    if (_cmsBacked) return;
    final d = _detail;
    if (d == null) return;
    for (final line in d.lines) {
      if (!fxIsPlatformLine(line) || !line.linePending) continue;
      if (!_autoResolved.add(line.id)) continue;
      unawaited(_backgroundResolve(line));
    }
  }

  Future<void> _backgroundResolve(LineInfo line) async {
    try {
      final r = await Api.resolveLine(widget.id, line.id);
      if (!mounted) return;
      if ('${r['status']}' == 'ready') {
        await _refreshLines(force: true);
      } else {
        // 上游明确不可用：卡片从「解析中」变成「暂时不可用」，线路不消失。
        _markLine(line.id, status: 'error');
      }
    } catch (_) {
      // 网络抖动：保持 pending，用户点的时候还能再试一次。
    }
  }

  /// 用户点 pending / 暂不可用的线路：现场解析，期间播放器显示「正在解析 X」。
  /// 成功正常播放并刷新选集；失败提示「该线路暂时不可用」，留在原线路不切走。
  Future<void> _resolveThenPlay(LineInfo line) async {
    if (!mounted) return;
    if (!_resolvingLines.add(line.id)) return;
    final player = _playerKey.currentState;
    player?.showResolving('正在解析 ${line.displayName}');
    try {
      final r = await Api.resolveLine(widget.id, line.id);
      if (!mounted) return;
      if ('${r['status']}' != 'ready') {
        player?.clearResolving();
        fxToast(context, '该线路暂时不可用');
        _markLine(line.id, status: 'error');
        return;
      }
      // 成功：先把状态和集名落到本地，再拉一次详情按服务端集数刷新选集区。
      _markLine(line.id, status: 'ready', epNames: _epNamesOf(r['epnames']));
      await _refreshLines(force: true);
      if (!mounted) return;
      player?.clearResolving();
      LineInfo? target;
      for (final l in _detail?.lines ?? const <LineInfo>[]) {
        if (l.id == line.id) {
          target = l;
          break;
        }
      }
      if (target == null) {
        fxToast(context, '该线路暂时不可用');
        return;
      }
      // 走正常切换路径（此时 status=ready，不会再进解析分支）。
      _selectLine(target);
    } catch (_) {
      player?.clearResolving();
      if (mounted) fxToast(context, '该线路暂时不可用');
    } finally {
      _resolvingLines.remove(line.id);
    }
  }

  /// 只改一条线路的 status / 集名，线路顺序和播放器实例都不动。
  void _markLine(String id, {required String status, List<String>? epNames}) {
    final d = _detail;
    if (d == null) return;
    final lines = <LineInfo>[
      for (final l in d.lines)
        l.id == id ? l.copyWith(status: status, epNames: epNames) : l,
    ];
    setState(() => _detail = d.copyWith(lines: lines));
  }

  List<String> _epNamesOf(Object? v) {
    if (v is! List) return const <String>[];
    return <String>[for (final e in v) '$e'];
  }

  /// `related` 只是 id 数组：按 id 补卡片，最多补 8 个。
  Future<void> _loadRelatedCards(List<String> ids) async {
    if (_relatedLoading || _relatedFetched) return;
    _relatedLoading = true;
    final cards = <VideoCard>[];
    Future<VideoDetail?> fetch(String id) async {
      try {
        // 猜你喜欢只是锦上添花：单个 id 8 秒拿不到就当它没有，
        // 绝不允许它拖住详情页（8 个 id 并行等，最多 8 秒）。
        return await CmsBridge.detail(id).timeout(
          const Duration(seconds: 8),
        );
      } on TimeoutException {
        // 超时 = 这条推荐没有（`Future<VideoDetail>` 的 onTimeout 不许返回
        // null，所以用 catch 兜，不写 onTimeout）。
        return null;
      } catch (_) {
        return null;
      }
    }

    try {
      final details = await Future.wait(<Future<VideoDetail?>>[
        for (final id in ids.take(8)) fetch(id),
      ]);
      for (final d in details) {
        if (d == null) continue;
        cards.add(VideoCard(
          id: d.id,
          title: d.title,
          cover: d.cover,
          rating: d.rating,
          year: d.year,
          status: d.status,
          episodes: d.episodes,
          category: d.category,
          tags: d.tags,
        ));
      }
    } finally {
      _relatedLoading = false;
    }
    if (!mounted) return;
    // 一张都没补到就别标记完成，下拉刷新时还能再试。
    _relatedFetched = cards.isNotEmpty;
    if (!_relatedFetched) return;
    setState(() => _related = cards);
  }

  /// 剧集列表：**按当前选中线路**返回它自己的集。
  ///
  /// LINE_EPNAMES（2026-11-14）：以前所有线路共用「合并后最长那条线路」
  /// 的集名 —— 三条线路都显示同一套 5 集，可有的线路根本没这些集，
  /// 点进去就播不出来。现在线路自带 epnames 时优先用它。
  /// 把集号夹到这条线路真实拥有的范围内（首屏与手动换线共用同一套规则）。
  ///
  /// 目标线路集数更少时落到「不超过当前集的最大集」，不要直接跳回第 1 集：
  /// 4K(28 集) ↔ 量子(29 集) 来回切、正在看第 29 集时，切 4K 应该落到
  /// 第 28 集，而不是从头开始。
  ///
  /// EP_CLAMP（2026-11-15）：这条规则原来只写在首屏 `_loadDetail` 里，
  /// `_selectLineReady`（用户点线路卡）单独写成了 `_ep = eps.first.n`，
  /// 于是同一个动作一处夹取、一处跳回第 1 集，还会把「第 1 集」立刻写进
  /// 观看历史 —— 用户点一下线路就丢进度。
  static int _clampEpisode(List<Episode> eps, int ep) {
    if (eps.isEmpty) return ep;
    if (eps.any((e) => e.n == ep)) return ep;
    var fallback = eps.first.n;
    for (final e in eps) {
      if (e.n <= ep) fallback = e.n;
    }
    return fallback;
  }

  List<Episode> _episodesOf(VideoDetail d, [String? lineId]) {
    final wantLine = (lineId ?? _lineId).trim();
    if (wantLine.isNotEmpty) {
      for (final l in d.lines) {
        if (l.id == wantLine && l.epNames.isNotEmpty) {
          return <Episode>[
            for (var i = 0; i < l.epNames.length; i++)
              Episode(i + 1, l.epNames[i], 0),
          ];
        }
      }
    }
    final all = d.allEpisodes;
    if (all.isNotEmpty) return all;
    return <Episode>[for (var i = 1; i <= d.episodes; i++) Episode(i, '', 0)];
  }

  /// 电影的多条是「版本」不是「集」。
  ///
  /// MOVIE_VERSION（2026-11-14 用户要求）：同剧合并、每条线路用自己
  /// 的集名，但电影不能出现「第01集」这种叫法 —— 有些采集源对电影
  /// 就是把两条版本命名成「第01集/第02集」，照搬出来用户看到的是
  /// 「这是电影啊，怎么显示集」。
  /// 这里只把**无意义的「第N集」**换成版本名：该线路本来就叫
  /// 「普通话版 / 粤语版 / 正片」的，原样保留。
  static final RegExp _epNumOnly = RegExp(r'^第\s*\d+\s*集$');

  List<Episode> _movieVersions(List<Episode> list) {
    return <Episode>[
      for (final e in list)
        Episode(e.n, _movieVersionName(e, list.length), e.duration),
    ];
  }

  String _movieVersionName(Episode e, int total) {
    final s = e.name.trim();
    if (s.isEmpty || _epNumOnly.hasMatch(s)) {
      return total <= 1 ? '正片' : '版本 ${e.n}';
    }
    return s;
  }

  List<Episode> get _episodes {
    final d = _detail;
    if (d == null) return const <Episode>[];
    final list = _episodesOf(d);
    return _isMovie ? _movieVersions(list) : list;
  }

  /// 正片 / 花絮等分组；接口没给分组时整段当「正片」。
  List<EpisodeGroup> get _episodeGroups {
    final d = _detail;
    if (d == null) return const <EpisodeGroup>[];
    // LINE_GROUP（2026-11-15）：`cms_api` 只造一个「正片」组，而且集名取的
    // 是**最长那条线路**。直接用它会出现：4K 只有 28 集、量子 29 集时，
    // 选 4K 仍列出 29 个集胶囊，点第 29 集播的其实是第 28 集。
    // 所以「只有一个组」时改用当前线路自己的集（[_episodes] 已是按线路取的）。
    final own = _episodes;
    if (d.groups.length <= 1 && own.isNotEmpty) {
      final name = d.groups.isEmpty ? '正片' : d.groups.first.name;
      return <EpisodeGroup>[EpisodeGroup(name, own)];
    }
    if (d.groups.isNotEmpty) {
      // 接口自带分组时也要过一遍电影版本名，否则电影会显示「第01集」。
      if (!_isMovie) return d.groups;
      return <EpisodeGroup>[
        for (final g in d.groups)
          EpisodeGroup(
            g.name,
            _movieVersions(g.episodes),
          ),
      ];
    }
    final all = _episodes;
    return all.isEmpty
        ? const <EpisodeGroup>[]
        : <EpisodeGroup>[
            EpisodeGroup('正片', all),
          ];
  }

  String get _lineName {
    final lines = _detail?.lines ?? const <LineInfo>[];
    for (final l in lines) {
      if (l.id == _lineId) return l.name;
    }
    return '';
  }

  String get _currentEpLabel {
    for (final e in _episodes) {
      if (e.n == _ep) return detailEpisodeLabel(e);
    }
    return fxEpisodeLabel(_ep);
  }

  /// 是不是电影：电影没有「集」的概念，它的多条是「正片 / 国语 / 粤语」
  /// 这类版本。列表与详情都不该给电影显示「共 N 集 / 更新至 N 集」。
  bool get _isMovie {
    final d = _detail;
    if (d == null) return false;
    // MOVIE_BY_CATEGORY（2026-11-14 用户明确要求）：只看分类。
    //   · 分类是「电影」→ 正片（多个版本时显示版本名）
    //   · 其它一切（电视剧/动漫/综艺…）→ 剧集，显示集数
    // 不再用集数兜底判断，也不写死单个线路。
    return d.category.contains('电影');
  }

  String get _statusText {
    final d = _detail;
    if (d == null) return '';
    // 电影先判：服务端对电影也会给「更新至 N 集」这种串，
    // 之前先返回 status 就把它漏过去了，电影详情页顶着「更新至2集」。
    if (_isMovie) return '电影';
    final s = d.status.trim();
    if (s.isNotEmpty) {
      if (RegExp(r'^全\s*\d+\s*集$').hasMatch(s)) return '已完结';
      return s;
    }
    final n = fxMainEpisodeCount(_episodes);
    return n > 0 ? '更新至$n集' : '';
  }

  String get _descText {
    final d = _detail;
    if (d == null) return '';
    final desc = d.desc.trim();
    if (desc.isEmpty) return '暂无简介';
    return desc.startsWith('介绍') ? desc : '介绍：$desc';
  }

  List<VideoCard> get _relatedList {
    final src = _related.isNotEmpty
        ? _related
        : (_detail?.related ?? const <VideoCard>[]);
    if (src.isEmpty) return const <VideoCard>[];
    final shift = _relatedOffset % src.length;
    if (shift == 0) return src;
    return <VideoCard>[...src.skip(shift), ...src.take(shift)];
  }

  Future<void> _loadFavState() async {
    var fav = false;
    try {
      // 收藏列表是唯一事实源：收藏页删除后这里必须立刻变回未收藏，
      // 不能再用 fav_ 标记抢先返回 true。读到结果后顺手修正旧标记。
      final list = await FxStore.read(FxStore.favoriteKey);
      fav = list.any(
        (m) =>
            '${m['id']}' == widget.id && '${m['kind'] ?? 'video'}' == 'video',
      );
      final sp = await SharedPreferences.getInstance();
      if ((sp.getBool('fav_${widget.id}') ?? false) != fav) {
        await sp.setBool('fav_${widget.id}', fav);
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _fav = fav);
  }

  Future<void> _saveHistory() async {
    final d = _detail;
    if (d == null) return;
    try {
      // 没真正播放时只刷新标题/封面，不覆盖历史里的集数与进度。
      if (_played) {
        final sp = await SharedPreferences.getInstance();
        await sp.setInt('his_${widget.id}', _ep);
      }
      await FxStore.addHistory(
        id: widget.id,
        title: d.title,
        cover: d.cover,
        // 片名 + 年份一起存：id 失效时详情页靠它们重查（ID_RETRY）。
        year: d.year,
        ep: _ep,
        epName: _currentEpLabel,
        lineId: _lineId,
        lineName: _lineName,
        updateEpisode: _played,
      );
    } catch (_) {}
  }

  Future<void> _toggleFav() async {
    final d = _detail;
    if (d == null) return;
    final next = !_fav;
    setState(() => _fav = next);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool('fav_${widget.id}', next);
      if (next) {
        await FxStore.addFavorite(
          id: widget.id,
          title: d.title,
          cover: d.cover,
          rating: d.rating,
          year: d.year,
          status: d.status,
          episodes: d.episodes,
          category: d.category,
          tags: d.tags,
        );
      } else {
        final list = await FxStore.read(FxStore.favoriteKey);
        list.removeWhere((m) => '${m['id']}' == widget.id);
        await FxStore.writeQueued(FxStore.favoriteKey, list);
      }
    } catch (_) {
      // 收藏是「乐观更新」，但写盘失败时必须回滚：否则页面显示已收藏、
      // 重启后又变回未收藏，中间一句提示都没有（收藏列表是唯一事实源）。
      if (mounted) {
        setState(() => _fav = !next);
        fxToast(context, '收藏失败，请重试');
      }
      return;
    }
    if (!mounted) return;
    fxToast(context, next ? '已加入收藏' : '已取消收藏');
  }

  Future<void> _loadComments({required bool reset, bool silent = false}) async {
    if (!mounted || _commentsLoading) return;
    final page = reset ? 1 : _commentPage + 1;
    setState(() {
      _commentsLoading = true;
      if (reset && _comments.isEmpty) _commentError = null;
    });
    try {
      final list = await Api.comments(widget.id, page);
      if (!mounted) return;
      setState(() {
        _comments = reset ? list : <CommentItem>[..._comments, ...list];
        _commentPage = page;
        _commentsLoaded = true;
        _commentsLoading = false;
        _commentsHasMore = list.length >= 10 && page < 20;
        _commentError = null;
      });
    } catch (e) {
      if (!mounted) return;
      final msg = fxErrorText(e);
      setState(() {
        _commentsLoading = false;
        _commentsLoaded = true;
        _commentsHasMore = false;
        _commentError = msg;
      });
      if (!silent) fxToast(context, msg);
    }
  }

  String _commentKey(CommentItem c) => '${c.user}|${c.time}|${c.content}';

  /* ------------------------------------------------------------ actions */

  void _switchTab(int index) {
    if (index == _tab) return;
    setState(() => _tab = index);
    _fade.forward(from: 0);
    if (index == 1 && !_commentsLoaded && !_commentsLoading) {
      _loadComments(reset: true);
    }
  }

  void _toggleDesc() {
    setState(() => _descOpen = !_descOpen);
  }

  void _selectLine(LineInfo line) {
    // JAR_FIRST：用户亲手点过线路，之后到达的 jar 线路不许再改默认选中。
    _linePickedByUser = true;
    // 切换中仍然接受点击：播放器会把这次选择记成 pendingSwitch，
    // 当前切换一结束就立刻执行，最多 12 秒僵死也会强制接管。
    // 之前这里直接 return，用户会觉得「点了没反应」。
    if (line.id == _lineId && !_playerSwitchingLine) {
      // 就是当前线路：不再「点了没反应」，改成重播一次（用户在这里点的
      // 语义一定是「这条线路再试一下」，单线路的片尤其需要这个出口）。
      fxToast(context, '正在重试该线路…');
      unawaited(_playerKey.currentState?.reload() ?? Future<void>.value());
      return;
    }
    // PLATFORM_PENDING：还没解析完（或上游暂不可用）的平台线，先现场解析。
    // 解析期间留在原线路继续播，播放器上显示「正在解析 X」。
    if (fxIsPlatformLine(line) && (line.linePending || line.lineUnavailable)) {
      unawaited(_resolveThenPlay(line));
      return;
    }
    // CMS 采集线路（幻想4K / 量子 / 幻想爱奇艺 …）：地址是令牌或平台页面，
    // 播之前要先找 hxparse 换直链。这里先显示「解析中」，解析成功才真正切线路；
    // 失败只提示「该线路解析失败」，_lineId 不动 —— 用户留在原线路继续看。
    if (_cmsBacked && line.needsParse) {
      unawaited(_parseThenSelect(line));
      return;
    }
    _selectLineReady(line);
  }

  /// CMS 线路预解析：把这一集交给 FxPlayCache 换直链（结果同时进缓存，
  /// 播放器随后 open 就是秒开），期间播放器上显示「正在解析 X」。
  ///
  /// 已经在缓存里（详情页预热 / 之前播过）就直接放行，不重复解析。
  Future<bool> _ensureParsed(LineInfo line, int ep) async {
    if (!_cmsBacked || !line.needsParse) return true;
    if (FxPlayCache.peek(widget.id, ep, line.id) != null) return true;
    if (!_resolvingLines.add(line.id)) return false;
    final player = _playerKey.currentState;
    player?.showResolving('正在解析 ${line.displayName}');
    try {
      await FxPlayCache.resolve(widget.id, ep, line.id);
      if (!mounted) return false;
      player?.clearResolving();
      return true;
    } catch (_) {
      player?.clearResolving();
      if (mounted) fxToast(context, '该线路解析失败');
      return false;
    } finally {
      _resolvingLines.remove(line.id);
    }
  }

  Future<void> _parseThenSelect(LineInfo line) async {
    if (!await _ensureParsed(line, _ep)) return;
    if (!mounted) return;
    _selectLineReady(line);
  }

  /// 解析就绪后的正常切线路（原来的 _selectLine 主体，行为不变）。
  void _selectLineReady(LineInfo line) {
    _stableTimer?.cancel();
    // 用户手动选线路视为重新开始，允许重试这一条。
    _failedLines.remove(line.id);
    _retriedLine = null;
    setState(() {
      _lineId = line.id;
      _autoLineTries = 0;
      // 换线路后集数可能变少（这条线路没有那么多集）：
      // 把当前集夹到该线路真实拥有的范围内，避免点了播不出来。
      // 规则和首屏完全一致 —— 少一集时落到「不超过当前集的最大集」。
      final eps = _episodesOf(_detail!, line.id);
      _ep = _clampEpisode(eps, _ep);
      _groupIndex = _groupIndexOf(_episodeGroups, _ep);
    });
    _saveHistory();
    fxToast(context, '正在切换播放源…');
  }

  /// 播放器切换结束回调实际生效的线路（自动尝试下一条成功或全失败时），
  /// 同步高亮，避免 UI 指着失败线路而实际播的是另一条。
  void _onLineFallback(String lineId) {
    if (!mounted || lineId.isEmpty || lineId == _lineId) return;
    final lines = _detail?.lines ?? const <LineInfo>[];
    if (!lines.any((l) => l.id == lineId)) return;
    setState(() => _lineId = lineId);
    _saveHistory();
  }

  /// 换线路；[auto] = 播放失败后自动切下一条（有限次）。
  /// [issue] 说明当前线路不可播的原因，用于选择文案与最终错误提示。
  void _switchNextLine({bool auto = false, SourceIssue? issue}) {
    _stableTimer?.cancel();
    final lines = _detail?.lines ?? const <LineInfo>[];
    if (lines.isEmpty) {
      _showPlaybackError(issue: issue);
      return;
    }
    // 自动兜底逐条换线直到每条线路都试过（每条最多换入一次、
    // 每条最多原线重试一次，_retriedLine 单独计数不占这里），
    // 全失败才展示错误页——原线重试不能挤掉换线预算导致漏换线路。
    if (auto && _autoLineTries >= lines.length - 1) {
      _showPlaybackError(issue: issue);
      return;
    }
    // GROUP_ORDER（2026-11-21 用户口径）：**先当前大类的其它子线路，再下一个
    // 大类**。以前按扁平列表取 `(index + step) % length`，而扁平列表被
    // `fxOwnLinesFirst` / 健康度排序 / jar 合并重排过，于是会在「幻想 → 咕噜」
    // 之间来回跳；现在顺序只有一处定义（[fxFallbackLineOrder]）。
    final next = fxFallbackNextLine(
      lines: lines,
      currentLineId: _lineId,
      skip: _failedLines,
    );
    if (next == null) {
      if (auto) {
        _showPlaybackError(issue: issue);
      } else {
        fxToast(context, '暂无其他可用线路');
      }
      return;
    }
    if (auto) {
      _autoLineTries++;
      final target = next;
      setState(() => _lineId = target.id);
      _saveHistory();
      // 自动换线全程静默：进度由画面上的「正在尝试其他线路（n/total）」表达，
      // 只在最终失败时提示一次（AUTO_LINE_FULL 2026-11-15）。
    } else {
      _selectLine(next);
    }
  }

  /* ---------------------------------------------- 三段降级（FX_FALLBACK） */

  /// 本次播放会话的降级状态机：**跨源只切一次**、每个源只试一次。
  FxSourceFallback? _fallback;

  /// 正在跑第 2 / 3 段（防并发，UI 只弹一次「正在尝试其他源…」）。
  bool _fallbackBusy = false;

  /// 这一次播放会话的降级已经跑完且没找到：再失败就直接给最终提示，
  /// 不重复搜一遍（「只尝试一次」的落地）。
  bool _fallbackDone = false;

  /// 当前记录属于哪个源（日志里的 `from=`）。外部 id 带 `@src:` 前缀，
  /// 按它解回源名；主站 / 旧接口一律算「幻想」。
  String _currentSourceName() {
    final id = widget.id.trim();
    if (id.startsWith(SourceHub.idMark)) {
      final source = SourceHub.instance.decodeSource(id);
      final label = (source?.resultLabel ?? '').trim();
      if (label.isNotEmpty) return label;
    }
    // SOURCE_LABEL：「幻想」这个统一叫法定义在 [KSource] 上
    // （片源对象），不是 SourceHub 的静态成员。
    final own = KSource.ownResultLabel;
    return own.isEmpty ? '幻想' : own;
  }

  /// 全部线路都试过仍不可播：先走第 2 / 3 段（同源其他版本 → 跨源同名），
  /// 都不行才给最终提示。
  ///
  /// 三段降级的顺序：
  /// ```
  /// 第 1 段  本片其他线路     _switchNextLine（已有）
  /// 第 2 段  同源其他版本     FxSourceFallback.find 内部先查我们自己的库
  /// 第 3 段  跨源找同名       再去外部源搜（接入层已拆，现恒为未命中）
  /// 全失败   「所有线路都尝试过了，暂时无法播放」
  /// ```
  void _showPlaybackError({SourceIssue? issue}) {
    final lines = _detail?.lines ?? const <LineInfo>[];
    if (lines.isEmpty || _detail == null) {
      _showFinalPlaybackError(issue: issue);
      return;
    }
    // 已经跨源切过一次（这条记录就是换过来的目标）：不再往外跳。
    if (widget.fallbackHops >= fxFallbackMaxHops) {
      _showFinalPlaybackError(issue: issue);
      return;
    }
    if (_fallbackDone || _fallbackBusy) {
      _showFinalPlaybackError(issue: issue);
      return;
    }
    unawaited(_attemptSourceFallback(issue: issue));
  }

  /// 第 2 / 3 段：换到另一条记录 / 另一个源，**保持集号与进度**。
  Future<void> _attemptSourceFallback({SourceIssue? issue}) async {
    if (_fallbackBusy || _fallbackDone) return;
    final detail = _detail;
    if (detail == null) {
      _showFinalPlaybackError(issue: issue);
      return;
    }
    final fb = _fallback ??= FxSourceFallback(
      title: detail.title.trim().isNotEmpty ? detail.title : widget.title,
      year: detail.year > 0 ? detail.year : widget.year,
      currentId: widget.id,
      sourceName: _currentSourceName(),
    );
    if (fb.switched) {
      _showFinalPlaybackError(issue: issue);
      return;
    }
    _fallbackBusy = true;
    // 换源前的现场：集号 + 位置 + 是否在播。位置优先取播放器可信进度，
    // 播放器报错后位置可能被清零，播放页会退回「本集最后一次正常位置」。
    final player = _playerKey.currentState;
    final snap = player?.playbackSnapshot();
    final ep = snap?.ep ?? _ep;
    final position = snap?.seconds ?? 0;

    // UI：切源时明确告诉用户在干什么（不是一直转圈）。
    // 只盖一层画面提示，不弹 toast —— 起播过程中除了最终失败不给任何打扰。
    player?.showResolving(fxFallbackSearchingText);

    FxFallbackOutcome outcome = const FxFallbackOutcome.miss();
    try {
      outcome = await fb.find(ep: ep, position: position);
    } catch (_) {
      // 降级只是兜底，任何异常都收敛成「没找到」，页面照常给最终提示。
      outcome = const FxFallbackOutcome.miss(reason: 'exception');
    }
    _fallbackBusy = false;
    if (!mounted) return;
    final target = outcome.candidate;
    if (target == null) {
      _fallbackDone = true;
      player?.clearResolving();
      _showFinalPlaybackError(
        issue: issue,
        note: outcome.note,
      );
      return;
    }

    // 命中：把「第 N 集 + 位置」原样带过去，整页换到目标记录。
    player?.clearResolving();
    fxPlayLog(
      fxFallbackResumeLog(
        ep: target.ep,
        posMs: (position * 1000).round(),
        from: fb.sourceName,
        to: target.sourceName,
      ),
    );
    final tail = outcome.note.trim();
    fxToast(
      context,
      tail.isEmpty
          ? fxFallbackSwitchedText(target.sourceName)
          : '${fxFallbackSwitchedText(target.sourceName)} · $tail',
    );
    _failedLines.clear();
    _autoLineTries = 0;
    await Navigator.of(context).pushReplacement(
      FxPageRoute(
        builder: (_) => DetailPage(
          id: target.videoId,
          ep: target.ep,
          line: target.lineId,
          title: target.title,
          year: detail.year,
          // 新记录按这条线路的第一集开始播也不需要「从头」：位置跟着走。
          startSeconds: position > 0 ? position : null,
          retried: true,
          fallbackHops: widget.fallbackHops + 1,
        ),
      ),
    );
  }

  /// 三段全部失败：给明确提示，不停在转圈。
  void _showFinalPlaybackError({
    SourceIssue? issue,
    String note = '',
  }) {
    final lines = _detail?.lines ?? const <LineInfo>[];
    String message;
    if (lines.isEmpty) {
      message = '暂无线路，请稍后刷新重试';
    } else {
      // GROUP_ORDER：全部大类都试过 —— 用户定稿的措辞就是这一句
      // （和「咕噜线路被剔除」共用 [fxLineNoUsableText]，不许两边各写一份）。
      message = fxLineNoUsableText;
      final tail = note.trim();
      if (tail.isNotEmpty) message = '$message（$tail）';
      if (issue == SourceIssue.parse) message = '$message · 这些线路都需要现场解析';
    }
    final player = _playerKey.currentState;
    if (player != null) {
      player.showSourceError(message);
    } else if (mounted) {
      fxToast(context, message);
    }
  }

  /// PlayerView 报告当前线路不可播：第一次先在原线路上重试一次（带缓冲态），
  /// 重试仍失败才记为失败线路并按原因切下一条。
  ///
  /// CHAIN_FIX（2026-11-15）：每次上报都挂一个哨兵（[_armLineChainWatchdog]）。
  /// 「原线重试」这一步有早退（player.reload() 里正在切线路 / 全部线路已试完
  /// 都会直接 return），早退之后没有人再触发下一次失败回调 —— 降级链就停在
  /// 错误页上。哨兵负责把这种情况接回来。
  void _reportLineIssue(SourceIssue issue) {
    if (!mounted) return;
    _stableTimer?.cancel();
    final lineId = _lineId;
    final player = _playerKey.currentState;
    // 第一次失败：原线静默重试（**不弹 toast**：起播失败的过程不该打断用户）。
    // reload() 一进来就置 _loading=true、清掉错误层，重试期间显示缓冲态。
    if (lineId.isNotEmpty &&
        !_failedLines.contains(lineId) &&
        _retriedLine != lineId &&
        player != null) {
      _retriedLine = lineId;
      fxPlayLog('chain line=$lineId stage=retry issue=${issue.name}');
      _armLineChainWatchdog();
      unawaited(player.reload());
      return;
    }
    if (lineId.isNotEmpty) {
      _failedLines.add(lineId);
      // LINE_VANISH（2026-11-21 用户口径）：「有就有，没有就跳、自动跳、消失」。
      // 播不出来的那条**直接从线路列表里移除**，不置灰、不占位。
      _dropLine(lineId);
    }
    // 之后全自动：把本片**所有**线路依次试一遍，画面显示
    // 「正在尝试其他线路（2/11）」，用户不用点任何东西。
    if (player != null) {
      _lineChainWatchdog?.cancel();
      fxPlayLog(
        'chain line=$lineId stage=auto-all total=${_detail?.lines.length ?? 0}',
      );
      unawaited(player.autoTryAllLines());
      return;
    }
    _switchNextLine(auto: true, issue: issue);
  }

  /// 把一条播不出来的线路从当前详情里剔除（列表、两行选择器、播放页线路面板
  /// 用的都是这一份 `_detail.lines`，所以一处移除处处消失）。
  void _dropLine(String id) {
    final d = _detail;
    if (d == null || id.isEmpty) return;
    final rest = <LineInfo>[
      for (final l in d.lines)
        if (l.id != id) l,
    ];
    if (rest.length == d.lines.length) return;
    fxPlayLog('chain drop line=$id rest=${rest.length}');
    if (!mounted) return;
    setState(() => _detail = d.copyWith(lines: rest));
  }

  /// 挂 / 重置自动换线哨兵（详见字段 [_lineChainWatchdog]）。
  ///
  /// 5 秒后看两件事：
  ///   · 已经出画面（不在错误层）→ 什么都不用做；
  ///   · 已经有一轮在跑（`autoChainRunning`）→ 别开第二轮打断它；
  ///   · 还是错误层且没人在跑 → 直接整轮（`autoTryAllLines`），
  ///     并由它走完「全部线路 → 跨源」的后半段。
  void _armLineChainWatchdog() {
    _lineChainWatchdog?.cancel();
    _lineChainWatchdog = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      final player = _playerKey.currentState;
      if (player == null) {
        _switchNextLine(auto: true);
        return;
      }
      if (!player.showingError) return;
      if (player.autoChainRunning) return;
      fxPlayLog('chain watchdog → 整轮线路自动尝试');
      unawaited(player.autoTryAllLines());
    });
  }

  /// 本片所有线路都试完仍不可播：继续第 2 / 3 段（同源其他版本 → 跨源同名）。
  void _onAllLinesFailed() {
    if (!mounted) return;
    // 本片线路已经轮完：接下来的动作由跨源降级接手，哨兵不用再开枪。
    _lineChainWatchdog?.cancel();
    unawaited(_attemptSourceFallback());
  }

  /// 用户点了最终失败页的「重试」：**重新从第一条线路开始**，并允许再跨源找一次。
  void _onRetryAllLines() {
    if (!mounted) return;
    _fallback = null;
    _fallbackDone = false;
    _fallbackBusy = false;
    _failedLines.clear();
    _autoLineTries = 0;
    _retriedLine = null;
    _stableTimer?.cancel();
    _lineChainWatchdog?.cancel();
  }

  /// 播放稳定 3 秒后才清空失败集合与自动重试预算，避免「能 open 但立刻报错」
  /// 的线路在 A/B 之间无限乒乓。
  void _onPlaybackStarted() {
    // CHAIN_WATCHDOG：出画面了 = 这一轮失败已经翻篇，哨兵撤掉。
    _lineChainWatchdog?.cancel();
    // 真正出声了才算看过：这时才允许回写历史集数。
    if (!_played) {
      _played = true;
      _saveHistory();
    }
    _stableTimer?.cancel();
    _stableTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _failedLines.clear();
      _autoLineTries = 0;
      _retriedLine = null;
    });
  }

  void _onEpChange(int n) {
    if (n == _ep) return;
    setState(() => _ep = n);
    _saveHistory();
  }

  void _selectEpisode(int n) {
    // 已下载的集优先播本地文件，不再走在线线路。
    if (_downloads.isCached(widget.id, n)) {
      unawaited(_playOffline(n));
      return;
    }
    _selectOnlineEpisode(n);
  }

  void _selectOnlineEpisode(int n, {bool parsed = false}) {
    if (n == _ep) {
      _scrollToPlayer();
      return;
    }
    // 需要 hxparse 的线路：这一集还没解析过就先解析（「解析中」提示），
    // 解析失败留在当前这一集，不切到播不出来的集数。
    if (!parsed && _cmsBacked) {
      final line = _currentLine;
      if (line != null &&
          line.needsParse &&
          FxPlayCache.peek(widget.id, n, line.id) == null) {
        unawaited(_parseEpThenSelect(line, n));
        return;
      }
    }
    setState(() {
      _ep = n;
      _groupIndex = _groupIndexOf(_episodeGroups, n);
    });
    _saveHistory();
    _scrollToPlayer();
  }

  /// 当前选中的线路（选集时判断要不要先解析）。
  LineInfo? get _currentLine {
    for (final l in _detail?.lines ?? const <LineInfo>[]) {
      if (l.id == _lineId) return l;
    }
    return null;
  }

  Future<void> _parseEpThenSelect(LineInfo line, int n) async {
    if (!await _ensureParsed(line, n)) return;
    if (!mounted) return;
    _selectOnlineEpisode(n, parsed: true);
  }

  /// [ep] 所在分组下标：让选集条停在能看到这一集的分组（默认正片组）。
  int _groupIndexOf(List<EpisodeGroup> groups, int ep) {
    for (var i = 0; i < groups.length; i++) {
      if (groups[i].episodes.any((e) => e.n == ep)) return i;
    }
    return 0;
  }

  /// 播本地缓存：先暂停内嵌播放器，退出离线页后按原状态恢复。
  Future<void> _playOffline(int n) async {
    final task = _downloads.taskFor(widget.id, n);
    final file = task == null ? null : await _downloads.fileFor(task);
    if (!mounted) return;
    if (task == null || file == null) {
      fxToast(context, '本地缓存文件已丢失，改为在线播放');
      _selectOnlineEpisode(n);
      return;
    }
    final player = _playerKey.currentState;
    final wasPlaying = await player?.pauseAndSave() ?? false;
    if (!mounted) return;
    try {
      await Navigator.of(context).push(
        FxPageRoute(
          builder: (_) => OfflinePlayerPage(task: task, file: file),
        ),
      );
    } finally {
      if (mounted) {
        await player?.resumeAfterCover(play: wasPlaying);
      }
    }
  }

  void _scrollToPlayer() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _openEpisodes() async {
    final eps = _episodes;
    if (eps.isEmpty) {
      fxToast(context, '暂无剧集信息');
      return;
    }
    final n = await showDetailEpisodeSheet(
      context,
      episodes: eps,
      current: _ep,
      isCached: (ep) => _downloads.isCached(widget.id, ep),
    );
    if (!mounted || n == null) return;
    _selectEpisode(n);
  }

  Future<void> _refreshPlayer() async {
    _stableTimer?.cancel();
    _failedLines.clear();
    _autoLineTries = 0;
    _retriedLine = null;
    fxToast(context, '正在刷新播放源…');
    final state = _playerKey.currentState;
    if (state != null) {
      await state.reload();
    } else {
      await _loadDetail(silent: true);
    }
    if (!mounted) return;
  }

  /// 详情 → 详情：新页面压栈前先暂停并保存当前播放进度，
  /// 返回时只有原本在播放才恢复，避免两层播放器同时出声。
  Future<void> _openRelated(String id) async {
    if (_openingRelated) return;
    _openingRelated = true;
    try {
      final player = _playerKey.currentState;
      final wasPlaying = await player?.pauseAndSave() ?? false;
      if (!mounted) return;
      try {
        if (!mounted) return;
        await Nav.detail(context, id);
      } finally {
        if (mounted) {
          await player?.resumeAfterCover(play: wasPlaying);
        }
      }
    } finally {
      _openingRelated = false;
    }
  }

  Future<void> _refresh() async {
    // 下拉刷新算一次新的补线预算：取消挂起的重试，重新数 2 次。
    _lineRefreshTimer?.cancel();
    _lineRefreshTimer = null;
    _lineRefreshTries = 0;
    // 手动刷新同样把「自动重试一次」的额度还回去（DETAIL_RETRY）。
    _autoRetried = false;
    // 下拉刷新必须绕过主站详情缓存，否则线路 / 集数永远刷不出来。
    await _loadDetail(silent: true, fresh: true);
    if (!mounted) return;
    await _loadComments(reset: true, silent: true);
  }

  Future<void> _download() async {
    final d = _detail;
    if (d == null) {
      fxToast(context, '剧集信息加载中，请稍后再试');
      return;
    }
    final episodes = _episodes;
    if (episodes.isEmpty) {
      fxToast(context, '暂无剧集信息');
      return;
    }
    try {
      await DownloadService.instance.init();
      if (!mounted) return;
      final count = await showDownloadSheet(
        context,
        videoId: d.id,
        title: d.title,
        cover: d.cover,
        lineId: _lineId,
        lineName: _lineName,
        episodes: episodes,
        currentEp: _ep,
        year: d.year,
        isMovie: d.category.contains('电影'),
      );
      if (!mounted || count == null) return;
      if (count == 0) {
        fxToast(context, '所选剧集已在缓存队列中');
      } else {
        fxToast(context, '已加入离线缓存');
      }
    } catch (e) {
      if (!mounted) return;
      fxToast(context, '加入下载失败，请稍后重试');
    }
  }

  Future<void> _together() async {
    if (_openingTogether) return;
    _openingTogether = true;
    try {
      // 先读当前线路 / 集数 / 进度，再释放详情页内嵌播放器；
      // 房间只保留一起看自己的播放器。
      final state = _playerKey.currentState;
      final line = (state?.currentLine.trim().isNotEmpty ?? false)
          ? state!.currentLine
          : _lineId;
      final ep = state?.currentEp ?? _ep;
      final position = state?.currentPosition ?? Duration.zero;
      final playing = state?.currentPlaying ?? false;
      await state?.pauseAndReleaseForTogether();
      if (!mounted) return;
      final TogetherExitResult? result = await Nav.together(
        context,
        videoId: widget.id,
        ep: ep,
        line: line,
        position: position.inMilliseconds / 1000.0,
        playing: playing,
      );
      if (!mounted) return;
      final player = _playerKey.currentState;
      if (result == null) {
        // 没真正进房间（入口页直接返回）：按进房前的状态恢复。
        await player?.resumeAfterTogether();
        return;
      }
      if (result.videoId.isNotEmpty && result.videoId != widget.id) {
        // 房间已换到另一部片：不能拿旧片的集数/进度重播。
        fxToast(context, '房间已切换到其他影片');
        player?.showSourceError('房间已切换到其他影片');
        return;
      }
      final targetEp = result.ep > 0 ? result.ep : ep;
      final targetLine =
          result.lineId.trim().isNotEmpty ? result.lineId.trim() : line;
      final ok = await player?.resumeAfterTogether(
            ep: targetEp,
            line: targetLine,
            position: result.position,
            play: result.playing,
          ) ??
          false;
      if (!mounted || !ok) return;
      // 播放器内部已切到房间的集/线，详情页同步刷新，
      // 否则下一次 rebuild 会用旧集把它们又切回去。
      setState(() {
        _ep = targetEp;
        if (targetLine.isNotEmpty) _lineId = targetLine;
      });
      _saveHistory();
    } finally {
      _openingTogether = false;
    }
  }

  void _onCommentTap() {
    fxToast(context, '当前为游客模式，登录后即可发表评论');
  }

  /// 把 jar 源的同名子线路合并进当前记录（FUSION 2026-11-21）。
  ///
  /// 命中来源有两条：
  ///   1. 搜索时 jar 波次命中了这部片 —— `JarMergeIndex` 里已经有记录；
  ///   2. jar 插件**装好之后**进详情 / 详情页开着时装好了（[fillHits]）——
  ///      按片名现场补一次命中。没有这一条，冷启动边装边用时四个 jar 大类
  ///      会一直置灰（用户 2026-11-21 实测的第二个问题）。
  ///
  /// 无论哪条路，都只在 **jar 已就绪** 时才会真的向 jar 源发请求：
  /// [CmsBridge.fillJarHitsFor] / [CmsBridge.jarLinesFor] 进来先看 `jarReady`。
  Future<void> _mergeJarLines(VideoDetail d, {bool fillHits = false}) async {
    if (_jarMerging || CmsBridge.isJarLine(_lineId)) return;
    _jarMerging = true;
    // JAR_PENDING：取线路的整个过程（补命中 + 拉详情）都挂着「加载中」占位，
    // 用户看到的第一行永远是 `咕噜(加载中) / 幻想` 这个固定顺序。
    if (_jarUsable) _startJarPending();
    try {
      // JAR_BOOT（2026-11-21）：jar 刚装好时索引里通常没有这部片（搜索那一轮
      // 被整段跳过了）。这里按片名补一次命中，否则四个 jar 大类会一直置灰。
      // jar 没装时 [CmsBridge.fillJarHitsFor] 直接返回 0，一条请求都不发。
      if (fillHits) await CmsBridge.fillJarHitsFor(d);
      final extra = await CmsBridge.jarLinesFor(d);
      if (!mounted) return;
      final current = _detail;
      if (current == null) return;
      // 同一个 id / 同名子线路只留一条（用户口径：「咕噜·4K」只出现一次）。
      final haveId = <String>{for (final line in current.lines) line.id};
      final haveName = <String>{for (final line in current.lines) line.name};
      final add = <LineInfo>[
        for (final line in extra)
          if (!haveId.contains(line.id) && !haveName.contains(line.name)) line,
      ];
      if (add.isEmpty) {
        debugPrint('[JAR_PENDING] 这部片在 jar 源里没有线路，大类回落到幻想');
        return;
      }
      final merged = fxOwnLinesFirst(
        LineHealth.instance.rankLines(widget.id, <LineInfo>[
          ...current.lines,
          ...add,
        ]),
      );
      setState(() {
        _detail = current.copyWith(lines: merged);
      });
      // JAR_FIRST（2026-11-22）：线路到齐后**默认选中咕噜的第一条子线路**。
      _applyJarDefault(merged);
      FxPlayCache.warm(widget.id, _ep, _lineId);
    } catch (e) {
      debugPrint('jar merge failed: $e');
    } finally {
      _jarMerging = false;
      _jarMergeDone = true;
      _stopJarPending();
      // 线路已定（含咕噜默认）→ 放心起播，这一次就是最终线路。
      _stopJarBootWait();
    }
  }

  /// JAR_FIRST（2026-11-22）：jar 线路到齐后，把默认线路落到**咕噜的第一条
  /// 子线路**上（用户口径：「优先使用咕噜」）。
  ///
  /// 判据只有两条：
  ///   1. 用户还没亲手点过线路（[_linePickedByUser]）——点过就永远听用户的；
  ///   2. 咕噜真给了线路（[fxJarDefaultLine] 非空）。
  ///
  /// 已经在播自有线路时**同样切**：用户要的就是「优先咕噜」，而切换走的是
  /// 播放器自己的换线通道（`PlayerView.didUpdateWidget → _switchLine`）——
  /// 记住当前集 + 进度、最多回退 3 秒续播，不是从头再来，也不弹 toast。
  /// 播放器在详情页一挂上就会 bootstrap 自有线路，不在这里切的话，「默认
  /// 咕噜」在真实使用里几乎永远轮不到（首帧播放往往比 jar 搜片名快）。
  void _applyJarDefault(List<LineInfo> lines) {
    if (!mounted || _linePickedByUser) return;
    final pick = fxJarDefaultLine(lines);
    if (pick == null || pick.id == _lineId) return;
    final current = _detail;
    if (current == null) return;
    // JAR_AUTO_SAME_PATH（2026-11-22 用户实测）：自动默认选中**必须走手动
    // 选线同一条路径**（_selectLineReady），而不是自己 setState 改 _lineId。
    // 差异在手动路径会清掉 _failedLines / _retriedLine / _autoLineTries 并
    // 夹集数；只改 _lineId 时这些状态原样保留 —— 用户实测「手动切咕噜能播、
    // 自动默认选中一直 0KB」就是这个状态差：自动切带着旧的失败/重试状态，
    // 播放器判定「这条试过了」不再重试，一次失败就永远卡在 0KB。
    debugPrint('[JAR_FIRST] 默认线路 = ${pick.displayName}（咕噜优先，走手动同路径）');
    _selectLineReady(pick);
    // JAR_WARM_DETAIL（2026-11-22）：趁用户还在详情页，把咕噜这条线首片拉热。
    // 咕噜分片的 CDN 边缘冷命中要回源 10~25 秒、热命中 1.6 秒；这一步把冷
    // 回源挪到「浏览详情」的时间里，用户点播放时就是热命中。
    unawaited(_warmJarDefaultLine(pick));
  }

  /// 把默认 jar 线路的首片提前拉热（fire-and-forget，失败静默）。
  ///
  /// 只做预热：拿到的地址不参与播放（播放时仍然现签一条新的），所以哪怕
  /// 令牌几秒后失效也不影响任何事 —— 变的只是 CDN 边缘的缓存状态。
  Future<void> _warmJarDefaultLine(LineInfo line) async {
    try {
      final info = await CmsBridge.play(widget.id, _ep, line.id);
      final url = CmsBridge.absolutePlayUrl(widget.id, info.url);
      if (url.isEmpty) return;
      unawaited(FxPlayer.warmJarFirstSegment(url, headers: info.headers));
    } catch (_) {
      // 预热失败不影响任何用户可见行为。
    }
  }

  /// ENRICH（2026-11-15）：按「片名 + 年份」补两条线路。
  ///
  /// 只补 `幻想爱奇艺` 与 `SH4K`（福盈蓝光 PAN1 的解析接口坏了，补上去是
  /// 死线路，明确不补）。集数按对方实际集数，探不到就不补；命中缓存 24 小时。
  /// 补进来的线路 id 带 `enrich:` 前缀，播放地址由 `LineEnrich.resolvePlay`
  /// 现算 —— 服务端库一行都不改。
  Future<void> _enrichLines(VideoDetail d) async {
    final EnrichEntry? entry;
    try {
      entry = await LineEnrich.instance.enrich(
        title: d.title,
        year: d.year,
        existing: d.lines,
        episodes: d.lines.isEmpty ? null : d.lines.first.epNames.length,
      );
    } catch (e, st) {
      debugPrint('enrich failed: $e\n$st');
      return;
    }
    if (!mounted || entry == null || entry.usable.isEmpty) return;
    final current = _detail;
    if (current == null) return;
    final extra = LineEnrich.instance.linesOf(entry);
    final have = <String>{for (final line in current.lines) line.id};
    final add = <LineInfo>[
      for (final line in extra)
        if (!have.contains(line.id)) line,
    ];
    if (add.isEmpty) return;
    setState(() {
      _detail = current.copyWith(
        lines: fxOwnLinesFirst(
          LineHealth.instance.rankLines(widget.id, <LineInfo>[
            ...current.lines,
            ...add,
          ]),
        ),
      );
    });
  }

  /* ---------------------------------------------------------------- ui */

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    // 白底 + 黑色线框：浅色纯白，深色自动反成深底（见 FxDetailSkin）。
    final skin = FxDetailSkin.of(context);
    return Scaffold(
      backgroundColor: skin.page,
      resizeToAvoidBottomInset: false,
      bottomNavigationBar: d != null && _tab == 1
          ? DetailCommentInput(onTap: _onCommentTap)
          : null,
      body: ColoredBox(
        color: skin.page,
        child: SafeArea(
          bottom: false,
          child: d == null ? _buildEntryState() : _buildPage(d),
        ),
      ),
    );
  }

  Widget _buildEntryState() {
    if (_invalid) {
      // 已失效的作品：一个提示 + 一个删除按钮，不给「重试」（必然失败），
      // 也不弹第二个错误对话框。
      return Column(
        children: [
          _backBar('详情'),
          Expanded(
            child: FxEmptyView(
              icon: Icons.link_off_rounded,
              title: '该视频已失效',
              subtitle: '该视频可能已被下架或删除，暂时无法播放。\n可以把这条观看记录删掉。',
              actionText: '删除这条记录',
              onAction: () => unawaited(_deleteGoneRecord()),
            ),
          ),
        ],
      );
    }
    if (_error != null) {
      return Column(
        children: [
          _backBar('详情'),
          Expanded(
            child: FxErrorView(
              message: _error!,
              onRetry: () {
                // 手点重试 = 重新给满额度（自动重试还能再来一次）。
                _autoRetried = false;
                setState(() => _error = null);
                _loadDetail(fresh: true);
              },
            ),
          ),
        ],
      );
    }
    return Column(
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Colors.white70,
                    ),
                  ),
                ),
                Positioned(
                  left: 8,
                  top: 8,
                  child: PGlassIcon(
                    icon: Icons.arrow_back_ios_new_rounded,
                    size: 34,
                    iconSize: 17,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: _loadingBody()),
      ],
    );
  }

  /// 详情还没回来时的下半屏（DETAIL_SKELETON 2026-11-15）。
  ///
  /// 原来这里只有一个居中的转圈：外部源的详情要 9～15 秒，用户面前就是
  /// 一整片空白 + 一个圈，看起来和「页面卡死」没区别。搜索阶段已经知道的
  /// 封面 / 片名直接带进来先画出来（[DetailPage.cover] / [DetailPage.title]），
  /// 下面接骨架块 —— 第一帧就知道「点对了片子、正在取详情」。
  Widget _loadingBody() {
    final skin = FxDetailSkin.of(context);
    final title = widget.title.trim();
    final cover = widget.cover.trim();
    final meta = <String>[
      if (widget.year > 0) '${widget.year}',
      if (_sourceName.isNotEmpty) _sourceName,
    ].join(' · ');
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 96,
                height: 128,
                // 空封面时 FxCover 自己画「片名首字 + 渐变底」占位，
                // 不会留一块空白（COVER_FIX）。
                child: FxCover(url: cover, title: title, radius: 12),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.isEmpty ? '正在取详情…' : title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 17,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                        color: skin.ink,
                      ),
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: skin.body),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: skin.body,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _sourceName.isEmpty
                                ? '正在取线路和选集…'
                                : '正在从$_sourceName取线路和选集…',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: skin.body),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          FxSkeletonPulse(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _skeletonBar(skin, width: 120),
                const SizedBox(height: 10),
                _skeletonBar(skin),
                const SizedBox(height: 8),
                _skeletonBar(skin),
                const SizedBox(height: 16),
                _skeletonBar(skin, height: 34, radius: 10),
                const SizedBox(height: 14),
                _skeletonBar(skin, width: 96),
                const SizedBox(height: 10),
                SizedBox(
                  height: 52,
                  child: Row(
                    children: [
                      for (var i = 0; i < 4; i++) ...[
                        Expanded(
                            child: _skeletonBar(skin, height: 52, radius: 10)),
                        if (i != 3) const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 骨架条：用皮肤里的浅灰胶囊色，深色主题下也看得见。
  ///
  /// （[FxSkeletonBox] 是半透明白色，压在白色详情页上等于隐形。）
  Widget _skeletonBar(
    FxDetailSkin skin, {
    double? width,
    double height = 12,
    double radius = 4,
  }) =>
      Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: skin.chip,
          borderRadius: BorderRadius.circular(radius),
        ),
      );

  Widget _buildPage(VideoDetail d) {
    final skin = FxDetailSkin.of(context);
    return RefreshIndicator(
      onRefresh: _refresh,
      color: skin.body,
      backgroundColor: skin.surface,
      edgeOffset: 0,
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _playerHeader(d)),
          SliverToBoxAdapter(child: _topArea()),
          if (_tab == 0)
            SliverToBoxAdapter(child: _fadeWrap(_videoTab(d)))
          else
            ..._commentsSlivers(),
          SliverToBoxAdapter(
            child: SizedBox(height: 28 + MediaQuery.of(context).padding.bottom),
          ),
        ],
      ),
    );
  }

  Widget _backBar(String title) {
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            icon: Icon(Icons.arrow_back_ios_new_rounded,
                size: 20, color: FxDetailSkin.of(context).icon),
          ),
          Text(
            title,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: FxDetailSkin.of(context).ink,
            ),
          ),
        ],
      ),
    );
  }

  Widget _playerHeader(VideoDetail d) {
    // ASPECT_REAL（2026-11-15）：播放区高度跟视频真实比例走，不写死 16:9。
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // STAGE_FULLWIDTH（2026-11-15）：宽度撑满、高度 = 宽度 / 视频比例，
          // 且绝不低于 16:9（上一版把宽片收窄到 2.4:1、把竖屏短剧夹在 16:9，
          // 视频区明显变小）。竖屏短剧按自身比例变高，上限 62% 屏高，
          // 否则 9:16 的片子会把整页顶下去、选集要滑很远。
          final screenHeight = MediaQuery.sizeOf(context).height;
          final stageHeight = fxPlayerStageHeight(
            width: constraints.maxWidth,
            videoRatio: _videoAspect,
            maxHeight: screenHeight * .62,
          );
          // JAR_SINGLE_OPEN：等咕噜线路到齐再挂播放器 —— 否则会先起播自有
          // 线路、再被切到咕噜，用户看到的就是「加载两下然后 0 KB」。
          if (_jarBootWait && !_jarMergeDone) {
            return SizedBox(
              height: stageHeight,
              child: const _JarBootPlaceholder(),
            );
          }
          return SizedBox(
            height: stageHeight,
            child: PlayerView(
              key: _playerKey,
              videoId: widget.id,
              ep: _ep,
              line: _lineId,
              detail: d,
              onEpChange: _onEpChange,
              onSourceFailed: () => _reportLineIssue(SourceIssue.error),
              onSourceIssue: _reportLineIssue,
              onChangeLine: d.lines.length > 1 ? () => _switchNextLine() : null,
              onLineFallback: _onLineFallback,
              onSwitchingChanged: (busy) {
                if (!mounted || _playerSwitchingLine == busy) return;
                setState(() => _playerSwitchingLine = busy);
              },
              onVideoAspect: _onVideoAspect,
              onPlaybackStarted: _onPlaybackStarted,
              // AUTO_LINE_FULL：本片线路全试完 → 继续第 2 / 3 段（跨源）。
              onAllLinesFailed: _onAllLinesFailed,
              // 用户点最终失败页的「重试」：重置降级状态，重新从第一条开始。
              onRetryAllLines: _onRetryAllLines,
              autoPlay: true,
              // FX_FALLBACK：跨源换源带过来的起播位置（保持原集号与原进度）。
              startSeconds: widget.startSeconds,
            ),
          );
        },
      ),
    );
  }

  /// 内嵌播放器上报真实比例 → 播放区高度跟着变（拿不到时保持上一次的值）。
  void _onVideoAspect(double ratio) {
    if (!mounted || !ratio.isFinite || ratio <= 0) return;
    if ((ratio - _videoAspect).abs() < 0.001) return;
    setState(() => _videoAspect = ratio);
  }

  Widget _topArea() {
    final skin = FxDetailSkin.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          // 用户要求：详情页下面这两行公告不再显示
          // （「欢迎使用幻想影视…」和「温馨提示：本站不存储任何视频资源…」）
          // Flexible：大字号 / 窄屏时先让 tab 行占位，胶囊固定宽度不出框。
          Expanded(
            child: DetailTabs(
              index: _tab,
              onChanged: _switchTab,
              commentCount: _commentsLoaded
                  ? '${_comments.length}${_commentsHasMore ? '+' : ''}'
                  : null,
            ),
          ),
          const SizedBox(width: 10),
          // 参考图右侧那枚圆角胶囊：浅灰底 + 黑色线框搜索图标。
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => unawaited(Nav.search(context)),
            child: Container(
              width: 120,
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 11),
              decoration: BoxDecoration(
                color: skin.chip,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Icon(Icons.search_rounded, size: 15, color: skin.hint),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      '搜索影视',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: skin.hint),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /* ----------------------------------------------------------- video tab */

  Widget _videoTab(VideoDetail d) {
    final episodes = _episodes;
    final groups = _episodeGroups;
    final groupIndex =
        groups.isEmpty ? 0 : _groupIndex.clamp(0, groups.length - 1);
    final visibleEpisodes =
        groups.isEmpty ? episodes : groups[groupIndex].episodes;
    // LINE_OWN_COUNT（2026-11-14）：集数按**当前线路自己**的算。
    // 我们只把线路合并到一条记录里，剧集始终归属各线路自己，
    // 不能用合并后的总数（否则蓝光只有 6 集也显示 12 集）。
    final lineEpNames = () {
      final id = _lineId.trim();
      if (id.isEmpty) return const <String>[];
      for (final l in d.lines) {
        if (l.id == id && l.epNames.isNotEmpty) return l.epNames;
      }
      return const <String>[];
    }();
    final totalAll = lineEpNames.isNotEmpty
        ? lineEpNames.length
        : (d.episodes > 0
            ? d.episodes
            : (episodes.isNotEmpty ? fxMainEpisodeCount(episodes) : 0));
    final related = _relatedList;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顺序照参考图：提示小字 → 标题 / 简介 → 5 圆钮 → 线路 → 选集。
        _sourceHint(),
        _titleBlock(d),
        _actionRow(),
        const SizedBox(height: 16),
        // LINE_GROUPS（2026-11-21）：线路区改成**两行** ——
        // 第一行大类（幻想 / 咕噜 / 剧圈 / 橘汁 / 下饭），第二行该大类的子线路。
        // 组件在 `widgets/fx_line_group_selector.dart`，一起看三处入口共用同一份。
        // 一行自有线路都没有、但 jar 正在取线路时不摆「暂无线路」：
        // 直接把咕噜大类的「加载中」占位显示出来（JAR_PENDING）。
        if (d.lines.isNotEmpty || _jarPending)
          FxLineGroupSelector(
            lines: d.lines,
            currentLineId: _lineId,
            onSelected: _selectLine,
            // JAR_PENDING：咕噜正在取线路时先按「加载中」占位（顺序固定
            // 咕噜在前），拿到就原地填充，没有就整条消失 —— 不会出现
            // 「先显示幻想，等线路补上再整体跳成咕噜」的错位。
            pendingGroups: _jarPending ? kEnabledJarSources : const <String>[],
          )
        else if (_lineRefreshTimer != null)
          // 补线进行中：同尺寸骨架占位，线路到了直接替换，不跳版。
          SizedBox(height: 76, child: _linePlaceholder())
        else
          _noLinesHint(),
        // JAR_BOOT（2026-11-21 用户要求第 4 条）：jar 没装时说清楚为什么那四个
        // 大类是灰的，并给出装的地方（搜索页用同一句话，见 SourceHub.jarNotice）。
        if (SourceHub.instance.jarMissing) _jarNotReadyHint(),
        if (visibleEpisodes.isNotEmpty) ...[
          const SizedBox(height: 22),
          _episodeHeader(totalAll, available: visibleEpisodes.length),
          if (groups.length > 1) ...[
            const SizedBox(height: 9),
            _episodeGroupTabs(groups, groupIndex),
          ],
          const SizedBox(height: 10),
          DetailEpisodeStrip(
            episodes: visibleEpisodes,
            current: _ep,
            onSelect: _selectEpisode,
            isCached: (ep) => _downloads.isCached(widget.id, ep),
          ),
        ],
        if (related.isNotEmpty) ...[
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DetailSectionTitle(
              title: '相关推荐',
              trailing: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _relatedOffset += 3),
                child: Row(
                  children: [
                    Icon(Icons.autorenew_rounded,
                        size: 14, color: FxDetailSkin.of(context).hint),
                    const SizedBox(width: 4),
                    Text('换一换',
                        style: TextStyle(
                            fontSize: 11.5,
                            color: FxDetailSkin.of(context).hint)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 190,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: related.length,
              separatorBuilder: (context, i) => const SizedBox(width: 9),
              itemBuilder: (context, i) => _relatedCard(related[i]),
            ),
          ),
        ],
      ],
    );
  }

  Widget _titleBlock(VideoDetail d) {
    final status = _statusText;
    final skin = FxDetailSkin.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        d.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 21,
                          height: 1.2,
                          fontWeight: FontWeight.w800,
                          color: skin.ink,
                        ),
                      ),
                    ),
                    if (d.rating > 0) ...[
                      const SizedBox(width: 6),
                      _scoreTag(d.rating),
                    ],
                    if (status.isNotEmpty) ...[
                      const SizedBox(width: 7),
                      _statusTag(status),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleDesc,
                child: Row(
                  children: [
                    Text('简介',
                        style: TextStyle(fontSize: 11.5, color: skin.hint)),
                    Icon(
                      _descOpen
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.chevron_right_rounded,
                      size: 17,
                      color: skin.hint,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleDesc,
            child: AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: Text(
                _descText,
                maxLines: _descOpen ? null : 2,
                overflow:
                    _descOpen ? TextOverflow.visible : TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.55,
                  color: skin.body,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 评分小标签：浅灰底圆角 + 深灰字（跟「高清」标签同一套）。
  Widget _scoreTag(num score) {
    final skin = FxDetailSkin.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: skin.chip,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_border_rounded, size: 11, color: skin.chipText),
          const SizedBox(width: 2),
          Text(
            score.toStringAsFixed(1),
            style: TextStyle(
              fontSize: 10,
              height: 1.1,
              fontWeight: FontWeight.w700,
              color: skin.chipText,
            ),
          ),
        ],
      ),
    );
  }

  /// 「高清 / 更新至 N 集」这类标签：浅灰底圆角小标签，文字深灰。
  Widget _statusTag(String text) {
    final skin = FxDetailSkin.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: skin.chip,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 9.5,
          height: 1.1,
          fontWeight: FontWeight.w600,
          color: skin.chipText,
        ),
      ),
    );
  }

  Widget _actionRow() {
    // 统一规格（参考图）：5 个直径 56 的白圆钮 + 黑色线框图标 + 12px 深灰标签。
    // 投屏不占这一行的槽位（参考图的第 4 格是「反馈」），投屏入口仍在播放器
    // 浮层里（player_page.dart 的 openCastSheet），能力没有丢。
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 16, 6, 0),
      child: Row(
        children: [
          Expanded(
            child: DetailActionButton(
              icon: Icons.star_border,
              activeIcon: Icons.star,
              label: _fav ? '已收藏' : '收藏',
              active: _fav,
              onTap: _toggleFav,
            ),
          ),
          Expanded(
            child: DetailActionButton(
              icon: Icons.file_download_outlined,
              label: '下载',
              onTap: _download,
            ),
          ),
          Expanded(
            child: DetailActionButton(
              icon: Icons.refresh,
              label: '刷新',
              onTap: _refreshPlayer,
            ),
          ),
          Expanded(
            child: DetailActionButton(
              icon: Icons.edit_outlined,
              label: '反馈',
              onTap: _feedback,
            ),
          ),
          Expanded(
            child: DetailActionButton(
              icon: Icons.tv_outlined,
              label: '一起看',
              onTap: _together,
            ),
          ),
        ],
      ),
    );
  }

  /// 反馈：进现有的意见反馈页（`POST /api/feedback`），不带任何剧集上下文，
  /// 和设置页里的「意见反馈」是同一个入口。
  void _feedback() {
    unawaited(Navigator.of(context).push(
      FxPageRoute(builder: (_) => const FeedbackPage()),
    ));
  }

  // NO_HINT（2026-11-15）：用户要求删掉这类线路提示文案，
  // 不要把问题甩给用户；线路失败由自动切线/换源处理，不需要文案。
  Widget _sourceHint() => const SizedBox.shrink();

  /// 补线中的占位骨架：与线路卡片同尺寸、同起点，平台线补到时直接原地
  /// 替换成真实卡片，页面不会先空一块再撑开。
  Widget _linePlaceholder() {
    final skin = FxDetailSkin.of(context);
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: 3,
      separatorBuilder: (_, __) => const SizedBox(width: 8),
      itemBuilder: (_, __) => Container(
        width: 102,
        height: 60,
        decoration: BoxDecoration(
          color: skin.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: skin.hairline),
        ),
      ),
    );
  }

  /// 「jar 未就绪」提示条：只在 jar 没装、且确实有启用的 jar 源时出现。
  ///
  /// 它不是错误 —— 自有线路照常能播；这条只解释「第一行那四个 jar 大类为什么
  /// 是灰的」，免得用户以为功能坏了（用户 2026-11-21 截图里的第二个问题）。
  Widget _jarNotReadyHint() {
    final skin = FxDetailSkin.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.extension_off_rounded, size: 13, color: skin.hint),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              SourceHub.instance.jarNotice,
              style: TextStyle(
                fontSize: 10.5,
                height: 1.45,
                color: skin.hint,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _noLinesHint() {
    final skin = FxDetailSkin.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: skin.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: skin.hairline),
        ),
        child: Row(
          children: [
            Icon(Icons.wifi_off_outlined, size: 16, color: skin.hint),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '暂无线路，请稍后刷新重试',
                style: TextStyle(fontSize: 11.5, color: skin.hint),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _episodeGroupTabs(List<EpisodeGroup> groups, int current) {
    final skin = FxDetailSkin.of(context);
    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: groups.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final active = i == current;
          final raw = groups[i].name.trim();
          final name = raw.isEmpty ? (i == 0 ? '正片' : '花絮') : raw;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _groupIndex = i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: active ? skin.chip : skin.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: active ? skin.ink : skin.hairline,
                ),
              ),
              child: Text(
                name,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? skin.ink : skin.body,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _episodeHeader(int total, {int available = 0}) {
    final skin = FxDetailSkin.of(context);
    final avail = available > 0 ? available : total;
    // 电影没有集数概念：一条是「正片」，多条是「国语 / 粤语」这类版本
    final title = _isMovie
        ? (total > 1 ? '正片 · $total 个版本' : '正片')
        : (total > 0 ? '更新至 $avail 集 · 全 $total 集' : '选集');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: skin.ink,
              ),
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _openEpisodes,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: Row(
                children: [
                  Text('查看全部',
                      style: TextStyle(fontSize: 11.5, color: skin.hint)),
                  Icon(Icons.chevron_right_rounded, size: 16, color: skin.hint),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _openEpisodes,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: skin.surface,
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(color: skin.hairline),
                  ),
                  child: Text(
                    '选集',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: skin.ink,
                    ),
                  ),
                ),
                if (total > 0)
                  Positioned(
                    right: -6,
                    top: -6,
                    child: Container(
                      constraints:
                          const BoxConstraints(minWidth: 17, minHeight: 17),
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: skin.chip,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: skin.page, width: 1.2),
                      ),
                      child: Text(
                        '$total',
                        style: TextStyle(
                          fontSize: 8.5,
                          height: 1.1,
                          color: skin.chipText,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _relatedCard(VideoCard v) {
    return SizedBox(
      width: 104,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          FxPosterCard(
            item: v,
            width: 104,
            showSubtitle: false,
            onTap: () => _openRelated(v.id),
          ),
          if (v.year > 0)
            Positioned(
              left: 6,
              top: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .42),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${v.year}',
                  style: const TextStyle(
                    fontSize: 9,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /* --------------------------------------------------------- comments tab */

  Widget _fadeWrap(Widget child) {
    return AnimatedBuilder(
      animation: _fade,
      builder: (context, child) {
        final t = Curves.easeOut.transform(_fade.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - t)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }

  /// 评论列表可能一次加载几十条：拆成 SliverList + builder，
  /// 只构建屏幕内的评论，而不是在 Column 里一次性全部 build。
  List<Widget> _commentsSlivers() {
    final list = _comments;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Row(
        children: [
          Text(
            '全部评论',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: FxDetailSkin.of(context).ink,
            ),
          ),
          const SizedBox(width: 6),
          if (list.isNotEmpty)
            Text(
              '${list.length}',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: FxDetailSkin.of(context).body,
              ),
            ),
          const Spacer(),
          Icon(Icons.local_fire_department_outlined,
              size: 13, color: FxDetailSkin.of(context).hint),
          const SizedBox(width: 2),
          Text('按热度',
              style: TextStyle(
                  fontSize: 10.5, color: FxDetailSkin.of(context).hint)),
        ],
      ),
    );

    if (list.isEmpty) {
      return [
        SliverToBoxAdapter(child: _fadeWrap(header)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _commentsEmptyView(),
          ),
        ),
      ];
    }

    return [
      SliverToBoxAdapter(child: _fadeWrap(header)),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              final c = list[i];
              final key = _commentKey(c);
              return RepaintBoundary(
                child: DetailCommentTile(
                  key: ValueKey<String>(key),
                  item: c,
                  liked: _liked.contains(key),
                  onLike: () => _toggleCommentLike(key),
                ),
              );
            },
            childCount: list.length,
          ),
        ),
      ),
      SliverToBoxAdapter(child: _commentsFooter()),
    ];
  }

  void _toggleCommentLike(String key) {
    setState(() {
      if (_liked.contains(key)) {
        _liked.remove(key);
      } else {
        _liked.add(key);
      }
    });
  }

  Widget _commentsEmptyView() {
    if (_commentsLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 34),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2.3,
              color: FxDetailSkin.of(context).body,
            ),
          ),
        ),
      );
    }
    if (_commentError != null) {
      return FxErrorView(
        message: _commentError!,
        compact: true,
        onRetry: () => _loadComments(reset: true),
      );
    }
    return const FxEmptyView(
      icon: Icons.forum_outlined,
      title: '还没有评论',
      subtitle: '登录后来说两句，抢个沙发吧',
    );
  }

  Widget _commentsFooter() {
    final skin = FxDetailSkin.of(context);
    if (_commentsLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: skin.body,
            ),
          ),
        ),
      );
    }
    if (_commentsHasMore) {
      return Center(
        child: TextButton(
          onPressed: () => _loadComments(reset: false),
          child: Text(
            '加载更多评论',
            style: TextStyle(fontSize: 12, color: skin.body),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Text(
          '— 已经到底啦 —',
          style: TextStyle(fontSize: 10.5, color: skin.hint),
        ),
      ),
    );
  }
}

/// JAR_SINGLE_OPEN：等咕噜线路到齐时的播放区占位。
///
/// 只占位置、不动播放器 —— 合并一结束它就被真正的 [PlayerView] 换掉，
/// 那一次起播用的就是最终线路（默认咕噜），不会再有「先播幻想再切咕噜」。
class _JarBootPlaceholder extends StatelessWidget {
  const _JarBootPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Colors.black,
      child: Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(
              strokeWidth: 2.4, color: Colors.white70),
        ),
      ),
    );
  }
}

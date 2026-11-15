import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../main.dart' show Nav;
import '../models.dart';
import '../services/cms_bridge.dart';
import '../services/download_service.dart';
import '../services/fallback_match.dart';
import '../services/fx_player.dart';
import '../services/line_cooldown.dart';
import '../services/line_enrich.dart';
import '../services/line_health.dart';
import '../services/play_log.dart';
import '../services/source_fallback.dart';
import '../services/source_hub.dart';
import '../services/fx_video_geometry.dart';
import '../widgets/detail_widgets.dart';
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
    this.retried = false,
    this.startSeconds,
    this.fallbackHops = 0,
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

  /// 已经按片名重查过一次（换到新记录的那个页面不再重查，避免来回跳）。
  final bool retried;

  /// 起播位置（秒），null = 按本地保存的进度续播。
  ///
  /// FX_FALLBACK（2026-11-15）：跨源换源会 pushReplacement 到这个页面打开
  /// **另一条记录**；当前集号由 [ep] 带入，播放进度由它带入 ——
  /// 「第 5 集看到 12:34，换源后还是第 5 集 12:34」。
  final double? startSeconds;

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

  /// 服务端平台线路是异步计算的：首屏没有平台线时，2.5 秒后再拉一次
  /// /api/detail 把平台线补上，最多补 2 次；只合并 lines，不重载页面、
  /// 不重建播放器。补线期间线路区一直占着固定高度，布局不跳动。
  Timer? _lineRefreshTimer;
  int _lineRefreshTries = 0;

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
    _init();
  }

  void _onDownloadsChanged() {
    if (mounted) setState(() {});
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
    _downloads.removeListener(_onDownloadsChanged);
    _stableTimer?.cancel();
    _lineRefreshTimer?.cancel();
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
    try {
      // DETAIL_TIMEOUT（2026-11-15）：详情整条链（主站 8 秒 ×2 重试、
      // 外部源、jar 源）都必须有一个总上限 —— 页面不能一直转圈。
      // jar 源自己已经有 8 秒硬超时（CmsBridge._jarGuard），这里是最后一道，
      // 12 秒还没回来就按「加载失败」给文案 + 重试入口。
      final d = await CmsBridge.detail(widget.id, fresh: fresh).timeout(
        const Duration(seconds: 12),
        onTimeout: () => throw ApiException(
          '加载超时了，换个网络或稍后重试',
          kind: ApiErrorKind.timeout,
        ),
      );
      if (!mounted || req != _detailReq) return;
      _cmsBacked = CmsBridge.isCms(widget.id);

      final lines = d.lines;
      var lineId = _lineId;
      if (lineId.isEmpty || !lines.any((l) => l.id == lineId)) {
        if (lines.any((l) => l.id == widget.line)) {
          lineId = widget.line;
        } else {
          // LINE_COOLDOWN（2026-11-15）：10 分钟内失败过的线路沉到最后 ——
          // 「下次打开同一部剧，最近失败过的排在同分辨率后面，10 分钟后
          // 恢复原权重」。这里只是默认值，用户手动点哪条仍然尊重。
          final ordered = FxLineCooldown.sortLines(widget.id, lines);
          lineId = ordered.isEmpty ? '' : ordered.first.id;
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
          lines: LineHealth.instance.rankLines(widget.id, d.lines),
        );
        _lineId = lineId;
        _ep = ep;
        _error = lines.isEmpty ? '这部片暂无可播放地址' : null;
        // 从历史 / 播放器带集数进来时，选集条要切到能看见这一集的分组，
        // 才能高亮并滚动到对应集数。
        _groupIndex = _groupIndexOf(_episodeGroups, ep);
      });
      // ENRICH（2026-11-15）：搜索命中后补线路（幻想爱奇艺 / SH4K）。
      // 后台跑，不阻塞详情页；命中就追加到线路列表，并参与现有排序
      // （付费线在前、按实测分辨率）与自动切线。
      unawaited(_enrichLines(d));
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
        }
        return;
      }
      final msg = fxErrorText(e);
      setState(() => _error = msg);
      if (_detail != null) fxToast(context, msg);
    }
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
    final index = lines.indexWhere((l) => l.id == _lineId);
    LineInfo? next;
    for (var step = 1; step <= lines.length; step++) {
      final candidate = lines[(index + step) % lines.length];
      if (_failedLines.contains(candidate.id)) continue;
      if (auto && candidate.id == _lineId) continue;
      next = candidate;
      break;
    }
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
  /// 第 3 段  跨源找同名       再去外部源（肥猫的 jar 源）搜
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
        jarSkipped: outcome.jarSkipped,
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
    bool jarSkipped = false,
  }) {
    final lines = _detail?.lines ?? const <LineInfo>[];
    String message;
    if (lines.isEmpty) {
      message = '暂无线路，请稍后刷新重试';
    } else {
      message = fxFallbackAllFailedText;
      final tail = note.trim();
      if (tail.isNotEmpty) message = '$message（$tail）';
      // 第 3 段因为 jar 没装被跳过：说清是「没装插件」，不是「没有这部片」。
      if (jarSkipped) message = '$message · 装好 jar 插件（spider.jar）后可跨源再找一次';
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
      unawaited(player.reload());
      return;
    }
    if (lineId.isNotEmpty) _failedLines.add(lineId);
    // 之后全自动：把本片**所有**线路依次试一遍，画面显示
    // 「正在尝试其他线路（2/11）」，用户不用点任何东西。
    if (player != null) {
      unawaited(player.autoTryAllLines());
      return;
    }
    _switchNextLine(auto: true, issue: issue);
  }

  /// 本片所有线路都试完仍不可播：继续第 2 / 3 段（同源其他版本 → 跨源同名）。
  void _onAllLinesFailed() {
    if (!mounted) return;
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
  }

  /// 播放稳定 3 秒后才清空失败集合与自动重试预算，避免「能 open 但立刻报错」
  /// 的线路在 A/B 之间无限乒乓。
  void _onPlaybackStarted() {
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
        lines: LineHealth.instance.rankLines(widget.id, <LineInfo>[
          ...current.lines,
          ...add,
        ]),
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
                setState(() => _error = null);
                _loadDetail();
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
        Expanded(
          child: Center(
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: FxDetailSkin.of(context).body,
            ),
          ),
        ),
      ],
    );
  }

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
          return SizedBox(
            height: fxPlayerStageHeight(
              width: constraints.maxWidth,
              videoRatio: _videoAspect,
            ),
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
    final total =
        episodes.isNotEmpty ? fxMainEpisodeCount(episodes) : d.episodes;
    final related = _relatedList;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顺序照参考图：提示小字 → 标题 / 简介 → 5 圆钮 → 线路 → 选集。
        _sourceHint(),
        _titleBlock(d),
        _actionRow(),
        const SizedBox(height: 16),
        // 线路区固定 60px：平台线后到时原地填充，标题 / 选集不整体下移。
        SizedBox(
          height: 60,
          child: d.lines.isNotEmpty
              ? ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: d.lines.length,
                  separatorBuilder: (context, i) => const SizedBox(width: 8),
                  itemBuilder: (context, i) {
                    final line = d.lines[i];
                    // 所有线路统一展示，不显示额外角标。
                    return SizedBox(
                      key: ValueKey<String>(line.id),
                      width: 102,
                      height: 60,
                      child: DetailLineCard(
                        name: line.displayName.isEmpty
                            ? '线路${i + 1}'
                            : line.displayName,
                        // 集数用这条线路自己的：合并后的总集数套给所有线路，
                        // 会出现「显示 5 集、点第 4 集播不出来」。
                        count: line.epNames.isNotEmpty
                            ? line.epNames.length
                            : total,
                        // LINE_SUBTITLE_DYNAMIC（2026-11-14）：副标题按**这条线路
                        // 自己**的集数决定，不再用全局 _isMovie 写死。
                        //
                        // 之前 41 集的剧，每条线路卡片都挂「正片」，明明是多集。
                        // 现在：
                        //   · 该线路 ≤ 3 集 → 显示它自己的版本名（正片/粤语/国语）
                        //   · 该线路 > 3 集 → 显示「共 N 集」
                        // 电影显示它自己的版本名（正片/粤语/国语），
                        // 其它分类一律显示「共 N 集」。
                        subtitle: (() {
                          // PLATFORM_PENDING：平台线永远占位。
                          // 还没解析完显示「解析中」，上游不可用显示「暂时不可用」；
                          // 绝不因为没解析完就藏掉这条线。
                          if (line.linePending) return '解析中';
                          if (line.lineUnavailable) return '暂时不可用';
                          final names = line.epNames;
                          final n = names.isNotEmpty ? names.length : total;
                          if (_isMovie) {
                            final first = names.isNotEmpty
                                ? names.first.trim()
                                : '';
                            // 平台线解析回来的集名是「第N集」，电影不能这么显示
                            final shown = first.isEmpty || _epNumOnly.hasMatch(first)
                                ? '正片'
                                : first;
                            return shown;
                          }
                          return n > 0 ? '共 $n 集' : null;
                        })(),
                        active: line.id == _lineId,
                        // degraded 线路照常展示并可点，只在卡片名后补灰色小字。
                        unstable: line.degraded,
                        // 量子 / 红牛是免费站，播放前有广告，名字上标出来。
                        ads: fxLineHasAds(line.displayName),
                        // 切换/重试期间不禁用点击：播放器内部有 _pendingSwitch
                        // 排队机制（记住最后一次选择，当前切换一结束就执行）。
                        // 这里把 onTap 置 null 的话，用户点线路完全没反应，
                        // 就是「重试线路时没法手动切换」的根因。
                        onTap: () => _selectLine(line),
                      ),
                    );
                  },
                )
              : (_lineRefreshTimer != null
                  // 补线进行中：同尺寸骨架占位，线路到了直接替换，不跳版。
                  ? _linePlaceholder()
                  : Center(child: _noLinesHint())),
        ),
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
                  Icon(Icons.chevron_right_rounded,
                      size: 16, color: skin.hint),
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

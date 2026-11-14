import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../main.dart' show Nav;
import '../models.dart';
import '../services/download_service.dart';
import '../services/fx_player.dart';
import '../theme.dart';
import '../widgets/detail_widgets.dart';
import '../widgets/download_sheet.dart';
import '../widgets/player_theme.dart';
import 'category_page.dart'
    show FxEmptyView, FxErrorView, FxPosterCard, fxErrorText, fxInt;
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
  });

  final String id;
  final int ep;
  final String line;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage>
    with SingleTickerProviderStateMixin {
  final GlobalKey<PlayerViewState> _playerKey = GlobalKey<PlayerViewState>();
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

  /// 平台线补线的节奏：服务端匹配窗口 2.5 秒，两次重试足够等到结果。
  static const int _lineRefreshMax = 2;
  static const Duration _lineRefreshDelay = Duration(milliseconds: 2500);

  /// 作品已被服务端删除 / 下架：首屏拿到 404「作品不存在」时，
  /// 给友好提示 + 删除这条历史记录的入口，不再走通用错误页的重试。
  bool _invalid = false;

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

  Future<void> _loadDetail({bool silent = false}) async {
    if (!silent && mounted) setState(() => _error = null);
    try {
      final d = await Api.detail(widget.id);
      if (!mounted) return;

      final lines = d.lines;
      var lineId = _lineId;
      if (lineId.isEmpty || !lines.any((l) => l.id == lineId)) {
        if (lines.any((l) => l.id == widget.line)) {
          lineId = widget.line;
        } else {
          lineId = lines.isEmpty ? '' : lines.first.id;
        }
      }

      final eps = _episodesOf(d, lineId);
      var ep = _ep;
      if (eps.isNotEmpty && !eps.any((e) => e.n == ep)) {
        ep = eps.first.n;
      }

      setState(() {
        _detail = d;
        _lineId = lineId;
        _ep = ep;
        _error = null;
        // 从历史 / 播放器带集数进来时，选集条要切到能看见这一集的分组，
        // 才能高亮并滚动到对应集数。
        _groupIndex = _groupIndexOf(_episodeGroups, ep);
      });
      _scheduleLineRefresh();
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
        // 作品已从服务端删除：只提示一次，并给出删除这条记录的入口。
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
      await FxStore.write(FxStore.historyKey, list);
    } catch (_) {}
    if (!mounted) return;
    fxToast(context, '已删除这条记录');
    await Navigator.of(context).maybePop();
  }

  /// 首屏线路里没有平台线（腾讯 / 芒果 / B 站…）时，2.5 秒后再取一次详情，
  /// 把服务端异步补上的平台线路显示出来；最多补 2 次。服务端确实还没算完
  /// 也会把结果写进缓存，下次进入详情页就能直接带上。
  void _scheduleLineRefresh() {
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
  Future<void> _refreshLines() async {
    if (!mounted) return;
    final current = _detail;
    if (current == null) return;
    if (current.lines.any(fxIsPlatformLine)) return;
    VideoDetail fresh;
    try {
      fresh = await Api.detail(widget.id);
    } catch (_) {
      // 这次没取到（服务端还在算 / 网络抖动）：还有重试额度就继续排。
      if (mounted) _scheduleLineRefresh();
      return;
    }
    if (!mounted) return;
    final latest = _detail;
    if (latest == null) return;
    if (latest.lines.any(fxIsPlatformLine)) return;

    final merged = fxMergeLines(latest.lines, fresh.lines);
    final changed = merged.length != latest.lines.length ||
        merged.asMap().entries.any(
              (entry) => entry.value.id != latest.lines[entry.key].id,
            );
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

  /// `related` 只是 id 数组：按 id 补卡片，最多补 8 个。
  Future<void> _loadRelatedCards(List<String> ids) async {
    if (_relatedLoading || _relatedFetched) return;
    _relatedLoading = true;
    final cards = <VideoCard>[];
    Future<VideoDetail?> fetch(String id) async {
      try {
        return await Api.detail(id);
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
    if (d.groups.isNotEmpty) return d.groups;
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
    // VideoDetail 没有 type 字段，只有 category（服务端已把类型归一成中文）
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
        await FxStore.write(FxStore.favoriteKey, list);
      }
    } catch (_) {}
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
    if (line.id == _lineId && !_playerSwitchingLine) return;
    _stableTimer?.cancel();
    // 用户手动选线路视为重新开始，允许重试这一条。
    _failedLines.remove(line.id);
    _retriedLine = null;
    setState(() {
      _lineId = line.id;
      _autoLineTries = 0;
      // 换线路后集数可能变少（这条线路没有那么多集）：
      // 把当前集夹到该线路真实拥有的范围内，避免点了播不出来。
      final eps = _episodesOf(_detail!, line.id);
      if (eps.isNotEmpty && !eps.any((e) => e.n == _ep)) {
        _ep = eps.first.n;
      }
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
      fxToast(context, _autoSwitchText(issue, target.name));
    } else {
      _selectLine(next);
    }
  }

  String _autoSwitchText(SourceIssue? issue, String name) {
    final label = name.isEmpty ? '下一线路' : '「$name」';
    return switch (issue) {
      SourceIssue.parse => '该线路暂不可直接播放，已为你切换$label',
      SourceIssue.empty => '该线路暂无播放地址，已为你切换$label',
      SourceIssue.expired => '该平台线路已失效，请切换线路',
      _ => '线路播放失败，已自动切换$label',
    };
  }

  /// 全部线路都试过仍不可播：在播放器里显示错误 + 重试/换线路按钮。
  void _showPlaybackError({SourceIssue? issue}) {
    final lines = _detail?.lines ?? const <LineInfo>[];
    final message = lines.isEmpty
        ? '暂无线路，请稍后刷新重试'
        : switch (issue) {
            SourceIssue.parse => '所有线路暂不可直接播放，请重试或换线路',
            SourceIssue.empty => '所有线路都没有可用播放地址，请稍后重试',
            SourceIssue.expired => '该平台线路已失效，请切换线路',
            _ => '所有线路都不可用，请重试或换线路',
          };
    final player = _playerKey.currentState;
    if (player != null) {
      player.showSourceError(message);
    } else {
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
    // 第一次失败：原线重试。reload() 一进来就置 _loading=true、清掉错误层，
    // 重试期间显示缓冲态，不瞬间判死也不闪错误页；重试单独计数，
    // 不占用 _autoLineTries 的换线预算。
    if (lineId.isNotEmpty &&
        !_failedLines.contains(lineId) &&
        _retriedLine != lineId &&
        player != null) {
      _retriedLine = lineId;
      fxToast(context, '线路播放失败，正在原线路重试…');
      unawaited(player.reload());
      return;
    }
    if (lineId.isNotEmpty) _failedLines.add(lineId);
    _switchNextLine(auto: true, issue: issue);
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

  void _selectOnlineEpisode(int n) {
    if (n == _ep) {
      _scrollToPlayer();
      return;
    }
    setState(() {
      _ep = n;
      _groupIndex = _groupIndexOf(_episodeGroups, n);
    });
    _saveHistory();
    _scrollToPlayer();
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
    await _loadDetail(silent: true);
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

  /* ---------------------------------------------------------------- ui */

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FC),
      resizeToAvoidBottomInset: false,
      bottomNavigationBar: d != null && _tab == 1
          ? DetailCommentInput(onTap: _onCommentTap)
          : null,
      body: FxBackground(
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
        const Expanded(
          child: Center(
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: Fx.accent,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPage(VideoDetail d) {
    return RefreshIndicator(
      onRefresh: _refresh,
      color: Fx.accent,
      backgroundColor: Colors.white,
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
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                size: 20, color: Fx.ink),
          ),
          Text(
            title,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: Fx.ink,
            ),
          ),
        ],
      ),
    );
  }

  Widget _playerHeader(VideoDetail d) {
    return ColoredBox(
      color: Colors.black,
      child: AspectRatio(
        aspectRatio: 16 / 9,
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
          onPlaybackStarted: _onPlaybackStarted,
          autoPlay: true,
        ),
      ),
    );
  }

  Widget _topArea() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 用户要求：详情页下面这两行公告不再显示
          // （「欢迎使用幻想影视…」和「温馨提示：本站不存储任何视频资源…」）
          Row(
            children: [
              DetailTabs(
                index: _tab,
                onChanged: _switchTab,
                commentCount: _commentsLoaded
                    ? '${_comments.length}${_commentsHasMore ? '+' : ''}'
                    : null,
              ),
            ],
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
    final totalAll = d.episodes > 0
        ? d.episodes
        : (episodes.isNotEmpty ? fxMainEpisodeCount(episodes) : 0);
    final total =
        episodes.isNotEmpty ? fxMainEpisodeCount(episodes) : d.episodes;
    final related = _relatedList;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _titleBlock(d),
        _actionRow(),
        _sourceHint(),
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
                        // 电影不显示「共 N 集」，标「正片」
                        subtitle: _isMovie ? '正片' : null,
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
                child: const Row(
                  children: [
                    Icon(Icons.autorenew_rounded, size: 14, color: Fx.accent),
                    SizedBox(width: 4),
                    Text('换一换',
                        style: TextStyle(fontSize: 11.5, color: Fx.sub)),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 0),
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
                        style: const TextStyle(
                          fontSize: 20.5,
                          height: 1.2,
                          fontWeight: FontWeight.w800,
                          color: Fx.ink,
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
                    const Text('简介',
                        style: TextStyle(fontSize: 11.5, color: Fx.sub)),
                    Icon(
                      _descOpen
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.chevron_right_rounded,
                      size: 17,
                      color: Fx.sub,
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
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.55,
                  color: Fx.sub,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _scoreTag(num score) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFFB74D), Color(0xFFFF8A3D)],
        ),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, size: 11, color: Colors.white),
          const SizedBox(width: 2),
          Text(
            score.toStringAsFixed(1),
            style: const TextStyle(
              fontSize: 10,
              height: 1.1,
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Fx.accent.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: Fx.accent.withValues(alpha: .20)),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 9.5,
          height: 1.1,
          fontWeight: FontWeight.w600,
          color: Fx.accent,
        ),
      ),
    );
  }

  Widget _actionRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 16, 6, 0),
      child: Row(
        children: [
          Expanded(
            child: DetailActionButton(
              icon: _fav ? Icons.star_rounded : Icons.star_border_rounded,
              label: _fav ? '已收藏' : '收藏',
              color: Fx.gold,
              active: _fav,
              onTap: _toggleFav,
            ),
          ),
          Expanded(
            child: DetailActionButton(
              icon: Icons.download_rounded,
              label: '下载',
              color: const Color(0xFFF5A623),
              onTap: _download,
            ),
          ),
          Expanded(
            child: DetailActionButton(
              icon: Icons.tv_rounded,
              label: '投屏',
              color: const Color(0xFF5B8DEF),
              onTap: _cast,
            ),
          ),
          Expanded(
            child: DetailActionButton(
              icon: Icons.live_tv_rounded,
              label: '一起看',
              color: const Color(0xFF39B7B0),
              onTap: _together,
            ),
          ),
          Expanded(
            child: DetailActionButton(
              icon: Icons.sync_rounded,
              label: '刷新',
              color: const Color(0xFFFF6B6B),
              onTap: _refreshPlayer,
            ),
          ),
        ],
      ),
    );
  }

  void _cast() {
    final player = _playerKey.currentState;
    if (player == null) {
      fxToast(context, '播放器还没准备好');
      return;
    }
    unawaited(player.openCastSheet());
  }

  Widget _sourceHint() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .56),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: Colors.white.withValues(alpha: .9)),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.swap_horiz_rounded, size: 15, color: Fx.accent),
            SizedBox(width: 6),
            Flexible(
              child: Text(
                '无法观看换播放器🔄或更换下方线路👇',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Fx.sub),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 补线中的占位骨架：与线路卡片同尺寸、同起点，平台线补到时直接原地
  /// 替换成真实卡片，页面不会先空一块再撑开。
  Widget _linePlaceholder() {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: 3,
      separatorBuilder: (_, __) => const SizedBox(width: 8),
      itemBuilder: (_, __) => Container(
        width: 102,
        height: 60,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .72),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white),
        ),
      ),
    );
  }

  Widget _noLinesHint() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .72),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white),
        ),
        child: const Row(
          children: [
            Icon(Icons.wifi_off_rounded, size: 16, color: Fx.sub),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '暂无线路，请稍后刷新重试',
                style: TextStyle(fontSize: 11.5, color: Fx.sub),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _episodeGroupTabs(List<EpisodeGroup> groups, int current) {
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
                color: active
                    ? Fx.accent.withValues(alpha: .12)
                    : Colors.white.withValues(alpha: .72),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: active ? Fx.accent : Colors.white,
                ),
              ),
              child: Text(
                name,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? Fx.accent : Fx.sub,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _episodeHeader(int total, {int available = 0}) {
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
              style: const TextStyle(
                fontSize: 16.5,
                fontWeight: FontWeight.w800,
                color: Fx.ink,
              ),
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _openEpisodes,
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: Row(
                children: [
                  Text('查看全部', style: TextStyle(fontSize: 11.5, color: Fx.sub)),
                  Icon(Icons.chevron_right_rounded, size: 16, color: Fx.sub),
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
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .78),
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(color: Colors.white),
                  ),
                  child: const Text(
                    '选集',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: Fx.ink,
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
                        gradient: Fx.brand,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: Colors.white, width: 1.2),
                      ),
                      child: Text(
                        '$total',
                        style: const TextStyle(
                          fontSize: 8.5,
                          height: 1.1,
                          color: Colors.white,
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
          const Text(
            '全部评论',
            style: TextStyle(
              fontSize: 16.5,
              fontWeight: FontWeight.w800,
              color: Fx.ink,
            ),
          ),
          const SizedBox(width: 6),
          if (list.isNotEmpty)
            Text(
              '${list.length}',
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: Fx.accent,
              ),
            ),
          const Spacer(),
          const Icon(Icons.local_fire_department_rounded,
              size: 13, color: Fx.gold),
          const SizedBox(width: 2),
          const Text('按热度', style: TextStyle(fontSize: 10.5, color: Fx.sub)),
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
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 34),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2.3,
              color: Fx.accent,
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
    if (_commentsLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Fx.accent,
            ),
          ),
        ),
      );
    }
    if (_commentsHasMore) {
      return Center(
        child: TextButton(
          onPressed: () => _loadComments(reset: false),
          child: const Text(
            '加载更多评论',
            style: TextStyle(fontSize: 12, color: Fx.accent),
          ),
        ),
      );
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Text(
          '— 已经到底啦 —',
          style: TextStyle(fontSize: 10.5, color: Fx.sub),
        ),
      ),
    );
  }
}

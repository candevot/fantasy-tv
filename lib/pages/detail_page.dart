import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../main.dart' show Nav;
import '../models.dart';
import '../services/download_service.dart';
import '../theme.dart';
import '../widgets/detail_widgets.dart';
import '../widgets/download_sheet.dart';
import '../widgets/player_theme.dart';
import 'category_page.dart'
    show FxEmptyView, FxErrorView, FxPosterCard, fxErrorText;
import 'history_page.dart' show FxStore;
import 'player_page.dart';

/// 详情播放页：顶部内嵌 PlayerView（自动播放当前线路当前集），
/// 下方「视频 / 评论」双 Tab、公告、简介、5 圆钮、线路、选集、猜你喜欢。
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
  bool _noticeClosed = false;
  bool _fav = false;
  bool _openingTogether = false;
  bool _openingRelated = false;
  int _autoLineTries = 0;
  int _relatedOffset = 0;

  /// 本轮自动切线路已经失败过的线路，避免 A/B 反复乒乓。
  final Set<String> _failedLines = <String>{};

  /// 稳定播放 3 秒后才清零重试预算与失败集合。
  Timer? _stableTimer;

  List<CommentItem> _comments = const <CommentItem>[];
  final Set<String> _liked = <String>{};
  bool _commentsLoading = false;
  bool _commentsLoaded = false;
  bool _commentsHasMore = true;
  int _commentPage = 0;
  String? _commentError;

  @override
  void initState() {
    super.initState();
    _ep = widget.ep <= 0 ? 1 : widget.ep;
    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: 1,
    );
    _loadDetail();
  }

  @override
  void dispose() {
    _stableTimer?.cancel();
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

      final eps = _episodesOf(d);
      var ep = _ep;
      if (eps.isNotEmpty && !eps.any((e) => e.n == ep)) {
        ep = eps.first.n;
      }

      setState(() {
        _detail = d;
        _lineId = lineId;
        _ep = ep;
        _error = null;
      });

      await _loadFavState();
      await _saveHistory();
      if (!_commentsLoaded && !_commentsLoading) {
        await _loadComments(reset: true, silent: true);
      }
    } catch (e) {
      if (!mounted) return;
      final msg = fxErrorText(e);
      setState(() => _error = msg);
      if (_detail != null) fxToast(context, msg);
    }
  }

  List<Episode> _episodesOf(VideoDetail d) {
    final all = d.allEpisodes;
    if (all.isNotEmpty) return all;
    return <Episode>[for (var i = 1; i <= d.episodes; i++) Episode(i, '', 0)];
  }

  List<Episode> get _episodes {
    final d = _detail;
    return d == null ? const <Episode>[] : _episodesOf(d);
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
      if (e.n == _ep && e.name.isNotEmpty) return detailEpisodeLabel(e);
    }
    return fxEpisodeLabel(_ep);
  }

  String get _statusText {
    final d = _detail;
    if (d == null) return '';
    final s = d.status.trim();
    if (s.isNotEmpty) {
      if (RegExp(r'^全\s*\d+\s*集$').hasMatch(s)) return '已完结';
      return s;
    }
    final n = _episodes.length;
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
    final src = _detail?.related ?? const <VideoCard>[];
    if (src.isEmpty) return const <VideoCard>[];
    final shift = _relatedOffset % src.length;
    if (shift == 0) return src;
    return <VideoCard>[...src.skip(shift), ...src.take(shift)];
  }

  Future<void> _loadFavState() async {
    var fav = false;
    try {
      final sp = await SharedPreferences.getInstance();
      fav = sp.getBool('fav_${widget.id}') ?? false;
      if (!fav) {
        final list = await FxStore.read(FxStore.favoriteKey);
        fav = list.any((m) => '${m['id']}' == widget.id);
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _fav = fav);
  }

  Future<void> _saveHistory() async {
    final d = _detail;
    if (d == null) return;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt('his_${widget.id}', _ep);
      await FxStore.addHistory(
        id: widget.id,
        title: d.title,
        cover: d.cover,
        ep: _ep,
        epName: _currentEpLabel,
        lineId: _lineId,
        lineName: _lineName,
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
    if (_commentsLoading) return;
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
    if (line.id == _lineId) return;
    _stableTimer?.cancel();
    // 用户手动选线路视为重新开始，允许重试这一条。
    _failedLines.remove(line.id);
    setState(() {
      _lineId = line.id;
      _autoLineTries = 0;
    });
    _saveHistory();
    fxToast(context, '正在切换播放源…');
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
      SourceIssue.parse => '该线路需解析，已为你切换$label',
      SourceIssue.empty => '该线路暂无播放地址，已为你切换$label',
      _ => '线路播放失败，已自动切换$label',
    };
  }

  /// 全部线路都试过仍不可播：在播放器里显示错误 + 重试/换线路按钮。
  void _showPlaybackError({SourceIssue? issue}) {
    final lines = _detail?.lines ?? const <LineInfo>[];
    final message = lines.isEmpty
        ? '暂无线路，请稍后刷新重试'
        : switch (issue) {
            SourceIssue.parse => '所有线路都需解析，暂时无法播放，请重试或换线路',
            SourceIssue.empty => '所有线路都没有可用播放地址，请稍后重试',
            _ => '所有线路都不可用，请重试或换线路',
          };
    final player = _playerKey.currentState;
    if (player != null) {
      player.showSourceError(message);
    } else {
      fxToast(context, message);
    }
  }

  /// PlayerView 报告当前线路不可播：记为失败并按原因切下一条。
  void _reportLineIssue(SourceIssue issue) {
    if (!mounted) return;
    _stableTimer?.cancel();
    if (_lineId.isNotEmpty) _failedLines.add(_lineId);
    _switchNextLine(auto: true, issue: issue);
  }

  /// 播放稳定 3 秒后才清空失败集合与自动重试预算，避免「能 open 但立刻报错」
  /// 的线路在 A/B 之间无限乒乓。
  void _onPlaybackStarted() {
    _stableTimer?.cancel();
    _stableTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _failedLines.clear();
      _autoLineTries = 0;
    });
  }

  void _onEpChange(int n) {
    if (n == _ep) return;
    setState(() => _ep = n);
    _saveHistory();
  }

  void _selectEpisode(int n) {
    if (n == _ep) {
      _scrollToPlayer();
      return;
    }
    setState(() => _ep = n);
    _saveHistory();
    _scrollToPlayer();
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
    );
    if (!mounted || n == null) return;
    _selectEpisode(n);
  }

  Future<void> _refreshPlayer() async {
    _stableTimer?.cancel();
    _failedLines.clear();
    _autoLineTries = 0;
    fxToast(context, '正在刷新播放源…');
    final state = _playerKey.currentState;
    if (state != null) {
      await state.reload();
    } else {
      await _loadDetail(silent: true);
    }
  }

  /// 详情 → 详情：新页面压栈前先暂停并保存当前播放进度，
  /// 返回时只有原本在播放才恢复，避免两层播放器同时出声。
  Future<void> _openRelated(String id) async {
    if (_openingRelated) return;
    _openingRelated = true;
    try {
      final player = _playerKey.currentState;
      final wasPlaying = await player?.pauseAndSave() ?? false;
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
    await _loadDetail(silent: true);
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

  Future<void> _feedback() async {
    final reason = await showDetailFeedbackSheet(context);
    if (!mounted || reason == null) return;
    fxToast(context, '已收到反馈：$reason，感谢支持');
  }

  Future<void> _together() async {
    if (_openingTogether) return;
    _openingTogether = true;
    try {
      // 先暂停并释放详情页内嵌播放器，房间内只保留一起看自己的播放器。
      await _playerKey.currentState?.pauseAndReleaseForTogether();
      if (!mounted) return;
      await Nav.together(context, videoId: widget.id, ep: _ep);
      if (!mounted) return;
      await _playerKey.currentState?.resumeAfterTogether();
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
          SliverToBoxAdapter(
            child: AnimatedBuilder(
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
              child: _tab == 0 ? _videoTab(d) : _commentsTab(),
            ),
          ),
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
          Row(
            children: [
              DetailTabs(
                index: _tab,
                onChanged: _switchTab,
                commentCount: _commentsLoaded
                    ? '${_comments.length}${_commentsHasMore ? '+' : ''}'
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _noticeClosed
                    ? const SizedBox.shrink()
                    : DetailNoticeBar(
                        text: '欢迎使用幻想影视，全网高清影视免费看～',
                        onClose: () => setState(() => _noticeClosed = true),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: DetailNoticeBar(
              text: '温馨提示：本站不存储任何视频资源，请勿轻信视频中的广告与打赏信息。',
              icon: Icons.verified_user_outlined,
              bare: true,
              period: const Duration(seconds: 16),
            ),
          ),
        ],
      ),
    );
  }

  /* ----------------------------------------------------------- video tab */

  Widget _videoTab(VideoDetail d) {
    final episodes = _episodes;
    final total = episodes.isNotEmpty ? episodes.length : d.episodes;
    final related = _relatedList;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _titleBlock(d),
        _actionRow(),
        _sourceHint(),
        if (d.lines.isNotEmpty) ...[
          const SizedBox(height: 16),
          SizedBox(
            height: 60,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: d.lines.length,
              separatorBuilder: (context, i) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final line = d.lines[i];
                final needsParse = line.type.trim().toLowerCase() == 'parse';
                return SizedBox(
                  width: 102,
                  height: 60,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      DetailLineCard(
                        name: line.displayName.isEmpty
                            ? '线路${i + 1}'
                            : line.displayName,
                        count: total,
                        active: line.id == _lineId,
                        onTap: () => _selectLine(line),
                      ),
                      if (needsParse)
                        Positioned(
                          top: 4,
                          right: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 3, vertical: 1),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFF4DF),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: Fx.gold.withOpacity(.48),
                              ),
                            ),
                            child: const Text(
                              '需解析',
                              style: TextStyle(
                                fontSize: 7.5,
                                height: 1.1,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFC77800),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ] else ...[
          const SizedBox(height: 16),
          _noLinesHint(),
        ],
        if (episodes.isNotEmpty) ...[
          const SizedBox(height: 22),
          _episodeHeader(total),
          const SizedBox(height: 10),
          DetailEpisodeStrip(
            episodes: episodes,
            current: _ep,
            onSelect: _selectEpisode,
          ),
        ],
        if (related.isNotEmpty) ...[
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DetailSectionTitle(
              title: '猜你喜欢',
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

  Widget _statusTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Fx.accent.withOpacity(.10),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: Fx.accent.withOpacity(.20)),
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
              icon: Icons.sync_rounded,
              label: '刷新',
              color: const Color(0xFFFF6B6B),
              onTap: _refreshPlayer,
            ),
          ),
          Expanded(
            child: DetailActionButton(
              icon: Icons.edit_rounded,
              label: '反馈',
              color: const Color(0xFFE45D8E),
              onTap: _feedback,
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
        ],
      ),
    );
  }

  Widget _sourceHint() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.56),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: Colors.white.withOpacity(.9)),
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

  Widget _noLinesHint() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.72),
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

  Widget _episodeHeader(int total) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              total > 0 ? '更新至 $total 集' : '选集',
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
                    color: Colors.white.withOpacity(.78),
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
                  color: Colors.black.withOpacity(.42),
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

  Widget _commentsTab() {
    final list = _comments;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
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
              const Text('按热度',
                  style: TextStyle(fontSize: 10.5, color: Fx.sub)),
            ],
          ),
          const SizedBox(height: 12),
          if (list.isEmpty && _commentsLoading)
            const Padding(
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
            )
          else if (list.isEmpty && _commentError != null)
            FxErrorView(
              message: _commentError!,
              compact: true,
              onRetry: () => _loadComments(reset: true),
            )
          else if (list.isEmpty)
            const FxEmptyView(
              icon: Icons.forum_outlined,
              title: '还没有评论',
              subtitle: '登录后来说两句，抢个沙发吧',
            )
          else ...[
            for (final c in list)
              DetailCommentTile(
                key: ValueKey<String>(_commentKey(c)),
                item: c,
                liked: _liked.contains(_commentKey(c)),
                onLike: () {
                  final key = _commentKey(c);
                  setState(() {
                    if (_liked.contains(key)) {
                      _liked.remove(key);
                    } else {
                      _liked.add(key);
                    }
                  });
                },
              ),
            if (_commentsLoading)
              const Padding(
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
              )
            else if (_commentsHasMore)
              Center(
                child: TextButton(
                  onPressed: () => _loadComments(reset: false),
                  child: const Text(
                    '加载更多评论',
                    style: TextStyle(fontSize: 12, color: Fx.accent),
                  ),
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Center(
                  child: Text(
                    '— 已经到底啦 —',
                    style: TextStyle(fontSize: 10.5, color: Fx.sub),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

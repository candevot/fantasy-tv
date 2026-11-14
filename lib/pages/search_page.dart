import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../models.dart';
import '../services/cms_bridge.dart';
import '../theme.dart';
import 'category_page.dart';
import 'detail_page.dart';
import '../utils/fx_route.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key, this.openAi = false});

  final bool openAi;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  static const String _historyKey = 'fx_search_history_v1';

  final TextEditingController _q = TextEditingController();
  final TextEditingController _ai = TextEditingController();
  final FocusNode _focus = FocusNode();
  final FocusNode _aiFocus = FocusNode();
  final ScrollController _scroll = ScrollController();

  List<String> _history = [];
  List<String> _hotWords = const [];

  /// 我们自己那一批的结果（主站采集库 + 幻想 7 条线路），排在上面。
  List<VideoCard> _results = [];

  /// 外部源（肥猫 41 个 jar 源 + 自加）陆续追加的结果，排在下面的
  /// 「外部源结果」分区里。
  List<VideoCard> _external = [];

  /// 渐进检索的订阅：换关键词 / 离开页面时要取消，旧结果不许再回填。
  StreamSubscription<SearchBatch>? _sub;

  /// 我们的源 300ms 还没回来就先铺骨架卡片的定时器。
  Timer? _skeletonTimer;

  /// 进度：「已查 12/48 个源」。
  int _done = 0;
  int _total = 0;

  /// 骨架卡片是否已经铺出来（300ms 阈值）。
  bool _skeleton = false;

  String? _mode;
  String? _lastQuery;
  String? _error;
  bool _loading = false;
  bool _loadingMore = false;
  bool _moreError = false;
  bool _hasMore = true;
  bool _hotLoading = true;
  bool _hotError = false;
  int _page = 1;
  int _req = 0;

  @override
  void initState() {
    super.initState();
    _q.addListener(_onQueryChanged);
    _scroll.addListener(_onScroll);
    _loadHistory();
    _loadHotWords();
    if (widget.openAi) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _aiFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _q.removeListener(_onQueryChanged);
    _scroll.removeListener(_onScroll);
    _sub?.cancel();
    _skeletonTimer?.cancel();
    _q.dispose();
    _ai.dispose();
    _focus.dispose();
    _aiFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_mode != 'search' || _loading || _loadingMore || !_hasMore) return;
    final p = _scroll.position;
    if (p.pixels >= p.maxScrollExtent - 300) _loadMore();
  }

  Future<void> _loadHistory() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final h = sp.getStringList(_historyKey) ?? <String>[];
      if (!mounted) return;
      setState(() => _history = h);
    } catch (_) {}
  }

  Future<void> _loadHotWords() async {
    if (mounted && !_hotLoading) {
      setState(() {
        _hotLoading = true;
        _hotError = false;
      });
    }
    // 热搜词也走 CMS（按点击量排的片名），拿不到再回落旧接口榜单。
    List<String> words = const <String>[];
    try {
      words = await CmsBridge.hotWords();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _hotLoading = false;
        _hotError = true;
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _hotWords = words;
      _hotLoading = false;
      _hotError = words.isEmpty;
    });
  }

  Future<void> _saveHistory(String q) async {
    final next = <String>[q, ..._history.where((e) => e != q)];
    if (next.length > 10) next.removeRange(10, next.length);
    setState(() => _history = next);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(_historyKey, next);
    } catch (_) {}
  }

  Future<void> _clearHistory() async {
    setState(() => _history = []);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_historyKey);
    } catch (_) {}
    if (!mounted) return;
    _toast('已清空搜索历史');
  }

  void _toast(String msg) {
    final m = ScaffoldMessenger.maybeOf(context);
    if (m == null) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xEE1B2430),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ));
  }

  /// 搜索（渐进）：我们自己的源先渲染，外部源后台并行查、陆续追加。
  ///
  /// 实现要点：**不是一个 `await` 等 48 个源**，而是订阅
  /// [CmsBridge.searchStream] —— 每回来一批就 setState 一次，谁的 Future
  /// 先完成谁先出现在列表里：
  ///   · 第一批是本地 CMS（主站采集库），几十毫秒；
  ///   · 接着是幻想那 7 条线路（同一个接口）；
  ///   · 肥猫的 41 个 jar 源在后台并行跑，回来一批追加一批到「外部源结果」。
  /// 单源 8 秒超时，超时算这个源没结果，不阻塞别人。
  Future<void> _search(String raw) async {
    final text = raw.trim();
    if (text.isEmpty) {
      _focus.requestFocus();
      return;
    }
    if (_q.text != text) {
      _q.text = text;
      _q.selection = TextSelection.collapsed(offset: text.length);
    }
    FocusScope.of(context).unfocus();
    _saveHistory(text);

    final req = ++_req;
    await _sub?.cancel();
    _skeletonTimer?.cancel();
    if (!mounted || req != _req) return;
    setState(() {
      _mode = 'search';
      _lastQuery = text;
      _results = [];
      _external = [];
      _error = null;
      _loading = true;
      _page = 1;
      _hasMore = true;
      _loadingMore = false;
      _moreError = false;
      _done = 0;
      _total = 0;
      _skeleton = false;
    });
    _scrollTop();
    // 我们自己的源 300ms 还没回来：先铺骨架卡片，让用户知道在动；
    // 但绝不会为了等外部源而把骨架屏挂在这里。
    _skeletonTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || req != _req) return;
      if (_results.isNotEmpty || _external.isNotEmpty) return;
      setState(() => _skeleton = true);
    });
    _sub = CmsBridge.searchStream(text, 1).listen(
      (batch) => _onBatch(batch, req, first: true),
      onError: (Object e) {
        if (!mounted || req != _req) return;
        _skeletonTimer?.cancel();
        setState(() {
          _loading = false;
          _skeleton = false;
          _error = fxErrorText(e);
        });
      },
    );
  }

  /// 收到一批结果：立刻渲染，不等其它源。
  void _onBatch(SearchBatch batch, int req, {required bool first}) {
    if (!mounted || req != _req) return;
    _skeletonTimer?.cancel();
    // 我们自己的第一批结果刚落地：把列表拉回顶部，新搜索从第一屏开始看。
    final pinTop = first &&
        !batch.external &&
        batch.items.isNotEmpty &&
        _results.isEmpty;
    setState(() {
      if (batch.external) {
        _external.addAll(batch.items);
      } else {
        _results.addAll(batch.items);
        _loading = false;
      }
      if (first) {
        _done = batch.done;
        _total = batch.total;
      }
      _skeleton = false;
      if (batch.finished) {
        _loading = false;
        _loadingMore = false;
        if (first) {
          _hasMore = (_results.length + _external.length) >= 20;
        }
      }
    });
    if (pinTop) _scrollTop();
  }

  Future<void> _loadMore() async {
    if (_mode != 'search' || _loading || _loadingMore || !_hasMore) return;
    final q = _lastQuery;
    if (q == null) return;
    final next = _page + 1;
    final req = _req;
    setState(() {
      _loadingMore = true;
      _moreError = false;
    });
    try {
      // 翻页只续我们自己那一批：外部源的分页质量参差（不少 jar 源把第 1 页
      // 原样再返回一遍），追加进来只会变成重复卡片。
      final list = await CmsBridge.searchOwn(q, next);
      if (!mounted || req != _req || _mode != 'search') return;
      setState(() {
        _results.addAll(list);
        _page = next;
        _loadingMore = false;
        _hasMore = list.length >= 20;
      });
    } catch (_) {
      if (!mounted || req != _req) return;
      setState(() {
        _loadingMore = false;
        _moreError = true;
      });
    }
  }

  // 入口已移除（用户要求删掉 AI 找片），逻辑保留以备恢复。
  // ignore: unused_element
  Future<void> _aiFind() async {
    final prompt = _ai.text.trim();
    if (prompt.isEmpty) {
      _aiFocus.requestFocus();
      _toast('先描述一下你想看的剧情');
      return;
    }
    await _runAi(prompt);
  }

  Future<void> _runAi(String prompt) async {
    FocusScope.of(context).unfocus();
    final req = ++_req;
    await _sub?.cancel();
    _skeletonTimer?.cancel();
    if (!mounted || req != _req) return;
    setState(() {
      _mode = 'ai';
      _lastQuery = prompt;
      _results = [];
      _external = [];
      _error = null;
      _loading = true;
      _hasMore = false;
      _loadingMore = false;
      _moreError = false;
      _done = 0;
      _total = 0;
      _skeleton = false;
    });
    try {
      final list = await Api.aiFind(prompt);
      if (!mounted || req != _req) return;
      setState(() {
        _results = list;
        _loading = false;
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (e) {
      if (!mounted || req != _req) return;
      setState(() {
        _loading = false;
        _error = fxErrorText(e);
      });
    }
  }

  void _reset() {
    // 作废在途请求：清空搜索后旧结果不许再回填（AI 搜索同样走 _req）。
    _req++;
    _sub?.cancel();
    _skeletonTimer?.cancel();
    _q.clear();
    setState(() {
      _mode = null;
      _lastQuery = null;
      _results = [];
      _external = [];
      _error = null;
      _loading = false;
      _loadingMore = false;
      _moreError = false;
      _hasMore = true;
      _done = 0;
      _total = 0;
      _skeleton = false;
    });
    _focus.requestFocus();
  }

  /// 回到列表顶部（等这一帧画完再跳，避免 jumpTo 打在没有位置的对象上）。
  void _scrollTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  void _retry() {
    if (_mode == 'ai' && (_lastQuery ?? '').isNotEmpty) {
      _runAi(_lastQuery!);
    } else if ((_lastQuery ?? '').isNotEmpty) {
      _search(_lastQuery!);
    } else {
      setState(() => _error = null);
    }
  }

  void _openDetail(String id) {
    Navigator.of(context).push(
      FxPageRoute(builder: (_) => DetailPage(id: id)),
    );
  }


  /// 搜索结果点击：统一进详情页。
  /// 平台条目（tx_/iq_）由服务端合成详情，线路卡 / 选集 / 播放 / 一起看 /
  /// 下载与片库条目完全一致，客户端不再需要单独的简化播放页。
  void _openResult(VideoCard item) => _openDetail(item.id);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: FxBackground(
        child: SafeArea(
          child: Column(
            children: [
              _searchBar(),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.maybePop(context),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .72),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white),
              ),
              child: const Icon(Icons.arrow_back_ios_new_rounded,
                  size: 16, color: Fx.ink),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 13),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .78),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: Colors.white),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF50729F).withValues(alpha: .08),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const Icon(Icons.search_rounded, size: 18, color: Fx.sub),
                  const SizedBox(width: 7),
                  Expanded(
                    child: TextField(
                      controller: _q,
                      focusNode: _focus,
                      textInputAction: TextInputAction.search,
                      onSubmitted: _search,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          color: Fx.ink,
                          height: 1.2),
                      cursorColor: Fx.accent,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: '搜索片名、演员、导演',
                        hintStyle: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            color: Fx.sub),
                        contentPadding: EdgeInsets.only(top: 13, bottom: 12),
                      ),
                    ),
                  ),
                  if (_q.text.isNotEmpty)
                    GestureDetector(
                      onTap: _reset,
                      child: const Padding(
                        padding: EdgeInsets.only(left: 4),
                        child: Icon(Icons.cancel_rounded,
                            size: 16, color: Color(0xFFB9C3D2)),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: () => _search(_q.text),
            child: Text(
              '搜索',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: _q.text.isEmpty ? Fx.sub : Fx.accent,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_mode == 'search') {
      // 渐进检索：自己的那批还没回来时，只在 300ms 之后铺骨架；
      // 外部源永远不参与「要不要等」的判断。
      final empty = _results.isEmpty && _external.isEmpty;
      if (empty && _error != null) {
        return FxErrorView(message: _error!, onRetry: _retry);
      }
      if (empty && _skeleton) return _loadingView();
      if (empty && _loading) return _pendingView();
      if (empty) return _emptyResults();
      return _resultsView();
    }
    if (_loading) return _loadingView();
    if (_error != null && _results.isEmpty) {
      return FxErrorView(message: _error!, onRetry: _retry);
    }
    if (_results.isNotEmpty) return _resultsView();
    if (_mode != null) return _emptyResults();
    return _discover();
  }

  /// 发起搜索后 300ms 以内的空档：只放一个转圈，不铺骨架（避免闪一下
  /// 又立刻被真结果顶掉），也不阻塞——自己的源一回来就直接进结果页。
  Widget _pendingView() {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      children: [
        Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: const AlwaysStoppedAnimation<Color>(Fx.accent),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: Text(
            '正在搜索「${_lastQuery ?? ''}」…',
            style: const TextStyle(fontSize: 11.5, color: Color(0xFFA6B1C2)),
          ),
        ),
      ],
    );
  }

  /// 搜索中骨架屏：结果头 + 单列列表占位，避免一片空白。
  Widget _loadingView() {
    return FxSkeletonPulse(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
        children: [
          Row(
            children: [
              FxSkeletonBox(
                  height: 16, width: _mode == 'ai' ? 76 : 82, radius: 4),
              const SizedBox(width: 8),
              FxSkeletonBox(height: 12, width: 120, radius: 4),
            ],
          ),
          const SizedBox(height: 14),
          const FxResultListSkeleton(count: 5),
          const SizedBox(height: 16),
          Center(
            child: Text(
              _mode == 'ai'
                  ? 'AI 正在为你找片…'
                  : (_total > 0
                      ? '正在搜索「${_lastQuery ?? ''}」· 已查 $_done/$_total 个源'
                      : '正在搜索「${_lastQuery ?? ''}」…'),
              style: const TextStyle(fontSize: 11.5, color: Color(0xFFA6B1C2)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _discover() {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return ListView(
      controller: _scroll,
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.fromLTRB(16, 12, 16, 30 + bottom),
      children: [
        _historyCard(),
        const SizedBox(height: 12),
        _hotCard(),
        const SizedBox(height: 12),
        const SizedBox(height: 20),
        const Center(
          child: Text('内容来自幻想影视片库 · 每日更新',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: Color(0xFFA6B1C2))),
        ),
      ],
    );
  }

  Widget _historyCard() {
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.history_rounded,
                  size: 18, color: Fx.accent.withValues(alpha: .85)),
              const SizedBox(width: 7),
              const Text('搜索历史',
                  style: TextStyle(
                      fontSize: 17,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                      color: Fx.ink)),
              const Spacer(),
              if (_history.isNotEmpty)
                GestureDetector(
                  onTap: _clearHistory,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.delete_sweep_rounded,
                            size: 15, color: Fx.sub),
                        SizedBox(width: 3),
                        Text('清空',
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w400,
                                color: Fx.sub)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (_history.isEmpty)
            const Text('暂无搜索记录',
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w400, color: Fx.sub))
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final h in _history) ChipTag(h, onTap: () => _search(h)),
              ],
            ),
        ],
      ),
    );
  }

  Widget _hotCard() {
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.local_fire_department_rounded,
                  size: 19, color: Color(0xFFFF8A3D)),
              const SizedBox(width: 6),
              const Text('热搜词',
                  style: TextStyle(
                      fontSize: 17,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                      color: Fx.ink)),
              const SizedBox(width: 7),
              const Expanded(
                child: Text('大家都在搜',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: Fx.sub)),
              ),
              if (_hotLoading && _hotWords.isEmpty)
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    valueColor: AlwaysStoppedAnimation<Color>(Fx.accent),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (_hotLoading && _hotWords.isEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < 6; i++)
                  const FxSkeletonBox(height: 28, width: 76, radius: 14),
              ],
            )
          else if (_hotWords.isEmpty)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _loadHotWords,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.refresh_rounded,
                        size: 15, color: Fx.accent),
                    const SizedBox(width: 5),
                    Text(_hotError ? '热搜加载失败，点击重试' : '暂无热搜，点击重试',
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            color: Fx.sub)),
                  ],
                ),
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < _hotWords.length; i++)
                  _hotChip(i, _hotWords[i]),
              ],
            ),
        ],
      ),
    );
  }

  Widget _hotChip(int i, String word) {
    final color = i == 0
        ? Fx.gold
        : i == 1
            ? Fx.accent
            : i == 2
                ? Fx.accent2
                : const Color(0xFFB3BECD);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _search(word),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .7),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${i + 1}',
                style: TextStyle(
                    fontSize: 10,
                    height: 1.1,
                    fontWeight: FontWeight.w700,
                    color: color)),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 132),
              child: Text(
                word,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12,
                    height: 1.1,
                    fontWeight: FontWeight.w400,
                    color: Fx.ink),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultsView() {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final ai = _mode == 'ai';
    return Column(
      children: [
        _resultsHeader(),
        Expanded(
          child: CustomScrollView(
            controller: _scroll,
            physics: const BouncingScrollPhysics(),
            slivers: [
              // 我们自己那一批：主站采集库 + 幻想线路，永远排在最上面。
              if (_results.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (ctx, i) {
                        final item = _results[i];
                        return Padding(
                          // 行间 10dp 间距；最后一行交给底部留白，不拖一条空缝。
                          padding: EdgeInsets.only(
                              bottom: i == _results.length - 1 ? 0 : 10),
                          child: FxSearchResultTile(
                            item: item,
                            onTap: () => _openResult(item),
                          ),
                        );
                      },
                      childCount: _results.length,
                    ),
                  ),
                ),
              // 自己的还没全回来：骨架补在下面，表示「还在查」。
              if (_skeleton)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  sliver: const SliverToBoxAdapter(
                    child: FxSkeletonPulse(
                      child: FxResultListSkeleton(count: 3),
                    ),
                  ),
                ),
              // 外部源分区：通栏标题 + 陆续追加的结果（边到边）。
              if (!ai && _external.isNotEmpty) ...[
                SliverToBoxAdapter(child: _externalHeader()),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (ctx, i) {
                        final item = _external[i];
                        return Padding(
                          padding: EdgeInsets.only(
                              bottom: i == _external.length - 1 ? 0 : 10),
                          child: FxSearchResultTile(
                            item: item,
                            onTap: () => _openResult(item),
                          ),
                        );
                      },
                      childCount: _external.length,
                    ),
                  ),
                ),
              ],
              SliverToBoxAdapter(child: _footer(bottom)),
            ],
          ),
        ),
      ],
    );
  }

  /// 结果头：标题 + 总数 + 进度「已查 12/48 个源」。
  Widget _resultsHeader() {
    final ai = _mode == 'ai';
    final count = _results.length + _external.length;
    final progress = !ai && _total > 0 ? '已查 $_done/$_total 个源' : '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Row(
        children: [
          Text(ai ? 'AI 推荐' : '搜索结果',
              style: const TextStyle(
                  fontSize: 17,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  color: Fx.ink)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              ai
                  ? '按「${_lastQuery ?? ''}」匹配到 $count 部'
                  : '「${_lastQuery ?? ''}」· $count 部',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w400, color: Fx.sub),
            ),
          ),
          if (progress.isNotEmpty)
            Text(
              progress,
              style: const TextStyle(fontSize: 11, color: Color(0xFFA6B1C2)),
            ),
          if (_loading || _skeleton)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Fx.accent),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 「外部源结果」分区头：整条通栏（边到边），和上面我们自己那批分开。
  Widget _externalHeader() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6, bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: const BoxDecoration(
        color: Color(0xFFF1F4FA),
        border: Border(
          top: BorderSide(color: Color(0xFFE3E9F2), width: .5),
          bottom: BorderSide(color: Color(0xFFE3E9F2), width: .5),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.hub_rounded, size: 14, color: Fx.accent2),
          const SizedBox(width: 6),
          const Text(
            '外部源结果',
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: Fx.ink),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '肥猫 / 自加 · ${_external.length} 部',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Fx.sub),
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer(double keyboard) {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 22),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Fx.accent),
            ),
          ),
        ),
      );
    }
    if (_moreError) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: GestureDetector(
            onTap: _loadMore,
            child: const Text('加载失败，点击重试',
                style: TextStyle(fontSize: 12, color: Fx.accent)),
          ),
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(top: 24, bottom: 26 + keyboard),
      child: Center(
        child: Text(
          _mode == 'search' && !_hasMore
              ? '— 没有更多结果了 —'
              : _mode == 'ai'
                  ? '以上由 AI 根据片库匹配，仅供参考'
                  : '',
          style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: Color(0xFFA6B1C2)),
        ),
      ),
    );
  }

  Widget _emptyResults() {
    final ai = _mode == 'ai';
    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 32),
      children: [
        FxEmptyView(
          icon: ai ? Icons.auto_awesome_rounded : Icons.search_off_rounded,
          title: ai ? '没有找到合适的片子' : '没有找到相关影片',
          subtitle: ai ? '试试换一种描述，或直接搜索片名' : '换个关键词再试一次，或看看大家最近在搜什么',
          actionText: ai ? '重新描述' : '重新搜索',
          onAction: () {
            if (ai) {
              setState(() {
                _mode = null;
                _lastQuery = null;
                _results = [];
              });
              _aiFocus.requestFocus();
            } else {
              _reset();
            }
          },
        ),
        if (!ai && _hotWords.isNotEmpty) ...[
          const SizedBox(height: 6),
          const Center(
            child: Text('大家都在搜',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: Color(0xFFA6B1C2))),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < _hotWords.length && i < 8; i++)
                _hotChip(i, _hotWords[i]),
            ],
          ),
        ],
      ],
    );
  }
}

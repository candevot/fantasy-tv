import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'category_page.dart';
import 'detail_page.dart';

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
  List<VideoCard> _results = [];
  String? _mode;
  String? _lastQuery;
  String? _error;
  bool _showAi = false;
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
    _showAi = widget.openAi;
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
    List<VideoCard> items = const [];
    try {
      items = await Api.rank('hot');
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _hotLoading = false;
        _hotError = true;
      });
      return;
    }
    if (!mounted) return;
    final seen = <String>{};
    final words = <String>[];
    for (final item in items) {
      final title = item.title.trim();
      if (title.isEmpty || !seen.add(title)) continue;
      words.add(title);
      if (words.length >= 12) break;
    }
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
    setState(() {
      _mode = 'search';
      _lastQuery = text;
      _results = [];
      _error = null;
      _loading = true;
      _showAi = false;
      _page = 1;
      _hasMore = true;
      _loadingMore = false;
      _moreError = false;
    });
    try {
      final list = await Api.search(text, 1);
      if (!mounted || req != _req) return;
      setState(() {
        _results = list;
        _loading = false;
        _page = 1;
        _hasMore = list.length >= 20;
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

  Future<void> _loadMore() async {
    if (_mode != 'search' || _loading || _loadingMore || !_hasMore) return;
    final q = _lastQuery;
    if (q == null) return;
    final next = _page + 1;
    setState(() {
      _loadingMore = true;
      _moreError = false;
    });
    try {
      final list = await Api.search(q, next);
      if (!mounted || _mode != 'search' || _lastQuery != q) return;
      setState(() {
        _results.addAll(list);
        _page = next;
        _loadingMore = false;
        _hasMore = list.length >= 20;
      });
    } catch (e) {
      if (!mounted || _lastQuery != q) return;
      setState(() {
        _loadingMore = false;
        _moreError = true;
      });
    }
  }

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
    setState(() {
      _mode = 'ai';
      _lastQuery = prompt;
      _results = [];
      _error = null;
      _loading = true;
      _showAi = true;
      _hasMore = false;
      _loadingMore = false;
      _moreError = false;
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
    _q.clear();
    setState(() {
      _mode = null;
      _lastQuery = null;
      _results = [];
      _error = null;
      _loading = false;
      _loadingMore = false;
      _moreError = false;
      _hasMore = true;
    });
    _focus.requestFocus();
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
      MaterialPageRoute(builder: (_) => DetailPage(id: id)),
    );
  }

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
                color: Colors.white.withOpacity(.72),
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
                color: Colors.white.withOpacity(.78),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: Colors.white),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF50729F).withOpacity(.08),
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
    if (_loading) return _loadingView();
    if (_error != null && _results.isEmpty) {
      return FxErrorView(message: _error!, onRetry: _retry);
    }
    if (_results.isNotEmpty) return _resultsView();
    if (_mode != null) return _emptyResults();
    return _discover();
  }

  /// 搜索中骨架屏：结果头 + 3 列海报占位，避免一片空白。
  Widget _loadingView() {
    return FxSkeletonPulse(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
        children: [
          Row(
            children: [
              FxSkeletonBox(
                  height: 16,
                  width: _mode == 'ai' ? 76 : 82,
                  radius: 4),
              const SizedBox(width: 8),
              FxSkeletonBox(height: 12, width: 120, radius: 4),
            ],
          ),
          const SizedBox(height: 14),
          const FxPosterGridSkeleton(
            crossAxisCount: 3,
            itemCount: 9,
            padding: EdgeInsets.zero,
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              _mode == 'ai' ? 'AI 正在为你找片…' : '正在搜索「${_lastQuery ?? ''}」…',
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
        _aiCard(),
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
                  size: 18, color: Fx.accent.withOpacity(.85)),
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
          color: Colors.white.withOpacity(.7),
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

  Widget _aiCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Fx.accent.withOpacity(.10), Fx.accent2.withOpacity(.07)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(.95)),
        boxShadow: [
          BoxShadow(
            color: Fx.accent.withOpacity(.08),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  gradient: Fx.brand,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: Fx.accent.withOpacity(.3),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Icon(Icons.auto_awesome_rounded,
                    size: 18, color: Colors.white),
              ),
              const SizedBox(width: 9),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('AI 找片',
                      style: TextStyle(
                          fontSize: 17,
                          height: 1.2,
                          fontWeight: FontWeight.w600,
                          color: Fx.ink)),
                  SizedBox(height: 2),
                  Text('一句话，从片库里找到它',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          color: Fx.sub)),
                ],
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => setState(() => _showAi = !_showAi),
                child: Icon(
                  _showAi
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 20,
                  color: Fx.sub,
                ),
              ),
            ],
          ),
          if (_showAi) ...[
            const SizedBox(height: 12),
            const Text(
              '描述剧情、题材或氛围，例如「想找一部反转不断的悬疑剧」',
              style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  fontWeight: FontWeight.w400,
                  color: Fx.sub),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.78),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white),
              ),
              child: TextField(
                controller: _ai,
                focusNode: _aiFocus,
                minLines: 1,
                maxLines: 2,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _aiFind(),
                style: const TextStyle(fontSize: 13, color: Fx.ink),
                cursorColor: Fx.accent,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: '比如：2024 年高分悬疑，最好有反转',
                  hintStyle: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: Color(0xFFB3BECD)),
                  contentPadding: EdgeInsets.symmetric(vertical: 9),
                ),
              ),
            ),
            const SizedBox(height: 9),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in ['悬疑反转', '周末治愈', '高分古装'])
                  GestureDetector(
                    onTap: () {
                      _ai.text = e;
                      setState(() {});
                      _aiFocus.requestFocus();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(.6),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(e,
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w400,
                              color: Fx.sub)),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 40,
              child: GradButton(
                text: '帮我找片',
                icon: Icons.auto_awesome_rounded,
                height: 40,
                onTap: _aiFind,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _resultsView() {
    final width = MediaQuery.of(context).size.width;
    final itemWidth = (width - 32 - 16) / 3;
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Text(_mode == 'ai' ? 'AI 推荐' : '搜索结果',
                  style: const TextStyle(
                      fontSize: 17,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                      color: Fx.ink)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _mode == 'ai'
                      ? '按「${_lastQuery ?? ''}」匹配到 ${_results.length} 部'
                      : '「${_lastQuery ?? ''}」· ${_results.length} 部',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w400, color: Fx.sub),
                ),
              ),
              if (_loading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Fx.accent),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: CustomScrollView(
            controller: _scroll,
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    mainAxisExtent: itemWidth * 1.5 + 40,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) {
                      final item = _results[i];
                      return FxPosterTile(
                        item: item,
                        onTap: () => _openDetail(item.id),
                      );
                    },
                    childCount: _results.length,
                  ),
                ),
              ),
              SliverToBoxAdapter(child: _footer(bottom)),
            ],
          ),
        ),
      ],
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
                _showAi = true;
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

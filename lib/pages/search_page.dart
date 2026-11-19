import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../models.dart';
import '../services/cms_bridge.dart';
import '../services/search_rank.dart';
import '../services/source_hub.dart';
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

  /// SHA_ARRIVAL / SHELL_ARRIVAL（2026-11-17）：**结果上屏顺序**。
  ///
  /// 用户口径：「搜索不管顺序、不把幻想提前也不垫底，谁先返回谁先上屏」。
  /// 所以渲染只看这一份按到达顺序累加的列表，不再用 `[..._results,
  /// ..._external]` 那种「自己的永远在前」的拼接方式。
  List<VideoCard> _arrived = [];

  /// 源的到达顺序：哪个源先回内容，它那一组就先上屏。
  List<String> _arrivalOrder = [];

  /// 渐进检索的订阅：换关键词 / 离开页面时要取消，旧结果不许再回填。
  StreamSubscription<SearchBatch>? _sub;

  /// 我们的源 300ms 还没回来就先铺骨架卡片的定时器。
  Timer? _skeletonTimer;

  /// 进度：「已查 3/6 个源」。
  int _done = 0;
  int _total = 0;

  /// 软收尾之后还有源在后台补（SOFT_FINISH 2026-11-16）。
  ///
  /// 影视壳的多源搜索没有「整轮结束」—— 谁回来算谁，页面一直增量长。
  /// 我们把「停止转圈」提前到 4 秒（这时已有十几个源），剩下的源在后台继续
  /// 追加；这个标记只影响文案（「后台还在补其余源」），不影响结果。
  bool _backgroundFilling = false;

  /// 骨架卡片是否已经铺出来（300ms 阈值）。
  bool _skeleton = false;

  /// 我们自己的那批（主站采集库 + 幻想线路），段内按「实际分辨率 →
  /// 热度 → 更新时间」排序。
  ///
  /// SEARCH_SEGMENT（2026-11-15）→ SHELL_GROUP（2026-11-16）：
  /// 原来是「我们一段 + 外部一段」的两段长列表；现在按**源**分组
  /// （见 [_sourceGroups]），组间「我们的源优先 → 条数多的在前」，
  /// 组内仍走 [SearchRank.sort]（分辨率 → 冷却 → 热度 → 时间）。

  /// 一轮搜索的兜底看门狗：16 秒还没收到「查完了」，强制收尾。
  ///
  /// 流自己已经有 15 秒硬上限（见 `CmsBridge.searchStream`），这里是页面侧
  /// 的第二道保险：**任何情况下用户都不会对着骨架屏无限等**。
  Timer? _watchdog;

  /// 输入即搜的防抖计时器（停手 400ms 才发请求）。
  Timer? _debounce;

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
    _watchdog?.cancel();
    _debounce?.cancel();
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

  /// 输入即搜（SEARCH_TYPEAHEAD 2026-11-15）。
  ///
  /// 之前只有「回车 / 点搜索 / 点历史词」才会查，边打字边等是没有任何反馈的，
  /// 用户以为搜索坏了。这里补上防抖：
  ///   · 中文输入法组字期间（`composing` 有效）不查，否则拼音字母会变成
  ///     一次毫无意义的全库搜索；
  ///   · 停手 400ms 才发车，连续打字只发最后一次；
  ///   · 清空输入框直接回到热搜页；
  ///   · 触发时不收键盘、不写搜索历史（键盘一收用户就没法接着改字）。
  void _onInput(String raw) {
    _debounce?.cancel();
    final text = raw.trim();
    if (text.isEmpty) {
      if (_mode == 'search') _reset();
      return;
    }
    if (_q.value.composing.isValid) return;
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      if (_q.value.composing.isValid) return;
      final q = _q.text.trim();
      if (q.isEmpty) return;
      if (q == _lastQuery && (_loading || _results.isNotEmpty)) return;
      unawaited(_search(q, keepFocus: true));
    });
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

  /// 搜索（渐进）：只查我们自己的接口（幻想），谁先回来谁先上屏。
  ///
  /// 实现要点：**不是一个 `await` 等全部源**，而是订阅 [CmsBridge.searchStream]
  /// —— 每回来一批就 setState 一次，谁的 Future 先完成谁先出现在列表里：
  ///   · 第一批是本地 CMS（主站采集库），几十毫秒；
  ///   · 接着是幻想那几条线路（同一个接口，0.6~4 秒陆续回来）。
  /// 单源超时算这个源没结果，不阻塞别人。
  Future<void> _search(String raw, {bool keepFocus = false}) async {
    final text = raw.trim();
    if (text.isEmpty) {
      _focus.requestFocus();
      return;
    }
    _debounce?.cancel();
    if (_q.text != text) {
      _q.text = text;
      _q.selection = TextSelection.collapsed(offset: text.length);
    }
    // 输入即搜时不能收键盘、也不能把每个中间状态写进历史：
    // 边打字边搜只服务「现在就出结果」，历史只记用户真正提交过的词。
    if (!keepFocus) {
      FocusScope.of(context).unfocus();
      _saveHistory(text);
    }

    final req = ++_req;
    await _sub?.cancel();
    _skeletonTimer?.cancel();
    if (!mounted || req != _req) return;
    setState(() {
      _mode = 'search';
      _lastQuery = text;
      _results = [];
      _arrived = [];
      _arrivalOrder = [];
      _error = null;
      _loading = true;
      _page = 1;
      _hasMore = true;
      _loadingMore = false;
      _moreError = false;
      _done = 0;
      _total = 0;
      _skeleton = false;
      _backgroundFilling = false;
    });
    _scrollTop();
    // 我们自己的源 300ms 还没回来：先铺骨架卡片，让用户知道在动；
    // 但绝不会为了等外部源而把骨架屏挂在这里。
    _skeletonTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || req != _req) return;
      if (_results.isNotEmpty) return;
      setState(() => _skeleton = true);
    });
    _watchdog?.cancel();
    // JAR_TIMEOUT（2026-11-15）：16 秒 → 21 秒。流自己的硬上限是 20 秒
    // （单源 12 秒 + quick 回退），页面侧只做「比流再多等 1 秒」的第二道保险。
    _watchdog = Timer(const Duration(seconds: 21), () {
      if (!mounted || req != _req) return;
      if (!_loading && !_skeleton) return;
      _skeletonTimer?.cancel();
      setState(() {
        _loading = false;
        _skeleton = false;
        // 有结果就留着结果（只是不再显示「还在查」），一条都没有才给错误。
        if (_results.isEmpty) {
          _error = '搜索超时了，检查一下网络后重试';
        }
      });
    });
    var firstBatch = true;
    // SEARCH_MERGE_SCOPE（2026-11-16）：我们自己的线路之间按片名合并 ——
    // 同一部剧在幻想4K / 幻想蓝光 / 量子各命中一次，列表里只留线路最多的那条。
    _sub = CmsBridge.searchStream(text, 1).listen(
      (batch) {
        _onBatch(batch, req, first: firstBatch);
        firstBatch = false;
        if (batch.finished) _watchdog?.cancel();
      },
      onError: (Object e) {
        if (!mounted || req != _req) return;
        _skeletonTimer?.cancel();
        _watchdog?.cancel();
        setState(() {
          _loading = false;
          _skeleton = false;
          _error = fxErrorText(e);
        });
      },
      // 流被 close（哪怕没收到 finished 批次）也必须把转圈收掉。
      onDone: () {
        if (!mounted || req != _req) return;
        _skeletonTimer?.cancel();
        _watchdog?.cancel();
        if (_skeleton || _loading || _backgroundFilling) {
          setState(() {
            _skeleton = false;
            _loading = false;
            // 后台补全也结束了：进度文案不再显示「后台继续补」。
            _backgroundFilling = false;
          });
        }
      },
    );
  }

  /// 收到一批结果：立刻渲染，不等其它源。
  void _onBatch(SearchBatch batch, int req, {required bool first}) {
    if (!mounted || req != _req) return;
    _skeletonTimer?.cancel();
    // 第一批结果刚落地：把列表拉回顶部，新搜索从第一屏开始看。
    final pinTop = first && batch.items.isNotEmpty && _results.isEmpty;
    setState(() {
      // 追加时按 id 去重：流里除了第 1 页还会补一波第 2 页，上拉再取同一页
      // 时不能把同一部片挂两遍。
      _appendUnique(_results, batch.items);
      // 到达顺序：**谁先回来谁先上屏**（不受源在配置里的位置影响）。
      _noteArrival(batch.items);
      _done = batch.done;
      _total = batch.total;
      // 页码推进到「真实已经拿到的那一页」：SEARCH_WAVES 会顺带把第 2 页
      // 追加进来，页面还按 1 算的话，上拉会再取一次第 2 页。
      if (batch.page > _page) _page = batch.page;
      // SOFT_FINISH（2026-11-16）：`finished` 有「软收尾」的含义 —— 4 秒时
      // 先发一次让转圈停掉。所以这里记一个 `_backgroundFilling`，让文案
      // 说清楚「后台还在补」，而不是让用户以为「就这么多了」。
      if (batch.finished) {
        _loading = false;
        _loadingMore = false;
        _skeleton = false;
        _hasMore = _results.length >= 20;
        // 还有源没回来（batch.done < batch.total）说明是软收尾，不是真结束。
        _backgroundFilling = batch.done < batch.total;
      }
    });
    if (pinTop) _scrollTop();
  }

  /// 按 id 追加去重（同一批次重复、第 2 页与第 1 页重叠都走这里）。
  void _appendUnique(List<VideoCard> target, List<VideoCard> items) {
    if (items.isEmpty) return;
    final seen = <String>{for (final card in target) card.id};
    for (final card in items) {
      if (!seen.add(card.id)) continue;
      // DEDUPE_LINES（2026-11-15）：同一条记录（片名+年份+片源，片源为空是
      // 通配）后到的一版**线路更多**就替换掉先到的那版。
      // 典型场景：主库先回了「济公传」（2 条线路），线路切片后回一条同名的
      // 「济公传」（1 条线路）。以前两条都在列表里，且切片那条点进去必失败；
      // 现在只留线路多的主库那条。
      final at = target.indexWhere((c) => SourceHub.sameRecord(c, card));
      if (at < 0) {
        target.add(card);
      } else if (SourceHub.betterRecord(card, target[at])) {
        target[at] = card;
      }
    }
  }

  /// 记录一批刚到的结果（到达顺序 = 上屏顺序）。
  ///
  /// 只按 id 去重，不做任何跨源合并：咕噜 / 剧圈 / 幻想各自搜到的同名片
  /// 各占一行（MULTI_SOURCE_DROP 的口径），顺序就是它们回来的先后。
  void _noteArrival(List<VideoCard> items) {
    if (items.isEmpty) return;
    final seen = <String>{for (final card in _arrived) card.id};
    for (final card in items) {
      if (!seen.add(card.id)) continue;
      _arrived.add(card);
      final key = card.sourceLabel.trim().toLowerCase();
      if (key.isNotEmpty && !_arrivalOrder.contains(key)) {
        _arrivalOrder.add(key);
      }
    }
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
      final before = _results.length;
      setState(() {
        _appendUnique(_results, list);
        _noteArrival(list);
        _page = next;
        _loadingMore = false;
        // 去重后没长出来也算「没有更多」：否则上拉会一直空转。
        _hasMore = list.length >= 20 && _results.length > before;
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
      _arrived = [];
      _arrivalOrder = [];
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
        // AI 结果同样走「到达顺序」那一条渲染路径（_arrived）。
        _arrived = [];
        _arrivalOrder = [];
        _noteArrival(list);
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
      _arrived = [];
      _arrivalOrder = [];
      _arrived = [];
      _arrivalOrder = [];
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

  void _openDetail(
    String id, {
    String title = '',
    int year = 0,
    String cover = '',
    String sourceLabel = '',
  }) {
    Navigator.of(context).push(
      FxPageRoute(
        builder: (_) => DetailPage(
          id: id,
          title: title,
          year: year,
          // DETAIL_SKELETON（2026-11-15）：把搜索阶段已经知道的封面 / 来源
          // 带进详情页 —— 外部源详情要 9～15 秒，先把海报和片名画出来，
          // 用户不会对着空白页等；失败文案也才说得出「<源名> 暂时没响应」。
          cover: cover,
          sourceLabel: sourceLabel,
          // DEAD_CARD（2026-11-15）：这条记录在详情里被判定失效（404 /
          // 主库查不到）时，把它从搜索结果里摘掉 —— 不能让它继续占位置，
          // 用户下一次还会点到同一条打不开的卡片。
          onInvalid: (deadId) {
            if (!mounted) return;
            setState(() {
              _results.removeWhere((c) => c.id == deadId);
              _arrived.removeWhere((c) => c.id == deadId);
            });
          },
        ),
      ),
    );
  }


  /// 搜索结果点击：统一进详情页。
  /// 平台条目（tx_/iq_）由服务端合成详情，线路卡 / 选集 / 播放 / 一起看 /
  /// 下载与片库条目完全一致，客户端不再需要单独的简化播放页。
  ///
  /// 片名 + 年份一起带进详情页：id 万一已经失效（服务端去重合并过），
  /// 详情页能用它们重查，不会直接报「该视频已失效」（ID_RETRY）。
  void _openResult(VideoCard item) => _openDetail(
        item.id,
        title: item.title,
        year: item.year,
        cover: item.cover,
        sourceLabel: item.sourceLabel,
      );

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
                      onSubmitted: (v) => _search(v),
                      onChanged: _onInput,
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
      // 渐进检索：第一批还没回来时，只在 300ms 之后铺骨架。
      final empty = _results.isEmpty;
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
    // 只有我们自己的源（幻想）：结果就是一份按到达顺序累加的竖排列表，
    // 不分源、不分组、没有左栏 —— 那些都是影视壳多源搜索的东西。
    final items = _arrived;
    return Column(
      children: [
        _resultsHeader(),
        Expanded(
          child: CustomScrollView(
            controller: _scroll,
            physics: const BouncingScrollPhysics(),
            slivers: [
              // 骨架：还没查完时补在最上面（不是塞在结果中间）。
              if (_skeleton)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  sliver: const SliverToBoxAdapter(
                    child: FxSkeletonPulse(
                      child: FxResultListSkeleton(count: 3),
                    ),
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) {
                      final item = items[i];
                      return Padding(
                        padding: EdgeInsets.only(
                          bottom: i == items.length - 1 ? 0 : 10,
                        ),
                        child: FxSearchResultTile(
                          item: item,
                          onTap: () => _openResult(item),
                        ),
                      );
                    },
                    childCount: items.length,
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

  /// 结果头：标题 + 总数 + 进度「已查 3/6 个源」。
  Widget _resultsHeader() {
    final ai = _mode == 'ai';
    final count = _arrived.length;
    // SOFT_FINISH（2026-11-16）：4 秒软收尾后页面不再转圈，但源还在后台补 ——
    // 进度文案要一直显示「已查 X/Y」，让用户知道数字还在涨，而不是以为卡住了。
    final progress = !ai && _total > 0
        ? '已查 $_done/$_total 个源${_backgroundFilling ? ' · 补全中' : ''}'
        : '';
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
          _mode == 'search' && _backgroundFilling
              ? '其余源还在后台补，稍等会继续出现'
              : _mode == 'search' && !_hasMore
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
                _arrived = [];
                _arrivalOrder = [];
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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../models.dart';
import '../services/cms_bridge.dart';
import '../services/jar_plugin.dart';
import '../services/jar_log.dart';
import '../services/search_group.dart';
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

  /// JAR_PROGRESS（2026-11-15）：外部源（肥猫那批 jar 源）这一轮查到什么。
  ///
  /// 上一版只有一个总数，用户看到的是「一条都没有、整段消失」，分不清是
  /// 「肥猫没这部片」「源全超时」还是「装 jar 没生效」。现在每个源回来都会
  /// 报一个结局，这里按结局计数，页面直接写「已查 12/41 源 · 命中 3 ·
  /// 空 6 · 超时 2 · 出错 1」。
  int _externalHits = 0;
  int _externalQueried = 0;

  /// 按源筛选（SOURCE_FILTER 2026-11-16）：影视壳搜索页左侧是一列源名，
  /// 点哪个就看哪个源的结果。用户口径「肥猫的源还是不全，要不然就改成
  /// 影视壳一样的搜索」——把「每个源各自出了几条」直接摆出来，
  /// 不用他猜是哪个源没出。
  /// 空串 = 全部源。
  String _sourceFilter = '';

  final Map<SourceSearchStatus, int> _externalStates =
      <SourceSearchStatus, int>{};

  /// 软收尾之后还有源在后台补（SOFT_FINISH 2026-11-16）。
  ///
  /// 影视壳的多源搜索没有「整轮结束」—— 谁回来算谁，页面一直增量长。
  /// 我们把「停止转圈」提前到 4 秒（这时已有十几个源），剩下的源在后台继续
  /// 追加；这个标记只影响文案（「后台还在补其余源」），不影响结果。
  bool _backgroundFilling = false;

  /// 这一轮的 jar 源是不是有结果（决定「暂无相关结果」要不要出现）。
  bool get _jarEmpty =>
      _external.isEmpty &&
      _externalQueried > 0 &&
      !_loading &&
      // SOFT_FINISH：软收尾后源还在后台补，这时说「没有结果」是假的。
      !_backgroundFilling;

  /// 外部源结局的一行小字：「命中 3 · 空 6 · 超时 2 · 出错 1」。
  String get _externalStateText {
    final parts = <String>[
      if (_externalHits > 0) '命中 $_externalHits',
      for (final status in const <SourceSearchStatus>[
        SourceSearchStatus.empty,
        SourceSearchStatus.timeout,
        SourceSearchStatus.error,
      ])
        if ((_externalStates[status] ?? 0) > 0)
          '${status.label} ${_externalStates[status]}',
    ];
    return parts.join(' · ');
  }

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

  /// jar 插件（肥猫那批 csp_ 源）的状态：装好之后自动把这次搜索重跑一遍，
  /// 否则用户在「需要装 jar」的提示里装完，还得自己再点一次搜索。
  JarPluginPhase _jarPhase = JarPluginPhase.unknown;
  bool _jarRerunPending = false;

  @override
  void initState() {
    super.initState();
    _q.addListener(_onQueryChanged);
    _scroll.addListener(_onScroll);
    _loadHistory();
    _loadHotWords();
    _jarPhase = JarPluginManager.instance.phase;
    JarPluginManager.instance.addListener(_onJarChanged);
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
    JarPluginManager.instance.removeListener(_onJarChanged);
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

  /// jar 插件状态变化：进度 / 失败原因直接反映在提示条上；
  /// 一旦「从没装变成可用」，把上一次搜索自动重跑一遍。
  void _onJarChanged() {
    if (!mounted) return;
    final phase = JarPluginManager.instance.phase;
    final becameReady =
        phase == JarPluginPhase.ready && _jarPhase != JarPluginPhase.ready;
    _jarPhase = phase;
    setState(() {});
    if (!becameReady) return;
    final query = _lastQuery;
    if (_mode != 'search' || query == null || query.isEmpty) return;
    if (_loading) {
      // 这一轮还在查：等它收尾再重跑，避免把正在回填的批次打断。
      _jarRerunPending = true;
      return;
    }
    _rerunAfterJarReady(query);
  }

  void _rerunAfterJarReady(String query) {
    _jarRerunPending = false;
    _toast('jar 插件已就绪，正在把肥猫的源重新查一遍…');
    unawaited(_search(query));
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
      _external = [];
      // 新一轮搜索要清掉上一轮的按源筛选，否则列表会一直只剩某个源。
      _sourceFilter = '';
      _error = null;
      _loading = true;
      _page = 1;
      _hasMore = true;
      _loadingMore = false;
      _moreError = false;
      _done = 0;
      _total = 0;
      _skeleton = false;
      _externalHits = 0;
      _externalQueried = 0;
      _externalStates.clear();
      _backgroundFilling = false;
    });
    _scrollTop();
    // 我们自己的源 300ms 还没回来：先铺骨架卡片，让用户知道在动；
    // 但绝不会为了等外部源而把骨架屏挂在这里。
    _skeletonTimer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || req != _req) return;
      if (_results.isNotEmpty || _external.isNotEmpty) return;
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
        if (_results.isEmpty && _external.isEmpty) {
          _error = '搜索超时了，检查一下网络后重试';
        }
      });
    });
    var firstBatch = true;
    // SEARCH_MERGE_SCOPE（2026-11-16）：**合并只发生在我们自己的线路内**。
    //  · 我们自己的源（幻想）：同一部剧的多条记录按片名合并成一条（保持原逻辑）；
    //  · 肥猫的源：**一律不合并**，每个源各自出各自的结果，和壳一致。
    // 之前的问题是页面层 _appendUnique 用 sameRecord（忽略来源）把外部源也合并了，
    // 导致 41 个源命中 123 条、列表里却只剩「咕噜」。
    // 所以这里**不传 keepDuplicates**（我们的源继续按片名合并），
    // 外部源的分源去重由 searchStream 内的 perSource 参数保证。
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
    // 我们自己的第一批结果刚落地：把列表拉回顶部，新搜索从第一屏开始看。
    final pinTop = first &&
        !batch.external &&
        batch.items.isNotEmpty &&
        _results.isEmpty;
    setState(() {
      // 追加时按 id 去重：流里除了第 1 页还会补一波第 2 页，上拉再取同一页
      // 时不能把同一部片挂两遍。
      _appendUnique(batch.external ? _external : _results, batch.items);
      _done = batch.done;
      _total = batch.total;
      // 外部源：一个源一批，按结局记账（页面上要能看出是「空」还是「超时」）。
      if (batch.external && !batch.finished) {
        _externalQueried++;
        _externalHits += batch.items.length;
        _externalStates.update(
          batch.status,
          (v) => v + 1,
          ifAbsent: () => 1,
        );
        fxJarLog(
          'ui source=${batch.source.isEmpty ? '?' : batch.source} '
          '${batch.status.name} +${batch.items.length} '
          'drop=${batch.dropped} (${_externalQueried}源/命中$_externalHits)',
        );
      }
      // 页码推进到「真实已经拿到的那一页」：SEARCH_WAVES 会顺带把第 2 页
      // 追加进来，页面还按 1 算的话，上拉会再取一次第 2 页。
      if (!batch.external && batch.page > _page) _page = batch.page;
      // 转圈 / 骨架只由「整轮查完」收：我们这批先回来（哪怕是个空批次）时，
      // 肥猫那 86 个 jar 源还在跑，这时把 loading 关掉，页面会立刻显示
      // 「没有找到相关影片」—— 用户看到的空态是假的。
      //
      // SOFT_FINISH（2026-11-16）：`finished` 现在有「软收尾」的含义 —— 4 秒时
      // 先发一次让转圈停掉（用户这时已经能看到十几个源），流还开着，后面的源
      // 继续追加。所以这里要记一个 `_backgroundFilling`，让进度文案说清楚
      // 「后台还在补」，而不是让用户以为「就这么多了」。
      if (batch.finished) {
        _loading = false;
        _loadingMore = false;
        _skeleton = false;
        // 有没有下一页只看**我们自己**这一批：外部源不分页。
        _hasMore = _results.length >= 20;
        // 还有源没回来（batch.done < batch.total）说明是软收尾，不是真结束。
        _backgroundFilling = batch.done < batch.total;
      }
    });
    if (pinTop) _scrollTop();
    if (batch.finished && _jarRerunPending) {
      final query = _lastQuery;
      if (query != null && query.isNotEmpty && _mode == 'search') {
        // 等这一帧画完再起新请求：立刻 _search 会把当前 setState 打断。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _rerunAfterJarReady(query);
        });
      } else {
        _jarRerunPending = false;
      }
    }
  }

  /// 按 id 追加去重（同一批次重复、第 2 页与第 1 页重叠都走这里）。
  /// 这张卡是不是来自外部源（肥猫 jar）。外部源的 id 带 `@src:<源key>`。
  bool _isExternalCard(VideoCard card) {
    final id = card.id.trim();
    if (id.startsWith(SourceHub.idMark)) return true;
    return _external.isNotEmpty && _external.contains(card);
  }

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
      // MULTI_SOURCE_DROP（2026-11-16）：外部源（肥猫）之间**不再合并** ——
      // 咕噜、剧圈、苹果、布布、下饭 各自搜到的同名片要各占一行，和壳一致。
      // 以前这里用 sameRecord（忽略来源）二次合并，刚在批量层按 id 分开的
      // 结果到了列表层又被并成一条，用户只看到「咕噜」。
      final mergeable = !_isExternalCard(card);
      final at = mergeable
          ? target.indexWhere((c) => SourceHub.sameRecord(c, card))
          : -1;
      if (at < 0) {
        target.add(card);
      } else if (SourceHub.betterRecord(card, target[at])) {
        target[at] = card;
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
              _external.removeWhere((c) => c.id == deadId);
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
    // SHELL_LAYOUT（2026-11-16）：影视壳搜索页是「左侧固定源栏 + 右侧网格」。
    // 左栏不随结果滚动；右侧默认「全部」时按源分组（每组一个吸顶头 + 3 列网格）。
    final groups = _sourceGroups();
    final showRail = !ai && _railEntries(groups).length > 2;
    final railWidth = showRail ? _railWidth(context) : 0.0;
    return Column(
      children: [
        _resultsHeader(),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showRail)
                SizedBox(width: railWidth, child: _sourceRail(groups)),
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
                    // jar 插件没装 / 正在装：原因写在结果区上面，别让用户以为
                    // 「外部源就是没有内容」。
                    if (!ai && _sourceNoticeText.isNotEmpty)
                      SliverToBoxAdapter(
                        child: _sourceNotice(
                          _sourceNoticeText,
                          actionLabel:
                              _sourceNoticeAction == null ? null : '重试',
                          onAction: _sourceNoticeAction,
                        ),
                      ),
                    // 每个源一组：吸顶头（源名 + 条数）+ 3 列海报网格。
                    for (var i = 0; i < groups.length; i++)
                      _sourceGroupSliver(
                        groups[i],
                        railWidth: railWidth,
                        last: i == groups.length - 1,
                      ),
                    // 选中了一个 0 条的源（用户要求：点进去提示「该源没有这部片」）。
                    if (!ai && groups.isEmpty && _sourceFilter.isNotEmpty)
                      SliverToBoxAdapter(child: _sourceEmptyNotice()),
                    // 一个源都没出结果：说明查了几个、各自什么结局。
                    if (!ai && groups.isEmpty && _sourceFilter.isEmpty && _jarEmpty)
                      SliverToBoxAdapter(child: _externalEmptyNotice()),
                    SliverToBoxAdapter(child: _footer(bottom)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /* ------------------------------------------------------------ 按源分组 */

  /// 搜索结果按「源」分组（SHELL_GROUP 2026-11-16）。
  ///
  /// 规则全部在 [fxGroupBySource]（`lib/services/search_group.dart`）里，
  /// 由 `test/search_group_test.dart` 逐条钉住：
  ///   · 分组键 = 卡片的 `sourceLabel`（源短名：咕噜 / 下饭 / 幻想…）；
  ///   · 组间：我们自己的源优先 → 条数多的在前 → 名字；
  ///   · 组内：`SearchRank.sort`（分辨率 → 线路冷却 → 热度 → 时间）。
  ///
  /// 空源（0 条 / 超时 / 出错）不进分组 —— 组是「有内容的分区」；
  /// 它们只在左侧源栏出现（[fxRailEntries]），点进去给「该源没有这部片」。
  List<FxSourceGroup> _sourceGroups() => fxGroupBySource(
        <VideoCard>[..._results, ..._external],
        filter: _sourceFilter,
        sortCards: SearchRank.sort,
        ownLabel: KSource.ownResultLabel,
      );

  /// 左侧源栏的条目：「全部」+ 每个源（有结果的带条数，没结果的 0 条）。
  ///
  /// 空源的名字从本轮检索计划里取（`SourceHub.searchPlan` 的 own + external
  /// 就是这一轮真正发出去的源），用 `resultLabel` 得到和卡片 `sourceLabel`
  /// 完全一致的短名，才能和分组对上。
  List<FxRailEntry> _railEntries(List<FxSourceGroup> groups) {
    final plan = SourceHub.instance.searchPlan;
    return fxRailEntries(
      <VideoCard>[..._results, ..._external],
      emptyLabels: <String>[
        for (final s in <KSource>[...plan.own, ...plan.external])
          if (s.resultLabel.trim().isNotEmpty) s.resultLabel.trim(),
      ],
      sortCards: SearchRank.sort,
      ownLabel: KSource.ownResultLabel,
    );
  }

  /// 左侧源栏宽度（对齐壳 `CollectFragment.setWidth`）。
  ///
  /// 壳的算法：`max(120dp, min(最长源名宽度 + 48dp, 屏宽/(列数+1) - 40dp))`。
  /// 我们是 3 列网格，所以上限是 `屏宽/4 - 40dp`，并且再夹一个 96~132dp 的
  /// 区间 —— 手机上 120dp 已经能放下「金牌影视 8」这种最长的了。
  double _railWidth(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final maxWidth = width / 4 - 40;
    return maxWidth.clamp(96.0, 132.0);
  }

  /// 左侧固定源栏：竖排、不随结果滚动（壳的 `collect` RecyclerView）。
  Widget _sourceRail(List<FxSourceGroup> groups) {
    final entries = _railEntries(groups);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 4, 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: .9)),
      ),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
        physics: const BouncingScrollPhysics(),
        itemCount: entries.length,
        itemBuilder: (ctx, i) {
          final e = entries[i];
          final active = e.label == _sourceFilter;
          final label = e.label.isEmpty ? '全部' : e.label;
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _selectSource(e.label),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                decoration: BoxDecoration(
                  color: active ? Fx.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.2,
                        fontWeight:
                            active ? FontWeight.w600 : FontWeight.w500,
                        // 我们自己的源用金色区分（和组标题的「优先」标记同一套
                        // 视觉语言），一眼看出「这组是主站的」。
                        color: active
                            ? Colors.white
                            : (e.own ? const Color(0xFFB47600) : Fx.ink),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${e.count}',
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.2,
                        color: active
                            ? Colors.white.withValues(alpha: .85)
                            : Fx.sub,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 点左栏某个源：只显示它；点「全部」回到分组视图。
  ///
  /// 该源 0 条时不做空切换 —— 直接把结果区换成「该源没有这部片」的说明，
  /// 但**不**改 `_sourceFilter`（用户点回「全部」还能看到其它源）。
  void _selectSource(String label) {
    if (label.isEmpty) {
      if (_sourceFilter.isEmpty) return;
      setState(() => _sourceFilter = '');
      _scrollTop();
      return;
    }
    setState(() => _sourceFilter = label);
    _scrollTop();
  }

  /// 一组结果：吸顶头 + 3 列海报网格（SHELL_GROUP 2026-11-16）。
  ///
  /// 用 `SliverMainAxisGroup` 把「头」和「网格」绑在一起 —— 这样吸顶头只在
  /// **本组**滚动期间钉在顶部，滚到下一组就自然被顶掉（壳的 RecyclerView 里
  /// 每段标题的行为一样）。直接用 `PinnedHeaderSliver` 而不分组的话，所有头
  /// 会一直互相顶替，滚到第 5 个源时第 1 个源的头还挂着。
  Widget _sourceGroupSliver(
    FxSourceGroup group, {
    required double railWidth,
    required bool last,
  }) {
    final width = MediaQuery.sizeOf(context).width;
    // 竖排列表：右侧可用宽度 = 屏宽 − 左栏 − 左右内边距。
    final usable = width - railWidth - 16 * 2;
    return SliverMainAxisGroup(
      slivers: [
        PinnedHeaderSliver(child: _groupHeader(group)),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          // VERTICAL_LIST（2026-11-16）：用户要「两侧竖排」——左边竖排源栏，
          // 右边也是竖排列表（每部片一整行），不是海报网格。
          // 网格里片名只放得下一行，2~3 列必然截断（「济公传[电影…」），
          // 竖排行左侧有 84×112 海报 + 右侧两行片名 + 来源 + 状态，名字看得全。
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (ctx, i) {
                final item = group.cards[i];
                return Padding(
                  padding: EdgeInsets.only(
                    bottom: i == group.cards.length - 1 ? 0 : 10,
                  ),
                  child: FxSearchResultTile(
                    item: item,
                    onTap: () => _openResult(item),
                  ),
                );
              },
              childCount: group.cards.length,
            ),
          ),
        ),
        // 组尾留白：下一组的吸顶头不要贴死上一组最后一行海报。
        SliverToBoxAdapter(child: SizedBox(height: last ? 0 : 12)),
      ],
    );
  }



  /// 一个源的组标题（吸顶）：`源名 · N 部`，我们自己的源多一个「优先」标记。
  Widget _groupHeader(FxSourceGroup group) {
    return Container(
      // 吸顶头必须不透明：下面滚过去的海报不能透出来。
      color: const Color(0xFFF7FAFF),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 12,
            decoration: BoxDecoration(
              color: group.own
                  ? Fx.gold.withValues(alpha: .85)
                  : Fx.accent.withValues(alpha: .55),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 7),
          Text(
            group.label,
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600, color: Fx.ink),
          ),
          const SizedBox(width: 6),
          Text(
            '${group.cards.length}',
            style: const TextStyle(
                fontSize: 11, fontWeight: FontWeight.w400, color: Fx.sub),
          ),
          if (group.own) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Fx.gold.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                '优先',
                style: TextStyle(
                    fontSize: 9.5,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFB47600)),
              ),
            ),
          ],
          const Spacer(),
          if (_backgroundFilling)
            const Text(
              '后台补全中',
              style: TextStyle(fontSize: 10.5, color: Color(0xFFA6B1C2)),
            ),
        ],
      ),
    );
  }

  /// 点了一个「0 条」的源：明确告诉用户「这个源没有这部片」，并给回全部的路。
  ///
  /// SHELL_GROUP（2026-11-16）：壳的左栏里空源也列着，点进去右边是空的 ——
  /// 用户会以为是加载失败。这里把「确实查了、确实没有」说清楚，并且不把
  /// `_sourceFilter` 清掉（用户可以自己点左栏「全部」回去）。
  Widget _sourceEmptyNotice() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
      decoration: BoxDecoration(
        color: Fx.ink.withValues(alpha: .04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Fx.ink.withValues(alpha: .08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.search_off_rounded, size: 16, color: Fx.sub),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '「$_sourceFilter」没有「${_lastQuery ?? ''}」',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: Fx.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _backgroundFilling ? '这个源还在后台查，稍等一下，或者先看别的源' : '这个源确实查过了，站点上没有这部片',
            style: const TextStyle(fontSize: 11, height: 1.45, color: Fx.sub),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => _selectSource(''),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('看全部源',
                style: TextStyle(fontSize: 12, color: Fx.accent)),
          ),
        ],
      ),
    );
  }

  /// 所有源都查完、却一条相关结果都没有时的说明（JAR_PROGRESS 2026-11-15）。
  ///
  /// 为什么不能「整段不显示」：用户搜「济公传」看到整片空白，会以为是插件坏了；
  /// 而实际情况可能是「这些源确实没这部片」或「站点全超时」。
  /// 这里把**查了几个源、各自什么结局**写清楚，并把「重试」直接给出来
  /// （不用用户再点一次搜索按钮）。
  ///
  /// SHELL_GROUP（2026-11-16）：分组视图下它的位置变成「一条结果都没有」时的
  /// 兜底说明；有结果时各组自己带标题，不再需要「肥猫源」这个分区标题。
  Widget _externalEmptyNotice() {
    final detail = _externalStateText.isEmpty
        ? '已查 $_externalQueried 个源'
        : '已查 $_externalQueried 个源（$_externalStateText）';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: Fx.ink.withValues(alpha: .04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Fx.ink.withValues(alpha: .08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.pets_outlined, size: 15, color: Fx.sub),
              const SizedBox(width: 8),
              Text(
                _results.isEmpty ? '外部源暂无相关结果' : '这个源没有这部片',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: Fx.ink),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            detail,
            style: const TextStyle(fontSize: 11, height: 1.45, color: Fx.sub),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton(
                onPressed: () {
                  final q = _lastQuery;
                  if (q != null && q.isNotEmpty) _search(q);
                },
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('重新查一次',
                    style: TextStyle(fontSize: 12, color: Fx.accent)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 结果头：标题 + 总数 + 进度「已查 12/48 个源」。
  Widget _resultsHeader() {
    final ai = _mode == 'ai';
    final count = _results.length + _external.length;
    // SOFT_FINISH（2026-11-16）：4 秒软收尾后页面不再转圈，但源还在后台补 ——
    // 进度文案要一直显示「已查 X/Y」，让用户知道数字还在涨，而不是以为卡住了。
    final progress = !ai && _total > 0
        ? '已查 $_done/$_total 个源'
            '${_externalQueried > 0 ? ' · 命中 $_externalHits' : ''}'
            '${_backgroundFilling ? ' · 补全中' : ''}'
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

  /// 提示条文案：装 jar 的过程中显示进度，失败显示原因，其余沿用片源的说明。
  String get _sourceNoticeText {
    final jar = JarPluginManager.instance;
    final installing = jar.phase == JarPluginPhase.downloading ||
        jar.phase == JarPluginPhase.installing ||
        jar.phase == JarPluginPhase.installingBundled;
    if (installing) {
      final pct = jar.fraction;
      final progress = pct == null ? '' : ' ${(pct * 100).round()}%';
      return '正在准备 jar 插件（$progress）：'
          '${jar.message}。装好后会自动把肥猫的源重新查一遍。';
    }
    if (jar.phase == JarPluginPhase.failed && SourceHub.instance.jarMissing) {
      return '肥猫的 jar 源还不可用：${jar.error}';
    }
    return CmsBridge.sourceNotice;
  }

  /// 提示条右侧的重试按钮（只有「jar 缺失 / 失败」时才出现）。
  VoidCallback? get _sourceNoticeAction {
    if (!SourceHub.instance.jarMissing) return null;
    final phase = JarPluginManager.instance.phase;
    if (phase == JarPluginPhase.downloading ||
        phase == JarPluginPhase.installing ||
        phase == JarPluginPhase.installingBundled) {
      return null;
    }
    return () => unawaited(JarPluginManager.instance.ensureReady(force: true));
  }

  /// 片源侧提示条（jar 插件进度 / 失败原因 / 需要安装）。
  Widget _sourceNotice(
    String text, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Fx.accent.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Fx.accent.withValues(alpha: .22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, size: 15, color: Fx.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 12, height: 1.45, color: Fx.sub),
            ),
          ),
          if (actionLabel != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                actionLabel,
                style: const TextStyle(fontSize: 12, color: Fx.accent),
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
              });
              _aiFocus.requestFocus();
            } else {
              _reset();
            }
          },
        ),
        // 空结果时更要说清楚「外部源为什么没东西」（jar 插件没装 / 正在装）。
        if (!ai && _sourceNoticeText.isNotEmpty) ...[
          const SizedBox(height: 10),
          _sourceNotice(
            _sourceNoticeText,
            actionLabel: _sourceNoticeAction == null ? null : '重试',
            onAction: _sourceNoticeAction,
          ),
        ],
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

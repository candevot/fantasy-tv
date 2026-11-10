import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
// TickerModeData（TickerMode.getValuesNotifier 的返回类型）在 scheduler 里。
import 'package:flutter/scheduler.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'category_page.dart';
import 'detail_page.dart';
import 'live_groups_page.dart';
import 'search_page.dart';
import 'together_page.dart';
import '../utils/fx_route.dart';

class _Channel {
  const _Channel(this.key, this.label);
  final String key;
  final String label;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  static const List<_Channel> _channels = [
    _Channel('recommend', '推荐'),
    _Channel('juji', '剧集'),
    _Channel('movie', '电影'),
    _Channel('zongyi', '综艺'),
    _Channel('manhua', '动漫'),
    _Channel('live', '直播'),
  ];

  final PageController _bannerCtrl = PageController(viewportFraction: .88);
  final Map<String, HomeData> _cache = {};

  Timer? _timer;
  String _channel = 'recommend';

  /// banner 页码只驱动指示点，不再 setState 整页。
  final ValueNotifier<int> _bannerPage = ValueNotifier<int>(0);
  int _req = 0;
  bool _loading = true;
  bool _dragging = false;
  bool _tabVisible = true;
  bool _appResumed = true;
  // getValuesNotifier 的类型是 TickerModeData，取 .enabled 才是 bool。
  ValueListenable<TickerModeData>? _tickerMode;
  String? _error;

  /// 直播频道单独维护：接口可能为空 / 404，失败也按空态处理，不弹错误。
  List<LiveGroup> _liveGroups = const <LiveGroup>[];
  bool _liveLoading = false;
  bool _liveLoaded = false;

  /// 直播首屏搜索：本地过滤全部频道，输入即出结果。
  final TextEditingController _liveSearchCtrl = TextEditingController();
  String _liveQuery = '';

  List<LiveSection> get _liveSections => buildLiveSections(_liveGroups);

  List<LiveChannel> get _liveAllChannels => <LiveChannel>[
    for (final section in _liveSections) ...section.channels,
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Tab 切走 / 被详情页盖住时，TickerMode 会变 false：banner 定时器
    // 随可见性启停，不再在后台空转。
    // Flutter 3.35 起 getValuesNotifier 返回 ValueListenable<TickerModeData>，
    // 里面 .enabled 才是「是否在播放动画」的 bool（.value 是 TickerModeData）。
    final mode = TickerMode.getValuesNotifier(context);
    if (!identical(mode, _tickerMode)) {
      _tickerMode?.removeListener(_onTickerModeChanged);
      _tickerMode = mode..addListener(_onTickerModeChanged);
      _tabVisible = mode.value.enabled;
    }
  }

  void _onTickerModeChanged() {
    final visible = _tickerMode?.value.enabled ?? true;
    if (visible == _tabVisible) return;
    _tabVisible = visible;
    _syncAuto();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed;
    _syncAuto();
  }

  void _syncAuto() {
    if (_tabVisible && _appResumed) {
      _restartAuto();
    } else {
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tickerMode?.removeListener(_onTickerModeChanged);
    _timer?.cancel();
    _bannerCtrl.dispose();
    _bannerPage.dispose();
    _liveSearchCtrl.dispose();
    super.dispose();
  }

  String get _channelLabel {
    for (final c in _channels) {
      if (c.key == _channel) return c.label;
    }
    return '推荐';
  }

  Future<void> _load({bool force = false}) async {
    final channel = _channel;
    final req = ++_req;
    final cached = _cache.containsKey(channel);
    if (!cached) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await Api.home(channel);
      if (!mounted || req != _req || channel != _channel) return;
      setState(() {
        _cache[channel] = data;
        _loading = false;
        _error = null;
        _bannerPage.value = 0;
      });
      _precacheFirstCovers(_arrangeSections(data.sections), channel);
      _restartAuto();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _bannerCtrl.hasClients) {
          _bannerCtrl.jumpToPage(0);
        }
      });
    } catch (e) {
      if (!mounted || req != _req || channel != _channel) return;
      final msg = fxErrorText(e);
      setState(() {
        _loading = false;
        if (!cached) _error = msg;
      });
      if (cached) _toast(msg);
    }
  }

  void _toast(String msg) {
    final m = ScaffoldMessenger.maybeOf(context);
    if (m == null) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xEE1B2430),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 96),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  /// 首页只预热前 6 张海报封面，其余（含横幅）按需懒加载。
  /// 宽度按 FxSectionRow 的 4 列布局计算，保证 precache 与 FxCover
  /// 使用同一个 ImageProvider 缓存键，不会各请求一次。
  void _precacheFirstCovers(List<HomeSection> sections, String channel) {
    final covers = <String>[
      for (final section in sections)
        for (final item in section.items) item.cover,
    ];
    if (covers.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _channel != channel) return;
      final media = MediaQuery.maybeOf(context);
      if (media == null) return;
      final contentWidth = media.size.width - media.padding.horizontal;
      // 与 FxSectionRow 默认值一致：horizontalPadding 16、gap 8、visibleCount 4。
      final posterWidth = (contentWidth - 16 * 2 - 8 * 3) / 4;
      if (!posterWidth.isFinite || posterWidth <= 0) return;
      final cacheWidth = (posterWidth * media.devicePixelRatio).round().clamp(
        64,
        4096,
      );
      final seen = <String>{};
      var count = 0;
      for (final cover in covers) {
        if (count >= 6) break;
        final src = Api.imgProxy(cover);
        if (src.isEmpty || !seen.add(src)) continue;
        final provider = fxImageProvider(cover, cacheWidth: cacheWidth);
        if (provider == null) continue;
        count++;
        unawaited(
          precacheImage(
            provider,
            context,
            onError: (Object error, StackTrace? stackTrace) {},
          ),
        );
      }
    });
  }

  Future<void> _loadLive() async {
    final req = ++_req;
    setState(() => _liveLoading = true);
    try {
      final groups = await Api.liveGroups();
      if (!mounted || req != _req || _channel != 'live') return;
      setState(() {
        _liveGroups = groups;
        _liveLoaded = true;
        _liveLoading = false;
      });
    } catch (_) {
      // 404 / 网络异常 / 脏数据都按「暂无直播」处理，不弹错误也不影响其它频道。
      if (!mounted || req != _req || _channel != 'live') return;
      setState(() {
        _liveGroups = const <LiveGroup>[];
        _liveLoaded = true;
        _liveLoading = false;
      });
    }
  }

  void _restartAuto() {
    _timer?.cancel();
    if (!mounted || !_tabVisible || !_appResumed) return;
    final n = _cache[_channel]?.banners.length ?? 0;
    if (n <= 1) return;
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || !_tabVisible || !_appResumed || _dragging) return;
      if (!_bannerCtrl.hasClients) return;
      final next = (_bannerPage.value + 1) % n;
      _bannerCtrl.animateToPage(
        next,
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _selectChannel(String key) {
    if (_channel == key) return;
    if (key == 'live' && _liveQuery.isNotEmpty) {
      _liveSearchCtrl.clear();
      _liveQuery = '';
    }
    setState(() {
      _channel = key;
      _bannerPage.value = 0;
      _error = null;
      _loading = key != 'live' && !_cache.containsKey(key);
    });
    _timer?.cancel();
    if (key == 'live') {
      _loadLive();
      return;
    }
    if (_cache.containsKey(key)) {
      _restartAuto();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _bannerCtrl.hasClients) {
          _bannerCtrl.jumpToPage(0);
        }
      });
    } else {
      _load();
    }
  }

  void _openSearch({bool ai = false}) {
    Navigator.of(
      context,
    ).push(FxPageRoute(builder: (_) => SearchPage(openAi: ai)));
  }

  void _openDetail(String id) {
    Navigator.of(
      context,
    ).push(FxPageRoute(builder: (_) => DetailPage(id: id)));
  }

  void _openCategory(String type, String title) {
    Navigator.of(context).push(
      FxPageRoute(
        builder: (_) => CategoryPage(
          initialType: type,
          initialTitle: title,
          standalone: true,
        ),
      ),
    );
  }

  void _openSectionMore(HomeSection s) {
    var type = _channel == 'recommend' ? '' : _channel;
    var title = type.isEmpty ? '全部片库' : _channelLabel;
    if (s.title.contains('电影')) {
      type = 'movie';
      title = '电影';
    } else if (s.title.contains('动漫')) {
      type = 'manhua';
      title = '动漫';
    } else if (s.title.contains('综艺')) {
      type = 'zongyi';
      title = '综艺';
    } else if (s.title.contains('直播')) {
      type = 'live';
      title = '直播';
    }
    _openCategory(type, title);
  }

  /// 服务端分区名较长，首页统一成短标题，保持分区节奏一致。
  /// 注意「电影精选 · 高分片单」同时含「电影」「高分」，必须先判分类词，
  /// 否则会被误归到「高分好剧」，导致电影分区丢失。
  String _sectionLabel(String raw) {
    if (raw.contains('今日热播')) return '今日热播';
    if (raw.contains('最新')) return '最新更新';
    if (raw.contains('电影')) return '电影';
    if (raw.contains('综艺')) return '综艺';
    if (raw.contains('动漫')) return '动漫';
    if (raw.contains('高分')) return '高分好剧';
    return raw;
  }

  /// 首页分区固定顺序：今日热播（腾讯榜命中）→ 最新更新 → 高分好剧 →
  /// 电影 → 综艺 → 动漫。推荐频道只保留这 6 个分区，每区最多 10 条。
  static const List<String> _sectionOrder = <String>[
    '今日热播',
    '最新更新',
    '高分好剧',
    '电影',
    '综艺',
    '动漫',
  ];

  int _sectionRank(String label) {
    final i = _sectionOrder.indexOf(label);
    return i < 0 ? _sectionOrder.length : i;
  }

  List<HomeSection> _arrangeSections(List<HomeSection> raw) {
    final list = <HomeSection>[
      for (final s in raw)
        if (s.items.isNotEmpty && !s.title.contains('短剧'))
          HomeSection(_sectionLabel(s.title), s.items.take(10).toList()),
    ];
    if (_channel == 'recommend') {
      // 推荐频道严格按 6 个分区输出，服务端的其它分区不占用首页首屏。
      return <HomeSection>[
        for (final label in _sectionOrder)
          ...list.where((s) => s.title == label),
      ];
    }
    // 分类频道保留服务端分区，但同样按统一顺序排列。
    list.sort((a, b) => _sectionRank(a.title).compareTo(_sectionRank(b.title)));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final data = _cache[_channel];
    // 频道切换时给内容一层淡入：之前是 setState 直接换列表，内容硬切，
    // 观感像「闪一下」。这里用 key 绑定频道，切换时旧内容淡出、新内容淡入，
    // 时长 180ms —— 够遮住跳变，又不会拖慢操作手感。
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      // 默认的 FadeTransition 会让两层同时占位导致高度跳动，
      // 用 layoutBuilder 固定为「只显示新层」，避免滚动位置被顶歪。
      layoutBuilder: (currentChild, previousChildren) => currentChild ?? const SizedBox.shrink(),
      child: KeyedSubtree(
        key: ValueKey<String>(_channel),
        child: SafeArea(
      bottom: false,
      child: RefreshIndicator(
        color: Fx.accent,
        backgroundColor: Colors.white,
        onRefresh: () => _channel == 'live' ? _loadLive() : _load(force: true),
        child: CustomScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: [
            SliverToBoxAdapter(child: _header()),
            ..._body(data),
            const SliverToBoxAdapter(child: SizedBox(height: 104)),
          ],
        ),
      ),
        ),
      ),
    );
  }

  List<Widget> _body(HomeData? data) {
    if (_channel == 'live') return _liveBody();
    if (data == null) {
      if (_loading) {
        return const [SliverToBoxAdapter(child: _HomeSkeleton())];
      }
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: FxErrorView(
            message: _error ?? '内容加载失败，请稍后重试',
            onRetry: () => _load(force: true),
          ),
        ),
      ];
    }

    final sections = _arrangeSections(data.sections);
    if (data.banners.isEmpty && sections.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: FxEmptyView(
            icon: Icons.movie_outlined,
            title: '这个频道暂时没有内容',
            subtitle: '去其他频道看看吧',
            actionText: '刷新试试',
            onAction: () => _load(force: true),
          ),
        ),
      ];
    }

    return [
      if (data.banners.isNotEmpty)
        SliverToBoxAdapter(child: _banner(data.banners)),
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (ctx, i) => _section(sections[i]),
          childCount: sections.length,
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 24, 0, 0),
          child: Column(
            children: [
              Container(
                width: 26,
                height: 3,
                decoration: BoxDecoration(
                  color: const Color(0xFFD9E2F0),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '已经到底啦 · 发现更多好片',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: Color(0xFFA6B1C2),
                ),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  /// 直播首屏：搜索 + 固定顺序的分组卡；输入台名时直接出频道结果。
  List<Widget> _liveBody() {
    if (_liveLoading && !_liveLoaded) {
      return const [SliverToBoxAdapter(child: _HomeSkeleton())];
    }
    final sections = _liveSections;
    if (sections.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: FxEmptyView(
            icon: Icons.live_tv_rounded,
            title: '暂无直播频道 · 敬请期待',
            subtitle: '频道上线后会在这里出现',
            actionText: '刷新试试',
            onAction: _loadLive,
          ),
        ),
      ];
    }

    final query = _liveQuery.trim();
    final matches = query.isEmpty
        ? const <LiveChannel>[]
        : <LiveChannel>[
            for (final channel in _liveAllChannels)
              if (liveChannelMatches(channel, query)) channel,
          ];
    return [
      SliverToBoxAdapter(child: _liveSearchBar()),
      if (query.isEmpty) ...[
        SliverToBoxAdapter(child: _liveSectionHeader(sections)),
        _liveSectionGrid(sections),
      ] else if (matches.isEmpty)
        SliverFillRemaining(
          hasScrollBody: false,
          child: FxEmptyView(
            icon: Icons.search_off_rounded,
            title: '没找到「$query」',
            subtitle: '换个台名试试，如 CCTV5、湖南',
          ),
        )
      else ...[
        SliverToBoxAdapter(child: _liveSearchHeader(matches.length)),
        _liveChannelGrid(matches),
      ],
    ];
  }

  void _clearLiveSearch() {
    if (_liveQuery.isEmpty) return;
    _liveSearchCtrl.clear();
    setState(() => _liveQuery = '');
    FocusScope.of(context).unfocus();
  }

  Widget _liveSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Container(
        height: 44,
        padding: const EdgeInsets.only(left: 13, right: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .72),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF50729F).withValues(alpha: .08),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            const Icon(Icons.search_rounded, size: 19, color: Fx.sub),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _liveSearchCtrl,
                textInputAction: TextInputAction.search,
                textAlignVertical: TextAlignVertical.center,
                cursorColor: Fx.accent,
                style: const TextStyle(fontSize: 13, color: Fx.ink),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: '搜索台名，如 CCTV5 / 湖南',
                  hintStyle: TextStyle(
                    fontSize: 12.5,
                    color: Color(0xFF9AA6B8),
                  ),
                ),
                onChanged: (value) {
                  final query = value.trim();
                  if (query == _liveQuery) return;
                  setState(() => _liveQuery = query);
                },
              ),
            ),
            if (_liveQuery.isNotEmpty)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _clearLiveSearch,
                child: const SizedBox(
                  width: 32,
                  height: 32,
                  child: Icon(Icons.close_rounded, size: 17, color: Fx.sub),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _liveSectionHeader(List<LiveSection> sections) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const Text(
            '频道分组',
            style: TextStyle(
              fontSize: 16.5,
              height: 1.2,
              fontWeight: FontWeight.w800,
              color: Fx.ink,
            ),
          ),
          const SizedBox(width: 7),
          Text(
            '${sections.length} 组',
            style: const TextStyle(fontSize: 10.5, color: Fx.sub),
          ),
          const Spacer(),
          Text(
            '${_liveAllChannels.length} 台',
            style: const TextStyle(fontSize: 10.5, color: Fx.sub),
          ),
        ],
      ),
    );
  }

  Widget _liveSearchHeader(int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const Text(
            '搜索结果',
            style: TextStyle(
              fontSize: 16.5,
              height: 1.2,
              fontWeight: FontWeight.w800,
              color: Fx.ink,
            ),
          ),
          const SizedBox(width: 7),
          Text(
            '$count 台',
            style: const TextStyle(fontSize: 10.5, color: Fx.sub),
          ),
          const Spacer(),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _clearLiveSearch,
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: Text(
                '清空',
                style: TextStyle(fontSize: 11.5, color: Fx.sub),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _liveSectionGrid(List<LiveSection> sections) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.crossAxisExtent >= 560 ? 3 : 2;
          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: columns == 3 ? 1.45 : 1.25,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) => LiveGroupCard(
                section: sections[i],
                onTap: () => openLiveSection(context, sections[i]),
              ),
              childCount: sections.length,
            ),
          );
        },
      ),
    );
  }

  Widget _liveChannelGrid(List<LiveChannel> channels) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.crossAxisExtent >= 700 ? 3 : 2;
          final itemWidth =
              (constraints.crossAxisExtent - 12 * (columns - 1)) / columns;
          final extent = (itemWidth - 12) * 9 / 16 + 58;
          return SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              mainAxisExtent: extent,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) => LiveChannelCard(
                channel: channels[i],
                onTap: () => openLiveChannel(context, channels[i]),
              ),
              childCount: channels.length,
            ),
          );
        },
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(11),
                  boxShadow: [
                    BoxShadow(
                      color: Fx.accent.withValues(alpha: .18),
                      blurRadius: 14,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(11),
                  child: Image.asset(
                    'assets/logo.png',
                    fit: BoxFit.cover,
                    cacheWidth: (36 * MediaQuery.devicePixelRatioOf(context))
                        .round()
                        .clamp(36, 216),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '幻想影视',
                      style: TextStyle(
                        fontSize: 20,
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                        color: Fx.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '高画 · 免费 · 无广',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: Fx.sub,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(
                  context,
                ).push(FxPageRoute(builder: (_) => const TogetherPage())),
                child: Tooltip(
                  message: '一起看',
                  child: Semantics(
                    button: true,
                    label: '一起看',
                    child: Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 11),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .72),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: Colors.white),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(
                              0xFF50729F,
                            ).withValues(alpha: .08),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.groups_rounded,
                            size: 16,
                            color: Fx.accent,
                          ),
                          SizedBox(width: 5),
                          Text(
                            '一起看',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Fx.ink,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _searchBar(),
          const SizedBox(height: 12),
          _channelTabs(),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .72),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withValues(alpha: .95)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF50729F).withValues(alpha: .08),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          const Icon(Icons.search_rounded, size: 18, color: Fx.sub),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _openSearch(),
              child: const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '搜索片名、演员、导演',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: Fx.sub,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _channelTabs() {
    return Container(
      height: 42,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .58),
        borderRadius: BorderRadius.circular(21),
        border: Border.all(color: Colors.white.withValues(alpha: .92)),
      ),
      child: Row(
        children: [
          for (final c in _channels)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _selectChannel(c.key),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    gradient: c.key == _channel ? Fx.brand : null,
                    borderRadius: BorderRadius.circular(17),
                    boxShadow: c.key == _channel
                        ? [
                            BoxShadow(
                              color: Fx.accent.withValues(alpha: .22),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ]
                        : null,
                  ),
                  child: Center(
                    child: Text(
                      c.label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: c.key == _channel
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: c.key == _channel ? Colors.white : Fx.sub,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _banner(List<BannerItem> banners) {
    return Column(
      children: [
        SizedBox(
          height: 178,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is ScrollStartNotification && n.dragDetails != null) {
                  _dragging = true;
                  _timer?.cancel();
                } else if (n is ScrollEndNotification && _dragging) {
                  _dragging = false;
                  _restartAuto();
                }
                return false;
              },
              child: PageView.builder(
                controller: _bannerCtrl,
                itemCount: banners.length,
                onPageChanged: (i) => _bannerPage.value = i,
                itemBuilder: (ctx, i) {
                  final b = banners[i];
                  return RepaintBoundary(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: GestureDetector(
                        onTap: () => _openDetail(b.id),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              FxCover(
                                url: b.cover,
                                title: b.title,
                                radius: 18,
                                big: true,
                                showText: false,
                              ),
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.black.withValues(alpha: .02),
                                      Colors.black.withValues(alpha: .12),
                                      Colors.black.withValues(alpha: .74),
                                    ],
                                    stops: const [0, .42, 1],
                                  ),
                                ),
                              ),
                              if (b.rating > 0)
                                Positioned(
                                  top: 10,
                                  right: 10,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.black.withValues(
                                        alpha: .32,
                                      ),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: Colors.white.withValues(
                                          alpha: .24,
                                        ),
                                      ),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          Icons.star_rounded,
                                          size: 12,
                                          color: Fx.gold,
                                        ),
                                        const SizedBox(width: 2),
                                        Text(
                                          b.rating.toStringAsFixed(1),
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              Positioned(
                                left: 16,
                                right: 16,
                                bottom: 13,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        gradient: Fx.brand,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: const Text(
                                        '正在热播',
                                        style: TextStyle(
                                          fontSize: 9,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      b.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 20,
                                        height: 1.2,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                      ),
                                    ),
                                    if (b.desc.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        b.desc,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          height: 1.45,
                                          fontWeight: FontWeight.w400,
                                          color: Colors.white.withValues(
                                            alpha: .84,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        ValueListenableBuilder<int>(
          valueListenable: _bannerPage,
          builder: (context, index, _) => Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(banners.length, (i) {
              final on = i == index % banners.length;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 240),
                width: on ? 18 : 6,
                height: 6,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  gradient: on ? Fx.brand : null,
                  color: on ? null : const Color(0xFFCBD6E6),
                  borderRadius: BorderRadius.circular(3),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }

  Widget _section(HomeSection s) {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: FxSectionRow(
        title: s.title,
        items: s.items,
        onMore: () => _openSectionMore(s),
        onTapItem: (item) => _openDetail(item.id),
      ),
    );
  }
}

class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) {
    return FxSkeletonPulse(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const FxSkeletonBox(height: 176, radius: 18),
            const SizedBox(height: 22),
            for (var i = 0; i < 3; i++) ...[
              const FxSkeletonBox(height: 17, width: 132, radius: 6),
              const SizedBox(height: 12),
              const FxPosterRowSkeleton(horizontalPadding: 0),
              const SizedBox(height: 22),
            ],
          ],
        ),
      ),
    );
  }
}

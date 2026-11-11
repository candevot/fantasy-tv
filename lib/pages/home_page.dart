import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'category_page.dart';
import 'detail_page.dart';
import 'live_all_page.dart';
import 'live_detail_page.dart';
import 'live_groups_page.dart';
import '../widgets/fx_live_section.dart';
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
  String _channel = 'recommend';  // 分类入口已移除，只保留推荐频道

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

  /// 直播首屏搜索：本地过滤全部频道，输入即出结果。

  List<LiveSection> get _liveSections => buildLiveSections(_liveGroups);


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    // 首页末尾有「直播」分区，需要直播数据。
    // 之前只在 _channel == 'live' 时才拉，而分类页签删掉后 _channel 恒为
    // 'recommend'，_loadLive 永远不会被调用 → 直播区一直是空的。
    unawaited(_loadLive());
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
    try {
      final groups = await Api.liveGroups();
      if (!mounted || req != _req) return;
      setState(() {
        _liveGroups = groups;
      });
    } catch (_) {
      // 404 / 网络异常 / 脏数据都按「暂无直播」处理，不弹错误也不影响其它频道。
      if (!mounted || req != _req) return;
      setState(() {
        _liveGroups = const <LiveGroup>[];
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
    // 「最新」要排在分类词之后判：服务端可能返回「最新电视剧」，
    // 先判「最新」会把它归到「最新更新」，剧集分区就少一块。
    if (raw.contains('电视剧') || raw.contains('剧集') || raw.contains('连续剧')) {
      // 「最新剧集」这类同时含两个词的，仍按剧集归类（内容以分类为主）。
      if (!raw.contains('最新')) return '剧集';
    }
    if (raw.contains('最新')) return '最新更新';
    // 电视剧 / 剧集 / 连续剧 都归到「剧集」。之前没有这条分支，
    // 服务端返回的「电视剧热播榜」会原样落到白名单外被丢弃 —— 首页空白。
    if (raw.contains('电视剧') || raw.contains('剧集') || raw.contains('连续剧')) {
      return '剧集';
    }
    if (raw.contains('电影')) return '电影';
    if (raw.contains('综艺')) return '综艺';
    if (raw.contains('动漫')) return '动漫';
    if (raw.contains('高分')) return '高分好剧';
    return raw;
  }

  /// 首页分区固定顺序：今日热播（腾讯榜命中）→ 最新更新 → 高分好剧 →
  /// 电影 → 综艺 → 动漫。推荐频道只保留这 6 个分区，每区最多 10 条。
  /// 首页分区顺序：热门优先。
  ///
  /// 用户要求「去掉分类入口，各区域优先显示热门」，所以：
  ///   · 今日热播 / 最新更新 放最前（更新最快、点击率最高）
  ///   · 电影 / 剧集 / 综艺 / 动漫 按内容量排
  ///   · 直播作为独立分区放在最后（它不用卡片网格，单独渲染）
  static const List<String> _sectionOrder = <String>[
    '今日热播',
    '最新更新',
    '电影',
    '剧集',
    '综艺',
    '动漫',
    '高分好剧',
    '直播',
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
    // 排序：已知分区按 _sectionOrder 排前面，未知分区按原顺序跟后面。
    //
    // 之前这里是「严格白名单」：只输出 _sectionOrder 里列出的标签，
    // 服务端一旦改分区名（电视剧热播榜 / 电影精选 / 综艺现场 / 动漫番剧），
    // 全部匹配不上 → sections 变空 → 首页只剩 banner，看起来就是白屏。
    // 现在改成「已知的排前面、未知的也保留」，服务端加分区不会再丢内容。
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
        onRefresh: () async {
          // 分类页签已删，首页固定推荐频道；下拉同时刷新影视与直播。
          await Future.wait(<Future<void>>[_load(force: true), _loadLive()]);
        },
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
      // 直播作为首页的一个区（用户要求：去掉分类页签，直播进分区）。
      // 数据来自 /api/live，与直播页共用同一份 _liveGroups。
      if (_liveSections.isNotEmpty)
        SliverToBoxAdapter(
          child: FxLiveSectionRow(
            sections: _liveSections,
            onMore: _openLiveAll,
            onTapChannel: _openLiveChannel,
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

  /// 「全部」：跳直播总览页。
  void _openLiveAll() {
    Navigator.of(context).push(
      FxPageRoute(builder: (_) => const LiveAllPage()),
    );
  }

  /// 点某个直播频道：进直播播放页。
  void _openLiveChannel(LiveChannel channel) {
    Navigator.of(context).push(
      FxPageRoute(builder: (_) => LiveDetailPage(channel: channel)),
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

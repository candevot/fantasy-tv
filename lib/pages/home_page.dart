import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../services/cms_bridge.dart';
import '../services/exo_player.dart';
import '../theme.dart';
import 'category_page.dart';
import 'favorite_page.dart';
import 'history_page.dart';
import 'detail_page.dart';
import 'search_page.dart';
import 'together_page.dart';
import '../utils/fx_route.dart';
import '../services/source_hub.dart';
import '../widgets/fx_source_sheet.dart';
import '../widgets/player_theme.dart' show PGlassIcon, PGlassPill;
import '../widgets/fx_resume_bar.dart' show FxResumeBarHost;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  /// 顶部频道栏 = CMS 的一级栏目（推荐 + 电影 / 电视剧 / 动漫 / 综艺 /
  /// 短剧 / 少儿，共七项）。直播是底部导航的独立入口，这一轮不接。
  static const List<CmsChannel> _channels = CmsBridge.channels;

  final PageController _bannerCtrl = PageController(viewportFraction: .88);
  final Map<String, HomeData> _cache = {};

  /// 源选择面板 / 片源管理改了东西时，标题栏要立刻跟着变。
  final SourceHub _hub = SourceHub.instance;

  /// 换源次数：分类 tab 的 key 带上它，换源时旧列表整体重建，
  /// 不会残留上一个源的卡片。
  int _sourceRev = 0;

  Timer? _timer;
  String _channel = 'recommend';

  /// banner 页码只驱动指示点，不再 setState 整页。
  final ValueNotifier<int> _bannerPage = ValueNotifier<int>(0);
  int _req = 0;

  /// 直播请求独立的序号。
  ///
  /// 原来 _load 和 _loadLive 共用 _req：initState 里先 _load()（req=1），
  /// 紧接着 _loadLive()（req=2），等 _load 的响应回来时 req(1) != _req(2)，
  /// 首页数据被当成「过期请求」丢掉 —— 表现就是进入 App 首页空白，
  /// 必须下拉刷新才出来。
  bool _loading = true;
  bool _dragging = false;
  bool _tabVisible = true;
  bool _appResumed = true;
  // getValuesNotifier 的类型是 TickerModeData，取 .enabled 才是 bool。
  ValueListenable<TickerModeData>? _tickerMode;
  String? _error;

  /// 直播频道单独维护：接口可能为空 / 404，失败也按空态处理，不弹错误。

  /// 直播首屏搜索：本地过滤全部频道，输入即出结果。



  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _hub.addListener(_onHubChanged);
    _load();
    // BG_SERVICE（2026-11-15）：上次后台播放被系统压过内存 → 启动后提示一次。
    unawaited(_maybeShowBackgroundHint());
    // 直播是独立 Tab（LiveAllPage），首页不再展示直播分区。
    // 之前 initState 顺手拉一次直播数据，现在没必要 —— 白占一次请求和内存。
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

  void _onHubChanged() {
    if (mounted) setState(() {});
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
    _hub.removeListener(_onHubChanged);
    _tickerMode?.removeListener(_onTickerModeChanged);
    _timer?.cancel();
    _bannerCtrl.dispose();
    _bannerPage.dispose();
    super.dispose();
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
      final data = await CmsBridge.home(channel);
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

  /// 后台播放保活的**一次性**提示。
  ///
  /// 触发链路：原生 `PlaybackService.onTrimMemory` 发现「播放中被系统压内存」
  /// （这就是被回收的前兆），在偏好里记一个标记 → 下次启动问一次 → 读后即清。
  /// 不主动弹系统对话框，只在提示条上给一个「去设置」的入口。
  Future<void> _maybeShowBackgroundHint() async {
    final hit = await ExoPlayerEngine.consumeBackgroundHint();
    if (!hit || !mounted) return;
    final m = ScaffoldMessenger.maybeOf(context);
    if (m == null) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(
      SnackBar(
        content: const Text('后台播放曾被系统中断过：把「幻想影视」加入电池优化白名单可以避免'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xEE1B2430),
        duration: const Duration(seconds: 8),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 96),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        action: SnackBarAction(
          label: '去设置',
          onPressed: () {
            unawaited(ExoPlayerEngine.requestIgnoreBatteryOptimizations());
          },
        ),
      ),
    );
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
    setState(() {
      _channel = key;
      _bannerPage.value = 0;
      _error = null;
      // 分类 tab 的数据由它自己的分类网格去拉（不再请求「频道首页」——
      // 那正是「点电视剧出来一个 banner + 4 条剧集分区」的原因）。
      _loading = _isChannelFeed ? false : !_cache.containsKey(key);
    });
    _timer?.cancel();
    if (_isChannelFeed) return;
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

  /// 当前 tab 是不是「某个一级栏目」（电影 / 电视剧 / 动漫 / 综艺 …）。
  ///
  /// TAB_GRID（2026-11-15）：这些 tab 应该是**该分类的完整片库**（网格 +
  /// 无限滚动），不是又一个 banner + 分区首页。推荐（typeId=0）仍然是首页。
  bool get _isChannelFeed {
    final ch = CmsBridge.channelOf(_channel);
    return ch != null && ch.typeId > 0;
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

  /// 分区「更多」→ 对应的分类 tab（不再压一个新的分类页进导航栈）。
  ///
  /// TAB_GRID（2026-11-15）：用户点「电影 · 更多」就是要看这个分类的全部
  /// 片子，切 tab 比开二级页更直接，返回键也能继续用。
  /// 「今日热播 / 最新更新 / 高分好剧」不是一级栏目，落回完整分类页兜底。
  void _openSectionMore(HomeSection s) {
    final target = CmsBridge.channelOfLabel(s.title);
    if (target != null && target.typeId > 0) {
      _selectChannel(target.key);
      return;
    }
    _openCategory('', '全部片库');
  }

  /// 服务端分区名较长，首页统一成短标题，保持分区节奏一致。
  /// 注意「电影精选 · 高分片单」同时含「电影」「高分」，必须先判分类词，
  /// 否则会被误归到「高分好剧」，导致电影分区丢失。
  String _sectionLabel(String raw) {
    if (raw.contains('今日热播')) return '今日热播';
    if (raw.contains('最新')) return '最新更新';
    // 电视剧 / 剧集 / 连续剧 都归到「剧集」。没有这条分支时，
    // 服务端的「电视剧热播榜」会原样落到白名单外被丢弃。
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
  /// 今日热播 / 最新更新放最前，然后电影 / 剧集 / 综艺 / 动漫。
  /// 首页分区顺序：CMS 的六个一级栏目在前（电影 → 电视剧 → 动漫 →
  /// 综艺 → 短剧 → 少儿），旧接口的热播 / 高分分区排在后面兜底。
  static const List<String> _sectionOrder = <String>[
    '电影',
    '剧集',
    '动漫',
    '综艺',
    '短剧',
    '少儿',
    '今日热播',
    '最新更新',
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
        if (s.items.isNotEmpty)
          HomeSection(_sectionLabel(s.title), s.items.take(10).toList()),
    ];
    // 排序：已知分区按 _sectionOrder 排前面，未知分区按原顺序跟后面。
    //
    // 原来这里是严格白名单（只输出 _sectionOrder 里的标签），服务端返回的
    // 「电视剧热播榜 / 电影精选 / 综艺现场 / 动漫番剧」一个都匹配不上，
    // sections 变空 → 首页只剩 banner，看起来就是白屏。
    list.sort((a, b) => _sectionRank(a.title).compareTo(_sectionRank(b.title)));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    // 频道切换时给内容一层淡入：之前是 setState 直接换列表，内容硬切，
    // 观感像「闪一下」。这里用 key 绑定频道，切换时旧内容淡出、新内容淡入，
    // 时长 180ms —— 够遮住跳变，又不会拖慢操作手感。
    // HOME_NO_SWITCHER（2026-11-12）：去掉 AnimatedSwitcher。
    //
    // 它把整个页面（SafeArea + CustomScrollView）包在 KeyedSubtree 里，
    // layoutBuilder 只返回 currentChild —— 首帧 currentChild 为 null，
    // 整页被吞成 SizedBox.shrink()，用户看到的就是「首页白屏」。
    // 现在只剩「推荐」一个频道，淡入动画没有存在意义。
    return SafeArea(
      bottom: false,
      // HOME_STACK（2026-11-14）：首页内容之外再叠一层「继续观看」悬浮条。
      //
      // 为什么必须是 Stack：悬浮条要固定在底部标签栏正上方，不能跟着
      // CustomScrollView 一起滚。它挂在 Stack 的最后一层（内容之上），
      // 自己算底距（theme.dart 的 fxBottomBarInset + 8），
      // 于是既不会和首页滚动打架，也不会被标签栏盖住。
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_isChannelFeed) _channelFeed() else _recommendFeed(),
          // 没有历史记录 / 用户已关掉时它自己返回 SizedBox.shrink()，
          // 不占位、不拦手势；数据与预取都在它内部完成。
          const FxResumeBarHost(),
        ],
      ),
    );
  }

  /// 分类 tab：顶部频道栏固定，下面是该分类的完整网格（无限滚动）。
  ///
  /// TAB_GRID（2026-11-15）：之前这里走的是 `CmsBridge.home(key)` —— 服务端
  /// 给「单个栏目」的首页就是一张 banner + 一个分区（最多 10 条），于是用户
  /// 点「电视剧」看到的是「走马上任」大图 + 一行 4 条剧集 + 「已经到底啦」，
  /// 而库里其实有 144 部。现在整块交给 [CategoryPage]：
  ///   · 不带 banner / 不带分区标题，进来就是影片网格；
  ///   · 每页 20 条，`src=hx` + `order=vod_hits&by=desc`（按热度）；
  ///   · 按服务端 pagecount 翻完才显示「已经到底啦」；
  ///   · 换 tab 时 key 变化 → 旧 State 销毁，不会残留上一个分类的列表。
  Widget _channelFeed() {
    final ch = CmsBridge.channelOf(_channel)!;
    return Column(
      children: [
        _header(),
        Expanded(
          child: CategoryPage(
            // 换源时 key 一起变：旧的分类列表整体销毁重建，
            // 不会残留上一个源的卡片。
            key: ValueKey<String>('feed-${ch.key}-$_sourceRev'),
            initialType: ch.key,
            initialTitle: ch.label,
            initialSort: 'hot',
            embedded: true,
          ),
        ),
      ],
    );
  }

  /// 推荐 tab：维持原样（banner + 多个分区，每个分区带「更多 >」）。
  Widget _recommendFeed() {
    final data = _cache[_channel];
    return RefreshIndicator(
      color: Fx.accent,
      backgroundColor: Colors.white,
      onRefresh: () => _load(force: true),
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

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _logo(),
              const SizedBox(width: 8),
              // 源名（壳的写法「名字 · APP」）：点一下弹源选择面板。
              Expanded(child: _sourceTitle()),
              _iconButton(
                icon: Icons.search_rounded,
                label: '搜索',
                onTap: _openSearch,
              ),
              _iconButton(
                icon: Icons.star_rounded,
                label: '收藏',
                onTap: _openFavorites,
              ),
              _iconButton(
                icon: Icons.history_rounded,
                label: '历史',
                onTap: _openHistory,
              ),
              const SizedBox(width: 4),
              _togetherChip(),
            ],
          ),
          const SizedBox(height: 12),
          _searchBar(),
          const SizedBox(height: 10),
          _channelTabs(),
          const SizedBox(height: 10),
        ],
      ),
    );
  }

  /// 圆形 logo（assets/logo.png 圆形裁切）。
  Widget _logo() {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Fx.accent.withValues(alpha: .20),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipOval(
        child: Image.asset(
          'assets/logo.png',
          fit: BoxFit.cover,
          cacheWidth: (34 * MediaQuery.devicePixelRatioOf(context))
              .round()
              .clamp(34, 204),
        ),
      ),
    );
  }

  /// 「咕噜 · APP」/「幻想 · APP」：玻璃胶囊 + 弹面板的箭头。热区 44dp。
  Widget _sourceTitle() {
    return Semantics(
      button: true,
      label: '选择接口：${_hub.homeSourceName}',
      child: SizedBox(
        height: 44,
        child: Center(
          child: PGlassPill(
            height: 34,
            tint: .62,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            onTap: _pickSource,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    _hub.homeSourceTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14.5,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                      color: Fx.ink,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                const Icon(
                  Icons.expand_more_rounded,
                  size: 16,
                  color: Fx.sub,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 圆形玻璃按钮：走 PGlassIcon（玻璃底 + 白描边 + 44dp 热区）。
  Widget _iconButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return PGlassIcon(
      icon: icon,
      onTap: onTap,
      size: 34,
      iconSize: 17,
      tint: .62,
      iconColor: Fx.ink,
      hitSize: 44,
      tooltip: label,
    );
  }

  /// 源选择面板：选完就按那个源重拉首页（幻想是默认，永远第一项）。
  Future<void> _pickSource() async {
    final choice = await showFxSourceSheet(context);
    if (!mounted || choice == null) return;
    final hub = SourceHub.instance;
    if (choice.key != hub.homeSourceKey) {
      await hub.selectHomeSource(choice.key);
      if (!mounted) return;
      // 换源 = 换一整套数据：清缓存、回到「推荐」、重新拉。
      setState(() {
        _cache.clear();
        _channel = 'recommend';
        _bannerPage.value = 0;
        _sourceRev++;
      });
      await _load(force: true);
      if (!mounted) return;
      _toast('已切换到「${hub.homeSourceName}」');
      return;
    }
    // 点的是当前源那一行的刷新图标：只重拉首页。
    await _load(force: true);
    if (!mounted) return;
    _toast('「${hub.homeSourceName}」已刷新');
  }

  void _openFavorites() {
    Navigator.of(
      context,
    ).push(FxPageRoute(builder: (_) => const FavoritePage()));
  }

  void _openHistory() {
    Navigator.of(
      context,
    ).push(FxPageRoute(builder: (_) => const HistoryPage()));
  }

  /// 一起看（用户明确要求保留，放在最右）。玻璃胶囊，和左边的圆钮同高。
  Widget _togetherChip() {
    return Semantics(
      button: true,
      label: '一起看',
      child: PGlassPill(
        height: 34,
        tint: .62,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        onTap: () => Navigator.of(
          context,
        ).push(FxPageRoute(builder: (_) => const TogetherPage())),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.groups_rounded, size: 15, color: Fx.accent),
            SizedBox(width: 4),
            Text(
              '一起看',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: Fx.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 搜索框：玻璃胶囊（毛玻璃底 + 白描边），和壳的搜索框一致。
  Widget _searchBar() {
    return FxGlassPanel(
      radius: 22,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: SizedBox(
        height: 44,
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
      ),
    );
  }

  /// 分类胶囊条（壳的样式）：玻璃底条 + 选中态**实心主题色胶囊**、
  /// 未选中透明；最右边一枚 ☰ 是「全部片库」入口。
  Widget _channelTabs() {
    return FxGlassPanel(
      radius: 21,
      padding: const EdgeInsets.all(4),
      child: SizedBox(
        height: 34,
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: Row(
                  children: [
                    for (final c in _channels)
                      _channelChip(c),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            // ☰：拉出完整分类页（壳的「更多分类」）。
            PGlassIcon(
              icon: Icons.menu_rounded,
              size: 30,
              iconSize: 16,
              tint: .18,
              iconColor: Fx.sub,
              hitSize: 34,
              tooltip: '全部分类',
              onTap: () => _openCategory('', '全部片库'),
            ),
          ],
        ),
      ),
    );
  }

  /// 一枚分类胶囊：选中 = 实心主题色 + 白字；未选中 = 透明 + 灰字。
  Widget _channelChip(CmsChannel c) {
    final on = c.key == _channel;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _selectChannel(c.key),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? Fx.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(17),
          boxShadow: on
              ? [
                  BoxShadow(
                    color: Fx.accent.withValues(alpha: .28),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Text(
          c.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: on ? FontWeight.w600 : FontWeight.w400,
            color: on ? Colors.white : Fx.sub,
          ),
        ),
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

import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'category_page.dart';
import 'detail_page.dart';
import 'search_page.dart';
import 'together_page.dart';

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

class _HomePageState extends State<HomePage> {
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
  int _bannerIndex = 0;
  int _req = 0;
  bool _loading = true;
  bool _dragging = false;
  String? _error;

  /// 直播频道单独维护：接口可能为空 / 404，失败也按空态处理，不弹错误。
  List<LiveChannel> _liveItems = const <LiveChannel>[];
  bool _liveLoading = false;
  bool _liveLoaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _bannerCtrl.dispose();
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
        _bannerIndex = 0;
      });
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
    m.showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xEE1B2430),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 96),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ));
  }

  Future<void> _loadLive() async {
    final req = ++_req;
    setState(() => _liveLoading = true);
    try {
      final items = await Api.live();
      if (!mounted || req != _req || _channel != 'live') return;
      setState(() {
        _liveItems = items;
        _liveLoaded = true;
        _liveLoading = false;
      });
    } catch (_) {
      // 404 / 网络异常 / 脏数据都按「暂无直播」处理，不弹错误也不影响其它频道。
      if (!mounted || req != _req || _channel != 'live') return;
      setState(() {
        _liveItems = const <LiveChannel>[];
        _liveLoaded = true;
        _liveLoading = false;
      });
    }
  }

  void _restartAuto() {
    _timer?.cancel();
    final n = _cache[_channel]?.banners.length ?? 0;
    if (n <= 1) return;
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || !_bannerCtrl.hasClients) return;
      final next = (_bannerIndex + 1) % n;
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
      _bannerIndex = 0;
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
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SearchPage(openAi: ai)),
    );
  }

  void _openDetail(String id) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DetailPage(id: id)),
    );
  }

  void _openCategory(String type, String title) {
    Navigator.of(context).push(
      MaterialPageRoute(
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
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        color: Fx.accent,
        backgroundColor: Colors.white,
        onRefresh: () => _channel == 'live' ? _loadLive() : _load(force: true),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics()),
          slivers: [
            SliverToBoxAdapter(child: _header()),
            ..._body(data),
            const SliverToBoxAdapter(child: SizedBox(height: 104)),
          ],
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
              const Text('已经到底啦 · 发现更多好片',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: Color(0xFFA6B1C2))),
            ],
          ),
        ),
      ),
    ];
  }

  /// 直播频道：2 列卡片；接口为空 / 失败时展示占位空态，不影响其它频道。
  List<Widget> _liveBody() {
    if (_liveLoading && !_liveLoaded) {
      return const [SliverToBoxAdapter(child: _HomeSkeleton())];
    }
    if (_liveItems.isEmpty) {
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
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.05,
          ),
          delegate: SliverChildBuilderDelegate(
            (ctx, i) => _LiveCard(
              item: _liveItems[i],
              onTap: () => _toast('直播即将上线'),
            ),
            childCount: _liveItems.length,
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
                      color: Fx.accent.withOpacity(.18),
                      blurRadius: 14,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(11),
                  child: Image.asset('assets/logo.png', fit: BoxFit.cover),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('幻想影视',
                        style: TextStyle(
                            fontSize: 20,
                            height: 1.2,
                            fontWeight: FontWeight.w600,
                            color: Fx.ink)),
                    const SizedBox(height: 2),
                    Text('高画 · 免费 · 无广',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            color: Fx.sub)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const TogetherPage()),
                ),
                child: Tooltip(
                  message: '一起看',
                  child: Semantics(
                    button: true,
                    label: '一起看',
                    child: Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 11),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(.72),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: Colors.white),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF50729F).withOpacity(.08),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.groups_rounded,
                              size: 16, color: Fx.accent),
                          SizedBox(width: 5),
                          Text('一起看',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Fx.ink)),
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
        color: Colors.white.withOpacity(.72),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withOpacity(.95)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF50729F).withOpacity(.08),
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
                child: Text('搜索片名、演员、导演',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: Fx.sub)),
              ),
            ),
          ),
          GestureDetector(
            onTap: () => _openSearch(ai: true),
            child: Container(
              height: 26,
              padding: const EdgeInsets.symmetric(horizontal: 9),
              decoration: BoxDecoration(
                gradient: Fx.brand,
                borderRadius: BorderRadius.circular(13),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_awesome_rounded,
                      size: 12, color: Colors.white),
                  SizedBox(width: 3),
                  Text('AI 找片',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Colors.white)),
                ],
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
        color: Colors.white.withOpacity(.58),
        borderRadius: BorderRadius.circular(21),
        border: Border.all(color: Colors.white.withOpacity(.92)),
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
                              color: Fx.accent.withOpacity(.22),
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
                onPageChanged: (i) => setState(() => _bannerIndex = i),
                itemBuilder: (ctx, i) {
                  final b = banners[i];
                  return Padding(
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
                                    Colors.black.withOpacity(.02),
                                    Colors.black.withOpacity(.12),
                                    Colors.black.withOpacity(.74),
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
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(.32),
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                        color: Colors.white.withOpacity(.24)),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.star_rounded,
                                          size: 12, color: Fx.gold),
                                      const SizedBox(width: 2),
                                      Text(
                                        b.rating.toStringAsFixed(1),
                                        style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.white),
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
                                        horizontal: 7, vertical: 2),
                                    decoration: BoxDecoration(
                                      gradient: Fx.brand,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: const Text('正在热播',
                                        style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.white)),
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
                                        color: Colors.white),
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
                                          color: Colors.white.withOpacity(.84)),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
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
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(
            banners.length,
            (i) => AnimatedContainer(
              duration: const Duration(milliseconds: 240),
              width: i == _bannerIndex % banners.length ? 18 : 6,
              height: 6,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                gradient: i == _bannerIndex % banners.length ? Fx.brand : null,
                color: i == _bannerIndex % banners.length
                    ? null
                    : const Color(0xFFCBD6E6),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
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

/// 直播卡片：封面 + 台名 + 分组标签。直播源尚未接入，点击只给占位提示。
class _LiveCard extends StatelessWidget {
  const _LiveCard({required this.item, required this.onTap});

  final LiveChannel item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final title = item.title.trim().isEmpty ? '未命名频道' : item.title.trim();
    final group = item.group.trim();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.72),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF50729F).withOpacity(.08),
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FxCover(url: item.cover, title: title, radius: 10),
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(.42),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.circle, size: 6, color: Color(0xFFFF5A5A)),
                          SizedBox(width: 3),
                          Text(
                            'LIVE',
                            style: TextStyle(
                              fontSize: 9,
                              height: 1.1,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 7),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Fx.ink,
              ),
            ),
            if (group.isNotEmpty) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Fx.accent.withOpacity(.10),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  group,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: Fx.accent,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

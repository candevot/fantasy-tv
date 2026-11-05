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
      _loading = !_cache.containsKey(key);
    });
    _timer?.cancel();
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
  String _sectionLabel(String raw) {
    if (raw.contains('最新')) return '最新更新';
    if (raw.contains('电影')) return '电影';
    if (raw.contains('动漫')) return '动漫';
    if (raw.contains('综艺')) return '综艺';
    if (raw.contains('高分')) return '高分好剧';
    if (raw.contains('今日') || raw.contains('热播')) return '今日热播';
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    final data = _cache[_channel];
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        color: Fx.accent,
        backgroundColor: Colors.white,
        onRefresh: () => _load(force: true),
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

    final sections = data.sections
        .where((s) => s.items.isNotEmpty && !s.title.contains('短剧'))
        .toList();
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
                                      b.rating > 0
                                          ? b.rating.toStringAsFixed(1)
                                          : '推荐',
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
    final count = s.items.length > 12 ? 12 : s.items.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        FxSectionTitle(
            title: _sectionLabel(s.title), onMore: () => _openSectionMore(s)),
        const SizedBox(height: 12),
        SizedBox(
          height: 212,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: count,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (ctx, i) {
              final item = s.items[i];
              return FxPosterCard(
                item: item,
                width: 112,
                onTap: () => _openDetail(item.id),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _HomeSkeleton extends StatefulWidget {
  const _HomeSkeleton();

  @override
  State<_HomeSkeleton> createState() => _HomeSkeletonState();
}

class _HomeSkeletonState extends State<_HomeSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _box({double? height, double? width, double radius = 14}) {
    return Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.62),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white.withOpacity(.9)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final itemWidth = (width - 32 - 20) / 3;
    return AnimatedBuilder(
      animation: _c,
      builder: (ctx, _) => Opacity(
        opacity: .55 + .35 * _c.value,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _box(height: 176, radius: 18),
              const SizedBox(height: 20),
              _box(height: 17, width: 132, radius: 6),
              const SizedBox(height: 10),
              Row(
                children: [
                  for (var i = 0; i < 3; i++) ...[
                    if (i != 0) const SizedBox(width: 10),
                    SizedBox(
                      width: itemWidth,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _box(height: itemWidth * 1.5, radius: 14),
                          const SizedBox(height: 6),
                          _box(height: 14, width: itemWidth * .84, radius: 4),
                          const SizedBox(height: 4),
                          _box(height: 11, width: itemWidth * .55, radius: 3),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 20),
              _box(height: 17, width: 156, radius: 6),
              const SizedBox(height: 10),
              Row(
                children: [
                  for (var i = 0; i < 3; i++) ...[
                    if (i != 0) const SizedBox(width: 10),
                    SizedBox(
                      width: itemWidth,
                      child: _box(height: itemWidth * 1.5, radius: 14),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

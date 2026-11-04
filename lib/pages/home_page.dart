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
    _Channel('duanju', '短剧'),
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
      margin: const EdgeInsets.fromLTRB(18, 0, 18, 96),
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
    if (s.title.contains('短剧')) {
      type = 'duanju';
      title = '短剧';
    } else if (s.title.contains('动漫')) {
      type = 'manhua';
      title = '动漫';
    } else if (s.title.contains('直播')) {
      type = 'live';
      title = '直播';
    }
    _openCategory(type, title);
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

    final sections = data.sections.where((s) => s.items.isNotEmpty).toList();
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
          (ctx, i) => _section(sections[i], i == 0),
          childCount: sections.length,
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(0, 26, 0, 0),
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
              const SizedBox(height: 9),
              const Text('已经到底啦 · 发现更多好片',
                  style: TextStyle(fontSize: 11, color: Color(0xFFA6B1C2))),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 0),
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
                  borderRadius: BorderRadius.circular(11),
                  boxShadow: [
                    BoxShadow(
                      color: Fx.accent.withOpacity(.28),
                      blurRadius: 14,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: const Icon(Icons.play_arrow_rounded,
                    color: Colors.white, size: 23),
              ),
              const SizedBox(width: 9),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('幻想影视',
                      style: TextStyle(
                          fontSize: 18.5,
                          fontWeight: FontWeight.w800,
                          color: Fx.ink,
                          letterSpacing: .4)),
                  Text('高清 4K · 多线路 · 纯净追剧',
                      style: TextStyle(
                          fontSize: 9,
                          color: Fx.sub.withOpacity(.9),
                          letterSpacing: .2)),
                ],
              ),
              const Spacer(),
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
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(.72),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF50729F).withOpacity(.10),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.groups_rounded,
                          size: 19, color: Fx.accent),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.65),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.verified_rounded,
                        size: 12, color: Color(0xFF5BC8A8)),
                    SizedBox(width: 3),
                    Text('纯净版',
                        style:
                            TextStyle(fontSize: 9.5, color: Fx.sub)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _searchBar(),
          const SizedBox(height: 13),
          _channelTabs(),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _searchBar() {
    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.72),
        borderRadius: BorderRadius.circular(21),
        border: Border.all(color: Colors.white.withOpacity(.95)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF50729F).withOpacity(.08),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 13),
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
                    style: TextStyle(fontSize: 12.5, color: Fx.sub)),
              ),
            ),
          ),
          GestureDetector(
            onTap: () => _openSearch(ai: true),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
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
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(right: 10),
        itemCount: _channels.length,
        separatorBuilder: (_, __) => const SizedBox(width: 21),
        itemBuilder: (ctx, i) {
          final c = _channels[i];
          final active = c.key == _channel;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _selectChannel(c.key),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  c.label,
                  style: TextStyle(
                    fontSize: active ? 16 : 14.5,
                    fontWeight: active ? FontWeight.w800 : FontWeight.w400,
                    color: active ? Fx.ink : Fx.sub,
                  ),
                ),
                const SizedBox(height: 5),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: active ? 18 : 0,
                  height: 3,
                  decoration: BoxDecoration(
                    gradient: active ? Fx.brand : null,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _banner(List<BannerItem> banners) {
    return Column(
      children: [
        SizedBox(
          height: 188,
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
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: GestureDetector(
                    onTap: () => _openDetail(b.id),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          FxCover(
                            url: b.cover,
                            title: b.title,
                            radius: 20,
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
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
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
                                          fontSize: 8.5,
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600)),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  b.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white,
                                      letterSpacing: .3),
                                ),
                                if (b.desc.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    b.desc,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 10.5,
                                        height: 1.45,
                                        color:
                                            Colors.white.withOpacity(.84)),
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
        const SizedBox(height: 10),
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

  Widget _section(HomeSection s, bool first) {
    final count = s.items.length > 12 ? 12 : s.items.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: first ? 18 : 23),
        FxSectionTitle(title: s.title, onMore: () => _openSectionMore(s)),
        const SizedBox(height: 12),
        SizedBox(
          height: 226,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            itemCount: count,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (ctx, i) {
              final item = s.items[i];
              return FxPosterCard(
                item: item,
                width: 116,
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
    final itemWidth = (width - 36 - 24) / 3;
    return AnimatedBuilder(
      animation: _c,
      builder: (ctx, _) => Opacity(
        opacity: .55 + .35 * _c.value,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _box(height: 170, radius: 20),
              const SizedBox(height: 26),
              _box(height: 17, width: 132, radius: 7),
              const SizedBox(height: 14),
              Row(
                children: [
                  for (var i = 0; i < 3; i++) ...[
                    if (i != 0) const SizedBox(width: 12),
                    SizedBox(
                      width: itemWidth,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _box(height: itemWidth * 1.5),
                          const SizedBox(height: 8),
                          _box(height: 11, width: itemWidth * .84, radius: 5),
                          const SizedBox(height: 5),
                          _box(height: 9, width: itemWidth * .55, radius: 4),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 28),
              _box(height: 17, width: 156, radius: 7),
              const SizedBox(height: 14),
              Row(
                children: [
                  for (var i = 0; i < 3; i++) ...[
                    if (i != 0) const SizedBox(width: 12),
                    _box(height: itemWidth * 1.5, width: itemWidth),
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

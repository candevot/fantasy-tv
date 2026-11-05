import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/player_theme.dart' show fxToast;
import 'category_page.dart';
import 'detail_page.dart';

class _RankType {
  const _RankType(this.key, this.label);
  final String key;
  final String label;
}

class _Period {
  const _Period(this.key, this.name);
  final String key;
  final String name;
}

class RankPage extends StatefulWidget {
  const RankPage({super.key});

  @override
  State<RankPage> createState() => _RankPageState();
}

class _RankPageState extends State<RankPage> {
  static const List<_RankType> _types = [
    _RankType('juji', '剧集'),
    _RankType('movie', '电影'),
    _RankType('zongyi', '综艺'),
    _RankType('manhua', '动漫'),
  ];
  static const List<_Period> _periods = [
    _Period('day', '日榜'),
    _Period('week', '周榜'),
    _Period('month', '月榜'),
    _Period('total', '总榜'),
  ];

  String _type = 'juji';
  String _period = 'week';
  List<VideoCard> _raw = [];
  List<VideoCard> _items = [];
  bool _loading = true;
  String? _error;
  int _req = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String get _periodName {
    for (final p in _periods) {
      if (p.key == _period) return p.name;
    }
    return '周榜';
  }

  List<VideoCard> _order(List<VideoCard> src) {
    if (_period == 'day' || _period == 'week') return List<VideoCard>.from(src);
    final list = List<VideoCard>.from(src);
    if (_period == 'month') {
      list.sort((a, b) => b.rating.compareTo(a.rating));
    } else {
      list.sort((a, b) {
        final r = b.rating.compareTo(a.rating);
        return r != 0 ? r : b.year.compareTo(a.year);
      });
    }
    return list;
  }

  Future<void> _load() async {
    final req = ++_req;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await Api.rank(_type);
      if (!mounted || req != _req) return;
      setState(() {
        _raw = list;
        _items = _order(list);
        _loading = false;
      });
    } catch (e) {
      if (!mounted || req != _req) return;
      final msg = fxErrorText(e);
      setState(() {
        _loading = false;
        _error = msg;
      });
      // 已有榜单时不要整页报错：保留旧数据 + 顶部重试条，再轻提示一次。
      if (_items.isNotEmpty) fxToast(context, '刷新失败：$msg');
    }
  }

  void _selectType(String key) {
    if (_type == key) return;
    setState(() {
      _type = key;
      _raw = [];
      _items = [];
      _error = null;
      _loading = true;
    });
    _load();
  }

  void _selectPeriod(String key) {
    if (_period == key) return;
    setState(() {
      _period = key;
      _items = _order(_raw);
    });
  }

  void _openDetail(String id) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DetailPage(id: id)),
    );
  }

  Color _rankColor(int i) {
    if (i == 0) return Fx.gold;
    if (i == 1) return const Color(0xFF8FA7C8);
    if (i == 2) return const Color(0xFFC79A78);
    return const Color(0xFFB3BECD);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          _header(),
          if (_error != null && _items.isNotEmpty) _retryBar(),
          const SizedBox(height: 12),
          Expanded(child: _content()),
        ],
      ),
    );
  }

  /// 刷新失败但还有旧榜单：顶部细条提示 + 重试，不整页报错。
  Widget _retryBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, size: 14, color: Fx.sub),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              '刷新失败，当前为上次榜单',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w400, color: Fx.sub),
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _loading ? null : _load,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Text(
                '重试',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Fx.accent,
                ),
              ),
            ),
          ),
        ],
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
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('排行榜',
                        style: TextStyle(
                            fontSize: 20,
                            height: 1.2,
                            fontWeight: FontWeight.w600,
                            color: Fx.ink)),
                    SizedBox(height: 2),
                    Text('发现此刻最热的剧集',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            color: Fx.sub)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _periodButton(),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _loading ? null : _load,
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.72),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white),
                  ),
                  child: _loading
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Fx.accent),
                          ),
                        )
                      : const Icon(Icons.refresh_rounded,
                          size: 18, color: Fx.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            height: 40,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.58),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withOpacity(.92)),
            ),
            child: Row(
              children: [
                for (final t in _types)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _selectType(t.key),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOutCubic,
                        decoration: BoxDecoration(
                          gradient: t.key == _type ? Fx.brand : null,
                          borderRadius: BorderRadius.circular(17),
                          boxShadow: t.key == _type
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
                            t.label,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: t.key == _type
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: t.key == _type ? Colors.white : Fx.sub,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _periodButton() {
    return PopupMenuButton<String>(
      tooltip: '',
      elevation: 10,
      color: Colors.white,
      offset: const Offset(0, 36),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onSelected: _selectPeriod,
      itemBuilder: (ctx) => [
        for (final p in _periods)
          PopupMenuItem<String>(
            value: p.key,
            height: 40,
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  child: p.key == _period
                      ? const Icon(Icons.check_rounded,
                          size: 15, color: Fx.accent)
                      : null,
                ),
                Text(
                  p.name,
                  style: TextStyle(
                    fontSize: 13,
                    color: p.key == _period ? Fx.accent : Fx.ink,
                    fontWeight:
                        p.key == _period ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.8),
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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_periodName,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600, color: Fx.ink)),
            const SizedBox(width: 2),
            const Icon(Icons.expand_more_rounded, size: 16, color: Fx.sub),
          ],
        ),
      ),
    );
  }

  Widget _content() {
    if (_loading && _items.isEmpty) {
      return const FxLoadingView(label: '正在整理榜单…');
    }
    if (_error != null && _items.isEmpty) {
      return FxErrorView(message: _error!, onRetry: _load);
    }
    if (_items.isEmpty) {
      return FxEmptyView(
        icon: Icons.local_fire_department_outlined,
        title: '榜单暂时还是空的',
        subtitle: '换个分类，或稍后刷新试试',
        actionText: '刷新',
        onAction: _load,
      );
    }
    return RefreshIndicator(
      color: Fx.accent,
      backgroundColor: Colors.white,
      onRefresh: _load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 104),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (ctx, i) => _row(_items[i], i),
      ),
    );
  }

  Widget _rankBadge(int i) {
    final top = i < 3;
    final color = _rankColor(i);
    return Container(
      width: 34,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: top
            ? LinearGradient(
                colors: [color, color.withOpacity(.72)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: top ? null : Colors.white.withOpacity(.66),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: top ? Colors.white.withOpacity(.38) : Colors.white,
        ),
        boxShadow: top
            ? [
                BoxShadow(
                  color: color.withOpacity(.26),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Text(
        '${i + 1}',
        style: TextStyle(
          fontSize: top ? 16 : 14,
          height: 1,
          fontWeight: FontWeight.w700,
          color: top ? Colors.white : Fx.sub,
        ),
      ),
    );
  }

  Widget _row(VideoCard item, int i) {
    final meta = [
      if (item.year > 0) '${item.year}',
      fxCategoryName(item.category),
    ].join(' · ');
    final update = item.status.isNotEmpty
        ? '${item.status}${item.episodes > 0 ? ' · 共 ${item.episodes} 集' : ''}'
        : (item.episodes > 0 ? '全 ${item.episodes} 集' : '榜单热度上升中');
    return GlassCard(
      padding: const EdgeInsets.all(10),
      radius: 18,
      opacity: i < 3 ? .72 : .6,
      onTap: () => _openDetail(item.id),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _rankBadge(i),
          const SizedBox(width: 10),
          SizedBox(
            width: 64,
            height: 96,
            child: FxCover(url: item.cover, title: item.title, radius: 14),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 96,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14,
                        height: 1.25,
                        fontWeight: FontWeight.w500,
                        color: Fx.ink),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.star_rounded, size: 14, color: Fx.gold),
                      const SizedBox(width: 3),
                      Text(
                        item.rating > 0 ? item.rating.toStringAsFixed(1) : '—',
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Fx.gold),
                      ),
                      if (meta.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w400,
                                color: Fx.sub),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const Spacer(),
                  Text(
                    update,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12,
                        height: 1.2,
                        fontWeight: FontWeight.w400,
                        color: Fx.sub),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

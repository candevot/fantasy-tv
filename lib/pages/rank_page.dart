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
          const SizedBox(height: 4),
          Expanded(child: _content()),
        ],
      ),
    );
  }

  /// 刷新失败但还有旧榜单：顶部细条提示 + 重试，不整页报错。
  Widget _retryBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, size: 14, color: Fx.sub),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              '刷新失败，当前为上次榜单',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: Fx.sub),
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
                  fontSize: 11.5,
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
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('排行榜',
                      style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: Fx.ink,
                          letterSpacing: -.3)),
                  SizedBox(height: 2),
                  Text('发现此刻最热的剧集',
                      style: TextStyle(fontSize: 11, color: Fx.sub)),
                ],
              ),
              const Spacer(),
              _periodButton(),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _loading ? null : _load,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.72),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white),
                  ),
                  child: _loading
                      ? const Padding(
                          padding: EdgeInsets.all(9),
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
          const SizedBox(height: 13),
          SizedBox(
            height: 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _types.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (ctx, i) {
                final t = _types[i];
                final active = t.key == _type;
                return GestureDetector(
                  onTap: () => _selectType(t.key),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(horizontal: 15),
                    decoration: BoxDecoration(
                      gradient: active ? Fx.brand : null,
                      color: active ? null : Colors.white.withOpacity(.65),
                      borderRadius: BorderRadius.circular(17),
                      border: Border.all(
                        color: active ? Colors.transparent : Colors.white,
                      ),
                      boxShadow: active
                          ? [
                              BoxShadow(
                                color: Fx.accent.withOpacity(.28),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ]
                          : null,
                    ),
                    child: Center(
                      child: Text(
                        t.label,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight:
                              active ? FontWeight.w700 : FontWeight.w400,
                          color: active ? Colors.white : Fx.sub,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 9),
          Row(
            children: [
              const Icon(Icons.insights_rounded, size: 13, color: Fx.sub),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  '$_periodName · 根据片库热度整理，实时更新',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, color: Fx.sub),
                ),
              ),
              if (!_loading && _raw.isNotEmpty)
                Text('TOP ${_raw.length}',
                    style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFA6B1C2))),
            ],
          ),
          const SizedBox(height: 6),
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
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.8),
          borderRadius: BorderRadius.circular(17),
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
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Fx.ink)),
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
        physics:
            const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(18, 6, 18, 104),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (ctx, i) => _row(_items[i], i),
      ),
    );
  }

  Widget _row(VideoCard item, int i) {
    final color = _rankColor(i);
    final tagLine = item.tags.isEmpty
        ? fxCategoryName(item.category)
        : item.tags.take(3).join(' · ');
    final metaLine = [
      if (item.year > 0) '${item.year}',
      if (item.status.isNotEmpty) item.status,
      if (item.episodes > 0) '全 ${item.episodes} 集',
    ].join(' · ');
    return GlassCard(
      padding: const EdgeInsets.all(10),
      radius: 18,
      opacity: i < 3 ? .72 : .6,
      onTap: () => _openDetail(item.id),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 32,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                children: [
                  Text(
                    '${i + 1}',
                    style: TextStyle(
                      fontSize: i < 3 ? 22 : 16,
                      height: 1,
                      fontWeight: FontWeight.w900,
                      fontStyle: FontStyle.italic,
                      color: color,
                    ),
                  ),
                  if (i < 3) ...[
                    const SizedBox(height: 4),
                    Container(
                      width: 13,
                      height: 2.5,
                      decoration: BoxDecoration(
                        color: color.withOpacity(.55),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 62,
            height: 93,
            child: Stack(
              fit: StackFit.expand,
              children: [
                FxCover(url: item.cover, title: item.title, radius: 11),
                if (item.rating > 0)
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: RatingBadge(item.rating),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 93,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: Fx.ink),
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      const Icon(Icons.star_rounded,
                          size: 13, color: Fx.gold),
                      const SizedBox(width: 2),
                      Text(
                        item.rating > 0
                            ? item.rating.toStringAsFixed(1)
                            : '—',
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Fx.gold),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          metaLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              const TextStyle(fontSize: 10, color: Fx.sub),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Fx.accent.withOpacity(.08),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      tagLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 9.5, color: Fx.accent),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    item.status.isNotEmpty
                        ? '${item.status}${item.episodes > 0 ? ' · 共 ${item.episodes} 集' : ''}'
                        : (item.tags.isNotEmpty
                            ? item.tags.join(' / ')
                            : '片库热度持续上升中'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 10.5, height: 1.3, color: Fx.sub),
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

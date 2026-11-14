import 'package:flutter/material.dart';

import '../models.dart';
import '../services/cms_bridge.dart';
import '../theme.dart';
import '../widgets/player_theme.dart' show fxToast;
import 'category_page.dart';
import 'detail_page.dart';
import '../utils/fx_route.dart';

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
    _Period('week', '周榜'),
    _Period('day', '日榜'),
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

  /// 榜单接口不返回简介：可见卡片按需拉一次详情补齐，失败就保持占位文案。
  final Map<String, String> _desc = <String, String>{};

  /// 详情返回的线路名；列表接口没给 source 时用它给卡片补来源小字。
  final Map<String, String> _source = <String, String>{};
  final Set<String> _descPending = <String>{};
  final List<String> _descQueue = <String>[];
  int _descActive = 0;
  static const int _descConcurrency = 3;

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
      final list = await CmsBridge.rank(_type);
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
      FxPageRoute(builder: (_) => DetailPage(id: id)),
    );
  }

  /* -------------------------------------------------- 简介懒加载 */

  void _ensureDesc(VideoCard item) {
    final id = item.id;
    if (id.isEmpty || item.desc.isNotEmpty) return;
    if (_desc.containsKey(id) || _descPending.contains(id)) return;
    _descPending.add(id);
    _descQueue.add(id);
    _pumpDesc();
  }

  void _pumpDesc() {
    while (_descActive < _descConcurrency && _descQueue.isNotEmpty) {
      final id = _descQueue.removeAt(0);
      _descActive++;
      _fetchDesc(id);
    }
  }

  Future<void> _fetchDesc(String id) async {
    try {
      final detail = await CmsBridge.detail(id);
      if (!mounted) return;
      setState(() {
        _desc[id] = detail.desc;
        final source = detail.sourceLabel;
        if (source.isNotEmpty) _source[id] = source;
      });
    } catch (_) {
      if (!mounted) return;
      // 记空串：不再重复请求，卡片显示「暂无简介」而不是留白。
      setState(() => _desc[id] = '');
    } finally {
      _descActive--;
      _descPending.remove(id);
      if (mounted) _pumpDesc();
    }
  }

  String _descOf(VideoCard item) {
    if (item.desc.isNotEmpty) return item.desc;
    return _desc[item.id] ?? '';
  }

  String _descPlaceholder(VideoCard item) {
    if (_desc.containsKey(item.id)) return '暂无简介';
    return '简介加载中…';
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
                    Text('根据实时热度整理',
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
                    color: Colors.white.withValues(alpha: .72),
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
              color: Colors.white.withValues(alpha: .58),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: .92)),
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
                                    color: Fx.accent.withValues(alpha: .22),
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
          color: Colors.white.withValues(alpha: .8),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF50729F).withValues(alpha: .08),
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
      return const FxSkeletonPulse(child: FxRankListSkeleton(count: 6));
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
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (ctx, i) => _row(_items[i], i),
      ),
    );
  }

  Widget _rankBadge(int i) {
    final top = i < 3;
    final color = _rankColor(i);
    return Container(
      width: 30,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: top
            ? LinearGradient(
                colors: [color, color.withValues(alpha: .72)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: top ? null : Colors.white.withValues(alpha: .66),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: top ? Colors.white.withValues(alpha: .38) : Colors.white,
        ),
        boxShadow: top
            ? [
                BoxShadow(
                  color: color.withValues(alpha: .26),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Text(
        '${i + 1}',
        style: TextStyle(
          fontSize: top ? 15 : 13,
          height: 1,
          fontWeight: FontWeight.w700,
          color: top ? Colors.white : Fx.sub,
        ),
      ),
    );
  }

  Widget _statusTag(String status) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Fx.accent.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        status,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 10.5,
          height: 1.2,
          fontWeight: FontWeight.w600,
          color: Fx.accent,
        ),
      ),
    );
  }

  Widget _row(VideoCard item, int i) {
    final meta = <String>[
      if (item.year > 0) '${item.year}',
      if (item.type.isNotEmpty) item.type else fxCategoryName(item.category),
      if (item.area.isNotEmpty) item.area,
    ].join(' · ');
    final status = item.status.isNotEmpty
        ? item.status
        : (item.episodes > 0 ? '全 ${item.episodes} 集' : '热度上升中');
    final badge = fxBadgeText(item);
    _ensureDesc(item);
    final desc = _descOf(item);
    final source = item.sourceLabel.trim().isNotEmpty
        ? item.sourceLabel.trim()
        : (_source[item.id] ?? '');
    return GlassCard(
      padding: const EdgeInsets.all(10),
      radius: 18,
      opacity: i < 3 ? .72 : .6,
      onTap: () => _openDetail(item.id),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _rankBadge(i),
          const SizedBox(width: 8),
          SizedBox(
            width: 66,
            height: 99,
            child: Stack(
              fit: StackFit.expand,
              children: [
                FxCover(url: item.cover, title: item.title, radius: 10),
                if (badge != null)
                  Positioned(
                    left: 4,
                    top: 4,
                    child: FxPosterBadge(badge),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            // 内容至少与封面同高；大字体下随文字长高，不裁描述也不压住底栏。
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 99),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                        color: Fx.ink),
                  ),
                  if (source.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    FxSourceLabel(source),
                  ],
                  const SizedBox(height: 3),
                  Text(
                    meta.isEmpty ? '影视' : meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11.5,
                        height: 1.2,
                        fontWeight: FontWeight.w400,
                        color: Fx.sub),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    desc.isNotEmpty ? desc : _descPlaceholder(item),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.45,
                      fontWeight: FontWeight.w400,
                      color: desc.isNotEmpty
                          ? const Color(0xFF5A6577)
                          : const Color(0xFFA6B1C2),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Flexible(child: _statusTag(status)),
                      if (item.heat.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(
                          '热度 ${item.heat}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 10.5, color: Color(0xFFA6B1C2)),
                        ),
                      ],
                    ],
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

import 'package:flutter/material.dart';

import '../theme.dart';
import 'category_page.dart';
import 'detail_page.dart';
import 'history_page.dart';

/* ========================================================================== */
/*  收藏                                                                       */
/* ========================================================================== */

class FavRecord {
  FavRecord({
    required this.id,
    required this.title,
    required this.cover,
    required this.rating,
    required this.year,
    required this.status,
    required this.episodes,
    required this.category,
    required this.tags,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String cover;
  final num rating;
  final int year;
  final String status;
  final int episodes;
  final String category;
  final List<String> tags;
  final int updatedAt;

  factory FavRecord.fromMap(Map<String, dynamic> m) => FavRecord(
        id: fxStr(m['id']),
        title: fxStr(m['title'], '未命名影片'),
        cover: fxStr(m['cover']),
        rating: (m['rating'] is num) ? m['rating'] as num : 0,
        year: fxInt(m['year']),
        status: fxStr(m['status']),
        episodes: fxInt(m['episodes']),
        category: fxStr(m['category']),
        tags: (m['tags'] is List)
            ? (m['tags'] as List).map((e) => '$e').toList()
            : <String>[],
        updatedAt: fxInt(m['updatedAt']),
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'id': id,
        'title': title,
        'cover': cover,
        'rating': rating,
        'year': year,
        'status': status,
        'episodes': episodes,
        'category': category,
        'tags': tags,
        'updatedAt': updatedAt,
      };
}

class FavoritePage extends StatefulWidget {
  const FavoritePage({super.key});

  @override
  State<FavoritePage> createState() => _FavoritePageState();
}

class _FavoritePageState extends State<FavoritePage> {
  List<FavRecord> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final raw = await FxStore.read(FxStore.favoriteKey);
    final list = raw.map(FavRecord.fromMap).where((e) => e.id.isNotEmpty).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (!mounted) return;
    setState(() {
      _items = list;
      _loading = false;
    });
  }

  Future<void> _persist() async {
    await FxStore.write(
        FxStore.favoriteKey, _items.map((e) => e.toMap()).toList());
  }

  Future<void> _delete(FavRecord r) async {
    setState(() => _items.removeWhere((e) => e.id == r.id));
    await _persist();
    _toast('已取消收藏');
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('清空我的收藏？',
            style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
        content: const Text('清空后无法恢复，观看历史与离线缓存不受影响。',
            style: TextStyle(fontSize: 12.5, height: 1.5, color: Fx.sub)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Fx.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('清空', style: TextStyle(color: Color(0xFFE45C5C))),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _items = []);
    await _persist();
    _toast('收藏已清空');
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

  void _open(String id) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DetailPage(id: id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FxPageScaffold(
      title: '我的收藏',
      actions: [
        FxTextAction(
          '清空',
          icon: Icons.delete_sweep_rounded,
          onTap: _items.isEmpty ? null : _confirmClear,
        ),
      ],
      child: _content(),
    );
  }

  Widget _content() {
    if (_loading) return const FxLoadingView(label: '正在读取收藏…');
    if (_items.isEmpty) {
      return const FxEmptyView(
        icon: Icons.favorite_border_rounded,
        title: '还没有收藏',
        subtitle: '在详情页点亮爱心，喜欢的片子会出现在这里',
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Row(
            children: [
              const Icon(Icons.favorite_rounded,
                  size: 12, color: Color(0xFFFF7EA8)),
              const SizedBox(width: 5),
              Text('共 ${_items.length} 部 · 按收藏时间排序',
                  style: const TextStyle(fontSize: 10.5, color: Fx.sub)),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(18, 2, 18, 30),
            itemCount: _items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (ctx, i) => _card(_items[i]),
          ),
        ),
      ],
    );
  }

  Widget _card(FavRecord r) {
    final tags = r.tags.take(3).join(' / ');
    final meta = [
      if (r.year > 0) '${r.year}',
      fxCategoryName(r.category),
      if (r.episodes > 0) '${r.episodes} 集',
    ].join(' · ');
    return GlassCard(
      padding: const EdgeInsets.all(10),
      radius: 18,
      opacity: .62,
      onTap: () => _open(r.id),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            height: 96,
            child: Stack(
              fit: StackFit.expand,
              children: [
                FxCover(url: r.cover, title: r.title, radius: 11),
                Positioned(
                  left: 5,
                  top: 5,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(.28),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.favorite_rounded,
                        size: 11, color: Color(0xFFFF9EBC)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 96,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  const SizedBox(height: 2),
                  Text(
                    r.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: Fx.ink),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.star_rounded,
                          size: 13, color: Fx.gold),
                      const SizedBox(width: 2),
                      Text(r.rating > 0 ? r.rating.toStringAsFixed(1) : '—',
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Fx.gold)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 10, color: Fx.sub)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Text(
                    tags.isEmpty
                        ? (r.status.isEmpty ? '收藏于 ${fxTimeAgo(r.updatedAt)}' : r.status)
                        : tags,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 10.5, color: Fx.sub, height: 1.4),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    r.status.isEmpty
                        ? '点击查看详情'
                        : (r.episodes > 0
                            ? '${r.status} · 共 ${r.episodes} 集'
                            : r.status),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 10.5, color: Fx.sub, height: 1.4),
                  ),
                  const Spacer(),
                  Text('收藏于 ${fxTimeAgo(r.updatedAt)}',
                      style: const TextStyle(
                          fontSize: 9.5, color: Color(0xFFA6B1C2))),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () => _delete(r),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.6),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close_rounded, size: 15, color: Fx.sub),
            ),
          ),
        ],
      ),
    );
  }
}

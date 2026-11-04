import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme.dart';
import 'category_page.dart';
import 'player_page.dart';
import 'search_page.dart';

/* ========================================================================== */
/*  本地记录仓库（详情页 / 播放页可复用）                                      */
/* ========================================================================== */

class FxStore {
  static const String historyKey = 'fx_history_v1';
  static const String favoriteKey = 'fx_favorites_v1';
  static const String downloadKey = 'fx_downloads_v1';

  static Future<List<Map<String, dynamic>>> read(String key) async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getStringList(key) ?? const <String>[];
      final out = <Map<String, dynamic>>[];
      for (final s in raw) {
        try {
          final v = jsonDecode(s);
          if (v is Map) out.add(Map<String, dynamic>.from(v));
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> write(String key, List<Map<String, dynamic>> items) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(key, items.map((e) => jsonEncode(e)).toList());
    } catch (_) {}
  }

  static Future<int> count(String key) async => (await read(key)).length;

  /// 记录一次观看（同一作品去重，最多 100 条）
  static Future<void> addHistory({
    required String id,
    required String title,
    String cover = '',
    int ep = 1,
    String epName = '',
    String line = '',
    int position = 0,
    int duration = 0,
  }) async {
    if (id.isEmpty) return;
    final list = await read(historyKey);
    list.removeWhere((e) => '${e['id']}' == id);
    list.insert(0, <String, dynamic>{
      'id': id,
      'title': title,
      'cover': cover,
      'ep': ep,
      'epName': epName,
      'line': line,
      'position': position,
      'duration': duration,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
    if (list.length > 100) list.removeRange(100, list.length);
    await write(historyKey, list);
  }

  /// 收藏一部作品（详情页可调用）
  static Future<void> addFavorite({
    required String id,
    required String title,
    String cover = '',
    num rating = 0,
    int year = 0,
    String status = '',
    int episodes = 0,
    String category = '',
    List<String> tags = const [],
  }) async {
    if (id.isEmpty) return;
    final list = await read(favoriteKey);
    list.removeWhere((e) => '${e['id']}' == id);
    list.insert(0, <String, dynamic>{
      'id': id,
      'title': title,
      'cover': cover,
      'rating': rating,
      'year': year,
      'status': status,
      'episodes': episodes,
      'category': category,
      'tags': tags,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
    await write(favoriteKey, list);
  }
}

/* ========================================================================== */
/*  观看历史                                                                   */
/* ========================================================================== */

class WatchRecord {
  WatchRecord({
    required this.id,
    required this.title,
    required this.cover,
    required this.ep,
    required this.epName,
    required this.line,
    required this.position,
    required this.duration,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String cover;
  final int ep;
  final String epName;
  final String line;
  final int position;
  final int duration;
  final int updatedAt;

  factory WatchRecord.fromMap(Map<String, dynamic> m) => WatchRecord(
        id: fxStr(m['id']),
        title: fxStr(m['title'], '未命名影片'),
        cover: fxStr(m['cover']),
        ep: fxInt(m['ep'], 1),
        epName: fxStr(m['epName']),
        line: fxStr(m['line']),
        position: fxInt(m['position']),
        duration: fxInt(m['duration']),
        updatedAt: fxInt(m['updatedAt']),
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'id': id,
        'title': title,
        'cover': cover,
        'ep': ep,
        'epName': epName,
        'line': line,
        'position': position,
        'duration': duration,
        'updatedAt': updatedAt,
      };

  double get progress {
    if (duration <= 0 || position <= 0) return 0;
    final v = position / duration;
    return v.clamp(0.0, 1.0).toDouble();
  }
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<WatchRecord> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final raw = await FxStore.read(FxStore.historyKey);
    final list = raw.map(WatchRecord.fromMap).where((e) => e.id.isNotEmpty).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (!mounted) return;
    setState(() {
      _items = list;
      _loading = false;
    });
  }

  Future<void> _persist() async {
    await FxStore.write(
        FxStore.historyKey, _items.map((e) => e.toMap()).toList());
  }

  Future<void> _delete(WatchRecord r) async {
    setState(() => _items.removeWhere((e) => e.id == r.id));
    await _persist();
    _toast('已删除这条记录');
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('清空观看历史？',
            style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
        content: const Text('清空后无法恢复，收藏与离线缓存不受影响。',
            style: TextStyle(fontSize: 12.5, height: 1.5, color: Fx.sub)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Fx.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: Color(0xFFE45C5C))),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _items = []);
    await _persist();
    _toast('观看历史已清空');
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

  void _continue(WatchRecord r) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(videoId: r.id, ep: r.ep, line: r.line),
      ),
    );
  }

  String _dayLabel(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(d.year, d.month, d.day);
    final diff = today.difference(target).inDays;
    if (diff <= 0) return '今天';
    if (diff == 1) return '昨天';
    if (diff < 7) return '本周';
    if (now.year == d.year) return '${d.month} 月';
    return '${d.year} 年';
  }

  @override
  Widget build(BuildContext context) {
    return FxPageScaffold(
      title: '观看历史',
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
    if (_loading) return const FxLoadingView(label: '正在读取观看记录…');
    if (_items.isEmpty) {
      return FxEmptyView(
        icon: Icons.history_rounded,
        title: '还没有观看记录',
        subtitle: '去挑一部好片，看到一半也会替你记住',
        actionText: '去搜片',
        onAction: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SearchPage()),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Row(
            children: [
              const Icon(Icons.cloud_done_rounded,
                  size: 13, color: Fx.sub),
              const SizedBox(width: 5),
              Text('共 ${_items.length} 条 · 仅保存在本机',
                  style: const TextStyle(fontSize: 10.5, color: Fx.sub)),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
            itemCount: _items.length,
            itemBuilder: (ctx, i) {
              final r = _items[i];
              final showHeader = i == 0 ||
                  _dayLabel(r.updatedAt) != _dayLabel(_items[i - 1].updatedAt);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showHeader)
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                          2, i == 0 ? 4 : 16, 2, 8),
                      child: Row(
                        children: [
                          Container(
                            width: 5,
                            height: 5,
                            decoration: const BoxDecoration(
                              color: Fx.accent,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(_dayLabel(r.updatedAt),
                              style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: Fx.sub)),
                        ],
                      ),
                    ),
                  _card(r),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _card(WatchRecord r) {
    final epLabel = r.epName.isNotEmpty ? r.epName : '第 ${r.ep} 集';
    final progressText = r.duration > 0 && r.position > 0
        ? '看到 ${fxDurationText(r.position)} / ${fxDurationText(r.duration)}'
        : '上次观看 ${fxTimeAgo(r.updatedAt)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: const EdgeInsets.all(10),
        radius: 18,
        opacity: .64,
        onTap: () => _continue(r),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 60,
              height: 90,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    FxCover(url: r.cover, title: r.title, radius: 10),
                    Center(
                      child: Container(
                        width: 25,
                        height: 25,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(.84),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.play_arrow_rounded,
                            size: 17, color: Fx.accent),
                      ),
                    ),
                    if (r.progress > 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: LinearProgressIndicator(
                          value: r.progress,
                          minHeight: 3,
                          backgroundColor: Colors.white.withOpacity(.4),
                          valueColor: const AlwaysStoppedAnimation<Color>(
                              Fx.accent),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    r.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Fx.ink),
                  ),
                  const SizedBox(height: 5),
                  Text(epLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11, color: Fx.accent)),
                  const SizedBox(height: 5),
                  Text(progressText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 10.5, color: Fx.sub)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.play_circle_fill_rounded,
                          size: 13, color: Fx.accent),
                      const SizedBox(width: 3),
                      const Text('继续观看',
                          style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: Fx.accent)),
                      const SizedBox(width: 6),
                      Text('· ${fxTimeAgo(r.updatedAt)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 9.5, color: Color(0xFFA6B1C2))),
                    ],
                  ),
                ],
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
                child: const Icon(Icons.close_rounded,
                    size: 15, color: Fx.sub),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

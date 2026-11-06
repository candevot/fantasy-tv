import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart' show Nav;
import '../theme.dart';
import 'category_page.dart';
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

  static Future<void> write(
      String key, List<Map<String, dynamic>> items) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(key, items.map((e) => jsonEncode(e)).toList());
    } catch (_) {}
  }

  static Future<int> count(String key) async => (await read(key)).length;

  /// 读-改-写串行队列：切集时详情页与播放器会同时回写历史，
  /// 不加队列时后写会覆盖先写，集数与进度互相打架。
  static Future<void> _pending = Future<void>.value();

  static Future<void> _serialized(Future<void> Function() action) {
    final next = _pending.then<void>((_) => action()).catchError((_) {});
    _pending = next;
    return next;
  }

  /// 记录一次观看（同一作品去重，最多 100 条）。
  ///
  /// 只传 ep/line 时保留已有进度：详情页重新加载不该把播放器写入的
  /// position/duration 清零。线路存 id 供续播，name 仅用于展示。
  /// [updateEpisode] = false 用于「打开详情页但还没真正播放」：只刷新
  /// 标题/封面，不覆盖历史里的集数与进度。
  static Future<void> addHistory({
    required String id,
    required String title,
    String cover = '',
    int ep = 1,
    String epName = '',
    String lineId = '',
    String lineName = '',
    int? position,
    int? duration,
    bool updateEpisode = true,
  }) async {
    if (id.isEmpty) return;
    await _serialized(() async {
      final list = await read(historyKey);
      Map<String, dynamic>? old;
      for (final e in list) {
        if ('${e['id']}' == id) {
          old = e;
          break;
        }
      }
      list.removeWhere((e) => '${e['id']}' == id);
      final oldLineId =
          old == null ? '' : _firstNonEmpty(old['lineId'], old['line']);
      final oldLineName =
          old == null ? '' : _firstNonEmpty(old['lineName'], old['line']);
      final hasOld = old != null;
      // 没播放过就不要动已有记录的集数/进度。
      final keepOld = hasOld && !updateEpisode;
      final oldEp = hasOld ? fxInt(old['ep'], 1) : ep;
      final oldEpName = hasOld ? fxStr(old['epName']) : epName;
      final keepProgress = hasOld &&
          (keepOld || fxInt(old['ep'], 1) == (updateEpisode ? ep : oldEp));
      final nextEp = keepOld ? oldEp : ep;
      list.insert(0, <String, dynamic>{
        'id': id,
        'title': title,
        'cover': cover.isEmpty && hasOld ? fxStr(old['cover']) : cover,
        'ep': nextEp,
        'epName': keepOld ? oldEpName : epName,
        'lineId': keepOld || lineId.isEmpty ? oldLineId : lineId,
        'lineName': keepOld || lineName.isEmpty ? oldLineName : lineName,
        // 旧版本只认 line；保留它，避免回退时线路丢失。
        'line': keepOld || lineName.isEmpty ? oldLineName : lineName,
        'position': position ?? (keepProgress ? fxInt(old['position']) : 0),
        'duration': duration ?? (keepProgress ? fxInt(old['duration']) : 0),
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });
      if (list.length > 100) list.removeRange(100, list.length);
      await write(historyKey, list);
    });
  }

  /// 播放器回写：只更新已有历史记录，不凭空新增。
  ///
  /// 集数以 [addHistory] 为准；这里只有记录已经是这一集时才写进度，
  /// 避免切集后旧集的迟到回写把新集进度覆盖掉。
  static Future<void> updateProgress({
    required String id,
    required int ep,
    required int position,
    required int duration,
    String epName = '',
    String lineId = '',
    String lineName = '',
  }) async {
    if (id.isEmpty) return;
    await _serialized(() async {
      final list = await read(historyKey);
      var found = false;
      for (final e in list) {
        if ('${e['id']}' != id) continue;
        if (fxInt(e['ep'], 1) != ep) return;
        found = true;
        if (epName.isNotEmpty) e['epName'] = epName;
        if (lineId.isNotEmpty) e['lineId'] = lineId;
        if (lineName.isNotEmpty) {
          e['lineName'] = lineName;
          e['line'] = lineName;
        }
        e['position'] = position < 0 ? 0 : position;
        e['duration'] = duration < 0 ? 0 : duration;
        e['updatedAt'] = DateTime.now().millisecondsSinceEpoch;
        break;
      }
      if (!found) return;
      await write(historyKey, list);
    });
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
    String kind = 'video',
    String group = '',
    String url = '',
    List<Map<String, dynamic>> lines = const <Map<String, dynamic>>[],
  }) async {
    if (id.isEmpty) return;
    final list = await read(favoriteKey);
    list.removeWhere(
        (e) => '${e['id']}' == id && '${e['kind'] ?? 'video'}' == kind);
    list.insert(0, <String, dynamic>{
      'id': id,
      'kind': kind,
      'title': title,
      'cover': cover,
      'rating': rating,
      'year': year,
      'status': status,
      'episodes': episodes,
      'category': category,
      'tags': tags,
      if (group.isNotEmpty) 'group': group,
      if (url.isNotEmpty) 'url': url,
      if (lines.isNotEmpty) 'lines': lines,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
    await write(favoriteKey, list);
  }
}

/* ========================================================================== */
/*  观看历史                                                                   */
/* ========================================================================== */

String _firstNonEmpty(Object? primary, Object? fallback) {
  final first = fxStr(primary);
  return first.isNotEmpty ? first : fxStr(fallback);
}

class WatchRecord {
  WatchRecord({
    required this.id,
    required this.title,
    required this.cover,
    required this.ep,
    required this.epName,
    required this.lineId,
    required this.lineName,
    required this.position,
    required this.duration,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String cover;
  final int ep;
  final String epName;

  /// 续播用的线路 id（旧记录没有时回退到 line 字段）。
  final String lineId;
  final String lineName;
  final int position;
  final int duration;
  final int updatedAt;

  factory WatchRecord.fromMap(Map<String, dynamic> m) => WatchRecord(
        id: fxStr(m['id']),
        title: fxStr(m['title'], '未命名影片'),
        cover: fxStr(m['cover']),
        ep: fxInt(m['ep'], 1),
        epName: fxStr(m['epName']),
        lineId: _firstNonEmpty(m['lineId'], m['line']),
        lineName: _firstNonEmpty(m['lineName'], m['line']),
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
        'lineId': lineId,
        'lineName': lineName,
        // 旧版本字段，保持可回退。
        'line': lineName,
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
    final list = raw
        .map(WatchRecord.fromMap)
        .where((e) => e.id.isNotEmpty)
        .toList()
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

  Future<void> _continue(WatchRecord r) async {
    // 与首页点卡片保持一致：先进详情页，由详情页定位集数并负责起播。
    // 作品已被服务端删除时，详情页会提示「该视频已失效」并提供删除入口。
    await Nav.detail(context, r.id, ep: r.ep, line: r.lineId);
    // 播放器会在播放中回写进度，返回时重新读一次让进度条保持最新。
    if (mounted) await _load();
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
              const Icon(Icons.cloud_done_rounded, size: 13, color: Fx.sub),
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
                      padding: EdgeInsets.fromLTRB(2, i == 0 ? 4 : 16, 2, 8),
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
    final epAndLine = r.lineName.isEmpty ? epLabel : '$epLabel · ${r.lineName}';
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
                          color: Colors.white.withValues(alpha: .84),
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
                          backgroundColor: Colors.white.withValues(alpha: .4),
                          valueColor:
                              const AlwaysStoppedAnimation<Color>(Fx.accent),
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
                  Text(epAndLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Fx.accent)),
                  const SizedBox(height: 5),
                  Text(progressText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10.5, color: Fx.sub)),
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
                  color: Colors.white.withValues(alpha: .6),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close_rounded, size: 15, color: Fx.sub),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

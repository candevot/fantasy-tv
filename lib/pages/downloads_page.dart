import 'package:flutter/material.dart';

import '../theme.dart';
import 'category_page.dart';
import 'history_page.dart';
import 'player_page.dart';

/* ========================================================================== */
/*  离线缓存                                                                   */
/* ========================================================================== */

class DownloadRecord {
  DownloadRecord({
    required this.id,
    required this.title,
    required this.cover,
    required this.ep,
    required this.epName,
    required this.size,
    required this.status,
    required this.line,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String cover;
  final int ep;
  final String epName;
  final int size;
  final String status;
  final String line;
  final int updatedAt;

  factory DownloadRecord.fromMap(Map<String, dynamic> m) => DownloadRecord(
        id: fxStr(m['id']),
        title: fxStr(m['title'], '未命名影片'),
        cover: fxStr(m['cover']),
        ep: fxInt(m['ep'], 1),
        epName: fxStr(m['epName']),
        size: fxInt(m['size']),
        status: fxStr(m['status'], '已缓存'),
        line: fxStr(m['line']),
        updatedAt: fxInt(m['updatedAt']),
      );
}

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  List<DownloadRecord> _items = [];
  bool _loading = true;

  int get _totalSize => _items.fold(0, (sum, e) => sum + e.size);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final raw = await FxStore.read(FxStore.downloadKey);
    final list = raw
        .map(DownloadRecord.fromMap)
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
    await FxStore.write(FxStore.downloadKey, [
      for (final e in _items)
        <String, dynamic>{
          'id': e.id,
          'title': e.title,
          'cover': e.cover,
          'ep': e.ep,
          'epName': e.epName,
          'size': e.size,
          'status': e.status,
          'line': e.line,
          'updatedAt': e.updatedAt,
        },
    ]);
  }

  Future<void> _delete(DownloadRecord r) async {
    setState(() => _items.removeWhere((e) => e.id == r.id));
    await _persist();
    _toast('已删除缓存记录');
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('清空离线缓存？',
            style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
        content: const Text('将移除全部缓存记录，不会影响观看历史与收藏。',
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
    _toast('缓存记录已清空');
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

  void _play(DownloadRecord r) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(videoId: r.id, ep: r.ep, line: r.line),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FxPageScaffold(
      title: '离线缓存',
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
    if (_loading) return const FxLoadingView(label: '正在读取缓存…');
    if (_items.isEmpty) {
      return const FxEmptyView(
        icon: Icons.download_rounded,
        title: '暂无离线缓存',
        subtitle: '在详情页点击「下载」，缓存任务会出现在这里',
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Row(
            children: [
              const Icon(Icons.offline_pin_rounded,
                  size: 13, color: Fx.sub),
              const SizedBox(width: 5),
              Text(
                '共 ${_items.length} 个任务 · ${fxBytes(_totalSize)}',
                style: const TextStyle(fontSize: 10.5, color: Fx.sub),
              ),
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

  Widget _card(DownloadRecord r) {
    final epLabel = r.epName.isNotEmpty ? r.epName : '第 ${r.ep} 集';
    final done = r.status.contains('完成') || r.status.contains('已缓存');
    return GlassCard(
      padding: const EdgeInsets.all(10),
      radius: 18,
      opacity: .62,
      onTap: () => _play(r),
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
                  bottom: 5,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(.36),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(epLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 8.5, color: Colors.white)),
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
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: done
                              ? const Color(0xFF5BC8A8).withOpacity(.12)
                              : Fx.gold.withOpacity(.13),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          r.status,
                          style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w600,
                              color: done
                                  ? const Color(0xFF2FA985)
                                  : const Color(0xFFD68A00)),
                        ),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          fxBytes(r.size),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 10, color: Fx.sub),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Text(epLabel,
                      style: const TextStyle(
                          fontSize: 10.5, color: Fx.sub)),
                  const Spacer(),
                  Row(
                    children: [
                      const Icon(Icons.play_circle_fill_rounded,
                          size: 14, color: Fx.accent),
                      const SizedBox(width: 3),
                      const Text('离线播放',
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

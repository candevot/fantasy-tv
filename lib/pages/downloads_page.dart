import 'package:flutter/material.dart';

import '../services/download_service.dart';
import '../theme.dart';
import 'category_page.dart';
import 'offline_player_page.dart';

/* ========================================================================== */
/*  离线缓存                                                                   */
/* ========================================================================== */

class _DownloadSection {
  const _DownloadSection(this.title, this.count, this.icon);

  final String title;
  final int count;
  final IconData icon;
}

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  final DownloadService _service = DownloadService.instance;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onChanged);
    _load();
  }

  Future<void> _load() async {
    await _service.init();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _service.removeListener(_onChanged);
    super.dispose();
  }

  List<DownloadTask> get _active {
    final list = _service.activeTasks.toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  List<DownloadTask> get _completed {
    final list = _service.completedTasks.toList();
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  bool get _hasActive => _service.tasks.any((t) =>
      t.status == DownloadStatus.downloading ||
      t.status == DownloadStatus.queued);

  bool get _hasPaused =>
      _service.tasks.any((t) => t.status == DownloadStatus.paused);

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('清空离线缓存？',
            style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
        content: const Text(
          '将停止所有下载并删除本地缓存文件，不影响观看历史与收藏。',
          style: TextStyle(fontSize: 12.5, height: 1.5, color: Fx.sub),
        ),
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
    await _service.clearAll();
    if (!mounted) return;
    _toast('已清空离线缓存');
  }

  Future<void> _delete(DownloadTask task) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text('删除「${task.epLabel}」缓存？',
            style:
                const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
        content: const Text('本地缓存文件会一并删除。',
            style: TextStyle(fontSize: 12.5, height: 1.5, color: Fx.sub)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Fx.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Color(0xFFE45C5C))),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _service.remove(task);
    if (!mounted) return;
    _toast('已删除「${task.epLabel}」');
  }

  Future<void> _deleteSeries(DownloadTask task) async {
    final count = _service.tasksForSeries(task.id).length;
    if (count <= 1) {
      await _delete(task);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text('删除「${task.title}」整部缓存？',
            style:
                const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
        content: Text(
          '将删除全部 $count 集的本地文件与任务记录，不影响其它剧集。',
          style: const TextStyle(fontSize: 12.5, height: 1.5, color: Fx.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Fx.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('删除整剧', style: TextStyle(color: Color(0xFFE45C5C))),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final removed = await _service.removeSeries(task.id);
    if (!mounted) return;
    _toast('已删除「${task.title}」$removed 集缓存');
  }

  Future<void> _play(DownloadTask task) async {
    final file = await _service.fileFor(task);
    if (!mounted) return;
    if (file == null) {
      _toast('缓存文件不存在，请删除后重新下载');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OfflinePlayerPage(task: task, file: file),
      ),
    );
  }

  void _toast(String msg) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xEE1B2430),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return FxPageScaffold(
      title: '离线缓存',
      actions: [
        FxTextAction(
          '清空',
          icon: Icons.delete_sweep_rounded,
          onTap: _service.tasks.isEmpty ? null : _confirmClear,
        ),
      ],
      child: _content(),
    );
  }

  Widget _content() {
    if (_loading) return const FxLoadingView(label: '正在读取缓存…');
    if (_service.tasks.isEmpty) {
      return const FxEmptyView(
        icon: Icons.download_rounded,
        title: '暂无离线缓存',
        subtitle: '在详情页点击「下载」并选择剧集，缓存任务会出现在这里',
      );
    }
    final active = _active;
    final completed = _completed;
    // 任务可能很多：拍平成「分组头 / 任务」两类行，交给 builder
    // 按需构建，避免一次性创建全部卡片。
    final rows = <Object>[
      if (active.isNotEmpty)
        _DownloadSection('下载中', active.length, Icons.downloading_rounded),
      ...active,
      if (completed.isNotEmpty)
        _DownloadSection('已完成', completed.length, Icons.offline_pin_rounded),
      ...completed,
    ];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
          child: Row(
            children: [
              _topAction(
                icon: Icons.pause_circle_outline_rounded,
                label: '全部暂停',
                enabled: _hasActive,
                onTap: _service.pauseAll,
              ),
              const SizedBox(width: 8),
              _topAction(
                icon: Icons.play_circle_outline_rounded,
                label: '全部继续',
                enabled: _hasPaused,
                onTap: _service.resumeAll,
              ),
              const Spacer(),
              Flexible(
                child: Text(
                  '${_service.tasks.length} 项 · ${fxBytes(_service.totalCachedBytes)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 10, color: Fx.sub),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
            itemCount: rows.length,
            itemBuilder: (ctx, i) {
              final row = rows[i];
              if (row is _DownloadSection) {
                return Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 8, bottom: 8),
                  child: _section(row.title, row.count, row.icon),
                );
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _card(row as DownloadTask),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _topAction({
    required IconData icon,
    required String label,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: enabled ? .72 : .38),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: Colors.white),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 13, color: enabled ? Fx.accent : const Color(0xFFB6C0CD)),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: enabled ? Fx.ink : const Color(0xFFB6C0CD),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(String title, int count, IconData icon) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 0),
      child: Row(
        children: [
          Icon(icon, size: 13, color: Fx.accent),
          const SizedBox(width: 5),
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: Fx.ink,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: Fx.accent.withValues(alpha: .10),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '$count',
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: Fx.accent,
              ),
            ),
          ),
          const Expanded(
            child: Divider(
              height: 1,
              thickness: 1,
              indent: 8,
              color: Color(0x0D1B2430),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(DownloadTask task) {
    final completed = task.status == DownloadStatus.completed;
    final failed = task.status == DownloadStatus.failed;
    final paused = task.status == DownloadStatus.paused;
    final downloading = task.status == DownloadStatus.downloading;

    return GlassCard(
      padding: const EdgeInsets.all(10),
      radius: 18,
      opacity: .62,
      onTap: completed ? () => _play(task) : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            height: 108,
            child: Stack(
              fit: StackFit.expand,
              children: [
                FxCover(url: task.cover, title: task.title, radius: 11),
                Positioned(
                  left: 5,
                  bottom: 5,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .36),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      task.epLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(fontSize: 8.5, color: Colors.white),
                    ),
                  ),
                ),
                if (completed)
                  Positioned(
                    right: 5,
                    top: 5,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        color: Color(0xCC2FA985),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.check_rounded,
                          size: 9, color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: SizedBox(
              height: 108,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: Fx.ink,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      _statusChip(task),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          task.lineName.trim().isEmpty
                              ? task.epLabel
                              : task.lineName.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 9.5, color: Fx.sub),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        task.sizeLabel,
                        style: const TextStyle(fontSize: 9.5, color: Fx.sub),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (failed)
                    Expanded(
                      child: Text(
                        task.error ?? '缓存失败，请重试',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 9.5,
                          height: 1.35,
                          color: Color(0xFFE45C5C),
                        ),
                      ),
                    )
                  else ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: task.progressValue,
                        minHeight: 3.5,
                        backgroundColor: const Color(0xFFE8EDF5),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          completed
                              ? const Color(0xFF5BC8A8)
                              : paused
                                  ? Fx.gold
                                  : Fx.accent,
                        ),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Text(
                          '${(task.progressValue * 100).round()}%',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: completed ? const Color(0xFF2FA985) : Fx.sub,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            task.progressDetail,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 9, color: Fx.sub),
                          ),
                        ),
                        if (downloading)
                          const Text(
                            '下载中…',
                            style: TextStyle(fontSize: 9, color: Fx.accent),
                          ),
                      ],
                    ),
                  ],
                  const Spacer(),
                  Row(
                    children: [
                      if (completed)
                        _action(
                          icon: Icons.play_arrow_rounded,
                          label: '离线播放',
                          color: Fx.accent,
                          onTap: () => _play(task),
                        )
                      else if (downloading ||
                          task.status == DownloadStatus.queued)
                        _action(
                          icon: Icons.pause_rounded,
                          label: '暂停',
                          color: const Color(0xFFD68A00),
                          onTap: () => _service.pause(task),
                        )
                      else if (paused)
                        _action(
                          icon: Icons.play_arrow_rounded,
                          label: '继续',
                          color: Fx.accent,
                          onTap: () => _service.resume(task),
                        )
                      else
                        _action(
                          icon: Icons.refresh_rounded,
                          label: '重试',
                          color: const Color(0xFFD68A00),
                          onTap: () => _service.retry(task),
                        ),
                      const SizedBox(width: 6),
                      if (_service.tasksForSeries(task.id).length > 1) ...[
                        _action(
                          icon: Icons.delete_sweep_outlined,
                          label: '整剧',
                          color: const Color(0xFFD68A00),
                          onTap: () => _deleteSeries(task),
                        ),
                        const SizedBox(width: 6),
                      ],
                      _action(
                        icon: Icons.delete_outline_rounded,
                        label: '删除',
                        color: const Color(0xFFE45C5C),
                        onTap: () => _delete(task),
                      ),
                      const Spacer(),
                      Text(
                        fxTimeAgo(task.updatedAt),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 8.5,
                          color: Color(0xFFA6B1C2),
                        ),
                      ),
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

  Widget _statusChip(DownloadTask task) {
    final color = switch (task.status) {
      DownloadStatus.completed => const Color(0xFF2FA985),
      DownloadStatus.downloading => Fx.accent,
      DownloadStatus.queued => const Color(0xFF7C8AA0),
      DownloadStatus.paused => const Color(0xFFD68A00),
      DownloadStatus.failed => const Color(0xFFE45C5C),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .11),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        task.statusLabel,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _action({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: .16)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

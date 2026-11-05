import 'package:flutter/material.dart';

import '../services/download_service.dart';
import '../theme.dart';
import 'category_page.dart';
import 'offline_player_page.dart';

/* ========================================================================== */
/*  整部剧的缓存详情：集数列表 / 补下 / 单集删除                               */
/* ========================================================================== */

class DownloadSeriesPage extends StatefulWidget {
  const DownloadSeriesPage({super.key, required this.seriesId});

  final String seriesId;

  @override
  State<DownloadSeriesPage> createState() => _DownloadSeriesPageState();
}

class _DownloadSeriesPageState extends State<DownloadSeriesPage> {
  final DownloadService _service = DownloadService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onChanged);
  }

  @override
  void dispose() {
    _service.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  List<DownloadTask> get _tasks =>
      _service.tasksForSeries(widget.seriesId);

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

  Future<void> _enqueueEpisodes(List<int> episodes) async {
    if (episodes.isEmpty) {
      _toast('全部集数已在缓存队列中');
      return;
    }
    final tasks = _tasks;
    if (tasks.isEmpty) return;
    final block = await _service.networkBlockReason();
    if (!mounted) return;
    if (block != null) {
      _toast(block);
      return;
    }
    final sample = tasks.first;
    final total = _service.seriesTotalEpisodes(widget.seriesId);
    final requests = <DownloadRequest>[
      for (final n in episodes)
        DownloadRequest(
          id: sample.id,
          title: sample.title,
          cover: sample.cover,
          ep: n,
          epName: '第 $n 集',
          line: sample.line,
          lineName: sample.lineName,
          year: sample.year,
          isMovie: sample.isMovie,
          totalEpisodes: total,
        ),
    ];
    final added = await _service.enqueue(requests);
    if (!mounted) return;
    _toast(added > 0 ? '已加入 $added 集，按顺序排队下载' : '这些集已经在队列中');
  }

  Future<void> _downloadMissing() =>
      _enqueueEpisodes(_service.seriesMissingEpisodes(widget.seriesId));

  Future<void> _downloadOne(int ep) => _enqueueEpisodes(<int>[ep]);

  Future<void> _pauseResumeOne(DownloadTask task) async {
    if (task.status == DownloadStatus.downloading ||
        task.status == DownloadStatus.queued) {
      await _service.pause(task);
    } else {
      await _service.resume(task);
    }
  }

  Future<void> _deleteTask(DownloadTask task) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text('删除「${task.epLabel}」缓存？',
            style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
        content: const Text('本地缓存文件会一并删除，不影响其它集。',
            style: TextStyle(fontSize: 12.5, height: 1.5, color: Fx.sub)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Fx.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('删除', style: TextStyle(color: Color(0xFFE45C5C))),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _service.remove(task);
    if (!mounted) return;
    if (_tasks.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    _toast('已删除「${task.epLabel}」');
  }

  Future<void> _deleteSeries() async {
    final tasks = _tasks;
    if (tasks.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text('删除「${tasks.first.title}」整部缓存？',
            style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
        content: Text('将删除全部 ${tasks.length} 集的本地文件与任务记录。',
            style: const TextStyle(fontSize: 12.5, height: 1.5, color: Fx.sub)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Fx.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除整剧',
                style: TextStyle(color: Color(0xFFE45C5C))),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _service.removeSeries(widget.seriesId);
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _tasks;
    if (tasks.isEmpty) {
      return const FxPageScaffold(
        title: '剧集缓存',
        child: FxEmptyView(
          icon: Icons.download_rounded,
          title: '缓存已清空',
          subtitle: '这部剧的缓存任务已全部删除',
        ),
      );
    }
    final total = _service.seriesTotalEpisodes(widget.seriesId);
    final missing = _service.seriesMissingEpisodes(widget.seriesId).length;
    return FxPageScaffold(
      title: tasks.first.title,
      actions: [
        FxTextAction(
          '补下',
          icon: Icons.playlist_add_rounded,
          onTap: missing > 0 ? _downloadMissing : null,
        ),
      ],
      child: Column(
        children: [
          _header(tasks, total),
          Expanded(
            child: ListView.builder(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(18, 2, 18, 30),
              itemCount: total,
              itemBuilder: (ctx, i) => _episodeRow(i + 1),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(List<DownloadTask> tasks, int total) {
    final sample = tasks.first;
    final cached = _service.seriesCachedCount(widget.seriesId);
    final bytes = _service.seriesCachedBytes(widget.seriesId);
    final progress = _service.seriesProgress(widget.seriesId);
    final status = _service.seriesStatus(widget.seriesId);
    final active = status == DownloadStatus.downloading ||
        status == DownloadStatus.queued;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 8),
      child: GlassCard(
        padding: const EdgeInsets.all(11),
        radius: 18,
        opacity: .6,
        child: Column(
          children: [
            Row(
              children: [
                SizedBox(
                  width: 52,
                  height: 76,
                  child: FxCover(
                    url: sample.cover,
                    title: sample.title,
                    radius: 9,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sample.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Fx.ink,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '已缓存 $cached/$total 集 · ${fxBytes(bytes)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10, color: Fx.sub),
                      ),
                      const SizedBox(height: 7),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 4,
                          backgroundColor: const Color(0xFFE8EDF5),
                          valueColor: const AlwaysStoppedAnimation<Color>(
                              Fx.accent),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '已完成 ${(progress * 100).round()}%',
                        style: const TextStyle(fontSize: 9, color: Fx.sub),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 9),
            Row(
              children: [
                Expanded(
                  child: _pill(
                    icon: active
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    label: active ? '暂停整部' : '继续整部',
                    color: active ? const Color(0xFFD68A00) : Fx.accent,
                    onTap: active
                        ? () => _service.pauseSeries(widget.seriesId)
                        : () => _service.resumeSeries(widget.seriesId),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: _pill(
                    icon: Icons.playlist_add_rounded,
                    label: '继续补下',
                    color: Fx.accent,
                    onTap: _downloadMissing,
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: _pill(
                    icon: Icons.delete_outline_rounded,
                    label: '删除整剧',
                    color: const Color(0xFFE45C5C),
                    onTap: _deleteSeries,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _pill({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: color.withValues(alpha: .16)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _episodeRow(int ep) {
    final task = _service.taskFor(widget.seriesId, ep);
    final status = task?.status;
    final cached = status == DownloadStatus.completed;
    final busy =
        status == DownloadStatus.downloading || status == DownloadStatus.queued;
    final failed = status == DownloadStatus.failed;

    final statusText = switch (status) {
      null => '未缓存',
      DownloadStatus.completed => '已缓存 · ${task!.sizeLabel}',
      DownloadStatus.downloading =>
        '下载中 ${(task!.progressValue * 100).round()}% · ${task.progressDetail}',
      DownloadStatus.queued => '排队中',
      DownloadStatus.paused =>
        '已暂停 ${(task!.progressValue * 100).round()}%',
      DownloadStatus.failed => task!.error ?? '下载失败',
    };
    final color = switch (status) {
      null => Fx.sub,
      DownloadStatus.completed => const Color(0xFF2FA985),
      DownloadStatus.downloading => Fx.accent,
      DownloadStatus.queued => const Color(0xFF7C8AA0),
      DownloadStatus.paused => const Color(0xFFD68A00),
      DownloadStatus.failed => const Color(0xFFE45C5C),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        radius: 13,
        opacity: .5,
        onTap: () {
          if (task == null) {
            _downloadOne(ep);
          } else if (cached) {
            _play(task);
          } else if (busy || status == DownloadStatus.paused) {
            _pauseResumeOne(task);
          } else if (failed) {
            _service.resume(task);
          }
        },
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .10),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(
                '$ep',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task?.epLabel ?? '第 $ep 集',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Fx.ink,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    statusText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 9, color: color),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            if (task == null)
              Icon(Icons.download_rounded, size: 17, color: color)
            else if (cached)
              Icon(Icons.play_circle_outline_rounded, size: 19, color: color)
            else
              Icon(
                busy
                    ? Icons.pause_circle_outline_rounded
                    : status == DownloadStatus.paused
                        ? Icons.play_circle_outline_rounded
                        : Icons.refresh_rounded,
                size: 19,
                color: color,
              ),
            if (task != null) ...[
              const SizedBox(width: 6),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _deleteTask(task),
                child: const Padding(
                  padding: EdgeInsets.all(3),
                  child: Icon(Icons.delete_outline_rounded,
                      size: 17, color: Color(0xFFE45C5C)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

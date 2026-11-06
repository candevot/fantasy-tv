import 'package:flutter/material.dart';

import '../services/download_service.dart';
import '../theme.dart';
import 'category_page.dart';
import 'offline_player_page.dart';

/* ========================================================================== */
/*  整部剧的「离线详情」：标题 + 分组集数列表（全程不联网）                    */
/*  已缓存在上（带播放键）→ 下载中（进度/暂停）→ 未缓存（下载键）              */
/* ========================================================================== */

class DownloadSeriesPage extends StatefulWidget {
  const DownloadSeriesPage({
    super.key,
    required this.seriesId,
    this.cachedOnly = false,
  });

  final String seriesId;

  /// 「已下载」Tab 进来的只读视图：**只列已缓存的集**（下载几集显示几集），
  /// 未缓存 / 下载中的分区先不列；顶部保留「继续补下」，点了才展开补下流程。
  final bool cachedOnly;

  @override
  State<DownloadSeriesPage> createState() => _DownloadSeriesPageState();
}

class _DownloadSeriesPageState extends State<DownloadSeriesPage> {
  final DownloadService _service = DownloadService.instance;

  /// 点过「继续补下」后展开完整集数列表（已缓存 / 下载中 / 未缓存）。
  bool _supplementing = false;

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

  List<DownloadTask> get _tasks => _service.tasksForSeries(widget.seriesId);

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
      _enqueueEpisodes(_missingEpisodes());

  /// 「继续补下」入口（顶栏按钮 + 头部卡片都走这里）：
  /// 只列已缓存的视图先展开完整集数列表，再把没缓存的集排队下载。
  Future<void> _startSupplement() async {
    if (widget.cachedOnly && !_supplementing && mounted) {
      setState(() => _supplementing = true);
    }
    await _downloadMissing();
  }

  Future<void> _downloadOne(int ep) => _enqueueEpisodes(<int>[ep]);

  Future<void> _pauseResumeOne(DownloadTask task) async {
    if (task.status == DownloadStatus.downloading ||
        task.status == DownloadStatus.queued) {
      await _service.pause(task);
    } else {
      await _service.resume(task);
    }
  }

  /// 未缓存且也没排队的集号（1..总集数）。
  List<int> _missingEpisodes() {
    final total = _service.seriesTotalEpisodes(widget.seriesId);
    final busy = <int>{for (final t in _tasks) t.ep};
    return <int>[for (var n = 1; n <= total; n++) if (!busy.contains(n)) n];
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

  /* ------------------------------------------------------------------ UI */

  @override
  Widget build(BuildContext context) {
    final tasks = _tasks;
    if (tasks.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: FxBackground(
          child: SafeArea(
            child: Column(
              children: [
                _appBar('剧集缓存', subtitle: null, showDownloadMissing: false),
                const Expanded(
                  child: FxEmptyView(
                    icon: Icons.download_rounded,
                    title: '缓存已清空',
                    subtitle: '这部剧的缓存任务已全部删除',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final total = _service.seriesTotalEpisodes(widget.seriesId);
    final sorted = List<DownloadTask>.from(tasks)
      ..sort((a, b) => a.ep.compareTo(b.ep));
    final cached =
        sorted.where((t) => t.status == DownloadStatus.completed).toList();
    // 只列已缓存的视图：下载中 / 未缓存两段先不列，点「继续补下」后才展开。
    final cachedOnly = widget.cachedOnly && !_supplementing;
    final busy = cachedOnly
        ? const <DownloadTask>[]
        : sorted
            .where((t) => t.status != DownloadStatus.completed)
            .toList();
    final missing = _missingEpisodes();
    final listedMissing = cachedOnly ? const <int>[] : missing;
    final bytes = _service.seriesCachedBytes(widget.seriesId);

    final children = <Widget>[];
    if (cached.isNotEmpty) {
      children.add(_sectionHeader(
        title: '已缓存',
        count: cached.length,
        color: const Color(0xFF2FA985),
        hint: '点击即可离线播放',
      ));
      children.addAll(cached.map(_cachedRow));
    }
    if (busy.isNotEmpty) {
      if (children.isNotEmpty) children.add(const SizedBox(height: 12));
      children.add(_sectionHeader(
        title: '下载中',
        count: busy.length,
        color: Fx.accent,
        hint: '显示进度 · 可暂停 / 继续',
      ));
      children.addAll(busy.map(_busyRow));
    }
    if (listedMissing.isNotEmpty) {
      if (children.isNotEmpty) children.add(const SizedBox(height: 12));
      children.add(_sectionHeader(
        title: '未缓存',
        count: listedMissing.length,
        color: Fx.sub,
        hint: '点击下载',
        actionText: '全部下载',
        onAction: () => _enqueueEpisodes(listedMissing),
      ));
      children.addAll(listedMissing.map(_missingRow));
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: FxBackground(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _appBar(
                tasks.first.title,
                subtitle: '已缓存 ${cached.length}/$total 集 · ${fxBytes(bytes)}',
                showDownloadMissing: missing.isNotEmpty,
                downloadLabel: widget.cachedOnly ? '继续补下' : '补下',
              ),
              Expanded(
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(18, 4, 18, 30),
                  children: [
                    _header(tasks, total, cached.length, busy.length),
                    const SizedBox(height: 6),
                    ...children,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 标准 AppBar：返回 + 剧名（集数副标题）+ 右侧「补下」。
  Widget _appBar(
    String title, {
    required String? subtitle,
    required bool showDownloadMissing,
    String downloadLabel = '补下',
  }) {
    return AppBar(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 54,
      leading: IconButton(
        onPressed: () => Navigator.of(context).maybePop(),
        tooltip: '返回',
        icon: const Icon(Icons.arrow_back_ios_new_rounded,
            size: 17, color: Fx.ink),
      ),
      title: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Fx.ink,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 1),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10, color: Fx.sub),
            ),
          ],
        ],
      ),
      centerTitle: true,
      actions: [
        if (showDownloadMissing)
          TextButton(
            onPressed: _startSupplement,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.playlist_add_rounded,
                    size: 16, color: Fx.accent),
                const SizedBox(width: 4),
                Text(
                  downloadLabel,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Fx.accent,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _sectionHeader({
    required String title,
    required int count,
    required Color color,
    required String hint,
    String? actionText,
    VoidCallback? onAction,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 7),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 13,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 7),
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Fx.ink,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
            decoration: BoxDecoration(
              color: color.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$count 集',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 9.5, color: Fx.sub),
            ),
          ),
          if (actionText != null)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onAction,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: Fx.accent.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(10),
                  border:
                      Border.all(color: Fx.accent.withValues(alpha: .22)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.download_rounded,
                        size: 12, color: Fx.accent),
                    const SizedBox(width: 3),
                    Text(
                      actionText,
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: Fx.accent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _header(
    List<DownloadTask> tasks,
    int total,
    int cachedCount,
    int busyCount,
  ) {
    final sample = tasks.first;
    final bytes = _service.seriesCachedBytes(widget.seriesId);
    final progress = _service.seriesProgress(widget.seriesId);
    final status = _service.seriesStatus(widget.seriesId);
    final active = status == DownloadStatus.downloading ||
        status == DownloadStatus.queued;

    // 进度条下面那行状态：下载中报进度；全缓存才说「已全部缓存」，
    // 只缓存了一部分时如实报 X/Y（1/27 不再谎称已全部缓存）。
    final String? caption = busyCount > 0
        ? '下载中 $busyCount 集 · 已完成 ${(progress * 100).round()}%'
        : cachedCount >= total
            ? null
            : '还有 ${total - cachedCount} 集未缓存 · 点「继续补下」补齐';

    return GlassCard(
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
                      cachedCount >= total
                          ? '已全部缓存 · ${fxBytes(bytes)}'
                          : '已缓存 $cachedCount/$total 集 · ${fxBytes(bytes)}',
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
                    if (caption != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 9, color: Fx.sub),
                      ),
                    ],
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
                  label: active ? '暂停整部' : (busyCount > 0 ? '继续整部' : '播放'),
                  color: active ? const Color(0xFFD68A00) : Fx.accent,
                  onTap: active
                      ? () => _service.pauseSeries(widget.seriesId)
                      : () {
                          final done = tasks
                              .where((t) =>
                                  t.status == DownloadStatus.completed)
                              .toList()
                            ..sort((a, b) => a.ep.compareTo(b.ep));
                          if (done.isNotEmpty) {
                            _play(done.first);
                          } else {
                            _service.resumeSeries(widget.seriesId);
                          }
                        },
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: _pill(
                  icon: Icons.playlist_add_rounded,
                  label: '继续补下',
                  color: Fx.accent,
                  onTap: _startSupplement,
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

  /* ------------------------------------------------------------ 三种行 */

  /// 已缓存：右侧是播放键（点整行也播放）。
  Widget _cachedRow(DownloadTask task) {
    return _epCard(
      ep: task.ep,
      color: const Color(0xFF2FA985),
      title: task.epLabel,
      subtitle: '已缓存 · ${task.sizeLabel}',
      progress: 1,
      progressColor: const Color(0xFF2FA985),
      onTap: () => _play(task),
      trailing: [
        _iconBtn(
          icon: Icons.play_circle_fill_rounded,
          color: const Color(0xFF2FA985),
          tooltip: '播放',
          onTap: () => _play(task),
        ),
        _iconBtn(
          icon: Icons.delete_outline_rounded,
          color: const Color(0xFFE45C5C),
          tooltip: '删除',
          onTap: () => _deleteTask(task),
        ),
      ],
    );
  }

  /// 下载中 / 排队 / 暂停 / 失败：进度 + 片数速度 + 暂停 / 继续。
  Widget _busyRow(DownloadTask task) {
    final status = task.status;
    final color = switch (status) {
      DownloadStatus.downloading => Fx.accent,
      DownloadStatus.queued => const Color(0xFF7C8AA0),
      DownloadStatus.paused => const Color(0xFFD68A00),
      DownloadStatus.failed => const Color(0xFFE45C5C),
      DownloadStatus.completed => const Color(0xFF2FA985),
    };
    final busy =
        status == DownloadStatus.downloading || status == DownloadStatus.queued;
    final subtitle = switch (status) {
      DownloadStatus.downloading =>
        '下载中 ${(task.progressValue * 100).round()}% · ${task.progressDetail}',
      DownloadStatus.queued => '排队中 · 等待前一集完成',
      DownloadStatus.paused =>
        '已暂停 ${(task.progressValue * 100).round()}% · ${task.sizeLabel}',
      DownloadStatus.failed => task.error ?? '下载失败 · 点击重试',
      DownloadStatus.completed => task.sizeLabel,
    };
    final known = task.totalSegments > 0 || task.totalBytes > 0;
    return _epCard(
      ep: task.ep,
      color: color,
      title: task.epLabel,
      subtitle: subtitle,
      progress: known ? task.progressValue : null,
      progressColor: color,
      indeterminate: busy && !known,
      onTap: () => _pauseResumeOne(task),
      trailing: [
        _iconBtn(
          icon: busy
              ? Icons.pause_circle_outline_rounded
              : Icons.play_circle_outline_rounded,
          color: color,
          tooltip: busy ? '暂停' : '继续',
          onTap: () => _pauseResumeOne(task),
        ),
        _iconBtn(
          icon: Icons.delete_outline_rounded,
          color: const Color(0xFFE45C5C),
          tooltip: '删除',
          onTap: () => _deleteTask(task),
        ),
      ],
    );
  }

  /// 未缓存：右侧是下载键。
  Widget _missingRow(int ep) {
    return _epCard(
      ep: ep,
      color: Fx.sub,
      title: '第 $ep 集',
      subtitle: '未缓存 · 点击下载',
      progress: null,
      onTap: () => _downloadOne(ep),
      trailing: [
        _iconBtn(
          icon: Icons.download_rounded,
          color: Fx.accent,
          tooltip: '下载',
          onTap: () => _downloadOne(ep),
        ),
      ],
    );
  }

  Widget _epCard({
    required int ep,
    required Color color,
    required String title,
    required String subtitle,
    required double? progress,
    Color? progressColor,
    bool indeterminate = false,
    required List<Widget> trailing,
    VoidCallback? onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        radius: 13,
        opacity: .5,
        onTap: onTap,
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
                    title,
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
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 9, color: color),
                  ),
                  if (progress != null || indeterminate) ...[
                    const SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: indeterminate ? null : progress,
                        minHeight: 3,
                        backgroundColor: const Color(0xFFE8EDF5),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          progressColor ?? Fx.accent,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 6),
            ...trailing,
          ],
        ),
      ),
    );
  }

  Widget _iconBtn({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    String? tooltip,
  }) {
    final btn = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, size: 20, color: color),
      ),
    );
    if (tooltip == null) return btn;
    return Tooltip(message: tooltip, child: btn);
  }
}

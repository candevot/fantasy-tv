import 'package:flutter/material.dart';

import '../services/download_service.dart';
import '../theme.dart';
import 'category_page.dart';
import 'download_series_page.dart';
import 'offline_player_page.dart';
import '../utils/fx_route.dart';

/* ========================================================================== */
/*  离线缓存：标准 AppBar + 「下载中 / 已下载」两个分区                        */
/* ========================================================================== */

/// 同一部剧的缓存任务聚合。下载页按剧展示一行，点进去再看具体集数。
class _SeriesGroup {
  _SeriesGroup(this.id, this.tasks);

  final String id;
  final List<DownloadTask> tasks;

  DownloadTask get sample => tasks.first;

  int get updatedAt =>
      tasks.fold(0, (max, t) => t.updatedAt > max ? t.updatedAt : max);

  /// 只要有任意一集没下载完，整部剧就留在「下载中」；
  /// 全部完成后下次刷新自动落到「已下载」。
  bool get finished =>
      tasks.isNotEmpty && tasks.every((t) => t.status == DownloadStatus.completed);
}

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage>
    with SingleTickerProviderStateMixin {
  final DownloadService _service = DownloadService.instance;
  late final TabController _tab = TabController(length: 2, vsync: this);
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
    _tab.dispose();
    super.dispose();
  }

  /// 按剧聚合，按最近一次下载排序。
  List<_SeriesGroup> get _groups {
    final map = <String, List<DownloadTask>>{};
    for (final task in _service.tasks) {
      map.putIfAbsent(task.id, () => <DownloadTask>[]).add(task);
    }
    final groups = <_SeriesGroup>[
      for (final entry in map.entries) _SeriesGroup(entry.key, entry.value),
    ];
    groups.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return groups;
  }

  /// 「下载中」：还有集没下完（下载 / 排队 / 暂停 / 失败）。
  List<_SeriesGroup> get _activeGroups =>
      _groups.where((g) => !g.finished).toList(growable: false);

  /// 「已下载」：这部剧的每一集都已完成。
  List<_SeriesGroup> get _finishedGroups =>
      _groups.where((g) => g.finished).toList(growable: false);

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

  Future<void> _deleteSeries(_SeriesGroup group) async {
    final count = group.tasks.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text(
          count > 1
              ? '删除「${group.sample.title}」整部缓存？'
              : '删除「${group.sample.epLabel}」缓存？',
          style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700),
        ),
        content: Text(
          count > 1
              ? '将删除全部 $count 集的本地文件与任务记录，不影响其它剧集。'
              : '本地缓存文件会一并删除。',
          style: const TextStyle(fontSize: 12.5, height: 1.5, color: Fx.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Fx.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(count > 1 ? '删除整剧' : '删除',
                style: const TextStyle(color: Color(0xFFE45C5C))),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final removed = await _service.removeSeries(group.id);
    if (!mounted) return;
    _toast(count > 1
        ? '已删除「${group.sample.title}」$removed 集缓存'
        : '已删除「${group.sample.epLabel}」');
  }

  Future<void> _play(DownloadTask task) async {
    final file = await _service.fileFor(task);
    if (!mounted) return;
    if (file == null) {
      _toast('缓存文件不存在，请删除后重新下载');
      return;
    }
    await Navigator.of(context).push(
      FxPageRoute(
        builder: (_) => OfflinePlayerPage(task: task, file: file),
      ),
    );
  }

  /// 点剧卡片：一律进「离线详情」（标题 + 集列表），不跳在线详情、不联网。
  ///
  /// [cachedOnly] 给「已下载」Tab 用：进去只列已缓存的集，未缓存的不列，
  /// 想补齐时点顶部「继续补下」。
  Future<void> _openSeries(_SeriesGroup group, {bool cachedOnly = false}) async {
    await Navigator.of(context).push(
      FxPageRoute(
        builder: (_) => DownloadSeriesPage(
          seriesId: group.id,
          cachedOnly: cachedOnly,
        ),
      ),
    );
  }

  /// 已缓存的整部剧：播放集号最小的一集，其余可从「集数」里选。
  Future<void> _playFirstCompleted(
    _SeriesGroup group, {
    bool cachedOnly = false,
  }) async {
    final done = group.tasks
        .where((t) => t.status == DownloadStatus.completed)
        .toList()
      ..sort((a, b) => a.ep.compareTo(b.ep));
    if (done.isEmpty) {
      await _openSeries(group, cachedOnly: cachedOnly);
      return;
    }
    await _play(done.first);
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

  /* ------------------------------------------------------------------ UI */

  @override
  Widget build(BuildContext context) {
    final active = _activeGroups.length;
    final finished = _finishedGroups.length;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: FxBackground(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _appBar(),
              _tabBar(active, finished),
              Expanded(
                child: TabBarView(
                  controller: _tab,
                  children: [
                    _tabBody(_activeGroups, downloadingTab: true),
                    _tabBody(_finishedGroups, downloadingTab: false),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 标准 AppBar：返回 + 居中「离线缓存」+ 右侧「清空」。
  /// 用真正的 AppBar 排版，标题与右侧按钮各自占位，不会再叠字。
  Widget _appBar() {
    final canClear = !_loading && _service.tasks.isNotEmpty;
    return AppBar(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 52,
      leading: IconButton(
        onPressed: () => Navigator.of(context).maybePop(),
        tooltip: '返回',
        icon: const Icon(Icons.arrow_back_ios_new_rounded,
            size: 17, color: Fx.ink),
      ),
      title: const Text(
        '离线缓存',
        style: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: Fx.ink,
        ),
      ),
      centerTitle: true,
      actions: [
        TextButton(
          onPressed: canClear ? _confirmClear : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.delete_sweep_rounded,
                size: 16,
                color: canClear ? Fx.sub : const Color(0xFFB6C0CD),
              ),
              const SizedBox(width: 4),
              Text(
                '清空',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: canClear ? Fx.sub : const Color(0xFFB6C0CD),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _tabBar(int active, int finished) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0x1450729F), width: 1),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: TabBar(
          controller: _tab,
          indicatorSize: TabBarIndicatorSize.tab,
          indicator: BoxDecoration(
            color: Colors.white.withValues(alpha: .88),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF50729F).withValues(alpha: .12),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          indicatorPadding: const EdgeInsets.fromLTRB(4, 7, 4, 7),
          dividerColor: Colors.transparent,
          labelColor: Fx.ink,
          unselectedLabelColor: Fx.sub,
          labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          unselectedLabelStyle:
              const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          splashFactory: NoSplash.splashFactory,
          tabs: [
            Tab(child: _tabLabel('下载中', active, const Color(0xFFD68A00))),
            Tab(child: _tabLabel('已下载', finished, const Color(0xFF2FA985))),
          ],
        ),
      ),
    );
  }

  Widget _tabLabel(String text, int count, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text),
        const SizedBox(width: 5),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .14),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
      ],
    );
  }

  Widget _tabBody(List<_SeriesGroup> groups, {required bool downloadingTab}) {
    if (_loading) return const FxLoadingView(label: '正在读取缓存…');
    if (groups.isEmpty) {
      return FxEmptyView(
        icon: downloadingTab
            ? Icons.download_rounded
            : Icons.offline_pin_rounded,
        title: downloadingTab ? '没有正在下载的任务' : '还没有已下载的剧集',
        subtitle: downloadingTab
            ? (_service.tasks.isEmpty
                ? '在详情页点击「下载」并选择剧集，任务会出现在这里'
                : '所有任务都下载完了，切换到「已下载」看看')
            : '下载完成后会自动出现在这里，可离线播放',
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
          child: Row(
            children: [
              if (downloadingTab) ...[
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
              ] else
                const Spacer(),
              Flexible(
                child: Text(
                  downloadingTab
                      ? '${groups.length} 部 · ${_service.activeTasks.length} 个任务'
                      : '${groups.length} 部 · ${fxBytes(_service.totalCachedBytes)}',
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
            itemCount: groups.length,
            itemBuilder: (ctx, i) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _seriesCard(groups[i], downloadingTab: downloadingTab),
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

  Widget _seriesCard(_SeriesGroup group, {required bool downloadingTab}) {
    final id = group.id;
    final status = _service.seriesStatus(id);
    final total = _service.seriesTotalEpisodes(id);
    final cached = _service.seriesCachedCount(id);
    final bytes = _service.seriesCachedBytes(id);
    final progress = _service.seriesProgress(id);
    final current = _service.seriesCurrentTask(id);
    final failedCount =
        group.tasks.where((t) => t.status == DownloadStatus.failed).length;
    // 「全部完成」只看集数：只缓存了 1/27 集不算完成（不打勾、不写「已全部缓存」）。
    final completed = cached >= total;
    final paused = status == DownloadStatus.paused;
    final failed = status == DownloadStatus.failed;
    final downloading = status == DownloadStatus.downloading;
    final queued = status == DownloadStatus.queued;
    final active = downloading || queued;

    final String detail;
    if (downloadingTab) {
      if (active) {
        detail =
            '第 ${current?.ep ?? cached}/$total 集 · ${current?.progressDetail ?? ''}';
      } else if (paused) {
        detail = '已暂停 · 已完成 ${(progress * 100).round()}% · $cached/$total 集';
      } else if (failed) {
        detail = '$failedCount 集下载失败 · 点击继续重试';
      } else {
        detail = '已缓存 $cached/$total 集';
      }
    } else {
      detail = completed
          ? '已全部缓存 · ${fxBytes(bytes)}'
          : '已缓存 $cached/$total 集 · ${fxBytes(bytes)}';
    }

    return GlassCard(
      padding: const EdgeInsets.all(10),
      radius: 18,
      opacity: .62,
      onTap: () => _openSeries(group, cachedOnly: !downloadingTab),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            height: 108,
            child: Stack(
              fit: StackFit.expand,
              children: [
                FxCover(
                  url: group.sample.cover,
                  title: group.sample.title,
                  radius: 11,
                ),
                Positioned(
                  left: 5,
                  right: 5,
                  bottom: 5,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .36),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      '$cached/$total',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 8, color: Colors.white),
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
                    group.sample.title,
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
                      _statusChip(status),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          group.sample.isMovie
                              ? '已缓存 · ${fxBytes(bytes)}'
                              : '已缓存 $cached/$total 集 · ${fxBytes(bytes)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              const TextStyle(fontSize: 9.5, color: Fx.sub),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 3.5,
                      backgroundColor: const Color(0xFFE8EDF5),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        completed
                            ? const Color(0xFF5BC8A8)
                            : paused
                                ? Fx.gold
                                : failed
                                    ? const Color(0xFFE45C5C)
                                    : Fx.accent,
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9,
                      color: failed
                          ? const Color(0xFFE45C5C)
                          : completed
                              ? const Color(0xFF2FA985)
                              : Fx.sub,
                    ),
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      if (downloadingTab && active)
                        _action(
                          icon: Icons.pause_rounded,
                          label: '暂停',
                          color: const Color(0xFFD68A00),
                          onTap: () => _service.pauseSeries(id),
                        )
                      else if (downloadingTab && (paused || failed))
                        _action(
                          icon: Icons.play_arrow_rounded,
                          label: '继续',
                          color: Fx.accent,
                          onTap: () => _service.resumeSeries(id),
                        )
                      else
                        _action(
                          icon: Icons.play_arrow_rounded,
                          label: '播放',
                          color: Fx.accent,
                          onTap: () => _playFirstCompleted(
                            group,
                            cachedOnly: !downloadingTab,
                          ),
                        ),
                      const SizedBox(width: 6),
                      _action(
                        icon: Icons.format_list_bulleted_rounded,
                        label: '集数',
                        color: Fx.sub,
                        onTap: () => _openSeries(
                          group,
                          cachedOnly: !downloadingTab,
                        ),
                      ),
                      const SizedBox(width: 6),
                      _action(
                        icon: Icons.delete_outline_rounded,
                        label: '删除',
                        color: const Color(0xFFE45C5C),
                        onTap: () => _deleteSeries(group),
                      ),
                      const Spacer(),
                      Text(
                        fxTimeAgo(group.updatedAt),
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

  Widget _statusChip(DownloadStatus status) {
    final color = switch (status) {
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
        status == DownloadStatus.completed
            ? '已缓存'
            : status == DownloadStatus.queued
                ? '排队中'
                : status.label,
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

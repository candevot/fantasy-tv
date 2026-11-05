import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/download_service.dart';
import '../theme.dart';
import '../widgets/player_theme.dart' show fxTime;
import 'category_page.dart';

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

  Future<void> _play(DownloadTask task) async {
    final path = task.filePath;
    final exists = path != null && await File(path).exists();
    if (!mounted) return;
    if (!exists) {
      _toast('缓存文件不存在，请删除后重新下载');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => OfflinePlayerPage(task: task)),
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
          color: Colors.white.withOpacity(enabled ? .72 : .38),
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
              color: Fx.accent.withOpacity(.10),
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
                      color: Colors.black.withOpacity(.36),
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
        color: color.withOpacity(.11),
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
          color: color.withOpacity(.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(.16)),
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

/* ========================================================================== */
/*  离线播放（本地文件，简化播放器）                                            */
/* ========================================================================== */

class OfflinePlayerPage extends StatefulWidget {
  const OfflinePlayerPage({super.key, required this.task});

  final DownloadTask task;

  @override
  State<OfflinePlayerPage> createState() => _OfflinePlayerPageState();
}

class _OfflinePlayerPageState extends State<OfflinePlayerPage> {
  VideoPlayerController? _controller;
  bool _initializing = true;
  String? _error;

  /// 初始化序号：dispose 后让 await 中的旧任务作废，避免退出后继续播放。
  int _openSeq = 0;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final seq = ++_openSeq;
    final path = widget.task.filePath;
    if (path == null) {
      if (mounted) {
        setState(() {
          _initializing = false;
          _error = '缓存文件路径缺失';
        });
      }
      return;
    }
    VideoPlayerController? controller;
    try {
      final file = File(path);
      if (!await file.exists()) {
        throw const FileSystemException('缓存文件已被清理');
      }
      if (!mounted || seq != _openSeq) return;
      controller = VideoPlayerController.file(file);
      await controller.initialize();
      if (!mounted || seq != _openSeq) {
        await controller.dispose();
        return;
      }
      await controller.setLooping(false);
      if (!mounted || seq != _openSeq) {
        await controller.dispose();
        return;
      }
      controller.addListener(_onTick);
      await controller.play();
      if (!mounted || seq != _openSeq) {
        controller.removeListener(_onTick);
        await controller.dispose();
        return;
      }
      _controller = controller;
      controller = null;
      setState(() {
        _initializing = false;
        _error = null;
      });
    } catch (e) {
      if (controller != null) {
        controller.removeListener(_onTick);
        try {
          await controller.dispose();
        } catch (_) {}
      }
      if (!mounted || seq != _openSeq) return;
      setState(() {
        _initializing = false;
        _error = '离线播放失败：${_short(e)}';
      });
    }
  }

  String _short(Object e) {
    final s = '$e';
    return s.length > 90 ? '${s.substring(0, 90)}…' : s;
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _openSeq++;
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(child: _video()),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(8, 6, 12, 18),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xB3000000), Color(0x00000000)],
                  ),
                ),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back_ios_new_rounded,
                          size: 19, color: Colors.white),
                    ),
                    const SizedBox(width: 2),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.task.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(.16),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: const Text(
                                  '离线缓存',
                                  style: TextStyle(
                                      fontSize: 8.5, color: Colors.white70),
                                ),
                              ),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  widget.task.epLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 10, color: Colors.white70),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (!_initializing && _error == null && _controller != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _controls(_controller!),
              ),
          ],
        ),
      ),
    );
  }

  Widget _video() {
    if (_initializing) {
      return const SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(
          strokeWidth: 2.4,
          color: Colors.white70,
        ),
      );
    }
    final error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded,
                size: 34, color: Colors.white54),
            const SizedBox(height: 12),
            Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 14),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('返回列表', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
    }
    final controller = _controller!;
    final value = controller.value;
    final ratio = value.aspectRatio <= 0 ? 16 / 9 : value.aspectRatio;
    return AspectRatio(
      aspectRatio: ratio,
      child: VideoPlayer(controller),
    );
  }

  Widget _controls(VideoPlayerController controller) {
    final value = controller.value;
    final duration = value.duration.inMilliseconds;
    final position =
        value.position.inMilliseconds.clamp(0, duration > 0 ? duration : 0);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 26, 14, 12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xB3000000)],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: Fx.accent,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
            ),
            child: Slider(
              value: position.toDouble(),
              max: duration > 0 ? duration.toDouble() : 1,
              onChanged: duration > 0
                  ? (v) => controller.seekTo(Duration(milliseconds: v.round()))
                  : null,
            ),
          ),
          Row(
            children: [
              IconButton(
                onPressed: () {
                  if (controller.value.isPlaying) {
                    controller.pause();
                  } else {
                    final position = controller.value.position;
                    final duration = controller.value.duration;
                    if (duration > Duration.zero && position >= duration) {
                      controller.seekTo(Duration.zero);
                    }
                    controller.play();
                  }
                },
                icon: Icon(
                  value.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
              Text(
                '${fxTime(value.position)} / ${fxTime(value.duration)}',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10.5,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              const Icon(Icons.offline_pin_rounded,
                  size: 12, color: Colors.white54),
              const SizedBox(width: 3),
              const Text(
                '本地播放',
                style: TextStyle(fontSize: 9.5, color: Colors.white54),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

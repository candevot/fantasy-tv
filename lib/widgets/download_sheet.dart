import 'package:flutter/material.dart';

import '../models.dart';
import '../services/download_service.dart';
import '../theme.dart';
import 'detail_widgets.dart' show detailEpisodeLabel;

/// 下载选集面板：按当前线路列出全部剧集，可多选后加入离线缓存队列。
///
/// 返回实际加入队列的集数；用户取消时返回 null。
Future<int?> showDownloadSheet(
  BuildContext context, {
  required String videoId,
  required String title,
  required String cover,
  required String lineId,
  required String lineName,
  required List<Episode> episodes,
  int currentEp = 1,
  int year = 0,
  bool isMovie = false,
}) {
  if (episodes.isEmpty) return Future<int?>.value();
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: .32),
    builder: (_) => DownloadSheet(
      videoId: videoId,
      title: title,
      cover: cover,
      lineId: lineId,
      lineName: lineName,
      episodes: episodes,
      currentEp: currentEp,
      year: year,
      isMovie: isMovie,
    ),
  );
}

class DownloadSheet extends StatefulWidget {
  const DownloadSheet({
    super.key,
    required this.videoId,
    required this.title,
    required this.cover,
    required this.lineId,
    required this.lineName,
    required this.episodes,
    required this.currentEp,
    this.year = 0,
    this.isMovie = false,
  });

  final String videoId;
  final String title;
  final String cover;
  final String lineId;
  final String lineName;
  final List<Episode> episodes;
  final int currentEp;
  final int year;
  final bool isMovie;

  @override
  State<DownloadSheet> createState() => _DownloadSheetState();
}

enum _EpState { available, cached, busy, paused, failed }

class _DownloadSheetState extends State<DownloadSheet> {
  final DownloadService _service = DownloadService.instance;
  final Set<int> _selected = <int>{};
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChanged);
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      await _service.init();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _loading = false);
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    if (!mounted) return;
    setState(() {
      _selected.removeWhere(
        (ep) => !_selectable(_stateOf(ep)),
      );
    });
  }

  _EpState _stateOf(int ep) {
    final task = _service.taskFor(widget.videoId, ep);
    if (task == null) return _EpState.available;
    switch (task.status) {
      case DownloadStatus.completed:
        return _EpState.cached;
      case DownloadStatus.queued:
      case DownloadStatus.downloading:
        return _EpState.busy;
      case DownloadStatus.paused:
        return _EpState.paused;
      case DownloadStatus.failed:
        return _EpState.failed;
    }
  }

  bool _selectable(_EpState state) =>
      state == _EpState.available || state == _EpState.failed;

  String _stateLabel(_EpState state) => switch (state) {
        _EpState.cached => '已下载',
        _EpState.busy => '下载中',
        _EpState.paused => '已暂停',
        _EpState.failed => '重试',
        _EpState.available => '',
      };

  List<Episode> get _selectableEpisodes => widget.episodes
      .where((e) => _selectable(_stateOf(e.n)))
      .toList(growable: false);

  void _toggle(int ep) {
    final state = _stateOf(ep);
    if (!_selectable(state)) return;
    setState(() {
      if (!_selected.remove(ep)) _selected.add(ep);
    });
  }

  void _toggleAll() {
    final all = _selectableEpisodes;
    final allSelected =
        all.isNotEmpty && all.every((e) => _selected.contains(e.n));
    setState(() {
      if (allSelected) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(all.map((e) => e.n));
      }
    });
  }

  Future<void> _confirm() async {
    if (_selected.isEmpty || _saving) return;
    final block = await _service.networkBlockReason();
    if (!mounted) return;
    if (block != null) {
      _toast(block);
      return;
    }
    final picked = widget.episodes
        .where((e) => _selected.contains(e.n) && _selectable(_stateOf(e.n)))
        .toList(growable: false);
    if (picked.isEmpty) return;
    setState(() => _saving = true);
    final requests = <DownloadRequest>[
      for (final e in picked)
        DownloadRequest(
          id: widget.videoId,
          title: widget.title,
          cover: widget.cover,
          ep: e.n,
          epName: detailEpisodeLabel(e),
          line: widget.lineId,
          lineName: widget.lineName,
          year: widget.year,
          isMovie: widget.isMovie,
        ),
    ];
    final added = await _service.enqueue(requests);
    if (!mounted) return;
    Navigator.of(context).pop(added);
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xEE1B2430),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final all = _selectableEpisodes;
    final allSelected =
        all.isNotEmpty && all.every((e) => _selected.contains(e.n));

    return Container(
      height: screenHeight * .76,
      decoration: const BoxDecoration(
        color: Color(0xFFF7FAFF),
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 9),
          Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFE3E9F3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 10, 6),
            child: Row(
              children: [
                const Icon(Icons.download_rounded, size: 19, color: Fx.accent),
                const SizedBox(width: 7),
                const Text(
                  '下载选集',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: Fx.ink,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '共 ${widget.episodes.length} 集',
                  style: const TextStyle(fontSize: 11, color: Fx.sub),
                ),
                const Spacer(),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).maybePop(),
                  child: Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .85),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white),
                    ),
                    child: const Icon(Icons.close_rounded,
                        size: 18, color: Fx.sub),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
            child: Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Fx.accent.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Fx.accent.withValues(alpha: .14)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.dns_rounded, size: 11, color: Fx.accent),
                      const SizedBox(width: 4),
                      Text(
                        widget.lineName.trim().isEmpty
                            ? '默认线路'
                            : widget.lineName.trim(),
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Fx.accent,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '已下载的集不可重复选择',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: Fx.sub),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Fx.accent,
                      ),
                    ),
                  )
                : GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                    physics: const BouncingScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1.9,
                    ),
                    itemCount: widget.episodes.length,
                    itemBuilder: (context, i) {
                      final ep = widget.episodes[i];
                      return _tile(ep);
                    },
                  ),
          ),
          Container(
            padding: EdgeInsets.fromLTRB(18, 10, 18, 10 + bottomInset),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              boxShadow: [
                BoxShadow(
                  color: Color(0x140B2B55),
                  blurRadius: 18,
                  offset: Offset(0, -4),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Row(
                  children: [
                    Icon(Icons.info_outline_rounded, size: 12, color: Fx.sub),
                    SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '仅缓存已获授权的公开片源；文件保存到设置中的下载目录（默认 手机存储/Download/幻想影视），可在「设置 → 下载与缓存」查看和清理。',
                        maxLines: 2,
                        style: TextStyle(
                          fontSize: 9.5,
                          height: 1.4,
                          color: Fx.sub,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: all.isEmpty ? null : _toggleAll,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .86),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE4EAF4)),
                        ),
                        child: Text(
                          allSelected ? '取消全选' : '全选',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: all.isEmpty ? Fx.sub : Fx.ink,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _selected.isEmpty
                            ? '未选择剧集'
                            : '已选 ${_selected.length} 集',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Fx.sub,
                        ),
                      ),
                    ),
                    Opacity(
                      opacity: _selected.isEmpty || _saving ? .45 : 1,
                      child: IgnorePointer(
                        ignoring: _selected.isEmpty || _saving,
                        child: GradButton(
                          text: _saving
                              ? '加入中…'
                              : '加入缓存${_selected.isEmpty ? '' : '（${_selected.length}）'}',
                          height: 40,
                          icon: Icons.download_done_rounded,
                          onTap: _confirm,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(Episode ep) {
    final state = _stateOf(ep.n);
    final selected = _selected.contains(ep.n);
    final enabled = _selectable(state);
    final isCurrent = ep.n == widget.currentEp;
    final color = selected
        ? Colors.white
        : switch (state) {
            _EpState.cached => const Color(0xFF2FA985),
            _EpState.busy => Fx.accent,
            _EpState.paused => const Color(0xFFD68A00),
            _EpState.failed => const Color(0xFFE45C5C),
            _EpState.available => Fx.ink,
          };
    final bg = switch (state) {
      _EpState.cached => const Color(0xFFF0F4F8),
      _EpState.busy => Fx.accent.withValues(alpha: .10),
      _EpState.paused => Fx.gold.withValues(alpha: .12),
      _EpState.failed => const Color(0xFFE45C5C).withValues(alpha: .08),
      _EpState.available => selected ? null : Colors.white.withValues(alpha: .82),
    };

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? () => _toggle(ep.n) : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          gradient: selected ? Fx.brand : null,
          color: bg,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: selected
                ? Fx.accent
                : isCurrent
                    ? Fx.gold.withValues(alpha: .65)
                    : Colors.white.withValues(alpha: .95),
            width: selected || isCurrent ? 1.2 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: (selected ? Fx.accent : const Color(0xFF50729F))
                  .withValues(alpha: selected ? .22 : .06),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              detailEpisodeLabel(ep),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                fontWeight: enabled ? FontWeight.w600 : FontWeight.w500,
                color: enabled ? color : const Color(0xFF8D99AA),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              state == _EpState.available
                  ? (isCurrent ? '当前集' : '可下载')
                  : _stateLabel(state),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 8,
                height: 1.1,
                color: selected
                    ? Colors.white.withValues(alpha: .85)
                    : color.withValues(alpha: .8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

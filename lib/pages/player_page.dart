import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/danmaku_overlay.dart';
import '../widgets/player_theme.dart';
import 'fullscreen_page.dart';

/// 详情页内嵌播放器（16:9），也是独立播放页复用的播放控件。
///
/// 控件布局：
/// 左上 返回 + 片名/集数
/// 右上 投屏 / TV / 设置
/// 右侧中部 弹幕开关 / 弹幕设置
/// 底部 播放暂停 · 当前时间 · 细进度条 · 总时长 · 下一集 · 全屏
/// 3 秒无操作自动隐藏；点画面唤出/隐藏；长按 2x；双击暂停。
class PlayerView extends StatefulWidget {
  const PlayerView({
    super.key,
    required this.videoId,
    required this.ep,
    required this.line,
    this.detail,
    this.onEpChange,
    this.onFullscreen,
    this.onSourceFailed,
    this.onPlaybackStarted,
    this.onChangeLine,
    this.autoPlay = true,
  });

  final String videoId;
  final int ep;
  final String line;
  final VideoDetail? detail;
  final ValueChanged<int>? onEpChange;
  final VoidCallback? onFullscreen;
  final VoidCallback? onSourceFailed;
  final VoidCallback? onPlaybackStarted;
  final VoidCallback? onChangeLine;
  final bool autoPlay;

  @override
  State<PlayerView> createState() => PlayerViewState();
}

class PlayerViewState extends State<PlayerView> with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  PlayInfo? _info;
  List<DanmuItem> _danmaku = const <DanmuItem>[];

  late int _ep;
  late String _line;
  int _loadToken = 0;

  bool _loading = true;
  bool _error = false;
  String _errorText = '';
  bool _sourceFailNotified = false;
  bool _ended = false;

  bool _controls = true;
  Timer? _hideTimer;

  bool _holding2x = false;
  double _rate = 1.0;
  double _rateBeforeHold = 1.0;

  bool _openingFullscreen = false;
  bool _wasPlayingBeforeFullscreen = false;

  int get _episodeCount {
    final d = widget.detail;
    if (d == null) return 0;
    final n = d.allEpisodes.length;
    return n > 0 ? n : d.episodes;
  }

  String get _title {
    final t = widget.detail?.title ?? '';
    return t.isEmpty ? '正在播放' : t;
  }

  String get _epLabel {
    final list = widget.detail?.allEpisodes ?? const <Episode>[];
    for (final e in list) {
      if (e.n == _ep && e.name.isNotEmpty) return e.name;
    }
    return fxEpisodeLabel(_ep);
  }

  @override
  void initState() {
    super.initState();
    _ep = widget.ep;
    _line = widget.line;
    WidgetsBinding.instance.addObserver(this);
    danmakuSettings.addListener(_onDanmakuChanged);
    _bootstrap(seekToSaved: true, saveOld: false);
  }

  @override
  void didUpdateWidget(covariant PlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.ep == _ep && widget.line == _line) return;
    final pos = _controller?.value.position;
    if (pos != null) {
      fxSaveProgress(widget.videoId, _ep, pos.inMilliseconds / 1000.0);
    }
    _ep = widget.ep;
    _line = widget.line;
    Future.microtask(() {
      if (!mounted) return;
      _bootstrap(seekToSaved: true, saveOld: false);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _saveProgress();
      _controller?.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    danmakuSettings.removeListener(_onDanmakuChanged);
    _hideTimer?.cancel();
    _loadToken++;
    _saveProgress();
    _controller?.removeListener(_onVideoValue);
    _controller?.dispose();
    super.dispose();
  }

  void _onDanmakuChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _saveProgress() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final duration = c.value.duration.inMilliseconds;
    var seconds = c.value.position.inMilliseconds / 1000.0;
    if (duration > 0 && c.value.position.inMilliseconds >= duration - 1500) {
      seconds = 0;
    }
    await fxSaveProgress(widget.videoId, _ep, seconds);
  }

  Future<void> _bootstrap({
    required bool seekToSaved,
    bool saveOld = true,
  }) async {
    final token = ++_loadToken;
    _hideTimer?.cancel();
    if (saveOld) await _saveProgress();
    if (!mounted || token != _loadToken) return;
    _controller?.pause();
    setState(() {
      _loading = true;
      _error = false;
      _errorText = '';
      _sourceFailNotified = false;
      _ended = false;
    });

    PlayInfo info;
    try {
      info = await Api.play(widget.videoId, _ep, _line);
    } catch (_) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        _error = true;
        _errorText = '获取播放地址失败，请检查网络后重试';
      });
      _notifySourceFailed();
      return;
    }
    if (!mounted || token != _loadToken) return;
    _info = info;

    final all = <String>[
      if (info.url.trim().isNotEmpty) info.url.trim(),
      for (final u in info.backup)
        if (u.trim().isNotEmpty) u.trim(),
    ];
    final candidates = <String>[];
    for (final u in all) {
      if (!candidates.contains(u)) candidates.add(u);
    }
    if (candidates.isEmpty) {
      setState(() {
        _loading = false;
        _error = true;
        _errorText = '当前线路没有可用播放地址，请更换线路';
      });
      _notifySourceFailed();
      return;
    }

    final saved = seekToSaved ? await fxLoadProgress(widget.videoId, _ep) : 0.0;
    if (!mounted || token != _loadToken) return;

    var ok = false;
    for (final url in candidates) {
      if (!mounted || token != _loadToken) return;
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders:
            info.headers.isEmpty ? const <String, String>{} : info.headers,
      );
      try {
        await controller.initialize();
        if (!mounted || token != _loadToken) {
          await controller.dispose();
          return;
        }
        controller.addListener(_onVideoValue);
        await controller.setLooping(false);
        if (_rate != 1.0) {
          await controller.setPlaybackSpeed(_rate);
        }
        final durationMs = controller.value.duration.inMilliseconds;
        var resume = saved;
        if (durationMs > 0 && resume >= durationMs / 1000.0 - 2) {
          resume = 0;
        }
        if (resume > 0) {
          await controller.seekTo(
            Duration(milliseconds: (resume * 1000).round()),
          );
        }
        _controller?.removeListener(_onVideoValue);
        await _controller?.dispose();
        _controller = controller;
        if (widget.autoPlay) {
          await controller.play();
        }
        if (!mounted || token != _loadToken) return;
        setState(() {
          _loading = false;
          _error = false;
          _errorText = '';
        });
        _sourceFailNotified = false;
        ok = true;
        widget.onPlaybackStarted?.call();
        _showControls();
        break;
      } catch (_) {
        try {
          controller.removeListener(_onVideoValue);
          await controller.dispose();
        } catch (_) {}
      }
    }

    if (!ok) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        _error = true;
        _errorText = '播放失败：线路不可用，请重试或切换下方线路';
      });
      _notifySourceFailed();
      return;
    }

    final danmaku = await loadDanmakuSource(info.danmu);
    if (!mounted || token != _loadToken) return;
    setState(() => _danmaku = danmaku);
  }

  void _notifySourceFailed() {
    if (_sourceFailNotified) return;
    _sourceFailNotified = true;
    widget.onSourceFailed?.call();
  }

  void _onVideoValue() {
    final c = _controller;
    if (c == null || !mounted) return;
    final v = c.value;
    if (v.hasError && !_error) {
      setState(() {
        _error = true;
        _errorText = '播放中断，请重试或切换线路';
      });
      _notifySourceFailed();
      return;
    }
    if (!v.isInitialized) return;
    if (!v.isCompleted) {
      _ended = false;
      return;
    }
    if (_ended) return;
    _ended = true;
    _handleEnded();
  }

  Future<void> _handleEnded() async {
    await fxSaveProgress(widget.videoId, _ep, 0);
    if (!mounted) return;
    final total = _episodeCount;
    if (total == 0 || _ep < total) {
      await _switchEpisode(_ep + 1, auto: true);
    } else {
      setState(() => _controls = true);
      _startHideTimer();
      fxToast(context, '已播放完最后一集');
    }
  }

  Future<void> _switchEpisode(int next, {bool auto = false}) async {
    if (next < 1) return;
    await _saveProgress();
    if (!mounted) return;
    setState(() {
      _ep = next;
      _loading = true;
      _error = false;
      _controls = true;
    });
    widget.onEpChange?.call(next);
    if (auto) fxToast(context, '即将播放 ${fxEpisodeLabel(next)}');
    await _bootstrap(seekToSaved: true, saveOld: false);
  }

  /// 竖屏底部栏的下一集：中间只保留播放/暂停，不再放下一集
  Future<void> _next() async {
    final next = _nextEpNumber();
    if (next == null) {
      fxToast(context, '已经是最后一集了');
      _touch();
      return;
    }
    await _switchEpisode(next);
  }

  int? _nextEpNumber() {
    final list = widget.detail?.allEpisodes ?? const <Episode>[];
    if (list.isNotEmpty) {
      final index = list.indexWhere((e) => e.n == _ep);
      if (index >= 0) {
        if (index + 1 >= list.length) return null;
        return list[index + 1].n;
      }
    }
    final total = _episodeCount;
    if (total > 0 && _ep >= total) return null;
    return _ep + 1;
  }

  /// 详情页「刷新」/错误重试可以调用
  Future<void> reload() async {
    await _saveProgress();
    if (!mounted) return;
    await _bootstrap(seekToSaved: true, saveOld: false);
  }

  // ---------------------------------------------------------------- controls

  void _showControls() {
    if (!mounted) return;
    setState(() => _controls = true);
    _startHideTimer();
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_holding2x || _openingFullscreen) {
        _startHideTimer();
        return;
      }
      if (_loading || _error) return;
      setState(() => _controls = false);
    });
  }

  void _hideControls() {
    _hideTimer?.cancel();
    if (!mounted) return;
    setState(() => _controls = false);
  }

  void _touch() {
    if (_controls) _startHideTimer();
  }

  void _onSurfaceTap() {
    if (_loading || _error) return;
    if (_controls) {
      _hideControls();
    } else {
      _showControls();
    }
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      c.pause();
      _saveProgress();
    } else {
      c.play();
    }
    _touch();
  }

  void _seek(Duration d) {
    final c = _controller;
    if (c == null) return;
    c.seekTo(d);
    _touch();
  }

  void _startHold2x() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    _rateBeforeHold = _rate;
    c.setPlaybackSpeed(2.0);
    setState(() => _holding2x = true);
    _showControls();
  }

  void _endHold2x() {
    if (!_holding2x) return;
    _controller?.setPlaybackSpeed(_rateBeforeHold);
    if (!mounted) return;
    setState(() => _holding2x = false);
    _touch();
  }

  void _setRate(double rate) {
    _rate = rate;
    _controller?.setPlaybackSpeed(rate);
    _touch();
  }

  Future<void> _openDanmakuSettings() async {
    _hideTimer?.cancel();
    if (mounted) setState(() => _controls = true);
    await showDanmakuSettingsPanel(context);
    if (!mounted) return;
    _startHideTimer();
  }

  Future<void> _openPlayerSettings() async {
    _hideTimer?.cancel();
    if (mounted) setState(() => _controls = true);
    var openDanmaku = false;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return AnimatedBuilder(
              animation: danmakuSettings,
              builder: (context, _) {
                return Container(
                  padding: EdgeInsets.fromLTRB(
                    18,
                    14,
                    18,
                    18 + MediaQuery.of(context).padding.bottom,
                  ),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(24)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text('播放设置',
                              style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: Fx.ink)),
                          const Spacer(),
                          IconButton(
                            onPressed: () => Navigator.of(sheetContext).pop(),
                            icon: const Icon(Icons.close_rounded,
                                color: Fx.sub, size: 22),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      const Text('播放速度',
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: Fx.sub)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final item in const [0.75, 1.0, 1.25, 1.5, 2.0])
                            ChipTag(
                              item == 1.0
                                  ? '1.0x'
                                  : '${item.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '')}x',
                              active: _rate == item,
                              onTap: () {
                                _setRate(item);
                                setSheetState(() {});
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Icon(Icons.subtitles_rounded,
                              size: 20, color: Fx.accent),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text('显示弹幕',
                                style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                    color: Fx.ink)),
                          ),
                          Switch(
                            value: danmakuSettings.show,
                            activeColor: Fx.accent,
                            onChanged: (v) {
                              danmakuSettings.setShow(v);
                              setSheetState(() {});
                            },
                          ),
                        ],
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.tune_rounded,
                            size: 20, color: Fx.accent),
                        title: const Text('弹幕设置',
                            style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: Fx.ink)),
                        subtitle: const Text('字号 / 透明度 / 区域 / 滚动时间',
                            style: TextStyle(fontSize: 10.5, color: Fx.sub)),
                        trailing: const Icon(Icons.chevron_right_rounded,
                            color: Fx.sub),
                        onTap: () {
                          openDanmaku = true;
                          Navigator.of(sheetContext).pop();
                        },
                      ),
                      const ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.info_outline_rounded,
                            size: 20, color: Fx.sub),
                        title: Text('播放内核',
                            style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: Fx.ink)),
                        subtitle: Text('video_player · HLS / MP4 自适应',
                            style: TextStyle(fontSize: 10.5, color: Fx.sub)),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
    if (!mounted) return;
    if (openDanmaku) {
      await _openDanmakuSettings();
    } else {
      _startHideTimer();
    }
  }

  Future<void> _openFullscreen() async {
    final c = _controller;
    if (c == null || _openingFullscreen) return;
    _openingFullscreen = true;
    _hideTimer?.cancel();
    _wasPlayingBeforeFullscreen = c.value.isPlaying;
    final start = c.value.position.inMilliseconds / 1000.0;
    await _saveProgress();
    await c.pause();
    if (!mounted) {
      _openingFullscreen = false;
      return;
    }
    widget.onFullscreen?.call();
    final result = await Navigator.of(context).push<FullPlayerResult>(
      PageRouteBuilder<FullPlayerResult>(
        transitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (context, animation, secondaryAnimation) => FullPlayerPage(
          videoId: widget.videoId,
          ep: _ep,
          line: _line,
          title: _title,
          startPosition: start,
          playInfo: _info,
          episodes: widget.detail?.allEpisodes ?? const <Episode>[],
          initialDanmaku: _danmaku,
          lineName: _info?.lineName ?? '',
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
    );
    _openingFullscreen = false;
    if (!mounted) return;

    if (result != null && result.ep != _ep) {
      await _saveProgress();
      if (!mounted) return;
      setState(() {
        _ep = result.ep;
        _loading = true;
        _error = false;
      });
      widget.onEpChange?.call(result.ep);
      await _bootstrap(seekToSaved: true, saveOld: false);
      return;
    }

    final target =
        result?.position ?? await fxLoadProgress(widget.videoId, _ep);
    if (!mounted) return;
    final current = _controller;
    if (current != null && current.value.isInitialized) {
      await current.seekTo(
        Duration(milliseconds: (target * 1000).round()),
      );
      if (result?.playing ?? _wasPlayingBeforeFullscreen) {
        await current.play();
      } else {
        await current.pause();
      }
    }
    _showControls();
  }

  // -------------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return ColoredBox(
      color: Colors.black,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (c != null && c.value.isInitialized)
              Center(
                child: AspectRatio(
                  aspectRatio:
                      c.value.aspectRatio > 0 ? c.value.aspectRatio : 16 / 9,
                  child: VideoPlayer(c),
                ),
              ),
            if (c != null)
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: c,
                  builder: (context, _) {
                    final v = c.value;
                    if (!v.isInitialized) return const SizedBox.shrink();
                    return DanmakuOverlay(
                      items: _danmaku,
                      position: v.position,
                      playing: v.isPlaying,
                      settings: danmakuSettings,
                    );
                  },
                ),
              ),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _onSurfaceTap,
                onDoubleTap: () {
                  _togglePlay();
                  _showControls();
                },
                onLongPressStart: (_) => _startHold2x(),
                onLongPressEnd: (_) => _endHold2x(),
                child: const SizedBox.expand(),
              ),
            ),
            if (_loading && !_error) _buildLoading(),
            if (_error) _buildError(),
            if (c != null && c.value.isInitialized && !_error)
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: c,
                  builder: (context, _) {
                    final v = c.value;
                    if (v.isBuffering && !_loading) {
                      return const Center(
                        child: SizedBox(
                          width: 34,
                          height: 34,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: Colors.white,
                          ),
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ),
            if (_controls && !_error) _buildControls(c),
            if (_holding2x)
              Positioned(
                top: 14,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(.45),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white.withOpacity(.25)),
                    ),
                    child: const Text(
                      '⏩ 2.0x 倍速播放中',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(.22),
        alignment: Alignment.center,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.16),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(.26)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 17,
                height: 17,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
              SizedBox(width: 9),
              Text('正在加载线路…',
                  style: TextStyle(color: Colors.white, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(.36),
        alignment: Alignment.center,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 20),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.94),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(.18),
                blurRadius: 24,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, color: Fx.sub, size: 26),
              const SizedBox(height: 4),
              Text(
                _errorText,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Fx.ink,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _errorAction('重试', () {
                    reload();
                  }),
                  if (widget.onChangeLine != null ||
                      widget.onSourceFailed != null) ...[
                    const SizedBox(width: 10),
                    _errorAction('换线路', _requestLineChange),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorAction(String text, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          gradient: Fx.brand,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Fx.accent.withOpacity(.25),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  void _requestLineChange() {
    if (widget.onChangeLine != null) {
      widget.onChangeLine!();
      return;
    }
    widget.onSourceFailed?.call();
  }

  Widget _buildControls(VideoPlayerController? c) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 22),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(.55),
                  Colors.black.withOpacity(0),
                ],
              ),
            ),
            child: Row(
              children: [
                PGlassIcon(
                  icon: Icons.arrow_back_ios_new_rounded,
                  size: 32,
                  iconSize: 17,
                  onTap: () async {
                    await _saveProgress();
                    if (mounted) Navigator.of(context).maybePop();
                  },
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          shadows: [
                            Shadow(color: Colors.black54, blurRadius: 4),
                          ],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _epLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10.5,
                          shadows: [
                            Shadow(color: Colors.black54, blurRadius: 4),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                PGlassIcon(
                  icon: Icons.cast_rounded,
                  size: 31,
                  iconSize: 18,
                  onTap: () => fxToast(context, '正在搜索附近投屏设备…'),
                ),
                const SizedBox(width: 6),
                PGlassIcon(
                  icon: Icons.tv_rounded,
                  size: 31,
                  iconSize: 18,
                  onTap: () => fxToast(context, 'TV 投屏：暂无可用设备'),
                ),
                const SizedBox(width: 6),
                PGlassIcon(
                  icon: Icons.settings_rounded,
                  size: 31,
                  iconSize: 18,
                  onTap: _openPlayerSettings,
                ),
              ],
            ),
          ),
        ),
        Positioned(
          right: 10,
          top: 0,
          bottom: 0,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PDanmakuToggle(
                  on: danmakuSettings.show,
                  size: 34,
                  onTap: () {
                    danmakuSettings.setShow(!danmakuSettings.show);
                    _touch();
                  },
                ),
                const SizedBox(height: 10),
                PGlassIcon(
                  icon: Icons.tune_rounded,
                  size: 34,
                  iconSize: 18,
                  tooltip: '弹幕设置',
                  onTap: _openDanmakuSettings,
                ),
              ],
            ),
          ),
        ),
        if (c != null && c.value.isInitialized && !c.value.isPlaying)
          Center(
            child: PGlassIcon(
              icon: Icons.play_arrow_rounded,
              size: 54,
              iconSize: 32,
              tint: .18,
              onTap: _togglePlay,
            ),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 26, 8, 6),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0),
                  Colors.black.withOpacity(.62),
                ],
              ),
            ),
            child: c == null
                ? const SizedBox(height: 30)
                : AnimatedBuilder(
                    animation: c,
                    builder: (context, _) {
                      final v = c.value;
                      final playing = v.isInitialized && v.isPlaying;
                      return Row(
                        children: [
                          PGlassIcon(
                            icon: playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 30,
                            iconSize: 19,
                            tint: .13,
                            onTap: _togglePlay,
                          ),
                          const SizedBox(width: 7),
                          Text(
                            fxTime(v.position),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10.5,
                              shadows: [
                                Shadow(color: Colors.black54, blurRadius: 3),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: PProgressBar(
                              position: v.position,
                              duration: v.duration,
                              height: 3,
                              thumbSize: 16,
                              onSeek: _seek,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            fxTime(v.duration),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10.5,
                              shadows: [
                                Shadow(color: Colors.black54, blurRadius: 3),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          PGlassIcon(
                            icon: Icons.skip_next_rounded,
                            size: 30,
                            iconSize: 19,
                            tint: .13,
                            tooltip: '下一集',
                            onTap: () => unawaited(_next()),
                          ),
                          const SizedBox(width: 6),
                          PGlassIcon(
                            icon: Icons.fullscreen_rounded,
                            size: 30,
                            iconSize: 20,
                            tint: .13,
                            onTap: _openFullscreen,
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

/// 独立播放页入口（保留 Nav.player 兼容）；详情页使用 PlayerView。
class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.videoId,
    this.ep = 1,
    this.line = '',
  });

  final String videoId;
  final int ep;
  final String line;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  VideoDetail? _detail;
  String? _error;
  late int _ep;

  @override
  void initState() {
    super.initState();
    _ep = widget.ep;
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final detail = await Api.detail(widget.videoId);
      if (!mounted) return;
      setState(() => _detail = detail);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '加载失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: PlayerView(
                videoId: widget.videoId,
                ep: _ep,
                line: widget.line,
                detail: _detail,
                onEpChange: (n) => setState(() => _ep = n),
                onChangeLine: () => Navigator.of(context).maybePop(),
              ),
            ),
            if (_detail == null)
              Expanded(
                child: Center(
                  child: _error == null
                      ? const CircularProgressIndicator(color: Colors.white70)
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _error!,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextButton(
                              onPressed: _load,
                              child: const Text('重试',
                                  style: TextStyle(color: Colors.white)),
                            ),
                          ],
                        ),
                ),
              )
            else
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 30),
                  children: [
                    Text(
                      _detail!.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${_detail!.status} · ${_detail!.year} · ${_detail!.area}',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final e in _detail!.allEpisodes)
                          GestureDetector(
                            onTap: () => setState(() => _ep = e.n),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 7),
                              decoration: BoxDecoration(
                                color: _ep == e.n
                                    ? Fx.accent.withOpacity(.9)
                                    : Colors.white.withOpacity(.08),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: Colors.white.withOpacity(.18),
                                ),
                              ),
                              child: Text(
                                e.name.isEmpty ? fxEpisodeLabel(e.n) : e.name,
                                style: TextStyle(
                                  color: _ep == e.n
                                      ? Colors.white
                                      : Colors.white70,
                                  fontSize: 11.5,
                                ),
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
      ),
    );
  }
}

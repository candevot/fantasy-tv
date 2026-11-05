import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/download_service.dart';
import '../services/fx_player.dart';
import '../theme.dart';
import '../widgets/player_gestures.dart';
import '../widgets/player_theme.dart'
    show
        FxLoadingOverlay,
        FxPlayerSurface,
        FxSeekRow,
        PGlassIcon,
        fxSaveProgress;

/// 离线播放页：用 media_kit（[FxPlayer]）打开已下载的本地文件。
///
/// 与在线播放页共用同一套播放内核和手势 / 进度条控件，但不再请求
/// `/api/play`，也不使用 video_player。支持播放 / 暂停、拖动进度、
/// 双击暂停，以及横屏沉浸式全屏。
class OfflinePlayerPage extends StatefulWidget {
  const OfflinePlayerPage({
    super.key,
    required this.task,
    this.file,
  });

  final DownloadTask task;

  /// 已解析好的本地文件；为空时页面会通过 DownloadService 再解析一次。
  final File? file;

  @override
  State<OfflinePlayerPage> createState() => _OfflinePlayerPageState();
}

class _OfflinePlayerPageState extends State<OfflinePlayerPage> {
  FxPlayer? _player;
  bool _loading = true;
  String? _error;
  bool _fullscreen = false;
  bool _controlsVisible = true;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  Timer? _hideTimer;
  int _openSeq = 0;

  static const List<DeviceOrientation> _landscape = <DeviceOrientation>[
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  static const SystemUiOverlayStyle _appOverlay = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarContrastEnforced: false,
  );

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final seq = ++_openSeq;
    // 重试时先释放旧播放器，避免同一个本地文件同时挂两个 libmpv 实例。
    final previous = _player;
    _player = null;
    if (previous != null) {
      previous.removeListener(_onPlayer);
      unawaited(previous.dispose());
    }
    final task = widget.task;
    File? file = widget.file;
    if (file == null) {
      final path = task.filePath;
      if (path != null && path.isNotEmpty) {
        final candidate = File(path);
        if (await candidate.exists()) file = candidate;
      }
      file ??= await DownloadService.instance.fileFor(task);
    }
    if (!mounted || seq != _openSeq) return;
    if (file == null || !await file.exists()) {
      setState(() {
        _loading = false;
        _error = '缓存文件不存在，可能已被系统清理';
      });
      return;
    }

    final player = FxPlayer.create();
    player.addListener(_onPlayer);
    try {
      // 离线播放统一走 file:// 本地地址；libmpv 按文件内容识别封装，
      // 即便缓存来自 HLS 拼接也能正常播放。
      final uri = Uri.file(file.path).toString();
      await player.open(uri, play: true);
      if (!mounted || seq != _openSeq) {
        player.removeListener(_onPlayer);
        await player.dispose();
        return;
      }
      await player.setLooping(false);
      await player.play();
      if (!mounted || seq != _openSeq) {
        player.removeListener(_onPlayer);
        await player.dispose();
        return;
      }
      setState(() {
        _player = player;
        _loading = false;
        _error = null;
        _duration = player.value.duration;
        _position = player.value.position;
        _playing = player.value.isPlaying;
      });
      _wake();
    } catch (e) {
      player.removeListener(_onPlayer);
      try {
        await player.dispose();
      } catch (_) {}
      if (!mounted || seq != _openSeq) return;
      setState(() {
        _loading = false;
        _error = '离线播放失败：${_short(e)}';
      });
    }
  }

  String _short(Object error) {
    final text = '$error';
    return text.length > 100 ? '${text.substring(0, 100)}…' : text;
  }

  void _onPlayer() {
    final player = _player;
    if (!mounted || player == null) return;
    final value = player.value;
    final error = value.hasError
        ? (value.errorText.trim().isEmpty ? '本地文件解码失败' : value.errorText)
        : null;
    setState(() {
      _position = value.position;
      _duration = value.duration;
      _playing = value.isPlaying;
      if (error != null) _error = error;
    });
  }

  @override
  void dispose() {
    _openSeq++;
    _hideTimer?.cancel();
    final player = _player;
    _player = null;
    if (player != null) {
      player.removeListener(_onPlayer);
      unawaited(player.dispose());
    }
    if (_position > Duration.zero) {
      unawaited(fxSaveProgress(
        widget.task.id,
        widget.task.ep,
        _position.inMilliseconds / 1000.0,
      ));
    }
    if (_fullscreen) {
      unawaited(_restorePortrait());
    }
    super.dispose();
  }

  Future<void> _playOrPause() async {
    final player = _player;
    if (player == null) return;
    if (!player.isPlaying &&
        _duration > Duration.zero &&
        _position >= _duration - const Duration(milliseconds: 300)) {
      await player.seek(Duration.zero);
    }
    await player.playOrPause();
    _wake();
  }

  Future<void> _seek(Duration position) async {
    await _player?.seek(position);
    _wake();
  }

  void _toggleControls() {
    if (_hideTimer?.isActive ?? false) {
      setState(() => _controlsVisible = false);
      _hideTimer?.cancel();
      return;
    }
    _wake();
  }

  void _wake() {
    _hideTimer?.cancel();
    if (!mounted) return;
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    if (_loading || _error != null) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _controlsVisible = false);
    });
  }

  Future<void> _toggleFullscreen() async {
    if (_fullscreen) {
      await _restorePortrait();
      if (mounted) setState(() => _fullscreen = false);
    } else {
      setState(() {
        _fullscreen = true;
        _controlsVisible = true;
      });
      await SystemChrome.setPreferredOrientations(_landscape);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    _wake();
  }

  Future<void> _restorePortrait() async {
    await SystemChrome.setPreferredOrientations(
      const <DeviceOrientation>[DeviceOrientation.portraitUp],
    );
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(_appOverlay);
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _fullscreen) {
          unawaited(_toggleFullscreen());
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          top: !_fullscreen,
          bottom: !_fullscreen,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (player != null)
                FxPlayerSurface(player: player, fit: BoxFit.contain)
              else
                const ColoredBox(color: Colors.black),
              if (player != null && _error == null)
                FxPlayerGestures(
                  player: player,
                  onTap: _toggleControls,
                  onDoubleTap: () => unawaited(_playOrPause()),
                  onSeek: (position) => unawaited(_seek(position)),
                ),
              if (_loading)
                const FxLoadingOverlay(
                  title: '正在打开离线缓存…',
                  compact: true,
                ),
              if (_error != null) _errorView(),
              if (player != null && _error == null) _controls(player),
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorView() {
    return ColoredBox(
      color: Colors.black.withValues(alpha: .78),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded,
                  size: 36, color: Colors.white54),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('返回列表',
                        style: TextStyle(color: Colors.white)),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () {
                      _error = null;
                      _loading = true;
                      setState(() {});
                      unawaited(_open());
                    },
                    child:
                        const Text('重试', style: TextStyle(color: Colors.white)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _controls(FxPlayer player) {
    final task = widget.task;
    return AnimatedOpacity(
      opacity: _controlsVisible ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      child: IgnorePointer(
        ignoring: !_controlsVisible,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: Container(
                padding: const EdgeInsets.fromLTRB(6, 6, 14, 26),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xB3000000), Color(0x00000000)],
                  ),
                ),
                child: Row(
                  children: [
                    PGlassIcon(
                      icon: Icons.arrow_back_ios_new_rounded,
                      iconSize: 18,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            task.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              shadows: [
                                Shadow(color: Colors.black54, blurRadius: 3),
                              ],
                            ),
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Fx.accent.withValues(alpha: .82),
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: const Text(
                                  '已下载',
                                  style: TextStyle(
                                      fontSize: 8.5, color: Colors.white),
                                ),
                              ),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  task.epLabel,
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
                    const SizedBox(width: 8),
                    PGlassIcon(
                      icon: _fullscreen
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                      iconSize: 21,
                      onTap: () => unawaited(_toggleFullscreen()),
                    ),
                  ],
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 28, 14, 12),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x00000000), Color(0xB3000000)],
                  ),
                ),
                child: Row(
                  children: [
                    PGlassIcon(
                      icon: _playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 44,
                      iconSize: 25,
                      onTap: () => unawaited(_playOrPause()),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FxSeekRow(
                        position: _position,
                        duration: _duration,
                        buffered: player.value.buffered,
                        onSeek: (position) => unawaited(_seek(position)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    PGlassIcon(
                      icon: _fullscreen
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                      size: 36,
                      iconSize: 19,
                      onTap: () => unawaited(_toggleFullscreen()),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

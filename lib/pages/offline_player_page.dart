import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_settings.dart';
import '../services/download_service.dart';
import '../services/fx_display_settings.dart';
import '../services/fx_player.dart';
import '../services/screen_orientation.dart';
import '../theme.dart';
import '../widgets/fs_controls.dart';
import '../widgets/fs_panels.dart';
import '../widgets/player_gestures.dart';
import '../widgets/player_more_panel.dart' show FxLoopMode;
import '../widgets/player_theme.dart'
    show
        FxLoadingOverlay,
        FxPlayerSurface,
        fxLoadProgress,
        fxPlayerQuality,
        fxResumeMinSeconds,
        fxSaveProgress,
        kPlayerControlsAutoHide;

/// 离线播放页：用 [FxPlayer]（ExoPlayer 内核）打开已下载的本地文件。
///
/// 打开即横屏全屏（与在线全屏一致），横屏控件**完全复用在线全屏组件**：
/// [FsTopBar] 返回·剧名·集数·⋯设置 / [FsSideControls] 左锁右±10s /
/// [FsBottomBar] 进度·播放暂停·下一集·选集·⋯设置·退出；⋯面板里是
/// 画面比例 / 镜像 / 倍速 / 定时关闭 / 循环。只隐藏在线才有的入口：
/// 投屏、清晰度·线路、下载，也不请求 `/api/play`。
/// 退出（返回键 / 顶栏返回 / 底栏退出）先恢复竖屏再退栈。
/// 播完当前集按设置自动切到下一部已下载集。
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

class _OfflinePlayerPageState extends State<OfflinePlayerPage>
    with WidgetsBindingObserver {
  final DownloadService _service = DownloadService.instance;

  /// 当前正在播放的集：选集 / 自动连播会就地切换，不重新入栈页面。
  late DownloadTask _task = widget.task;

  FxPlayer? _player;
  bool _loading = true;
  String? _error;
  bool _controlsVisible = true;
  bool _playing = false;
  bool _switching = false;
  bool _endedHandled = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  double _rate = 1;

  /// 循环播放：单集循环交给 mpv（loop-file），关闭则按「自动下一集」连播。
  FxLoopMode _loopMode = FxLoopMode.off;

  /// 退出进行中：顶栏返回 / 底栏退出 / 系统返回键共用一个闸门，只退一次。
  bool _leaving = false;

  /// 切集 / 打开后时长还没出来时挂起的续播点（秒）。
  int? _pendingSeek;

  /// 锁屏：锁定后只留一个解锁钮，点画面只做解锁钮的显隐切换。
  bool _locked = false;
  bool _unlockVisible = true;

  /// 切后台那一刻的播放位置：离线播放同样会被系统冻结 / 重置进度，
  /// 回前台按它自愈（拉回原进度并继续播）。
  bool _backgrounded = false;
  Duration _backgroundAnchor = Duration.zero;
  bool _backgroundWasPlaying = true;

  /// 该剧全部任务（选集面板用：已下载可直接切，其它显示状态）。
  List<DownloadTask> _episodes = const <DownloadTask>[];

  Timer? _hideTimer;
  Timer? _sleepTimer;
  Timer? _unlockTimer;
  int _openSeq = 0;

  /// 设置面板打开期间用于刷新面板自身的选中态。
  void Function(void Function())? _setSheet;

  static const SystemUiOverlayStyle _appOverlay = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarContrastEnforced: false,
  );

  static const List<double> _rates = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _service.addListener(_onServiceChanged);
    _refreshEpisodes();
    unawaited(_prepareSettings());
    // 打开即横屏全屏：竖屏进、横屏播，退出时再恢复竖屏。
    unawaited(_enterLandscape());
    _open();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        return;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        _backgrounded = true;
        _backgroundAnchor = _player?.value.position ?? _backgroundAnchor;
        _backgroundWasPlaying = _player?.value.isPlaying ?? true;
        unawaited(_savePosition());
        return;
      case AppLifecycleState.resumed:
        final wasBackgrounded = _backgrounded;
        _backgrounded = false;
        if (wasBackgrounded) unawaited(_recoverAfterBackground());
        return;
    }
  }

  /// 回前台自愈：冻结就继续播，进度被重置就拉回切后台时的位置。
  Future<void> _recoverAfterBackground() async {
    final player = _player;
    if (player == null || _error != null) return;
    final anchor = _backgroundAnchor;
    if (anchor <= Duration.zero) return;
    final healed = await player.recoverAfterBackground(
      anchor,
      wasPlaying: _backgroundWasPlaying,
    );
    if (!mounted) return;
    if (!healed) {
      unawaited(player.resumeSelfCheck());
      return;
    }
    setState(() {});
    _wake();
  }

  Future<void> _prepareSettings() async {
    final settings = AppSettings.instance;
    await settings.init();
    if (!mounted) return;
    await _restoreSleepTimer();
    if (mounted) setState(() {});
  }

  void _onServiceChanged() {
    if (!mounted) return;
    _refreshEpisodes();
    setState(() {});
  }

  void _refreshEpisodes() {
    final list =
        List<DownloadTask>.from(_service.tasksForSeries(_task.id))
          ..sort((a, b) => a.ep.compareTo(b.ep));
    _episodes = list;
  }

  /// 该剧总集数（选集面板要列出还没下载的集号）。
  int get _totalEpisodes {
    var total = _service.seriesTotalEpisodes(_task.id);
    for (final t in _episodes) {
      if (t.ep > total) total = t.ep;
    }
    return total < 1 ? 1 : total;
  }

  List<DownloadTask> get _downloaded =>
      _episodes.where((t) => t.status == DownloadStatus.completed).toList();

  Future<void> _open() async {
    final seq = ++_openSeq;
    final task = _task;
    File? file;
    if (identical(task, widget.task)) file = widget.file;
    file ??= await _service.fileFor(task);
    if (!mounted || seq != _openSeq) return;
    if (file == null || !await file.exists()) {
      setState(() {
        _loading = false;
        _error = '缓存文件不存在，可能已被系统清理';
      });
      return;
    }

    FxPlayer player = _player ?? FxPlayer.create();
    final isNew = _player == null;
    if (isNew) {
      player.addListener(_onPlayer);
      _player = player;
    }
    try {
      // 离线播放统一走 file:// 本地地址；libmpv 按文件内容识别封装，
      // 即便缓存来自 HLS 拼接也能正常播放。
      final uri = Uri.file(file.path).toString();
      await player.open(uri, play: true);
      if (!mounted || seq != _openSeq) return;
      await player.setLooping(_loopMode == FxLoopMode.single);
      await player.setRate(_rate);
      // 续播：读上次离线/在线共用的进度（同一 videoId + 集号）。
      final saved = await fxLoadProgress(task.id, task.ep);
      if (!mounted || seq != _openSeq) return;
      setState(() {
        _loading = false;
        _error = null;
        _endedHandled = false;
        _duration = player.value.duration;
        _position = player.value.position;
        _playing = player.value.isPlaying;
        _buffered = player.value.buffered;
      });
      _armResume(saved);
      _wake();
    } catch (e) {
      // 打开失败：释放这个实例，重试时重新创建，避免坏状态残留。
      player.removeListener(_onPlayer);
      try {
        await player.dispose();
      } catch (_) {}
      if (identical(_player, player)) _player = null;
      if (!mounted || seq != _openSeq) return;
      setState(() {
        _loading = false;
        _error = '离线播放失败：${_short(e)}';
      });
    }
  }

  /// 续播门槛与在线播放一致：不足 60 秒从头播，接近结尾也不回跳。
  ///
  /// 根因（v3.8 及以前「本地缓存不续播」）：这里用 [_duration] 判断时长是否
  /// 就绪，而 [_open] 是在 `player.open()` 之后立刻调用本方法的——那时
  /// `player.value.duration` 还是 0，于是永远走 `_pendingSeek` 分支；而
  /// [_onPlayer] 只在 `value.duration > Duration.zero` 时才消费挂起点，本地
  /// 文件 open 后位置/时长往往一次到位、后续不再有「从 0 变成有时长」的通知，
  /// 挂起点就一直烂在字段里，续播永远不生效。
  ///
  /// 现在：时长已知就直接 seek；未知就把秒数挂在 [_pendingSeek]，
  /// 由 [_onPlayer] 在「位置已推进」或「时长已到」任一条件下立刻消费。
  void _armResume(double saved) {
    _pendingSeek = null;
    if (saved < fxResumeMinSeconds) return;
    final seconds = saved.round();
    final duration = _duration > Duration.zero
        ? _duration
        : (_player?.value.duration ?? Duration.zero);
    if (duration > Duration.zero) {
      // 存的进度太靠近结尾就直接从头播，别卡在最后一秒。
      if (seconds < duration.inSeconds - 5) {
        unawaited(_seekAfterOpen(seconds));
      }
      return;
    }
    _pendingSeek = seconds;
  }

  /// open 之后立刻 seek 可能被 mpv 的起播复位吃掉，稍微让一拍再落点。
  Future<void> _seekAfterOpen(int seconds) async {
    final player = _player;
    if (player == null) return;
    try {
      await player.seek(Duration(seconds: seconds));
    } catch (_) {
      return;
    }
    // 复核：位置没落到目标附近（被起播流程复位）就再补一次。
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted || !identical(_player, player)) return;
    final now = player.value.position;
    if ((now.inSeconds - seconds).abs() > 5) {
      try {
        await player.seek(Duration(seconds: seconds));
      } catch (_) {}
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
      _buffered = value.buffered;
      _playing = value.isPlaying;
      if (error != null) _error = error;
    });
    // 续播挂起点：时长一到、或位置已经开始推进（本地文件常常一次就绪，
    // 不会再有一次「时长从 0 变有时长」的通知）都要立刻消费，否则永远不续播。
    final pending = _pendingSeek;
    if (pending != null &&
        (value.duration > Duration.zero ||
            value.position > Duration.zero ||
            value.isPlaying)) {
      _pendingSeek = null;
      final duration = value.duration;
      // 存的进度太靠近结尾就直接从头播，别卡在最后一秒。
      if (duration <= Duration.zero ||
          pending < duration.inSeconds - 5) {
        unawaited(player.seek(Duration(seconds: pending)));
      }
    }
    if (value.isCompleted) unawaited(_handleEnded());
  }

  /* ------------------------------------------------------------ 播控逻辑 */

  /// 播完一集：定时关闭「看完当集」优先暂停；否则按「自动下一集」切到
  /// 下一部已下载的集（只在本地已缓存的集之间连播）。
  Future<void> _handleEnded() async {
    if (_endedHandled || _switching) return;
    _endedHandled = true;
    await _savePosition(ended: true);
    if (!mounted) return;
    final settings = AppSettings.instance;
    if (settings.sleepMode == FxSleepMode.episode) {
      try {
        await _player?.pause();
      } catch (_) {}
      unawaited(settings.setSleepTimer(FxSleepMode.off));
      _refreshSheet();
      _wake();
      return;
    }
    if (_loopMode == FxLoopMode.single) {
      // 单集循环：回到片头继续播这一集，不切下一集、不连播。
      _endedHandled = false;
      try {
        await _player?.seek(Duration.zero);
        await _player?.play();
      } catch (_) {}
      return;
    }
    if (settings.autoNext) {
      final next = _nextEpisode();
      if (next != null) {
        await _switchTo(next, reason: '自动播放');
        return;
      }
    }
    _wake();
  }

  /// 下一集：优先同号顺位的下一集，其次取集号更大的第一集已下载集。
  DownloadTask? _nextEpisode() {
    final done = _downloaded;
    if (done.isEmpty) return null;
    final index = done.indexWhere((t) => t.ep == _task.ep);
    if (index >= 0 && index + 1 < done.length) return done[index + 1];
    for (final t in done) {
      if (t.ep > _task.ep) return t;
    }
    return null;
  }

  /// 选集 / 自动连播切换：只换本地文件，不联网。
  Future<void> _switchTo(DownloadTask next, {String? reason}) async {
    if (_switching || next.ep == _task.ep || _loading) return;
    final file = await _service.fileFor(next);
    if (!mounted) return;
    if (file == null) {
      _toast('「${next.epLabel}」缓存文件不存在，请重新下载');
      return;
    }
    _switching = true;
    _hideTimer?.cancel();
    await _savePosition();
    if (!mounted) {
      _switching = false;
      return;
    }
    setState(() {
      _task = next;
      _loading = true;
      _error = null;
      _endedHandled = false;
      _controlsVisible = true;
      _position = Duration.zero;
      _duration = Duration.zero;
      _buffered = Duration.zero;
      _playing = false;
    });
    if (reason != null) _toast('$reason · ${next.epLabel}');
    await _open();
    _switching = false;
    if (mounted) _wake();
  }

  /// 记进度：播完写 0（下次从头看），退出 / 切集写当前位置。
  Future<void> _savePosition({bool ended = false}) async {
    final task = _task;
    final seconds =
        ended ? 0.0 : _position.inMilliseconds / 1000.0;
    if (!ended && seconds <= 0) return;
    if (seconds.isNaN || seconds.isInfinite) return;
    unawaited(fxSaveProgress(task.id, task.ep, seconds));
  }

  Future<void> _playOrPause() async {
    final player = _player;
    if (player == null) return;
    if (!player.isPlaying &&
        _duration > Duration.zero &&
        _position >= _duration - const Duration(milliseconds: 300)) {
      await player.seek(Duration.zero);
      _endedHandled = false;
    }
    await player.playOrPause();
    _wake();
  }

  Future<void> _seek(Duration position) async {
    final player = _player;
    if (player == null) return;
    _endedHandled = false;
    await player.seek(position);
    _wake();
  }

  Future<void> _seekBy(int seconds) async {
    final target = _position + Duration(seconds: seconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (_duration > Duration.zero && target > _duration
            ? _duration
            : target);
    await _seek(clamped);
  }

  Future<void> _setRate(double rate) async {
    _rate = rate;
    if (mounted) setState(() {});
    try {
      await _player?.setRate(rate);
    } catch (_) {}
    _refreshSheet();
  }

  /// 循环播放：单集循环交给 mpv（loop-file），关闭则按「自动下一集」连播。
  Future<void> _setLoopMode(FxLoopMode mode) async {
    if (_loopMode == mode) return;
    _loopMode = mode;
    // 关掉循环时清掉「本集已播完」标记，这一集结尾才会触发自动下一集。
    if (mode == FxLoopMode.off) _endedHandled = false;
    try {
      await _player?.setLooping(mode == FxLoopMode.single);
    } catch (_) {}
    _refreshSheet();
  }

  /* -------------------------------------------------------------- 控件显隐 */

  void _toggleControls() {
    if (_hideTimer?.isActive ?? false) {
      _hideControls();
      return;
    }
    _wake();
  }

  void _wake() {
    _hideTimer?.cancel();
    if (!mounted || _locked) return;
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    if (_loading || _error != null) return;
    _hideTimer = Timer(kPlayerControlsAutoHide, () {
      if (!mounted) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _hideControls() {
    _hideTimer?.cancel();
    if (!mounted) return;
    setState(() => _controlsVisible = false);
  }

  /* ------------------------------------------------------------------ 锁屏 */

  void _lock() {
    _hideTimer?.cancel();
    setState(() {
      _locked = true;
      _controlsVisible = false;
      _unlockVisible = true;
    });
    _unlockTimer?.cancel();
    _unlockTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _unlockVisible = false);
    });
  }

  void _unlock() {
    _unlockTimer?.cancel();
    setState(() {
      _locked = false;
      _unlockVisible = true;
    });
    _wake();
  }

  /// 锁定后点画面：解锁钮可见就立即藏起来，藏起来就再亮 3 秒。
  void _onLockedTap() {
    _unlockTimer?.cancel();
    if (_unlockVisible) {
      setState(() => _unlockVisible = false);
      return;
    }
    setState(() => _unlockVisible = true);
    _unlockTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !_locked) return;
      setState(() => _unlockVisible = false);
    });
  }

  /* ----------------------------------------------------------- 全屏 / 系统 */

  /// 进页面即横屏 + 沉浸式全屏（与在线全屏同一套系统栏动作）。
  Future<void> _enterLandscape() async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    } catch (_) {
      // 桌面 / 模拟器上不支持也无所谓
    }
    // 与在线全屏同一套：SENSOR_LANDSCAPE，系统旋转锁开着也能横屏。
    await ScreenOrientation.landscape();
  }

  /// 退出前恢复竖屏 + 常规系统栏。
  Future<void> _restorePortrait() async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(_appOverlay);
    } catch (_) {}
    await ScreenOrientation.portrait();
  }

  /// 退出离线播放：先恢复竖屏再退栈，回到列表时已经是竖屏。
  /// 顶栏返回、底栏「退出」、系统返回键都走这里。
  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    await _restorePortrait();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /* ------------------------------------------------------------ 定时关闭 */

  Future<void> _applySleep(FxSleepMode mode, int minutes) async {
    final settings = AppSettings.instance;
    await settings.init();
    _sleepTimer?.cancel();
    _sleepTimer = null;
    if (mode == FxSleepMode.minutes) {
      final endsAt = DateTime.now().millisecondsSinceEpoch + minutes * 60000;
      await settings.setSleepTimer(mode, minutes: minutes, endsAt: endsAt);
      _armSleep(endsAt - DateTime.now().millisecondsSinceEpoch);
    } else {
      await settings.setSleepTimer(mode);
    }
    if (mounted) setState(() {});
    _refreshSheet();
  }

  void _armSleep(int millis) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    if (millis <= 0) {
      _fireSleep();
      return;
    }
    _sleepTimer = Timer(Duration(milliseconds: millis), _fireSleep);
  }

  /// 定时到点：暂停播放、保留进度，模式回落「不开启」。
  void _fireSleep() {
    _sleepTimer = null;
    if (!mounted) return;
    unawaited(_player?.pause());
    unawaited(AppSettings.instance.setSleepTimer(FxSleepMode.off));
    setState(() {});
    _toast('定时关闭已到，已暂停播放');
  }

  /// 进页面时续上持久化的分钟定时：过期就直接回落「不开启」。
  Future<void> _restoreSleepTimer() async {
    final settings = AppSettings.instance;
    if (settings.sleepMode != FxSleepMode.minutes) return;
    final left = settings.sleepEndsAt - DateTime.now().millisecondsSinceEpoch;
    if (left <= 0) {
      await settings.setSleepTimer(FxSleepMode.off);
      return;
    }
    _armSleep(left);
  }

  void _refreshSheet() {
    _setSheet?.call(() {});
    if (mounted) setState(() {});
  }

  /* ------------------------------------------------------------- 设置面板 */

  Future<void> _openSettingsSheet() async {
    _hideTimer?.cancel();
    if (mounted) setState(() => _controlsVisible = true);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: Colors.black.withValues(alpha: .34),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) {
          _setSheet = setSheet;
          return _settingsSheet();
        },
      ),
    );
    _setSheet = null;
    if (mounted) _wake();
  }

  Future<void> _openEpisodeSheet() async {
    _hideTimer?.cancel();
    if (mounted) setState(() => _controlsVisible = true);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: Colors.black.withValues(alpha: .34),
      builder: (sheetCtx) => _episodeSheet(),
    );
    if (mounted) _wake();
  }

  Widget _settingsSheet() {
    final display = FxDisplaySettings.instance;
    final settings = AppSettings.instance;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .78,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFFF7FAFF),
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(18, 10, 18, 14 + bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFE3E9F3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.tune_rounded, size: 18, color: Fx.accent),
                const SizedBox(width: 7),
                const Text(
                  '播放设置',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Fx.ink,
                  ),
                ),
                const Spacer(),
                Flexible(
                  child: Text(
                    '${_task.title} · ${_task.epLabel}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10.5, color: Fx.sub),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _sheetSection(
              title: '画面比例',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final mode in FxAspectMode.values)
                    _optChip(
                      label: mode.label,
                      selected: display.aspect == mode,
                      onTap: () {
                        unawaited(display.setAspect(mode));
                        _refreshSheet();
                      },
                    ),
                ],
              ),
            ),
            _sheetSection(
              title: '镜像',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final mode in FxMirrorMode.values)
                    _optChip(
                      label: mode.label,
                      selected: display.mirror == mode,
                      onTap: () {
                        unawaited(display.setMirror(mode));
                        _refreshSheet();
                      },
                    ),
                ],
              ),
            ),
            _sheetSection(
              title: '倍速',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final rate in _rates)
                    _optChip(
                      label: _rateLabel(rate),
                      selected: (_rate - rate).abs() < .001,
                      onTap: () => unawaited(_setRate(rate)),
                    ),
                ],
              ),
            ),
            _sheetSection(
              title: '定时关闭',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _optChip(
                    label: '不开启',
                    selected: settings.sleepMode == FxSleepMode.off,
                    onTap: () => unawaited(_applySleep(FxSleepMode.off, 0)),
                  ),
                  _optChip(
                    label: '播完本集',
                    selected: settings.sleepMode == FxSleepMode.episode,
                    onTap: () =>
                        unawaited(_applySleep(FxSleepMode.episode, 0)),
                  ),
                  for (final minutes in AppSettings.sleepTimerOptions)
                    _optChip(
                      label: '$minutes 分钟',
                      selected: settings.sleepMode == FxSleepMode.minutes &&
                          settings.sleepMinutes == minutes,
                      onTap: () =>
                          unawaited(_applySleep(FxSleepMode.minutes, minutes)),
                    ),
                ],
              ),
            ),
            _sheetSection(
              title: '循环播放',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final mode in FxLoopMode.values)
                    _optChip(
                      label: mode.label,
                      selected: _loopMode == mode,
                      onTap: () => unawaited(_setLoopMode(mode)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _switchRow(
                    label: '播完自动下一集',
                    hint: '仅在已下载的集之间连播',
                    value: settings.autoNext,
                    onChanged: (v) {
                      unawaited(settings.setAutoNext(v));
                      _refreshSheet();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                _sheetButton(
                  icon: Icons.lock_outline_rounded,
                  label: '锁定屏幕',
                  onTap: () {
                    Navigator.of(context).maybePop();
                    _lock();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _rateLabel(double rate) =>
      rate == rate.roundToDouble() ? '${rate.toInt()}x' : '${rate}x';

  Widget _sheetSection({required String title, required Widget child}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Fx.ink,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  Widget _optChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? Fx.accent.withValues(alpha: .14)
              : Colors.white,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: selected
                ? Fx.accent
                : const Color(0xFFE4EAF4),
            width: selected ? 1.3 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
            color: selected ? Fx.accent : Fx.ink,
          ),
        ),
      ),
    );
  }

  Widget _switchRow({
    required String label,
    required String hint,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE4EAF4)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: Fx.ink,
                  ),
                ),
                Text(
                  hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 9, color: Fx.sub),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            activeTrackColor: Fx.accent,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _sheetButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE4EAF4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: Fx.accent),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: Fx.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 选集：只列本地任务，已下载的可直接切，其余显示排队 / 未下载状态。
  Widget _episodeSheet() {
    final size = MediaQuery.sizeOf(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    final total = _totalEpisodes;
    final current = _task.ep;
    return Container(
      // 横屏可用高度小，抽屉放高一点；竖屏维持原来的 58%。
      height: size.height * (size.width > size.height ? .78 : .58),
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
            padding: const EdgeInsets.fromLTRB(18, 12, 10, 8),
            child: Row(
              children: [
                const Icon(Icons.playlist_play_rounded,
                    size: 19, color: Fx.accent),
                const SizedBox(width: 7),
                const Text(
                  '选集',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Fx.ink,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '已下载 ${_downloaded.length}/$total 集',
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
          Expanded(
            child: GridView.builder(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12 + bottom),
              physics: const BouncingScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1.9,
              ),
              itemCount: total,
              itemBuilder: (ctx, i) => _episodeTile(i + 1, current),
            ),
          ),
        ],
      ),
    );
  }

  Widget _episodeTile(int ep, int current) {
    final task = _service.taskFor(_task.id, ep);
    final status = task?.status;
    final downloaded = status == DownloadStatus.completed;
    final isCurrent = ep == current;
    final color = downloaded
        ? (isCurrent ? Fx.accent : const Color(0xFF2FA985))
        : (status == null ? const Color(0xFF8D99AA) : Fx.sub);
    final stateText = status == null
        ? '未下载'
        : switch (status) {
            DownloadStatus.completed => isCurrent ? '播放中' : '已下载',
            DownloadStatus.downloading => '下载中',
            DownloadStatus.queued => '排队中',
            DownloadStatus.paused => '已暂停',
            DownloadStatus.failed => '下载失败',
          };

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: downloaded
          ? () {
              final target = task;
              if (target == null) return;
              Navigator.of(context).maybePop();
              unawaited(_switchTo(target));
            }
          : null,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: isCurrent
              ? Fx.accent.withValues(alpha: .12)
              : Colors.white.withValues(alpha: .85),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: isCurrent
                ? Fx.accent
                : downloaded
                    ? const Color(0xFF2FA985).withValues(alpha: .45)
                    : const Color(0xFFE4EAF4),
            width: isCurrent ? 1.3 : 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '第 $ep 集',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                fontWeight: downloaded ? FontWeight.w700 : FontWeight.w500,
                color: color,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              stateText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 8,
                height: 1.1,
                color: color.withValues(alpha: .85),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /* ------------------------------------------------------------------ UI */

  @override
  Widget build(BuildContext context) {
    final player = _player;
    return PopScope(
      // 横屏打开：返回键一律走 [_leave]（先恢复竖屏再退栈）。
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        unawaited(_leave());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        // 横屏沉浸式全屏：不给系统栏留位，与在线全屏一致。
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (player != null)
              FxPlayerSurface(player: player)
            else
              const ColoredBox(color: Colors.black),
            if (player != null && _error == null && !_locked)
              FxPlayerGestures(
                player: player,
                onTap: _toggleControls,
                onDoubleTap: () => unawaited(_playOrPause()),
                onSeek: (position) => unawaited(_seek(position)),
              ),
            if (_loading)
              FxLoadingOverlay(
                title: _switching || !identical(_task, widget.task)
                    ? '正在打开 ${_task.epLabel}…'
                    : '正在打开离线缓存…',
                compact: true,
              ),
            if (_error != null) _errorView(),
            if (player != null && _error == null && !_locked)
              _controls(),
            if (_locked) _lockedLayer(),
          ],
        ),
      ),
    );
  }

  /// 锁屏层：点画面只切解锁钮显隐，解锁钮在最上面单独接点击。
  /// 解锁钮与左侧的锁同一位置（在线全屏同款 [FsUnlockButton]）。
  Widget _lockedLayer() {
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onLockedTap,
          child: const SizedBox.expand(),
        ),
        SafeArea(
          child: FsUnlockButton(
            onUnlock: _unlock,
            visible: _unlockVisible,
          ),
        ),
      ],
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
                    onPressed: () => unawaited(_leave()),
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

  /// 横屏控件层：完全复用在线全屏三件套 —— [FsTopBar] 返回·剧名·集数·⋯设置，
  /// [FsSideControls] 左锁（左侧中部，不与返回重叠）·右 ±10 秒，
  /// [FsBottomBar] 进度 · 播放暂停 · 下一集 · 选集 · ⋯设置 · 退出。
  /// 投屏 / 清晰度·线路 / 下载这些在线入口一律不给。
  Widget _controls() {
    final compact = MediaQuery.sizeOf(context).width < 700;
    return AnimatedOpacity(
      opacity: _controlsVisible ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      child: IgnorePointer(
        ignoring: !_controlsVisible,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _topBar(compact: compact),
            ),
            Positioned.fill(
              child: FsSideControls(
                onLock: _lock,
                onSeekBy: (seconds) => unawaited(_seekBy(seconds)),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _bottomBar(compact: compact),
            ),
          ],
        ),
      ),
    );
  }

  /// 顶栏：完全复用在线全屏的 [FsTopBar]（返回 · 剧名 · 集数 · ⋯设置）。
  ///
  /// 投屏只对在线播放有意义，而 [FsTopBar] 的投屏钮是必填项：这里传空实现，
  /// 再用与顶栏逐像素相同的渐变把投屏那一列盖住（离线页不给投屏入口，
  /// 顺带挡住那颗按钮的点击与长按提示）。遮罩按 FsTopBar 的排布定位：
  /// 右内边距 10 + ⋯钮 32·s + 间距 7·s + 投屏钮 32·s，上下拉满整条顶栏。
  Widget _topBar({required bool compact}) {
    final s = compact ? .9 : 1.0;
    // FsTopBar 会按屏幕安全边距右移一列，遮罩跟着移才能继续盖住投屏钮。
    final safeRight = MediaQuery.viewPaddingOf(context).right;
    return Stack(
      children: [
        FsTopBar(
          title: _task.title,
          epLabel: '${_task.epLabel} · ${_task.sizeLabel} · 已下载',
          compact: compact,
          qualityLabel: fxPlayerQuality(_player),
          onBack: () => unawaited(_leave()),
          onCast: () {}, // 离线不投屏：这一列已被下面的遮罩盖住
          onMore: () => unawaited(_openSettingsSheet()),
        ),
        Positioned(
          right: 5 + 39 * s + safeRight,
          width: 32 * s + 10,
          top: 0,
          bottom: 0,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: .52),
                    Colors.black.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _bottomBar({required bool compact}) {
    return FsBottomBar(
      position: _position,
      duration: _duration,
      buffered: _buffered,
      playing: _playing,
      rate: _rate,
      // 清晰度 / 线路只对在线播放有意义：空串即不显示入口。
      qualityLabel: '',
      compact: compact,
      onSeek: (position) => unawaited(_seek(position)),
      onTogglePlay: () => unawaited(_playOrPause()),
      onNext: _playNextEpisode,
      onEpisodes: () => unawaited(_openEpisodeSheet()),
      onMore: () => unawaited(_openSettingsSheet()),
      onExit: () => unawaited(_leave()),
    );
  }

  /// 下一集：只在已下载的集之间切；没有了就提示一句。
  void _playNextEpisode() {
    final next = _nextEpisode();
    if (next == null) {
      _toast('已经是最后一集已下载的集');
      return;
    }
    unawaited(_switchTo(next, reason: '下一集'));
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
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _openSeq++;
    _hideTimer?.cancel();
    _sleepTimer?.cancel();
    _unlockTimer?.cancel();
    final player = _player;
    _player = null;
    if (player != null) {
      player.removeListener(_onPlayer);
      unawaited(player.dispose());
    }
    if (_position > Duration.zero) {
      unawaited(_savePosition());
    }
    // 打开即横屏：任何退出路径（按钮、返回键、外层 pop）都要恢复竖屏。
    unawaited(_restorePortrait());
    _service.removeListener(_onServiceChanged);
    super.dispose();
  }
}

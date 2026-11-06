import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_settings.dart';
import '../services/download_service.dart';
import '../services/fx_display_settings.dart';
import '../services/fx_player.dart';
import '../theme.dart';
import '../widgets/player_gestures.dart';
import '../widgets/player_theme.dart'
    show
        FxLoadingOverlay,
        FxPlayerSurface,
        FxSeekRow,
        PGlassIcon,
        PGlassPill,
        fxLoadProgress,
        fxResumeMinSeconds,
        fxSaveProgress,
        kPlayerControlsAutoHide;

/// 离线播放页：用 media_kit（[FxPlayer]）打开已下载的本地文件。
///
/// 与全屏播放器共用同一套控件结构（顶栏 / 底栏 / 锁 / 选集 / 画面比例 /
/// 镜像 / 倍速 / 定时关闭），但**只连本地文件**：不显示线路、清晰度、
/// 下载、投屏这些在线才有意义的入口，也不请求 `/api/play`。
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

class _OfflinePlayerPageState extends State<OfflinePlayerPage> {
  final DownloadService _service = DownloadService.instance;

  /// 当前正在播放的集：选集 / 自动连播会就地切换，不重新入栈页面。
  late DownloadTask _task = widget.task;

  FxPlayer? _player;
  bool _loading = true;
  String? _error;
  bool _fullscreen = false;
  bool _controlsVisible = true;
  bool _playing = false;
  bool _switching = false;
  bool _endedHandled = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  double _rate = 1;

  /// 切集 / 打开后时长还没出来时挂起的续播点（秒）。
  int? _pendingSeek;

  /// 锁屏：锁定后只留一个解锁钮，点画面只做解锁钮的显隐切换。
  bool _locked = false;
  bool _unlockVisible = true;

  /// 该剧全部任务（选集面板用：已下载可直接切，其它显示状态）。
  List<DownloadTask> _episodes = const <DownloadTask>[];

  Timer? _hideTimer;
  Timer? _sleepTimer;
  Timer? _unlockTimer;
  int _openSeq = 0;

  /// 设置面板打开期间用于刷新面板自身的选中态。
  void Function(void Function())? _setSheet;

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

  static const List<double> _rates = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChanged);
    _refreshEpisodes();
    unawaited(_prepareSettings());
    _open();
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
      await player.setLooping(false);
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
  void _armResume(double saved) {
    _pendingSeek = null;
    if (saved < fxResumeMinSeconds) return;
    final seconds = saved.round();
    if (_duration > Duration.zero) {
      if (seconds < _duration.inSeconds - 5) {
        unawaited(_player?.seek(Duration(seconds: seconds)));
      }
      return;
    }
    _pendingSeek = seconds;
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
    final pending = _pendingSeek;
    if (pending != null && value.duration > Duration.zero) {
      _pendingSeek = null;
      // 存的进度太靠近结尾就直接从头播，别卡在最后一秒。
      if (pending < value.duration.inSeconds - 5) {
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
            activeColor: Colors.white,
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
    final bottom = MediaQuery.paddingOf(context).bottom;
    final total = _totalEpisodes;
    final current = _task.ep;
    return Container(
      height: MediaQuery.sizeOf(context).height * .58,
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
                _controls(player),
              if (_locked) _lockedLayer(),
            ],
          ),
        ),
      ),
    );
  }

  /// 锁屏层：点画面只切解锁钮显隐，解锁钮在最上面单独接点击。
  Widget _lockedLayer() {
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onLockedTap,
          child: const ColoredBox(color: Colors.transparent),
        ),
        IgnorePointer(
          ignoring: !_unlockVisible,
          child: AnimatedOpacity(
            opacity: _unlockVisible ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            child: Align(
              alignment: const Alignment(-.9, 0),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _unlock,
                child: Opacity(
                  opacity: .7,
                  child: PGlassIcon(
                    icon: Icons.lock_rounded,
                    size: 44,
                    iconSize: 21,
                    tint: .14,
                    tooltip: '点击解锁',
                    onTap: _unlock,
                  ),
                ),
              ),
            ),
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

  /// 完整控件结构（对齐全屏播放器）：顶栏 返回·剧名·集数·⋯设置，
  /// 中部 锁 / ±10 秒，底部 进度 · 播放暂停 · 选集 · 全屏。
  Widget _controls(FxPlayer player) {
    return AnimatedOpacity(
      opacity: _controlsVisible ? 1 : 0,
      duration: const Duration(milliseconds: 180),
      child: IgnorePointer(
        ignoring: !_controlsVisible,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Align(alignment: Alignment.topCenter, child: _topBar()),
            Positioned.fill(child: _sideControls()),
            Align(alignment: Alignment.bottomCenter, child: _bottomBar(player)),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    final task = _task;
    return Container(
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
            tooltip: '返回',
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
                    shadows: [Shadow(color: Colors.black54, blurRadius: 3)],
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
                        style: TextStyle(fontSize: 8.5, color: Colors.white),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        '${task.epLabel} · ${task.sizeLabel}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(fontSize: 10, color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          PGlassIcon(
            icon: Icons.more_horiz_rounded,
            iconSize: 21,
            tooltip: '播放设置',
            onTap: () => unawaited(_openSettingsSheet()),
          ),
        ],
      ),
    );
  }

  Widget _sideControls() {
    return Stack(
      children: [
        Positioned(
          left: 14,
          top: 0,
          bottom: 0,
          child: Center(
            child: PGlassIcon(
              icon: Icons.lock_outline_rounded,
              size: 42,
              iconSize: 21,
              tint: .16,
              tooltip: '锁定屏幕',
              onTap: _lock,
            ),
          ),
        ),
        Positioned(
          right: 14,
          top: 0,
          bottom: 0,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PGlassIcon(
                  icon: Icons.forward_10_rounded,
                  size: 44,
                  iconSize: 23,
                  tint: .16,
                  tooltip: '快进 10 秒',
                  onTap: () => unawaited(_seekBy(10)),
                ),
                const SizedBox(height: 22),
                PGlassIcon(
                  icon: Icons.replay_10_rounded,
                  size: 44,
                  iconSize: 23,
                  tint: .16,
                  tooltip: '后退 10 秒',
                  onTap: () => unawaited(_seekBy(-10)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _bottomBar(FxPlayer player) {
    final downloaded = _downloaded.length;
    return Container(
      padding: EdgeInsets.fromLTRB(14, 28, 14, 12),
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
          FxSeekRow(
            position: _position,
            duration: _duration,
            buffered: _buffered,
            onSeek: (position) => unawaited(_seek(position)),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              PGlassIcon(
                icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: 44,
                iconSize: 25,
                tooltip: _playing ? '暂停' : '播放',
                onTap: () => unawaited(_playOrPause()),
              ),
              const SizedBox(width: 10),
              const Spacer(),
              PGlassPill(
                onTap: () => unawaited(_openEpisodeSheet()),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.playlist_play_rounded,
                        size: 14, color: Colors.white),
                    const SizedBox(width: 4),
                    Text(
                      downloaded > 0 ? '选集 $downloaded' : '选集',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              PGlassIcon(
                icon: _fullscreen
                    ? Icons.fullscreen_exit_rounded
                    : Icons.fullscreen_rounded,
                size: 36,
                iconSize: 19,
                tooltip: _fullscreen ? '退出全屏' : '全屏',
                onTap: () => unawaited(_toggleFullscreen()),
              ),
            ],
          ),
        ],
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
  void dispose() {
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
    if (_fullscreen) {
      unawaited(_restorePortrait());
    }
    _service.removeListener(_onServiceChanged);
    super.dispose();
  }
}

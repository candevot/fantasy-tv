import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../services/fx_player.dart';
import '../theme.dart';
import '../widgets/player_gestures.dart';
import '../widgets/player_theme.dart';
import 'fullscreen_page.dart';
import 'history_page.dart' show FxStore;

/// 当前线路不能直接播放的原因，交给外层决定换线路与提示文案。
enum SourceIssue { parse, empty, error }

/// 详情页内嵌播放器（16:9），也是独立播放页复用的播放控件。
///
/// 控件布局（竖屏只保留 5 项）：
/// 左上 返回；右上 投屏
/// 底部 播放暂停 · 当前时间 · 细进度条 · 总时长 · 全屏
/// 3 秒无操作自动隐藏；点画面唤出/隐藏；双击暂停。
/// 长按倍速、亮度/音量手势、锁屏等只在全屏提供。
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
    this.onSourceIssue,
    this.onPlaybackStarted,
    this.onChangeLine,
    this.onLineFallback,
    this.onSwitchingChanged,
    this.autoPlay = true,
  });

  final String videoId;
  final int ep;
  final String line;
  final VideoDetail? detail;
  final ValueChanged<int>? onEpChange;
  final VoidCallback? onFullscreen;
  final VoidCallback? onSourceFailed;

  /// 接口返回解析页（type == 'parse'）或没有直链地址时回调，
  /// 由外层按原因切下一线路并展示对应文案。
  final ValueChanged<SourceIssue>? onSourceIssue;
  final VoidCallback? onPlaybackStarted;
  final VoidCallback? onChangeLine;

  /// 切线路结束（成功或失败）后回调实际生效的线路 id，外层据此同步高亮，
  /// 避免自动尝试下一条线路时 UI 仍指着失败线路。
  final ValueChanged<String>? onLineFallback;

  /// 线路切换开关状态：为 true 时外层应禁用线路卡片，避免重复点击并发 open。
  final ValueChanged<bool>? onSwitchingChanged;

  final bool autoPlay;

  @override
  State<PlayerView> createState() => PlayerViewState();
}

class PlayerViewState extends State<PlayerView> with WidgetsBindingObserver {
  /// 单次 open 等待 ready 的上限：超过即视为该地址不可播，避免黑屏空等。
  static const Duration _openReadyTimeout = Duration(seconds: 8);

  /// 切线路时最多尝试的线路数（含用户选中的目标线路）。
  static const int _maxLineAttempts = 2;

  /// 看门狗：每 3 秒检查一次，连续 12 秒位置不前进即尝试自愈。
  static const Duration _watchdogTick = Duration(seconds: 3);
  static const Duration _watchdogStall = Duration(seconds: 12);

  /// 竖屏控件 3 秒无操作自动隐藏。
  static const Duration _controlsAutoHide = Duration(seconds: 3);

  FxPlayer? _controller;
  PlayInfo? _info;

  late int _ep;
  late String _line;
  int _loadToken = 0;

  /// controller 实际已经打开的集。进度只写这一集，loading 时不写。
  int? _loadedEp;

  /// 全屏内选择的清晰度，退出全屏时随结果带回。
  String? _qualityKey;

  bool _loading = true;
  bool _error = false;
  String _errorText = '';
  bool _sourceFailNotified = false;
  bool _ended = false;

  bool _controls = true;
  Timer? _hideTimer;

  /// 正在切换线路（防止重复点击并发 open）。
  bool _switchingLine = false;
  int? _pendingEp;

  /// 看门狗：播放中位置长时间不动时自愈一次，再失败自动换下一条线路。
  Timer? _watchdogTimer;
  Duration _watchdogLastPosition = Duration.zero;
  DateTime _watchdogLastAdvance = DateTime.now();
  bool _watchdogBusy = false;
  bool _watchdogRetried = false;

  /// 自愈成功后等 position 真正前进，再提示「已自动恢复」。
  bool _watchdogRecoverPending = false;

  /// 切换期间锁住 UI 进度，避免新播放器 open 时进度归零。
  Duration? _uiPosition;
  Duration? _uiDuration;
  String? _loadingHint;

  /// 每 10 秒把观看进度回写历史，App 被杀也能保留大致位置。
  Timer? _progressTimer;

  /// 切后台 3 秒后才暂停；通知栏 / 截屏只到 inactive，不打断播放。
  Timer? _backgroundTimer;
  bool _backgrounded = false;
  bool _pausedByBackground = false;

  /// 进入全屏时随结果带回的真实倍速，切集时沿用。
  double _rate = 1.0;

  /// 全屏画面是否撑满（cover）。默认开；关掉后全屏 contain。
  bool _fillScreen = true;

  bool _openingFullscreen = false;
  bool _fullscreenActive = false;

  /// 详情页被另一层详情覆盖中：此时 bootstrap 完成后不要自动出声。
  bool _covered = false;

  int get _episodeCount {
    final d = widget.detail;
    if (d == null) return 0;
    final n = d.allEpisodes.length;
    return n > 0 ? n : d.episodes;
  }

  /// 全屏和自动连播共用的剧集列表；只有集数没有名字时也补齐。
  List<Episode> get _episodeList {
    final d = widget.detail;
    if (d == null) return const <Episode>[];
    if (d.allEpisodes.isNotEmpty) return d.allEpisodes;
    return <Episode>[for (var i = 1; i <= d.episodes; i++) Episode(i, '', 0)];
  }

  String get _title {
    final t = widget.detail?.title ?? '';
    return t.isEmpty ? '正在播放' : t;
  }

  String _epLabelFor(int n) {
    for (final e in _episodeList) {
      if (e.n == n) return fxEpisodeLabel(e.n, e.name);
    }
    return fxEpisodeLabel(n);
  }

  /// 当前线路名：优先用接口返回的线路名，其次从详情线路表里按 id 查。
  String get _lineName {
    final infoName = _info?.lineName.trim() ?? '';
    if (infoName.isNotEmpty) return infoName;
    for (final line in widget.detail?.lines ?? const <LineInfo>[]) {
      if (line.id == _line) return line.displayName;
    }
    return '';
  }

  @override
  void initState() {
    super.initState();
    _ep = widget.ep;
    _line = widget.line;
    WidgetsBinding.instance.addObserver(this);
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      // 全屏期间由全屏页保存，避免把全屏切换后的位置记到旧集。
      if (!mounted || _fullscreenActive) return;
      unawaited(_saveProgress());
    });
    _watchdogTimer = Timer.periodic(_watchdogTick, (_) => _checkWatchdog());
    unawaited(_loadFillScreen());
    _bootstrap(seekToSaved: true, saveOld: false);
  }

  Future<void> _loadFillScreen() async {
    final value = await fxLoadFillScreen();
    if (!mounted) return;
    setState(() => _fillScreen = value);
  }

  @override
  void didUpdateWidget(covariant PlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.ep == _ep && widget.line == _line) return;
    if (widget.line != _line) {
      // 切线路：记住当前集+进度，就绪后 seek 回并恢复播放；
      // 目标线路失败会自动尝试下一条，最多 2 条。
      unawaited(_switchLine(widget.line, widget.ep));
      return;
    }
    if (widget.ep != _ep) {
      unawaited(_switchEpisodeFromParent(widget.ep));
    }
  }

  Future<void> _switchEpisodeFromParent(int next) async {
    if (_switchingLine) {
      _pendingEp = next;
      return;
    }
    if (next == _ep) return;
    await _saveProgress();
    if (!mounted) return;
    // 作废旧请求，防止旧集晚到的位置写进新集。
    _loadToken++;
    unawaited(_controller?.pause());
    setState(() {
      _ep = next;
      _loading = true;
      _loadedEp = null;
      _qualityKey = null;
      _error = false;
      _errorText = '';
      _ended = false;
      _sourceFailNotified = false;
      _loadingHint = null;
      _uiPosition = null;
      _uiDuration = null;
    });
    await _bootstrap(
      seekToSaved: true,
      saveOld: false,
      epOverride: next,
      playOverride: widget.autoPlay && !_covered,
    );
  }

  Future<void> _switchLine(String targetLine, int targetEp) async {
    if (_switchingLine) {
      // 切换中禁止重复点击：直接忽略新的线路请求，绝不允许并发 open。
      return;
    }
    _switchingLine = true;
    widget.onSwitchingChanged?.call(true);
    _watchdogRecoverPending = false;
    final old = _controller;
    final healthy = old != null &&
        old.value.isInitialized &&
        !old.value.hasError &&
        !_error;
    final wasPlaying = healthy && old.value.isPlaying;
    final resume = healthy ? old.value.position : Duration.zero;
    final oldDuration = old?.value.duration;
    var resumeSeconds = resume.inMilliseconds / 1000.0;

    try {
      // 先保存旧线路进度（此刻还没进入 loading，_saveProgress 才会生效）。
      await _saveProgress();
      if (!mounted) return;

      if (!healthy) {
        resumeSeconds = await fxLoadProgress(widget.videoId, targetEp);
        if (!mounted) return;
      }

      _loadToken++;
      unawaited(old?.pause());
      _hideTimer?.cancel();
      setState(() {
        _loading = true;
        _loadingHint = '正在切换线路，请稍候';
        _uiPosition = Duration(milliseconds: (resumeSeconds * 1000).round());
        _uiDuration = oldDuration;
        _error = false;
        _errorText = '';
        _sourceFailNotified = false;
        _ended = false;
      });

      // 目标线路失败时自动尝试下一条，最多 2 条；全失败才进入错误态。
      final attempts = _lineAttempts(targetLine);
      String? actualLine;
      for (final candidate in attempts) {
        if (!mounted) return;
        final ok = await _bootstrap(
          seekToSaved: false,
          saveOld: false,
          lineOverride: candidate,
          epOverride: targetEp,
          resumeSeconds: resumeSeconds,
          playOverride: wasPlaying,
          commitLine: true,
          reportFailure: false,
        );
        if (!mounted) return;
        if (ok) {
          actualLine = candidate;
          break;
        }
      }

      if (actualLine != null) {
        setState(() {
          _loadingHint = null;
          _uiPosition = null;
          _uiDuration = null;
        });
        _resetWatchdogClock();
        _watchdogRetried = false;
        _showControls();
        fxToast(
          context,
          actualLine == targetLine ? '已切换线路' : '已自动切换到可用线路',
        );
        // 自动尝试下一条成功时同步外层高亮，避免 UI 仍指着失败线路。
        widget.onLineFallback?.call(actualLine);
      } else {
        // 两条线路都失败：停在最后尝试的线路，错误页的重试按钮直接重试它。
        final lastTried = attempts.isEmpty ? targetLine : attempts.last;
        _line = lastTried;
        setState(() {
          _loading = false;
          _loadingHint = null;
          _loadedEp = null;
          _error = true;
          _errorText = '线路不可用，请重试或换线路';
          _uiPosition = null;
          _uiDuration = null;
        });
        _showControls();
        fxToast(context, '线路切换失败，请重试');
        widget.onLineFallback?.call(lastTried);
      }
    } finally {
      if (mounted) {
        setState(() => _switchingLine = false);
      } else {
        _switchingLine = false;
      }
      widget.onSwitchingChanged?.call(false);
      // 切换期间点过的下一集：等本次切换结束再执行，不并发 open。
      final pendingEp = _pendingEp;
      _pendingEp = null;
      if (mounted && pendingEp != null && pendingEp != _ep) {
        unawaited(_switchEpisodeFromParent(pendingEp));
      }
    }
  }

  /// 当前线路 + 下一条线路（最多 2 条），用于失败后的自动兜底。
  List<String> _lineAttempts(String targetLine) {
    final lines = widget.detail?.lines ?? const <LineInfo>[];
    final attempts = <String>[];
    if (targetLine.isNotEmpty) attempts.add(targetLine);
    var index = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].id == targetLine) {
        index = i;
        break;
      }
    }
    for (var step = 0;
        step < lines.length && attempts.length < _maxLineAttempts;
        step++) {
      final candidate =
          index >= 0 ? lines[(index + 1 + step) % lines.length] : lines[step];
      if (candidate.id.isEmpty || attempts.contains(candidate.id)) continue;
      attempts.add(candidate.id);
    }
    return attempts.take(_maxLineAttempts).toList(growable: false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 全屏期间由全屏页负责保存进度与暂停，避免同一实例被重复处理。
    if (_fullscreenActive) return;
    switch (state) {
      case AppLifecycleState.inactive:
        // 下拉通知栏 / 截屏 / 多任务预览都只到 inactive：不暂停。
        return;
      case AppLifecycleState.paused:
        // 来电 / 切后台：先记进度，3 秒内回前台就不暂停。
        _backgrounded = true;
        unawaited(_saveProgress());
        _backgroundTimer?.cancel();
        _backgroundTimer = Timer(fxBackgroundPauseDelay, _pauseForBackground);
        return;
      case AppLifecycleState.resumed:
        _backgrounded = false;
        _backgroundTimer?.cancel();
        _backgroundTimer = null;
        _resumeAfterBackground();
        return;
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        return;
    }
  }

  void _pauseForBackground() {
    _backgroundTimer = null;
    if (!mounted || !_backgrounded || _fullscreenActive) return;
    final c = _controller;
    if (c == null || !c.value.isInitialized || !c.value.isPlaying) return;
    _pausedByBackground = true;
    unawaited(_saveProgress());
    unawaited(c.pause());
  }

  void _resumeAfterBackground() {
    if (!_pausedByBackground) return;
    _pausedByBackground = false;
    if (!mounted || _fullscreenActive || _loading || _error || _covered) return;
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    unawaited(c.play());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _progressTimer?.cancel();
    _backgroundTimer?.cancel();
    _watchdogTimer?.cancel();
    _loadToken++;
    unawaited(_saveProgress());
    _controller?.removeListener(_onVideoValue);
    _controller?.dispose();
    super.dispose();
  }

  /// 保存进度。只写 controller 实际打开的集；新集加载期间直接跳过，
  /// 防止切集/双击下一集时把旧集的 position 写进新集。
  Future<void> _saveProgress({bool ended = false}) async {
    // loading / 播放出错时位置不可信（可能已归零），不要拿它覆盖历史进度。
    if (_loading || _error) return;
    final c = _controller;
    final ep = _loadedEp;
    if (c == null || ep == null || !c.value.isInitialized) return;
    final durationMs = c.value.duration.inMilliseconds;
    final rawPosition = c.value.position.inMilliseconds;
    final positionMs = durationMs > 0
        ? (rawPosition < 0
            ? 0
            : (rawPosition > durationMs ? durationMs : rawPosition))
        : (rawPosition < 0 ? 0 : rawPosition);
    var seconds = ended ? 0.0 : positionMs / 1000.0;
    if (!ended && durationMs > 0 && positionMs >= durationMs - 1500) {
      seconds = 0;
    }
    await fxSaveProgress(widget.videoId, ep, seconds);
    // 同一份进度回写历史页（FxStore.historyKey），让「观看历史」进度条可见。
    await FxStore.updateProgress(
      id: widget.videoId,
      ep: ep,
      epName: _epLabelFor(ep),
      lineId: _line,
      lineName: _lineName,
      position: positionMs ~/ 1000,
      duration: durationMs <= 0 ? 0 : durationMs ~/ 1000,
    );
  }

  /// 详情页被新页面覆盖前调用：暂停并保存，返回覆盖前是否正在播放。
  Future<bool> pauseAndSave() async {
    if (_fullscreenActive) return false;
    _covered = true;
    final c = _controller;
    final wasPlaying = c != null && c.value.isInitialized && c.value.isPlaying;
    await _saveProgress();
    try {
      await c?.pause();
    } catch (_) {}
    return wasPlaying;
  }

  /// 从被覆盖的详情页返回后恢复播放；原本暂停的保持暂停。
  Future<void> resumeAfterCover({required bool play}) async {
    if (_fullscreenActive) return;
    _covered = false;
    if (!play) return;
    final c = _controller;
    if (c == null || !c.value.isInitialized || _loading || _error) return;
    try {
      await c.play();
    } catch (_) {}
  }

  /// 进入一起看房间前调用：暂停并彻底释放当前播放器，
  /// 避免房间内同时存在详情页播放器和一起看播放器（不是静音）。
  Future<void> pauseAndReleaseForTogether() async {
    _loadToken++;
    _hideTimer?.cancel();
    await _saveProgress();
    final controller = _controller;
    _controller = null;
    _loadedEp = null;
    if (controller != null) {
      controller.removeListener(_onVideoValue);
      try {
        await controller.pause();
      } catch (_) {}
      try {
        await controller.dispose();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = false;
      _errorText = '';
    });
  }

  /// 从一起看房间返回后调用：重新加载播放器并恢复进度。
  Future<void> resumeAfterTogether() async {
    if (!mounted) return;
    await _bootstrap(seekToSaved: true, saveOld: false);
  }

  Future<bool> _bootstrap({
    required bool seekToSaved,
    bool saveOld = true,
    String? lineOverride,
    int? epOverride,
    double? resumeSeconds,
    bool? playOverride,
    bool commitLine = false,
    bool reportFailure = true,
  }) async {
    final line = lineOverride ?? _line;
    final ep = epOverride ?? _ep;
    final token = ++_loadToken;
    _hideTimer?.cancel();
    if (saveOld) await _saveProgress();
    if (!mounted || token != _loadToken) return false;
    unawaited(_controller?.pause());
    setState(() {
      _loading = true;
      _loadedEp = null;
      _qualityKey = null;
      _error = false;
      _errorText = '';
      _sourceFailNotified = false;
      _ended = false;
    });

    PlayInfo info;
    try {
      info = await Api.play(widget.videoId, ep, line);
    } catch (_) {
      if (!mounted || token != _loadToken) return false;
      setState(() {
        _loading = false;
        _loadingHint = null;
        if (reportFailure) {
          _error = true;
          _errorText = '获取播放地址失败，请检查网络后重试';
        }
      });
      if (reportFailure) _notifySourceFailed();
      return false;
    }
    if (!mounted || token != _loadToken) return false;
    _info = info;

    // TW 等线路可能返回一个需要解析器处理的播放页地址（type == 'parse'）。
    // 空 url 与解析页是两种不同情况，分开交给外层展示文案。
    final isParse = info.type.trim().toLowerCase() == 'parse';
    if (isParse) {
      if (reportFailure) {
        _emitSourceIssue(SourceIssue.parse);
      } else {
        setState(() {
          _loading = false;
          _loadingHint = null;
        });
      }
      return false;
    }

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
      if (reportFailure) {
        _emitSourceIssue(SourceIssue.empty);
      } else {
        setState(() {
          _loading = false;
          _loadingHint = null;
        });
      }
      return false;
    }

    final saved = resumeSeconds ??
        (seekToSaved ? await fxLoadProgress(widget.videoId, ep) : 0.0);
    if (!mounted || token != _loadToken) return false;
    final shouldPlay = playOverride ?? (widget.autoPlay && !_covered);

    var ok = false;
    for (final url in candidates) {
      if (!mounted || token != _loadToken) return false;
      final controller = FxPlayer.create();
      try {
        // 8 秒拿不到可播状态就判这条地址失败，避免黑屏一直转圈。
        await controller
            .open(url, headers: info.headers)
            .timeout(_openReadyTimeout);
        if (!mounted || token != _loadToken) {
          await controller.dispose();
          return false;
        }
        await controller.setLooping(false);
        try {
          await controller.setRate(_rate);
        } catch (_) {}
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
        if (shouldPlay) {
          await controller.play();
        } else {
          // 暂停态也先拉一帧再暂停，切线路后不黑屏。
          await controller.play();
          await Future<void>.delayed(const Duration(milliseconds: 60));
          await controller.pause();
        }
        // 初始化期间被新操作取代：释放新实例，不要把旧 controller 挂回。
        if (!mounted || token != _loadToken) {
          await controller.dispose();
          return false;
        }
        final previous = _controller;
        previous?.removeListener(_onVideoValue);
        _controller = controller;
        _ep = ep;
        if (commitLine) _line = line;
        _loadedEp = ep;
        controller.addListener(_onVideoValue);
        unawaited(previous?.dispose());
        setState(() {
          _loading = false;
          _loadingHint = null;
          _error = false;
          _errorText = '';
        });
        _sourceFailNotified = false;
        ok = true;
        _resetWatchdogClock();
        widget.onPlaybackStarted?.call();
        _showControls();
        break;
      } catch (_) {
        try {
          controller.dispose();
        } catch (_) {}
      }
    }

    if (!ok) {
      if (!mounted || token != _loadToken) return false;
      setState(() {
        _loading = false;
        _loadingHint = null;
        if (reportFailure) {
          _error = true;
          _errorText = '播放失败：线路不可用，请重试或切换下方线路';
        }
      });
      if (reportFailure) _notifySourceFailed();
      return false;
    }
    return true;
  }

  void _emitSourceIssue(SourceIssue issue) {
    final callback = widget.onSourceIssue;
    if (callback != null) {
      callback(issue);
      return;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = true;
      _errorText = switch (issue) {
        SourceIssue.parse => '该线路暂不可直接播放，请切换线路',
        SourceIssue.empty => '当前线路没有可用播放地址，请切换线路',
        SourceIssue.error => '线路播放失败，请切换线路',
      };
    });
    _notifySourceFailed();
  }

  void _notifySourceFailed() {
    if (_sourceFailNotified) return;
    _sourceFailNotified = true;
    widget.onSourceFailed?.call();
  }

  /* -------------------------------------------------------------- 看门狗 */

  /// 播放中位置连续 12 秒不前进（仍在 buffering / 应该播放）时尝试自愈：
  /// 先重新 open 当前地址一次，仍失败或再次报错则自动切下一条线路。
  void _checkWatchdog() {
    if (!mounted || _fullscreenActive || _watchdogBusy) return;
    if (_loading || _error || _switchingLine || _backgrounded) {
      _resetWatchdogClock();
      return;
    }
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      _resetWatchdogClock();
      return;
    }
    final v = c.value;
    if (v.isCompleted) {
      _resetWatchdogClock();
      return;
    }
    // ready 之后 hasError 也必须走看门狗，而不是直接锁死错误页。
    if (v.hasError) {
      unawaited(_recoverFromWatchdog());
      return;
    }
    if (!v.isPlaying && !v.isBuffering) {
      _resetWatchdogClock();
      return;
    }
    // 位置前进了：播放恢复健康，播过自愈提示后重新计数。
    if ((v.position - _watchdogLastPosition).abs() >
        const Duration(milliseconds: 300)) {
      _watchdogLastPosition = v.position;
      _watchdogLastAdvance = DateTime.now();
      _watchdogRetried = false;
      if (_watchdogRecoverPending) {
        _watchdogRecoverPending = false;
        if (mounted) fxToast(context, '已自动恢复');
      }
      return;
    }
    _watchdogLastPosition = v.position;
    if (DateTime.now().difference(_watchdogLastAdvance) < _watchdogStall) {
      return;
    }
    unawaited(_recoverFromWatchdog());
  }

  void _resetWatchdogClock() {
    _watchdogLastPosition = _controller?.value.position ?? Duration.zero;
    _watchdogLastAdvance = DateTime.now();
  }

  Future<void> _recoverFromWatchdog() async {
    if (!mounted || _watchdogBusy || _switchingLine) return;
    if (_watchdogRetried) {
      await _watchdogNextLine();
      return;
    }
    final c = _controller;
    if (c == null) return;
    final resume = c.value.position;
    _watchdogRetried = true;
    _watchdogBusy = true;
    try {
      // 重新 open 当前线路（含备用地址），成功后等 position 前进再提示恢复。
      final ok = await _bootstrap(
        seekToSaved: false,
        saveOld: false,
        resumeSeconds: resume.inMilliseconds / 1000.0,
        playOverride: true,
        reportFailure: false,
      );
      if (!mounted) return;
      if (ok) {
        _watchdogRecoverPending = true;
        _resetWatchdogClock();
      } else {
        await _watchdogNextLine();
      }
    } finally {
      _watchdogBusy = false;
    }
  }

  /// 看门狗自愈失败：切下一条线路；没有下一条才显示错误 + 重试。
  Future<void> _watchdogNextLine() async {
    if (!mounted) return;
    final lines = widget.detail?.lines ?? const <LineInfo>[];
    String? next;
    if (lines.length > 1) {
      final index = lines.indexWhere((l) => l.id == _line);
      next = lines[(index < 0 ? 0 : index + 1) % lines.length].id;
      if (next == _line) next = null;
    }
    if (next == null || next.isEmpty) {
      setState(() {
        _loading = false;
        _loadingHint = null;
        _loadedEp = null;
        _error = true;
        _errorText = '播放中断，自动恢复失败，请重试或切换线路';
        _uiPosition = null;
        _uiDuration = null;
      });
      _showControls();
      return;
    }
    // 新线路有自己的自愈额度，避免一条坏线路反复重试。
    _watchdogRetried = false;
    await _switchLine(next, _ep);
  }

  void _onVideoValue() {
    final c = _controller;
    if (c == null || !mounted) return;
    // 全屏期间由全屏页接管同一个播放器的事件（切集 / 结束 / 报错）；
    // loading 期间的错误由 _bootstrap 的 try/catch 处理。
    if (_fullscreenActive || _loading || _error) return;
    final v = c.value;
    if (v.hasError) {
      // ready 后出错不直接锁死：交给看门狗重开当前地址 / 切线路。
      unawaited(_recoverFromWatchdog());
      return;
    }
    if (!v.isInitialized) return;
    if (!v.isCompleted) {
      _ended = false;
      return;
    }
    if (_ended) return;
    _ended = true;
    unawaited(_handleEnded());
  }

  Future<void> _handleEnded() async {
    await _saveProgress(ended: true);
    if (!mounted) return;
    final next = _nextEpNumber();
    if (next != null) {
      await _switchEpisode(next, auto: true);
    } else {
      setState(() => _controls = true);
      _startHideTimer();
      fxToast(context, '已播放完最后一集');
    }
  }

  Future<void> _switchEpisode(int next, {bool auto = false}) async {
    if (next < 1 || _switchingLine) return;
    await _saveProgress();
    if (!mounted) return;
    setState(() {
      _ep = next;
      _loading = true;
      _loadedEp = null;
      _qualityKey = null;
      _error = false;
      _controls = true;
      _loadingHint = null;
      _uiPosition = null;
      _uiDuration = null;
    });
    widget.onEpChange?.call(next);
    if (auto) fxToast(context, '即将播放 ${_epLabelFor(next)}');
    await _bootstrap(
      seekToSaved: true,
      saveOld: false,
      epOverride: next,
      playOverride: !_covered,
    );
  }

  int? _nextEpNumber() {
    final list = _episodeList;
    if (list.isNotEmpty) {
      final index = list.indexWhere((e) => e.n == _ep);
      if (index >= 0) {
        if (index + 1 >= list.length) return null;
        return list[index + 1].n;
      }
    }
    final total = _episodeCount;
    // 没有明确集数时按单片处理，播完就停，不再无限跳下一集。
    if (total <= 0 || _ep >= total) return null;
    return _ep + 1;
  }

  /// 详情页「刷新」/错误重试可以调用
  Future<void> reload() async {
    if (_switchingLine) return;
    await _saveProgress();
    if (!mounted) return;
    await _bootstrap(seekToSaved: true, saveOld: false);
  }

  /// 详情页试完全部线路仍不可播时调用，展示错误与重试/换线路按钮。
  void showSourceError(String message) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = true;
      _errorText = message;
      _sourceFailNotified = true;
    });
  }

  // ---------------------------------------------------------------- controls

  void _showControls() {
    if (!mounted) return;
    setState(() => _controls = true);
    _startHideTimer();
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_controlsAutoHide, () {
      if (!mounted) return;
      if (_openingFullscreen) {
        // 正在进入全屏，等全屏页接管后再由页面恢复显隐。
        _startHideTimer();
        return;
      }
      if (_loading || _error || _switchingLine) return;
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
    if (_error) return;
    // 加载 / 切集期间也能显隐控件，不因为 loading 把整层点击吞掉。
    if (_controls) {
      _hideControls();
    } else {
      _showControls();
    }
  }

  void _togglePlay() {
    final c = _controller;
    if (_switchingLine ||
        c == null ||
        _loading ||
        _error ||
        !c.value.isInitialized) {
      return;
    }
    // 以播放器真实状态为准：交给 media_kit 切换，按钮图标随后续
    // player.stream.playing 事件刷新，不用本地布尔抢先改状态。
    unawaited(c.playOrPause());
    _touch();
  }

  void _seek(Duration d) {
    final c = _controller;
    if (_switchingLine || c == null || _loading || _error) return;
    c.seekTo(d);
    _touch();
  }

  Future<void> _openFullscreen() async {
    final c = _controller;
    if (c == null ||
        _openingFullscreen ||
        _switchingLine ||
        _loading ||
        _error ||
        !c.value.isInitialized) {
      return;
    }
    _openingFullscreen = true;
    _hideTimer?.cancel();
    // 进入全屏时复用同一个 FxPlayer / Player 实例：不重新 open，
    // 保持当前进度与播放/暂停状态；竖屏画面暂时让出视频输出。
    final token = _loadToken;
    final realRate = c.rate;
    await _saveProgress();
    // 等待保存期间可能开始切集/换线路，旧实例随时会被释放：
    // 必须确认还是同一个已加载完成的 controller 才能交给全屏。
    if (!mounted ||
        token != _loadToken ||
        _loading ||
        !identical(c, _controller) ||
        !c.value.isInitialized) {
      _openingFullscreen = false;
      return;
    }
    setState(() => _fullscreenActive = true);

    FullPlayerResult? result;
    try {
      result = await Navigator.of(context).push<FullPlayerResult>(
        PageRouteBuilder<FullPlayerResult>(
          transitionDuration: const Duration(milliseconds: 260),
          pageBuilder: (context, animation, secondaryAnimation) =>
              FullPlayerPage(
            player: c,
            videoId: widget.videoId,
            ep: _ep,
            line: _line,
            title: _title,
            playInfo: _info,
            episodes: _episodeList,
            lineName: _info?.lineName ?? '',
            rate: realRate,
            qualityKey: _qualityKey,
            canChangeLine: widget.onChangeLine != null,
            fillScreen: _fillScreen,
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      );
    } finally {
      _openingFullscreen = false;
    }
    if (!mounted) return;

    if (result != null) {
      // 全屏里切了集且成功打开：同一个播放器实例已经加载新集，才同步集数；
      // 打开失败时 result.loaded=false，不能把「没加载的集」记成已加载。
      final switched = result.ep != _ep;
      if (result.loaded) {
        _ep = result.ep;
        _loadedEp = result.ep;
        _info = result.info ?? _info;
      }
      _qualityKey = result.qualityKey;
      if (result.fillScreen != _fillScreen) {
        _fillScreen = result.fillScreen;
        unawaited(fxSaveFillScreen(_fillScreen));
      }
      if (result.rate > 0) {
        _rate = result.rate;
        try {
          await c.setRate(_rate);
        } catch (_) {}
      }
      if (switched && result.loaded) widget.onEpChange?.call(result.ep);
      if (result.requestLineChange) {
        // 全屏错误页点了「换线路」：退出后切下一条线路。
        widget.onChangeLine?.call();
      }
    }
    // 先同步完集数/进度归属，再交回视频层并恢复监听，避免全屏里
    // 已经换集时把新位置记到旧集。
    if (mounted && _fullscreenActive) {
      setState(() => _fullscreenActive = false);
    }
    if (c.value.hasError && !_error) {
      // 全屏里播放器已坏，位置可能被重置为 0；不要再拿它覆盖原进度。
      _loadedEp = null;
      setState(() {
        _error = true;
        _errorText = '播放中断，请重试或切换线路';
      });
    } else {
      _showControls();
    }
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
            if (c != null && c.value.isInitialized && !_fullscreenActive)
              SizedBox.expand(
                child: FxPlayerSurface(
                  player: c,
                  fit: BoxFit.contain,
                  subtitleBottom: fxSubtitleMinBottom,
                ),
              ),
            // 手势层：单击显隐控件 / 双击暂停 / 左右滑调进度。
            // 亮度音量上下滑与长按倍速只在全屏提供。
            if (c != null)
              Positioned.fill(
                child: FxPlayerGestures(
                  player: c,
                  enabled: !_error,
                  enableVertical: false,
                  onTap: _onSurfaceTap,
                  onDoubleTap: _togglePlay,
                  onSeek: _seek,
                  onGestureStart: _hideControls,
                ),
              ),
            // 播放中的缓冲：玻璃圆环 + 真实缓存百分比。
            // 缓冲 / 加载层在视频之上，但必须在控件层之下。
            if (!_loading && !_error && c != null)
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: c,
                  builder: (context, _) {
                    final v = c.value;
                    if (!v.isInitialized || !v.isBuffering) {
                      return const SizedBox.shrink();
                    }
                    final raw = v.bufferingPercentage.isFinite
                        ? v.bufferingPercentage
                        : 0.0;
                    final percent = raw.clamp(0.0, 100.0).toDouble();
                    return FxLoadingOverlay(
                      title: '缓冲中 ${percent.round()}%',
                      percent: percent,
                      dim: false,
                      compact: true,
                    );
                  },
                ),
              ),
            if (_loading && !_error) _buildLoading(),
            // 控件层压在 loading / 缓冲之上：切集 8s 窗口里也能退出全屏。
            // 只按控件显隐禁用指针，不因 loading 整层失效。
            if (_controls && !_error) _buildControls(c),
            if (_error) _buildError(),
          ],
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return Positioned.fill(
      child: FxLoadingOverlay(
        title: fxLoadingEpisodeText(_ep),
        subtitle: _loadingHint ?? _lineName,
        compact: true,
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

  Widget _buildControls(FxPlayer? c) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 18),
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
                const Spacer(),
                PGlassIcon(
                  icon: Icons.tv_rounded,
                  size: 31,
                  iconSize: 18,
                  tooltip: '投屏',
                  onTap: () => fxToast(context, '投屏：暂无可用设备'),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 24, 8, 6),
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
                      final shownPosition = _uiPosition ?? v.position;
                      final shownDuration =
                          (_uiDuration != null && _uiDuration! > Duration.zero)
                              ? _uiDuration!
                              : v.duration;
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
                          const SizedBox(width: 6),
                          Expanded(
                            child: FxSeekRow(
                              position: shownPosition,
                              duration: shownDuration,
                              buffered: v.buffered,
                              height: 3,
                              touchHeight: 34,
                              thumbSize: 15,
                              labelWidth: 40,
                              gap: 6,
                              timeFontSize: 10.5,
                              onSeek: _seek,
                            ),
                          ),
                          const SizedBox(width: 6),
                          PGlassIcon(
                            icon: Icons.fullscreen_rounded,
                            size: 30,
                            iconSize: 20,
                            tint: .13,
                            tooltip: '全屏',
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
      // 传进来的集数可能超出详情实际集数（历史脏数据 / 集数变化），按详情收敛。
      final eps = detail.allEpisodes.isNotEmpty
          ? detail.allEpisodes
          : <Episode>[
              for (var i = 1; i <= detail.episodes; i++) Episode(i, '', 0)
            ];
      var ep = _ep;
      if (eps.isNotEmpty && !eps.any((e) => e.n == ep)) {
        ep = eps.first.n;
      }
      setState(() {
        _detail = detail;
        _ep = ep;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '加载失败：$e');
    }
  }

  String _epNameFor(VideoDetail d, int n) {
    for (final e in d.allEpisodes) {
      if (e.n == n) return fxEpisodeLabel(e.n, e.name);
    }
    return fxEpisodeLabel(n);
  }

  /// 换集后同步历史里的集数（进度由播放器通过 updateProgress 回写）。
  Future<void> _onEpChanged(int n) async {
    setState(() => _ep = n);
    final d = _detail;
    if (d == null) return;
    await FxStore.addHistory(
      id: widget.videoId,
      title: d.title,
      cover: d.cover,
      ep: n,
      epName: _epNameFor(d, n),
      lineId: widget.line,
    );
  }

  /// 详情元信息：年份未知（0 / 越界）时直接省略，不显示 "· 0 ·"。
  String _metaLine() {
    final d = _detail;
    if (d == null) return '';
    return <String>[
      d.status,
      if (d.year > 0) '${d.year}',
      d.area,
    ].where((s) => s.trim().isNotEmpty).join(' · ');
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
                onEpChange: _onEpChanged,
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
                      _metaLine(),
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
                                fxEpisodeLabel(e.n, e.name),
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

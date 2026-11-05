import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../models.dart';
import '../services/fx_player.dart';
import '../theme.dart';
import '../widgets/fs_controls.dart';
import '../widgets/fs_panels.dart';
import '../widgets/player_gestures.dart';
import '../widgets/player_theme.dart';
import 'history_page.dart' show FxStore;

/// 全屏播放退出时带回给竖屏播放器的结果。
///
/// 退出时播放器实例由竖屏继续复用，这里只同步集数 / 进度 / 播放状态。
class FullPlayerResult {
  const FullPlayerResult({
    required this.ep,
    required this.position,
    required this.playing,
    this.info,
    this.rate = 1.0,
    this.qualityKey,
    this.loaded = false,
    this.requestLineChange = false,
  });

  /// 退出时的集数
  final int ep;

  /// 退出时的播放进度（秒）
  final double position;

  /// 退出时是否处于播放中
  final bool playing;

  /// 退出时对应的播放信息（全屏内切集后用于同步竖屏）
  final PlayInfo? info;

  /// 退出时的播放倍速，交回竖屏继续使用
  final double rate;

  /// 退出时选择的清晰度 key；null = 原画（主播放地址）
  final String? qualityKey;

  /// 退出时 [ep] 是否真的加载成功并处于可播放状态。
  /// 切集失败/播放出错时为 false，竖屏不能把它记成「已加载」。
  final bool loaded;

  /// 全屏错误页点了「换线路」：退出后由竖屏页负责切下一条线路。
  final bool requestLineChange;
}

/// 全屏横屏播放页
///
/// 直接复用竖屏传入的 [FxPlayer]（同一个 Player / VideoController）：
/// 进入和退出全屏都不重新创建、不重新 open，进度与暂停状态自然保持。
/// 进入即横屏 + 沉浸式，退出恢复竖屏；控件 3 秒自动隐藏，点击画面切换显隐；
/// 锁屏后只剩解锁按钮，其它手势全部失效。
class FullPlayerPage extends StatefulWidget {
  const FullPlayerPage({
    super.key,
    required this.player,
    this.videoId = '',
    this.ep = 1,
    this.line = '',
    this.title = '',
    this.playInfo,
    this.episodes = const <Episode>[],
    this.lineName = '',
    this.rate = 1.0,
    this.qualityKey,
    this.canChangeLine = false,
  });

  /// 竖屏播放页正在使用的播放器实例（全屏直接复用）
  final FxPlayer player;

  final String videoId;
  final int ep;
  final String line;
  final String title;

  /// 竖屏已经拿到的播放信息，可直接复用，省一次请求
  final PlayInfo? playInfo;

  /// 剧集列表（详情页带入）
  final List<Episode> episodes;

  /// 线路名（仅用于设置面板展示）
  final String lineName;

  /// 竖屏进入全屏时的真实倍速（来自 player.state.rate）
  final double rate;

  /// 竖屏上次在全屏选择的清晰度，重进时保持选中
  final String? qualityKey;

  /// 竖屏是否还有其它线路可换（错误页展示「换线路」）
  final bool canChangeLine;

  @override
  State<FullPlayerPage> createState() => _FullPlayerPageState();
}

class _FullPlayerPageState extends State<FullPlayerPage>
    with WidgetsBindingObserver {
  static const List<DeviceOrientation> _landscape = <DeviceOrientation>[
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  /// 与 main.dart 里保持一致，退出全屏后恢复
  static const SystemUiOverlayStyle _appOverlay = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarContrastEnforced: false,
  );

  FxPlayer? _controller;
  PlayInfo? _info;

  late int _ep;
  late String _line;
  late String _title;
  late List<Episode> _episodes;

  int _loadToken = 0;

  /// controller 实际已经打开的集；进度只写这一集，loading 时不写。
  int? _loadedEp;

  bool _loading = false;
  bool _error = false;
  String _errorText = '';
  bool _sourceFailNotified = false;
  bool _ended = false;

  // 控件显隐 / 锁屏
  bool _controls = true;
  Timer? _hideTimer;
  Timer? _progressTimer;

  /// 切后台 3 秒后才暂停；通知栏 / 截屏只到 inactive，不打断播放。
  Timer? _backgroundTimer;
  bool _backgrounded = false;
  bool _pausedByBackground = false;
  bool _locked = false;
  bool _rotationLocked = false;

  /// 锁屏后解锁钮是否可见：出现 3 秒后自动隐藏，点屏幕再出现。
  bool _unlockVisible = false;
  Timer? _unlockTimer;

  // 弹层
  bool _showSpeed = false;
  bool _showJump = false;
  bool _showQuality = false;

  /// 切清晰度期间：禁止重复点击，避免并发 open。
  bool _switching = false;

  /// 切清晰度期间锁住 UI 进度，防止播放器 open 归零时进度条跳回 0。
  Duration? _uiPosition;
  Duration? _uiDuration;
  Timer? _uiHoldTimer;

  /// loading 浮层文案（切清晰度时不同）。
  String? _loadingHint;

  /// 已展示过的分辨率标签：videoParams 晚到时补一次重建。
  String _resolutionSeen = '';

  /// 当前清晰度；null = 原画（使用 PlayInfo.url + backup）
  String? _qualityKey;

  // 播放倍速
  double _rate = 1.0;
  double _rateBeforeHold = 1.0;
  bool _holding2x = false;

  // 进度提示
  String? _seekHint;
  Timer? _seekHintTimer;

  bool _exiting = false;

  bool get _panelOpen => _showSpeed || _showJump || _showQuality;

  bool get _playing => _controller?.value.isPlaying ?? false;

  List<QualityItem> get _qualityList => _info?.quality ?? const <QualityItem>[];

  /// 只有 ≥2 个真实码率才提供清晰度入口（产品要求，单码率不显示）。
  bool get _canChangeQuality => _qualityList.length >= 2;

  /// 底部清晰度按钮文案：单码率返回空串，直接隐藏入口。
  String get _qualityLabel {
    if (!_canChangeQuality) return '';
    final key = _qualityKey;
    if (key == null) return '原画';
    for (final q in _qualityList) {
      if (q.key == key) return _qualityName(q);
    }
    return '原画';
  }

  /// 主播放地址不在码率列表里时，用真实的「原画」档代表它。
  bool get _showSourceTier {
    final info = _info;
    if (info == null) return false;
    final main = info.url.trim();
    if (main.isEmpty) return false;
    return _qualityList.every((q) => q.url.trim() != main);
  }

  /// 主地址对应哪个码率：用于进入页面时正确高亮当前档。
  String? _qualityKeyFor(PlayInfo? info) {
    if (info == null) return null;
    final main = info.url.trim();
    if (main.isEmpty) return null;
    for (final q in info.quality) {
      if (q.url.trim() == main) return q.key;
    }
    return null;
  }

  /// loading / 切换期间显示用的进度，避免 open 重置成 0 导致进度条回弹。
  Duration get _displayPosition =>
      _uiPosition ?? (_controller?.value.position ?? Duration.zero);

  Duration get _displayDuration =>
      (_uiDuration != null && _uiDuration! > Duration.zero)
          ? _uiDuration!
          : (_controller?.value.duration ?? Duration.zero);

  /// 切换结束后最多再占位 2 秒；seek 异常时也不会把假进度永远挂在 UI 上。
  void _startUiHoldTimeout() {
    _uiHoldTimer?.cancel();
    _uiHoldTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted || _uiPosition == null) return;
      setState(() {
        _uiPosition = null;
        _uiDuration = null;
      });
    });
  }

  /// 直接使用 PlayInfo.quality 里的真实名称，不再把 key 猜成 4K / 1080P。
  String _qualityName(QualityItem q) {
    final name = q.name.trim();
    return name.isEmpty ? q.key : name;
  }

  /// 分辨率通俗标签：4K / 1080P / 720P / 标清（未就绪时为空串）。
  String get _resolutionText {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return '';
    // 优先用解码后的原始宽度，其次用显示宽度。
    return fxResolutionLabel(c.value.videoWidth ?? c.value.width);
  }

  /// 当前画质名称：纯信息展示（原画 / 接口返回的真实码率名）。
  String get _currentQualityText {
    final info = _info;
    if (info == null) return '';
    final key = _qualityKey;
    if (key != null) {
      for (final q in info.quality) {
        if (q.key == key) {
          final name = q.name.trim();
          return name.isEmpty ? q.key : name;
        }
      }
    }
    return '原画';
  }

  String get _epLabel => _epLabelFor(_ep);

  String get _lineName {
    final infoName = _info?.lineName.trim() ?? '';
    return infoName.isNotEmpty ? infoName : widget.lineName;
  }

  String _epLabelFor(int n) {
    for (final e in _episodes) {
      if (e.n == n) return fxEpisodeLabel(e.n, e.name);
    }
    return fxEpisodeLabel(n);
  }

  @override
  void initState() {
    super.initState();
    _ep = widget.ep;
    _line = widget.line;
    _title = widget.title.trim().isEmpty ? '正在播放' : widget.title.trim();
    _episodes = List<Episode>.from(widget.episodes);

    // 复用竖屏的播放器实例：不新建 player，也不重新 open。
    final c = widget.player;
    _controller = c;
    _info = widget.playInfo;
    _qualityKey = widget.qualityKey ?? _qualityKeyFor(widget.playInfo);
    _rate = widget.rate > 0 ? widget.rate : (c.rate > 0 ? c.rate : 1.0);
    _loadedEp = c.value.isInitialized ? _ep : null;
    _loading = !c.value.isInitialized;
    c.addListener(_onVideoValue);
    if (c.value.isInitialized && (c.rate - _rate).abs() > .01) {
      unawaited(_applyRate(_rate));
    }

    WidgetsBinding.instance.addObserver(this);
    unawaited(_enterImmersive());
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return;
      unawaited(_saveProgress());
    });
    _startHideTimer();
    if (widget.videoId.isNotEmpty && _episodes.isEmpty) {
      unawaited(_loadEpisodeMeta());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _seekHintTimer?.cancel();
    _unlockTimer?.cancel();
    _uiHoldTimer?.cancel();
    _progressTimer?.cancel();
    _backgroundTimer?.cancel();
    _loadToken++;
    unawaited(_saveProgress());
    // 播放器实例属于竖屏页面，退出全屏只移除监听，不能 dispose。
    _controller?.removeListener(_onVideoValue);
    unawaited(_restoreSystemUi());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
        // 下拉通知栏 / 截屏 / 多任务预览都只到 inactive：不暂停。
        return;
      case AppLifecycleState.paused:
        // 来电 / 切后台：长按 2 倍速必须复位；先记进度，3 秒内回前台就不暂停。
        _backgrounded = true;
        _endHold2x();
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
    if (!mounted || !_backgrounded) return;
    final c = _controller;
    if (c == null || !c.value.isInitialized || !c.value.isPlaying) return;
    _pausedByBackground = true;
    unawaited(_saveProgress());
    unawaited(c.pause());
  }

  void _resumeAfterBackground() {
    if (!_pausedByBackground) return;
    _pausedByBackground = false;
    if (!mounted || _loading || _error) return;
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    unawaited(c.play());
  }

  /* ------------------------------------------------------------------ 系统 */

  Future<void> _enterImmersive() async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations(_landscape);
      SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    } catch (_) {
      // 桌面 / 模拟器上不支持也无所谓
    }
  }

  Future<void> _restoreSystemUi() async {
    try {
      await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
        DeviceOrientation.portraitUp,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(_appOverlay);
    } catch (_) {}
  }

  /* ---------------------------------------------------------------- 数据 */

  Future<void> _loadEpisodeMeta() async {
    try {
      final detail = await Api.detail(widget.videoId);
      if (!mounted) return;
      setState(() {
        _episodes = detail.allEpisodes;
        if (widget.title.trim().isEmpty && detail.title.isNotEmpty) {
          _title = detail.title;
        }
      });
    } catch (_) {
      // 拿不到剧集也不影响播放
    }
  }

  /// 重新加载当前集（重试 / 全屏内切集）：复用竖屏传入的同一个
  /// [FxPlayer] 实例换播放地址，不新建播放器、不重建视频输出。
  Future<void> _bootstrap({
    required bool seekToSaved,
    bool saveOld = true,
  }) async {
    final c = _controller;
    if (c == null) return;
    final token = ++_loadToken;
    _hideTimer?.cancel();
    if (saveOld) await _saveProgress();
    if (!mounted || token != _loadToken) return;
    unawaited(c.pause());
    setState(() {
      _loading = true;
      _loadedEp = null;
      _error = false;
      _errorText = '';
      _ended = false;
      _sourceFailNotified = false;
      _qualityKey = null;
      _uiPosition = null;
      _uiDuration = null;
      _loadingHint = null;
    });

    PlayInfo source;
    try {
      source = await Api.play(widget.videoId, _ep, _line);
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
    _info = source;
    _qualityKey = _qualityKeyFor(source);

    final all = <String>[
      if (source.url.trim().isNotEmpty) source.url.trim(),
      for (final u in source.backup)
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

    var resume = 0.0;
    if (seekToSaved) {
      resume = await fxLoadProgress(widget.videoId, _ep);
    }
    if (!mounted || token != _loadToken) return;

    var ok = false;
    for (final url in candidates) {
      if (!mounted || token != _loadToken) return;
      try {
        await c.open(url, headers: source.headers);
        if (!mounted || token != _loadToken) return;
        final durationMs = c.value.duration.inMilliseconds;
        var start = resume;
        if (durationMs > 0 && start >= durationMs / 1000.0 - 2) start = 0;
        if (start > 0) {
          await c.seekTo(Duration(milliseconds: (start * 1000).round()));
        }
        await c.setLooping(false);
        try {
          await c.setRate(_rate);
        } catch (_) {}
        if (!mounted || token != _loadToken) return;
        await c.play();
        if (!mounted || token != _loadToken) return;
        _loadedEp = _ep;
        setState(() {
          _loading = false;
          _error = false;
          _errorText = '';
          _loadingHint = null;
        });
        _sourceFailNotified = false;
        ok = true;
        _wake();
        break;
      } catch (_) {
        // 换下一条备用地址继续尝试
      }
    }

    if (!ok) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        _error = true;
        _errorText = '播放失败：线路不可用，请重试或切换线路';
        _loadingHint = null;
      });
      _notifySourceFailed();
    }
  }

  void _notifySourceFailed() {
    if (_sourceFailNotified) return;
    _sourceFailNotified = true;
    if (!mounted) return;
    fxToast(context, '当前线路播放失败，可返回竖屏切换线路');
  }

  /// 用同一播放器实例打开一个地址，并恢复进度 / 倍速 / 播放状态。
  /// open 或 play 抛出的异常都在这里兜住，返回是否成功。
  Future<bool> _openSource(
    String url, {
    required Map<String, String> headers,
    required Duration resume,
    required bool wasPlaying,
  }) async {
    final c = _controller;
    if (c == null) return false;
    try {
      await c.open(url, headers: headers);
      if (!mounted) return false;
      final duration = c.value.duration;
      var target = resume;
      if (duration > Duration.zero &&
          target >= duration - const Duration(milliseconds: 1500)) {
        target = Duration.zero;
      }
      if (target > Duration.zero) await c.seekTo(target);
      await c.setLooping(false);
      try {
        await c.setRate(_rate);
      } catch (_) {}
      if (wasPlaying) {
        await c.play();
      } else {
        // 暂停状态下也先拉一帧再暂停，避免切清晰度后停在黑屏。
        await c.play();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await c.pause();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 切换清晰度：真正换 networkUrl，并恢复切换前的进度 / 倍速 / 播放状态。
  /// 新清晰度失败时回退打开原来的播放地址；连回退也失败才进入错误态。
  Future<void> _selectQuality(String? key) async {
    if (_loading || _switching) {
      fxToast(context, '正在切换，请稍候');
      return;
    }
    final info = _info;
    final list = _qualityList;
    // 产品要求：只有 1 个画质时没有清晰度入口；这里再兜一层。
    if (info == null || list.length < 2) {
      fxToast(context, '当前线路仅提供原画');
      return;
    }
    if (key == _qualityKey) {
      _closePanels();
      _wake();
      return;
    }

    QualityItem? picked;
    if (key != null) {
      for (final q in list) {
        if (q.key == key) {
          picked = q;
          break;
        }
      }
      if (picked == null) {
        fxToast(context, '该清晰度暂不可用');
        return;
      }
    }

    final urls = <String>[];
    if (picked == null) {
      for (final u in <String>[info.url, ...info.backup]) {
        final url = u.trim();
        if (url.isNotEmpty && !urls.contains(url)) urls.add(url);
      }
    } else {
      final url = picked.url.trim();
      if (url.isNotEmpty) urls.add(url);
    }
    if (urls.isEmpty) {
      fxToast(context, '当前清晰度没有可用的播放地址');
      return;
    }

    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      fxToast(context, '播放器尚未就绪，请稍后再试');
      return;
    }
    final oldQuality = _qualityKey;
    String? oldUrl;
    if (oldQuality != null) {
      for (final q in list) {
        if (q.key == oldQuality && q.url.trim().isNotEmpty) {
          oldUrl = q.url.trim();
          break;
        }
      }
    }
    // 切换前固定住进度与播放状态：open 新地址期间 UI 不允许归零。
    final wasPlaying = c.value.isPlaying;
    final resume = c.value.position;
    final resumeDuration = c.value.duration;

    /// 清晰度地址可能带自己的请求头（防盗链），优先用它，其次用全局头。
    Map<String, String> headersFor(String url) {
      for (final q in list) {
        if (q.url.trim() == url && q.headers.isNotEmpty) return q.headers;
      }
      return info.headers;
    }

    _switching = true;
    final token = ++_loadToken;
    try {
      // 先把当前进度落盘：切换失败后点重试也能回到正确位置。
      await _saveProgress();
      if (!mounted || token != _loadToken) return;
      _hideTimer?.cancel();
      setState(() {
        _showQuality = false;
        _showSpeed = false;
        _showJump = false;
        _loading = true;
        _loadingHint = '正在切换清晰度';
        _error = false;
        _errorText = '';
        _ended = false;
        _controls = true;
        _uiPosition = resume;
        _uiDuration = resumeDuration;
      });

      var ok = false;
      for (final url in urls) {
        if (!mounted || token != _loadToken) return;
        // 复用同一个播放器实例，只换地址；ready 后 seek 回原进度。
        if (await _openSource(
          url,
          headers: headersFor(url),
          resume: resume,
          wasPlaying: wasPlaying,
        )) {
          ok = true;
          break;
        }
      }

      if (!mounted || token != _loadToken) return;
      if (!ok) {
        // open 已经打断了原片源：必须把原来的地址重新打开并 seek 回原进度，
        // 否则就是黑屏且不报错。回退也失败才置错误态，让用户点重试。
        final fallback = <String>[];
        if (oldUrl != null) fallback.add(oldUrl);
        for (final u in <String>[info.url, ...info.backup]) {
          final url = u.trim();
          if (url.isNotEmpty && !fallback.contains(url)) fallback.add(url);
        }
        var restored = false;
        var restoredKey = oldUrl == null ? null : oldQuality;
        for (final url in fallback) {
          if (!mounted || token != _loadToken) return;
          if (await _openSource(
            url,
            headers: headersFor(url),
            resume: resume,
            wasPlaying: wasPlaying,
          )) {
            restored = true;
            if (oldUrl == null || url != oldUrl) restoredKey = null;
            break;
          }
        }
        if (!mounted || token != _loadToken) return;
        setState(() {
          _loading = false;
          _loadingHint = null;
          _qualityKey = restored ? restoredKey : oldQuality;
          _controls = true;
          if (!restored) {
            _error = true;
            _errorText = '切换清晰度失败，播放器需要重试';
            _uiPosition = null;
            _uiDuration = null;
          }
          // 回退成功时继续用 resume 占位，真实进度追上后由 _onVideoValue 释放。
        });
        if (restored) _startUiHoldTimeout();
        _wake();
        fxToast(context, restored ? '切换清晰度失败，已恢复原清晰度' : '切换清晰度失败，请重试');
        return;
      }

      setState(() {
        _qualityKey = key;
        _loading = false;
        _loadingHint = null;
        _error = false;
        _errorText = '';
        _sourceFailNotified = false;
        _controls = true;
      });
      _startUiHoldTimeout();
      _wake();
      _showSeekHint('清晰度：$_qualityLabel');
    } finally {
      // 必须触发一次重建：否则手势层/控件会一直停留在「切换中」的禁用状态。
      if (mounted && _switching) {
        setState(() => _switching = false);
      }
    }
  }

  Future<double> _saveProgress({bool ended = false}) async {
    if (_loading || _error) return 0;
    final c = _controller;
    final ep = _loadedEp;
    if (c == null || ep == null || !c.value.isInitialized) return 0;
    final v = c.value;
    final durationMs = v.duration.inMilliseconds;
    final rawPosition = v.position.inMilliseconds;
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
    await FxStore.updateProgress(
      id: widget.videoId,
      ep: ep,
      epName: _epLabelFor(ep),
      lineId: widget.line,
      lineName: widget.lineName,
      position: positionMs ~/ 1000,
      duration: durationMs <= 0 ? 0 : durationMs ~/ 1000,
    );
    return seconds;
  }

  void _onVideoValue() {
    final c = _controller;
    if (c == null || !mounted) return;
    // loading 期间的错误交给 _bootstrap / _openSource 的 try/catch 处理。
    if (_loading || _error) return;
    final v = c.value;
    // 切清晰度成功后，真实进度追上占位值再释放，避免进度条归零。
    if (_uiPosition != null && v.isInitialized) {
      final diff = (v.position - _uiPosition!).abs();
      if (diff <= const Duration(seconds: 3)) {
        _uiHoldTimer?.cancel();
        setState(() {
          _uiPosition = null;
          if (v.duration > Duration.zero) _uiDuration = null;
        });
      }
    }
    final resolution = fxResolutionLabel(v.videoWidth ?? v.width);
    if (resolution.isNotEmpty && resolution != _resolutionSeen) {
      _resolutionSeen = resolution;
      setState(() {});
    }
    if (v.hasError) {
      setState(() {
        _loading = false;
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
    unawaited(_handleEnded());
  }

  Future<void> _handleEnded() async {
    await _saveProgress(ended: true);
    if (!mounted) return;
    final next = _nextEpNumber();
    if (next != null) {
      await _switchEp(next, auto: true);
    } else {
      _wake();
      fxToast(context, '已播放完最后一集');
    }
  }

  int? _nextEpNumber() {
    // 剧集列表为空时按单片处理，播完就停；不再无限跳第 02 集。
    if (_episodes.isEmpty) return null;
    final index = _episodes.indexWhere((e) => e.n == _ep);
    if (index < 0) return null;
    if (index + 1 >= _episodes.length) return null;
    return _episodes[index + 1].n;
  }

  Future<void> _switchEp(int next, {bool auto = false}) async {
    if (_loading || _switching) return;
    if (next == _ep) {
      _closePanels();
      return;
    }
    await _saveProgress();
    if (!mounted) return;
    setState(() {
      _ep = next;
      _episodes = List<Episode>.from(_episodes);
      _showQuality = false;
      _controls = true;
      _loading = true;
      _loadedEp = null;
      _error = false;
    });
    if (auto) fxToast(context, '即将播放 ${_epLabelFor(next)}');
    await _bootstrap(seekToSaved: true, saveOld: false);
    if (!mounted) return;
    _wake();
  }

  Future<void> _next() async {
    final next = _nextEpNumber();
    if (next == null) {
      fxToast(context, '已经是最后一集了');
      _wake();
      return;
    }
    await _switchEp(next);
  }

  /* ---------------------------------------------------------------- 控件 */

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (_locked ||
          _panelOpen ||
          _holding2x ||
          _loading ||
          _error ||
          _switching) {
        if (_holding2x) _startHideTimer();
        return;
      }
      setState(() => _controls = false);
    });
  }

  void _wake() {
    if (!mounted || _locked) return;
    if (!_controls) {
      setState(() => _controls = true);
    }
    _startHideTimer();
  }

  void _hideControls() {
    _hideTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _controls = false;
      _showSpeed = false;
      _showJump = false;
      _showQuality = false;
    });
  }

  void _onSurfaceTap() {
    if (_locked) return;
    if (_panelOpen) {
      _closePanels();
      return;
    }
    if (_loading || _error) {
      _wake();
      return;
    }
    if (_controls) {
      _hideControls();
    } else {
      _wake();
    }
  }

  void _closePanels() {
    if (!_panelOpen) return;
    setState(() {
      _showSpeed = false;
      _showJump = false;
      _showQuality = false;
    });
    _wake();
  }

  void _lock() {
    _unlockTimer?.cancel();
    setState(() {
      _locked = true;
      _controls = false;
      _unlockVisible = true;
      _showSpeed = false;
      _showJump = false;
      _showQuality = false;
    });
    _hideTimer?.cancel();
    _startUnlockTimer();
    fxToast(context, '已锁定，点击屏幕显示解锁按钮');
  }

  /// 锁定后解锁钮只亮 3 秒；点屏幕可重新唤出。
  void _startUnlockTimer() {
    _unlockTimer?.cancel();
    _unlockTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !_locked) return;
      setState(() => _unlockVisible = false);
    });
  }

  void _onLockedTap() {
    if (!mounted) return;
    if (!_unlockVisible) setState(() => _unlockVisible = true);
    _startUnlockTimer();
    _showSeekHint('已锁定，点锁图标解锁');
  }

  void _unlock() {
    if (!mounted) return;
    _unlockTimer?.cancel();
    setState(() {
      _locked = false;
      _unlockVisible = false;
      _controls = true;
    });
    _wake();
  }

  void _toggleRotation() {
    setState(() => _rotationLocked = !_rotationLocked);
    // Flutter 无法读取当前横屏的左右朝向，这里保留状态位（接入平台插件后可真正锁定）
    fxToast(
      context,
      _rotationLocked ? '已锁定横屏方向，旋转手机不再翻转画面' : '已解除旋转锁定',
    );
    _wake();
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null ||
        _loading ||
        _error ||
        _switching ||
        !c.value.isInitialized) {
      return;
    }
    // 直接让 media_kit 切换，图标由 player.stream.playing 驱动，避免本地态覆盖。
    unawaited(c.playOrPause());
    _wake();
  }

  void _seekTo(Duration d) {
    final c = _controller;
    if (c == null || _loading || _switching || !c.value.isInitialized) return;
    unawaited(c.seekTo(d));
    _wake();
  }

  void _seekBy(int seconds) {
    final c = _controller;
    if (c == null || _loading || _switching || !c.value.isInitialized) return;
    final total = c.value.duration;
    var target = c.value.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (target > total) target = total;
    unawaited(c.seekTo(target));
    _showSeekHint(seconds > 0 ? '快进 ${seconds}s' : '后退 ${-seconds}s');
    _wake();
  }

  void _showSeekHint(String text) {
    _seekHintTimer?.cancel();
    if (!mounted) return;
    setState(() => _seekHint = text);
    _seekHintTimer = Timer(const Duration(milliseconds: 720), () {
      if (!mounted) return;
      setState(() => _seekHint = null);
    });
  }

  Future<void> _applyRate(double rate) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    try {
      await c.setRate(rate);
    } catch (_) {}
  }

  void _setRate(double rate) {
    if (!mounted) return;
    setState(() => _rate = rate);
    unawaited(_applyRate(rate));
    _showSeekHint('${fxRateLabel(rate)} 播放');
  }

  void _startHold2x() {
    final c = _controller;
    if (c == null ||
        _loading ||
        _error ||
        _switching ||
        !c.value.isInitialized) {
      return;
    }
    if (_rate >= 2.0) return;
    _rateBeforeHold = _rate;
    unawaited(_applyRate(2.0));
    setState(() => _holding2x = true);
    _wake();
  }

  void _endHold2x() {
    if (!_holding2x) return;
    unawaited(_applyRate(_rateBeforeHold));
    if (!mounted) return;
    setState(() => _holding2x = false);
    _wake();
  }

  void _toggleSpeed() {
    _hideTimer?.cancel();
    setState(() {
      _showSpeed = !_showSpeed;
      _showJump = false;
      _showQuality = false;
      _controls = true;
    });
    if (!_showSpeed) _wake();
  }

  void _toggleJump() {
    _hideTimer?.cancel();
    setState(() {
      _showJump = !_showJump;
      _showSpeed = false;
      _showQuality = false;
      _controls = true;
    });
    if (!_showJump) _wake();
  }

  Future<void> _openEpisodeSheet() async {
    if (_loading || _switching) return;
    _hideTimer?.cancel();
    if (_episodes.isEmpty) {
      fxToast(context, '暂无剧集信息');
      _wake();
      return;
    }
    if (mounted) setState(() => _controls = true);
    final picked = await showFsEpisodeSheet(
      context,
      episodes: _episodes,
      current: _ep,
    );
    if (!mounted) return;
    _wake();
    if (picked != null) await _switchEp(picked);
  }

  void _toggleQuality() {
    if (_loading || _switching) {
      fxToast(context, '正在切换，请稍候');
      return;
    }
    _hideTimer?.cancel();
    if (!_canChangeQuality) {
      fxToast(context, '当前线路仅提供原画');
      _wake();
      return;
    }
    setState(() {
      _showQuality = !_showQuality;
      _showSpeed = false;
      _showJump = false;
      _controls = true;
    });
    if (!_showQuality) _wake();
  }

  void _jumpIntro() {
    final c = _controller;
    if (c == null || _loading || _switching || !c.value.isInitialized) return;
    const target = Duration(seconds: 90);
    final total = c.value.duration;
    unawaited(c.seekTo(target > total ? Duration.zero : target));
    _showSeekHint('已跳过片头');
    _wake();
  }

  void _jumpOutro() {
    final c = _controller;
    if (c == null || _loading || _switching || !c.value.isInitialized) return;
    final total = c.value.duration;
    final target = total - const Duration(seconds: 90);
    unawaited(c.seekTo(target < Duration.zero ? Duration.zero : target));
    _showSeekHint('已跳到片尾');
    _wake();
  }

  Future<void> _openPlayerSettings() async {
    if (_loading || _switching) return;
    _hideTimer?.cancel();
    _closePanels();
    if (mounted) setState(() => _controls = true);

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final quality = _info?.quality ?? const <QualityItem>[];
            final lineName = _info?.lineName ?? widget.lineName;
            final maxHeight = MediaQuery.of(context).size.height * .88;
            return Container(
              constraints: BoxConstraints(maxHeight: maxHeight),
              padding: EdgeInsets.fromLTRB(
                20,
                14,
                20,
                16 + MediaQuery.of(context).padding.bottom,
              ),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.settings_rounded,
                            size: 19, color: Fx.accent),
                        const SizedBox(width: 7),
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
                    if (lineName.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text('当前线路：$lineName',
                            style:
                                const TextStyle(fontSize: 11.5, color: Fx.sub)),
                      ),
                    if (_resolutionText.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text('当前分辨率：$_resolutionText',
                            style:
                                const TextStyle(fontSize: 11.5, color: Fx.sub)),
                      ),
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
                        for (final item in FsSpeedPanel.options)
                          ChipTag(
                            fxRateLabel(item),
                            active: (_rate - item).abs() < .001,
                            onTap: () {
                              _setRate(item);
                              setSheetState(() {});
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    if (quality.length >= 2) ...[
                      const SizedBox(height: 14),
                      const Text('清晰度',
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: Fx.sub)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (_showSourceTier)
                            ChipTag(
                              '原画',
                              active: _qualityKey == null,
                              onTap: () {
                                Navigator.of(sheetContext).pop();
                                unawaited(_selectQuality(null));
                              },
                            ),
                          for (final q in quality)
                            ChipTag(
                              _qualityName(q),
                              active: _qualityKey == q.key,
                              onTap: () {
                                Navigator.of(sheetContext).pop();
                                unawaited(_selectQuality(q.key));
                              },
                            ),
                        ],
                      ),
                    ],
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: Icon(Icons.info_outline_rounded,
                          size: 20, color: Fx.sub),
                      title: Text('播放内核',
                          style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: Fx.ink)),
                      subtitle: Text('media_kit · libmpv · HLS / 加密 / 多编码',
                          style: TextStyle(fontSize: 10.5, color: Fx.sub)),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    if (!mounted) return;
    _wake();
  }

  Future<void> _exit({bool requestLineChange = false}) async {
    if (_exiting) return;
    _exiting = true;
    _unlockTimer?.cancel();
    // 作废仍在进行的切清晰度/切集请求，退出后不要再回写 UI。
    _loadToken++;
    _uiHoldTimer?.cancel();
    _hideTimer?.cancel();
    final playing = _playing;
    final position = await _saveProgress();
    // 播放器交回竖屏继续使用：不 pause、不 dispose，保持进度与播放状态。
    await _restoreSystemUi();
    if (!mounted) return;
    final c = _controller;
    Navigator.of(context).pop(
      FullPlayerResult(
        ep: _ep,
        position: position,
        playing: playing,
        info: _info,
        rate: _rate,
        qualityKey: _qualityKey,
        // 只有这一集真的打开成功（未处于错误态）才允许竖屏同步集数。
        loaded:
            _loadedEp == _ep && !_error && (c != null && c.value.isInitialized),
        requestLineChange: requestLineChange,
      ),
    );
  }

  /* ---------------------------------------------------------------- 布局 */

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final c = _controller;

    return PopScope<FullPlayerResult>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        unawaited(_exit());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        body: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(child: _buildVideoSurface(c)),
            // 手势层：双击暂停 / 横扫调进度 / 竖扫亮度音量 / 长按 2x。
            if (!_locked && c != null)
              Positioned.fill(
                child: FxPlayerGestures(
                  player: c,
                  enabled: !_loading && !_error && !_switching,
                  onTap: _onSurfaceTap,
                  onDoubleTap: _togglePlay,
                  onSeek: _seekTo,
                  onLongPressStart: _startHold2x,
                  onLongPressEnd: _endHold2x,
                  onGestureStart: _hideControls,
                  resetBrightnessOnDispose: false,
                ),
              ),
            if (_panelOpen)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _closePanels,
                  child: const SizedBox.expand(),
                ),
              ),
            if (!_locked)
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: !_controls || _loading || _switching,
                  child: AnimatedOpacity(
                    opacity: _controls ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: _buildControls(c, keyboard, pad),
                  ),
                ),
              ),
            // 播放中的缓冲：玻璃圆环 + libmpv 真实缓存百分比。
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
            if (_error) _buildError(),
            // 锁屏：所有控件隐藏，只留一个 3 秒后自动隐藏的解锁钮；
            // 点屏幕重新唤出并提示如何解锁。
            if (_locked)
              Positioned.fill(
                child: SafeArea(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _onLockedTap,
                        child: const SizedBox.expand(),
                      ),
                      if (_unlockVisible) FsUnlockButton(onUnlock: _unlock),
                    ],
                  ),
                ),
              ),
            if (_seekHint != null)
              Align(
                alignment: const Alignment(0, .56),
                child: _FsBadge(text: _seekHint!),
              ),
            if (_holding2x)
              Positioned(
                top: pad.top + 10,
                left: 0,
                right: 0,
                child: const Center(child: _FsBadge(text: '2.0x 倍速播放中')),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoSurface(FxPlayer? c) {
    if (c == null || !c.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }
    // 画面固定自适应：等比完整显示并居中，不裁剪、不变形。
    return ClipRect(
      child: SizedBox.expand(
        child: c.buildVideo(fit: BoxFit.contain),
      ),
    );
  }

  Widget _buildLoading() {
    return Positioned.fill(
      child: FxLoadingOverlay(
        title: _loadingHint ?? fxLoadingEpisodeText(_ep),
        subtitle: _lineName,
      ),
    );
  }

  Widget _buildError() {
    return Positioned.fill(
      child: Center(
        child: Container(
          width: 330,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.95),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(.20),
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
                style:
                    const TextStyle(color: Fx.ink, fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _errorAction('重试', () {
                    unawaited(_bootstrap(
                      seekToSaved: true,
                      saveOld: false,
                    ));
                  }),
                  if (widget.canChangeLine) ...[
                    const SizedBox(width: 10),
                    _errorAction(
                      '换线路',
                      () => unawaited(_exit(requestLineChange: true)),
                    ),
                  ],
                  const SizedBox(width: 10),
                  _errorAction('退出全屏', () => unawaited(_exit())),
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

  Widget _buildControls(
    FxPlayer? c,
    double keyboard,
    EdgeInsets pad,
  ) {
    final compact = MediaQuery.sizeOf(context).width < 700;
    final bottomInset = keyboard > 0 ? 0.0 : pad.bottom;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: FsTopBar(
            title: _title,
            epLabel: _epLabel,
            resolution: _resolutionText,
            quality: _currentQualityText,
            compact: compact,
            rotationLocked: _rotationLocked,
            onBack: () => unawaited(_exit()),
            onRotate: _toggleRotation,
            onPip: () => fxToast(context, '画中画：正在准备…'),
            onCast: () => fxToast(context, '正在搜索附近投屏设备…'),
            onSettings: () => unawaited(_openPlayerSettings()),
          ),
        ),
        Positioned.fill(
          child: FsSideControls(
            onLock: _lock,
            onSeekBy: _seekBy,
          ),
        ),
        if (c != null)
          Center(
            child: AnimatedBuilder(
              animation: c,
              builder: (context, _) {
                final playing = c.value.isInitialized && c.value.isPlaying;
                return FsCenterControls(
                  playing: playing,
                  onTogglePlay: _togglePlay,
                );
              },
            ),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: keyboard,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_showQuality)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FsQualityPanel(
                      items: _qualityList,
                      currentKey: _qualityKey,
                      showSource: _showSourceTier,
                      onPick: (key) => unawaited(_selectQuality(key)),
                    ),
                  ),
                ),
              if (_showSpeed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FsSpeedPanel(
                      rate: _rate,
                      onPick: (v) {
                        _setRate(v);
                        setState(() => _showSpeed = false);
                        _wake();
                      },
                    ),
                  ),
                ),
              if (_showJump)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FsJumpPanel(
                      onIntro: () {
                        _closePanels();
                        _jumpIntro();
                      },
                      onOutro: () {
                        _closePanels();
                        _jumpOutro();
                      },
                    ),
                  ),
                ),
              if (c == null)
                SizedBox(height: 68 + bottomInset)
              else
                AnimatedBuilder(
                  animation: c,
                  builder: (context, _) {
                    final v = c.value;
                    return FsBottomBar(
                      position: _displayPosition,
                      duration: _displayDuration,
                      buffered: v.buffered,
                      playing: v.isInitialized && v.isPlaying,
                      rate: _rate,
                      qualityLabel: _canChangeQuality ? '清晰度' : '',
                      qualityActive: _canChangeQuality && _qualityKey != null,
                      compact: compact,
                      bottomInset: bottomInset,
                      onSeek: _seekTo,
                      onTogglePlay: _togglePlay,
                      onNext: () => unawaited(_next()),
                      onJump: _toggleJump,
                      onSpeed: _toggleSpeed,
                      onQuality: _toggleQuality,
                      onEpisodes: () => unawaited(_openEpisodeSheet()),
                      onExit: () => unawaited(_exit()),
                    );
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 居中提示小胶囊（±10s / 倍速提示）
class _FsBadge extends StatelessWidget {
  const _FsBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.52),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(.28)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

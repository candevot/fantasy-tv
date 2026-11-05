import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../api.dart';
import '../models.dart';
import '../services/fx_player.dart';
import '../theme.dart';
import '../widgets/fs_controls.dart';
import '../widgets/fs_panels.dart';
import '../widgets/player_gestures.dart';
import '../widgets/player_more_panel.dart';
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
    this.fillScreen = false,
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

  /// 退出时选择的清晰度 key；null = 主播放地址
  final String? qualityKey;

  /// 退出时 [ep] 是否真的加载成功并处于可播放状态。
  /// 切集失败/播放出错时为 false，竖屏不能把它记成「已加载」。
  final bool loaded;

  /// 全屏错误页点了「换线路」：退出后由竖屏页负责切下一条线路。
  final bool requestLineChange;

  /// 退出时「撑满全屏」开关的状态，交回竖屏继续记住（默认 contain）。
  final bool fillScreen;
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
    this.lines = const <LineInfo>[],
    this.lineName = '',
    this.rate = 1.0,
    this.qualityKey,
    this.canChangeLine = false,
    this.fillScreen = false,
    this.isLive = false,
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

  /// 详情线路表：加载文案按当前 lineId 查线路名，不用上次请求的线路名。
  final List<LineInfo> lines;

  /// 竖屏当前线路名（仅用于进度回写历史，加载文案不读它）。
  final String lineName;

  /// 竖屏进入全屏时的真实倍速（来自 player.state.rate）
  final double rate;

  /// 竖屏上次在全屏选择的清晰度，重进时保持选中
  final String? qualityKey;

  /// 竖屏是否还有其它线路可换（错误页展示「换线路」）
  final bool canChangeLine;

  /// 全屏是否撑满（默认关、contain）；打开才 cover。
  final bool fillScreen;

  /// 直播全屏：复用同一个播放器，但隐藏进度条 / 选集 / 倍速 / 下一集，
  /// 左右横滑不再 seek，底部常驻 LIVE。默认 false，不影响点播。
  final bool isLive;

  @override
  State<FullPlayerPage> createState() => _FullPlayerPageState();
}

class _FullPlayerPageState extends State<FullPlayerPage>
    with WidgetsBindingObserver {
  /// 单次 open 等待 ready 的上限：超过即视为该地址不可播，避免黑屏空等。
  static const Duration _openReadyTimeout = Duration(seconds: 8);

  /// 首帧等待上限：open 成功但 10 秒内仍没有画面（红屏 / 黑屏不播）时
  /// 进入错误页；用户点「重试」重新 open 当前地址，连续失败 2 次自动换线路。
  static const Duration _firstFrameTimeout = Duration(seconds: 10);

  /// 连续播放失败次数；首帧真正出现后清零。
  int _failStreak = 0;

  /// 首帧超时看门狗。
  Timer? _firstFrameTimer;

  /// media_kit 平台错误（解码 / 输出 / 网络）：作为 Video 层错误源。
  StreamSubscription<String>? _platformErrorSub;

  /// 当前片源是否已经出过视频首帧；未出首帧时展示加载文案。
  bool _firstFrame = false;

  /// 切集 / 切清晰度 / 重连前抓下的最后一帧：盖在黑底和新画面之间，
  /// 等新流首帧出来再淡出，避免切换过程中闪一下黑屏。
  Uint8List? _frozenFrame;
  bool _freezeOpaque = false;
  Timer? _freezeClearTimer;

  /// 防止平台错误与首帧超时重复进入错误页。
  bool _failureBusy = false;

  /// 出错前的播放位置，重试时尽量接着播。
  Duration _positionBeforeError = Duration.zero;

  /// 看门狗：每 3 秒检查一次，连续 12 秒位置不前进即尝试自愈。
  static const Duration _watchdogTick = Duration(seconds: 3);
  static const Duration _watchdogStall = Duration(seconds: 12);

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

  /// 详情线路表：加载文案只按当前 lineId 查线路名。
  late List<LineInfo> _lines;

  int _loadToken = 0;

  /// controller 实际已经打开的集；进度只写这一集，loading 时不写。
  int? _loadedEp;

  /// 正在打开的组合（line|ep）：重复请求直接复用，防并发 open。
  String? _openingKey;
  Future<void>? _opening;

  /// 当前集播过 30 秒后已预解析的下一集。
  bool _nextPrewarmed = false;
  int? _prewarmEp;
  DateTime? _prewarmAt;

  /// 缓存命中 + 已有上一帧快照时跳过 loading 浮层，直接 open。
  bool _suppressLoadingOverlay = false;

  bool _loading = false;
  bool _error = false;
  String _errorText = '';
  bool _sourceFailNotified = false;
  bool _ended = false;

  // 控件显隐 / 锁屏
  bool _controls = true;
  Timer? _hideTimer;
  Timer? _progressTimer;

  /// 是否已切到后台：后台播放默认开启，切后台只记进度、不暂停；
  /// 看门狗在后台期间也必须停摆，避免回前台误判卡顿重新 open。
  bool _backgrounded = false;

  /// 音频焦点：inactive 持续一段时间才暂停（来电 / 被其它页面遮住）；
  /// 下拉通知栏、截屏会很快回到 resumed，不打断声音。
  Timer? _focusLossTimer;
  bool _pausedByFocusLoss = false;

  /// 回前台只重建 Video 输出层（换 key），播放器实例与进度保持不动。
  int _videoEpoch = 0;
  bool _locked = false;

  /// 锁屏后解锁钮是否可见：出现 3 秒后自动隐藏，点屏幕再出现。
  bool _unlockVisible = false;
  Timer? _unlockTimer;

  // 弹层
  bool _showSpeed = false;
  bool _showQuality = false;

  /// 循环模式默认列表（播完自动下一集）；关闭 / 单集由「更多」面板切换。
  FxLoopMode _loopMode = FxLoopMode.list;

  /// 跳过片头片尾默认关，只记住开关，不自动跳（产品硬性要求）。
  bool _skipIntroOutro = false;

  /// 撑满全屏：默认关（contain 完整显示）；打开才 cover。
  bool _fillScreen = false;

  Timer? _sleepTimer;

  /// 全屏截图：截取整个播放器层（含控制条）。
  final GlobalKey _captureKey = GlobalKey();

  /// 切清晰度期间：禁止重复点击，避免并发 open。
  bool _switching = false;

  /// 看门狗：播放中位置长时间不动时重开当前地址，仍失败则退出并切线路。
  Timer? _watchdogTimer;
  Duration _watchdogLastPosition = Duration.zero;
  DateTime _watchdogLastAdvance = DateTime.now();
  bool _watchdogBusy = false;
  bool _watchdogRetried = false;

  /// 自愈成功后等 position 真正前进，再提示「已自动恢复」。
  bool _watchdogRecoverPending = false;

  /// 切清晰度期间锁住 UI 进度，防止播放器 open 归零时进度条跳回 0。
  Duration? _uiPosition;
  Duration? _uiDuration;
  Timer? _uiHoldTimer;

  /// loading 浮层文案（切清晰度时不同）。
  String? _loadingHint;

  /// 已展示过的画质胶囊文案：videoParams 晚到时补一次重建。
  String _qualitySeen = '';

  /// 当前清晰度；null = 主播放地址（使用 PlayInfo.url + backup）
  String? _qualityKey;

  // 播放倍速
  double _rate = 1.0;
  double _rateBeforeHold = 1.0;
  bool _holding2x = false;

  // 进度提示
  String? _seekHint;
  Timer? _seekHintTimer;

  bool _exiting = false;

  bool get _panelOpen => _showSpeed || _showQuality;

  bool get _playing => _controller?.value.isPlaying ?? false;

  /// 直播模式：不做进度回写、倍速、选集、看门狗与按秒 seek。
  bool get _isLive => widget.isLive;

  List<QualityItem> get _qualityList => _info?.quality ?? const <QualityItem>[];

  /// 只有 ≥2 个真实码率才提供清晰度入口（产品要求，单码率不显示）。
  bool get _canChangeQuality => _qualityList.length >= 2;

  /// 顶栏唯一的画质胶囊：按真实视频宽度分档，未就绪时为空。
  String get _qualityText => fxPlayerQuality(_controller);

  /// 底部清晰度按钮文案：单码率返回空串，直接隐藏入口。
  String get _qualityLabel {
    if (!_canChangeQuality) return '';
    final key = _qualityKey;
    if (key == null) return '默认';
    for (final q in _qualityList) {
      if (q.key == key) return _qualityName(q);
    }
    return '默认';
  }

  /// 主播放地址不在码率列表里时，用「默认」档代表它。
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

  String get _epLabel => _epLabelFor(_ep);

  /// 当前线路名：只按当前 lineId 从详情线路表查，不用上一次请求的 _info。
  String get _lineName => fxLineNameOf(_lines, _line);

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
    _lines = List<LineInfo>.from(widget.lines);

    // 复用竖屏的播放器实例：不新建 player，也不重新 open。
    final c = widget.player;
    _controller = c;
    _info = widget.playInfo;
    _qualityKey = widget.qualityKey ?? _qualityKeyFor(widget.playInfo);
    _fillScreen = widget.fillScreen;
    _rate = widget.rate > 0 ? widget.rate : (c.rate > 0 ? c.rate : 1.0);
    _loadedEp = c.value.isInitialized ? _ep : null;
    _loading = !c.value.isInitialized;
    _firstFrame = _hasFirstFrame(c);
    // 全屏复用的是竖屏已经打开的播放器：这里只监听平台错误，不重新 open。
    _platformErrorSub = c.player.stream.error.listen(_onPlatformError);
    c.addListener(_onVideoValue);
    if (!_firstFrame) _armFirstFrameTimer();
    if (c.value.hasError) {
      // 竖屏交过来时播放器就已经坏了：进全屏直接给错误页，别黑屏干等。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_onPlaybackFailure());
      });
    }
    if (c.value.isInitialized && (c.rate - _rate).abs() > .01) {
      unawaited(_applyRate(_rate));
    }

    WidgetsBinding.instance.addObserver(this);
    unawaited(_enterImmersive());
    if (!_isLive) {
      _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        if (!mounted) return;
        unawaited(_saveProgress());
        _maybePrewarmNext();
      });
      _watchdogTimer =
          Timer.periodic(_watchdogTick, (_) => _checkWatchdog());
      _resetWatchdogClock();
      if (widget.videoId.isNotEmpty && _episodes.isEmpty) {
        unawaited(_loadEpisodeMeta());
      }
    }
    _startHideTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _seekHintTimer?.cancel();
    _unlockTimer?.cancel();
    _uiHoldTimer?.cancel();
    _progressTimer?.cancel();
    _cancelFocusLossPause();
    _watchdogTimer?.cancel();
    _sleepTimer?.cancel();
    _firstFrameTimer?.cancel();
    _freezeClearTimer?.cancel();
    final errorSub = _platformErrorSub;
    _platformErrorSub = null;
    if (errorSub != null) unawaited(errorSub.cancel());
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
        // 来电 / 其它应用抢占音频焦点：先等一小会儿，仍在后台就暂停；
        // 通知栏 / 截屏会很快回到 resumed，不触发暂停。
        _armFocusLossPause();
        return;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        // 切后台：后台播放默认开启，完全不暂停；只复位长按倍速并记进度。
        _backgrounded = true;
        _cancelFocusLossPause();
        _endHold2x();
        unawaited(_saveProgress());
        return;
      case AppLifecycleState.resumed:
        final wasBackgrounded = _backgrounded;
        _backgrounded = false;
        _cancelFocusLossPause();
        _resetWatchdogClock();
        _resumeAfterFocusLoss();
        // 只有真正切过后台才重建画面层；通知栏 / 截屏回来不重建，避免闪帧。
        if (wasBackgrounded) _remountVideoLayer();
        return;
      case AppLifecycleState.detached:
        return;
    }
  }

  void _armFocusLossPause() {
    _cancelFocusLossPause();
    _focusLossTimer = Timer(fxAudioFocusLossGrace, () {
      _focusLossTimer = null;
      if (!mounted || _backgrounded) return;
      final c = _controller;
      if (c == null || !c.value.isInitialized || !c.value.isPlaying) return;
      _pausedByFocusLoss = true;
      unawaited(c.pause());
    });
  }

  void _cancelFocusLossPause() {
    _focusLossTimer?.cancel();
    _focusLossTimer = null;
  }

  /// 焦点恢复：只在「因失去焦点而暂停」且之前确实在播放时继续。
  void _resumeAfterFocusLoss() {
    if (!_pausedByFocusLoss) return;
    _pausedByFocusLoss = false;
    if (!mounted || _loading || _error || _switching) return;
    final c = _controller;
    if (c == null ||
        !c.value.isInitialized ||
        c.value.isPlaying ||
        c.value.isCompleted) {
      return;
    }
    unawaited(c.play());
  }

  /// 回前台只重挂 Video 层（不 open / 不 seek）：换 key 让输出层重建，
  /// 同一 FxPlayer 实例、播放位置与播放状态全部保持。
  void _remountVideoLayer() {
    if (!mounted) return;
    setState(() => _videoEpoch++);
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
        _lines = detail.lines;
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
    bool forcePlayInfo = false,
  }) async {
    final c = _controller;
    if (c == null) return;
    // 同一 line+ep 正在打开时忽略重复请求（防抖）。
    final key = '$_line|$_ep';
    final opening = _opening;
    if (opening != null && _openingKey == key) return opening;
    final future = _bootstrapSource(
      seekToSaved: seekToSaved,
      saveOld: saveOld,
      forcePlayInfo: forcePlayInfo,
    );
    _opening = future;
    _openingKey = key;
    try {
      await future;
    } finally {
      if (identical(_opening, future)) {
        _opening = null;
        _openingKey = null;
      }
    }
  }

  Future<void> _bootstrapSource({
    required bool seekToSaved,
    required bool saveOld,
    required bool forcePlayInfo,
  }) async {
    final c = _controller;
    if (c == null) return;
    final token = ++_loadToken;
    _hideTimer?.cancel();
    _cancelFirstFrameTimer();
    // 先抓最后一帧：同一个 player 实例换地址时纹理会被清空，用它垫住黑屏。
    if (_firstFrame && (_frozenFrame == null || !_freezeOpaque)) {
      await _captureFrozenFrame();
    }
    if (saveOld) await _saveProgress();
    if (!mounted || token != _loadToken) return;
    unawaited(c.pause());
    // 缓存命中时不等接口与 playlist，直接用上一帧快照垫着 open。
    final cacheHit =
        !forcePlayInfo && FxPlayCache.peek(widget.videoId, _ep, _line) != null;
    final waitForWarm = !cacheHit;
    setState(() {
      _loading = true;
      _suppressLoadingOverlay = cacheHit && _frozenFrame != null;
      _loadedEp = null;
      _error = false;
      _errorText = '';
      _ended = false;
      _sourceFailNotified = false;
      _qualityKey = null;
      _uiPosition = null;
      _uiDuration = null;
      _loadingHint = null;
      _firstFrame = false;
      _nextPrewarmed = false;
      _prewarmEp = null;
      _prewarmAt = null;
    });

    PlayInfo source;
    try {
      // 命中竖屏/上一集预解析的缓存时不再等 /api/play。
      source = await FxPlayCache.resolve(
        widget.videoId,
        _ep,
        _line,
        force: forcePlayInfo,
      );
    } catch (_) {
      if (!mounted || token != _loadToken) return;
      _notifySourceFailed();
      _failWith('获取播放地址失败，请检查网络后重试');
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
      _notifySourceFailed();
      _failWith('当前线路没有可用播放地址，请更换线路');
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
        // 8 秒拿不到可播状态就判这条地址失败，避免黑屏一直转圈。
        await c
            .open(
              url,
              headers: source.headers,
              play: true,
              waitForWarm: waitForWarm,
              direct: source.direct && source.isHls,
            )
            .timeout(_openReadyTimeout);
        if (!mounted || token != _loadToken) return;
        final durationMs = c.value.duration.inMilliseconds;
        var start = resume;
        if (durationMs > 0 && start >= durationMs / 1000.0 - 2) start = 0;
        if (start > 0) {
          await c.seekTo(Duration(milliseconds: (start * 1000).round()));
        }
        await c.setLooping(_loopMode == FxLoopMode.single);
        try {
          await c.setRate(_rate);
        } catch (_) {}
        if (!mounted || token != _loadToken) return;
        await c.play();
        if (!mounted || token != _loadToken) return;
        // open 期间可能只是"假成功"：play 后仍带错误就不要当成可播。
        if (c.value.hasError) throw StateError('player error');
        _loadedEp = _ep;
        if (!_firstFrame) _armFirstFrameTimer();
        setState(() {
          _loading = false;
          _suppressLoadingOverlay = false;
          _error = false;
          _errorText = '';
          _loadingHint = null;
        });
        _sourceFailNotified = false;
        ok = true;
        _watchdogRetried = false;
        _resetWatchdogClock();
        _wake();
        break;
      } catch (_) {
        // 换下一条备用地址继续尝试
      }
    }

    if (!ok) {
      if (!mounted || token != _loadToken) return;
      _notifySourceFailed();
      _failWith('播放失败：线路不可用，请重试或切换线路');
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
    bool direct = false,
  }) async {
    final c = _controller;
    if (c == null) return false;
    _cancelFirstFrameTimer();
    if (_firstFrame && (_frozenFrame == null || !_freezeOpaque)) {
      await _captureFrozenFrame();
    }
    _firstFrame = false;
    try {
      await c
          .open(
            url,
            headers: headers,
            play: wasPlaying,
            direct: direct,
          )
          .timeout(_openReadyTimeout);
      if (!mounted) return false;
      final duration = c.value.duration;
      var target = resume;
      if (duration > Duration.zero &&
          target >= duration - const Duration(milliseconds: 1500)) {
        target = Duration.zero;
      }
      if (target > Duration.zero) await c.seekTo(target);
      await c.setLooping(_loopMode == FxLoopMode.single);
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
      // 平台错误可能发生在 open ready 之后、play 之前：这里再查一次，
      // 避免把已经坏掉的输出当成切换成功。
      if (c.value.hasError) return false;
      // open 成功不代表首帧已出（红屏/黑屏常见于这里）：超时仍未出画面
      // 就进入错误页，而不是一直干等。
      if (!_firstFrame) _armFirstFrameTimer();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 切换清晰度：真正换 networkUrl，并恢复切换前的进度 / 倍速 / 播放状态。
  /// 新清晰度失败时回退打开原来的播放地址；连回退也失败才进入错误态。
  Future<void> _selectQuality(String? key) async {
    if (_isLive) return;
    if (_loading || _switching) {
      fxToast(context, '正在切换，请稍候');
      return;
    }
    final info = _info;
    final list = _qualityList;
    // 产品要求：只有 1 个画质时没有清晰度入口；这里再兜一层。
    if (info == null || list.length < 2) {
      fxToast(context, '当前线路暂无更多清晰度');
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
        _loading = true;
        _loadingHint = '正在切换清晰度';
        _error = false;
        _errorText = '';
        _ended = false;
        _controls = true;
        _uiPosition = resume;
        _uiDuration = resumeDuration;
        _firstFrame = false;
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
          direct: info.direct && info.isHls,
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
            direct: info.direct && info.isHls,
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
      _watchdogRetried = false;
      _resetWatchdogClock();
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
    if (_isLive) return 0; // 直播没有可回写的观看进度。
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

  /* -------------------------------------------------------------- 看门狗 */

  /// 播放中位置连续 12 秒不前进（仍在 buffering / 应该播放）时重开当前地址；
  /// 一次自愈仍失败则退出全屏并请求竖屏切下一条线路。
  void _checkWatchdog() {
    if (_isLive) return;
    if (!mounted || _watchdogBusy) return;
    if (_loading || _error || _switching || _backgrounded) {
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
    if (v.hasError) {
      unawaited(_recoverFromWatchdog());
      return;
    }
    if (!v.isPlaying && !v.isBuffering) {
      _resetWatchdogClock();
      return;
    }
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

  String? _watchdogUrl() {
    final info = _info;
    if (info == null) return null;
    final key = _qualityKey;
    if (key != null) {
      for (final q in info.quality) {
        if (q.key == key && q.url.trim().isNotEmpty) return q.url.trim();
      }
    }
    final main = info.url.trim();
    if (main.isNotEmpty) return main;
    for (final u in info.backup) {
      if (u.trim().isNotEmpty) return u.trim();
    }
    return null;
  }

  Map<String, String> _watchdogHeaders(String url) {
    for (final q in _qualityList) {
      if (q.url.trim() == url && q.headers.isNotEmpty) return q.headers;
    }
    return _info?.headers ?? const <String, String>{};
  }

  Future<void> _recoverFromWatchdog() async {
    if (!mounted || _watchdogBusy || _switching || _loading) return;
    if (_watchdogRetried) {
      await _watchdogGiveUp();
      return;
    }
    final c = _controller;
    final url = _watchdogUrl();
    if (c == null || !c.value.isInitialized || url == null) {
      await _watchdogGiveUp();
      return;
    }
    final resume = c.value.position;
    _watchdogRetried = true;
    _watchdogBusy = true;
    _hideTimer?.cancel();
    setState(() {
      _loading = true;
      _loadingHint = '正在自动恢复播放';
      _error = false;
      _errorText = '';
      _controls = true;
      _uiPosition = resume;
      _uiDuration = c.value.duration > Duration.zero ? c.value.duration : null;
      _firstFrame = false;
    });
    final ok = await _openSource(
      url,
      headers: _watchdogHeaders(url),
      resume: resume,
      wasPlaying: true,
      direct: (_info?.direct ?? false) && (_info?.isHls ?? false),
    );
    _watchdogBusy = false;
    if (!mounted) return;
    if (ok) {
      _watchdogRecoverPending = true;
      _loadedEp = _ep;
      _resetWatchdogClock();
      setState(() {
        _loading = false;
        _loadingHint = null;
        _uiPosition = null;
        _uiDuration = null;
      });
      _wake();
    } else {
      await _watchdogGiveUp();
    }
  }

  Future<void> _watchdogGiveUp() async {
    if (!mounted) return;
    if (widget.canChangeLine && !_exiting) {
      // 全屏没有线路列表：退给竖屏自动切下一条，比停在全屏黑屏更好。
      fxToast(context, '播放无法恢复，正在切换线路');
      await _exit(requestLineChange: true);
      return;
    }
    setState(() {
      _loading = false;
      _loadingHint = null;
      _loadedEp = null;
      _error = true;
      _errorText = '加载失败，重试';
      _uiPosition = null;
      _uiDuration = null;
    });
    _wake();
  }

  /* ------------------------------------------------------ 首帧 / 错误检测 */

  /// 是否已经拿到视频画面参数（宽高 > 0）。open 成功但一直没画面时，
  /// 由 [_firstFrameTimeout] 兜底进入错误页。
  bool _hasFirstFrame(FxPlayer? player) {
    final v = player?.value;
    if (v == null || !v.isInitialized) return false;
    var w = v.videoWidth ?? 0;
    var h = v.videoHeight ?? 0;
    if (w <= 0) w = v.width ?? 0;
    if (h <= 0) h = v.height ?? 0;
    return w > 0 && h > 0;
  }

  void _armFirstFrameTimer() {
    _firstFrameTimer?.cancel();
    _firstFrameTimer = Timer(_firstFrameTimeout, () {
      _firstFrameTimer = null;
      if (!mounted || _error || _exiting) return;
      if (!_firstFrame && _hasFirstFrame(_controller)) {
        _firstFrame = true;
        _failStreak = 0;
        setState(() {});
        return;
      }
      if (_firstFrame) return;
      unawaited(_onPlaybackFailure());
    });
  }

  void _cancelFirstFrameTimer() {
    _firstFrameTimer?.cancel();
    _firstFrameTimer = null;
  }

  /// 切片源之前抓一帧当前画面。新地址 open 会清空 Video 纹理，
  /// 用这张快照垫在黑底上，等新流首帧出来再淡出，切换过程就不会闪黑。
  Future<void> _captureFrozenFrame() async {
    final c = _controller;
    if (c == null) return;
    // 抓取失败返回 null：退回纯黑 + 加载层，不弹错也不影响切源。
    final bytes = await c.captureFrame();
    if (!mounted || bytes == null) return;
    _freezeClearTimer?.cancel();
    _freezeClearTimer = null;
    setState(() {
      _frozenFrame = bytes;
      _freezeOpaque = true;
    });
  }

  /// 新流首帧已出：快照 200ms 淡出，露出新画面。
  void _fadeOutFrozenFrame() {
    if (_frozenFrame == null || !_freezeOpaque) return;
    _freezeClearTimer?.cancel();
    _freezeClearTimer = null;
    if (!mounted) return;
    setState(() => _freezeOpaque = false);
    _freezeClearTimer = Timer(const Duration(milliseconds: 240), () {
      _freezeClearTimer = null;
      if (!mounted || _freezeOpaque) return;
      setState(() => _frozenFrame = null);
    });
  }

  /// media_kit 平台错误（Video 层解码 / 输出失败）：直接进错误页。
  /// open / 切清晰度期间由各自 try/catch 处理，避免重复弹错误。
  void _onPlatformError(String message) {
    if (!mounted || _exiting || _error || _loading) return;
    unawaited(_onPlaybackFailure());
  }

  /// 一次真实播放失败：记录连续失败次数；首帧从未出来时展示
  /// 「加载失败，重试」，连续 2 次自动让竖屏切下一条线路。
  Future<void> _onPlaybackFailure() async {
    if (!mounted || _exiting || _error || _failureBusy) return;
    _failureBusy = true;
    _firstFrameTimer?.cancel();
    _firstFrameTimer = null;
    final c = _controller;
    _positionBeforeError = c?.value.position ?? Duration.zero;
    if (c != null && c.value.isInitialized) {
      try {
        await c.pause();
      } catch (_) {
        // 播放器已经坏了，暂停失败不影响展示错误页。
      }
    }
    _failureBusy = false;
    if (!mounted || _exiting || _error) return;
    _failWith('加载失败，重试');
  }

  /// 连续失败达到 2 次且还有其它线路时，退出全屏交给竖屏自动换线路。
  bool _registerFailure() {
    _failStreak++;
    if (_failStreak >= 2 && widget.canChangeLine && !_exiting) {
      if (mounted) fxToast(context, '连续加载失败，正在切换线路');
      unawaited(_exit(requestLineChange: true));
      return true;
    }
    return false;
  }

  /// 统一失败收尾：要么自动换线路退出，要么停留在可重试的错误页。
  void _failWith(String text) {
    if (!mounted || _exiting) return;
    _cancelFirstFrameTimer();
    // 失败即未加载成功：退出全屏时不能让竖屏把这一集记成「已加载」。
    _loadedEp = null;
    _freezeClearTimer?.cancel();
    _freezeClearTimer = null;
    _frozenFrame = null;
    _freezeOpaque = false;
    if (_registerFailure()) return;
    if (!mounted) return;
    setState(() {
      _loading = false;
      _loadingHint = null;
      _loadedEp = null;
      _error = true;
      _errorText = text;
      _controls = true;
      _uiPosition = null;
      _uiDuration = null;
    });
    _wake();
  }

  /// 错误页「重试」：不再重新请求接口，直接用当前地址重新 open，
  /// 尽量接着出错前的位置播放。
  Future<void> _retryPlayback() async {
    if (!mounted || _exiting || _loading || _switching) return;
    final c = _controller;
    if (c == null) return;
    final url = _watchdogUrl();
    if (url == null) {
      // 上次连播放地址都没拿到：强制刷新播放地址再试一次。
      await _bootstrap(
        seekToSaved: true,
        saveOld: false,
        forcePlayInfo: true,
      );
      return;
    }
    final resume = _positionBeforeError > Duration.zero
        ? _positionBeforeError
        : c.value.position;
    final headers = _watchdogHeaders(url);
    final token = ++_loadToken;
    _cancelFirstFrameTimer();
    setState(() {
      _loading = true;
      _loadingHint = '正在重新连接';
      _error = false;
      _errorText = '';
      _firstFrame = false;
      _controls = true;
      _uiPosition = resume > Duration.zero ? resume : null;
      _uiDuration = c.value.duration > Duration.zero ? c.value.duration : null;
    });
    final ok = await _openSource(
      url,
      headers: headers,
      resume: resume,
      wasPlaying: true,
      direct: (_info?.direct ?? false) && (_info?.isHls ?? false),
    );
    if (!mounted || token != _loadToken) return;
    if (!ok) {
      _failWith('加载失败，重试');
      return;
    }
    _loadedEp = _ep;
    _sourceFailNotified = false;
    _watchdogRetried = false;
    _resetWatchdogClock();
    if (!_firstFrame) _armFirstFrameTimer();
    setState(() {
      _loading = false;
      _loadingHint = null;
    });
    _wake();
  }

  void _onVideoValue() {
    final c = _controller;
    if (c == null || !mounted) return;
    final v = c.value;
    // 首帧检测：open 成功不等于画面已经出来，参数真正到达后才算。
    if (!_firstFrame && _hasFirstFrame(c)) {
      _firstFrame = true;
      _failStreak = 0;
      _cancelFirstFrameTimer();
      _fadeOutFrozenFrame();
      setState(() {});
    } else if (_firstFrame && _loading && !v.isInitialized) {
      // 重新 open 会重置播放器：画面层退回纯黑，避免残留红屏 / 黑屏。
      _firstFrame = false;
      setState(() {});
    }
    // loading 期间的错误交给 _bootstrap / _openSource 的 try/catch 处理。
    if (_loading || _error) return;
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
    final quality = _qualityText;
    if (quality.isNotEmpty && quality != _qualitySeen) {
      _qualitySeen = quality;
      setState(() {});
    }
    if (v.hasError) {
      unawaited(_onPlaybackFailure());
      return;
    }
    if (!v.isInitialized) return;
    if (!v.isCompleted) {
      _ended = false;
      return;
    }
    if (_isLive) return; // 直播流断开由重新拉流处理，不走「播完下一集」。
    if (_ended) return;
    _ended = true;
    unawaited(_handleEnded());
  }

  Future<void> _handleEnded() async {
    if (_isLive) return;
    await _saveProgress(ended: true);
    if (!mounted) return;
    if (_loopMode == FxLoopMode.single) {
      final c = _controller;
      if (c != null) {
        try {
          await c.seekTo(Duration.zero);
          await c.play();
        } catch (_) {}
      }
      return;
    }
    if (_loopMode == FxLoopMode.off) {
      _wake();
      fxToast(context, '已播放结束');
      return;
    }
    final next = _nextEpNumber();
    if (next != null) {
      await _switchEp(next, auto: true);
    } else {
      _wake();
      fxToast(context, '已播放完最后一集');
    }
  }

  /// 当前集播过 30 秒后后台预热下一集 /api/play 与 m3u8（只请求，不 open）。
  void _maybePrewarmNext() {
    if (_isLive) return;
    if (!mounted || _loading || _error) return;
    final c = _controller;
    final loaded = _loadedEp;
    if (c == null || loaded == null || loaded != _ep) return;
    if (!c.value.isInitialized || c.value.hasError) return;
    if (c.value.position < const Duration(seconds: 30)) return;
    final next = _nextEpNumber();
    if (next == null) return;
    // 已预热同一集时每 5 分钟刷新一次，避免长剧集播完时地址已过期。
    if (_nextPrewarmed && _prewarmEp == next) {
      final at = _prewarmAt;
      if (at != null &&
          DateTime.now().difference(at) < const Duration(minutes: 5)) {
        return;
      }
    }
    _nextPrewarmed = true;
    _prewarmEp = next;
    _prewarmAt = DateTime.now();
    FxPlayCache.prewarm(widget.videoId, next, _line);
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
    if (_isLive) return;
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
    if (_isLive) return;
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
    _hideTimer = Timer(kPlayerControlsAutoHide, () {
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
      _showQuality = false;
    });
  }

  void _onSurfaceTap() {
    if (_locked) return;
    if (_panelOpen) {
      _closePanels();
      return;
    }
    if (_error) return;
    // 加载 / 切集期间也允许显隐控件，控件点击不再被整层 IgnorePointer 吞掉。
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
      _showQuality = false;
    });
    _hideTimer?.cancel();
    // 锁按钮只亮 3 秒，之后完全隐藏；不弹 toast 打扰观看。
    _startUnlockTimer();
  }

  /// 锁定后解锁钮只亮 3 秒；点屏幕可重新唤出（同样 3 秒后隐藏）。
  void _startUnlockTimer() {
    _unlockTimer?.cancel();
    _unlockTimer = Timer(kPlayerUnlockAutoHide, () {
      if (!mounted || !_locked) return;
      setState(() => _unlockVisible = false);
    });
  }

  void _onLockedTap() {
    if (!mounted) return;
    if (!_unlockVisible) setState(() => _unlockVisible = true);
    _startUnlockTimer();
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

  void _togglePlay() {
    final c = _controller;
    if (c == null ||
        _loading ||
        _error ||
        _switching ||
        !c.value.isInitialized) {
      return;
    }
    // 用户手动暂停 / 播放后，焦点恢复不再替他继续播放。
    _pausedByFocusLoss = false;
    // 直接让 media_kit 切换，图标由 player.stream.playing 驱动，避免本地态覆盖。
    unawaited(c.playOrPause());
    _wake();
  }

  void _seekTo(Duration d) {
    if (_isLive) return; // 直播没有可回看的进度。
    final c = _controller;
    if (c == null || _loading || _switching || !c.value.isInitialized) return;
    unawaited(c.seekTo(d));
    _wake();
  }

  void _seekBy(int seconds) {
    if (_isLive) return;
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
    if (_isLive) return;
    final c = _controller;
    if (c == null ||
        _loading ||
        _error ||
        _switching ||
        !c.value.isInitialized) {
      return;
    }
    _rateBeforeHold = _rate;
    unawaited(_applyRate(kPlayerHoldRate));
    _hideTimer?.cancel();
    setState(() {
      _holding2x = true;
      // 参考：长按进入快进时收起控件，只在顶部留「3.0倍速快进中」胶囊。
      _controls = false;
      _showSpeed = false;
      _showQuality = false;
    });
  }

  void _endHold2x() {
    if (!_holding2x) return;
    unawaited(_applyRate(_rateBeforeHold));
    if (!mounted) return;
    setState(() => _holding2x = false);
  }

  void _toggleSpeed() {
    if (_isLive) {
      fxToast(context, '直播不支持倍速');
      return;
    }
    _hideTimer?.cancel();
    setState(() {
      _showSpeed = !_showSpeed;
      _showQuality = false;
      _controls = true;
    });
    if (!_showSpeed) _wake();
  }

  Future<void> _openEpisodeSheet() async {
    if (_isLive) {
      fxToast(context, '直播没有选集');
      return;
    }
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
    if (_isLive) return;
    if (_loading || _switching) {
      fxToast(context, '正在切换，请稍候');
      return;
    }
    _hideTimer?.cancel();
    if (!_canChangeQuality) {
      fxToast(context, '当前线路暂无更多清晰度');
      _wake();
      return;
    }
    setState(() {
      _showQuality = !_showQuality;
      _showSpeed = false;
      _controls = true;
    });
    if (!_showQuality) _wake();
  }

  void _setFillScreen(bool value) {
    if (_fillScreen == value) return;
    setState(() => _fillScreen = value);
    unawaited(fxSaveFillScreen(value));
  }

  Future<void> _openMorePanel() async {
    if (_isLive) {
      fxToast(context, '直播暂不支持更多设置');
      _wake();
      return;
    }
    _hideTimer?.cancel();
    if (mounted) setState(() => _controls = true);
    await showFxMorePanel(
      context,
      loopMode: _loopMode,
      skipIntroOutro: _skipIntroOutro,
      fillScreen: _fillScreen,
      onFillChanged: _setFillScreen,
      onLoopChanged: (mode) {
        if (!mounted) return;
        setState(() => _loopMode = mode);
        unawaited(
          _controller?.setLooping(mode == FxLoopMode.single) ??
              Future<void>.value(),
        );
        fxToast(context, '循环播放：${mode.label}');
      },
      onSkipChanged: (on) {
        if (!mounted) return;
        setState(() => _skipIntroOutro = on);
        fxToast(context, on ? '已开启跳过片头片尾' : '已关闭跳过片头片尾');
      },
      onPip: () => fxToast(context, '画中画：当前版本暂不支持'),
      onSleepTimer: () => unawaited(_openSleepTimerPicker()),
      onDownload: () => fxToast(context, '请到详情页下载本集'),
      onSpeed: () => unawaited(_openSpeedPicker()),
      onBackground: () => fxToast(context, '后台播放已开启'),
      onFeedback: () => fxToast(context, '问题反馈：请到「我的-意见反馈」提交'),
    );
    if (!mounted) return;
    _wake();
  }

  Future<void> _openSpeedPicker() async {
    final rate = await showFxSpeedSheet(context, _rate);
    if (!mounted || rate == null) return;
    _setRate(rate);
  }

  Future<void> _openSleepTimerPicker() async {
    final minutes = await showFxSleepTimerSheet(context);
    if (!mounted || minutes == null) return;
    _setSleepTimer(minutes);
  }

  void _setSleepTimer(int minutes) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    if (minutes <= 0) {
      fxToast(context, '已取消定时关闭');
      return;
    }
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      _sleepTimer = null;
      if (!mounted) return;
      unawaited(_controller?.pause());
      fxToast(context, '定时关闭：已暂停播放');
    });
    fxToast(context, '将在 $minutes 分钟后暂停播放');
  }

  Future<void> _screenshot() async {
    final boundary = _captureKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) {
      fxToast(context, '截图失败，请稍后重试');
      return;
    }
    try {
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) throw StateError('empty image');
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/fx_shot_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(data.buffer.asUint8List());
      if (!mounted) return;
      fxToast(context, '截图已保存');
    } catch (_) {
      if (!mounted) return;
      fxToast(context, '截图失败，请稍后重试');
    }
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
        fillScreen: _fillScreen,
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
        body: RepaintBoundary(
          key: _captureKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(child: _buildVideoSurface(c)),
              // 手势层：单击显隐控件 / 双击暂停 / 横扫调进度 / 竖扫亮度音量 /
              // 长按 3.0x。加载与切清晰度时仍保留手势（按钮的 no-op 由页面自己判）。
              if (!_locked && c != null)
                Positioned.fill(
                  child: FxPlayerGestures(
                    player: c,
                    enabled: !_error,
                    onTap: _onSurfaceTap,
                    onDoubleTap: _togglePlay,
                    onSeek: _seekTo,
                    enableSeek: !_isLive,
                    onLongPressStart: _isLive ? null : _startHold2x,
                    onLongPressEnd: _isLive ? null : _endHold2x,
                    onGestureStart: _hideControls,
                    resetBrightnessOnDispose: true,
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
              // 加载 / 首帧 / 缓冲层：在视频之上、控件层之下，不挡底部按钮。
              // 缓冲百分比来自 stream.buffer（真实已缓冲位置）÷ duration；
              // 时长未知时用不确定转圈 + 「缓冲中…」，绝不显示假的 100%。
              if (!_error && c != null)
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: c,
                    builder: (context, _) => _buildStatusOverlay(c),
                  ),
                ),
              // 控件层必须在 loading/缓冲层之上：切集 8s 窗口里也能退出全屏、
              // 选集、点下一集；只按「控件是否显示」禁用指针。
              if (!_locked)
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !_controls,
                    child: AnimatedOpacity(
                      opacity: _controls ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: _buildControls(c, keyboard, pad),
                    ),
                  ),
                ),
              if (_error) _buildError(),
              // 锁屏：所有控件隐藏；解锁钮只亮 3 秒（点屏幕再亮 3 秒），
              // 不常驻，也不再弹锁定 toast。
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
                        FsUnlockButton(
                          onUnlock: _unlock,
                          visible: _unlockVisible,
                        ),
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
                  child: const Center(child: _FsBadge(text: '3.0倍速快进中')),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildVideoSurface(FxPlayer? c) {
    // 底部控制条：26 上边距 + 40 进度条 + 4 间距 + 34 按钮 + 6 下边距，
    // 再留 12dp 间距，字幕层就不会压在进度条/按钮上。
    final controlsHeight =
        26.0 + 40.0 + 4.0 + 34.0 + 6.0 + MediaQuery.paddingOf(context).bottom;
    // 首帧未出 / 出错时不要挂 Video 纹理：部分设备会显示红屏或透明残帧。
    // 始终先铺纯黑底色，再把 Video 放上去，缓冲时不会出现纯黑无内容的画面。
    final showVideo =
        c != null && c.value.isInitialized && _firstFrame && !_error;
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          if (showVideo)
            // 默认 contain：完整显示、不裁字幕，可能有细黑边；
            // 只有打开「撑满全屏」才 cover（等比裁边、不拉伸变形）。
            FxPlayerSurface(
              key: ValueKey<int>(_videoEpoch),
              player: c,
              fit: fxFullscreenFit(_fillScreen),
              subtitleBottom: controlsHeight + 12,
            ),
          // 切集 / 切清晰度：最后一帧垫在黑底上，首帧就绪后 200ms 淡出。
          if (_frozenFrame != null)
            Positioned.fill(
              child: FxSnapshotLayer(
                bytes: _frozenFrame,
                opaque: _freezeOpaque,
                fit: fxFullscreenFit(_fillScreen),
              ),
            ),
        ],
      ),
    );
  }

  /// 首帧 / 加载 / 缓冲统一浮层。
  Widget _buildStatusOverlay(FxPlayer c) {
    final v = c.value;
    // 缓存命中且已有上一帧快照：切集时连 loading 浮层都跳过，只留快照。
    if (_loading && _suppressLoadingOverlay && _frozenFrame != null) {
      return const SizedBox.shrink();
    }
    // 首帧未出 / 正在加载：只显示单行文案，线路名按当前 lineId 查，
    // 不再叠一行旧线路名小字。
    final loading = _loadingHint ?? fxLoadingLineText(_ep, _lineName);
    // 真实缓存进度：起播 / 切集阶段有 buffer 就显示，不拿假进度凑数。
    if (!_firstFrame || _loading) {
      return FxLoadingOverlay(
        title: loading,
        percent: v.bufferingPercent,
        dim: _frozenFrame == null,
      );
    }
    if (!v.isBuffering) return const SizedBox.shrink();
    final percent = v.bufferingPercent;
    return FxLoadingOverlay(
      title: percent == null ? '缓冲中…' : '缓冲中 ${percent.round()}%',
      percent: percent,
      dim: false,
      compact: true,
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
                  if (!_isLive) ...[
                    _errorAction('重试', () {
                      unawaited(_retryPlayback());
                    }),
                    if (widget.canChangeLine) ...[
                      const SizedBox(width: 10),
                      _errorAction(
                        '换线路',
                        () => unawaited(_exit(requestLineChange: true)),
                      ),
                    ],
                    const SizedBox(width: 10),
                  ],
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
            epLabel: _isLive ? 'LIVE · 直播中' : _epLabel,
            quality: _isLive ? '' : _qualityText,
            compact: compact,
            onBack: () => unawaited(_exit()),
            onCast: () => fxToast(context, '投屏：暂无可用设备'),
            onScreenshot: () => unawaited(_screenshot()),
            onMore: () => unawaited(_openMorePanel()),
          ),
        ),
        Positioned.fill(
          child: FsSideControls(
            onLock: _lock,
            onSeekBy: _seekBy,
            showSeek: !_isLive,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: keyboard,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_isLive && _showQuality)
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
              if (!_isLive && _showSpeed)
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
                      qualityLabel: _isLive
                          ? ''
                          : (_canChangeQuality ? '清晰度' : ''),
                      qualityActive:
                          !_isLive && _canChangeQuality && _qualityKey != null,
                      compact: compact,
                      bottomInset: bottomInset,
                      live: _isLive,
                      onSeek: _isLive ? null : _seekTo,
                      onTogglePlay: _togglePlay,
                      onNext: _isLive ? null : () => unawaited(_next()),
                      onSpeed: _isLive ? null : _toggleSpeed,
                      onQuality: _isLive ? null : _toggleQuality,
                      onEpisodes: _isLive
                          ? null
                          : () => unawaited(_openEpisodeSheet()),
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

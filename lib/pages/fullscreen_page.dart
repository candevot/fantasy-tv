import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../models.dart';
import '../services/cast_service.dart';
import '../services/app_settings.dart';
import '../services/fx_player.dart';
import '../services/screen_orientation.dart';
import '../services/video_marks.dart';
import '../theme.dart';
import '../widgets/cast_sheet.dart';
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
    this.sourceFailed = false,
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

  /// 全屏内连续播放失败/平台签名过期后自动请求换线（不是用户点的）。
  /// 为 true 时竖屏走与竖屏失败完全相同的路径：先原线重试一次（带缓冲），
  /// 重试仍失败才记入失败线路并切下一条。
  final bool sourceFailed;
}

/// 全屏横屏播放页
///
/// 直接复用竖屏传入的 [FxPlayer]（同一个 Player / VideoController）：
/// 进入和退出全屏都不重新创建、不重新 open，进度与暂停状态自然保持。
/// 进入即横屏 + 沉浸式，退出恢复竖屏；控件 5 秒自动隐藏，点击画面切换显隐；
/// 锁屏后只剩解锁按钮（锁定瞬间亮 3 秒自动淡出，点屏幕切换显隐），
/// 其它手势全部失效。
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
    this.isLive = false,
    this.castSource,
    this.castOwner,
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

  /// 直播全屏：复用同一个播放器，但隐藏进度条 / 选集 / 倍速 / 下一集，
  /// 左右横滑不再 seek，底部常驻 LIVE。默认 false，不影响点播。
  final bool isLive;

  /// 直播没有 PlayInfo，由直播详情页把当前线路地址带进来；点播为 null，
  /// 全屏自己从 _info 解析。
  final CastSource? castSource;

  /// 投屏会话归属页（竖屏详情页 / 直播详情页），退出页面时停自己的投屏。
  final Object? castOwner;

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

  /// 切集 / 重连前抓下的最后一帧：盖在黑底和新画面之间，
  /// 等新流首帧出来再淡出，避免切换过程中闪一下黑屏。
  Uint8List? _frozenFrame;
  bool _freezeOpaque = false;
  Timer? _freezeClearTimer;

  /// 防止平台错误与首帧超时重复进入错误页。
  bool _failureBusy = false;

  /// 出错前的播放位置，重试时尽量接着播。
  Duration _positionBeforeError = Duration.zero;

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

  /// 全屏内实际 open 成功的地址 / 请求头（重新 open 后投屏要跟着变）。
  String? _activeCastUrl;
  Map<String, String> _activeCastHeaders = const <String, String>{};

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

  /// 是否已切到后台：切后台 / inactive / paused 一律不暂停，继续播放，
  /// 回前台接着播（不重新 open、不 seek）；看门狗在后台停摆，避免误判卡顿。
  bool _backgrounded = false;

  /// 切后台那一刻的播放位置与播放状态：系统可能冻结 libmpv 或把进度重置
  /// 到片头，回前台按这两项判断要不要自愈（拉回原进度并继续播）。
  Duration _backgroundAnchor = Duration.zero;
  bool _backgroundWasPlaying = true;

  /// 回前台只重建 Video 输出层（换 key），播放器实例与进度保持不动。
  int _videoEpoch = 0;
  bool _locked = false;

  /// 锁屏后解锁钮是否可见：锁定瞬间亮 3 秒后自动隐藏（[_startUnlockTimer]），
  /// 之后由点屏幕即时切换显隐（隐藏 0 延迟），不会常驻。
  bool _unlockVisible = false;
  Timer? _unlockTimer;

  // 弹层
  bool _showSpeed = false;

  /// 定时关闭右侧面板（不开启 / 看完当集 / 30·60·90 分钟 / 自定义）。
  bool _showSleep = false;

  /// 片头 / 片尾标记面板：底部「片头/尾」按钮打开。
  bool _showJump = false;

  /// 循环播放只剩 单集循环 / 关闭（对应 mpv setLooping）；「列表循环」已删，
  /// 连播交给设置页的「自动下一集」开关。
  FxLoopMode _loopMode = FxLoopMode.off;

  /// 本剧片头 / 片尾标记（按 videoId 存 [VideoMarks]）。
  /// 没加载到或没标记 = 空标记 = 任何位置都不跳（默认）。
  VideoMark _mark = const VideoMark();

  /// 片头 / 片尾每集各只触发一次：[_skipTag] 记当前集，换集自动复位。
  int? _skipTag;
  bool _introFired = false;
  bool _outroFired = false;

  Timer? _sleepTimer;

  /// 切线路 / 重连期间锁住 UI 进度，防止播放器 open 归零时进度条跳回 0。
  Duration? _uiPosition;
  Duration? _uiDuration;
  Timer? _uiHoldTimer;

  /// loading 浮层文案（重新连接时显示「正在重新连接」）。
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

  bool get _panelOpen => _showSpeed || _showSleep || _showJump;

  bool get _playing => _controller?.value.isPlaying ?? false;

  /// 直播模式：不做进度回写、倍速、选集、看门狗与按秒 seek。
  bool get _isLive => widget.isLive;

  List<QualityItem> get _qualityList => _info?.quality ?? const <QualityItem>[];

  /// 顶栏画质胶囊文案：真实分辨率 `宽x高`（如 1920x1080），未就绪时为空。
  String get _qualityText => fxPlayerQuality(_controller);

  /// 全屏顶栏「投屏」：复用竖屏解析好的当前清晰度 / 直播地址。
  CastSource _buildCastSource() {
    final info = _info;
    if (info == null) throw const CastException('投屏地址还没准备好');
    final active = _activeCastUrl?.trim() ?? '';
    final url = active.isNotEmpty ? active : _watchdogUrl();
    if (url == null) throw const CastException('当前没有可投屏的播放地址');
    final headers =
        active.isNotEmpty ? _activeCastHeaders : _watchdogHeaders(url);
    return CastService.resolveSource(
      url: url,
      headers: headers,
      title: _isLive ? _title : '$_title · $_epLabel',
      isLive: _isLive,
      direct: info.direct,
      startAt:
          _isLive ? Duration.zero : (_controller?.value.position ?? Duration.zero),
      serverBase: Api.base,
    );
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
    _rate = widget.rate > 0 ? widget.rate : (c.rate > 0 ? c.rate : 1.0);
    _loadedEp = c.value.isInitialized ? _ep : null;
    _loading = !c.value.isInitialized;
    _firstFrame = _hasFirstFrame(c);
    // 全屏复用的是竖屏已经打开的播放器：这里只监听错误流，不重新 open。
    // 播放层已换成 betterplayer，错误流由 FxPlayer 统一暴露。
    _platformErrorSub = c.errorStream.listen(_onPlatformError);
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
      if (widget.videoId.isNotEmpty && _episodes.isEmpty) {
        unawaited(_loadEpisodeMeta());
      }
      unawaited(_loadMarks());
    }
    // 持久化的分钟定时：退出全屏/杀进程再进来按剩余时间续上。
    unawaited(_restoreSleepTimer());
    _startHideTimer();
  }

  @override
  void dispose() {
    // 退出全屏也要复位长按倍速，不能让 3.0x 留在共享播放器上。
    _resetHold2x(notify: false);
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _seekHintTimer?.cancel();
    _unlockTimer?.cancel();
    _uiHoldTimer?.cancel();
    _progressTimer?.cancel();
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
        // 多任务 / 分屏 / 小窗 / 下拉通知栏：只失去前台焦点，绝不暂停。
        return;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        // 切后台：只复位长按倍速并记进度，永不暂停（系统 paused 也继续播；
        // 来电 / 被其它应用抢占音频属系统音频策略，不由 App 断播）。
        _backgrounded = true;
        _backgroundAnchor = _controller?.value.position ?? _backgroundAnchor;
        _backgroundWasPlaying = _controller?.value.isPlaying ?? true;
        _endHold2x();
        unawaited(_saveProgress());
        return;
      case AppLifecycleState.resumed:
        final wasBackgrounded = _backgrounded;
        _backgrounded = false;
        // 只有真正切过后台才重建画面层；通知栏 / 截屏回来不重建，避免闪帧。
        if (wasBackgrounded) {
          _remountVideoLayer();
          unawaited(_recoverAfterBackground());
        }
        return;
      case AppLifecycleState.detached:
        return;
    }
  }

  // 切后台永不暂停：不再有「paused 超时暂停」的定时器，回前台也不补 play
  // （播放状态从头到尾没有被 App 改过，直接接着播，不重新 open、不 seek）。

  /// 回前台只重挂 Video 层（不 open / 不 seek）：换 key 让输出层重建，
  /// 同一 FxPlayer 实例、播放位置与播放状态全部保持。
  void _remountVideoLayer() {
    if (!mounted) return;
    setState(() => _videoEpoch++);
  }

  /// 回前台自愈：系统在后台可能冻结 libmpv（位置不动、playing=false）或把
  /// 进度重置到片头，用户点播放就从 0 重来。按切后台时的位置拉回去并继续播。
  Future<void> _recoverAfterBackground() async {
    final c = _controller;
    if (c == null || _loading || _error) return;
    final anchor = _backgroundAnchor;
    if (anchor <= Duration.zero) return;
    final healed = await c.recoverAfterBackground(
      anchor,
      wasPlaying: _backgroundWasPlaying,
    );
    if (!mounted) return;
    if (!healed) {
      // 同上：位置没异常也可能已经断流，交给播放器自检（断了自动重连）。
      await c.resumeSelfCheck();
      return;
    }
    setState(() {});
  }

  /* ------------------------------------------------------------------ 系统 */

  Future<void> _enterImmersive() async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    } catch (_) {
      // 桌面 / 模拟器上不支持也无所谓
    }
    // 横屏必须走 SENSOR_LANDSCAPE：SystemChrome 的 landscape* 会被引擎映射成
    // USER_LANDSCAPE，遵守系统「自动旋转」开关，竖屏锁定下转不了横屏。
    await ScreenOrientation.landscape();
  }

  Future<void> _restoreSystemUi() async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(_appOverlay);
    } catch (_) {}
    await ScreenOrientation.portrait();
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
    // 全屏内切集 / 重试会重新拉流：先结束投屏，避免电视和手机双声。
    if (CastService.instance.isCasting) {
      await CastService.instance.stop();
      if (!mounted) return;
    }
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

  /// 切集 / 重载时是否继续播放：暂停态保持暂停，未就绪 / 出错 / 刚播完
  /// 则按「继续播放」处理。
  bool _shouldContinuePlayback(FxPlayer c) {
    final v = c.value;
    if (!v.isInitialized || v.hasError || v.isCompleted) return true;
    return v.isPlaying;
  }

  Future<void> _bootstrapSource({
    required bool seekToSaved,
    required bool saveOld,
    required bool forcePlayInfo,
  }) async {
    final c = _controller;
    if (c == null) return;
    // 换集 / 重试时手势可能还没收到 onLongPressEnd，先把长按倍速清掉。
    _resetHold2x();
    final token = ++_loadToken;
    _hideTimer?.cancel();
    _cancelFirstFrameTimer();
    // 先抓最后一帧：同一个 player 实例换地址时纹理会被清空，用它垫住黑屏。
    if (_firstFrame && (_frozenFrame == null || !_freezeOpaque)) {
      await _captureFrozenFrame();
    }
    if (saveOld) await _saveProgress();
    if (!mounted || token != _loadToken) return;
    final continuePlayback = _shouldContinuePlayback(c);
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
    // 统一补成绝对地址，让 mpv 直连（避免客户端代理整片下完才播）。
    final candidates = <String>[];
    for (final u in all) {
      final abs = fxAbsolutePlayUrl(u);
      if (!candidates.contains(abs)) candidates.add(abs);
    }
    if (candidates.isEmpty) {
      _notifySourceFailed();
      _failWith('当前线路没有可用播放地址，请更换线路');
      return;
    }

    var resume = 0.0;
    if (seekToSaved) {
      resume = await fxLoadProgress(widget.videoId, _ep);
      // 不足 60 秒视为「刚看片头」，直接从头播，避免误跳片头。
      if (resume < fxResumeMinSeconds) resume = 0;
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
              play: continuePlayback,
              waitForWarm: waitForWarm,
              // 采集线路直连（mpv 边下边播）；只有平台签名线路走代理。
              // 按实际地址判断：腾讯直连是 CDN 绝对地址，不需要代理；
              // 只有爱奇艺 /api/iqiyi.m3u8 这类站内包装地址才需要。
              // HLS 一律交给本地代理，才能享受整集预加载（与主播放页一致）。
              direct: fxShouldUseHlsProxy(url, isHls: source.isHls),
              refreshPlay: _refreshPlatformUrl,
              onPlayExpired: _onPlatformExpired,
              rescueLines: _rescueLineSource,
            )
            .timeout(_openReadyTimeout);
        if (!mounted || token != _loadToken) return;
        final durationMs = c.value.duration.inMilliseconds;
        var start = resume;
        // 片尾窗口内一律从头播：用户上次在最后几十秒退出很常见，
        // 照原样续播就成了「一打开就是片尾曲、总共只剩几十秒」。
        if (fxIsFinishedPosition(start, durationMs / 1000.0)) start = 0;
        if (start > 0) {
          // 静默续播：直接 seek 到上次位置，不弹任何提示。
          await c.seekTo(Duration(milliseconds: (start * 1000).round()));
        }
        await c.setLooping(_loopMode == FxLoopMode.single);
        try {
          await c.setRate(_rate);
        } catch (_) {}
        if (!mounted || token != _loadToken) return;
        if (continuePlayback) {
          await c.play();
        } else {
          // 本来暂停：先拉一帧再暂停，切集后不黑屏。
          await c.play();
          await Future<void>.delayed(const Duration(milliseconds: 60));
          await c.pause();
        }
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
        _wake();
        // 续播静默处理：直接停在上次位置，不弹「已跳到上次位置」提示。
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
            direct: fxShouldUseHlsProxy(url, isHls: true),
            refreshPlay: _refreshPlatformUrl,
            onPlayExpired: _onPlatformExpired,
            rescueLines: _rescueLineSource,
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
        // 暂停状态下也先拉一帧再暂停，避免重新 open 后停在黑屏。
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
      _activeCastUrl = url;
      _activeCastHeaders = headers;
      return true;
    } catch (_) {
      return false;
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
    // 片尾窗口内归零（见 fxIsFinishedPosition）：否则用户在最后几十秒
    // 退出，下次打开会直接跳到片尾，看起来像「一打开就是片尾曲」。
    if (!ended &&
        fxIsFinishedPosition(positionMs / 1000.0, durationMs / 1000.0)) {
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

  /* ------------------------------- 无感救援链（FxPlayer 内部） / 地址工具 */

  // 停摆 / 出错的自愈已整体搬进 FxPlayer：连续 30 秒「完全无字节流动」
  // 才判失败（缓冲中只显示「缓冲中 xx%」），随后播放器静默跑
  // ①refreshPlay 换地址 ②同地址重开并 seek 回原进度 ③换下一条线路，
  // 每步结果写进 proxy.log；三步都失败后播放器带 hasError，页面这里
  // 只通过 _onPlaybackFailure 弹一次错误层。

  /// 无感救援链第③步：本线路 ①②自救都失败后，播放器静默回调这里取
  /// 下一条线路的地址（换完它自己 seek 回原进度）。
  Future<FxLineSource?> _rescueLineSource() async {
    if (!mounted || _exiting) return null;
    if (_lines.length < 2 || widget.videoId.isEmpty) return null;
    final index = _lines.indexWhere((l) => l.id == _line);
    for (var k = 1; k <= _lines.length; k++) {
      final next = _lines[(index + k) % _lines.length];
      if (next.id == _line || next.id.trim().isEmpty) continue;
      try {
        final fresh = await Api.play(widget.videoId, _ep, next.id);
        // 救援换线也要补成绝对地址：站内相对路径补全后 mpv 才能直连，
        // 否则这条新线路又退化成「走代理、整片下完才播」。
        final freshUrl = fxAbsolutePlayUrl(fresh.url);
        if (freshUrl.isEmpty) continue;
        FxPlayCache.invalidate(widget.videoId, _ep, _line);
        if (mounted) setState(() => _line = next.id);
        return FxLineSource(
          url: freshUrl,
          headers: fresh.headers,
          direct: fxShouldUseHlsProxy(freshUrl, isHls: fresh.isHls),
        );
      } catch (_) {
        // 这条取不到地址就继续试下一条线路。
      }
    }
    return null;
  }

  /// 平台线路（爱奇艺 /api/iqiyi.m3u8?tvid=...）返回站内相对地址，
  /// 电视端拿不到，投屏前必须补成绝对 URL。
  String _absoluteUrl(String raw) {
    final url = raw.trim();
    if (url.isEmpty) return url;
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    final base = Api.base.trim();
    if (base.isEmpty) return url;
    final root = base.replaceFirst(RegExp(r'/api/?$'), '');
    if (url.startsWith('/')) return '$root$url';
    return '$root/$url';
  }

  String? _watchdogUrl() {
    final info = _info;
    if (info == null) return null;
    final key = _qualityKey;
    if (key != null) {
      for (final q in info.quality) {
        if (q.key == key && q.url.trim().isNotEmpty) {
          return _absoluteUrl(q.url);
        }
      }
    }
    final main = info.url.trim();
    if (main.isNotEmpty) return _absoluteUrl(main);
    for (final u in info.backup) {
      if (u.trim().isNotEmpty) return _absoluteUrl(u);
    }
    return null;
  }

  Map<String, String> _watchdogHeaders(String url) {
    for (final q in _qualityList) {
      if (q.url.trim() == url && q.headers.isNotEmpty) return q.headers;
    }
    return _info?.headers ?? const <String, String>{};
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
  /// open / 重连期间由各自 try/catch 处理，避免重复弹错误。
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
      // sourceFailed：竖屏按「先原线重试一次（带缓冲），仍失败再换线」处理，
      // 与竖屏自身的失败路径完全一致。
      unawaited(_exit(requestLineChange: true, sourceFailed: true));
      return true;
    }
    return false;
  }

  /// 统一失败收尾：要么自动换线路退出，要么停留在可重试的错误页。
  void _failWith(String text) {
    if (!mounted || _exiting) return;
    _resetHold2x();
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

  /// 平台线路（腾讯 / 芒果等）签名失效：重新请求 /api/play 拿新签名地址。
  /// 本地代理每 90 秒或遇到分片 403/404 时回调；失败返回 null。
  Future<String?> _refreshPlatformUrl() async {
    if (_isLive || widget.videoId.isEmpty || _line.isEmpty) return null;
    try {
      final info = await Api.play(widget.videoId, _ep, _line, fresh: true);
      final url = info.url.trim();
      if (url.isEmpty) return null;
      FxPlayCache.invalidate(widget.videoId, _ep, _line);
      return url;
    } catch (_) {
      return null;
    }
  }

  /// 代理连续两次拿不到新签名：提示该平台线路已失效，能换线就退回竖屏换线。
  void _onPlatformExpired() {
    if (!mounted || _exiting) return;
    _resetHold2x();
    if (widget.canChangeLine) {
      unawaited(_exit(requestLineChange: true, sourceFailed: true));
      return;
    }
    _failWith('该平台线路已失效，请切换线路');
  }

  /// 错误页「重试」：不再重新请求接口，直接用当前地址重新 open，
  /// 尽量接着出错前的位置播放。
  Future<void> _retryPlayback() async {
    if (!mounted || _exiting || _loading) return;
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
      direct: fxShouldUseHlsProxy(url, isHls: _info?.isHls ?? false),
    );
    if (!mounted || token != _loadToken) return;
    if (!ok) {
      _failWith('加载失败，重试');
      return;
    }
    _loadedEp = _ep;
    _sourceFailNotified = false;
    if (!_firstFrame) _armFirstFrameTimer();
    setState(() {
      _loading = false;
      _loadingHint = null;
    });
    // 占位进度最多挂 2 秒：真实进度没追上也不会让进度条永远停在旧值。
    _startUiHoldTimeout();
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
    // 重新 open 成功后，真实进度追上占位值再释放，避免进度条归零。
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
    _autoSkipCheck();
    if (!v.isCompleted) {
      _ended = false;
      return;
    }
    if (_isLive) return; // 直播流断开由重新拉流处理，不走「播完下一集」。
    if (_ended) return;
    _ended = true;
    unawaited(_handleEnded());
  }

  /// 开播 / 切集按本剧片头片尾时长自动跳，每集各只触发一次
  /// （[_skipTag] 换集复位）：
  ///
  /// - 片头：position < 片头秒数 → 跳到片头秒数（跳过前 N 秒）；
  /// - 片尾：时长 - position ≤ 片尾秒数 → 跳到本集结尾，随后由 [_handleEnded]
  ///   按「自动下一集」正常切集（「看完当集」则在那暂停）。
  /// 两项都没设（0）时两个分支都不进，任何位置都不跳。
  void _autoSkipCheck() {
    if (_isLive || _loading || _error) return;
    final intro = _mark.introSeconds;
    final outro = _mark.outroSeconds;
    if (intro <= 0 && outro <= 0) return;
    final ep = _loadedEp;
    if (ep == null) return;
    if (_skipTag != ep) {
      _skipTag = ep;
      _introFired = false;
      _outroFired = false;
    }
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final pos = c.value.position;
    final dur = c.value.duration;
    if (dur <= Duration.zero) return;
    // 片头 / 片尾 ≥ 整集时长 = 配错了：宁可不跳，也不把整集跳没。
    if (intro > 0 &&
        !_introFired &&
        intro < dur.inSeconds &&
        pos < Duration(seconds: intro)) {
      _introFired = true;
      unawaited(c.seekTo(Duration(seconds: intro)));
      _showSeekHint('已跳过片头 ${fxTime(Duration(seconds: intro))}');
      return;
    }
    if (outro > 0 &&
        !_outroFired &&
        outro < dur.inSeconds &&
        dur - pos <= Duration(seconds: outro)) {
      _outroFired = true;
      // 留 0.6 秒收尾：mpv 播到末尾自然触发完成 → 正常切集 / 结束。
      final target = dur - const Duration(milliseconds: 600);
      unawaited(c.seekTo(target.isNegative ? Duration.zero : target));
      _showSeekHint('已跳到片尾');
    }
  }

  Future<void> _handleEnded() async {
    if (_isLive) return;
    await _saveProgress(ended: true);
    if (!mounted) return;
    final settings = AppSettings.instance;
    // 定时关闭「看完当集」优先级最高：本集播完直接暂停，不连播也不重播。
    if (settings.sleepMode == FxSleepMode.episode) {
      try {
        await _controller?.pause();
      } catch (_) {}
      unawaited(settings.setSleepTimer(FxSleepMode.off));
      if (mounted) setState(() {});
      _wake();
      return;
    }
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
    // 关闭单集循环：是否连播看设置页的「自动下一集」（默认开）。
    if (settings.autoNext) {
      final next = _nextEpNumber();
      if (next != null) {
        await _switchEp(next);
        return;
      }
    }
    _wake();
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

  Future<void> _switchEp(int next) async {
    if (_isLive) return;
    if (_loading) return;
    _resetHold2x();
    if (next == _ep) {
      _closePanels();
      return;
    }
    await _saveProgress();
    if (!mounted) return;
    setState(() {
      _ep = next;
      _episodes = List<Episode>.from(_episodes);
      _showSleep = false;
      _showJump = false;
      _controls = true;
      _loading = true;
      _loadedEp = null;
      _error = false;
    });
    await _bootstrap(seekToSaved: true, saveOld: false);
    if (!mounted) return;
    _wake();
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
          _error) {
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
      _showSleep = false;
      _showJump = false;
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
      _showSleep = false;
      _showJump = false;
    });
    _wake();
  }

  /// 刚锁定时的唯一自动淡出计时器：3 秒后隐藏解锁钮。
  /// 之后点屏幕是即时切换显隐，不再有「点一下亮 3 秒」。
  void _startUnlockTimer() {
    _unlockTimer?.cancel();
    _unlockTimer = Timer(kPlayerUnlockAutoHide, () {
      if (!mounted || !_locked) return;
      setState(() => _unlockVisible = false);
    });
  }

  /// 锁定状态点屏幕 = 解锁钮显隐切换（toggle），隐藏 0 延迟立即执行；
  /// 可见时点一下马上消失，再点一下重新唤出，点锁钮本身则是解锁。
  ///
  /// 根因：旧实现每次点屏都置 visible=true 并重启 3 秒计时器，用户为了
  /// 让它消失而点屏反而不断续命，看起来就是「锁按钮永不消失」。
  void _onLockedTap() {
    if (!mounted) return;
    if (_unlockVisible) {
      _unlockTimer?.cancel();
      setState(() => _unlockVisible = false);
    } else {
      setState(() => _unlockVisible = true);
    }
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
        !c.value.isInitialized) {
      return;
    }
    // 投屏中用户点手机播放：先结束投屏，避免电视 / 手机双声。
    if (!c.value.isPlaying && CastService.instance.isCasting) {
      unawaited(CastService.instance.stop());
    }
    // 直接让 media_kit 切换，图标由 player.stream.playing 驱动，避免本地态覆盖。
    unawaited(c.playOrPause());
    _wake();
  }

  void _seekTo(Duration d) {
    if (_isLive) return; // 直播没有可回看的进度。
    final c = _controller;
    if (c == null || _loading || !c.value.isInitialized) return;
    unawaited(c.seekTo(d));
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

  void _startHold2x() {
    if (_isLive || _holding2x) return;
    final c = _controller;
    if (c == null ||
        _loading ||
        _error ||
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
      _showSleep = false;
      _showJump = false;
    });
  }

  void _endHold2x() => _resetHold2x();

  /// 强制结束长按快进并恢复长按前的倍速。
  /// 切换 / 失败 / 退出全屏 / 切后台都必须走这里，避免「3.0倍速快进中」常驻。
  void _resetHold2x({bool notify = true}) {
    if (!_holding2x) return;
    _holding2x = false;
    if (notify && mounted) {
      setState(() {});
    }
    unawaited(_applyRate(_rateBeforeHold));
  }

  void _toggleSpeed() {
    if (_isLive) {
      return;
    }
    _hideTimer?.cancel();
    setState(() {
      _showSpeed = !_showSpeed;
      _showSleep = false;
      _showJump = false;
      _controls = true;
    });
    if (!_showSpeed) _wake();
  }

  /// 播放设置里「跳过片头片尾」的状态文案：
  /// 「片头 00:30 · 片尾 01:00」；两项都没设置显示「未设置」。
  String get _markLabel {
    if (_mark.isEmpty) return '未设置';
    return '片头 ${fxTime(Duration(seconds: _mark.introSeconds))}'
        ' · 片尾 ${fxTime(Duration(seconds: _mark.outroSeconds))}';
  }

  /// 打开片头 / 片尾标记面板（底部「片头/尾」按钮、播放设置行）。
  void _openJumpPanel() {
    if (_isLive) return;
    _hideTimer?.cancel();
    setState(() {
      _showJump = true;
      _showSpeed = false;
      _showSleep = false;
      _controls = true;
    });
  }

  /// 应用输入的片头 / 片尾时长：按 videoId 落盘，本集立即按新值跳。
  /// 清空本剧设置：清完任何位置都不再自动跳。
  /// 打开定时关闭右侧面板（与速度 / 片头尾面板互斥）。
  /// 直播同样可用：到点暂停对直播一样生效。
  void _openSleepPanel() {
    _hideTimer?.cancel();
    setState(() {
      _showSleep = true;
      _showSpeed = false;
      _showJump = false;
      _controls = true;
    });
  }

  /// 面板选中一项：不开启 / 看完当集 / 30·60·90 分钟。
  /// 自定义分钟（1–1440）：弹输入框，确认后生效。
  /// 落地定时关闭：分钟模式记截止时间戳（杀进程再进来能续上剩余时间）。
  /// 到点只暂停播放并保留进度，不退出 App。
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
    if (!mounted) return;
    setState(() {});
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
    try {
      unawaited(_controller?.pause());
    } catch (_) {}
    unawaited(AppSettings.instance.setSleepTimer(FxSleepMode.off));
    setState(() {});
  }

  /// 进全屏时续上持久化的分钟定时：没过期按剩余时间重新武装，
  /// 关掉进程期间已经过期就直接回落「不开启」。
  Future<void> _restoreSleepTimer() async {
    final settings = AppSettings.instance;
    await settings.init();
    if (!mounted) return;
    if (settings.sleepMode != FxSleepMode.minutes) return;
    final left = settings.sleepEndsAt - DateTime.now().millisecondsSinceEpoch;
    if (left <= 0) {
      await settings.setSleepTimer(FxSleepMode.off);
      if (mounted) setState(() {});
      return;
    }
    _armSleep(left);
  }

  /// 读本剧片头 / 片尾标记（videoId 维度，进全屏读一次）。
  Future<void> _loadMarks() async {
    final mark = await VideoMarks.load(widget.videoId);
    if (!mounted) return;
    setState(() => _mark = mark);
  }

  Future<void> _exit({
    bool requestLineChange = false,
    bool sourceFailed = false,
  }) async {
    if (_exiting) return;
    _exiting = true;
    // 长按快进中直接退出全屏时，把倍速恢复成交给竖屏前的值。
    _resetHold2x();
    _unlockTimer?.cancel();
    // 作废仍在进行的切集 / 重连请求，退出后不要再回写 UI。
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
        sourceFailed: sourceFailed,
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
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(child: _buildVideoSurface(c)),
              // 手势层：单击显隐控件 / 双击暂停 / 横扫调进度 / 竖扫亮度音量 /
              // 长按 3.0x。加载与切换时仍保留手势（按钮的 no-op 由页面自己判）。
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
              // 锁屏：所有控件隐藏；锁按钮锁定瞬间亮 3 秒自动淡出，
              // 之后点屏幕即时切换显隐，点锁钮解锁，不常驻。
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
            // 画面比例 / 镜像模式在 FxPlayerSurface 内按全局设置渲染：
            // 改档立即生效、不重载视频，冻结帧用同一套裁切。
            FxPlayerSurface(
              key: ValueKey<int>(_videoEpoch),
              player: c,
              subtitleBottom: controlsHeight + 12,
            ),
          // 切集 / 重连：最后一帧垫在黑底上，首帧就绪后 200ms 淡出。
          if (_frozenFrame != null)
            Positioned.fill(
              child: FxAspectBox(
                child: (context, fit) => FxSnapshotLayer(
                  bytes: _frozenFrame,
                  opaque: _freezeOpaque,
                  fit: fit,
                ),
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
        speedText: v.speedText,
        dim: _frozenFrame == null,
      );
    }
    if (!v.isBuffering) return const SizedBox.shrink();
    final percent = v.bufferingPercent;
    return FxLoadingOverlay(
      title: percent == null ? '缓冲中…' : '缓冲中 ${percent.round()}%',
      percent: percent,
      speedText: v.speedText,
      dim: false,
      compact: true,
    );
  }

  /// 分辨率 / 网速胶囊：只在拿到数据后显示，拿不到就不占位。
  Widget _statChip(FxPlayer? c) {
    if (c == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final v = c.value;
        final res = v.resolutionText;
        final speed = v.speedText;
        if (res.isEmpty && speed.isEmpty) return const SizedBox.shrink();
        final parts = <String>[
          if (res.isNotEmpty) res,
          if (speed.isNotEmpty) speed,
        ];
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .38),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            parts.join(' · '),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        );
      },
    );
  }

  Widget _buildError() {
    return Positioned.fill(
      child: Center(
        child: Container(
          width: 330,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .95),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .20),
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
              color: Fx.accent.withValues(alpha: .25),
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
    // 控件全交给 betterplayer 内置，这里不再需要算 compact / bottomInset。
    return Stack(
      fit: StackFit.expand,
      children: [
        // 控件全部交给 betterplayer 内置（进度条 / 倍速 / 画质 / 音轨 /
        // 字幕 / PiP / 重试），位置就是它自己算的安全区。
        //
        // 之前这里还画着自绘的 FsTopBar + FsSideControls + FsBottomBar，
        // 结果是「上下两套控件同时出现」—— 用户报的原话。
        // 现在只留左上角一个返回键（betterplayer 的控件里没有退出全屏按钮）。
        Positioned(
          left: 0,
          top: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded,
                        color: Colors.white, size: 22),
                    tooltip: '返回',
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black.withValues(alpha: .38),
                    ),
                    onPressed: () => unawaited(_exit()),
                  ),
                  const SizedBox(width: 6),
                  // 分辨率 + 实时网速（betterplayer 不显示这些）
                  _statChip(c),
                ],
              ),
            ),
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
        color: Colors.black.withValues(alpha: .52),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: .28)),
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


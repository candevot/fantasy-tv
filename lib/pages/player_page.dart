import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../services/cast_service.dart';
import '../services/app_settings.dart';
import '../services/fx_player.dart';
import '../services/video_marks.dart';
import '../theme.dart';
import '../widgets/cast_sheet.dart';
import '../widgets/fs_panels.dart';
import '../widgets/player_gestures.dart';
import '../widgets/player_more_panel.dart';
import '../widgets/player_theme.dart';
import 'fullscreen_page.dart';
import 'history_page.dart' show FxStore;

/// 当前线路不能直接播放的原因，交给外层决定换线路与提示文案。
enum SourceIssue { parse, empty, expired, error }

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

  /// 停摆 / 出错的自愈已整体搬进 FxPlayer：连续 30 秒无字节流动才判定
  /// 失败（缓冲中只显示「缓冲中 xx%」），随后静默跑
  /// ①refreshPlay 换地址 ②同地址重开并 seek 回原进度 ③换下一条线路，
  /// 页面只在三步全失败时弹一次「播放中断」（见 _onPlayerFatal）。

  /// 竖屏控件 3 秒无操作自动隐藏。
  static const Duration _controlsAutoHide = Duration(seconds: 3);

  FxPlayer? _controller;
  PlayInfo? _info;

  /// 当前真正 open 成功的地址（可能是 backup），投屏优先用它；
  /// 切线路 / 切集时清空，避免把上一条地址投出去。
  String? _activeCastUrl;

  late int _ep;
  late String _line;
  int _loadToken = 0;

  /// controller 实际已经打开的集。进度只写这一集，loading 时不写。
  int? _loadedEp;

  /// 正在打开的组合（line|ep）：同一组合重复请求直接复用，防重复 open。
  String? _openingKey;
  Future<bool>? _opening;

  /// 当前集播放 30 秒后已预解析的下一集，避免 10 秒定时器重复请求。
  bool _nextPrewarmed = false;
  int? _prewarmEp;
  DateTime? _prewarmAt;

  /// 正在 open 的新播放器：loading 浮层据此显示真实缓冲进度，
  /// 而不是复用旧 controller 的缓存百分比。
  FxPlayer? _loadingPlayer;

  /// 缓存命中 + 已有上一帧快照时跳过 loading 浮层，直接 open。
  bool _suppressLoading = false;

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

  /// 切换期间锁住 UI 进度，避免新播放器 open 时进度归零。
  Duration? _uiPosition;
  Duration? _uiDuration;

  /// 本次加载请求的线路 / 集数：加载文案只认这次请求，
  /// 不能读上一次请求留下的 _info（换线路时会显示旧线路名）。
  String _requestLine = '';
  int _requestEp = 0;

  /// 每 10 秒把观看进度回写历史，App 被杀也能保留大致位置。
  Timer? _progressTimer;

  /// 是否已切到后台：切后台 / inactive / paused 一律不暂停，继续播放，
  /// 回前台接着播（不重新 open、不 seek）；看门狗在后台停摆，避免误判卡顿。
  bool _backgrounded = false;

  /// 切后台那一刻的播放位置与播放状态：系统在后台可能把 libmpv 冻结或把
  /// 进度重置到片头，回前台按这两项判断要不要自愈（拉回原进度并继续播）。
  Duration _backgroundAnchor = Duration.zero;
  bool _backgroundWasPlaying = true;

  /// 回前台只重建 Video 输出层（换 key），播放器实例与进度保持不动。
  int _videoEpoch = 0;

  /// 切线路 / 切集前抓下的最后一帧：Video 换源时会先清空纹理，
  /// 切换期间用它顶住空窗，新流首帧就绪后 200ms 淡出，不再闪黑。
  Uint8List? _frozenFrame;
  bool _frozenOpaque = false;
  Timer? _frozenClearTimer;
  Timer? _frozenFallbackTimer;

  /// 进入全屏时随结果带回的真实倍速，切集时沿用。
  double _rate = 1.0;

  /// 播放设置：循环播放（单集循环 / 关闭；连播交给「自动下一集」）。
  FxLoopMode _loopMode = FxLoopMode.off;

  /// 播放设置：定时关闭，到点自动暂停。
  Timer? _sleepTimer;

  /// 本剧片头 / 片尾标记（按 videoId 存，见 [VideoMarks]）。
  VideoMark _mark = const VideoMark();

  /// 本集是否已触发过片头 / 片尾跳转（每集各一次，重新开流时复位）。
  bool _introJumped = false;
  bool _outroJumped = false;

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
    return fxLineNameOf(widget.detail?.lines ?? const <LineInfo>[], _line);
  }

  /// 打开投屏面板。详情页底部动作栏的「投屏」也调用这里。
  Future<void> openCastSheet() async {
    final info = _info;
    if (info == null || _loading || _error) {
      // 还没准备好：静默返回，播放中不弹任何遮挡画面的提示。
      return;
    }
    final active = _activeCastUrl?.trim() ?? '';
    final url = active.isNotEmpty ? active : _castUrl(info);
    final headers = _castHeaders(url, info);
    CastSource source;
    try {
      source = CastService.resolveSource(
        url: url,
        headers: headers,
        title: '$_title · ${_epLabelFor(_ep)}',
        direct: info.direct,
        startAt: _controller?.value.position ?? Duration.zero,
        serverBase: Api.base,
      );
    } on CastException {
      // 解析投屏地址失败：静默返回，避免遮挡播放画面。
      return;
    }
    final wasPlaying = _controller?.value.isPlaying ?? false;
    await showCastSheet(
      context,
      source: source,
      owner: this,
      onCastStarted: () async {
        try {
          await _controller?.pause();
        } catch (_) {}
      },
      onCastStopped: () async {
        if (!wasPlaying || !mounted) return;
        try {
          await _controller?.play();
        } catch (_) {}
      },
    );
  }

  /// 投屏地址必须能落到绝对 URL。
  /// 平台线路（爱奇艺 /api/iqiyi.m3u8?tvid=...）返回的是站内相对地址，
  /// 直接交给电视会因 uri.host 为空被判定「不是 http(s) 直链」而投屏失败，
  /// 这里统一补上服务器前缀。
  String _absoluteUrl(String raw) {
    final url = raw.trim();
    if (url.isEmpty) return url;
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    final base = Api.base.trim();
    if (base.isEmpty) return url;
    // Api.base 形如 http://host:8787/api，站内地址以 /api/ 开头
    final root = base.replaceFirst(RegExp(r'/api/?$'), '');
    if (url.startsWith('/')) return '$root$url';
    return '$root/$url';
  }

  String _castUrl(PlayInfo info) {
    final key = _qualityKey;
    if (key != null) {
      for (final quality in info.quality) {
        if (quality.key == key && quality.url.trim().isNotEmpty) {
          return _absoluteUrl(quality.url);
        }
      }
    }
    final main = info.url.trim();
    if (main.isNotEmpty) return _absoluteUrl(main);
    for (final url in info.backup) {
      if (url.trim().isNotEmpty) return url.trim();
    }
    return '';
  }

  Map<String, String> _castHeaders(String url, PlayInfo info) {
    for (final quality in info.quality) {
      if (quality.url.trim() == url && quality.headers.isNotEmpty) {
        return quality.headers;
      }
    }
    return info.headers;
  }

  /// 本次加载请求的线路名：只按请求的 lineId 从详情线路表查，
  /// 取不到返回空串（加载文案会省略线路名）。
  String get _loadingLineName =>
      fxLineNameOf(widget.detail?.lines ?? const <LineInfo>[], _requestLine);

  @override
  void initState() {
    super.initState();
    _ep = widget.ep;
    _line = widget.line;
    _requestEp = widget.ep;
    _requestLine = widget.line;
    WidgetsBinding.instance.addObserver(this);
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      // 全屏期间由全屏页保存，避免把全屏切换后的位置记到旧集。
      if (!mounted || _fullscreenActive) return;
      unawaited(_saveProgress());
      _maybePrewarmNext();
    });
    unawaited(_loadMark());
    unawaited(_restoreSleepTimer());
    _bootstrap(seekToSaved: true, saveOld: false);
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
      _requestEp = next;
      _requestLine = _line;
      _uiPosition = null;
      _uiDuration = null;
    });
    await _bootstrap(
      seekToSaved: true,
      saveOld: false,
      epOverride: next,
      playOverride: !_covered && _shouldContinuePlayback(),
    );
  }

  Future<void> _switchLine(String targetLine, int targetEp) async {
    if (_switchingLine) {
      // 切换中禁止重复点击：直接忽略新的线路请求，绝不允许并发 open。
      return;
    }
    _switchingLine = true;
    widget.onSwitchingChanged?.call(true);
    final old = _controller;
    final healthy = old != null &&
        old.value.isInitialized &&
        !old.value.hasError &&
        !_error;
    // 切换动作默认「继续播放」；只有切换前确实是暂停（用户主动暂停）
    // 才保持暂停。未就绪 / 报错时按继续处理，避免自动换线后停在暂停。
    final continuePlayback = _shouldContinuePlayback(old);
    final resume = healthy ? old.value.position : Duration.zero;
    final oldDuration = old?.value.duration;
    var resumeSeconds = resume.inMilliseconds / 1000.0;

    try {
      // 先保存旧线路进度（此刻还没进入 loading，_saveProgress 才会生效）。
      await _saveProgress();
      if (!mounted) return;

      if (!healthy) {
        final saved = await fxLoadProgress(widget.videoId, targetEp);
        // 不足 60 秒视为刚看片头，不把 20 秒进度当成续播。
        resumeSeconds = saved >= fxResumeMinSeconds ? saved : 0;
        if (!mounted) return;
      }

      _loadToken++;
      unawaited(old?.pause());
      _hideTimer?.cancel();
      setState(() {
        _loading = true;
        _requestLine = targetLine;
        _requestEp = targetEp;
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
          playOverride: continuePlayback,
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
          _uiPosition = null;
          _uiDuration = null;
        });
        _showControls();
        // 线路已切换：静默，不弹遮挡画面的提示。
        // 自动尝试下一条成功时同步外层高亮，避免 UI 仍指着失败线路。
        widget.onLineFallback?.call(actualLine);
      } else {
        // 两条线路都失败：停在最后尝试的线路，错误页的重试按钮直接重试它。
        final lastTried = attempts.isEmpty ? targetLine : attempts.last;
        _line = lastTried;
        _clearFrozenFrame();
        setState(() {
          _loading = false;
          _loadedEp = null;
          _error = true;
          _errorText = '线路不可用，请重试或换线路';
          _uiPosition = null;
          _uiDuration = null;
        });
        _showControls();
        // 切换失败：错误层（含重试）已在上面亮出，不再叠加提示。
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

  /// 切换线路 / 切集时是否继续播放：
  /// - 已初始化且正常播放：继续；
  /// - 已初始化但暂停：用户主动暂停，保持暂停；
  /// - 未就绪 / 出错 / 刚播完：按继续处理（切换动作就是继续看）。
  bool _shouldContinuePlayback([FxPlayer? player]) {
    final c = player ?? _controller;
    if (c == null) return true;
    final v = c.value;
    if (!v.isInitialized || v.hasError || v.isCompleted) return true;
    return v.isPlaying;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 全屏期间由全屏页负责保存进度、后台暂停与画面重建。
    if (_fullscreenActive) return;
    switch (state) {
      case AppLifecycleState.inactive:
        // 多任务 / 分屏 / 小窗 / 下拉通知栏：只是失去前台焦点，绝不暂停。
        // 真正被其它应用占用音频时系统会继续走到 paused，由 5 秒兜底处理。
        return;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        // 切后台：只记进度，永不暂停（来电 / 抢占音频属系统音频策略）。
        _backgrounded = true;
        _backgroundAnchor = _controller?.value.position ?? _backgroundAnchor;
        _backgroundWasPlaying = _controller?.value.isPlaying ?? true;
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

  // 切后台永不暂停：不再有「paused 超时暂停」的定时器，
  // 回前台也不补 play（播放状态从头到尾没有被 App 改过）。

  /// 回前台只重挂 Video 层（不 open / 不 seek）：换 key 让输出层重建，
  /// 同一 FxPlayer 实例、播放位置与播放状态全部保持。
  void _remountVideoLayer() {
    if (!mounted) return;
    setState(() => _videoEpoch++);
  }

  /// 回前台自愈：系统在后台可能冻结 libmpv（位置不动、playing=false）或把
  /// 进度重置到片头，用户点播放就从 0 重来。这里按切后台时的位置把它拉回
  /// 去并继续播，全程静默；播放器已经正常推进时什么也不做。
  Future<void> _recoverAfterBackground() async {
    final c = _controller;
    if (c == null || _loading || _error) return;
    final anchor = _backgroundAnchor;
    if (anchor <= Duration.zero) return;
    final healed = await c.recoverAfterBackground(
      anchor,
      wasPlaying: _backgroundWasPlaying,
    );
    if (!mounted || !healed) return;
    // 自愈改过播放状态 / 位置：刷新一次进度条，避免停在旧值。
    setState(() {});
  }

  /* ------------------------------------------------------------ 画面过渡 */

  /// 换源前抢一帧当前画面。抓取失败返回 null，切换时退回纯黑 + 加载层。
  Future<Uint8List?> _captureFrozenFrame() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return null;
    return c.captureFrame();
  }

  /// 进入加载态前调用：把当前帧固定下来，盖住新 Video 纹理清空的空窗。
  Future<void> _freezeCurrentFrame() async {
    // 连试多条备用线路时沿用同一张快照，避免重新解码造成二闪。
    if (_frozenOpaque && _frozenFrame != null) return;
    final bytes = await _captureFrozenFrame();
    if (!mounted) return;
    // 首次加载没有旧画面：保持纯黑，不必多一次重建。
    if (bytes == null && _frozenFrame == null) return;
    _frozenClearTimer?.cancel();
    _frozenClearTimer = null;
    _frozenFallbackTimer?.cancel();
    _frozenFallbackTimer = null;
    setState(() {
      _frozenFrame = bytes;
      _frozenOpaque = bytes != null;
    });
  }

  /// 新流首帧就绪（宽高出现）后淡出快照。
  void _maybeFadeFrozenFrame() {
    if (!_frozenOpaque || _frozenFrame == null || _loading || _error) return;
    final c = _controller;
    if (c == null) return;
    final v = c.value;
    final width = v.videoWidth ?? v.width ?? 0;
    final height = v.videoHeight ?? v.height ?? 0;
    if (!v.isInitialized || width <= 0 || height <= 0) return;
    _fadeOutFrozenFrame();
  }

  /// 200ms 淡出快照；淡出完成后再释放，避免绘制中被销毁。
  void _fadeOutFrozenFrame() {
    if (_frozenFrame == null || !_frozenOpaque) return;
    _frozenFallbackTimer?.cancel();
    _frozenFallbackTimer = null;
    if (!mounted) return;
    setState(() => _frozenOpaque = false);
    _frozenClearTimer?.cancel();
    _frozenClearTimer = Timer(const Duration(milliseconds: 240), () {
      _frozenClearTimer = null;
      if (!mounted || _frozenOpaque) return;
      setState(() => _frozenFrame = null);
    });
  }

  /// 立即丢弃快照（加载失败 / 进入全屏 / 释放播放器时）。
  void _clearFrozenFrame() {
    _frozenClearTimer?.cancel();
    _frozenClearTimer = null;
    _frozenFallbackTimer?.cancel();
    _frozenFallbackTimer = null;
    if (_frozenFrame == null && !_frozenOpaque) return;
    _frozenFrame = null;
    _frozenOpaque = false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _sleepTimer?.cancel();
    _progressTimer?.cancel();
    _frozenClearTimer?.cancel();
    _frozenFallbackTimer?.cancel();
    _frozenFrame = null;
    _frozenOpaque = false;
    _loadToken++;
    unawaited(_saveProgress());
    // 投屏会话属于本页：退出详情页时停止电视，避免关掉 App 后电视还在播。
    if (CastService.instance.isOwnedBy(this)) {
      unawaited(CastService.instance.stop());
    }
    _controller?.removeListener(_onVideoValue);
    _controller?.dispose();
    _loadingPlayer = null;
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

  /// 当前实际播放线路 / 集数 / 进度：进入一起看时沿用，不能退回默认线路。
  String get currentLine => _line;
  int get currentEp => _ep;
  Duration get currentPosition => _controller?.value.position ?? Duration.zero;
  bool get currentPlaying => _controller?.value.isPlaying ?? false;

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
    if (CastService.instance.isOwnedBy(this)) {
      await CastService.instance.stop();
    }
    _loadToken++;
    _hideTimer?.cancel();
    _clearFrozenFrame();
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

  /// 从一起看房间返回后调用：按房间快照重新加载播放器并恢复进度。
  ///
  /// 房间内可能切集 / 换线路，[ep] / [line] 是退出时房间的当前状态，
  /// 不能沿用进房前的旧集；[position] 是房间进度（秒），[play] 沿用
  /// 房间的播放 / 暂停态（暂停退出就不要自己播起来）。
  Future<bool> resumeAfterTogether({
    int? ep,
    String? line,
    double? position,
    bool? play,
  }) async {
    if (!mounted) return false;
    final targetLine = (line ?? _line).trim();
    return _bootstrap(
      seekToSaved: position == null,
      saveOld: false,
      lineOverride: targetLine.isEmpty ? null : targetLine,
      epOverride: ep,
      resumeSeconds: position,
      playOverride: play,
      commitLine: true,
    );
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
    bool forcePlayInfo = false,
  }) async {
    // 手机重新加载 / 切集 / 换线路时结束投屏：否则电视还在播上一集，
    // 手机同时播新的，就是双声。
    if (CastService.instance.isCasting) {
      await CastService.instance.stop();
      if (!mounted) return false;
    }
    final line = lineOverride ?? _line;
    final ep = epOverride ?? _ep;
    // 同一 url+line+ep 正在打开时忽略重复请求（防抖），
    // 避免 didUpdateWidget / 连点「下一集」并发 open 造成双播放器与内存翻倍。
    final key = '$line|$ep';
    final opening = _opening;
    if (opening != null && _openingKey == key) return opening;
    final future = _bootstrapSource(
      seekToSaved: seekToSaved,
      saveOld: saveOld,
      line: line,
      ep: ep,
      resumeSeconds: resumeSeconds,
      playOverride: playOverride,
      commitLine: commitLine,
      reportFailure: reportFailure,
      forcePlayInfo: forcePlayInfo,
    );
    _opening = future;
    _openingKey = key;
    try {
      return await future;
    } finally {
      if (identical(_opening, future)) {
        _opening = null;
        _openingKey = null;
      }
    }
  }

  Future<bool> _bootstrapSource({
    required bool seekToSaved,
    required bool saveOld,
    required String line,
    required int ep,
    required bool commitLine,
    required bool reportFailure,
    required bool forcePlayInfo,
    double? resumeSeconds,
    bool? playOverride,
  }) async {
    final token = ++_loadToken;
    _hideTimer?.cancel();
    // 先抓最后一帧，再换播放器：Video 在 open 期间会清空纹理，
    // 用快照顶住加载窗口，新流首帧就绪后淡出。
    await _freezeCurrentFrame();
    if (!mounted || token != _loadToken) return false;
    if (saveOld) await _saveProgress();
    if (!mounted || token != _loadToken) return false;
    unawaited(_controller?.pause());
    // 上一集已预解析 / 同一集重复打开：缓存命中就不等接口和 playlist，
    // 有旧画面快照时连 loading 浮层都跳过。
    final cacheHit =
        !forcePlayInfo && FxPlayCache.peek(widget.videoId, ep, line) != null;
    final waitForWarm = !cacheHit;
    setState(() {
      _loading = true;
      _suppressLoading = cacheHit && _frozenFrame != null;
      _requestLine = line;
      _requestEp = ep;
      _loadedEp = null;
      _qualityKey = null;
      _error = false;
      _errorText = '';
      _sourceFailNotified = false;
      _ended = false;
      // 片头 / 片尾标记每集只触发一次：重新开流（切集 / 换线路）时复位。
      _introJumped = false;
      _outroJumped = false;
      // 新一集重新计算预解析，避免沿用上一集的标记。
      _nextPrewarmed = false;
      _prewarmEp = null;
      _prewarmAt = null;
    });

    PlayInfo info;
    try {
      // 命中下一集预解析缓存时不再等 /api/play，切集直接进 open。
      info = await FxPlayCache.resolve(
        widget.videoId,
        ep,
        line,
        force: forcePlayInfo,
      );
    } catch (_) {
      if (!mounted || token != _loadToken) return false;
      setState(() {
        _loading = false;
        _suppressLoading = false;
        if (reportFailure) {
          _error = true;
          _errorText = '获取播放地址失败，请检查网络后重试';
        }
      });
      if (reportFailure) {
        _clearFrozenFrame();
        _notifySourceFailed();
      }
      return false;
    }
    if (!mounted || token != _loadToken) return false;
    _info = info;
    _activeCastUrl = null;

    // TW 等线路可能返回一个需要解析器处理的播放页地址（type == 'parse'）。
    // 空 url 与解析页是两种不同情况，分开交给外层展示文案。
    final isParse = info.type.trim().toLowerCase() == 'parse';
    if (isParse) {
      if (reportFailure) {
        _emitSourceIssue(SourceIssue.parse);
      } else {
        setState(() {
          _loading = false;
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
        });
      }
      return false;
    }

    var saved = resumeSeconds ??
        (seekToSaved ? await fxLoadProgress(widget.videoId, ep) : 0.0);
    // 续播门槛：只看本地保存的进度，活跃切换（resumeSeconds）不受影响。
    final fromSavedPosition = resumeSeconds == null && seekToSaved;
    if (fromSavedPosition && saved < fxResumeMinSeconds) saved = 0;
    if (!mounted || token != _loadToken) return false;
    final shouldPlay = playOverride ?? (widget.autoPlay && !_covered);

    var ok = false;
    for (final url in candidates) {
      if (!mounted || token != _loadToken) return false;
      final controller = FxPlayer.create();
      if (mounted) setState(() => _loadingPlayer = controller);
      try {
        // 8 秒拿不到可播状态就判这条地址失败，避免黑屏一直转圈。
        await controller
            .open(
              url,
              headers: info.headers,
              play: shouldPlay,
              waitForWarm: waitForWarm,
              direct: info.direct && info.isHls,
              // 平台线路签名过期时，代理会回调这里重新走 /api/play。
              refreshPlay: () => _refreshPlatformUrl(line, ep),
              onPlayExpired: () {
                if (!mounted || token != _loadToken) return;
                _emitSourceIssue(SourceIssue.expired);
              },
              // 无感救援链第③步：本线路 ①refreshPlay ②同地址重开都失败后，
              // 播放器会静默回调这里换下一条线路（并 seek 回原进度）。
              rescueLines: () async {
                if (!mounted || token != _loadToken) return null;
                final lines = widget.detail?.lines ?? const <LineInfo>[];
                if (lines.length < 2) return null;
                final index = lines.indexWhere((l) => l.id == line);
                for (var k = 1; k <= lines.length; k++) {
                  final next = lines[(index + k) % lines.length];
                  if (next.id == line || next.id.trim().isEmpty) continue;
                  try {
                    final fresh =
                        await Api.play(widget.videoId, ep, next.id);
                    final freshUrl = fresh.url.trim();
                    if (freshUrl.isEmpty) continue;
                    FxPlayCache.invalidate(widget.videoId, ep, line);
                    if (mounted && token == _loadToken) {
                      setState(() => _line = next.id);
                      _activeCastUrl = null;
                    }
                    return FxLineSource(
                      url: freshUrl,
                      headers: fresh.headers,
                      direct: fresh.direct && fresh.isHls,
                    );
                  } catch (_) {
                    // 这条也取不到地址就继续试下一条线路。
                  }
                }
                return null;
              },
            )
            .timeout(_openReadyTimeout);
        if (!mounted || token != _loadToken) {
          await controller.dispose();
          return false;
        }
        _activeCastUrl = url;
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
          // 静默续播：直接 seek 到上次位置，不弹任何提示。
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
          _suppressLoading = false;
          _error = false;
          _errorText = '';
        });
        _sourceFailNotified = false;
        ok = true;
        // 新画面已挂上：等这一帧绘制完再淡出快照，避免露出还没上纹理的黑帧。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_fullscreenActive) _maybeFadeFrozenFrame();
        });
        _frozenFallbackTimer?.cancel();
        if (_frozenFrame != null) {
          // 首帧参数迟迟不到（异常流）时兜底淡出，不能让快照一直盖着。
          _frozenFallbackTimer = Timer(
            const Duration(seconds: 2),
            _fadeOutFrozenFrame,
          );
        }
        widget.onPlaybackStarted?.call();
        _showControls();
        // 续播静默处理：直接停在上次位置，不弹「已跳到上次位置」提示。
        break;
      } catch (_) {
        try {
          controller.dispose();
        } catch (_) {}
      }
    }

    if (mounted && _loadingPlayer != null) {
      setState(() => _loadingPlayer = null);
    }

    if (!ok) {
      if (!mounted || token != _loadToken) return false;
      setState(() {
        _loading = false;
        _suppressLoading = false;
        if (reportFailure) {
          _error = true;
          _errorText = '播放失败：线路不可用，请重试或切换下方线路';
        }
      });
      if (reportFailure) {
        _clearFrozenFrame();
        _notifySourceFailed();
      }
      return false;
    }
    return true;
  }

  /// 平台线路（腾讯 / 芒果等）签名失效：重新请求 /api/play 拿新签名地址。
  /// 本地代理会每 90 秒或遇到分片 403/404 时调用；失败返回 null。
  Future<String?> _refreshPlatformUrl(String line, int ep) async {
    if (widget.videoId.isEmpty || line.isEmpty) return null;
    try {
      final info = await Api.play(widget.videoId, ep, line, fresh: true);
      final url = info.url.trim();
      if (url.isEmpty) return null;
      // 旧签名已失效，清掉缓存，避免稍后切回本线路又命中过期地址。
      FxPlayCache.invalidate(widget.videoId, ep, line);
      return url;
    } catch (_) {
      return null;
    }
  }

  void _emitSourceIssue(SourceIssue issue) {
    final callback = widget.onSourceIssue;
    if (callback != null) {
      callback(issue);
      return;
    }
    if (!mounted) return;
    _clearFrozenFrame();
    setState(() {
      _loading = false;
      _error = true;
      _errorText = switch (issue) {
        SourceIssue.parse => '该线路暂不可直接播放，请切换线路',
        SourceIssue.empty => '当前线路没有可用播放地址，请切换线路',
        SourceIssue.expired => '该平台线路已失效，请切换线路',
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

  /* ------------------------------------------- 无感救援链（FxPlayer 内部） */

  // 停摆 / 出错的自愈已整体搬进 FxPlayer：连续 30 秒「完全无字节流动」
  // 才判定失败（缓冲中只显示「缓冲中 xx%」，不弹错误层），随后播放器内部
  // 静默跑 ①refreshPlay 换地址 ②同地址重新 open 并 seek 回原进度
  // ③换下一条线路（open 的 rescueLines hook），每步结果都写进 proxy.log。
  // 三步都失败后播放器才会带 hasError 回到页面，这里只负责弹一次错误层。

  /// 救援链三步全部失败：只弹一次「播放中断」，页面不再自己重开 / 换线。
  void _onPlayerFatal() {
    if (!mounted || _error) return;
    _clearFrozenFrame();
    setState(() {
      _loading = false;
      _loadedEp = null;
      _error = true;
      _errorText = '播放中断，自动恢复失败，请重试或切换线路';
      _uiPosition = null;
      _uiDuration = null;
    });
    _showControls();
  }

  void _onVideoValue() {
    final c = _controller;
    if (c == null || !mounted) return;
    // 新流首帧就绪（宽高出现）后淡出切换快照；loading / error 期间不动。
    if (!_fullscreenActive) _maybeFadeFrozenFrame();
    // 全屏期间由全屏页接管同一个播放器的事件（切集 / 结束 / 报错）；
    // loading 期间的错误由 _bootstrap 的 try/catch 处理。
    if (_fullscreenActive || _loading || _error) return;
    final v = c.value;
    if (v.hasError) {
      // FxPlayer 内部三步救援链已全部失败：页面只弹一次「播放中断」。
      _onPlayerFatal();
      return;
    }
    if (!v.isInitialized) return;
    // 本剧片头 / 片尾标记到点各跳一次（全屏期间由全屏页负责）。
    _maybeApplyMark(v.position);
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
    final settings = AppSettings.instance;
    // 定时关闭「看完当集」优先级最高：本集播完直接暂停，不连播也不重播。
    if (settings.sleepMode == FxSleepMode.episode) {
      try {
        await _controller?.pause();
      } catch (_) {}
      unawaited(settings.setSleepTimer(FxSleepMode.off));
      return;
    }
    if (_loopMode == FxLoopMode.single) {
      // 单集循环：回到片头继续播这一集，不切下一集。
      try {
        await _controller?.seek(Duration.zero);
        await _controller?.play();
      } catch (_) {}
      return;
    }
    final next = _nextEpNumber();
    if (next != null) {
      await _switchEpisode(next);
    } else {
      setState(() => _controls = true);
      _startHideTimer();
      // 播完最后一集：静默，不弹遮挡画面的提示。
    }
  }

  Future<void> _switchEpisode(int next) async {
    if (next < 1 || _switchingLine) return;
    await _saveProgress();
    if (!mounted) return;
    setState(() {
      _ep = next;
      _loading = true;
      _requestLine = _line;
      _requestEp = next;
      _loadedEp = null;
      _qualityKey = null;
      _error = false;
      _controls = true;
      _uiPosition = null;
      _uiDuration = null;
    });
    widget.onEpChange?.call(next);
    // 自动连播不提示「即将播放第N集」：播放中保持画面干净。
    await _bootstrap(
      seekToSaved: true,
      saveOld: false,
      epOverride: next,
      playOverride: !_covered && _shouldContinuePlayback(),
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

  /// 当前集播过 30 秒后，后台清空并预热下一集的 /api/play 与 m3u8。
  /// 只请求、不 open，切集时复用缓存，省掉接口往返。
  void _maybePrewarmNext() {
    if (!mounted || _loading || _error || _fullscreenActive) return;
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

  /// 详情页「刷新」/错误重试可以调用
  Future<void> reload() async {
    if (_switchingLine) return;
    // 重试一进来就进入缓冲态并清掉错误层：失败上报与重试在同一个事件循环
    // 里完成，UI 不会先闪一下错误页再变回加载。
    if (mounted) {
      setState(() {
        _loading = true;
        _suppressLoading = false;
        _error = false;
        _errorText = '';
      });
    }
    await _saveProgress();
    if (!mounted) return;
    // 重试时强制刷新播放地址，避免复用已经失效的直链。
    await _bootstrap(
      seekToSaved: true,
      saveOld: false,
      forcePlayInfo: true,
    );
  }

  /// 详情页试完全部线路仍不可播时调用，展示错误与重试/换线路按钮。
  void showSourceError(String message) {
    if (!mounted) return;
    _clearFrozenFrame();
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
    // 投屏中用户点手机播放：先结束投屏，避免电视 / 手机双声。
    if (!c.value.isPlaying && CastService.instance.isCasting) {
      unawaited(CastService.instance.stop());
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
    // 全屏交给全屏页接管画面，切换快照不再需要，避免返回竖屏后留下旧帧。
    _clearFrozenFrame();
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
            lines: widget.detail?.lines ?? const <LineInfo>[],
            lineName: _info?.lineName ?? '',
            rate: realRate,
            qualityKey: _qualityKey,
            canChangeLine: widget.onChangeLine != null,
            castOwner: this,
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
      if (result.rate > 0) {
        _rate = result.rate;
        try {
          await c.setRate(_rate);
        } catch (_) {}
      }
      if (switched && result.loaded) widget.onEpChange?.call(result.ep);
      if (result.requestLineChange) {
        if (result.sourceFailed && widget.onSourceFailed != null) {
          // 全屏里连续播放失败自动换线：交回与竖屏失败完全相同的路径
          // （先原线重试一次、带缓冲态，仍失败才记入失败线路换下一条）。
          widget.onSourceFailed!();
        } else {
          // 全屏错误页点了「换线路」：退出后直接切下一条线路。
          widget.onChangeLine?.call();
        }
      }
    }
    // 先同步完集数/进度归属，再交回视频层并恢复监听，避免全屏里
    // 已经换集时把新位置记到旧集。
    if (mounted && _fullscreenActive) {
      setState(() => _fullscreenActive = false);
    }
    // _loading 时说明刚按上面的失败回调进入重试（缓冲态），
    // 这时不能再把错误层盖回去，否则会先闪一下错误页。
    if (c.value.hasError && !_error && !_loading) {
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
                  key: ValueKey<int>(_videoEpoch),
                  player: c,
                  subtitleBottom: fxSubtitleMinBottom,
                ),
              ),
            // 切线路 / 切集：上一帧快照盖住已被清空的 Video 纹理，
            // 新流首帧就绪后 200ms 淡出；截图失败时保持纯黑底 + 加载层。
            if (!_fullscreenActive && _frozenFrame != null)
              Positioned.fill(
                child: FxAspectBox(
                  child: (context, fit) => FxSnapshotLayer(
                    bytes: _frozenFrame,
                    opaque: _frozenOpaque,
                    fit: fit,
                  ),
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
                    final percent = v.bufferingPercent;
                    return FxLoadingOverlay(
                      title:
                          percent == null ? '缓冲中…' : '缓冲中 ${percent.round()}%',
                      percent: percent,
                      dim: false,
                      compact: true,
                    );
                  },
                ),
              ),
            if (_loading && !_error && !_suppressLoading) _buildLoading(),
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
    final title = fxLoadingLineText(_requestEp, _loadingLineName);
    // 只显示本次 open 的新播放器缓存进度；新实例还没建好时用不确定圆环，
    // 不能拿旧 controller 的百分比冒充新集进度。
    final c = _loadingPlayer;
    if (c == null) {
      return Positioned.fill(
        child: FxLoadingOverlay(title: title, compact: true),
      );
    }
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: c,
        builder: (context, _) => FxLoadingOverlay(
          title: title,
          percent: c.value.bufferingPercent,
          compact: true,
        ),
      ),
    );
  }

  Widget _buildError() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: .36),
        alignment: Alignment.center,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 20),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .94),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .18),
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

  void _requestLineChange() {
    if (widget.onChangeLine != null) {
      widget.onChangeLine!();
      return;
    }
    widget.onSourceFailed?.call();
  }

  /* ---------------------------------------------------------- 播放设置面板 */

  /// 竖屏顶栏「⋯」：与全屏共用同一个「播放设置」面板。
  /// 画面比例 / 镜像模式在面板里改全局设置，立即生效、不重载视频。
  Future<void> _openMorePanel() async {
    _hideTimer?.cancel();
    if (mounted) setState(() => _controls = true);
    await showFxMorePanel(
      context,
      loopMode: _loopMode,
      markLabel: _markLabel,
      onLoopChanged: _setLoopMode,
      onJumpPanel: () => unawaited(_openJumpSheet()),
      onSleepTimer: () => unawaited(_openSleepPanel()),
      onDownload: () {},
      onSpeed: () => unawaited(_openSpeedPicker()),
      onBackground: () {},
      onFeedback: () {},
    );
    if (!mounted) return;
    _showControls();
  }

  /// 循环播放：单集循环交给 mpv（loop-file），关闭则按「自动下一集」连播。
  void _setLoopMode(FxLoopMode mode) {
    if (_loopMode == mode) return;
    setState(() => _loopMode = mode);
    final c = _controller;
    if (c == null) return;
    unawaited(c.setLooping(mode == FxLoopMode.single));
  }

  Future<void> _openSpeedPicker() async {
    final rate = await showFxSpeedSheet(context, _rate);
    if (!mounted || rate == null) return;
    _rate = rate;
    try {
      await _controller?.setRate(rate);
    } catch (_) {}
  }

  /// 定时关闭：竖屏用底部卡片打开同一个 [FsSleepPanel]，模式存进
  /// [AppSettings]（分钟模式带截止时间戳，杀进程再进来能续上）。
  Future<void> _openSleepPanel() async {
    final settings = AppSettings.instance;
    await settings.init();
    if (!mounted) return;
    final mode = settings.sleepMode;
    final minutes = settings.sleepMinutes;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: .38),
      builder: (sheetContext) => Center(
        child: FsSleepPanel(
          mode: mode,
          minutes: minutes,
          onPick: (next, nextMinutes) {
            Navigator.of(sheetContext).maybePop();
            unawaited(_applySleep(next, nextMinutes));
          },
          onCustom: () async {
            Navigator.of(sheetContext).maybePop();
            final picked = await showFxSleepCustomDialog(
              context,
              current: mode == FxSleepMode.minutes ? minutes : 0,
            );
            if (picked == null || !mounted) return;
            await _applySleep(FxSleepMode.minutes, picked);
          },
        ),
      ),
    );
    if (!mounted) return;
    _showControls();
  }

  /// 落地定时关闭：分钟模式记截止时间戳；到点只暂停，保留进度。
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

  /// 进页续上持久化的分钟定时：没过期按剩余时间重新武装。
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

  /// 「跳过片头片尾」行：点开分秒输入面板（竖屏弹层，全屏同一套面板）。
  Future<void> _openJumpSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: .38),
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        // 输入时键盘不盖住面板：整体抬到键盘之上。
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: Center(
          child: FsJumpPanel(
            mark: _mark,
            onApply: (intro, outro) =>
                unawaited(_saveMark(intro: intro, outro: outro)),
            onClear: () => unawaited(_saveMark(clear: true)),
          ),
        ),
      ),
    );
    if (!mounted) return;
    _showControls();
  }

  /// 读本剧片头 / 片尾标记（进页与改标记后各读一次）。
  Future<void> _loadMark() async {
    final mark = await VideoMarks.load(widget.videoId);
    if (!mounted) return;
    setState(() => _mark = mark);
  }

  /// 写本剧片头 / 片尾时长：[clear] 删掉整份，否则两项一起覆盖。
  Future<void> _saveMark({
    int intro = 0,
    int outro = 0,
    bool clear = false,
  }) async {
    final id = widget.videoId;
    if (clear) {
      await VideoMarks.clear(id);
    } else {
      await VideoMarks.save(
        id,
        VideoMark(introSeconds: intro, outroSeconds: outro),
      );
    }
    final mark = await VideoMarks.load(id);
    if (!mounted) return;
    setState(() => _mark = mark);
  }

  /// 「跳过片头片尾」行右侧文案：片头 00:30 · 片尾 01:00 / 未设置。
  String get _markLabel {
    if (_mark.isEmpty) return '未设置';
    return '片头 ${fxTime(Duration(seconds: _mark.introSeconds))}'
        ' · 片尾 ${fxTime(Duration(seconds: _mark.outroSeconds))}';
  }

  /// 开播 / 切集按本剧时长跳，每集各只触发一次（重新开流时复位）：
  /// position < 片头秒数 → seek 到片头秒数（跳过前 N 秒）；
  /// 时长 - position ≤ 片尾秒数 → seek 到本集结尾（交给播完流程切下一集）。
  /// 两项都没设（0）时直接返回，任何位置都不跳。
  void _maybeApplyMark(Duration position) {
    final intro = _mark.introSeconds;
    final outro = _mark.outroSeconds;
    if (intro <= 0 && outro <= 0) return;
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final dur = c.value.duration;
    if (dur <= Duration.zero) return;
    // 片头 / 片尾 ≥ 整集时长 = 配错了：宁可不跳，也不把整集跳没。
    if (intro > 0 &&
        !_introJumped &&
        intro < dur.inSeconds &&
        position < Duration(seconds: intro)) {
      _introJumped = true;
      unawaited(c.seek(Duration(seconds: intro)));
      return;
    }
    if (outro > 0 &&
        !_outroJumped &&
        outro < dur.inSeconds &&
        dur - position <= Duration(seconds: outro)) {
      _outroJumped = true;
      // 留 0.6 秒收尾：mpv 播到末尾自然触发完成 → 正常切集 / 结束。
      final target = dur - const Duration(milliseconds: 600);
      unawaited(c.seek(target.isNegative ? Duration.zero : target));
    }
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
                  Colors.black.withValues(alpha: .55),
                  Colors.black.withValues(alpha: 0),
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
                  onTap: () => unawaited(openCastSheet()),
                ),
                const SizedBox(width: 6),
                PGlassIcon(
                  icon: Icons.more_horiz_rounded,
                  size: 31,
                  iconSize: 18,
                  tooltip: '播放设置',
                  onTap: () => unawaited(_openMorePanel()),
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
                  Colors.black.withValues(alpha: 0),
                  Colors.black.withValues(alpha: .62),
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
                                    ? Fx.accent.withValues(alpha: .9)
                                    : Colors.white.withValues(alpha: .08),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: .18),
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

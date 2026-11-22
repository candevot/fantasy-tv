import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../services/cms_bridge.dart';
import '../services/search_rank.dart';
import '../services/cast_service.dart';
import '../services/app_settings.dart';
import '../services/auto_resume.dart';
import '../services/episode_step.dart';
import '../services/exo_player.dart';
import '../services/fx_player.dart';
import '../services/fx_video_geometry.dart';
import '../services/fallback_match.dart';
import '../services/playback_progress.dart';
import '../services/line_cooldown.dart';
import '../services/line_fallback_order.dart';
import '../services/line_health.dart';
import '../services/line_probe.dart';
import '../services/iq_codec_gate.dart';
import '../services/iqiyi_codec.dart';
import '../services/jar_log.dart' show fxJarLog, fxJarPlayTag;
import '../services/play_log.dart';
import '../services/play_orientation.dart';
import '../services/play_path.dart';
import '../services/screen_orientation.dart';
import '../services/video_marks.dart';
import '../theme.dart';
import '../widgets/cast_sheet.dart';
import '../widgets/fs_panels.dart';
import '../widgets/playback_diagnostics_panel.dart';
import '../widgets/player_gestures.dart';
import '../widgets/player_more_panel.dart';
import '../widgets/player_theme.dart';
import 'fullscreen_page.dart';
import 'history_page.dart' show FxStore;
import '../utils/fx_route.dart';

/// 当前线路不能直接播放的原因，交给外层决定换线路与提示文案。
enum SourceIssue { parse, empty, expired, error }

/// 换源 / 换线路降级前抓下来的「播放现场」（FX_FALLBACK，2026-11-15）。
///
/// 三段降级换的不只是线路，可能是**另一条记录 / 另一个源**，换完之后必须还能
/// 接着看：集号、位置、是否在播都要带过去。位置优先取播放器真实进度，
/// 播放器已经报错（位置可能被重置）时退回最后一次正常位置 / 切换期间锁定的进度。
class FxPlaybackSnapshot {
  const FxPlaybackSnapshot({
    required this.ep,
    required this.position,
    required this.playing,
    required this.lineId,
  });

  final int ep;
  final Duration position;
  final bool playing;
  final String lineId;

  /// 位置（秒）—— 换源后 seek 用它。
  double get seconds => position.inMilliseconds / 1000.0;
}

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
    this.onVideoAspect,
    this.onAllLinesFailed,
    this.onRetryAllLines,
    this.autoPlay = true,
    this.startSeconds,
  });

  final String videoId;
  final int ep;
  final String line;
  final VideoDetail? detail;

  /// 起播位置（秒），null = 按本地保存的进度续播。
  ///
  /// FX_FALLBACK（2026-11-15）：跨源换源是**换一条记录再打开**（详情页
  /// pushReplacement），新页面的本地进度是空的；换源前把「第 N 集 + 当前
  /// 进度」原样带过来，用户看到的才是「接着刚才的地方播」。
  final double? startSeconds;
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

  /// 本片**所有线路**都试完仍不可播（AUTO_LINE_FULL 2026-11-15）。
  ///
  /// 播放器自己把每条线路轮流试了一遍，全失败才回调这里；外层（详情页）
  /// 接着走第 2 / 3 段（同源其他版本 → 跨源同名）。没有外层时（独立播放页 /
  /// 全屏）播放器自己给最终提示，不把「换线路」这件事推给用户。
  final VoidCallback? onAllLinesFailed;

  /// 最终失败后用户点了「重试」：外层要重置降级状态（重新从第一条线路开始试，
  /// 并且允许再跨源找一次）。
  final VoidCallback? onRetryAllLines;

  /// 视频真实宽高比就绪 / 变化时回调（如 2.4:1 = 2.4、竖屏 9:16 ≈ 0.5625）。
  ///
  /// 外层页面拿它算播放区高度，让容器跟着视频比例变（ASPECT_REAL
  /// 2026-11-15）。只报真实值，拿不到宽高时不回调 —— 外层保持上一次的值。
  final ValueChanged<double>? onVideoAspect;

  final bool autoPlay;

  @override
  State<PlayerView> createState() => PlayerViewState();
}

class PlayerViewState extends State<PlayerView> with WidgetsBindingObserver {
  /// 起播阶段「连续无进展」判定窗口（SLOW_NET 2026-11-15）。
  ///
  /// 这里**不再有**「页面固定等 8 秒就判死」这回事。用户明确反对：
  ///
  /// > 一定要是真失败才会跳过，而不是没有加载出来就跳过。
  /// > 比如用户网速是真的慢。
  ///
  /// 现在页面和内核用同一个口径（[FxProgressWindow]）：每 500ms 采一次
  /// `bytesLoaded / buffered / position`，任意一项在涨就一直等；
  /// 连续 [fxStartupNoProgressWindow]（8 秒）三项全都不动才算真卡死。
  /// 慢到 60 秒还在动，只弹「继续等待 / 换条线路」两个按钮让用户自己选，
  /// 到 [fxSlowStartupCap]（120 秒）也不替他判失败。
  static const Duration _openNoProgressWindow = fxStartupNoProgressWindow;

  /// 切线路时最多尝试的线路数（含用户选中的目标线路）。
  ///
  /// SLOW_NET（2026-11-15）：每条线路的等待时间**不再按总时长封顶** ——
  /// 慢网下一条线路正常也要十几二十秒，按时间封顶等于专挑慢网下手。
  /// 现在每条线路只在「连续 8 秒毫无进展」或「原生报真失败」时才被放弃，
  /// 所以这里的 3 次是「真失败时的连续失败次数」，不是时间预算。
  /// 换线 / 失败兜底时最多试几条线路。
  ///
  /// LINE_ATTEMPTS（2026-11-22 真机）：jar 源一个片子常有 6~14 条子线路
  /// （咕噜4K / 咖啡4K / 金牌极速 / 玫瑰4K…），只试 3 条经常全落在坏线上，
  /// 用户看到的就是「失败也不自动切」。放到 5 条：坏线 8 秒内判死（判死
  /// 口径已修，见 FxProgressWindow.stalledFor），5 条最多也就几十秒。
  static const int _maxLineAttempts = 5;

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

  /// 父级上一次传进来的线路（用来区分「父级换线」和「我们自动换线兜底」）。
  String _lastWidgetLine = '';
  int _loadToken = 0;

  /// controller 实际已经打开的集。进度只写这一集，loading 时不写。
  int? _loadedEp;

  /// 正在打开的组合（line|ep）：同一组合重复请求直接复用，防重复 open。
  String? _openingKey;
  Future<bool>? _opening;

  /// 在跑的那次 open 的 `_loadToken`。
  ///
  /// OPEN_GATE（2026-11-15）：只按 key 去重会把「重试」吃掉 —— 页面点重试时
  /// token 已经推进（旧的一次注定作废），如果仍然按 key 命中，重试就只是把
  /// 那个旧 Future 又领回来，新的一次 open 从来没发出去，界面永远停在
  /// 「正在加载 第01集」。所以去重要同时比对 token，规则在
  /// `play_path.dart` 的 [shouldReuseOpen] 里，单测钉住。
  int _openingToken = 0;

  /// 当前集播放 30 秒后已预解析的下一集，避免 10 秒定时器重复请求。
  bool _nextPrewarmed = false;
  int? _prewarmEp;
  DateTime? _prewarmAt;

  /// 正在 open 的新播放器：loading 浮层据此显示真实缓冲进度，
  /// 而不是复用旧 controller 的缓存百分比。
  FxPlayer? _loadingPlayer;

  /// 已经触发过原生下一集预载的那一集（改动 ⑥）。
  ///
  /// 存集号而不是 bool：换集之后自然失效，回来重播同一集也不会重复预载。
  int? _nativePreloadedEp;

  /// 缓存命中 + 已有上一帧快照时跳过 loading 浮层，直接 open。
  bool _suppressLoading = false;

  /// 全屏内选择的清晰度，退出全屏时随结果带回。
  String? _qualityKey;

  bool _loading = true;
  bool _error = false;
  String _errorText = '';

  /// PLATFORM_PENDING：详情页正在现场解析某条平台线路时显示在画面上的提示。
  /// 只盖一层提示，不打断当前播放、不改播放器状态机。
  String _resolvingText = '';
  bool _sourceFailNotified = false;
  bool _ended = false;

  bool _controls = true;
  Timer? _hideTimer;

  /// IQ_CODEC（2026-11-15）：这次 open 用的是 HEVC 还是降级后的 AVC。
  ///
  /// 只影响「通知条 / 日志怎么说」，不改播放行为 —— 地址选择在
  /// [IqCodecGate.plan] 里已经定了。
  bool _iqHevc = false;
  bool _iqDegraded = false;

  /// 已经提示过的「这集用什么编码」（`videoId|线路`，一集只提示一次）。
  String _codecNoticeKey = '';

  /// 播放诊断浮层（默认关，持久化在 AppSettings.playbackDiagnostics）。
  ///
  /// DIAG（2026-11-15）：竖屏内嵌播放器里长按「片名」那一行切换；
  /// 只是展示，不参与播放逻辑，也不拦手势（浮层外层包 IgnorePointer）。
  bool _showDiagnostics = false;

  /// 正在切换线路（防止重复点击并发 open）。
  bool _switchingLine = false;

  /// 换线期间被排队的「原线重试」（RELOAD_DEFER，见 [reload]）。
  bool _pendingReload = false;

  /// 切换卡死时暂存用户最新选择的线路，当前切换一结束就立刻执行。
  (String, int)? _pendingSwitch;

  /// 上一次切换开始时间，用于判定僵死。
  DateTime _switchStartedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 切换代号：被强制接管后，旧的那次必须放弃后续所有状态写入。
  int _switchToken = 0;
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

  /// **用户意图**：现在应该是暂停的（AUTO_RESUME 2026-11-20）。
  ///
  /// 只有用户自己按过暂停（点画面 / 双击 / 底部暂停键）才置 true，点播放
  /// 置回 false。系统的、以及我们自己（换线前先停旧实例、报错、切后台）
  /// 的暂停**都不算** —— 以前拿 `isPlaying` 当用户意图，于是每次换线都会
  /// 把「旧实例被我们 pause 了 / 缓冲中 isPlaying=false」当成「用户暂停」，
  /// 新线路起播后立刻又被暂停，画面就停在第一帧不动。
  bool _userPaused = false;

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

  /// 通知栏 / 锁屏媒体卡片的封面地址（MEDIA_SESSION，2026-11-15）。
  ///
  /// 用的是详情接口的竖版封面：系统媒体卡片是竖排的（和 B 站 / 影视壳一致），
  /// 横版 backdrop 放在那儿会被裁成中间一条。
  String get _coverUrl => (widget.detail?.cover ?? '').trim();

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
    _lastWidgetLine = widget.line;
    WidgetsBinding.instance.addObserver(this);
    // 诊断浮层开关：上次开着就继续开着（两个播放页读同一份设置）。
    unawaited(_restoreDiagnostics());
    _progressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      // 全屏期间由全屏页保存，避免把全屏切换后的位置记到旧集。
      if (!mounted || _fullscreenActive) return;
      unawaited(_saveProgress());
      _maybePrewarmNext();
    });
    unawaited(_loadMark());
    unawaited(_restoreSleepTimer());
    // FX_FALLBACK：跨源换源带来的「第 N 集 + 位置」优先于本地进度。
    final start = widget.startSeconds;
    _bootstrap(
      seekToSaved: start == null,
      saveOld: false,
      resumeSeconds: start,
    );
  }

  @override
  void didUpdateWidget(covariant PlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // LINE_SYNC（2026-11-15）：判断「要不要换线」只能看父级入参有没有真的变，
    // 不能拿 `_line` 比 —— 自动换线失败后 `_line` 已经被改成兜底线路，与
    // widget.line 永久分叉，于是父级任何一次 rebuild 都会再跑一遍「3 条线路
    // × 8 秒」的换线，越换越乱。
    final lineChanged = widget.line != _lastWidgetLine;
    _lastWidgetLine = widget.line;
    if (!lineChanged && widget.ep == _ep) return;
    if (lineChanged) {
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

  /// 这条线路是否需要经过本地代理。
  ///
  /// 只有平台会员线路（腾讯/爱奇艺/芒果，地址是 /api/fyplay、/api/iqiyi.m3u8
  /// 这类需要服务端签名、且会过期的包装地址）才走代理；
  /// 采集线路（红牛/量子/幻想蓝光/4K）是可直接访问的 m3u8，
  /// 交给 mpv 自己拉流最快，也能边下边播大分片。
  Future<void> _switchLine(String targetLine, int targetEp) async {
    if (_switchingLine) {
      // 切换中禁止并发 open，但不能把用户永久锁死：卡顿/上游无响应时
      // 上一次切换可能一直挂着，这时用户点线路会「点不动」。
      // 记住这次请求，等当前切换结束时立即执行最新的那一次；
      // 超过 12 秒仍未结束则判定前一次已僵死，直接接管。
      _pendingSwitch = (targetLine, targetEp);
      final stuckFor = DateTime.now().difference(_switchStartedAt);
      // SWITCH_TAKEOVER（2026-11-22 真机）：用户手点线路必须**立刻**生效。
      // 以前要等满 12 秒才强制接管；配上 jar 线路的长判死窗口，用户点了
      // 另一条线路，界面 10 多秒都没反应 —— 用户的原话是「切线路没生效」。
      // 现在超过 2 秒就直接接管（正在跑的那次结果作废，token 已推进）。
      // 用户点了线路就必须立刻接管：一次都不等。
      if (stuckFor < const Duration(milliseconds: 200)) return;
      debugPrint('[FX] 上一次切换已僵死 ${stuckFor.inSeconds}s，强制接管');
      _switchToken++;
      _switchingLine = false;
    }
    final token = ++_switchToken;
    _switchStartedAt = DateTime.now();
    _pendingSwitch = null;
    _switchingLine = true;
    widget.onSwitchingChanged?.call(true);
    final old = _controller;
    final healthy = old != null &&
        old.value.isInitialized &&
        !old.value.hasError &&
        !_error;
    // 切换动作默认「继续播放」；只有**用户自己按过暂停**才保持暂停
    // （系统 / 我们先 pause 旧实例都不算，见 `_shouldContinuePlayback`）。
    // 以前这里读 `old.value.isPlaying`，而下面几行就会 `old?.pause()`，
    // 于是自动换线永远被判成「用户暂停」→ 新线路停帧。
    final continuePlayback =
        !_covered && fxShouldPlayAfterSwitch(userPaused: _userPaused);
    // LINE_EP_ALIGN（2026-11-15）：一次切换可能同时改线路和集数 ——
    // 详情页换到集数更少的线路时会把集号夹小（第 29 集 → 第 28 集），
    // 这时 `old.value.position` 是**上一集**的位置，原样带过去就是
    // 「第 28 集从第 29 集播到的中段开始」。只有集号没变才沿用当前位置，
    // 集号变了就按该集自己保存的进度续播。
    final sameEp = targetEp == _ep;
    // AUTO_RESUME：**在停旧实例之前**把可信位置抓下来。`old.pause()` 之后
    // 播放器报错 / 复位时位置会变 0，再读就晚了；这里抓一次快照，换线后
    // 用它接续（最多回退 [fxAutoSwitchMaxRewind] = 3 秒）。
    final snap = playbackSnapshot();
    final resume = healthy && sameEp ? old.value.position : Duration.zero;
    final oldDuration = old?.value.duration;
    var resumeSeconds = resume.inMilliseconds / 1000.0;

    try {
      // 先保存旧线路进度（此刻还没进入 loading，_saveProgress 才会生效）。
      await _saveProgress();
      if (!mounted) return;

      if (!healthy || !sameEp) {
        final saved = await fxLoadProgress(widget.videoId, targetEp);
        // 不足 60 秒视为刚看片头，不把 20 秒进度当成续播。
        resumeSeconds = saved >= fxResumeMinSeconds ? saved : 0;
        if (!mounted) return;
      }
      if (sameEp) {
        // 换线接续：以切换前的位置为准，磁盘进度只允许往回差 3 秒以内。
        resumeSeconds = fxResumeSecondsAfterSwitch(
          snapshotSeconds: snap.seconds,
          candidateSeconds: resumeSeconds,
          maxRewindSeconds: fxAutoSwitchMaxRewind.inSeconds.toDouble(),
        );
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
          // 换线 = 用户 / 自动兜底的明确动作：上一次同名请求即使还挂着
          // 也必须真发一次（强制接管路径就是靠这个生效）。
          force: true,
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
        // 只有仍然是「最新那次切换」才回写兜底，过期结果不许改页面状态。
        if (token == _switchToken) widget.onLineFallback?.call(actualLine);
        // 同步「父级最后一次告诉我的线路」：父级随后 rebuild 会带**这条**
        // 线路 id 下来（onLineFallback → 详情页 setState），不回填就会在
        // didUpdateWidget 里再跑一次换线（同一地址再 open 一遍 = 画面又闪
        // 一次加载）。回填成实际生效的线路，不是此刻的 widget.line。
        _lastWidgetLine = actualLine;
        // AUTO_RESUME：新线路必须真的播起来（用户没按过暂停）。
        unawaited(_ensureAutoPlay(lineName: _lineName));
        // 续播点重新 arm：按新线路 + 接上的位置落一次盘，首页「继续观看」
        // 的预取目标（线路 id + 秒数）才不会指向刚失败的那条线。
        unawaited(_saveProgress());
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
        if (token == _switchToken) widget.onLineFallback?.call(lastTried);
      }
    } finally {
      // 被强制接管的话，这次的结果已经过时，不写状态、不解锁。
      final superseded = token != _switchToken;
      if (!superseded) {
        if (mounted) {
          setState(() => _switchingLine = false);
        } else {
          _switchingLine = false;
        }
        widget.onSwitchingChanged?.call(false);
        // RELOAD_DEFER（GULU_FIRST_PLAY 2026-11-22）：换线过程中报上来的
        // 起播失败，原线重试以前被 `reload()` 开头的 `if (_switchingLine) return;`
        // 当场吞掉 —— 而外层 `_reportLineIssue` 在调它之前就已经把
        // `_retriedLine` 记成「这一条试过了」，于是那一次首播失败**永远拿不到
        // 原线重试**（用户看到的就是一直转圈，只能自己手点刷新）。
        // 现在改成排队：换线一收尾立刻补跑一次（force 重解析 = 手点刷新）。
        final deferredReload = _pendingReload;
        _pendingReload = false;
        if (deferredReload && mounted) unawaited(reload());
      }
      if (!superseded) {
        // 切换期间点过的下一集：等本次切换结束再执行，不并发 open。
        final pendingEp = _pendingEp;
        _pendingEp = null;
        if (mounted && pendingEp != null && pendingEp != _ep) {
          unawaited(_switchEpisodeFromParent(pendingEp));
          return;
        }
        // 切换卡顿时用户点过的线路：现在立刻执行他最后选的那条，
        // 不用再点第二次（这就是「卡的时候点不动」的修法）。
        final pending = _pendingSwitch;
        _pendingSwitch = null;
        if (mounted &&
            pending != null &&
            (pending.$1 != _line || pending.$2 != _ep)) {
          unawaited(_switchLine(pending.$1, pending.$2));
        }
      }
    }
  }

  /// 当前线路 + 下一条线路（最多 [_maxLineAttempts] 条），用于失败后的自动兜底。
  List<String> _lineAttempts(String targetLine) {
    final lines = widget.detail?.lines ?? const <LineInfo>[];
    final attempts = <String>[];
    if (targetLine.isNotEmpty) attempts.add(targetLine);
    // GROUP_ORDER（2026-11-21 用户口径）：候补顺序和整轮自动换线**同一份** ——
    // 先当前大类的其它子线路，本大类没有别的了才进下一个大类。
    // 以前是扁平列表 `(index + 1 + step) % lines.length`，健康度 / jar 合并
    // 重排过的列表会让它跨大类乱跳。
    // 「degraded 沉后」只在**同一大类内部**做（全局排又会跨大类）。
    final rest = fxSortDegradedWithinGroups(
      fxFallbackLineOrder(lines: lines, currentLineId: targetLine),
    );
    for (final candidate in rest) {
      if (attempts.length >= _maxLineAttempts) break;
      attempts.add(candidate.id);
    }
    return attempts.take(_maxLineAttempts).toList(growable: false);
  }

  /// 切换线路 / 切集时是否继续播放。
  ///
  /// 唯一依据是**用户意图**（[PlayerViewState._userPaused]）：
  /// - 用户没按过暂停 → 继续播（未就绪 / 出错 / 缓冲中 / 我们先 pause 过
  ///   旧实例，全都属于这一类，切换动作本身就是「继续看」）；
  /// - 用户自己按过暂停 → 保持暂停。
  ///
  /// 以前这里读 `player.value.isPlaying`，而调用点在此之前刚
  /// `_controller?.pause()`，ExoPlayer 缓冲中 `isPlaying` 也是 false ——
  /// 于是自动换线被读成「用户暂停」，新线路起播后又被 pause 回去，
  /// 画面停在第一帧、必须手点播放（AUTO_RESUME 2026-11-20 的根因）。
  bool _shouldContinuePlayback() =>
      fxShouldPlayAfterSwitch(userPaused: _userPaused);

  /// 自动换线 / 切集成功后的「起播兜底」（AUTO_RESUME 2026-11-20）。
  ///
  /// 正常路径上 `_bootstrap(playOverride: …)` 已经带着 `play: true` 打开，
  /// 这里只兜两种残余：原生在 `prepare` 之后把 `playWhenReady` 吞掉了、
  /// 或首帧前一瞬间状态被上一次 open 的收尾覆盖。用户按过暂停就直接返回
  /// （用户的暂停永远优先，自动换线不许把它顶掉）。
  Future<void> _ensureAutoPlay({required String lineName}) async {
    if (_userPaused || !mounted) return;
    final c = _controller;
    if (c == null) return;
    var nudged = false;
    for (var i = 0; i < 12; i++) {
      if (!mounted) return;
      final v = c.value;
      if (v.hasError) return;
      if (v.isPlaying) {
        if (nudged) fxPlayLog('auto resume line=$lineName ok');
        return;
      }
      // 已就绪但没在播：补一次 play()。缓冲中会被原生排到缓冲结束之后，
      // 所以这里每 150ms 看一眼，最多看 1.8 秒。
      if (v.isInitialized) {
        nudged = true;
        try {
          await c.play();
        } catch (_) {}
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (nudged) fxPlayLog('auto resume line=$lineName 未起播（交给看门狗）');
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
    if (!mounted) return;
    if (!healed) {
      // 位置没被重置、也没冻结，但流可能已经断了（后台待久了连接被回收、
      // 平台签名过期）。这时不能什么都不做 —— 交给播放器自检，
      // 真的断了会自动重连并回到原位置，不用用户点重试。
      unawaited(c.resumeSelfCheck());
      return;
    }
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
    // 片尾窗口内一律归零：用户在最后几十秒退出很常见（等片尾曲、
    // 看预告），若照原样存下来，下次打开就从那里播 —— 表现就是
    // 「一打开就是片尾、总共只有几十秒」。
    if (!ended &&
        fxIsFinishedPosition(positionMs / 1000.0, durationMs / 1000.0)) {
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
    bool force = false,
  }) async {
    // 手机重新加载 / 切集 / 换线路时结束投屏：否则电视还在播上一集，
    // 手机同时播新的，就是双声。
    if (CastService.instance.isCasting) {
      await CastService.instance.stop();
      if (!mounted) return false;
    }
    final line = lineOverride ?? _line;
    final ep = epOverride ?? _ep;
    // MEDIA_SESSION（2026-11-15）：封面提前暖到原生缓存。
    //
    // 通知 / 锁屏的封面读的是 MediaMetadata.artworkUri，而 MediaMetadata 在
    // prepare 之前就定死了 —— 等通知要显示封面再下载已经来不及（那会儿还在
    // 抢起播带宽）。放在这里：解析地址那几百毫秒正好够把这张图下完，
    // open 时原生就能直接给 file:// 地址。失败只是通知上少张图，不影响播放。
    unawaited(ExoPlayerEngine.warmArtwork(_coverUrl));
    // 同一 url+line+ep 正在打开时忽略重复请求（防抖），
    // 避免 didUpdateWidget / 连点「下一集」并发 open 造成双播放器与内存翻倍。
    final key = '$line|$ep';
    // 同一个组合正在打开时复用（防连点 / 防 didUpdateWidget 并发 open）。
    // 但被更新的请求取代过的那一次不算（token 已推进），用户点重试 /
    // 强制接管时必须真的重开一次 —— 规则见 [shouldReuseOpen]。
    final opening = _opening;
    if (shouldReuseOpen(
      hasPending: opening != null,
      pendingKey: _openingKey,
      key: key,
      pendingToken: _openingToken,
      currentToken: _loadToken,
      force: force,
    )) {
      return opening!;
    }
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
    // _bootstrapSource 的第一句就是 `++_loadToken`（同步执行到第一个 await），
    // 所以此刻 _loadToken 已经是这次请求的代际。
    _openingToken = _loadToken;
    try {
      return await future;
    } finally {
      if (identical(_opening, future)) {
        _opening = null;
        _openingKey = null;
      }
    }
  }

  /// 起播的**兜底包装**（BOOTSTRAP_GUARD 2026-11-15）。
  ///
  /// 降级链被打断的两个已知方式，这条包装堵住的是第二种：
  /// ```
  /// ① 失败回调只发一次（_sourceFailNotified 锁死）→ 见 [_onPlayerFatal]
  /// ② 起播流程自己抛异常 → 冒泡到 Future，界面停在 loading，
  ///    自动换线那一轮根本没机会开始
  /// ```
  /// 所以这里把整条起播流程包起来：任何意外异常都收敛成「这条线路失败」，
  /// 按本次调用是否允许上报决定要不要通知外层，绝不冒泡。
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
    try {
      return await _bootstrapSourceGuarded(
        seekToSaved: seekToSaved,
        saveOld: saveOld,
        line: line,
        ep: ep,
        commitLine: commitLine,
        reportFailure: reportFailure,
        forcePlayInfo: forcePlayInfo,
        resumeSeconds: resumeSeconds,
        playOverride: playOverride,
      );
    } catch (e) {
      _lastOpenError = '$e';
      fxPlayLog(
        'FAIL line=${fxLineNameOf(widget.detail?.lines ?? const <LineInfo>[], line)} '
        'ep=$ep reason=bootstrap_exception err=$e',
      );
      if (!mounted) return false;
      _clearFrozenFrame();
      setState(() {
        _loading = false;
        _suppressLoading = false;
        if (reportFailure) {
          _error = true;
          _errorText = '播放失败：线路不可用，请重试或切换下方线路';
        }
      });
      if (reportFailure) _notifySourceFailed();
      return false;
    }
  }

  /// 一次起播最多「自动重新解析再起播」几次：见 `play_path.dart` 的
  /// [fxFirstPlayReparseMax]（GULU_FIRST_PLAY 2026-11-22，用户口径 = 2 次，
  /// 日志留痕 `[JarPlay] retry=N …`）。用满就走原来的失败链。
  Future<bool> _bootstrapSourceGuarded({
    required bool seekToSaved,
    required bool saveOld,
    required String line,
    required int ep,
    required bool commitLine,
    required bool reportFailure,
    required bool forcePlayInfo,
    double? resumeSeconds,
    bool? playOverride,

    /// 第几次「重新解析后重起播」（0 = 首播）。重试沿用同一个代际，
    /// 不再 `++_loadToken` —— 否则上一层的 `_openingToken` 会对不上，
    /// 用户这时点线路会被判成「重复请求」而吞掉。
    int reparse = 0,

    /// 上一次失败用的地址（打进 `[JarPlay] retry=N … old=`）。
    String prevUrl = '',

    /// 上一次失败的原因（打进 `retry=N … reason=`）。
    String retryReason = '',
  }) async {
    final token = reparse == 0 ? ++_loadToken : _loadToken;
    // 纯取值，提前算好：重试路径（见下面的 retry 递归）也要用它们打日志。
    final openLineName =
        fxLineNameOf(widget.detail?.lines ?? const <LineInfo>[], line);
    final openSource = CmsBridge.isCms(widget.videoId) ? 'cms' : 'legacy';
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
    // WARMUP_NONBLOCK（ALIGN_FONGMI 2026-11-15）：不再有「首次打开等预热」
    // 这回事 —— 预热只剩 DNS 解析，且永远 fire-and-forget。
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
    } catch (e) {
      _lastOpenError = '$e';
      if (!mounted || token != _loadToken) return false;
      // CMS 需要解析的线路：解析服务失败时把真实原因透出来
      // （「该线路解析失败」），别一律说成「检查网络」。
      final message = e is ApiException && e.message.trim().isNotEmpty
          ? e.message.trim()
          : '获取播放地址失败，请检查网络后重试';
      setState(() {
        _loading = false;
        _suppressLoading = false;
        if (reportFailure) {
          _error = true;
          _errorText = message;
        }
      });
      if (reportFailure) {
        _clearFrozenFrame();
        _notifySourceFailed();
      }
      return false;
    }
    if (!mounted || token != _loadToken) return false;
    // GULU_FIRST_PLAY：第 2 次起播 = 上一次自动重新解析拿回来的新地址。
    // 这行就是验收要的证据：`old=` 是卡住的那条，`new=` 是重解析签出来的那条。
    if (reparse > 0) {
      fxJarLog(
        fxRetryLog(
          retry: reparse,
          line: openLineName,
          ep: ep,
          reason: retryReason,
          oldUrl: prevUrl,
          newUrl: info.url,
        ),
        tag: CmsBridge.isJarLine(line) ? fxJarPlayTag : fxPlayTag,
      );
    }
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
    // 统一补成绝对地址：服务端有些线路给的是 /api/fyplay、/api/iqiyi.m3u8
    // 这类站内相对路径，补全后 mpv 才能直接拉（否则只能走客户端代理，
    // 而代理是整片下完再交给 mpv，4K 大分片会一直卡）。
    final candidates = <String>[];
    for (final u in all) {
      final abs = CmsBridge.absolutePlayUrl(widget.videoId, u);
      if (!candidates.contains(abs)) candidates.add(abs);
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
    // KNOWN_BAD（2026-11-15）：**解析必然失败的地址不打开**。
    //
    // 幻想蓝光的 FY-PAN1 令牌（`/hxparse/play/fuying/FY-PAN1-…`）服务端一律
    // 404、mgtv 的网页地址我们这边没有解析器。这类地址以前照样交给播放器，
    // 代价是一整个起播超时窗口（有时还会把原生主线程带崩 —— 见原生
    // CRASH_GUARD2）。现在判定和解析层 / 服务端同一份（[isDeadAddress]）：
    // 命中就当场按「这条线路失败」收尾，立刻进入下一条，0 秒浪费。
    final usable = <String>[
      for (final u in candidates)
        if (!isDeadAddress(u)) u,
    ];
    if (usable.isEmpty) {
      final name =
          fxLineNameOf(widget.detail?.lines ?? const <LineInfo>[], line);
      fxPlayLog(
          'FAIL line=$name ep=$ep reason=dead_line url=${candidates.first}');
      FxLineCooldown.markFailed(widget.videoId, name);
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

    var saved = resumeSeconds ??
        (seekToSaved ? await fxLoadProgress(widget.videoId, ep) : 0.0);
    // 续播门槛：只看本地保存的进度，活跃切换（resumeSeconds）不受影响。
    final fromSavedPosition = resumeSeconds == null && seekToSaved;
    if (fromSavedPosition && saved < fxResumeMinSeconds) saved = 0;
    if (!mounted || token != _loadToken) return false;
    final shouldPlay = playOverride ?? (widget.autoPlay && !_covered);

    var ok = false;
    // PLAY_LOG / AUTO_LINE（2026-11-15）：起播计时 + 明确的失败日志。
    // 用户报障时只要 `adb logcat | grep FxPlay` 就能看到
    // `line=… url=… source=cms|legacy kind=direct|parse`，
    // 以及失败时的 `FAIL … elapsed=…`，不用再猜走了哪条路。
    // openLineName / openSource 在函数开头就算好了（重试路径也要用）。
    final openWatch = Stopwatch()..start();
    // 最后一次真正交给内核的地址：自动重新解析时打进 `retry=N … old=`。
    var lastOpenedUrl = '';
    // SWITCH_INSTANCE_REUSE（改动 ④）：换集 / 换线路**复用同一个 FxPlayer**。
    //
    // 以前每次 open 都 `FxPlayer.create()`，成功后 `previous.dispose()`：
    // 那个 dispose 会一路走到原生 `release` → `player.release()` + 缓存释放
    // + 事件通道解绑。也就是说「刚起来的新一集」会在几百毫秒内被上一次的
    // 实例拆掉重建，用户看到的就是换集卡一下、偶尔黑屏一下。
    //
    // 现在只有「第一次打开 / 上一个实例已经释放」才新建实例；换集只换源
    // （原生走 stop + clearMediaItems + setMediaSource + prepare）。
    final reusable =
        (_controller != null && !_controller!.isDisposed) ? _controller : null;
    // IQ_CODEC（2026-11-15）：爱奇艺线路按**设备硬解能力**选编码。
    //
    // 「能硬解 HEVC 的机器要 1080P HEVC，不能的才退 896×504 H.264」——
    // 能力探测在原生（`supportsHevc`），地址改写 / 失败降级在 IQ gate 里，
    // 这里只是把候选地址换成「按能力排好的尝试序列」：
    //   · 支持 HEVC → [hevc=1 的地址, 去掉 hevc 的同一条, …原来的其它候选]
    //   · 不支持    → 原地址（服务端默认就是 AVC，896×504）
    // HEVC 起播失败时循环自然落到下一条（AVC），降级只发生一次，
    // 日志固定 `[FxPlay] iqiyi downgrade hevc->avc`。
    await IqCodecGate.ensure();
    if (!mounted || token != _loadToken) return false;
    // KNOWN_BAD：只把「不是死形态」的地址交给播放器（usable 见上）。
    final targets = IqCodecGate.plan(usable);
    var openedHevc = false;
    var openedDegraded = false;
    for (final target in targets) {
      if (!mounted || token != _loadToken) return false;
      final url = target.url;
      lastOpenedUrl = url;
      if (target.degradeFromHevc) fxPlayLog(iqDegradeLog(url));
      final controller = reusable ?? FxPlayer.create();
      // BG_SERVICE / MEDIA_SESSION（2026-11-15）：通知栏 + 锁屏的
      // 「片名 / 第N集 · 线路名 / 封面」。在 open 之前登记：原生会把这份
      // 元数据挂到 MediaItem 上（prepare 之后再改就得重新起播），
      // 换集 / 换线路时这里会带着新集号重登记一次。
      controller.setBackgroundMedia(
        _title,
        ep,
        line: openLineName,
        cover: _coverUrl,
        hasPrev: _hasEpStep(ep, -1),
        hasNext: _hasEpStep(ep, 1),
      );
      // 媒体按键（通知栏 / 锁屏 / 耳机线控 / 车机）的上一集 / 下一集。
      // 每次 open 都重挂一次：复用同一个 FxPlayer 实例时旧的闭包可能已经
      // 指向上一轮的页面状态。
      controller.onEpisodeStep = _handleMediaStep;
      if (mounted) setState(() => _loadingPlayer = controller);
      try {
        fxPlayLog(
          'open line=$openLineName url=$url source=$openSource '
          'kind=${needsParseAddress(url) ? 'parse' : 'direct'}',
        );
        // SLOW_NET（2026-11-15）：这里**不看总时长**。以前的写法是
        // `.timeout(8s)` —— 慢网必误杀（几十 KB/s 拉 4K 清单 + 首片，
        // 20 秒才出首帧很正常）。现在交给 [_awaitOpenWithProgress]：
        // 有进展就一直等，连续 8 秒三项全不动才判失败。
        // PROBE_PARALLEL（2026-11-15）：预检结果只写进线路健康档案
        // （详情页排序用），不再参与起播判定 —— 播放器那边已经改成和 open
        // 并行跑，这里只负责把「这条线路好/坏」记下来给下次排序参考。
        controller.onProbeResult = (result) {
          // 预检结果单独一条日志（格式固定，排障用 grep）：
          //   [FxPlay] probe line=幻想4K ok=true stage=segment
          //   [FxPlay] probe line=mgtv ok=false stage=manifest reason=http_404
          // 预检现在是并行的，日志在这里出（拿到线路名 + 一定只出一次），
          // 不再依赖「open 返回时 lastProbe 已经就绪」。
          fxPlayLog(fxProbeLogMessage(line: openLineName, probe: result));
          unawaited(
            LineHealth.instance.record(
              vodId: widget.videoId,
              lineName: openLineName,
              ok: result.ok,
            ),
          );
        };
        final openFuture = controller.open(
          url,
          headers: info.headers,
          play: shouldPlay,
          // 续播：起始位置直接交给 open（原生 prepare 之前 seekTo），
          // 首个分片请求就是目标片。以前先拉第 0 片再 seek，第 0 片会
          // 把服务端 /api/seg 的首片中转名额用掉，续播反而更慢。
          startPosition: Duration(
            milliseconds: saved.isFinite ? (saved * 1000).round() : 0,
          ),
          // 用服务端声明的类型：幻想自建的地址没有 .m3u8 后缀，
          // 按后缀猜会被当成普通视频，直接解析失败。
          isHls: info.isHls,
          // GULU_FIRST_PLAY：短寿命线路不做任何前置动作（不预检、
          // 不预取拖动索引）—— 它们抓的就是播放器正在用的这条地址，
          // 抢一次就可能让首播 0 KB/s 卡住。详见 FxPlayer.open 的说明。
          preflight: !FxPlayCache.isShortLived(line),
          // JAR_WARM（2026-11-22）：jar 线路并行拉热首片前 1MB。
          // 实测冷边缘 10~25 秒、热边缘 1.6 秒，这一步只读数据、不碰
          // 现签令牌，也不阻塞 open。详见 _FxJarWarm 的注释。
          warmSegments: FxPlayCache.isShortLived(line),
          // 只有「平台签名线路」才走本地代理（需要代理改写签名、
          // 定时换新地址）。普通采集线路直接交给 mpv 边下边播。
          //
          // 这是 4K 卡顿的根因：代理是「整片下完再交给 mpv」，
          // 1080P 分片 1~2MB 看不出来，4K 分片 10~40MB 时
          // mpv 要等整个分片下完才能解码，表现就是一直卡、
          // 一直转圈。别的播放器没这问题就是因为它直接让 mpv 拉流。
          // 按实际地址判断：腾讯直连是 CDN 绝对地址，不需要代理；
          // 只有爱奇艺 /api/iqiyi.m3u8 这类站内包装地址才需要。
          // HLS 一律交给本地代理：整集预加载 / 预取让位 / 下一片保护
          // 全都做在代理里，采集线路（红牛/量子/蓝光/4K）也是公网直链，
          // 之前被判「不需要代理」就完全享受不到这些优化。
          direct: fxShouldUseHlsProxy(url, isHls: info.isHls),
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
                final fresh = await CmsBridge.play(widget.videoId, ep, next.id);
                // 救援换线同样补成绝对地址，避免新线路退化成走代理。
                final freshUrl =
                    CmsBridge.absolutePlayUrl(widget.videoId, fresh.url);
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
        );
        // IQ_CODEC：HEVC 候选的「无进展」窗口收紧到 8 秒（解码器起不来时
        // 不值得拖），超时 / 解码报错都会落到 catch，下一条就是它的 AVC 地址。
        await _awaitOpenWithProgress(
          controller,
          openFuture,
          hevc: target.hevc,
          // SH4K_RETRY：令牌解析线路（SH4K / 幻想4K / hxparse 包装地址）
          // 给 20 秒无进展窗口；直链仍是 8 秒。
          noProgress: fxStartupNoProgressWindowFor(
            url: url,
            lineName: openLineName,
            // JAR_FIRST_WINDOW：jar 线路冷边缘要回源 10~25 秒，8 秒窗口会把
            // 正常起播判死（用户实测「加载两下就 0KB」）。详见 auto_resume。
            jarLine: CmsBridge.isJarLine(line),
          ),
        );
        // 被新一次 open 取代：只回收**本次新建**的实例。
        //
        // SWITCH_REUSE_GUARD（2026-11-15）：复用实例（`reusable`）是后来的
        // 那次 open 正在用的同一个对象，这里 dispose 掉它就是「旧请求把新
        // 播放器拆了」—— 原生已释放、Dart 侧还认为已就绪，结果是新的一次
        // 起播被判「线路不可用」（还会被冷却 10 分钟）、画面停帧或黑屏。
        if (!mounted || token != _loadToken) {
          if (!identical(controller, reusable)) {
            await controller.dispose();
          }
          return false;
        }
        _activeCastUrl = url;
        await controller.setLooping(false);
        try {
          await controller.setRate(_rate);
        } catch (_) {}
        final durationMs = controller.value.duration.inMilliseconds;
        var resume = saved;
        // 旧版本存下的「距结尾几十秒」进度也要在这里兜住：
        // 否则升级后第一次打开仍然会直接跳到片尾。
        if (fxIsFinishedPosition(resume, durationMs / 1000.0)) {
          resume = 0;
        }
        final landedSeconds = controller.value.position.inMilliseconds / 1000.0;
        if (resume > 0) {
          // 静默续播：open 已带着起始位置就位，没落准时才补跳一次
          // （补跳会让目标分片重下一次）。
          if ((landedSeconds - resume).abs() > 1.0) {
            await controller.seekTo(
              Duration(milliseconds: (resume * 1000).round()),
            );
          }
        } else if (landedSeconds > 1.0) {
          // 片尾窗口 / 越界：明确回到开头，不能停在片尾。
          await controller.seekTo(Duration.zero);
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
        // 复用实例不能在这里 dispose（它是后一次 open 正在用的那一个）。
        if (!mounted || token != _loadToken) {
          if (!identical(controller, reusable)) {
            await controller.dispose();
          }
          return false;
        }
        final previous = _controller;
        // 复用实例时监听器已经在挂了，别 remove 掉（否则进度 / 首帧 / 结束
        // 事件全部失联）。
        if (!identical(previous, controller)) {
          previous?.removeListener(_onVideoValue);
        }
        _controller = controller;
        _ep = ep;
        if (commitLine) _line = line;
        _loadedEp = ep;
        controller.addListener(_onVideoValue);
        // 复用实例时宽高早就有了，监听器不会为新一集再触发；这里补报一次，
        // 页面的播放区高度才能跟上这一集的真实比例（ASPECT_REAL）。
        _reportVideoAspect(controller);
        // 只有真的换了实例才释放旧的：复用路径下「旧的就是它自己」。
        if (!identical(previous, controller)) {
          unawaited(previous?.dispose());
        }
        setState(() {
          _loading = false;
          _suppressLoading = false;
          _error = false;
          _errorText = '';
        });
        _sourceFailNotified = false;
        // STALL_RESET（2026-11-15）：这一次起播成功了，就清掉「本轮已判卡死」
        // 的记录。原来这个字段只写不清，同一条线路在一集里卡死过一次之后，
        // 后面再卡就是纯等 —— 永远不再自动换线（用户看到的是一直转圈）。
        _bufferingFailedLine = '';
        _stallProgress.reset();
        openedHevc = target.hevc;
        openedDegraded = target.degradeFromHevc;
        _iqHevc = openedHevc;
        _iqDegraded = openedDegraded;
        openWatch.stop();
        fxPlayLog(
          'OK line=$openLineName url=$url source=$openSource '
          'elapsed=${openWatch.elapsedMilliseconds}ms',
        );
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
        if (openedHevc || openedDegraded) {
          fxPlayLog(
            'iqiyi codec=${openedDegraded ? 'avc(downgrade)' : 'hevc'} '
            'url=$url',
          );
        }
        widget.onPlaybackStarted?.call();
        _showControls();
        // 续播静默处理：直接停在上次位置，不弹「已跳到上次位置」提示。
        break;
      } catch (e) {
        _lastOpenError = '$e';
        // 复用实例失败时**不能** dispose：原生那边还要靠它接着试下一个
        // 候选地址（open 会自己重置状态）。只有本次新建的实例才回收。
        if (!identical(controller, reusable)) {
          try {
            controller.dispose();
          } catch (_) {}
        }
        // 慢网硬上限（30 秒）到点：这条线路就算「能播」也等不起了，
        // 直接换下一条，不必在同线路的其它候选地址（HEVC → AVC）上再等一轮。
        // 日志固定 `slow line=… waited=30s buffered=2.1s → switch`。
        if ('$e'.contains('慢网超时')) {
          fxPlayLog(
            fxSlowSwitchLog(
              line: openLineName,
              waitedSeconds: fxSlowStartupCap.inSeconds,
              buffered: controller.value.buffered,
            ),
          );
          break;
        }
      }
    }

    if (mounted && _loadingPlayer != null) {
      setState(() => _loadingPlayer = null);
    }

    if (!ok) {
      if (!mounted || token != _loadToken) return false;
      // GULU_FIRST_PLAY（2026-11-22，用户钉死的口径）：首播失败或无进展时
      // **自动重新解析再起播**，最多 2 次，等价于用户手点右上角「刷新」
      // （实测：咕噜首播 0 KB/s 卡死，手点刷新立刻秒播）。
      //
      // 两条不许破的既有规则：
      //   · 慢网硬上限（30s 到点直接换下一条）不参与重试 —— 那是用户定的
      //     「到点就切」，不能被这里拖成 30s × 3；
      //   · 重试用尽才落到最后的失败分支（原线重试 → 全线路轮 → 跨源），
      //     自动切线路的既有逻辑一行没动。
      final reason =
          _lastOpenError.trim().isEmpty ? 'no_progress' : _lastOpenError.trim();
      if (fxShouldReparsePlay(reparse: reparse, reason: reason)) {
        openWatch.stop();
        final next = reparse + 1;
        fxJarLog(
          fxRetryLog(
            retry: next,
            line: openLineName,
            ep: ep,
            reason: reason,
            oldUrl: lastOpenedUrl,
            action: 'reparse',
          ),
          tag: CmsBridge.isJarLine(line) ? fxJarPlayTag : fxPlayTag,
        );
        FxPlayCache.invalidate(widget.videoId, ep, line);
        return _bootstrapSourceGuarded(
          seekToSaved: seekToSaved,
          saveOld: false,
          line: line,
          ep: ep,
          commitLine: commitLine,
          reportFailure: reportFailure,
          forcePlayInfo: true,
          resumeSeconds: resumeSeconds,
          playOverride: playOverride,
          reparse: next,
          prevUrl: lastOpenedUrl,
          retryReason: reason,
        );
      }
      openWatch.stop();
      fxPlayLog(
        'FAIL line=$openLineName ep=$ep source=$openSource '
        'reason=candidates-exhausted elapsed=${openWatch.elapsedMilliseconds}ms',
      );
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
        // AUTO_LINE（2026-11-15）：外层没接过失败回调时（全屏页 / 一起看 /
        // 独立播放页），播放器自己换下一条线路 —— 需求是「起播失败要有明确
        // 提示并且能自动换下一条」，这几种页面没有外层可换，只能这里换。
        // AUTO_LINE_FULL（2026-11-15）：外层没接失败回调时（独立播放页 / 一起看）
        // 播放器自己把本片所有线路轮一遍；接了回调的（详情页）由外层统一驱动，
        // 免得两边同时开轮、互相打断。
        if (widget.onSourceFailed == null) _autoSwitchNextLine();
      }
      return false;
    }
    return true;
  }

  /// 全部线路都试完仍不可播（挡住重复回调）。
  bool _linesExhausted = false;

  /// 自动换线路轮正在跑（防止「失败回调」和「用户操作」同时开两轮）。
  bool _autoChainBusy = false;

  /// **自动把本片所有线路依次试一遍**（AUTO_LINE_FULL 2026-11-15）。
  ///
  /// 用户明确要求「失败不能直接报错让用户自己切线路」：这里从当前线路的下一
  /// 条开始，一条一条试到底（每条最多 [fxOpenFirstFrameTimeout]），
  /// 过程中画面上显示「正在尝试其他线路（2/11）」——用户看得见在动，
  /// 不用点任何按钮；**全程不弹错误 toast**。
  ///
  /// 返回 true = 有一条线路接上了（集号与进度沿用换线前的现场）。
  /// 全部失败时复位到第一条线路并交给外层（[PlayerView.onAllLinesFailed]），
  /// 没有外层时自己给最终提示（[fxFallbackAllFailedText]）。
  Future<bool> autoTryAllLines({bool restart = false}) async {
    final lines = <LineInfo>[
      for (final line in widget.detail?.lines ?? const <LineInfo>[])
        if (line.id.trim().isNotEmpty) line,
    ];
    if (lines.isEmpty || !mounted) return false;
    if (_autoChainBusy) return false;
    await FxLineCooldown.load();
    if (!mounted) return false;
    _autoChainBusy = true;
    _linesExhausted = false;
    final total = lines.length;
    final startLine = restart ? '' : _line;
    // 已试过的线路：本轮不再重复（restart 时从第一条开始）。
    final tried = <String>{if (!restart && _line.isNotEmpty) _line};
    final snap = playbackSnapshot();
    // AUTO_RESUME（2026-11-20）：**接上切换前的位置，最多回退 3 秒**。
    final resumeAt = restart
        ? 0.0
        : fxResumeSecondsAfterSwitch(
            snapshotSeconds: snap.seconds,
            candidateSeconds: snap.seconds,
            maxRewindSeconds: fxAutoSwitchMaxRewind.inSeconds.toDouble(),
          );
    // 自动换线成功必须自动起播 —— 判据只有一个：用户自己按过暂停没有。
    // 看 `snap.playing` 是根因所在：进 `_bootstrap` 第一件事就是
    // `_controller?.pause()`（先停旧实例），缓冲中 `isPlaying` 也是 false，
    // 于是「切换前在播」被读成 false，新线路 open 完又被暂停（画面停帧）。
    final playState =
        restart || fxShouldPlayAfterSwitch(userPaused: _userPaused);
    final ep = _ep;
    final videoId = widget.videoId;
    // LINE_COOLDOWN：10 分钟内失败过的线路沉到最后；本轮里它们先跳过，
    // 但如果全都还在冷却期（上一次刚全试完），就把冷却清掉重来一遍 ——
    // 宁可多试一次，也不能对着用户说「没线路」。
    var cooled = FxLineCooldown.sortLines(videoId, lines);
    if (cooled.every(
      (l) => FxLineCooldown.isCooling(videoId, l.displayName),
    )) {
      FxLineCooldown.clearFor(videoId);
      cooled = lines;
    }
    // GROUP_ORDER（2026-11-21 用户口径）：候选顺序**按大类走** ——
    // 先当前大类的其它子线路（按显示顺序），本大类全失败才进下一个大类。
    // 以前是扁平列表 `(index + 1 + step) % length`，而那份列表被健康度排序 /
    // jar 合并重排过，会在「幻想 ↔ 咕噜」之间乱跳。顺序只在
    // [fxFallbackLineOrder] 定义一次，详情页 `_switchNextLine` 用的是同一份。
    final ordered = fxFallbackLineOrder(
      lines: cooled,
      currentLineId: startLine,
    );
    var attempt = 0;
    var ok = false;
    var skippedCooling = 0;
    var deadSkipped = 0;
    try {
      for (final candidate in ordered) {
        if (!mounted) return false;
        if (!tried.add(candidate.id)) continue;
        // KNOWN_BAD（2026-11-15）：死线路（幻想蓝光 FY-PAN1 / mgtv）本轮
        // 直接跳过，不用试 —— 服务端解析一律 404，试它只是白白多等一个
        // 失败窗口。记一笔日志与冷却（下次排序也不会再排前面）。
        if (isDeadLineName(candidate.displayName)) {
          deadSkipped++;
          FxLineCooldown.markFailed(
            videoId,
            candidate.displayName,
            reason: 'dead_line',
          );
          fxPlayLog(
            fxAutoLineLog(
              attempt: attempt + 1,
              total: total,
              name: candidate.displayName,
              ok: false,
              reason: 'dead_line',
            ),
          );
          continue;
        }
        // 冷却中的线路本轮直接跳过（真坏 10 分钟 / 抖动 2 分钟，见
        // `auto_resume.dart` 的 fxCooldownWindowFor）。
        if (FxLineCooldown.isCooling(videoId, candidate.displayName)) {
          skippedCooling++;
          continue;
        }
        var skip = false;
        try {
          attempt++;
          // 进度提示：让用户知道在动，而不是卡死。
          showResolving(fxTryingLineText(attempt, total));
          _lastOpenError = '';
          // SH4K_RETRY（2026-11-20）：令牌解析线路的首帧天然比直链慢
          // （本站 302 → 上游清单 → AES key → 首片，冷启动实测 5~7 秒）。
          // 判死之前补**一次**快速重试（间隔 [fxFastRetryDelay] = 1.5 秒），
          // 别让上游一次抖动就把整条线路标死。真坏（4xx / 解析失败 /
          // 清单非法 / DNS）不补 —— 那几种再要一次也是一样的结果。
          final tokenLine = fxIsTokenParseLine(
            lineName: candidate.displayName,
          );
          var opened = false;
          var reason = '';
          for (var retry = 0; retry <= 1; retry++) {
            if (retry > 0) {
              if (!mounted) return false;
              fxPlayLog(
                'auto line retry fast line=${candidate.displayName} '
                'reason=$reason delay=${fxFastRetryDelay.inMilliseconds}ms',
              );
              await Future<void>.delayed(fxFastRetryDelay);
              if (!mounted) return false;
            }
            final watch = Stopwatch()..start();
            opened = await _bootstrap(
              seekToSaved: false,
              saveOld: false,
              lineOverride: candidate.id,
              epOverride: ep,
              resumeSeconds: resumeAt,
              playOverride: playState,
              commitLine: true,
              reportFailure: false,
              // 补重试必须重新要一次地址：令牌 / 一次性地址可能已经用掉。
              forcePlayInfo: retry > 0,
              force: true,
            );
            watch.stop();
            if (opened && mounted) {
              reason = '';
              break;
            }
            // 失败原因：预检失败 / 真失败（4xx/5xx、DNS、TLS）/ 无进展 / 慢网。
            reason = fxOpenFailReason(
              elapsedMs: watch.elapsedMilliseconds,
              error: _lastOpenError,
            );
            if (!fxShouldFastRetry(
              reason: reason,
              retries: retry,
              tokenLine: tokenLine,
            )) {
              break;
            }
          }
          ok = opened && mounted;
          // PROBE（2026-11-15）：预检日志已经挪到 `onProbeResult` 回调里
          // （预检改成并行后，这里读 `lastProbe` 时它多半还没回来）。
          fxPlayLog(
            fxAutoLineLog(
              attempt: attempt,
              total: total,
              name: candidate.displayName,
              ok: ok,
              reason: reason,
            ),
          );
          if (ok) {
            _line = candidate.id;
            FxLineCooldown.markHealthy(videoId, candidate.displayName);
            widget.onLineFallback?.call(candidate.id);
            // 见 `_switchLine`：父级 rebuild 带来的就是这条线路，不该再触发
            // 一次换线（否则自动换线成功后画面会再闪一次加载）。
            _lastWidgetLine = candidate.id;
            // 自动换线成功 → 必须真的播起来（用户没按过暂停）。
            unawaited(_ensureAutoPlay(lineName: candidate.displayName));
            // 续播点重新 arm：新线路 + 接上的位置立刻落一次盘。
            unawaited(_saveProgress());
            break;
          }
          // 失败：按原因记冷却（真坏 10 分钟 / 抖动 2 分钟），马上试下一条。
          FxLineCooldown.markFailed(
            videoId,
            candidate.displayName,
            reason: reason,
          );
        } catch (e) {
          skip = true;
          _lastOpenError = '$e';
          FxLineCooldown.markFailed(
            videoId,
            candidate.displayName,
            reason: 'bootstrap_exception',
          );
          fxPlayLog(
            fxAutoLineLog(
              attempt: attempt,
              total: total,
              name: candidate.displayName,
              ok: false,
              reason: 'exception',
            ),
          );
        }
        if (skip) continue;
      }
      if (skippedCooling > 0) {
        fxPlayLog(
          'auto line skip=$skippedCooling reason=cooldown '
          'window=${fxLineCooldownWindow.inMinutes}min',
        );
      }
      if (deadSkipped > 0) {
        fxPlayLog('auto line skip=$deadSkipped reason=dead_line');
      }
      // 本轮结论（固定格式，真机 `adb logcat -s FxPlay` 直接 grep auto）：
      //   `[FxPlay] auto done tried=2/11 ok=false dead=1 cooldown=0`
      fxPlayLog(
        'auto done tried=$attempt/$total ok=$ok '
        'dead=$deadSkipped cooldown=$skippedCooling',
      );
    } finally {
      _autoChainBusy = false;
      if (mounted) clearResolving();
    }
    if (!mounted) return ok;
    if (ok) return true;

    // 全部大类都试完：回到第一条线路，给最终提示（或交给外层继续跨源）。
    // GROUP_ORDER：这份提示就是用户定稿的「本片暂无可用线路」
    // （[fxLineNoUsableText]，与详情页最终错误页同一句）。
    _linesExhausted = true;
    _line = lines.first.id;
    _clearFrozenFrame();
    setState(() {
      _loading = false;
      _loadedEp = null;
      _error = true;
      _errorText = fxLineNoUsableText;
      _uiPosition = null;
      _uiDuration = null;
    });
    _showControls();
    if (widget.onAllLinesFailed != null) {
      widget.onAllLinesFailed!();
    } else {
      // 没有外层（独立播放页 / 一起看）：停在可重试的错误层，文案不甩锅。
      showSourceError(fxLineNoUsableText);
    }
    return false;
  }

  /// 起播失败后自己换下一条线路（**只在外层没有失败回调时**使用）。
  ///
  /// 有了 [autoTryAllLines] 之后这条只剩「没有外层」的场景要兜：
  /// 直接把整轮跑完，而不是一条一条等下一轮失败回调。
  void _autoSwitchNextLine() {
    unawaited(autoTryAllLines());
  }

  /// 平台线路（腾讯 / 芒果等）签名失效：重新请求 /api/play 拿新签名地址。
  /// 本地代理会每 90 秒或遇到分片 403/404 时调用；失败返回 null。
  ///
  /// GULU_FIRST_PLAY（2026-11-22）：这条救援链**覆盖 jar 线路**，已确认 ——
  /// `CmsBridge.play` 进来先判 `fxParseJarLineId(line)`，命中就走
  /// `JarSpider.play`（playerContent 现场解析），`fresh` 对它没有额外语义
  /// （jar 分支本来就没有服务端缓存，每次都是新签）。所以咕噜首播卡住时，
  /// 救援链①拿到的一定是**新地址**，和手点「刷新」同一条路。
  /// 唯一补的一处：地址统一过 `absolutePlayUrl`，和首播建候选地址的口径一致
  /// （站内相对路径不补全，救援链重开就会拿相对路径去连，必然失败）。
  Future<String?> _refreshPlatformUrl(String line, int ep) async {
    if (widget.videoId.isEmpty || line.isEmpty) return null;
    try {
      final info = await CmsBridge.play(widget.videoId, ep, line, fresh: true);
      final url = info.url.trim();
      if (url.isEmpty) return null;
      // 旧签名已失效，清掉缓存，避免稍后切回本线路又命中过期地址。
      FxPlayCache.invalidate(widget.videoId, ep, line);
      final abs = CmsBridge.absolutePlayUrl(widget.videoId, url);
      final resolved = abs.isEmpty ? url : abs;
      fxJarLog(
        'refresh line=$line ep=$ep jar=${CmsBridge.isJarLine(line)} '
        'url=$resolved',
        tag: CmsBridge.isJarLine(line) ? fxJarPlayTag : fxPlayTag,
      );
      return resolved;
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

  /// 下一集预载（改动 ⑥）：首帧之后、播放稳定 3 秒触发一次。
  ///
  /// 只把「下一集的清单地址」交给原生：原生用 CacheDataSource 把清单 +
  /// 前 2 个分片写进**播放器同一份**磁盘缓存（只写不读），换集时播放器的
  /// 首批分片请求就是本地命中。三条约束都在原生侧：
  ///   · 播放器 BUFFERING 时预载让路；
  ///   · 换集 / 换线路时取消上一轮（原生 open 会取消）；
  ///   · 失败静默，绝不影响当前播放。
  void _maybePreloadNextNative() {
    if (!mounted || !ExoPlayerEngine.isSupported) return;
    // GULU_FIRST_PLAY：短寿命线路不预载下一集。播放器切集时会**现签**一条
    // 新地址（见 FxPlayCache.isShortLived），这里按旧地址预取的分片永远
    // 命中不了 —— 白跑一次 playerContent 还白占带宽。
    if (FxPlayCache.isShortLived(_line)) return;
    final c = _controller;
    final loaded = _loadedEp;
    if (c == null || loaded == null || loaded != _ep) return;
    // 每集只触发一次：失败也不重试（切集时照常回源，不差这一次）。
    if (_nativePreloadedEp == _ep) return;
    final v = c.value;
    // 首帧 + 正在播 = 播放稳定。
    if (!v.hasRenderedFirstFrame || !v.isPlaying) return;
    // PRELOAD_BUDGET（2026-11-15）：不能刚开始就抢带宽，否则起播那几秒要抢首片。
    // 只有「缓冲水位够高」才预载下一集：
    //   · 已播过 20 秒（起播高峰已过）
    //   · 前方缓冲领先 ≥ 25 秒（当前播放不会被挤）
    //   · 当前不在缓冲中
    if (v.position < const Duration(seconds: 20)) return;
    // 前方缓冲 = 原生上报的 bufferedPosition - position（[FxPlayerValue.bufferedAhead]）。
    // 注意 `buffered` 是「已缓冲的绝对位置」（Duration），不是分片列表。
    if (v.bufferedAhead < const Duration(seconds: 25)) return;
    final next = _nextEpNumber();
    if (next == null) return;
    _nativePreloadedEp = _ep;
    unawaited(() async {
      try {
        // 复用下一集预解析缓存（和 30 秒预热的 _maybePrewarmNext 同一份）。
        final info = await FxPlayCache.resolve(widget.videoId, next, _line);
        if (!mounted || _loading || _error || _ep != loaded) return;
        final url = CmsBridge.absolutePlayUrl(widget.videoId, info.url);
        if (url.isEmpty) return;
        // PRELOAD_ONCE（2026-11-15）：一次性令牌清单（`/hxparse` 的
        // `FY-*` / `/share/` 这类）只能被拉一次，预载会把它烧掉，
        // 真正切集时命中缓存复用同一地址就 403 / 0 分片。和 fx_player
        // 打开时的闸保持一致，这种地址不预载。
        // PRELOAD_ALL（2026-11-15）：用户要求**所有线路**都预载下一集（切集无感）。
        // 以前一次性令牌地址（/hxparse/*）会被跳过，怕预载把令牌烧掉；实测
        // 预载走的是播放器同一份 CacheDataSource，清单和首几个分片都写进磁盘缓存，
        // 真正切集时是本地命中，不会再向源站要一次令牌。
        await ExoPlayerEngine.preloadNextEpisode(url, headers: info.headers);
      } catch (_) {
        // 预载失败静默：不打扰播放，也不弹提示。
      }
    }());
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

  /// 救援链三步全部失败 / 播放中真失败：弹「播放中断」**并继续换线路**。
  ///
  /// CHAIN_FIX（2026-11-15，用户实测）：这里原来是**终点** —— 只 setState 亮
  /// 错误层，既不通知外层（[onSourceFailed]），也不自己开自动轮。于是两种
  /// 最常见的失败都停在错误页上：
  ///   · 清单能拉、分片 404（幻想4K 的过期令牌就是这样）：播放器早就
  ///     initialized，真失败走的是救援链，救援链 ③换线在
  ///     `_autoSwitchLine=false` 下是关着的（AUTO_SWITCH_OFF 2026-11-14）→
  ///     `_fail('播放中断…')` → 到这里就断了，一条线路都没再试；
  ///   · 首帧之后卡死 / 停摆：同上。
  /// 用户口径是「全部线路试完才允许说播不了」，所以错误层只是**过渡画面**：
  /// 接着把失败交给外层（详情页：原线重试 → 全线路轮 → 跨源），
  /// 没有外层（独立播放页 / 一起看）时自己开整轮。
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
    // 这一次失败必须能上报：`_sourceFailNotified` 可能已经被上一轮
    // （showSourceError / 上一次 open）置位，不重置的话降级链会就此锁死。
    _sourceFailNotified = false;
    fxPlayLog(
      'FAIL line=$_lineName ep=$_ep reason=player_fatal '
      '→ ${widget.onSourceFailed == null ? 'auto' : 'outer'} 换线路',
    );
    if (widget.onSourceFailed != null) {
      _notifySourceFailed();
    } else {
      _autoSwitchNextLine();
    }
  }

  /// 本次播放页已经记过的最小集合（避免每帧写一次）。
  final Set<String> _learnedResKeys = <String>{};

  /// 上一次报给外层的真实宽高比（判重用，见 [_reportVideoAspect]）。
  double? _lastStableAspect;

  /// 最近一次 open 的原始错误文本（AUTO_LINE_FULL）。
  ///
  /// 失败原因要分得清 403/404/解析错误（立即判失败）与「8 秒没出首帧」，
  /// 日志和冷却判定都靠它：`reason=http_403` / `no_first_frame`。
  String _lastOpenError = '';

  /// 首帧之后卡顿的进度窗口（连续 10 秒三条全不动才算失败）。
  final FxProgressWindow _stallProgress = FxProgressWindow(
    window: fxStallNoProgressWindow,
  );

  /// 起播进度窗口：判失败 + 界面显示「已下载 xx / 正在缓冲 xx%」都靠它。
  final FxProgressWindow _openProgress = FxProgressWindow(
    window: fxStartupNoProgressWindow,
  );

  /// 当前这次 open 已经等了多久（慢网提示「已等 N 秒」用）。
  Duration _openWaited = Duration.zero;

  /// 起播慢网提示是否该显示（等满 [fxSlowNoticeAfter] 15 秒才亮）。
  ///
  /// 只提示、不让用户做决定：30 秒硬上限到点由内核直接切下一条。
  /// 提示的意义是让用户知道「在等什么」，不是等他点按钮。
  bool _slowNotice = false;

  /// 「本轮已判过卡死」的线路名。
  String _bufferingFailedLine = '';

  /// 上一次写卡顿进度日志的时刻（2 秒一条，别刷屏）。
  int _stallLogAt = 0;

  /// 等这次 open，但按「**连续无进展**」判失败（SLOW_NET 2026-11-15）。
  ///
  /// 这里同时是「慢网由用户决定」的挂点：
  ///   · 有进展就无限等（内核和这里都不按总时长判死）；
  ///   · 连续 8 秒三项全不动 → 抛异常，落到 [_bootstrapSource] 的 catch 换线；
  ///   · 原生 `fatalError`（404 / DNS / TLS / 清单非法 / 0 分片）→ 立刻抛；
  ///   · 慢到 60 秒还在动 → 界面摆出「继续等待 / 换条线路」两个按钮，
  ///     用户点「换条线路」就 complete [abort]，这次等待立刻放手。
  Future<void> _awaitOpenWithProgress(
    FxPlayer controller,
    Future<void> open, {
    required bool hevc,
    Duration? noProgress,
  }) {
    _openProgress.reset();
    _openWaited = Duration.zero;
    _setSlowNotice(false);
    return FxPlayer.awaitOpenProgress<void>(
      controller,
      open,
      progress: _openProgress,
      // 窗口来源三档：调用方按线路类型给的（令牌段 20 秒）→ HEVC 收紧到
      // 8 秒 → 直链默认 8 秒。
      noProgress: noProgress ??
          (hevc ? IqCodecGate.hevcOpenTimeout : _openNoProgressWindow),
      onSample: _onOpenProgressSample,
    );
  }

  /// 起播进度采样回调（每 500ms 一次）：刷新界面 + 决定要不要显示慢网提示。
  ///
  /// 界面必须「看得出在动」：加载层要显示实时网速，不能只有一个转圈；
  /// 等满 15 秒再补一行「网速较慢（已等 N 秒）」。
  void _onOpenProgressSample(
    FxProgressState verdict,
    FxProgressWindow window,
    Duration elapsed,
  ) {
    if (!mounted || !_loading) return;
    _openWaited = elapsed;
    setState(() {});
    final slow =
        elapsed >= fxSlowNoticeAfter && verdict == FxProgressState.slow;
    if (slow == _slowNotice) return;
    _setSlowNotice(slow);
    if (slow) {
      fxPlayLog(
        fxProgressLog(
          bytesDelta: window.bytesDelta,
          bufferedDeltaMs: window.bufferedDeltaMs,
          state: verdict,
          extra: 'notice=${elapsed.inSeconds}s line=$_loadingLineName',
        ),
      );
    }
  }

  /// 显示 / 收起慢网提示（只改状态，不重复 setState）。
  void _setSlowNotice(bool value) {
    if (_slowNotice == value) return;
    _slowNotice = value;
    if (mounted) setState(() {});
  }

  /// 首帧之后卡顿判定（SLOW_NET 2026-11-15：连续 10 秒「三项全不动」才算失败）。
  ///
  /// 老规则是「缓冲满 10 秒 → 判这条线路失败并换下一条」，慢网下必误杀：
  /// 一片 4K 分片本来就十几 MB，缓冲位置按分片整段落盘才推进，这十几秒里
  /// `bufferedPosition` 一动不动，看起来和卡死一模一样。
  ///
  /// 现在和起播用同一个口径（[FxProgressWindow]）：字节数 / 缓冲位置 /
  /// 播放位置任意一项在涨 = 活着，继续等；连续 [fxStallNoProgressWindow]
  /// （10 秒）三项全不动才是真卡死。
  void _watchBuffering(FxPlayerValue v) {
    // 全屏期间由全屏页自己的链路判定（同一个播放器，两边都切会打架）。
    if (_loading || _error || _fullscreenActive) {
      _stallProgress.reset();
      return;
    }
    if (!v.isInitialized ||
        !v.hasRenderedFirstFrame ||
        !v.isBuffering ||
        v.isPlaying) {
      // 位置还在走 / 没在缓冲：管线是通的，窗口清零重新起算。
      _stallProgress.reset();
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _stallProgress.window = fxStallNoProgressWindow;
    _stallProgress.add(
      FxProgressSample(
        atMs: nowMs,
        bytesLoaded: v.bytesLoaded,
        buffered: v.buffered,
        position: v.position,
        isLoading: v.isLoading,
      ),
    );
    final verdict = _stallProgress.state;
    // 2 秒一条进度日志：`[FxPlay] progress bytes=+38KB buffered=+1.2s verdict=slow`。
    if (nowMs - _stallLogAt >= 2000) {
      _stallLogAt = nowMs;
      fxPlayLog(
        fxProgressLog(
          bytesDelta: _stallProgress.bytesDelta,
          bufferedDeltaMs: _stallProgress.bufferedDeltaMs,
          state: verdict,
          extra: 'stage=buffer '
              'stalled=${_stallProgress.stalledFor.inMilliseconds}ms',
        ),
      );
    }
    if (verdict != FxProgressState.stuck) return;
    // 同一条线路只判一次，避免自动轮里重复触发。
    if (_bufferingFailedLine == _lineName) return;
    _bufferingFailedLine = _lineName;
    _stallProgress.reset();
    fxPlayLog(
      fxAutoLineLog(
        attempt: 1,
        total: widget.detail?.lines.length ?? 1,
        name: _lineName,
        ok: false,
        reason: 'stuck_no_progress',
      ),
    );
    FxLineCooldown.markFailed(
      widget.videoId,
      _lineName,
      reason: 'stuck_no_progress',
    );
    // 立刻切下一条（不等用户，也不弹错误提示）。
    unawaited(autoTryAllLines());
  }

  /// 每集最后一次「位置可信」的进度（FX_FALLBACK）。
  ///
  /// 播放器报错 / 换源后 `value.position` 会归零或乱跳，拿它当换源起点就会
  /// 「回到片头」。按集号分别记一笔，降级时优先用它。
  final Map<int, Duration> _goodPositions = <int, Duration>{};

  void _onVideoValue() {
    final c = _controller;
    if (c == null || !mounted) return;
    // BUFFER_WATCH（2026-11-15）：首帧出了但一直缓冲（播放位置不动）
    // 超过 10 秒就判这条线路失败，立刻换下一条 —— 用户定稿的规则，
    // 不等 FxPlayer 的 30 秒停摆判定。
    _watchBuffering(c.value);
    // 位置可信时才记（换成另一条线路失败时，这里保留的还是上一次正常的位置）。
    final live = c.value;
    if (live.isInitialized && !live.hasError && live.position > Duration.zero) {
      final prev = _goodPositions[_ep];
      if (prev == null || live.position > prev) {
        _goodPositions[_ep] = live.position;
      }
    }
    // ASPECT_REAL：真实宽高一到就把比例报给页面（放在所有早退之前 ——
    // 全屏、loading、error 时页面容器同样要按新比例定高，否则退出全屏 /
    // 加载结束时容器会「跳」一下）。
    _reportVideoAspect(c);
    // 新流首帧就绪（宽高出现）后淡出切换快照；loading / error 期间不动。
    if (!_fullscreenActive) _maybeFadeFrozenFrame();
    // NEXT_EPISODE_PRELOAD（改动 ⑥）：首帧 + 稳定播放 3 秒触发一次。
    // 放在 loading / 全屏的早退**之前**：全屏观影时也要把下一集预载好。
    if (!_loading && !_error) _maybePreloadNextNative();
    // RES_LEARNED（2026-11-15）：播放器拿到真实宽高就记一条
    // `sourceKey|线路名|vodId → 实际高度`，下次搜索排序直接用真实分辨率
    // 覆盖线路名推断（第三层）。
    _rememberRealResolution(c.value);
    // IQ_CODEC：首帧之后用通知条说明「实际用的是哪种编码」。
    if (!_fullscreenActive) _maybeNotifyIqCodec(c.value);
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

  /// IQ_CODEC（2026-11-15）：爱奇艺线路首帧后提示一次实际编码。
  ///
  /// 为什么要有它：设备能力探测 + 失败降级都在后台悄悄发生，用户只看到
  /// 「画质好像不一样」。这里在首帧（不是 open 成功，那时还没有视频轨）
  /// 之后把真实编码 / 分辨率和一句人话贴出来：
  ///   · `爱奇艺：HEVC 1920x1080` —— 硬解生效；
  ///   · `爱奇艺：HEVC 不可用，已降级 H.264 896x504` —— 走的是 AVC。
  /// 同一部剧同一条线路只提示一次；非爱奇艺线路一声不响。
  void _maybeNotifyIqCodec(FxPlayerValue v) {
    if (!mounted || !v.hasRenderedFirstFrame) return;
    final key = '${widget.videoId}|$_line';
    if (_codecNoticeKey == key) return;
    // 「请求参数」和「响应头」都空 = 这条线路跟爱奇艺没关系，一声不响。
    // （响应头 X-Iq-Codec 在清单抓取时才到，实测编码要等视频轨，所以
    //  只要两者之一有值就提示 —— 那时候信息已经够说清了。）
    if (v.codecHint.isEmpty && v.iqCodec.isEmpty) return;
    _codecNoticeKey = key;
    final text = IqCodecGate.notice(
      degraded: _iqDegraded,
      mime: v.videoCodec,
      headerCodec: v.iqCodec,
      headerQuality: v.iqQuality,
      width: v.videoWidth ?? 0,
      height: v.videoHeight ?? 0,
    );
    fxPlayLog(
      'iqiyi notice text=$text requested=${_iqHevc ? 'hevc' : 'avc'} '
      'degraded=$_iqDegraded',
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 把当前视频的真实宽高比报给外层（页面按它算播放区高度）。
  ///
  /// 只在「拿到真实宽高」且「比例真的变了」时回调：
  /// - 拿不到（切集 / 换线刚开始时报 0×0）直接跳过，外层沿用上一次的比例；
  /// - 同一个尺寸会被 `onVideoSizeChanged` / 每秒的状态回调反复报，不判重
  ///   就会一直 setState 整页。
  void _reportVideoAspect(FxPlayer c) {
    final cb = widget.onVideoAspect;
    if (cb == null) return;
    final v = c.value;
    final ratio = fxVideoAspectOf(v.width, v.height) ??
        fxVideoAspectOf(v.videoWidth, v.videoHeight);
    if (ratio == null || !ratio.isFinite || ratio <= 0) return;
    final last = _lastStableAspect;
    if (last != null && (last - ratio).abs() < 0.001) return;
    _lastStableAspect = ratio;
    cb(ratio);
  }

  /// 记一次真实分辨率（同一集只记一次，尺寸没变就不重复写盘）。
  void _rememberRealResolution(FxPlayerValue v) {
    // FxPlayerValue.width / height 是可空的（还没拿到 size 时为 null）。
    final width = v.width;
    final height = v.height;
    if (width == null || height == null || width <= 0 || height <= 0) return;
    final line = _line;
    if (line.isEmpty) return;
    final key = '${widget.videoId}|$line|$width|$height';
    if (_learnedResKeys.contains(key)) return;
    _learnedResKeys.add(key);
    final id = widget.videoId;
    final marked = id.startsWith('@src:');
    final source = marked ? id.substring(5).split('::').first : '';
    final vodId = marked ? id.split('::').last : id;
    unawaited(LearnedResolution.remember(
      sourceKey: source,
      lineName: line,
      vodId: vodId,
      width: width,
      height: height,
    ));
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

  /// 系统媒体控件（通知栏 / 锁屏 / 耳机线控 / 车机）的上一集 / 下一集。
  ///
  /// MEDIA_SESSION（2026-11-15）：原生只把「用户按了、方向是啥」抛过来，
  /// 真正的切集在这里做 —— 走的还是页面上那条 `_switchEpisode`，
  /// 和用户自己点「下一集」完全同一条路径（存进度、换线路、续播位置、
  /// 上报 onEpChange 全都在里面）。
  void _handleMediaStep(int delta) {
    if (!mounted) return;
    final next = delta > 0 ? _nextEpNumber() : _prevEpNumber();
    if (next == null) {
      // 已经是第一集 / 最后一集：保持当前画面，不动播放。
      fxPlayLog('媒体按键：没有${delta > 0 ? "下一集" : "上一集"}了');
      return;
    }
    fxPlayLog('媒体按键：切到第$next集');
    unawaited(_switchEpisode(next));
  }

  /// 第 [ep] 集有没有相邻集（[delta] = -1 上一集 / +1 下一集）。
  ///
  /// MEDIA_SESSION（2026-11-15）：系统媒体控件是**按可用性**渲染上一集 /
  /// 下一集按钮的 —— 最后一集上还挂一个按了没反应的「下一集」，比没有更糟。
  /// 口径和 [_nextEpNumber] / [_prevEpNumber] 保持一致：有明确集数表就按表，
  /// 只有总集数就按总集数算（总集数为 0 = 单片，两个方向都没有）。
  bool _hasEpStep(int ep, int delta) =>
      fxHasAdjacentEpisode(_episodeList, ep, delta, _episodeCount);

  /// 上一集（和 [_nextEpNumber] 同一套口径：明确集数表优先，否则按总集数算）。
  int? _prevEpNumber() =>
      fxAdjacentEpisode(_episodeList, _ep, -1, _episodeCount);

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
  ///
  /// OPEN_GATE（2026-11-15）：这个方法是「一直转圈」的直接修复点。
  ///
  /// 失败上报（[onSourceFailed]）是从 [_bootstrapSource] **内部**发出的，
  /// 那一刻 `_opening` 还挂着这次（注定失败的）Future。原来的重试没有绕过去重，
  /// `_bootstrap` 于是把同一个 Future 原样还回来：
  ///   · 新的 open 一次都没发出去；
  ///   · 旧那次随后判定失败，但它已经因为 token 推进而「静默返回」；
  /// 两条路都不写状态，`_loading` 就永远停在 true —— 用户看到的就是
  /// 「正在加载 幻想爱奇艺 · 第01集」一动不动，既不出画也不报错。
  ///
  /// 现在重试带 `force: true`（真发一次，代价最多一次接口），并且在这次
  /// 重试自己失败时**收尾**：亮明确错误 + 通知外层换线路，绝不留悬空 loading。
  Future<void> reload() async {
    // RELOAD_DEFER（GULU_FIRST_PLAY 2026-11-22）：换线正在跑时**不许当场
    // 放弃** —— 外层 `_reportLineIssue` 在调用前就已经把 `_retriedLine` 记成
    // 「这条试过了」，这里直接 return 就等于把那次原线重试白白烧掉，首播失败
    // 再也拿不到一次 force 重解析。改成排队，换线收尾时补跑。
    if (_switchingLine) {
      _pendingReload = true;
      return;
    }
    _pendingReload = false;
    // AUTO_LINE_FULL：上一次已经把全部线路试完 —— 点「重试」等于重新开始：
    // 从第一条线路重新轮一轮，并且让外层重置降级状态（这次可以再跨源找一次）。
    if (_linesExhausted) {
      _linesExhausted = false;
      // 用户点了「重试」= 重新开始：清掉这部剧的冷却记录，从第一条线路再试。
      FxLineCooldown.clearFor(widget.videoId);
      widget.onRetryAllLines?.call();
      if (mounted) {
        setState(() {
          _loading = true;
          _error = false;
          _errorText = '';
        });
      }
      // 外层重置完会把第一条线路设回来；这里直接跑整轮，用户不用再点。
      final ok = await autoTryAllLines(restart: true);
      if (ok || !mounted) return;
      return;
    }
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
    final ok = await _bootstrap(
      seekToSaved: true,
      saveOld: false,
      forcePlayInfo: true,
      playOverride: !_covered && _shouldContinuePlayback(),
      force: true,
    );
    // 这次重试自己也没成：必须有明确结果，绝不留悬空 loading。
    //
    // 两个前置判断都必要：
    //   · `_switchingLine`：外层已经决定换线路了（失败回调里同步开始的），
    //     换线自己会收尾，这里再亮错误层会和它抢状态；
    //   · `!_loading`：本次失败已经写过了（[_bootstrapSource] 的失败分支），
    //     或者被更新的请求取代。
    if (!mounted || ok || !_loading || _switchingLine) return;
    fxPlayLog('FAIL line=${_loadingLineName} ep=$_ep reason=retry-failed');
    _clearFrozenFrame();
    setState(() {
      _loading = false;
      _suppressLoading = false;
      _error = true;
      _errorText = '线路不可用，请重试或切换下方线路';
    });
    // 不再重复通知外层：本次失败在 [_bootstrapSource] 里已经报过一次
    // （[_sourceFailNotified] 守着），这里再报会让详情页多换一次线路。
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

  /// PLATFORM_PENDING：用户点了一条还在解析的平台线路，画面上给个明确提示
  /// （「正在解析 幻想爱奇艺」），原线路继续播，解析完再切。
  void showResolving(String text) {
    if (!mounted || text.isEmpty) return;
    setState(() => _resolvingText = text);
  }

  /// CHAIN_WATCHDOG（2026-11-15）：外层判断降级链有没有真的跑起来的两个信号。
  ///
  /// 「原线重试」这一步有多个早退（正在切线路 / 已试完全部线路），任何一条
  /// 都会让重试变成「什么都没发生」：界面停在错误页，自动换线永远不开始。
  /// 外层用这两个 getter 判断「要不要自己把整轮开起来」：
  ///   · [showingError] 停在错误层 = 这一轮确实没救了；
  ///   · [autoChainRunning] 已经在轮线路 = 别再开一轮打断它。
  bool get showingError => _error;

  bool get autoChainRunning => _autoChainBusy;

  /// 换源 / 换线路降级前抓一份「播放现场」：集号 + 位置 + 播放状态。
  ///
  /// 位置的可信顺序：播放器当前进度（正常推进时）→ 本集最后一次正常位置
  /// （报错 / 换源把进度清零了）→ 切换期间锁定的 UI 进度。绝不直接读
  /// `value.position` 就交出去 —— 播放器出错后它常常是 0。
  FxPlaybackSnapshot playbackSnapshot() {
    final v = _controller?.value;
    final trusted = v != null && v.isInitialized && !v.hasError;
    var pos = trusted ? v.position : Duration.zero;
    if (!trusted || pos <= Duration.zero) {
      final good = _goodPositions[_ep];
      if (good != null && good > pos) pos = good;
    }
    final ui = _uiPosition;
    if (ui != null && ui > pos) pos = ui;
    // AUTO_RESUME：这份快照的 `playing` 只表示**用户意图**，不是播放器现状。
    // 拿 `isPlaying` 当证据时，换线前那句 `_controller?.pause()`（还有缓冲中
    // 必然是 false 的 isPlaying）会被读成「用户暂停了」，新线路就停在暂停。
    final playing = fxShouldPlayAfterSwitch(userPaused: _userPaused);
    return FxPlaybackSnapshot(
      ep: _ep,
      position: pos,
      playing: playing,
      lineId: _line,
    );
  }

  /// 解析结束（成功或失败）都收起提示；失败时由详情页弹 toast。
  void clearResolving() {
    if (!mounted || _resolvingText.isEmpty) return;
    setState(() => _resolvingText = '');
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
    // 以播放器真实状态为准：交给内核切换，按钮图标随后续
    // player.stream.playing 事件刷新，不用本地布尔抢先改状态。
    // AUTO_RESUME：但**意图**要记下来 —— 只有这里（用户自己点的）才算暂停，
    // 之后自动换线 / 切集才不会把用户的暂停当成「系统暂停」又播起来。
    _userPaused = c.value.isPlaying;
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
    // 先把屏幕方向切成「这一集该有的方向」，再推页面：让系统旋转动画跑在
    // 淡入之前，新页面第一帧就已经是正确布局，不会先按竖屏铺一遍再重排
    // （PlatformView 重排会闪一下）。不 await——淡入不该等旋转完成。
    //
    // 方向按「视频自身分辨率」算：1080×1920 的竖屏短剧锁竖屏，
    // 常规横屏片锁横屏；全屏页进去后会再做一次 300ms 防抖校正。
    final size = c.value;
    final target = fxResolvePlayOrientation(
      width: (size.width ?? 0) > 0 ? size.width : size.videoWidth,
      height: (size.height ?? 0) > 0 ? size.height : size.videoHeight,
    );
    unawaited(ScreenOrientation.applyPlayback(portraitMode: target.isPortrait));
    setState(() => _fullscreenActive = true);

    FullPlayerResult? result;
    try {
      result = await Navigator.of(context).push<FullPlayerResult>(
        // 进全屏用「淡入 + 放大 2%」而不是横向推：
        // 视频画面横向滑动会让人以为画面在动。
        FxFullscreenRoute<FullPlayerResult>(
          builder: (context) => FullPlayerPage(
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
      // FX_FALLBACK：全屏里已经播不了，回竖屏必须继续走降级链
      // （原线重试 → 换线路 → 跨源找同名），不能停在这一屏不动。
      _notifySourceFailed();
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
                    // 真的在播就别挂「缓冲中」：音频已经出来、位置在走，
                    // 说明管线是通的，此时盖一层缓冲圆环只是骗用户。
                    if (!v.isInitialized || !v.isBuffering || v.isPlaying) {
                      return const SizedBox.shrink();
                    }
                    // FIRST_FRAME：首帧还没上屏时由下面的加载层负责，
                    // 这里再叠一个「缓冲中」只会和它打架。
                    if (!v.hasRenderedFirstFrame) {
                      return const SizedBox.shrink();
                    }
                    // BUFFER_UI（2026-11-15）：首帧之后缓冲层只给转圈 + 实时
                    // 网速，不再画百分比（buffered/duration 和「还要等多久」
                    // 没关系，缓到 42% 可能还要十秒，用户会以为是进度条假了）。
                    return FxLoadingOverlay(
                      title: '缓冲中…',
                      speedText: fxSpeedLabel(_liveSpeed(v)),
                      dim: false,
                      compact: true,
                    );
                  },
                ),
              ),
            // 加载层（FIRST_FRAME）：只在「首帧还没上屏」时显示，
            // hasRenderedFirstFrame 变 true 才收起。
            //
            // 以前这里是 `if (_loading) _buildLoading()`，而 `_loading` 在
            // open 返回（拿到尺寸/时长）时就置 false —— 那时首帧还没渲染，
            // 于是层一收、画面还是黑的，用户要再等几百毫秒。
            if (!_error && !_suppressLoading && c != null)
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: c,
                  builder: (context, _) {
                    final waitingFirst = !c.value.hasRenderedFirstFrame;
                    if (!_loading && !waitingFirst) {
                      return const SizedBox.shrink();
                    }
                    return _buildLoading();
                  },
                ),
              ),
            // 播放器实例还没建出来（首个 open 之前）：只有状态位可看。
            if (c == null && _loading && !_error && !_suppressLoading)
              Positioned.fill(child: _buildLoading()),
            // PLATFORM_PENDING：平台线现场解析提示（盖在画面之上、控件之下）。
            if (_resolvingText.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: .55),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white70,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _resolvingText,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            // 控件层压在 loading / 缓冲之上：切集 8s 窗口里也能退出全屏。
            // 只按控件显隐禁用指针，不因 loading 整层失效。
            if (_controls && !_error) _buildControls(c),
            // 播放诊断浮层：播放器区域内右上角，只在用户打开时存在。
            //
            // 放在栈尾：起播阶段正要看它，不能被加载层盖住。
            // IgnorePointer 包住：它是纯展示，不能吃掉单击显隐 / 双击暂停
            // 这些画面手势（诊断层的存在不能改变任何播放交互）。
            if (_showDiagnostics && c != null)
              Positioned(
                top: 44,
                right: 8,
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    // 跟着播放器重建：首帧耗时 / 缓冲 / 丢帧都由它通知。
                    animation: c,
                    builder: (context, _) => PlaybackDiagnosticsPanel(
                      data: PlaybackDiagnosticsData.fromPlayer(c.value),
                    ),
                  ),
                ),
              ),
            if (_error) _buildError(),
          ],
        ),
      ),
    );
  }

  /// 当前实时网速（字节/秒）：优先原生按块统计的真实速率。
  ///
  /// 老原生包没有 `bytesLoadedPerSec` 时退回 `bytesPerSecond`（旧估算值），
  /// 再拿不到就是 0 —— 界面显示「0 KB/s」，不编数字。
  double _liveSpeed(FxPlayerValue v) {
    if (v.bytesLoadedPerSec > 0) return v.bytesLoadedPerSec.toDouble();
    return v.bytesPerSecond;
  }

  /// 加载层内容（不带定位）：由调用方决定挂在哪一层 Stack 上。
  Widget _buildLoading() {
    final title = fxLoadingLineText(_requestEp, _loadingLineName);
    // 只显示本次 open 的新播放器缓存进度；新实例还没建好时用不确定圆环，
    // 不能拿旧 controller 的百分比冒充新集进度。
    //
    // FIRST_FRAME：open 返回后 `_loadingPlayer` 就被清掉了，但加载层还要
    // 挂到首帧上屏，这段时间用当前 controller（此时它一定还没出首帧）。
    final c = _loadingPlayer ??
        (_controller?.value.hasRenderedFirstFrame == false
            ? _controller
            : null);
    if (c == null) {
      return FxLoadingOverlay(
        title: title,
        speedText: fxSpeedLabel(0),
        attemptText: _resolvingText,
        noteText: _slowNotice ? fxSlowNoticeText(_openWaited.inSeconds) : '',
        compact: true,
      );
    }
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) {
        final v = c.value;
        return FxLoadingOverlay(
          title: title,
          // 实时网速：原生按块统计的真实字节速率（0 就写「0 KB/s」）。
          speedText: fxSpeedLabel(_liveSpeed(v)),
          // 「正在尝试其他线路（2/11）」放在网速下面。
          attemptText: _resolvingText,
          // 15 秒起：「网速较慢（已等 18 秒）」——让用户知道在等什么。
          noteText: _slowNotice ? fxSlowNoticeText(_openWaited.inSeconds) : '',
          compact: true,
        );
      },
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

  /* ---------------------------------------------------------- 播放诊断浮层 */

  /// 读持久化的诊断开关（默认关）。
  Future<void> _restoreDiagnostics() async {
    final settings = AppSettings.instance;
    await settings.init();
    if (!mounted) return;
    if (settings.playbackDiagnostics == _showDiagnostics) return;
    setState(() => _showDiagnostics = settings.playbackDiagnostics);
  }

  /// 给外层（[PlayerPage] 的片名行）用的开关：长按片名切换诊断浮层。
  ///
  /// 状态在播放器这一层（它有 controller / 有分段耗时），外层只管调一下。
  void togglePlaybackDiagnostics() {
    _setDiagnostics(!_showDiagnostics);
  }

  void _setDiagnostics(bool value) {
    if (_showDiagnostics == value) return;
    setState(() => _showDiagnostics = value);
    // 写回设置：exit 再进、竖屏 ↔ 全屏都保持用户的选择。
    unawaited(AppSettings.instance.setPlaybackDiagnostics(value));
  }

  /* ---------------------------------------------------------- 播放设置面板 */

  /// 竖屏顶栏「⋯」：与全屏共用同一个「播放设置」面板。
  /// 画面比例 / 镜像模式在面板里改全局设置，立即生效、不重载视频。
  Future<void> _openMorePanel() async {
    _hideTimer?.cancel();
    if (mounted) setState(() => _controls = true);
    // 面板里可能改了「播放诊断」：关掉面板后按实际情况补一句提示
    // （SnackBar 放面板下面会被模态层挡住）。
    final diagnosticsBefore = _showDiagnostics;
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
      diagnosticsOn: _showDiagnostics,
      onDiagnosticsChanged: _setDiagnostics,
    );
    if (!mounted) return;
    if (diagnosticsBefore != _showDiagnostics) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_showDiagnostics ? '播放诊断已开启' : '播放诊断已关闭'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
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
                  icon: Icons.settings_rounded,
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

  /// 内嵌播放器的句柄：片名行长按要切它的诊断浮层。
  ///
  /// 为什么用 GlobalKey：诊断数据（分段耗时 / 丢帧 / 缓冲）全在
  /// [PlayerViewState] 里，页面这一层没有播放器，只能通过它转一手 ——
  /// 比把 controller 提到页面再往下传改动小得多。
  final GlobalKey<PlayerViewState> _playerKey = GlobalKey<PlayerViewState>();

  /// 当前播放画面的真实宽高比（ASPECT_REAL 2026-11-15）。
  ///
  /// 播放区的高度按它算，不再写死 16:9 —— 不然 1920×800 的宽银幕片上下
  /// 留出多余黑边、1080×1920 的竖屏短剧被挤成一条，4:3 老片两头都被裁。
  /// 拿不到时退回 [kFxFallbackVideoAspect]（16:9，老行为，保证有画面）。
  ///
  /// 只接受真实值：切集 / 换线期间播放器会短暂报不出宽高，这里**不**退回
  /// 16:9（那会让容器跳一下），沿用上一次的比例直到新值到。
  double _videoAspect = kFxFallbackVideoAspect;

  @override
  void initState() {
    super.initState();
    _ep = widget.ep;
    _load();
  }

  /// 内嵌播放器上报的真实比例：变了才重建（判定见 [fxVideoAspectOf]）。
  void _onVideoAspect(double ratio) {
    if (!mounted) return;
    if (!ratio.isFinite || ratio <= 0) return;
    if ((ratio - _videoAspect).abs() < 0.001) return;
    setState(() => _videoAspect = ratio);
  }

  /// 播放区：宽度撑满，高度跟视频真实比例走。
  ///
  /// 比 16:9 更宽的片子容器跟着收窄（不留上下黑边），4:3 / 竖屏片停在
  /// 16:9 的高度（画面铺满高度、左右留黑），规则在
  /// [fxPlayerStageHeight] 里，单测钉住。
  Widget _buildStage(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SizedBox(
          height: fxPlayerStageHeight(
            width: constraints.maxWidth,
            videoRatio: _videoAspect,
            // 与详情页同一条规则（STAGE_FULLWIDTH）：宽度撑满、比例按视频，
            // 竖屏短剧最多占 62% 屏高。
            maxHeight: MediaQuery.sizeOf(context).height * .62,
          ),
          child: PlayerView(
            key: _playerKey,
            videoId: widget.videoId,
            ep: _ep,
            line: widget.line,
            detail: _detail,
            onEpChange: _onEpChanged,
            onChangeLine: () => Navigator.of(context).maybePop(),
            onVideoAspect: _onVideoAspect,
          ),
        );
      },
    );
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final detail = await CmsBridge.detail(widget.videoId);
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
            _buildStage(context),
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
                    // 片名 + 元信息整行可长按：切换播放诊断浮层。
                    //
                    // 为什么挂这里：竖屏画面里没有空位再加按钮，而「片名」
                    // 是用户本来就会看的位置；长按不抢点击语义（这一行本来
                    // 也没有点击行为）。
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onLongPress: () =>
                          _playerKey.currentState?.togglePlaybackDiagnostics(),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
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
                        ],
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

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../auth.dart';
import '../fx_globals.dart';
import '../models.dart';
import '../services/cms_bridge.dart';
import '../services/fx_player.dart';
import '../theme.dart';
import '../widgets/player_theme.dart';
import '../widgets/together_chat.dart';
import '../widgets/together_client.dart';
import '../widgets/together_fullscreen.dart';
import '../widgets/together_picker.dart';
import '../widgets/together_room.dart';
import '../widgets/together_sheets.dart';
import '../widgets/together_sync.dart';
import '../widgets/together_ui.dart';

/* ========================================================================== */
/*  一起看                                                                     */
/*                                                                            */
/*  · 入口/建房/加入；房间内服务器权威同步（房主写 state/seek/episode）          */
/*  · 竖屏房间 UI 在 widgets/together_room.dart，全屏在 together_fullscreen.dart */
/*  · 切后台不断 WS / 不暂停播放，回前台 refreshRoom 后再对齐                   */
/*  · 退出房间 pause → stop → dispose，并把房间进度写回本地进度                 */
/* ========================================================================== */

enum _TogetherStage { entry, entering, room }

/// 退出房间时回传给详情页的快照。
///
/// 房间内可能切集 / 换剧 / 换线，详情页不能拿进房前的旧集恢复播放，
/// 必须按这份快照刷新当前集与线路后再 seek。
class TogetherExitResult {
  const TogetherExitResult({
    required this.videoId,
    required this.ep,
    required this.lineId,
    required this.position,
    required this.playing,
    required this.kind,
  });

  final String videoId;
  final int ep;
  final String lineId;

  /// 房间当前播放位置（秒）。
  final double position;

  /// 退出时是否处于播放态；false 时详情页恢复后保持暂停。
  final bool playing;

  /// `live` = 直播房；其余为普通剧集房。
  final String kind;

  bool get isLive => kind == 'live';
}

class TogetherPage extends StatefulWidget {
  const TogetherPage({
    super.key,
    this.videoId,
    this.ep = 1,
    this.line = '',
    this.position = 0,
    this.playing = false,
    this.liveChannel,
    this.liveLineId = '',
  });

  /// 直播频道：直接建一个 `kind:"live"` 的房间。
  const TogetherPage.live({
    super.key,
    required this.liveChannel,
    this.liveLineId = '',
  })  : videoId = null,
        ep = 1,
        line = '',
        position = 0,
        playing = true;

  /// 从详情页进入时直接创建房间；为空时显示一起看入口。
  final String? videoId;
  final int ep;

  /// 建房沿用详情页当前线路与进度，不再默认第一条线路。
  final String line;
  final double position;
  final bool playing;

  /// 直播一起看：频道 + 房主当前线路。
  final LiveChannel? liveChannel;
  final String liveLineId;

  @override
  State<TogetherPage> createState() => _TogetherPageState();
}

class _TogetherPageState extends State<TogetherPage>
    with WidgetsBindingObserver {
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

  late final TogetherClient _client;
  final TextEditingController _joinCtrl = TextEditingController();

  _TogetherStage _stage = _TogetherStage.entry;
  bool _entered = false;
  bool _enteringAsHost = false;
  bool _wantsRoom = false;
  bool _exiting = false;
  bool _leaving = false;
  bool _fullscreen = false;

  /// token 已过期：只处理一次，停止重连并引导重新登录。
  bool _authExpired = false;

  bool _online = false;
  bool _isHost = false;
  bool _foreground = true;
  bool _downReported = false;
  bool _needsHostResync = false;

  String _myId = '';
  String _stageText = '';
  String _roomCode = '';
  String _roomTitle = '';

  TogetherRoomState? _remote;
  final TogetherSeqGate _seqGate = TogetherSeqGate();

  // A socket hello is not a fresh room snapshot. Keep periodic corrections
  // suspended after disconnect/resume until room_state has arrived again.
  bool _awaitingRoomState = false;

  /// 等待房间状态的兜底定时器：room_state 迟迟不来时不能让画面一直转圈。
  Timer? _awaitingStateTimer;

  /// 成员硬 seek 错峰：房主拖动后 N 个成员会在同一帧收到同一份 room_state，
  /// 同时硬 seek 就会同时抢服务端 `/api/seg` 的首片中转槽位，抢不到的人
  /// 被降级成直连。这里按「自己在成员列表里的序号」把 seek 延后
  /// i * 200ms（上限 2 秒），错峰只作用于硬 seek，倍速微调照旧即时。
  Timer? _staggerSeekTimer;

  bool get _waitingStaggerSeek => _staggerSeekTimer != null;

  bool get _canCorrectMember => togetherCanCorrectMember(
        online: _online,
        connected: _client.connected,
        clockSynced: _client.synced,
        // 错峰等待期间也复用同一个 gate：心跳到达不能把这段等待顶掉，
        // 否则周期纠偏会先跳一次，等于错峰白做。
        awaitingRoomState: _awaitingRoomState || _waitingStaggerSeek,
      );

  /// 应用房主操作后的短暂静默期：先让 play / pause / seek 落位，再开始纠偏。
  int _applyHoldUntil = 0;

  /// 硬 seek 后 2 秒内不再纠偏（防抖）。
  int _seekGuardUntil = 0;

  /// 每次硬 seek 递增，旧 seek 的完成回调不再覆盖新状态。
  int _seekToken = 0;
  bool _seeking = false;

  /// 缓冲 / 卡顿时不主动 seek，恢复后只按 drift 处理一次。
  bool _bufferingHold = false;
  bool _stalled = false;
  int _lastProgressPositionMs = 0;
  int _lastProgressAt = 0;

  /// 内核精度不足以微调倍速时，10 秒内不再尝试（等下一次同步）。
  int _microRateRetryAt = 0;
  bool _microRateUnsupported = false;

  /// 最近一次下发给内核的倍速，避免每 500ms 重复 setRate。
  double _lastRequestedRate = 1.0;

  /// 房主停滞（缓冲）：position 停住而房间时钟照走，期间冻结期望进度。
  bool _authStall = false;
  int _authStallAt = 0;

  /// 成员原地保持：房主卡住且本地已领先太多时先暂停，等房主追上再恢复。
  bool _stallHold = false;
  int _stallHoldAt = 0;

  /// 成员持续领先的起点：超过 togetherBackSeekPersistMs 才允许往回跳。
  int _aheadSince = 0;

  /// 上次处理过的时钟校准版本（offset 台阶先吸收、不立刻 seek）。
  int _lastClockVersion = 0;

  /// 房主端：最近一次广播出去的权威 position / 时间 / 状态。
  /// 正常播放时不让它因读数抖动往回走，成员才能稳定区分「房主卡住」
  /// 和「房主在拖进度」。
  double _hostReportedPos = -1;
  int _hostReportedAt = 0;
  String _hostReportedState = '';

  /// 下一次上报强制用原始读数（房主主动 seek / 换集之后）。
  bool _hostReportFresh = false;

  /// 房主读数持续回退的起点：超过 togetherHostBacktrackGraceMs 才如实上报。
  int _hostBacktrackAt = 0;

  /// 房主缓冲上报节流：缓冲期间每秒报一次停住的 position（心跳 9s 太慢）。
  bool _hostBuffering = false;
  int _hostBufferReportAt = 0;

  List<TogetherMember> _members = const <TogetherMember>[];

  /// 成员实时列表：成员弹层打开期间也跟着进出（join / leave）即时更新。
  final ValueNotifier<List<TogetherMember>> _membersLive =
      ValueNotifier<List<TogetherMember>>(const <TogetherMember>[]);

  final List<TogetherChatMessage> _messages = <TogetherChatMessage>[];
  final ValueNotifier<List<TogetherChatMessage>> _chat =
      ValueNotifier<List<TogetherChatMessage>>(const <TogetherChatMessage>[]);

  String _videoId = '';
  int _ep = 1;
  String _videoLine = '';
  String _videoTitle = '';
  String _videoCover = '';

  /// 直播房：频道与当前线路；普通房为 null。
  LiveChannel? _liveChannel;
  String _liveLineId = '';
  int _liveLastPosMs = -1;
  int _liveLastProgressAt = 0;
  int _liveReloadAt = 0;
  bool _liveJumping = false;

  /// 无感救援链第③步已试过的线路 id：每轮拉流重置，每条只换一次。
  final List<String> _liveRescueTried = <String>[];

  /// 直播房期望的播放状态：建房默认在播；房主每次 play / pause 立即更新
  /// 并广播，成员则以最新的 room_state 为准，不自行猜成「在播」。
  bool _livePlaying = true;

  bool get _isLive => _liveChannel != null;

  List<Episode> _episodes = const <Episode>[];
  List<LineInfo> _lines = const <LineInfo>[];
  String _detailVideoId = '';
  Future<void>? _detailPending;
  PlayInfo? _playInfo;
  String? _qualityKey;

  String _loadedKey = '';
  String _loadingKey = '';
  bool _videoLoading = false;
  String _videoError = '';
  int _videoSeq = 0;
  bool _endedSent = false;
  FxPlayer? _controller;
  double _hostRate = 1.0;
  double? _resumePos;
  bool _resumePlaying = false;

  /// 切剧 / 切集 / 换线路前抓下的最后一帧：新流首帧就绪前盖住黑屏，
  /// 首帧出来后淡出，做到不黑屏闪。
  final GlobalKey _videoBoundaryKey = GlobalKey();
  ui.Image? _frozenFrame;
  bool _frozenFrameOpaque = false;
  Timer? _frozenFadeTimer;
  Timer? _frozenFallbackTimer;

  /// 直播首帧等待上限：open 成功但 10 秒仍没有画面时显示「加载失败，重试」，
  /// 和全屏播放页的兜底一致。
  static const Duration _liveFirstFrameTimeout = Duration(seconds: 10);
  Timer? _liveFirstFrameTimer;

  /// 回前台只重建 Video 输出层（换 key），播放器实例与进度不动。
  int _videoEpoch = 0;

  final ValueNotifier<double> _position = ValueNotifier<double>(0);

  Timer? _ticker;
  Timer? _heartbeat;

  /// 房主进度推送间隔（毫秒）。
  ///
  /// 之前房主只在 9 秒心跳和播放/暂停事件时上报进度，成员只能靠本地时钟
  /// 外推 —— 网络一抖就偏，表现出来就是「成员慢半拍 / 一直原地循环」。
  /// 咕噜咕噜把这件事做成服务器下发的 `room_play_push_interval_ms`，
  /// 这里同样做成可调：默认 1.5 秒（够平滑，又不至于把房间消息刷爆）。
  int _pushIntervalMs = 1500;

  /// 上一次房主进度推送的时间戳（毫秒）。
  int _lastHostPushAt = 0;

  /// 推送间隔的自适应倍率：弱网时 >1（推得慢些），良好时 =1。
  ///
  /// 由 [_updatePushIntervalFactor] 根据「成员纠偏频率」估算：
  /// 纠偏越频繁说明越不同步，可能是网络抖，也可能是推送太少 ——
  /// 这里选择拉长间隔而不是缩短，因为弱网下高频推送只会把消息堆在
  /// WebSocket 里，成员收到的还是过期的位置，反而更糟。
  double _pushIntervalFactor = 1;

  /// 根据最近的纠偏次数调整推送倍率（每 10 秒评估一次）。
  void _updatePushIntervalFactor() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _pushFactorAt < 10000) return;
    final corrections = _correctionsSinceFactor;
    _pushFactorAt = now;
    _correctionsSinceFactor = 0;
    // 10 秒内纠偏 0~1 次：网络好，正常推送
    // 2~4 次：轻微不同步，间隔拉到 1.6 倍
    // ≥5 次：明显抖动，间隔拉到 2.5 倍（少推、让成员多外推）
    if (corrections >= 5) {
      _pushIntervalFactor = 2.5;
    } else if (corrections >= 2) {
      _pushIntervalFactor = 1.6;
    } else {
      _pushIntervalFactor = 1;
    }
  }

  int _pushFactorAt = 0;
  int _correctionsSinceFactor = 0;
  Timer? _enterTimer;

  @override
  void initState() {
    super.initState();
    _client = TogetherClient(
      onOpen: _onOpen,
      onDown: _onDown,
      onRoom: _onRoom,
      onState: _onState,
      onChat: _onChat,
      onSystem: _onSystem,
      onError: _onError,
      onClosed: _onClosed,
      onAuthFailed: _onAuthFailed,
      onUnreachable: _onUnreachable,
    );
    WidgetsBinding.instance.addObserver(this);
    _startTimers();
    final live = widget.liveChannel;
    if (live != null) {
      _setupLive(live, widget.liveLineId, create: true);
    } else {
      final videoId = (widget.videoId ?? '').trim();
      if (videoId.isNotEmpty) {
        _videoId = videoId;
        _ep = widget.ep < 1 ? 1 : widget.ep;
        // 线路为空时不能假定 'l1'：我们的线路 id 是真实值
        // （平台线路 pt_xxx、采集线路是服务端生成的 id），根本没有 l1。
        // 留空，等 _createRoom 拿到详情后再取第一条真实线路。
        _videoLine = widget.line.trim();
        // 从详情页进入时沿用当前进度；不足 60 秒视为刚看片头，从头开始。
        _resumePos =
            widget.position >= fxResumeMinSeconds ? widget.position : 0;
        _resumePlaying = widget.playing;
        _createRoom(videoId, _ep);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _heartbeat?.cancel();
    _enterTimer?.cancel();
    _ticker = null;
    _heartbeat = null;
    _enterTimer = null;
    _awaitingStateTimer?.cancel();
    _awaitingStateTimer = null;
    _frozenFadeTimer?.cancel();
    _frozenFallbackTimer?.cancel();
    _liveFirstFrameTimer?.cancel();
    _frozenFrame?.dispose();
    _frozenFrame = null;
    _joinCtrl.dispose();
    if (_fullscreen) {
      _fullscreen = false;
      unawaited(_restoreSystemUi());
    }
    _videoSeq++;
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      controller.removeListener(_onVideoValue);
      unawaited(_releasePlayer(controller));
    }
    _client.leave();
    _client.dispose();
    _chat.dispose();
    _membersLive.dispose();
    _position.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state == AppLifecycleState.resumed) {
      final wasBackground = !_foreground;
      _foreground = true;
      // 回前台只接回画面：换 key 重挂 Video 层，不重新拉流、不重置进度。
      if (wasBackground && _stage == _TogetherStage.room && mounted) {
        setState(() => _videoEpoch++);
        // 画面层重建不等于流还活着：后台待久了连接会被回收、平台签名
        // 也会过期。这里让播放器自检一次，真断了自动重连回原位置，
        // 房主/房员都不用手动点重试。
        final c = _controller;
        if (c != null) {
          unawaited(c.resumeSelfCheck());
        } else if (_stage == _TogetherStage.room && _videoId.isNotEmpty) {
          // 播放器已被释放（后台被系统回收）：按房间当前状态整段重建，
          // 位置由随后的 room_state 对齐。
          unawaited(_loadVideo(_videoId, _ep, _videoLine));
        }
      }
      if (_stage == _TogetherStage.room) {
        // 不断连：socket 还在就直接要一次权威状态，否则重连。
        if (_client.connected) {
          if (!_isHost) _armAwaitingState();
        } else {
          _client.connect();
        }
        // 回前台只做对齐：房主把本地进度写回；客人等最新的 room_state
        // 回来再同步位置，不拿旧状态先 pause 再 play 造成声音断层。
        if (_isHost) _resync();
      } else if (_stage == _TogetherStage.entering && !_client.connected) {
        _client.connect();
      }
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // 切后台不主动 pause/disconnect（房间要继续同步），回来再对齐。
      _foreground = false;
    }
  }

  /* ------------------------------------------------------------ 连接回调 */

  void _onOpen(TogetherMember me) {
    if (!mounted) return;
    final first = _myId.isEmpty;
    setState(() {
      _online = true;
      if (me.id.isNotEmpty) _myId = me.id;
    });
    _downReported = false;
    if (!first && _entered) {
      _appendSystem('已重新连接服务器');
      if (_isLive) {
        // 直播断线重连：直接重新拉流回到直播边缘，不等旧流慢慢追。
        _liveJumpToEdge(force: true);
      } else {
        _syncVideo();
      }
      // 重连时 hello 先于 join，此时直接写 state 会被服务器拒绝；
      // 等 room_state 回来后再把房主本地进度写回。
      if (_isHost) _needsHostResync = true;
    }
  }

  /// 进入「等房间状态」并挂兜底：3 秒内没等到就放弃等待、按本地继续播。
  ///
  /// 之前只置 true 不设超时，room_state 一旦因为网络抖动没回来，
  /// 画面就一直停在「转圈等同步」，用户看到的就是一起看一直卡。
  void _armAwaitingState() {
    _awaitingRoomState = true;
    _awaitingStateTimer?.cancel();
    _awaitingStateTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !_awaitingRoomState) return;
      _awaitingRoomState = false;
      // 放弃等待：让播放继续，下一次 room_state 到达再对齐。
      final c = _controller;
      if (c != null && !c.value.hasError) {
        unawaited(c.play());
      }
      if (mounted) setState(() {});
    });
  }

  void _onDown() {
    if (!mounted) return;
    final wasOnline = _online;
    _armAwaitingState();
    // 断线后错峰等待也没有意义：重连回来会拿到新的权威状态。
    _cancelStaggerSeek();
    // Losing the control socket must not leave a member locally paused while
    // the host's last playback intent was play. Do not extrapolate/seek against
    // that stale snapshot; let the media stream continue until rejoin succeeds.
    final wasHeld = _stallHold;
    _stallHold = false;
    _authStall = false;
    _aheadSince = 0;
    final remote = _remote;
    if (!_isHost && remote != null) {
      _restoreBaseRate(remote);
      if (wasHeld) _followPlayIntent(remote);
    }
    setState(() => _online = false);
    if (!_entered && _stage == _TogetherStage.entering) {
      _backToEntry();
      togetherToast(
        context,
        '连不上一起看服务器（${_client.wsUrl}），检查网络后重试',
      );
      return;
    }
    if (_entered && wasOnline && !_downReported) {
      _downReported = true;
      if (_isHost) _needsHostResync = true;
      _appendSystem('连接断开，正在自动重连…');
    }
  }

  /// 自动重连耗尽（连续失败 5 次，约 45 秒）：**停止无限「正在重连」**，
  /// 把地址和失败原因说清楚，并给一个能点的「重试」。
  ///
  /// 之前这里只有 `_onDown` 里的一句「连接断开，正在自动重连…」，
  /// 服务器地址错 / 端口不通时这句话会一直挂着，用户既不知道连的是哪，
  /// 也没有任何可点的东西 —— 这就是「一起看连不上」的观感来源。
  void _onUnreachable(String url) {
    if (!mounted) return;
    setState(() => _online = false);
    final reason = '连不上一起看服务器（$url），已停止自动重连';
    if (!_entered) {
      if (_stage == _TogetherStage.entering) _backToEntry();
    } else {
      _downReported = true;
      _appendSystem('$reason。点「重试」再连。');
    }
    _showRetrySnack(reason);
  }

  void _showRetrySnack(String text) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(text),
      duration: const Duration(seconds: 12),
      behavior: SnackBarBehavior.floating,
      action: SnackBarAction(
        label: '重试',
        textColor: Colors.white,
        onPressed: () {
          if (!mounted) return;
          _appendSystem('正在重连一起看服务器…');
          _client.retryNow();
        },
      ),
    ));
  }

  /// 建房 / 加入 / 退出时清空同步游标与防抖状态。
  void _resetSyncState() {
    _remote = null;
    _awaitingRoomState = false;
    _awaitingStateTimer?.cancel();
    _cancelStaggerSeek();
    _seqGate.reset();
    _applyHoldUntil = 0;
    _seekGuardUntil = 0;
    _seekToken++;
    _seeking = false;
    _bufferingHold = false;
    _stalled = false;
    _lastProgressPositionMs = 0;
    _lastProgressAt = 0;
    _microRateRetryAt = 0;
    _microRateUnsupported = false;
    _lastRequestedRate = 1.0;
    _authStall = false;
    _authStallAt = 0;
    _stallHold = false;
    _stallHoldAt = 0;
    _aheadSince = 0;
    _lastClockVersion = _client.clockVersion;
    _hostReportedPos = -1;
    _hostReportedAt = 0;
    _hostReportedState = '';
    _hostReportFresh = false;
    _hostBacktrackAt = 0;
    _hostBuffering = false;
    _hostBufferReportAt = 0;
  }

  void _onRoom(TogetherRoomInfo info) {
    if (!mounted) return;
    if (!_wantsRoom) {
      // 用户已取消进入，服务器却建好了房：顺手清理，避免留空房。
      _client.leave();
      return;
    }
    if (_isLive) {
      // 直播房：服务器可能把 videoId 填成库里的第一部片，不能覆盖频道 id。
      final live = info.liveChannel;
      if (live != null && live.id != _liveChannel?.id) {
        _setupLive(live, _liveLineId, create: false);
      }
      if (info.line.isNotEmpty &&
          (_liveChannel?.lines.any((line) => line.id == info.line) ?? false)) {
        _liveLineId = info.line;
        _videoLine = info.line;
      }
    }
    setState(() {
      _stage = _TogetherStage.room;
      _entered = true;
      _online = true;
      _isHost = true;
      _roomCode = info.code;
      _roomTitle = _isLive ? '$_videoTitle · 一起看' : info.title;
      if (!_isLive && info.videoId.isNotEmpty) _videoId = info.videoId;
      if (!_isLive && info.ep > 0) _ep = info.ep;
      if (!_isLive && info.line.isNotEmpty) _videoLine = info.line;
      _members = info.members.isEmpty
          ? <TogetherMember>[
              TogetherMember(
                id: _client.selfId,
                name: _client.selfName.isEmpty ? '房主' : _client.selfName,
                avatar: _client.selfAvatar,
                host: true,
              ),
            ]
          : info.members;
      _membersLive.value = _members;
    });
    _resetSyncState();
    _downReported = false;
    if (_isLive) {
      // 直播房一建好就默认在播：先把本地权威状态置为 playing，
      // 再广播给服务器 / 成员，不能等服务端回一个默认的暂停态。
      _livePlaying = true;
      _position.value = 0;
      if (_isHost && _online) _sendLiveState(true);
      _syncVideo();
      return;
    }
    // 建房沿用详情页当前进度，并按默认 playing 立刻广播给房间，
    // 成员加入时就能按房主的 lineId、进度和播放态拉流。
    final startPosition = _resumePos ?? 0;
    _position.value = startPosition;
    if (_isHost && _online) {
      _reportHostState(
        _resumePlaying ? 'play' : 'pause',
        startPosition,
        videoId: _videoId,
        ep: _ep,
        line: _videoLine,
        rate: _hostRate,
        fresh: true,
        mark: false,
      );
    }
    _syncVideo();
  }

  void _onState(TogetherRoomState state) {
    if (!mounted || !_wantsRoom) return;
    if (_roomCode.isNotEmpty && state.code != _roomCode) {
      return; // 忽略上一个房间迟到的状态
    }
    // 防重入：同一房间同一 seq 只应用一次；旧 seq 直接丢弃。
    final awaitingRoomState = _awaitingRoomState;
    _awaitingRoomState = false;
    _awaitingStateTimer?.cancel();
    if (!_seqGate.accept(state.code, state.seq)) {
      // A refresh/rejoin can legitimately return the same revision. It still
      // confirms that this socket is back in the room and can release playback.
      if (awaitingRoomState && !_isHost && !_isLive) {
        final remote = _remote;
        if (remote != null) _followPlayIntent(remote);
      }
      return;
    }
    final prev = _remote;
    final incomingLive = state.liveChannel;
    if (_isLive || state.isLive) {
      final live = incomingLive ?? _liveChannel;
      final changedChannel =
          live != null && (!_isLive || live.id != _liveChannel?.id);
      if (changedChannel) {
        _setupLive(live, _liveLineId, create: false);
      }
      final targetLine = state.line.trim();
      final validLine = targetLine.isNotEmpty &&
          (_liveChannel?.lines.any((line) => line.id == targetLine) ?? false);
      final changedLine = validLine && targetLine != _liveLineId;
      setState(() {
        _remote = state;
        _stage = _TogetherStage.room;
        _entered = true;
        _online = true;
        if (state.code.isNotEmpty) _roomCode = state.code;
        _roomTitle = stripLiveRoomTitle(state.title);
        if (_liveChannel != null) _videoTitle = _liveChannel!.title;
        if (state.members.isNotEmpty) _members = state.members;
        _membersLive.value = _members;
        if (validLine) {
          _liveLineId = targetLine;
          _videoLine = targetLine;
        }
        if (state.members.isNotEmpty) {
          var host = false;
          for (final member in state.members) {
            if (member.id == _myId && member.host) host = true;
          }
          _isHost = host;
        }
      });
      _downReported = false;
      if (changedChannel && _isLive) {
        _loadedKey = '';
        _loadingKey = '';
      }
      // 成员以房主最新状态为准：房主暂停 / 回到开头后再邀请，
      // 新成员也必须先按暂停态拉流，不能先自己播一段再跳。
      if (!_isHost) _livePlaying = state.playing;
      if (changedChannel || changedLine) _syncVideo();
      if (!_isHost) {
        _applyLiveRemote(state, prev);
      } else if (_needsHostResync) {
        _needsHostResync = false;
        _sendLiveState(state.playing);
      }
      return;
    }
    final changedVideo = state.videoId.isNotEmpty && state.videoId != _videoId;
    final changedEp = state.ep > 0 && state.ep != _ep;
    final changedLine = state.line.isNotEmpty && state.line != _videoLine;

    setState(() {
      _remote = state;
      _stage = _TogetherStage.room;
      _entered = true;
      _online = true;
      if (state.code.isNotEmpty) _roomCode = state.code;
      if (state.title.isNotEmpty) _roomTitle = state.title;
      if (state.members.isNotEmpty) _members = state.members;
      _membersLive.value = _members;
      if (state.videoId.isNotEmpty) _videoId = state.videoId;
      if (state.ep > 0) _ep = state.ep;
      if (state.line.isNotEmpty) _videoLine = state.line;
      if (state.members.isNotEmpty) {
        var host = false;
        for (final member in state.members) {
          if (member.id == _myId && member.host) host = true;
        }
        _isHost = host;
      }
    });
    _downReported = false;

    if (changedVideo) {
      _detailVideoId = '';
      _lines = const <LineInfo>[];
      _episodes = const <Episode>[];
      _playInfo = null;
      _qualityKey = null;
    }
    if ((changedVideo || changedEp) && !_isHost) {
      // 成员只跟权威 state；房主切换时保留本地播放意图，避免回调把
      // 刚发出去的 play 覆盖成 pause。
      _resumePos = null;
      _resumePlaying = false;
    }
    if (changedVideo || changedEp || changedLine) _syncVideo();
    if (!_isHost) {
      _applyRemoteState(
        state,
        prev: prev,
        mediaChanged: changedVideo || changedEp || changedLine,
      );
    } else if (_needsHostResync) {
      _needsHostResync = false;
      _resync();
    }
    _position.value = _displayPosition();
  }

  void _onChat(TogetherChatIncoming chat) {
    if (!mounted || chat.text.isEmpty) return;
    _appendMessage(
      TogetherChatMessage(
        text: chat.text,
        time: DateTime.now(),
        user: chat.name,
        avatar: chat.avatar,
        mine: chat.userId.isNotEmpty && chat.userId == _myId,
      ),
    );
  }

  void _onSystem(String text) {
    if (!mounted || text.isEmpty) return;
    _appendSystem(text.replaceAll('加入了房间', '进入房间'));
  }

  void _onError(String code, String message) {
    if (!mounted) return;
    if (code == 'host_only') {
      fxShowTopTag('跟随房主');
      _bounceToAuthority();
      return;
    }
    if (code == 'bad_code') {
      togetherToast(context, message.isEmpty ? '房间号必须是 6 位数字' : message);
      return;
    }
    if (code == 'not_in_room') {
      // 取消进入时补发的 leave 可能落在服务器清理之后，静默处理。
      return;
    }
    if (_isPasswordErrorCode(code)) {
      final text = code == 'password_required' ? '房间需要密码' : '房间密码错误，请重新输入';
      if (_stage == _TogetherStage.entering) {
        togetherToast(context, text);
        _backToEntry();
      } else if (_stage == _TogetherStage.room) {
        _onClosed(text);
      } else {
        togetherToast(context, text);
      }
      return;
    }
    if (code == 'not_found') {
      if (_stage == _TogetherStage.entering) {
        togetherToast(
          context,
          _enteringAsHost
              ? (message.isEmpty ? '创建房间失败，请稍后重试' : message)
              : '房间不存在，请检查房间号',
        );
        _backToEntry();
      } else if (_stage == _TogetherStage.room) {
        if (_client.code.isEmpty) {
          _onClosed('房间已解散');
        } else if (message.isNotEmpty) {
          togetherToast(context, message);
        }
      }
      return;
    }
    if (code == 'room_full') {
      if (_stage == _TogetherStage.entering) {
        togetherToast(context, '房间已满，请稍后再试');
        _backToEntry();
      } else if (_stage == _TogetherStage.room) {
        _onClosed('房间已满');
      } else {
        togetherToast(context, '房间已满，请稍后再试');
      }
      return;
    }
    if (message.isNotEmpty) togetherToast(context, message);
  }

  bool _isPasswordErrorCode(String code) {
    final lower = code.toLowerCase();
    return lower.contains('password') ||
        lower.contains('passwd') ||
        lower.contains('pwd');
  }

  void _onClosed(String reason) {
    if (!mounted || _leaving) return;
    unawaited(_saveRoomProgress());
    if (_fullscreen) unawaited(_exitFullscreen());
    final text = reason.isEmpty ? '房间已解散' : reason;
    _clearRoom();
    togetherToast(context, text);
  }

  /// token 过期：客户端已停止自动重连。清本地登录态、退房间回详情页，
  /// 不能让用户停在一个永远「正在自动重连…」的房间里。
  void _onAuthFailed() {
    if (!mounted || _authExpired || _leaving) return;
    _authExpired = true;
    unawaited(_handleAuthExpired());
  }

  Future<void> _handleAuthExpired() async {
    // Auth 清本地登录态并弹「登录已过期，请重新登录」；
    // 已经因 HTTP 401 处理过时会静默，避免重复提示。
    await Auth.instance.expire();
    if (!mounted) return;
    final inRoom = _stage == _TogetherStage.room;
    // 登录已失效时不要让详情页自动播起来，退出后保持暂停等用户处理账号。
    final result = inRoom ? _exitResult(forcePaused: true) : null;
    if (_fullscreen) await _exitFullscreen();
    if (!mounted) return;
    _leaving = true;
    _client.leave();
    _videoSeq++;
    await _disposeController();
    if (!mounted) return;
    _clearRoom();
    // 客户端已停止重连，房间不可用：直接退回详情页，不再无限重连。
    Navigator.of(context).pop(result);
  }

  /* ------------------------------------------------------------ 建房 / 加入 */

  /* ------------------------------------------------------------ 直播房 */

  /// 初始化直播房：host 建房 / 成员从 room_state 还原时都会走这里。
  void _setupLive(LiveChannel channel, String lineId, {required bool create}) {
    final lines = channel.lines;
    var target = lineId.trim();
    if (!lines.any((line) => line.id == target)) {
      target = lines.isEmpty ? '' : lines.first.id;
    }
    _liveChannel = channel;
    _liveLineId = target;
    _videoId = channel.id;
    _videoLine = target;
    _episodes = const <Episode>[];
    _lines = const <LineInfo>[];
    _playInfo = null;
    _qualityKey = null;
    _videoTitle = channel.title.trim().isEmpty ? '电视直播' : channel.title.trim();
    _videoCover = togetherCoverUrl(channel.cover);
    _videoError = '';
    _liveLastPosMs = -1;
    _liveLastProgressAt = 0;
    if (!create) return;
    _createLiveRoom();
  }

  Map<String, dynamic> _liveMeta() {
    final channel = _liveChannel;
    if (channel == null) return const <String, dynamic>{};
    return <String, dynamic>{
      'liveName': channel.title,
      'liveCover': channel.cover,
      'liveGroup': channel.group,
      'lines': [for (final line in channel.lines) line.toJson()],
    };
  }

  LiveLine? get _liveLine {
    final channel = _liveChannel;
    if (channel == null) return null;
    for (final line in channel.lines) {
      if (line.id == _liveLineId) return line;
    }
    return channel.lines.isEmpty ? null : channel.lines.first;
  }

  void _createLiveRoom() {
    final channel = _liveChannel;
    if (channel == null || channel.lines.isEmpty) {
      togetherToast(context, '该频道暂无可用直播线路');
      return;
    }
    _clearMessages();
    _wantsRoom = true;
    _enteringAsHost = true;
    _entered = false;
    _leaving = false;
    _exiting = false;
    _resetSyncState();
    _roomCode = '';
    _roomTitle = '${_videoTitle} · 一起看';
    _stage = _TogetherStage.entering;
    _stageText = '正在创建直播房间…';
    // 直播默认在播：房间还没收到服务端状态前也按 playing 处理，
    // 成员加入时看到的房主状态就是「播放中」。
    _livePlaying = true;
    _loadedKey = '';
    _loadingKey = '';
    _videoLoading = false;
    _videoError = '';
    _online = _client.connected;
    // 老服务端不会透传 kind/channelId/lines：把频道编码进 title，
    // 成员加入时仍能还原频道和线路；新服务端则直接读结构化字段。
    _client.createRoom(
      videoId: channel.id,
      ep: 1,
      line: _liveLineId,
      title: encodeLiveRoomTitle(channel),
      kind: 'live',
      channelId: channel.id,
      live: _liveMeta(),
    );
    _client.connect();
    _armEnterTimer();
    if (mounted) setState(() {});
  }

  /// 房主广播直播播放状态：只同步 play/pause 和线路，不传进度。
  void _sendLiveState(bool playing) {
    _livePlaying = playing;
    if (!_online) return;
    _client.sendState(
      playing ? 'play' : 'pause',
      0,
      line: _liveLineId,
      live: true,
    );
    _markRemote(playing ? 'play' : 'pause', 0);
  }

  /// 重新拉流回到直播边缘（成员暂停后恢复 / 卡顿 / 重连时调用）。
  void _liveJumpToEdge({bool force = false}) {
    if (!mounted) return;
    // 只有房主能主动暂停/播放；成员的暂停恢复由房主状态触发。
    if (_isHost && !force) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_liveJumping || now - _liveReloadAt < 3000) return;
    _liveJumping = true;
    _liveReloadAt = now;
    _loadedKey = '';
    _loadingKey = '';
    _loadLiveVideo().whenComplete(() => _liveJumping = false);
  }

  /// 成员收到直播权威状态：只跟 play/pause；从暂停恢复时回到直播最新位置。
  void _applyLiveRemote(TogetherRoomState state, TogetherRoomState? prev) {
    if (_isHost) return;
    _livePlaying = state.playing;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (!state.playing) {
      if (controller.value.isPlaying) {
        unawaited(controller.pause().catchError((_) {}));
      }
      return;
    }
    final wasPaused = prev != null && !prev.playing;
    if (wasPaused || !controller.value.isPlaying) {
      // 直播没有可 seam 的进度：重新拉流即回到最新位置（静默，不提示）。
      _liveJumpToEdge();
      return;
    }
  }

  /// 直播卡顿检测：播放中 6 秒画面不前进，重新拉流回到直播边缘。
  void _tickLive() {
    final controller = _controller;
    if (controller == null || !mounted) return;
    final value = controller.value;
    if (!value.isInitialized) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final pos = value.position.inMilliseconds;
    if (!value.isPlaying || value.isBuffering) {
      _liveLastPosMs = pos;
      _liveLastProgressAt = now;
      return;
    }
    if (pos > _liveLastPosMs + 200) {
      _liveLastPosMs = pos;
      _liveLastProgressAt = now;
      return;
    }
    if (_liveLastProgressAt > 0 && now - _liveLastProgressAt > 6000) {
      _liveLastProgressAt = now;
      _liveJumpToEdge(force: _isHost);
    }
  }

  void _createRoom(String videoId, int ep, {VideoDetail? detail}) {
    _liveChannel = null;
    _liveLineId = '';
    _clearMessages();
    _wantsRoom = true;
    _enteringAsHost = true;
    _entered = false;
    _leaving = false;
    _exiting = false;
    _resetSyncState();
    _roomCode = '';
    _stage = _TogetherStage.entering;
    _stageText = '正在创建房间…';
    _videoId = videoId;
    _ep = ep < 1 ? 1 : ep;
    // 线路留空时，用详情里的第一条真实线路（详情已在上面拿到）。
    // 之前写死 'l1'，而服务端从来没有这个 id，导致一起看里线路名显示成
    // 原始 id、切线路也对不上 —— 用户报的「一起看的线路完全对不上」。
    if (_videoLine.trim().isEmpty) {
      _videoLine = _lines.isNotEmpty
          ? _lines.first.id
          : (detail?.lines.isNotEmpty ?? false)
              ? detail!.lines.first.id
              : '';
    }
    _qualityKey = null;
    _playInfo = null;
    // 选集面板已经拿到的详情直接带进来，不再多请求一次 /api/detail。
    _detailVideoId = detail == null ? '' : videoId;
    _lines = detail?.lines ?? const <LineInfo>[];
    _episodes = detail?.allEpisodes ?? const <Episode>[];
    _loadedKey = '';
    _loadingKey = '';
    _videoError = '';
    // 建房默认 state = playing：当前集、当前进度直接开播，不要求用户
    // 先进房再点一次播放；房主随后暂停 / 拖动后，成员以服务器权威
    // state 为准（见 _onState / _loadVideo）。
    if (_resumePos == null) _resumePos = 0;
    _resumePlaying = true;
    _online = _client.connected;
    _client.createRoom(
      videoId: videoId,
      ep: _ep,
      line: _videoLine,
      title: _videoTitle.isEmpty ? '' : '$_videoTitle · 一起看',
    );
    _client.connect();
    _armEnterTimer();
    if (detail == null) {
      _loadVideoTitle(videoId);
    } else {
      if (detail.title.isNotEmpty) _videoTitle = detail.title;
      if (detail.cover.isNotEmpty) {
        _videoCover = togetherCoverUrl(detail.cover);
      }
    }
    if (mounted) setState(() {});
  }

  void _joinRoom(String code) {
    if (!TogetherClient.validCode(code)) {
      togetherToast(context, '房间号必须是 6 位数字');
      return;
    }
    _joinCtrl.clear();
    _clearMessages();
    _wantsRoom = true;
    _enteringAsHost = false;
    _entered = false;
    _leaving = false;
    _exiting = false;
    _resetSyncState();
    _roomCode = code;
    _stage = _TogetherStage.entering;
    _stageText = '正在加入房间 $code…';
    _videoId = '';
    _videoTitle = '';
    _videoCover = '';
    _liveChannel = null;
    _liveLineId = '';
    _episodes = const <Episode>[];
    _lines = const <LineInfo>[];
    _detailVideoId = '';
    _ep = 1;
    _qualityKey = null;
    _playInfo = null;
    _loadedKey = '';
    _loadingKey = '';
    _videoError = '';
    _online = _client.connected;
    if (!_client.joinRoom(code)) {
      _backToEntry();
      return;
    }
    _client.connect();
    _armEnterTimer();
    if (mounted) setState(() {});
  }

  void _armEnterTimer() {
    _enterTimer?.cancel();
    _enterTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted || _entered || _stage != _TogetherStage.entering) return;
      _backToEntry();
      togetherToast(context, '连不上一起看服务器，稍后再试');
    });
  }

  void _backToEntry() {
    if (!mounted) return;
    _clearRoom();
  }

  /// 清空房间与播放器，回到入口；调用方决定后续导航。
  void _clearRoom() {
    _enterTimer?.cancel();
    _enterTimer = null;
    _wantsRoom = false;
    _enteringAsHost = false;
    if (_fullscreen) unawaited(_exitFullscreen());
    _client.leave();
    _videoSeq++;
    _cancelLiveFirstFrameTimer();
    _resumePos = null;
    _resumePlaying = false;
    _detailVideoId = '';
    _liveChannel = null;
    _liveLineId = '';
    _livePlaying = true;
    _position.value = 0;
    unawaited(_disposeController());
    _resetSyncState();
    if (!mounted) return;
    setState(() {
      _stage = _TogetherStage.entry;
      _entered = false;
      _isHost = false;
      _online = _client.connected;
      _roomCode = '';
      _roomTitle = '';
      _members = const <TogetherMember>[];
      _membersLive.value = const <TogetherMember>[];
      _messages.clear();
      _chat.value = const <TogetherChatMessage>[];
      _videoId = '';
      _videoTitle = '';
      _videoCover = '';
      _liveChannel = null;
      _liveLineId = '';
      _episodes = const <Episode>[];
      _lines = const <LineInfo>[];
      _ep = 1;
      _videoLine = '';
      _playInfo = null;
      _qualityKey = null;
      _loadedKey = '';
      _loadingKey = '';
      _videoLoading = false;
      _videoError = '';
      _stageText = '';
      _downReported = false;
      _needsHostResync = false;
    });
  }

  Future<void> _leaveEntering() async {
    if (_leaving) return;
    if (!_enteringAsHost) {
      _backToEntry();
      return;
    }
    _leaving = true;
    _videoSeq++;
    _client.leave();
    await _disposeController();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _confirmLeaveRoom() async {
    if (!mounted || _exiting || _leaving) return;
    if (_stage != _TogetherStage.room) return;
    _exiting = true;
    final host = _isHost;
    final ok = await showTogetherConfirm(
      context,
      title: host ? '解散房间？' : '退出房间？',
      content: host ? '你是房主，退出后房间会解散，其他成员将全部离开。' : '退出后可以重新加入，房主和播放进度不受影响。',
      confirmText: host ? '解散离开' : '退出',
      danger: host,
    );
    _exiting = false;
    if (!ok || !mounted) return;
    _leaving = true;
    await _saveRoomProgress();
    if (!mounted) return;
    // 释放播放器之前取快照：房间内切集 / 换剧 / 换线后，
    // 详情页必须按房间当前状态恢复，而不是重播进房前的旧集。
    final result = _exitResult();
    if (_fullscreen) await _exitFullscreen();
    if (!mounted) return;
    _client.leave();
    _videoSeq++;
    await _disposeController();
    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  /// 退出房间时回传给详情页的快照。
  ///
  /// [forcePaused] 用于 token 过期这类异常退出：详情页恢复后保持暂停，
  /// 不让画面在登录失效后自己播起来。
  TogetherExitResult _exitResult({bool forcePaused = false}) {
    final controller = _controller;
    final initialized = controller != null && controller.value.isInitialized;
    final position = initialized
        ? controller.value.position.inMilliseconds / 1000.0
        : _displayPosition();
    return TogetherExitResult(
      videoId: _videoId,
      ep: _ep < 1 ? 1 : _ep,
      lineId: _isLive ? _liveLineId : _videoLine,
      position: position.isFinite && position > 0 ? position : 0,
      playing: !forcePaused &&
          (controller?.value.isPlaying ??
              (_isLive ? _livePlaying : (_remote?.playing ?? false))),
      kind: _isLive ? 'live' : 'video',
    );
  }

  Future<void> _saveRoomProgress() async {
    if (_isLive) return; // 直播没有观看进度可回写。
    final controller = _controller;
    final position = controller != null && controller.value.isInitialized
        ? controller.value.position.inMilliseconds / 1000.0
        : _displayPosition();
    if (_videoId.isEmpty || _ep <= 0) return;
    // 0 秒不覆盖详情页原本的进度；有真实观看进度才回写。
    if (!position.isFinite || position <= .5) return;
    // 片尾窗口内不写进度，直接清 0：房间散场时往往已经播到片尾，
    // 若把「距结尾几十秒」存下来，下次单独打开这集会直接从片尾开始。
    final totalSeconds =
        controller != null && controller.value.isInitialized
            ? controller.value.duration.inMilliseconds / 1000.0
            : 0.0;
    final save = fxIsFinishedPosition(position, totalSeconds) ? 0.0 : position;
    try {
      await fxSaveProgress(_videoId, _ep, save);
    } catch (_) {}
  }

  /// 返回键 / 左上角返回：全屏先退全屏，房间确认退出，入口直接 pop。
  void _requestBack() {
    if (_fullscreen) {
      unawaited(_exitFullscreen());
      return;
    }
    switch (_stage) {
      case _TogetherStage.entry:
        Navigator.of(context).pop();
      case _TogetherStage.entering:
        unawaited(_leaveEntering());
      case _TogetherStage.room:
        unawaited(_confirmLeaveRoom());
    }
  }

  /* ------------------------------------------------------------ 生命周期 / 定时 */

  void _startTimers() {
    _ticker ??= Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _tick(),
    );
    _heartbeat ??= Timer.periodic(
      const Duration(seconds: 9),
      (_) => _hostHeartbeat(),
    );
  }

  void _resync() {
    if (_stage != _TogetherStage.room) return;
    if (_isLive) {
      final controller = _controller;
      if (_isHost) {
        final playing = controller?.value.isPlaying ?? _livePlaying;
        _sendLiveState(playing);
      } else {
        final remote = _remote;
        if (remote != null) _applyLiveRemote(remote, remote);
      }
      return;
    }
    if (_isHost) {
      final controller = _controller;
      if (controller != null && controller.value.isInitialized) {
        final position = controller.value.position.inMilliseconds / 1000.0;
        final playing = controller.value.isPlaying;
        _reportHostState(
          playing ? 'play' : 'pause',
          position,
          videoId: _videoId,
          ep: _ep,
          line: _videoLine,
          rate: _hostRate,
        );
      }
    } else {
      final state = _remote;
      if (state != null) _applyRemoteState(state, prev: state);
    }
    _tick(force: true);
  }

  void _hostHeartbeat() {
    if (!mounted || !_isHost || !_online || !_foreground) return;
    if (_isLive) return; // 直播只广播 play/pause，不按秒同步进度。
    final controller = _controller;
    final state = _remote;
    if (controller == null ||
        !controller.value.isInitialized ||
        state == null ||
        !controller.value.isPlaying) {
      return;
    }
    final position = controller.value.position.inMilliseconds / 1000.0;
    _reportHostState('play', position, rate: _hostRate);
  }

  /* ------------------------------------------------------------ 同步 */

  double _clampPosition(double value) {
    if (!value.isFinite || value < 0) return 0;
    return value > 86400 ? 86400 : value;
  }

  /// 服务器权威 position 按本地时钟外推：
  /// expect = position + (now + clockOffset - serverTime) / 1000 * rate。
  /// 房主倍速不为 1 时，进度同样按倍速推进，否则 9 秒心跳之间会被误判成 drift。
  double _targetPosition(TogetherRoomState state) {
    // 补偿单程延迟：state 里的 position 是房主「发出那一刻」的位置，
    // 成员收到时已经过去了半个 RTT。不补这一下，网络正常也会凭空
    // 产生几十~几百毫秒偏差，被纠偏逻辑当成落后 → 微调/硬跳 →
    // 下一份 state 又反过来 → 来回跳。双方网络都不差却一直跳，
    // 主因就是这里没扣延迟。
    final rttSec = _client.rtt / 2000.0;
    return _clampPosition(
      togetherExpectedPosition(
        position: state.position,
        serverTime: state.serverTime,
        // 用「当前时刻 - 单程延迟」等价于把外推起点往前挪，
        // 得到的是「此刻房主应该在的位置」。
        nowServerMs: _client.nowServerMs() - (rttSec * 1000).round(),
        // 房主停滞期间期望进度冻结：不能一边让权威停住、一边继续外推，
        // 否则成员会越跑越前，等下一份 state 到达又整体回退。
        playing: state.playing && _client.synced && !_authStall,
        rate: _baseRate(state),
      ),
    );
  }

  double _displayPosition() {
    final controller = _controller;
    if (_isHost) {
      if (controller != null && controller.value.isInitialized) {
        return controller.value.position.inMilliseconds / 1000.0;
      }
      final state = _remote;
      return state == null ? 0 : _targetPosition(state);
    }
    // 成员：进度条跟本地播放器走。权威值只在加载 / 播放器未起步时兜底，
    // 这样权威 position 的任何回退（房主缓冲、段重载、读数抖动）都不会
    // 在进度条上肉眼可见地来回跳。
    if (!_videoLoading &&
        controller != null &&
        controller.value.isInitialized) {
      return controller.value.position.inMilliseconds / 1000.0;
    }
    final state = _remote;
    if (state != null) return _targetPosition(state);
    if (controller != null && controller.value.isInitialized) {
      return controller.value.position.inMilliseconds / 1000.0;
    }
    return 0;
  }

  double _baseRate(TogetherRoomState state) => togetherClampRate(state.rate);

  double _microRateFor(TogetherRoomState state, double drift) {
    final step = drift > 0 ? togetherMicroRateStep : -togetherMicroRateStep;
    return togetherClampRate(_baseRate(state) + step);
  }

  void _tick({bool force = false}) {
    if (!mounted || _stage != _TogetherStage.room) return;
    if (_isLive) {
      _tickLive();
      return;
    }
    final controller = _controller;
    final state = _remote;
    // Buffering can stop value notifications entirely; the timer must keep
    // publishing the frozen host position instead of relying on that stream.
    if (_isHost && _foreground) {
      _watchHostBuffering();
      _updatePushIntervalFactor();
      _pushHostProgressThrottled();
    }
    // 后台不与服务器做 seek / 变速对齐：那时心跳和网络都可能被系统限流，
    // 强行追进度会造成声音断层；回前台拿到最新 room_state 再对齐。
    if (!_isHost &&
        _foreground &&
        _canCorrectMember &&
        controller != null &&
        controller.value.isInitialized &&
        state != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final positionMs = controller.value.position.inMilliseconds;
      final buffering = controller.value.isBuffering;
      final playing = controller.value.isPlaying;

      // 卡顿检测：播放中进度 1.2s 不前进视为 stall；恢复后只纠一次。
      if (playing && !buffering) {
        if (togetherPositionMoved(positionMs, _lastProgressPositionMs)) {
          _lastProgressPositionMs = positionMs;
          _lastProgressAt = now;
          if (_stalled) {
            _stalled = false;
            _bufferingHold = true;
          }
        } else if (_lastProgressAt > 0 && now - _lastProgressAt > 1200) {
          if (!_stalled) {
            _stalled = true;
            _restoreBaseRate(state);
          }
        }
      } else {
        _lastProgressPositionMs = positionMs;
        _lastProgressAt = now;
        if (buffering) _stalled = false;
      }

      // 时钟 offset 台阶会让期望进度突然跳一段：先延长冷却吸收，
      // 不要把它当成 drift 去硬 seek。
      _watchClockJump(now);

      // 房主停滞期间的保持策略：落后太多先原地暂停，等房主追上。
      _syncStallHold(state, now: now);

      if (buffering) {
        if (!_bufferingHold) {
          _bufferingHold = true;
          _restoreBaseRate(state);
        }
      } else if (_bufferingHold) {
        // 缓冲区恢复：按 drift 规则处理一次，不连续 seek。
        _bufferingHold = false;
        _correctDrift(state);
      } else if (!_stalled) {
        _correctDrift(state);
      }
    }
    final value = _displayPosition();
    if (force || (value - _position.value).abs() >= .05) {
      _position.value = value;
    }
  }

  /// 周期纠偏：<0.4s 不动；0.4–1.5s 微调 ±0.05 倍速；>1.5s 硬 seek。
  void _correctDrift(TogetherRoomState state) {
    if (_isHost ||
        !_foreground ||
        !_canCorrectMember ||
        !state.playing ||
        _stallHold) {
      return;
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_seeking || now < _seekGuardUntil || now < _applyHoldUntil) {
      return;
    }
    // 缓冲中交给 decideTogetherDrift 判断（放宽阈值、优先自然缓冲完）。
    // 之前这里直接 return，缓冲结束时偏差已经远超硬跳阈值，
    // 于是立刻被拉回去 → 又卡 → 又拉，表现就是一直原地循环。
    final buffering = controller.value.isBuffering;
    final expected = _targetPosition(state);
    final current = controller.value.position.inMilliseconds / 1000.0;
    final decision = decideTogetherDrift(
      expected: expected,
      current: current,
      playing: state.playing,
      baseRate: _baseRate(state),
      // 上次内核读数不支持微调时，等冷却结束再试一次，不是永久放弃。
      allowRate: !_microRateUnsupported || now >= _microRateRetryAt,
      // 成员领先的一侧先降速吸收：只有持续超出硬 seek 阈值才允许回跳。
      allowBackwardSeek: _allowBackSeek(expected, current, now),
      buffering: buffering,
    );
    if (decision.move == TogetherSyncMove.rate) {
      _correctionsSinceFactor++;
      _setMicroRate(decision.rate, state);
      return;
    }
    if (decision.move == TogetherSyncMove.seek) {
      // 硬 seek 是最重的纠偏，权重算 2 次，让它更快触发「拉长间隔」。
      _correctionsSinceFactor += 2;
      _hardSeek(decision.target, state);
      return;
    }
    _restoreBaseRate(state);
  }

  /// 成员领先（负向 drift）时是否允许往回跳。
  ///
  /// 房主在缓冲 / 成员处于保持中一律禁止；否则要求「持续领先超过
  /// togetherBackSeekPersistMs」——瞬时抖动先用降速吸收，别一见回退就跳。
  bool _allowBackSeek(double expected, double current, int now) {
    if (!expected.isFinite || !current.isFinite) return false;
    if (expected >= current) {
      _aheadSince = 0;
      return true;
    }
    if (_authStall || _stallHold) {
      _aheadSince = 0;
      return false;
    }
    if (_aheadSince == 0) {
      _aheadSince = now;
      return false;
    }
    return now - _aheadSince >= togetherBackSeekPersistMs;
  }

  /// 时钟 offset 大跳检测：期望进度会因此出现台阶，先延长 seek 冷却吸收，
  /// 不要立刻把它当成 drift 去硬跳。
  void _watchClockJump(int now) {
    final version = _client.clockVersion;
    if (version == _lastClockVersion) return;
    final delta = _client.clockOffsetDeltaMs;
    _lastClockVersion = version;
    if (delta.abs() <= togetherClockJumpGuardMs) return;
    final guard = now + togetherSeekCooldownMs;
    if (guard > _seekGuardUntil) _seekGuardUntil = guard;
    _aheadSince = 0;
  }

  /// 房主停滞（缓冲）时的成员保持策略。
  ///
  /// 期望进度冻结后成员会继续往前跑；落后超过阈值就原地暂停保持同步状态，
  /// 等房主恢复、期望进度追上来再继续播——全程不往回跳。
  void _syncStallHold(
    TogetherRoomState state, {
    required int now,
    bool authoritySeek = false,
  }) {
    // 房主长时间没再确认停滞（断开 / 退出）：恢复正常外推，别把成员卡死。
    if (_authStall && now - _authStallAt > togetherStallTimeoutMs) {
      _authStall = false;
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final expected = _targetPosition(state);
    final current = controller.value.position.inMilliseconds / 1000.0;
    final drift = expected - current;
    final hold = togetherShouldStallHold(
      holding: _stallHold,
      playing: state.playing,
      authorityStalled: _authStall,
      drift: drift,
      authoritySeek: authoritySeek,
      timedOut: !_authStall && now - _stallHoldAt > togetherStallTimeoutMs,
      seeking: _seeking,
      buffering: controller.value.isBuffering,
    );
    if (hold == _stallHold) return;
    _stallHold = hold;
    if (hold) {
      _stallHoldAt = now;
      _restoreBaseRate(state);
    }
    _followPlayIntent(state);
  }

  /// 跟随房主 play / pause；成员处于保持（房主缓冲）时只允许暂停。
  void _followPlayIntent(TogetherRoomState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (_stallHold) {
      if (controller.value.isPlaying) {
        unawaited(controller.pause().catchError((_) {}));
      }
      return;
    }
    if (state.playing && !controller.value.isPlaying) {
      unawaited(controller.play().catchError((_) {}));
    } else if (!state.playing && controller.value.isPlaying) {
      unawaited(controller.pause().catchError((_) {}));
    }
  }

  void _setControllerRate(double rate) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final value = togetherClampRate(rate);
    if ((_lastRequestedRate - value).abs() < 0.001 &&
        (controller.rate - value).abs() < 0.02) {
      return;
    }
    _lastRequestedRate = value;
    controller.setRate(value).catchError((_) {});
  }

  void _restoreBaseRate(TogetherRoomState state) {
    _setControllerRate(_baseRate(state));
  }

  /// 微调倍速：ExoPlayer 支持任意小数倍速；
  /// 若内核读数与请求值偏差过大，标记不支持并等下一次同步再试。
  void _setMicroRate(double rate, TogetherRoomState state) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_microRateUnsupported) {
      if (now < _microRateRetryAt) return;
      _microRateUnsupported = false; // 冷却结束，允许再试一次
    }
    final base = _baseRate(state);
    final target = togetherClampRate(rate);
    if ((target - base).abs() < 0.001) {
      _restoreBaseRate(state);
      return;
    }
    final requestedController = _controller;
    final generation = _videoSeq;
    _setControllerRate(target);
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 250), () {
        if (!mounted || generation != _videoSeq) return;
        final controller = _controller;
        if (controller == null ||
            !identical(controller, requestedController) ||
            !controller.value.isInitialized ||
            (_lastRequestedRate - target).abs() > 0.001) {
          return;
        }
        if ((controller.rate - target).abs() <= 0.02) return;
        _microRateUnsupported = true;
        _microRateRetryAt = DateTime.now().millisecondsSinceEpoch + 10000;
        _setControllerRate(base);
      }),
    );
  }

  /// 房主本地 seek（不进入成员防抖流程）。
  void _seekController(double seconds) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final target = _clampPosition(seconds);
    controller
        .seekTo(Duration(milliseconds: (target * 1000).round()))
        .catchError((_) {});
  }

  /// 成员硬 seek：seek 落位后再等 2 秒才允许下一次纠偏。
  /// 与房主的进度偏差（秒，正数=自己落后）。没有权威状态时返回 0。
  double _syncOffsetSeconds() {
    final state = _remote;
    final controller = _controller;
    if (state == null || controller == null || !controller.value.isInitialized) {
      return 0;
    }
    final expected = _targetPosition(state);
    final current = controller.value.position.inMilliseconds / 1000.0;
    return expected - current;
  }

  /// 手动同步到房主进度：一键对齐，用户自己决定何时跳。
  ///
  /// 自动纠偏只在超阈值时才硬跳（会打断缓冲），网络差的一方偶尔会
  /// 长时间落后。给一个明确的手动入口，比让它反复自动跳体验更好。
  Future<void> _syncToHostNow() async {
    final state = _remote;
    final controller = _controller;
    if (state == null || controller == null || !controller.value.isInitialized) {
      return;
    }
    final expected = _targetPosition(state);
    _logSync('手动同步房主：当前 ${controller.value.position.inSeconds}s → '
        '目标 ${expected.toStringAsFixed(1)}s');
    // 手动同步是用户点出来的：不吃错峰延迟，还要顶掉排队中的错峰 seek。
    _cancelStaggerSeek();
    _hardSeek(expected, state);
    // 房主在播就跟着播。
    if (state.playing) _followPlayIntent(state);
    if (mounted) setState(() {});
  }

  void _logSync(String message) {
    debugPrint('[Together] $message');
  }

  void _hardSeek(double seconds, TogetherRoomState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final target = _clampPosition(seconds);
    final token = ++_seekToken;
    _seeking = true;
    _stalled = false;
    _lastProgressPositionMs = (target * 1000).round();
    _lastProgressAt = DateTime.now().millisecondsSinceEpoch;
    _restoreBaseRate(state);
    final future = controller.seekTo(
      Duration(milliseconds: (target * 1000).round()),
    );
    unawaited(
      future.catchError((_) {}).whenComplete(() {
        if (!mounted || token != _seekToken) return;
        _seeking = false;
        final now = DateTime.now().millisecondsSinceEpoch;
        _stalled = false;
        _lastProgressPositionMs = controller.value.position.inMilliseconds;
        _lastProgressAt = now;
        _seekGuardUntil = now + togetherSeekCooldownMs;
      }),
    );
  }

  /// 自己在房间成员列表里的序号（房主 / 还没拿到成员表时为 0）。
  ///
  /// 只用来算硬 seek 错峰：序号越靠后等得越久，N 个成员就不会同时去抢
  /// 服务端的首片中转槽位。
  int get _selfMemberIndex {
    final index = _members.indexWhere((member) => member.id == _myId);
    return index < 0 ? 0 : index;
  }

  /// 成员硬 seek 错峰：第 i 位延迟 i * 200ms（上限 2 秒）再跳。
  ///
  /// 等待期间只更新「还有一跳没做」这个状态，不重置截止时间 ——
  /// 心跳照常到来、照常更新 _remote，但不能把这段等待一直往后推。
  void _staggerHardSeek(TogetherRoomState state) {
    final delayMs = togetherSeekStaggerMs(_selfMemberIndex);
    if (delayMs <= 0) {
      _cancelStaggerSeek();
      _hardSeek(_targetPosition(state), state);
      return;
    }
    if (_staggerSeekTimer != null) return; // 已在等：目标到点按最新 state 取
    _staggerSeekTimer = Timer(Duration(milliseconds: delayMs), () {
      _staggerSeekTimer = null;
      if (!mounted || _isHost || _isLive) return;
      final remote = _remote;
      final controller = _controller;
      if (remote == null ||
          controller == null ||
          !controller.value.isInitialized) {
        return;
      }
      if (!_online || !_client.connected) return;
      // 到点用最新权威状态算目标：错峰期间房主可能又拖了一次。
      _hardSeek(_targetPosition(remote), remote);
    });
  }

  void _cancelStaggerSeek() {
    _staggerSeekTimer?.cancel();
    _staggerSeekTimer = null;
  }

  /// 收到新房主 state：先立即应用 play / pause / seek / rate，再做一次 drift 决策。
  void _applyRemoteState(
    TogetherRoomState state, {
    TogetherRoomState? prev,
    bool mediaChanged = false,
  }) {
    if (_isHost) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (mediaChanged) {
      // 新剧集 / 新线路由 _loadVideo 按最新 state 定位，避免先对旧流 seek。
      // 旧流上的错峰 seek 也一起作废，否则新流刚起来就被跳一下。
      _cancelStaggerSeek();
      _restoreBaseRate(state);
      _authStall = false;
      _stallHold = false;
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;

    // 1) 先分类这份权威变化：正常推进 / 房主主动 seek / 房主卡缓冲。
    //    旧逻辑只要偏差 >0.5s 就当 seek 硬跳，房主缓冲一下成员就被拉回去。
    final verdict = prev == null
        ? const TogetherAuthorityVerdict(change: TogetherAuthorityChange.normal)
        : classifyTogetherAuthority(
            prevPosition: prev.position,
            prevServerTime: prev.serverTime,
            prevPlaying: prev.playing,
            prevRate: prev.rate,
            position: state.position,
            serverTime: state.serverTime,
            playing: state.playing,
          );
    if (verdict.isStall) {
      _authStall = true;
      _authStallAt = now;
      _aheadSince = 0;
    } else if (_authStall &&
        (verdict.isSeek ||
            !state.playing ||
            (verdict.gapMs >= togetherStallMinGapMs &&
                verdict.advance >=
                    togetherStallAdvanceRatio *
                        (verdict.gapMs / 1000.0) *
                        _baseRate(state)) ||
            now - _authStallAt > togetherStallTimeoutMs)) {
      // 房主恢复推进 / 主动拖动 / 暂停 / 停滞超时：恢复正常外推对齐。
      _authStall = false;
    }

    final wantPlay = state.playing;
    final expected = _targetPosition(state);
    final current = controller.value.position.inMilliseconds / 1000.0;
    final drift = expected - current;
    final modeChanged = prev == null ||
        prev.playing != state.playing ||
        (prev.rate - state.rate).abs() > 0.001;

    // 2) 房主停滞期间的保持策略：期望进度冻结后成员会越跑越前，
    //    落后太多就原地暂停，等房主追上再恢复——全程不往回跳。
    _syncStallHold(state, now: now, authoritySeek: verdict.isSeek);

    // 3) 跟随房主 play / pause（保持中只允许暂停）。
    _followPlayIntent(state);
    _applyHoldUntil = now + 400;
    if (!wantPlay) _restoreBaseRate(state);

    // 4) 房主在缓冲：不 seek、不追进度，先照常播着（或维持保持），
    //    等房主恢复后自然收敛。
    if (verdict.isStall) {
      _restoreBaseRate(state);
      return;
    }

    // 5) 明确的房主主动 seek：硬跳到权威位置，不受上一次 seek 防抖限制。
    //    成员按自己的序号错峰（0 / 200 / 400… ms，上限 2 秒），
    //    避免所有人在同一帧一起抢 /api/seg 的首片中转槽位。
    if (verdict.isSeek) {
      _stallHold = false;
      _followPlayIntent(state);
      _staggerHardSeek(state);
      return;
    }

    if (_stallHold) {
      _restoreBaseRate(state);
      return;
    }
    if (modeChanged && !wantPlay) {
      // A host pause is an explicit position command, not periodic recovery.
      // Apply it once even if the old local progress detector marked a stall.
      if (drift.abs() >= togetherDriftDeadband) {
        _hardSeek(state.position, state);
      }
      return;
    }
    if (controller.value.isBuffering || _stalled) {
      _bufferingHold = true;
      _restoreBaseRate(state);
      return;
    }
    if (modeChanged) {
      if (drift.abs() > togetherDriftSeek) {
        if (_allowBackSeek(expected, current, now)) {
          _hardSeek(expected, state);
          return;
        }
        // 成员领先的一侧：先降速吸收，不立刻回跳。
        if (state.playing) {
          _setMicroRate(_microRateFor(state, drift), state);
        } else {
          _restoreBaseRate(state);
        }
        return;
      }
      if (drift.abs() >= togetherDriftDeadband) {
        _setMicroRate(_microRateFor(state, drift), state);
        return;
      }
      _restoreBaseRate(state);
      return;
    }
    if (now < _applyHoldUntil || now < _seekGuardUntil || _seeking) return;
    _correctDrift(state);
  }

  void _markRemote(String playback, double position, {double? rate}) {
    final state = _remote;
    if (state == null) return;
    final playing = playback == 'play';
    final ended = playback == 'ended';
    final changed = state.playing != playing || state.ended != ended;
    _remote = state.copyWith(
      playing: playing,
      ended: ended,
      position: position,
      serverTime: _client.nowServerMs(),
      rate: rate,
    );
    if (changed && mounted) setState(() {});
    if (mounted) _position.value = position;
  }

  /// 房主广播进度前的净化：正常播放时不让权威 position 因读数抖动往回走。
  ///
  /// 段重载 / 关键帧对齐会让播放器读数短暂回退（或停在旧位置），若照原样
  /// 上报，成员端的权威进度就会跟着来回跳（48→50→49→51）。这里只冻结上报
  /// 值、不造假位置：读数一旦真的往回拖（持续超过
  /// togetherHostBacktrackGraceMs），照样如实上报，成员端会把它当成房主
  /// 主动 seek 去对齐。
  double _sanitizeHostPosition(
    String state,
    double position, {
    bool fresh = false,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final anchorOk = _hostReportedPos >= 0 &&
        _hostReportedAt > 0 &&
        _hostReportedState == 'play';
    if (_isLive ||
        state != 'play' ||
        fresh ||
        !anchorOk ||
        !position.isFinite ||
        position < 0) {
      _setHostReportAnchor(state, position, now, clearBacktrack: true);
      return position;
    }
    if (position >= _hostReportedPos) {
      _setHostReportAnchor(state, position, now, clearBacktrack: true);
      return position;
    }
    // 读数回退：先按上一次广播的值上报（等价于 position 停住），
    // 成员端会判成房主停滞而不是被拉回去。
    if (_hostBacktrackAt == 0) {
      _hostBacktrackAt = now;
    } else if (now - _hostBacktrackAt >= togetherHostBacktrackGraceMs) {
      // 持续回退 = 房主真的往回拖（或真实回退），如实上报让成员对齐。
      _setHostReportAnchor(state, position, now, clearBacktrack: true);
      return position;
    }
    _hostReportedAt = now;
    _hostReportedState = state;
    _hostReportFresh = false;
    return _hostReportedPos;
  }

  void _setHostReportAnchor(
    String state,
    double position,
    int now, {
    required bool clearBacktrack,
  }) {
    _hostReportedPos = position;
    _hostReportedAt = now;
    _hostReportedState = state;
    _hostReportFresh = false;
    if (clearBacktrack) _hostBacktrackAt = 0;
  }

  /// 房主主动拖过进度：下一次上报直接用原始读数，并把锚点挪到拖动目标。
  void _noteHostSeek(double target) {
    _setHostReportAnchor(
      _remote?.playing == true ? 'play' : 'pause',
      target,
      DateTime.now().millisecondsSinceEpoch,
      clearBacktrack: true,
    );
    _hostReportFresh = true;
  }

  /// 房主广播一份进度状态：净化 → 发送 →（可选）同步本地权威镜像。
  /// 返回真正发出去的 position。
  ///
  /// [coalesce] 为真时交给客户端 200ms 合并窗口（拖拽进度这种高频操作）：
  /// 窗口内只发最后一次，服务端 rev 递增与成员 seq gate 都不受影响。
  double _reportHostState(
    String state,
    double position, {
    String? videoId,
    int? ep,
    String? line,
    double? rate,
    bool fresh = false,
    bool mark = true,
    bool coalesce = false,
  }) {
    final safe = _sanitizeHostPosition(
      state,
      position,
      fresh: fresh || _hostReportFresh,
    );
    // 房主操作一律立刻推 room_state（不等心跳）；合并窗口只削掉拖拽途中的
    // 中间态。本地镜像要按原始目标立即更新，不能等窗口到点。
    if (_online) {
      _client.sendState(
        state,
        safe,
        videoId: videoId,
        ep: ep,
        line: line,
        rate: rate,
        coalesce: coalesce,
      );
    }
    if (mark) _markRemote(state, safe, rate: rate);
    return safe;
  }

  /// 房主进度按 [_pushIntervalMs] 节流推送。
  ///
  /// 只在「真的在播、位置有推进」时推：暂停 / 缓冲由 _watchHostBuffering
  /// 和播放事件负责，这里重复推反而会让成员端 seq 乱跳。
  ///
  /// 为什么需要它：9 秒心跳太慢。成员靠 `position + 本地时钟外推` 追进度，
  /// 房主侧时钟和网络抖动累积到 9 秒会偏出几百毫秒，纠偏就得硬 seek，
  /// 表现就是「卡一下」。1.5 秒推一次能把偏差压在几十毫秒内，基本不用 seek。
  void _pushHostProgressThrottled() {
    if (!_isHost || _isLive || !_online || !_foreground) return;
    final controller = _controller;
    if (controller == null) return;
    final value = controller.value;
    if (!value.isInitialized || !value.isPlaying || value.isBuffering) return;
    if (_endedSent || _seeking) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    // 自适应：连接质量差时拉长间隔，避免消息在弱网里排队（排队比不同步更糟）。
    // 咕噜的 room_filter_public_speed_* 也是同一思路：按带宽决定推送频率。
    final interval = _pushIntervalMs * _pushIntervalFactor;
    if (now - _lastHostPushAt < interval) return;
    _lastHostPushAt = now;
    _reportHostState(
      'play',
      value.position.inMilliseconds / 1000.0,
      rate: _hostRate,
      mark: false,
    );
  }

  /// 房主缓冲上报：缓冲开始 / 结束各立即报一次，缓冲期间每秒报一次
  /// 停住的 position（9 秒心跳太慢，成员会先跑飞再被拉回来）。
  void _watchHostBuffering() {
    final controller = _controller;
    if (controller == null || !_isHost || _isLive || !_online) return;
    final value = controller.value;
    if (!value.isInitialized || _endedSent) return;
    // 用「最后广播的播放意图」判断该不该报：缓冲期间 isPlaying 可能被内核
    // 置 false，但房主仍处于播放态，成员需要每秒收到停住的 position。
    final intent = _remote?.playing ?? value.isPlaying;
    final buffering = value.isBuffering && intent;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (buffering == _hostBuffering) {
      // 状态没变：只在「持续缓冲」时按 1 秒节流补报停住的进度。
      if (!buffering || now - _hostBufferReportAt < 1000) return;
    }
    _hostBuffering = buffering;
    _hostBufferReportAt = now;
    // Buffering ending because the host pressed pause is not a new play
    // command. Preserve the last explicit room intent on that transition.
    _reportHostState(
      intent ? 'play' : 'pause',
      value.position.inMilliseconds / 1000.0,
    );
  }

  void _bounceToAuthority() {
    final state = _remote;
    if (state == null) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    _hardSeek(_targetPosition(state), state);
    if (state.playing) {
      unawaited(controller.play().catchError((_) {}));
    } else {
      unawaited(controller.pause().catchError((_) {}));
    }
    _tick(force: true);
  }

  void _onVideoValue() {
    final controller = _controller;
    if (controller == null || !mounted) return;
    final value = controller.value;
    if (_hasFirstFrame(value)) _cancelLiveFirstFrameTimer();
    _maybeFadeFrozenFrame();
    if (value.hasError && _videoError.isEmpty) {
      _cancelLiveFirstFrameTimer();
      _clearFrozenFrame();
      setState(() => _videoError = '播放中断，点重试即可恢复');
      return;
    }
    if (_isLive) return; // 直播流没有「播放结束」和观看进度。
    _watchHostBuffering();
    if (_endedSent || !_isHost || !value.isInitialized) return;
    if (value.duration.inMilliseconds <= 0) return;
    if (value.position >= value.duration - const Duration(milliseconds: 400)) {
      _endedSent = true;
      final position = value.position.inMilliseconds / 1000.0;
      _reportHostState('ended', position);
      if (mounted) setState(() {});
    }
  }

  /* ------------------------------------------------------------ 播放操作 */

  void _hostOnly() {
    fxShowTopTag('跟随房主');
  }

  void _togglePlay() {
    if (!_isHost) {
      _hostOnly();
      return;
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    if (_isLive) {
      final next = !controller.value.isPlaying;
      if (next) {
        controller.play().catchError((_) {});
      } else {
        controller.pause().catchError((_) {});
      }
      _sendLiveState(next);
      if (mounted) setState(() {});
      return;
    }
    final position = controller.value.position.inMilliseconds / 1000.0;
    if (controller.value.isPlaying) {
      controller.pause().catchError((_) {});
      _reportHostState('pause', position, rate: _hostRate);
      if (mounted) setState(() {});
      return;
    }
    final ended = _endedSent ||
        (controller.value.duration > Duration.zero &&
            controller.value.position >=
                controller.value.duration - const Duration(milliseconds: 400));
    if (ended) _seekController(0);
    _endedSent = false;
    final start = ended ? 0.0 : position;
    controller.play().catchError((_) {});
    // 从片尾重播会把 position 拉回 0：这是主动重播，不能被当成读数回退。
    _reportHostState('play', start, rate: _hostRate, fresh: ended);
    if (mounted) setState(() {});
  }

  void _seekTo(double seconds) {
    if (_isLive) {
      return;
    }
    if (!_isHost) {
      _hostOnly();
      _bounceToAuthority();
      return;
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    var target = seconds;
    if (!target.isFinite || target < 0) target = 0;
    final duration = controller.value.duration.inMilliseconds / 1000.0;
    if (duration > 0 && target > duration) target = duration;
    _seekController(target);
    _endedSent = false;
    // 主动拖动进度：把锚点挪到目标，别让后续上报被当成读数回退冻结。
    _noteHostSeek(target);
    if (_online) {
      // 房主自己拖动：立刻推一次权威 room_state，不等 9 秒心跳。
      // 以前这里发的是只带 position 的 `seek`，成员要等下一次 state 才敢跳，
      // 表现就是「房主拖完 1~3 秒，成员才跳过去」。
      // 走 `state` 通道后服务端照常递增 rev，成员 seq gate 判重逻辑不变；
      // 连续拖拽由客户端 200ms 合并窗口收口，只推最后一次。
      _reportHostState(
        _remote?.playing == true ? 'play' : 'pause',
        target,
        rate: _hostRate,
        fresh: true,
        coalesce: true,
      );
    }
    if (mounted) _position.value = target;
  }

  void _seekBy(int seconds) {
    if (_isLive) {
      return;
    }
    if (!_isHost) {
      _hostOnly();
      _bounceToAuthority();
      return;
    }
    _seekTo(_displayPosition() + seconds);
  }

  void _setHostRate(double rate) {
    if (!_isHost) {
      _hostOnly();
      return;
    }
    if (_isLive) {
      return;
    }
    final value = rate.clamp(.5, 2.0).toDouble();
    _hostRate = value;
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;
    final position = ready
        ? controller.value.position.inMilliseconds / 1000.0
        : _displayPosition();
    final playing =
        ready ? controller.value.isPlaying : (_remote?.playing ?? false);
    if (ready) {
      _lastRequestedRate = value;
      controller.setRate(value).catchError((_) {});
    }
    // 倍速也是房主操作：立即广播，成员同帧跟随。
    _reportHostState(playing ? 'play' : 'pause', position, rate: value);
    if (mounted) setState(() {});
  }

  /* ------------------------------------------------------------ 换剧 / 选集 / 清晰度 / 线路 */

  String get _epLabel {
    for (final episode in _episodes) {
      if (episode.n == _ep) return fxEpisodeLabel(episode.n, episode.name);
    }
    return fxEpisodeLabel(_ep);
  }

  String get _currentQualityLabel {
    final key = _qualityKey;
    if (key == null) return '默认';
    for (final item in _playInfo?.quality ?? const <QualityItem>[]) {
      if (item.key == key) {
        final name = item.name.trim();
        return name.isEmpty ? item.key : name;
      }
    }
    return key;
  }

  String get _currentLineLabel {
    for (final line in _lines) {
      if (line.id == _videoLine) {
        final name = line.displayName.trim();
        return name.isEmpty ? line.id : name;
      }
    }
    return _videoLine.isEmpty ? '默认线路' : _videoLine;
  }

  Future<void> _showMediaSheet() async {
    if (!_isHost) {
      _hostOnly();
      return;
    }
    final qualities = _playInfo?.quality ?? const <QualityItem>[];
    // TOGETHER_ALL_LINES（2026-11-14）：不再剔除 needsParse 线路。
    // 幻想4K / 幻想自建 都属于「需要解析」，之前一起看把它们全过滤了，
    // 用户看到的就是「一起看没有 4K、线路比播放页少」。
    // 普通播放页并不做这个过滤，两边保持一致。
    final playableLines = _lines.toList();
    final action = await showTogetherRoomMenu(
      context,
      epLabel: _epLabel,
      qualityLabel: _currentQualityLabel,
      lineLabel: _currentLineLabel,
      rate: _hostRate,
      hasEpisodes: _episodes.isNotEmpty,
      hasQuality: qualities.length >= 2,
      hasLines: playableLines.length >= 2,
    );
    if (!mounted || action == null) return;
    switch (action) {
      case TogetherRoomMenuAction.episodes:
        await _pickEpisode();
      case TogetherRoomMenuAction.changeDrama:
        await _pickDrama();
      case TogetherRoomMenuAction.quality:
        await _pickQuality();
      case TogetherRoomMenuAction.line:
        await _pickLine();
      case TogetherRoomMenuAction.speed:
        await _pickSpeed();
    }
  }

  Future<void> _pickDrama() async {
    if (!_isHost) {
      _hostOnly();
      return;
    }
    final card = await showTogetherVideoPicker(context);
    if (!mounted || card == null) return;
    // 选片后必须先选集：服务端 room_state 只负责同步，不能替用户默认第 1 集。
    final detail = await _fetchDetailForPicker(card.id);
    if (!mounted) return;
    final episodes = _episodesForPicker(detail, card);
    final episode = await _pickEpisodeFor(card, episodes);
    if (!mounted) return;
    if (!_online) {
      return;
    }
    // 换剧视为「继续播放」：切换前暂停才保持暂停。
    final playing = _controller?.value.isPlaying ?? (_remote?.playing ?? true);
    // 没有详情时留空，交给 _loadVideo 重新拉详情后再定线路；
    // 写死 'l1' 会让切剧后线路对不上（服务端没有这个 id）。
    final lineId = detail != null && detail.lines.isNotEmpty
        ? detail.lines.first.id
        : '';
    // 房主本地立即切到新片，再广播 room_state；其它成员收到后重新拉流。
    // 最后一帧由 _loadVideo 抓取，切剧不黑屏。
    setState(() {
      _videoId = card.id;
      _ep = episode;
      _videoLine = lineId;
      _videoTitle = card.title;
      _videoCover = togetherCoverUrl(card.cover);
      _episodes = episodes;
      _lines = detail?.lines ?? const <LineInfo>[];
      _detailVideoId = detail == null ? '' : card.id;
      _qualityKey = null;
      _playInfo = null;
      _videoError = '';
      _resumePos = 0;
      _resumePlaying = playing;
      _endedSent = false;
    });
    _loadedKey = '';
    _loadingKey = '';
    _reportHostState(
      playing ? 'play' : 'pause',
      0,
      videoId: card.id,
      ep: episode,
      line: lineId,
      rate: _hostRate,
      fresh: true,
      mark: false,
    );
    _syncVideo();
  }

  /// 选片弹层用：拿详情补真实集数；失败时退回卡片自带的集数。
  Future<VideoDetail?> _fetchDetailForPicker(String videoId) async {
    try {
      return await CmsBridge.detail(videoId);
    } catch (_) {
      return null;
    }
  }

  List<Episode> _episodesForPicker(VideoDetail? detail, VideoCard card) {
    final real = detail?.allEpisodes ?? const <Episode>[];
    if (real.isNotEmpty) return real;
    final detailCount = detail?.episodes ?? 0;
    final count = detailCount > 0 ? detailCount : card.episodes;
    if (count <= 0) return const <Episode>[];
    return <Episode>[for (var i = 1; i <= count; i++) Episode(i, '', 0)];
  }

  /// 选完片先弹一次选集面板；直接关闭 / 下滑取消时默认第 1 集。
  Future<int> _pickEpisodeFor(VideoCard card, List<Episode> episodes) async {
    final picked = await showTogetherEpisodePicker(
      context,
      episodes: episodes,
      current: 1,
      title: card.title,
    );
    return picked ?? 1;
  }

  Future<void> _pickEpisode() async {
    if (_isLive) {
      return;
    }
    if (!_isHost) {
      _hostOnly();
      return;
    }
    if (_episodes.isEmpty) {
      return;
    }
    final episode = await showTogetherEpisodePicker(
      context,
      episodes: _episodes,
      current: _ep,
      title: _videoTitle,
    );
    if (!mounted || episode == null || episode == _ep) return;
    if (!_online) {
      return;
    }
    // 服务端 episode 动作会重置为 pause；这里带播放意图发 state，
    // 切集视为继续播放，只有切换前确实暂停才保持暂停。
    final playing = _controller?.value.isPlaying ?? (_remote?.playing ?? true);
    _resumePos = 0;
    _resumePlaying = playing;
    _reportHostState(
      playing ? 'play' : 'pause',
      0,
      ep: episode,
      line: _videoLine,
      rate: _hostRate,
      fresh: true,
      mark: false,
    );
  }

  void _nextEpisode() {
    if (_isLive) {
      return;
    }
    if (!_isHost) {
      _hostOnly();
      return;
    }
    if (_episodes.isEmpty) {
      return;
    }
    final main = _episodes.where((e) => !fxIsExtraEpisode(e.name)).toList();
    final list = main.isEmpty ? _episodes : main;
    int? next;
    for (final episode in list) {
      if (episode.n > _ep) {
        next = episode.n;
        break;
      }
    }
    if (next == null) {
      return;
    }
    if (!_online) {
      return;
    }
    final playing = _controller?.value.isPlaying ?? (_remote?.playing ?? true);
    _resumePos = 0;
    _resumePlaying = playing;
    _reportHostState(
      playing ? 'play' : 'pause',
      0,
      ep: next,
      line: _videoLine,
      rate: _hostRate,
      fresh: true,
      mark: false,
    );
  }

  Future<void> _pickQuality() async {
    if (_isLive) {
      await _pickLiveLine();
      return;
    }
    if (!_isHost) {
      _hostOnly();
      return;
    }
    final items = _playInfo?.quality ?? const <QualityItem>[];
    if (items.length < 2) {
      return;
    }
    final picked = await showTogetherQualitySheet(
      context,
      items: items,
      currentKey: _qualityKey,
    );
    if (!mounted || picked == null) return;
    await _setQuality(picked == togetherDefaultQualityKey ? null : picked);
  }

  /// 直播线路切换：房主广播 lineId，成员收到 changedLine 后重新拉流。
  Future<void> _pickLiveLine() async {
    if (!_isHost) {
      _hostOnly();
      return;
    }
    final channel = _liveChannel;
    final lines = channel?.lines ?? const <LiveLine>[];
    if (lines.length < 2) {
      return;
    }
    final infos = <LineInfo>[
      for (var i = 0; i < lines.length; i++)
        LineInfo(
          lines[i].id,
          '${lines[i].qualityLabel} · ${lines[i].subtitle(i)}',
          'hls',
          0,
        ),
    ];
    final picked = await showTogetherLineSheet(
      context,
      lines: infos,
      current: _liveLineId,
    );
    if (!mounted || picked == null || picked == _liveLineId) return;
    await _setLiveLine(picked);
  }

  Future<void> _setLiveLine(String lineId) async {
    if (!_isHost) {
      _hostOnly();
      return;
    }
    if (lineId == _liveLineId) return;
    if (!_online) {
      return;
    }
    setState(() {
      _liveLineId = lineId;
      _videoLine = lineId;
      _videoError = '';
    });
    _loadedKey = '';
    _loadingKey = '';
    _syncVideo();
    // 换线路不能把房主的暂停态「换」成播放：优先跟随当前播放器，
    // 播放器还没就绪时用最近一次广播的状态。
    final playing = _controller?.value.isPlaying ?? _livePlaying;
    _livePlaying = playing;
    _client.sendState(playing ? 'play' : 'pause', 0, line: lineId, live: true);
    _markRemote(playing ? 'play' : 'pause', 0);
  }

  Future<void> _setQuality(String? key) async {
    if (_isLive) {
      if (key != null) await _setLiveLine(key);
      return;
    }
    if (!_isHost) {
      _hostOnly();
      return;
    }
    if (key == _qualityKey) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    _resumePos = controller.value.position.inMilliseconds / 1000.0;
    _resumePlaying = controller.value.isPlaying;
    setState(() => _qualityKey = key);
    _loadedKey = '';
    _loadingKey = '';
    _syncVideo();
  }

  Future<void> _pickLine() async {
    if (_isLive) {
      await _pickLiveLine();
      return;
    }
    if (!_isHost) {
      _hostOnly();
      return;
    }
    if (_lines.isEmpty && _videoId.isNotEmpty) {
      await _ensureDetail(_videoId);
      if (!mounted) return;
    }
    final playable = _lines.toList();
    if (playable.length < 2) {
      return;
    }
    final picked = await showTogetherLineSheet(
      context,
      lines: playable,
      current: _videoLine,
    );
    if (!mounted || picked == null || picked == _videoLine) return;
    if (!_online) {
      return;
    }
    final controller = _controller;
    final position = controller != null && controller.value.isInitialized
        ? controller.value.position.inMilliseconds / 1000.0
        : _displayPosition();
    final playing = controller != null && controller.value.isInitialized
        ? controller.value.isPlaying
        : (_remote?.playing == true);
    if (controller != null && controller.value.isInitialized) {
      _resumePos = position;
      _resumePlaying = playing;
    }
    setState(() {
      _videoLine = picked;
      _qualityKey = null;
      _playInfo = null;
    });
    _loadedKey = '';
    _loadingKey = '';
    _syncVideo();
    _reportHostState(
      playing ? 'play' : 'pause',
      position,
      videoId: _videoId,
      ep: _ep,
      line: picked,
      rate: _hostRate,
      fresh: true,
      mark: false,
    );
  }

  Future<void> _pickSpeed() async {
    if (!_isHost) {
      _hostOnly();
      return;
    }
    final picked = await showTogetherSpeedSheet(context, current: _hostRate);
    if (!mounted || picked == null) return;
    _setHostRate(picked);
  }

  /* ------------------------------------------------------------ 邀请 / 成员 */

  Future<void> _showInvite() async {
    await showTogetherInvite(
      context,
      code: _roomCode,
      title: _videoTitle.isNotEmpty ? _videoTitle : _roomTitle,
    );
  }

  Future<void> _showMembers() async {
    if (!mounted) return;
    await showTogetherMembers(
      context,
      members: _members,
      membersLive: _membersLive,
    );
  }

  /* ------------------------------------------------------------ 视频加载 */

  Future<void> _loadVideoTitle(String videoId) async {
    await _ensureDetail(videoId);
  }

  Future<void> _ensureDetail(String videoId) async {
    if (videoId.isEmpty) return;
    // 同一个视频正在加载详情：等待同一个 Future，避免第二个调用者
    // 看到 _lines 还是空的就去用默认线路播放。
    if (_detailVideoId == videoId) {
      final pending = _detailPending;
      if (pending != null) await pending;
      return;
    }
    _detailVideoId = videoId;
    final future = _fetchDetail(videoId);
    _detailPending = future;
    try {
      await future;
    } finally {
      if (identical(_detailPending, future)) _detailPending = null;
    }
  }

  Future<void> _fetchDetail(String videoId) async {
    try {
      final detail = await CmsBridge.detail(videoId);
      if (!mounted || _videoId != videoId) return;
      setState(() {
        _lines = detail.lines;
        _episodes = detail.allEpisodes;
        if (detail.title.isNotEmpty) _videoTitle = detail.title;
        if (detail.cover.isNotEmpty) {
          _videoCover = togetherCoverUrl(detail.cover);
        }
      });
    } catch (_) {
      if (_detailVideoId == videoId && _lines.isEmpty) {
        _detailVideoId = '';
      }
    }
  }

  /// 无感救援链第③步：本台前两步自救失败后，换下一条线路的地址。
  /// 只更新线路 id 并返回新地址，不重新 open（播放器自己换流），
  /// 每条线路每轮只试一次；本轮全部试完返回 null，交给三步全败。
  Future<FxLineSource?> _nextLiveLineSource(
    LiveChannel channel,
    LiveLine current,
    int seq,
  ) async {
    if (!mounted || seq != _videoSeq) return null;
    final lines = channel.lines;
    if (lines.length < 2) return null;
    if (!_liveRescueTried.contains(current.id)) {
      _liveRescueTried.add(current.id);
    }
    final index = lines.indexWhere((line) => line.id == current.id);
    for (var k = 1; k <= lines.length; k++) {
      final next = lines[(index + k) % lines.length];
      if (next.id == current.id || next.url.trim().isEmpty) continue;
      if (_liveRescueTried.contains(next.id)) continue;
      _liveRescueTried.add(next.id);
      if (!mounted || seq != _videoSeq) return null;
      // 线路卡跟着换，界面显示与实际线路保持一致（不重新 open）。
      setState(() {
        _liveLineId = next.id;
        _videoLine = next.id;
      });
      return FxLineSource(url: next.url.trim());
    }
    return null;
  }

  /// 直播拉流：没有 seek / 进度，open 后直接播到最新位置。
  ///
  /// 成员跟随房主的 lineId；线路变化、暂停恢复、卡顿、重连都走这里重新拉流，
  /// 相当于「回到直播边缘」。
  Future<void> _loadLiveVideo() async {
    final channel = _liveChannel;
    if (channel == null) return;
    final line = _liveLine;
    if (line == null || line.url.trim().isEmpty) {
      _cancelLiveFirstFrameTimer();
      if (mounted) {
        setState(() {
          _videoLoading = false;
          _videoError = '该频道暂无可用直播线路';
        });
      }
      return;
    }
    final key = 'live|${channel.id}|${line.id}';
    if (!_liveJumping && (key == _loadedKey || key == _loadingKey)) return;
    _loadingKey = key;
    final seq = ++_videoSeq;
    _liveRescueTried.clear();
    _endedSent = false;
    // 本次拉流是否已作废（页面销毁 / 被换线、重连的新请求取代）。
    bool stale() => !mounted || seq != _videoSeq;
    _cancelLiveFirstFrameTimer();

    // 换台 / 换线路前先抓下旧画面：新流首帧出来前用快照顶住，
    // 不让房间在加载的几秒里变成纯黑。
    final frozen = await _captureVideoFrame();
    if (stale()) {
      frozen?.dispose();
      return;
    }
    if (frozen != null) _showFrozenFrame(frozen);

    final previous = _controller;
    _controller = null;
    previous?.removeListener(_onVideoValue);
    _position.value = 0;
    if (mounted) {
      setState(() {
        _videoLoading = true;
        _videoError = '';
      });
    }
    if (previous != null) await _releasePlayer(previous);
    if (stale()) return;

    // 直播默认在播；房主暂停时沿用本地状态，成员以最新 room_state 为准。
    // 这里先记下期望值，open 完成后还会再取一次，避免加载期间房主切了状态。
    final shouldPlay = _isHost ? _livePlaying : (_remote?.playing ?? true);
    _armLiveFirstFrameTimeout(seq);
    FxPlayer? controller;
    try {
      controller = FxPlayer.create(readyTimeout: const Duration(seconds: 20));
      await controller.open(
        line.url,
        play: shouldPlay,
        // 无感救援链第③步（与直播详情页一致）：前两步自救失败后按本台
        // 线路表轮换，播放器自己换流、不打断观看，日志走 FX RESCUE。
        rescueLines: () async => _nextLiveLineSource(channel, line, seq),
      );
      if (stale()) {
        await _dropLivePlayer(controller);
        return;
      }
      await controller.setLooping(false).catchError((_) {});
      await controller.setRate(1).catchError((_) {});
      if (stale()) {
        await _dropLivePlayer(controller);
        return;
      }

      // open(play:true) 只负责起播意图：ready 之后必须再显式 play，
      // 否则部分直播源停在首帧不动，用户得手点一次播放。
      final wantPlay =
          _isHost ? _livePlaying : (_remote?.playing ?? shouldPlay);
      if (wantPlay) {
        await controller.play().catchError((_) {});
      } else {
        // 暂停态也先拉一帧，避免房主暂停后成员看到纯黑。
        await controller.play().catchError((_) {});
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await controller.pause().catchError((_) {});
      }
      if (stale()) {
        await _dropLivePlayer(controller);
        return;
      }

      final old = _controller;
      old?.removeListener(_onVideoValue);
      _controller = controller;
      controller.addListener(_onVideoValue);
      if (old != null) unawaited(old.dispose());
      if (_hasFirstFrame(controller.value)) {
        _cancelLiveFirstFrameTimer();
      }
      _maybeFadeFrozenFrame();
      _loadedKey = key;
      _loadingKey = '';
      _liveLastPosMs = -1;
      _liveLastProgressAt = DateTime.now().millisecondsSinceEpoch;
      _position.value = 0;
      setState(() {
        _videoLoading = false;
        _videoError = '';
      });
      debugPrint(
        'room autoplay ep=$_ep state=${wantPlay ? 'playing' : 'paused'} live=1',
      );
      // 房主重新拉流后广播当前播放状态，成员跟着对齐。
      if (_isHost) _sendLiveState(wantPlay);
      _applyLiveRemote(_remote ?? _emptyLiveState(), _remote);
    } catch (_) {
      // 失败也要先把本次创建（可能已挂到 _controller）的实例释放掉，
      // 再决定是否展示错误，避免卡顿重连叠加时遗留孤儿播放器。
      if (controller != null) await _dropLivePlayer(controller);
      if (stale()) return;
      _cancelLiveFirstFrameTimer();
      _clearFrozenFrame();
      _loadingKey = '';
      _loadedKey = '';
      setState(() {
        _videoLoading = false;
        _videoError = '直播源加载失败，请重试';
      });
    }
  }

  /// 直播首帧兜底：10 秒还没有画面参数就放弃本次拉流并显示重试入口，
  /// 不让用户对着冻结的旧画面一直等。
  void _armLiveFirstFrameTimeout(int seq) {
    _cancelLiveFirstFrameTimer();
    _liveFirstFrameTimer = Timer(_liveFirstFrameTimeout, () {
      _liveFirstFrameTimer = null;
      if (!mounted || seq != _videoSeq) return;
      final controller = _controller;
      if (controller != null && _hasFirstFrame(controller.value)) return;
      // 作废还在 open 中的请求；已挂上的播放器直接释放，交给重试重建。
      _videoSeq++;
      _loadingKey = '';
      _loadedKey = '';
      final pending = _controller;
      _controller = null;
      if (pending != null) {
        pending.removeListener(_onVideoValue);
        unawaited(_releasePlayer(pending));
      }
      _clearFrozenFrame();
      if (!mounted) return;
      setState(() {
        _videoLoading = false;
        _videoError = '加载失败，重试';
      });
    });
  }

  void _cancelLiveFirstFrameTimer() {
    _liveFirstFrameTimer?.cancel();
    _liveFirstFrameTimer = null;
  }

  /// 直播拉流作废时释放本次创建的播放器。
  ///
  /// 此时它可能还没挂到 `_controller`（换线在 open 途中被打断），也可能
  /// 已经挂上（挂上后才被新的请求取代）；两种都要摘掉监听并释放。
  Future<void> _dropLivePlayer(FxPlayer player) async {
    player.removeListener(_onVideoValue);
    if (identical(_controller, player)) _controller = null;
    await _releasePlayer(player);
  }

  /// 成员刚进房还没收到 state 时的兜底：按播放处理。
  TogetherRoomState _emptyLiveState() => TogetherRoomState(
        code: _roomCode,
        title: _roomTitle,
        hostId: '',
        members: _members,
        videoId: _videoId,
        ep: 1,
        line: _liveLineId,
        playing: true,
        ended: false,
        position: 0,
        serverTime: 0,
        seq: 0,
        rate: 1,
        kind: 'live',
        liveChannel: _liveChannel,
      );

  void _syncVideo() {
    if (_isLive) {
      unawaited(_loadLiveVideo());
      return;
    }
    if (_videoId.isEmpty) return;
    final key = '$_videoId|$_ep|$_videoLine';
    if (key == _loadedKey || key == _loadingKey) return;
    unawaited(_loadVideo(_videoId, _ep, _videoLine));
  }

  /* ------------------------------------------------------ 最后一帧 / 淡入 */

  bool _hasFirstFrame(FxPlayerValue value) {
    if (!value.isInitialized) return false;
    final width = value.videoWidth ?? value.width ?? 0;
    final height = value.videoHeight ?? value.height ?? 0;
    return width > 0 && height > 0;
  }

  /// 抢在旧播放器释放前抓下当前画面；失败就返回 null，继续走原来的加载态。
  Future<ui.Image?> _captureVideoFrame() async {
    // 后台切集时没有新帧，等 endOfFrame 会卡住加载；直接跳过最后一帧。
    if (!_foreground) return null;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return null;
    try {
      await WidgetsBinding.instance.endOfFrame;
      final boundary = _videoBoundaryKey.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary) return null;
      if (boundary.debugNeedsPaint) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      return await boundary.toImage(pixelRatio: 1);
    } catch (_) {
      return null;
    }
  }

  void _showFrozenFrame(ui.Image frame) {
    _frozenFadeTimer?.cancel();
    _frozenFadeTimer = null;
    _frozenFallbackTimer?.cancel();
    final old = _frozenFrame;
    _frozenFrame = frame;
    _frozenFrameOpaque = true;
    if (mounted) setState(() {});
    // 旧帧可能还在淡出里，延后释放，避免正在绘制时被 dispose。
    if (old != null) {
      Future<void>.delayed(const Duration(milliseconds: 400), old.dispose);
    }
  }

  /// 新流首帧就绪：淡出最后一帧，让真实画面淡入。
  void _fadeOutFrozenFrame() {
    if (!_frozenFrameOpaque || _frozenFrame == null) return;
    _frozenFallbackTimer?.cancel();
    _frozenFallbackTimer = null;
    if (mounted) setState(() => _frozenFrameOpaque = false);
    _frozenFadeTimer?.cancel();
    _frozenFadeTimer = Timer(const Duration(milliseconds: 320), () {
      _frozenFadeTimer = null;
      _clearFrozenFrame();
    });
  }

  void _maybeFadeFrozenFrame() {
    final controller = _controller;
    if (controller == null || !_hasFirstFrame(controller.value)) return;
    _fadeOutFrozenFrame();
  }

  void _clearFrozenFrame() {
    _frozenFadeTimer?.cancel();
    _frozenFadeTimer = null;
    _frozenFallbackTimer?.cancel();
    _frozenFallbackTimer = null;
    final frame = _frozenFrame;
    _frozenFrame = null;
    _frozenFrameOpaque = false;
    if (mounted) setState(() {});
    if (frame != null) {
      Future<void>.delayed(const Duration(milliseconds: 60), frame.dispose);
    }
  }

  /// 本次 open 应该带的起始位置（秒）。
  ///
  /// 房主优先用「继续播放」的本地位置；成员用当前权威进度外推值。
  /// 只作为 open 的起始位置，真正的落位仍是 open 之后的 target 计算。
  double _desiredStartSeconds(double? localResumePos) {
    // 房主显式给过续播位置就以它为准（0 也是有效值：从开头播），
    // 不能退回去用房间进度，否则会先跳到房主进度再跳回 0。
    if (_isHost && localResumePos != null) {
      return localResumePos.isFinite && localResumePos > 0
          ? localResumePos
          : 0;
    }
    final state = _remote;
    if (state == null) return 0;
    final value = _targetPosition(state);
    if (!value.isFinite || value <= 0) return 0;
    return value;
  }

  Future<void> _loadVideo(String videoId, int ep, String line) async {
    final key = '$videoId|$ep|$line';
    _loadingKey = key;
    final seq = ++_videoSeq;
    _seekToken++;
    _seeking = false;
    _stalled = false;
    _bufferingHold = false;
    _authStall = false;
    _stallHold = false;
    _aheadSince = 0;
    _lastProgressAt = 0;
    _lastProgressPositionMs = 0;
    _endedSent = false;
    // 旧流上的错峰 seek 作废：新流由 open 的起始位置一次性定位。
    _cancelStaggerSeek();
    // 切剧 / 切集发起时记下本地的「继续播放」意图：加载期间 room_state
    // 可能先到并清掉 _resume*，不能让它把这次切换变成暂停。
    final localResumePos = _resumePos;
    final localResumePlaying = _resumePlaying;

    // 先抓最后一帧再摘旧 controller：切剧/切集/换线路不露出黑屏。
    final frozen = await _captureVideoFrame();
    if (!mounted || seq != _videoSeq) {
      frozen?.dispose();
      return;
    }
    if (frozen != null) _showFrozenFrame(frozen);

    // 摘掉旧 controller 并进入加载态，再异步 pause → stop → dispose，
    // 避免旧画面在释放期间继续渲染；最后一帧顶住这段空窗。
    final previous = _controller;
    _controller = null;
    previous?.removeListener(_onVideoValue);
    _position.value = 0;
    if (mounted) {
      setState(() {
        _videoLoading = true;
        _videoError = '';
      });
    }
    if (previous != null) await _releasePlayer(previous);
    if (!mounted || seq != _videoSeq) return;

    await _ensureDetail(videoId);
    if (!mounted || seq != _videoSeq) return;

    var playable = _lines.toList();
    if (playable.isEmpty) {
      // 详情拿不到时仍尝试一次默认线路，避免房间完全不可看。
      // 详情拿不到时仍尝试一次当前线路，避免房间完全不可看。
      // 注意：line 为空时不能用假 id（'l1'），否则 /api/play 必然失败；
      // 这种情况下直接不给兜底，让上层展示错误而不是播一个坏地址。
      playable = line.isEmpty
          ? <LineInfo>[]
          : <LineInfo>[LineInfo(line, '默认线路', 'hls', 0)];
    }
    final ordered = <LineInfo>[
      for (final item in playable)
        if (item.id == line) item,
      for (final item in playable)
        if (item.id != line) item,
    ];

    for (final lineInfo in ordered) {
      if (!mounted || seq != _videoSeq) return;
      PlayInfo play;
      try {
        play = await CmsBridge.play(videoId, ep, lineInfo.id);
      } catch (_) {
        continue;
      }
      if (!mounted || seq != _videoSeq) return;
      if (play.type.trim().toLowerCase() == 'parse') continue;
      _playInfo = play;

      // 统一补成绝对地址：站内相对路径补全后 mpv 能直连，
      // 不必再过客户端代理（代理是整片下完才播，4K 大分片会卡）。
      final urls = <String>[];
      final primary = fxAbsolutePlayUrl(_qualityUrl(play));
      if (primary.isNotEmpty) urls.add(primary);
      for (final raw in play.backup) {
        final url = fxAbsolutePlayUrl(raw);
        if (url.isNotEmpty && !urls.contains(url)) urls.add(url);
      }
      if (urls.isEmpty) continue;

      for (final url in urls) {
        if (!mounted || seq != _videoSeq) return;
        FxPlayer? controller;
        try {
          // 和主播放页用同一套起播超时策略：慢线路不再被 20 秒一刀切，
          // 只要还在下载就继续等（FxPlayer 内部按下载进展判定）。
          controller = FxPlayer.create();
          final qualityKey = _qualityKey;
          // 续播 / 跟房主进度：把起始位置直接交给 open（原生在 prepare 之前
          // seekTo），第一个分片请求就是目标片，不会先拉第 0 片把服务端
          // `/api/seg` 的首片中转名额用掉 —— 这就是「带 27:55 续播比从头播
          // 慢很多」的根因。
          await controller.open(
            url,
            headers: play.headers,
            isHls: play.isHls,
            startPosition: Duration(
              milliseconds: (_desiredStartSeconds(localResumePos) * 1000).round(),
            ),
            // 采集线路直连（让 mpv 边下边播），只有平台签名线路才走代理。
            // 一起看卡顿的主因就是这里：4K/大分片走代理要整片下完才播。
            // 按实际地址判断（腾讯直连是 CDN 绝对地址，不需要代理）。
            // 与主播放页一致：HLS 一律交给本地代理，才能享受整集预加载。
            direct: fxShouldUseHlsProxy(play.url, isHls: play.isHls),
            // Capture this load's media/line: a later room switch must not let
            // an old proxy refresh fetch or publish a different episode.
            refreshPlay: () =>
                _refreshTogetherUrl(videoId, ep, lineInfo.id, qualityKey, seq),
            // 无感救援链第③步：本线路 refresh / 重开都失败后自动换下一条，
            // 并 seek 回房主的进度。之前一起看点播没有这条，线路一坏就
            // 只能干等或退出房间重进。
            rescueLines: () =>
                _nextTogetherLineSource(videoId, ep, lineInfo, qualityKey, seq),
          );
          if (!mounted || seq != _videoSeq) {
            await _releasePlayer(controller);
            return;
          }
          await controller.setLooping(false);
          if (!mounted || seq != _videoSeq) {
            await _releasePlayer(controller);
            return;
          }

          final duration = controller.value.duration.inMilliseconds / 1000.0;
          final state = _remote;
          double target;
          bool shouldPlay;
          if (_isHost) {
            var resume = localResumePos;
            // 片尾窗口内的进度不续播，从头开始。房间散场常常发生在
            // 播到片尾时，这个进度会被带进下一次播放。
            if (resume != null && fxIsFinishedPosition(resume, duration)) {
              resume = 0;
            }
            if (resume != null) {
              target = resume;
              shouldPlay = localResumePlaying;
            } else if (state != null) {
              target = _targetPosition(state);
              shouldPlay = state.playing;
            } else {
              // 建房 / 首次进入没有 state 时默认播放，不能等用户点。
              target = 0;
              shouldPlay = true;
            }
          } else {
            target = state == null ? 0 : _targetPosition(state);
            // 成员严格跟随房主：房主暂停就停在权威位置，不先播再跳。
            shouldPlay = state?.playing ?? false;
          }
          if (!target.isFinite || target < 0) target = 0;
          if (duration > 0 && target > duration - 1) target = 0;
          // open 已经带着起始位置准备好了：落位正确就不再补跳
          // （补跳会把刚拉到的目标分片又丢一次）。
          final landed = controller.value.position.inMilliseconds / 1000.0;
          if (target > 0 && (landed - target).abs() > 1.0) {
            await controller.seekTo(
              Duration(milliseconds: (target * 1000).round()),
            );
          } else if (target <= 0 && landed > 1.0) {
            // 片尾窗口等情况下改成从头播：明确跳回 0。
            await controller.seekTo(Duration.zero);
          }
          final controllerRate = togetherClampRate(
            _isHost ? _hostRate : (_remote?.rate ?? 1.0),
          );
          await controller.setRate(controllerRate);
          // 打开成功即按房间 state 执行真正起播；open 只负责把流准备好，
          // 不能依赖用户再点一次播放按钮。
          var wantPlay = shouldPlay;
          if (!_isHost) wantPlay = _remote?.playing ?? shouldPlay;
          if (wantPlay) {
            await controller.play();
          } else {
            // 暂停态也先拉一帧，避免切集/切线路后黑屏；随后停回权威位置。
            await controller.play();
            await Future<void>.delayed(const Duration(milliseconds: 60));
            await controller.pause();
          }
          if (!mounted || seq != _videoSeq) {
            await _releasePlayer(controller);
            return;
          }

          final previous = _controller;
          previous?.removeListener(_onVideoValue);
          _controller = controller;
          controller.addListener(_onVideoValue);
          if (previous != null) unawaited(previous.dispose());
          _maybeFadeFrozenFrame();
          _frozenFallbackTimer?.cancel();
          if (_frozenFrame != null) {
            // 首帧参数迟迟不到（异常流）时兜底淡出，不能一直盖着。
            _frozenFallbackTimer = Timer(
              const Duration(seconds: 2),
              _fadeOutFrozenFrame,
            );
          }
          // 再补一次 play：某些内核在 attach 视频层后会退回 paused。
          if (wantPlay) {
            await controller.play().catchError((_) {});
          }
          debugPrint(
            'room autoplay ep=$_ep state=${wantPlay ? 'playing' : 'paused'}',
          );

          _resumePos = null;
          _resumePlaying = false;
          _loadingKey = '';
          // 当前线路不可用时沿 ordered 回退到备用线路；房间 lineId 仍保留
          // 房主选择的线路，避免服务器旧状态回跳导致重复拉流。
          _loadedKey = key;
          if (mounted) {
            setState(() {
              _videoLoading = false;
              _videoError = '';
            });
          }
          _position.value = target;
          _lastRequestedRate = controllerRate;
          if (!_isHost) {
            // 新流刚 seek 到权威位置：按最新 state 再对齐一次（加载期间房主
            // 可能又 seek 过），然后 2 秒内不再纠偏。
            _seeking = false;
            final remote = _remote;
            if (remote != null) _applyRemoteState(remote);
            _seekGuardUntil =
                DateTime.now().millisecondsSinceEpoch + togetherSeekCooldownMs;
          }
          return;
        } catch (_) {
          try {
            controller?.removeListener(_onVideoValue);
            if (identical(_controller, controller)) _controller = null;
            if (controller != null) await _releasePlayer(controller);
          } catch (_) {}
        }
      }
    }

    if (!mounted || seq != _videoSeq) return;
    _loadingKey = '';
    _loadedKey = '';
    _clearFrozenFrame();
    setState(() {
      _videoLoading = false;
      _videoError = '暂时无法播放，请重试或让房主切换线路';
    });
  }

  Future<String?> _refreshTogetherUrl(
    String videoId,
    int ep,
    String line,
    String? qualityKey,
    int seq,
  ) async {
    if (!mounted || seq != _videoSeq) return null;
    try {
      final play = await CmsBridge.play(videoId, ep, line, fresh: true);
      if (!mounted ||
          seq != _videoSeq ||
          play.type.trim().toLowerCase() == 'parse') {
        return null;
      }
      if (qualityKey != null) {
        for (final quality in play.quality) {
          if (quality.key == qualityKey && quality.url.trim().isNotEmpty) {
            // 换签后也要补成绝对地址，保持直连（否则新地址会退化成走代理）。
            return fxAbsolutePlayUrl(quality.url);
          }
        }
      }
      final url = fxAbsolutePlayUrl(play.url);
      return url.isEmpty ? null : url;
    } catch (_) {
      return null;
    }
  }

  /// 救援换线：当前线路彻底不可用时，按房间线路表顺延找下一条能出地址的，
  /// 并 seek 回房主的进度（由 FxPlayer 的救援链负责 seek）。
  ///
  /// 只在「本线路 refresh + 重开都失败」后才会被调用，属于最后一层兜底；
  /// 失败返回 null，播放器会把错误交给页面提示。
  Future<FxLineSource?> _nextTogetherLineSource(
    String videoId,
    int ep,
    LineInfo current,
    String? qualityKey,
    int seq,
  ) async {
    if (!mounted || seq != _videoSeq) return null;
    final lines = _lines;
    if (lines.length < 2) return null;
    final index = lines.indexWhere((l) => l.id == current.id);
    for (var k = 1; k <= lines.length; k++) {
      if (!mounted || seq != _videoSeq) return null;
      final next = lines[(index + k) % lines.length];
      if (next.id == current.id || next.id.trim().isEmpty) continue;
      try {
        final play = await CmsBridge.play(videoId, ep, next.id);
        if (!mounted || seq != _videoSeq) return null;
        if (play.type.trim().toLowerCase() == 'parse') continue;
        final url = fxAbsolutePlayUrl(_qualityUrlFor(play, qualityKey));
        if (url.isEmpty) continue;
        return FxLineSource(
          url: url,
          headers: play.headers,
          direct: fxShouldUseHlsProxy(play.url, isHls: play.isHls),
        );
      } catch (_) {
        // 这条也取不到地址就继续试下一条。
      }
    }
    return null;
  }

  /// 按指定清晰度取地址；没有就退回默认地址。
  String _qualityUrlFor(PlayInfo play, String? qualityKey) {
    if (qualityKey != null) {
      for (final item in play.quality) {
        if (item.key == qualityKey && item.url.trim().isNotEmpty) {
          return item.url.trim();
        }
      }
    }
    return play.url.trim();
  }

  String _qualityUrl(PlayInfo play) {
    final key = _qualityKey;
    if (key != null) {
      for (final item in play.quality) {
        if (item.key == key) {
          final url = item.url.trim();
          if (url.isNotEmpty) return url;
        }
      }
    }
    return play.url.trim();
  }

  Future<void> _disposeController() async {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    controller.removeListener(_onVideoValue);
    await _releasePlayer(controller);
  }

  /// 退出房间不能只暂停：pause → stop → dispose 全部走一遍。
  Future<void> _releasePlayer(FxPlayer controller) async {
    try {
      await controller.pause();
    } catch (_) {}
    try {
      await controller.stop();
    } catch (_) {}
    try {
      await controller.dispose();
    } catch (_) {}
  }

  void _retryVideo() {
    if (!mounted) return;
    _cancelLiveFirstFrameTimer();
    _loadedKey = '';
    _loadingKey = '';
    _videoError = '';
    _syncVideo();
  }

  /* ------------------------------------------------------------ 聊天 */

  void _appendMessage(TogetherChatMessage message) {
    _messages.add(message);
    _trimMessages();
    _publishChat();
  }

  void _appendSystem(String text) {
    _appendMessage(TogetherChatMessage.system(text));
  }

  void _trimMessages() {
    const max = 200;
    if (_messages.length > max) {
      _messages.removeRange(0, _messages.length - max);
    }
  }

  void _publishChat() {
    if (!mounted) return;
    _chat.value = List<TogetherChatMessage>.unmodifiable(
      List<TogetherChatMessage>.from(_messages),
    );
  }

  void _clearMessages() {
    _messages.clear();
    _chat.value = const <TogetherChatMessage>[];
  }

  bool _sendChat(String text) {
    final sent = _client.sendChat(text);
    if (!sent) {
      togetherToast(context, '消息发送失败，请检查网络');
      return false;
    }
    return true;
  }

  /* ------------------------------------------------------------ 全屏 / 系统 UI */

  Future<void> _enterFullscreen() async {
    if (_fullscreen || _stage != _TogetherStage.room) return;
    FocusScope.of(context).unfocus();
    setState(() => _fullscreen = true);
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations(_landscape);
      SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    } catch (_) {
      // 桌面 / 模拟器不支持也无所谓。
    }
  }

  Future<void> _exitFullscreen() async {
    if (!_fullscreen) return;
    FocusScope.of(context).unfocus();
    if (mounted) setState(() => _fullscreen = false);
    await _restoreSystemUi();
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

  /* ------------------------------------------------------------ 入口 UI */

  Future<void> _pickAndCreate() async {
    final card = await showTogetherVideoPicker(context);
    if (!mounted || card == null) return;
    // 选片后先选集，再建房；直接关闭选集面板时默认第 1 集。
    final detail = await _fetchDetailForPicker(card.id);
    if (!mounted) return;
    final episodes = _episodesForPicker(detail, card);
    final episode = await _pickEpisodeFor(card, episodes);
    if (!mounted) return;
    _videoTitle = card.title;
    _videoCover = togetherCoverUrl(card.cover);
    _episodes = episodes;
    _lines = detail?.lines ?? const <LineInfo>[];
    _videoLine = detail != null && detail.lines.isNotEmpty
        ? detail.lines.first.id
        : '';
    // 主动选片建房视为「开始观看」，从第 1 集（或用户选的那集）自动播放。
    _resumePos = 0;
    _resumePlaying = true;
    _createRoom(card.id, episode, detail: detail);
  }

  void _joinByInput() {
    final code = _joinCtrl.text.replaceAll(RegExp(r'\D'), '');
    if (code.length != 6) {
      togetherToast(context, '请输入 6 位房间号');
      return;
    }
    FocusScope.of(context).unfocus();
    _joinRoom(code);
  }

  @override
  Widget build(BuildContext context) {
    final fullscreen = _fullscreen && _stage == _TogetherStage.room;
    // 必须在 Scaffold 之上取 viewInsets：Scaffold 在 resizeToAvoidBottomInset
    // 为 true 时会从 body 的 MediaQuery 里移除 bottom inset。
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _requestBack();
      },
      child: Scaffold(
        backgroundColor: fullscreen ? Colors.black : const Color(0xFFF6F8FC),
        // 竖屏房间允许键盘压缩页面：聊天列表收缩，视频区固定高度不消失。
        resizeToAvoidBottomInset: !fullscreen,
        body: fullscreen
            ? _buildFullscreen()
            : FxBackground(
                child: SafeArea(
                  bottom: false,
                  child: switch (_stage) {
                    _TogetherStage.entry => _buildEntry(),
                    _TogetherStage.entering => _buildEntering(),
                    _TogetherStage.room => _buildRoom(keyboard: keyboard),
                  },
                ),
              ),
      ),
    );
  }

  Widget _buildFullscreen() {
    return TogetherFullscreenView(
      player: _controller,
      position: _position,
      chat: _chat,
      members: _members,
      roomCode: _roomCode,
      title: _videoTitle.isNotEmpty
          ? _videoTitle
          : (_roomTitle.isNotEmpty ? _roomTitle : '一起看'),
      cover: _videoCover,
      ep: _ep,
      episodes: _episodes,
      isHost: _isHost,
      online: _online,
      loading: _videoLoading,
      errorText: _videoError,
      isLive: _isLive,
      qualityLabel: _isLive
          ? (_liveLine?.qualityLabel ?? '')
          : fxPlayerQuality(_controller),
      qualityKey: _isLive ? _liveLineId : _qualityKey,
      canChangeQuality: _isLive
          ? (_liveChannel?.lines.length ?? 0) >= 2
          : (_playInfo?.quality.length ?? 0) >= 2,
      qualities: _isLive
          ? <QualityItem>[
              for (var i = 0; i < (_liveChannel?.lines.length ?? 0); i++)
                QualityItem(
                  _liveChannel!.lines[i].id,
                  '${_liveChannel!.lines[i].qualityLabel} · '
                  '${_liveChannel!.lines[i].subtitle(i)}',
                  _liveChannel!.lines[i].url,
                ),
            ]
          : (_playInfo?.quality ?? const <QualityItem>[]),
      rate: _isHost ? _hostRate : (_remote?.rate ?? 1.0),
      videoBoundaryKey: _videoBoundaryKey,
      videoEpoch: _videoEpoch,
      frozenFrame: _frozenFrame,
      frozenFrameOpaque: _frozenFrameOpaque,
      onExit: () => unawaited(_exitFullscreen()),
      onExitRoom: () => unawaited(_confirmLeaveRoom()),
      onInvite: () => unawaited(_showInvite()),
      onMembers: () => unawaited(_showMembers()),
      onSwitchLine: () => unawaited(_pickLine()),
      onChangeDrama: () => unawaited(_pickDrama()),
      onTogglePlay: _togglePlay,
      onSeek: _seekTo,
      onSeekBy: _seekBy,
      onNext: _nextEpisode,
      onEpisodes: () => unawaited(_pickEpisode()),
      onRate: _setHostRate,
      onQuality: (key) => unawaited(_setQuality(key)),
      onRetry: _retryVideo,
      onHostOnly: _hostOnly,
      onSendChat: _sendChat,
    );
  }

  Widget _buildRoom({required bool keyboard}) {
    return TogetherRoomView(
      player: _controller,
      position: _position,
      chat: _chat,
      roomCode: _roomCode,
      roomTitle: _roomTitle,
      videoTitle: _videoTitle,
      cover: _videoCover,
      ep: _ep,
      episodes: _episodes,
      members: _members,
      isHost: _isHost,
      online: _online,
      loading: _videoLoading,
      errorText: _videoError,
      isLive: _isLive,
      videoBoundaryKey: _videoBoundaryKey,
      videoEpoch: _videoEpoch,
      frozenFrame: _frozenFrame,
      frozenFrameOpaque: _frozenFrameOpaque,
      onBack: () => unawaited(_confirmLeaveRoom()),
      onCopyCode: () {
        if (_roomCode.isEmpty) return;
        unawaited(togetherCopy(context, _roomCode, message: '房间号已复制'));
      },
      onInvite: () => unawaited(_showInvite()),
      onMembers: () => unawaited(_showMembers()),
      onMedia: () => unawaited(_showMediaSheet()),
      onSwitchLine: () => unawaited(_pickLine()),
      onChangeDrama: () => unawaited(_pickDrama()),
      onEpisodes: () => unawaited(_pickEpisode()),
      onTogglePlay: _togglePlay,
      onSeek: _seekTo,
      onEnterFullscreen: () => unawaited(_enterFullscreen()),
      onSendChat: _sendChat,
      onRetry: _retryVideo,
      onHostOnly: _hostOnly,
      onSyncToHost: _isHost ? null : () => unawaited(_syncToHostNow()),
      syncOffsetSeconds: _syncOffsetSeconds(),
      keyboardVisible: keyboard,
    );
  }

  Widget _buildEntry() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
          child: Row(
            children: [
              TogetherCircleButton(
                icon: Icons.arrow_back_ios_new_rounded,
                size: 36,
                iconSize: 15,
                onTap: _requestBack,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '一起看',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: Fx.ink,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      '和好友同步追剧，进度由房主统一控制',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: Fx.sub),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                  decoration: togetherGlass(radius: 22, opacity: .72),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: Fx.accent.withValues(alpha: .11),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(
                              Icons.dialpad_rounded,
                              size: 19,
                              color: Fx.accent,
                            ),
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '输入房间号加入',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: Fx.ink,
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  '向房主要 6 位房间号',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: Fx.sub,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _joinCtrl,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.done,
                        textAlign: TextAlign.center,
                        maxLength: 6,
                        onSubmitted: (_) => _joinByInput(),
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: Fx.ink,
                          letterSpacing: 7,
                        ),
                        decoration: InputDecoration(
                          hintText: '000000',
                          counterText: '',
                          hintStyle: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 7,
                            color: Fx.sub.withValues(alpha: .35),
                          ),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: .76),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 13,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(15),
                            borderSide: BorderSide(
                              color: Colors.white.withValues(alpha: .95),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(15),
                            borderSide: const BorderSide(
                              color: Fx.accent,
                              width: 1.2,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: GradButton(
                          text: '加入房间',
                          icon: Icons.login_rounded,
                          height: 46,
                          onTap: _joinByInput,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                  decoration: togetherGlass(radius: 22, opacity: .62),
                  child: Column(
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: Fx.accent2.withValues(alpha: .10),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.movie_filter_rounded,
                          size: 26,
                          color: Fx.accent2,
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        '还没有房间号？',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: Fx.ink,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        '创建房间并选一部片，把邀请发给好友，\n对方输入房间号即可同步追剧',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 10.5,
                          height: 1.5,
                          color: Fx.sub,
                        ),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: GradButton(
                          text: '创建一起看房间',
                          icon: Icons.add_rounded,
                          height: 46,
                          onTap: _pickAndCreate,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEntering() {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 34),
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
        decoration: togetherGlass(radius: 24, opacity: .72),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                valueColor: AlwaysStoppedAnimation<Color>(Fx.accent),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _stageText,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Fx.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _online ? '已连接服务器，正在同步房间状态…' : '正在连接一起看服务器…',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10.5,
                color: Fx.sub.withValues(alpha: .9),
              ),
            ),
            const SizedBox(height: 16),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _backToEntry,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .85),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Text(
                  '取消',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Fx.sub,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

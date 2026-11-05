import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../models.dart';
import '../services/fx_player.dart';
import '../theme.dart';
import '../widgets/together_chat.dart';
import '../widgets/together_client.dart';
import '../widgets/together_fullscreen.dart';
import '../widgets/together_picker.dart';
import '../widgets/together_ui.dart';

/* ========================================================================== */
/*  一起看                                                                     */
/*  入口：输入房间号加入 ／ 选片创建房间                                       */
/*  房间：16:9 视频（房主控制） + 聊天 + 服务器权威同步（API.md §4）            */
/* ========================================================================== */

enum _TogetherStage { entry, entering, room }

class TogetherPage extends StatefulWidget {
  const TogetherPage({super.key, this.videoId, this.ep = 1});

  /// 从播放页带过来时直接建房，不再选片。
  final String? videoId;
  final int ep;

  @override
  State<TogetherPage> createState() => _TogetherPageState();
}

class _TogetherPageState extends State<TogetherPage>
    with WidgetsBindingObserver {
  static const Color _videoBg = Color(0xFF101722);
  static const List<DeviceOrientation> _landscape = <DeviceOrientation>[
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  /// 与 main.dart 里保持一致，退出全屏后恢复。
  static const SystemUiOverlayStyle _appOverlay = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarContrastEnforced: false,
  );

  static const TextStyle _timeStyle = TextStyle(
    fontSize: 9,
    fontWeight: FontWeight.w600,
    color: Color(0xCCFFFFFF),
  );

  late final TogetherClient _client;

  /* 页面 / 房间 */
  _TogetherStage _stage = _TogetherStage.entry;
  bool _entered = false;
  bool _enteringAsHost = false;
  String _stageText = '';
  bool _exiting = false;
  bool _leaving = false;
  bool _wantsRoom = false;
  bool _restoreAfterResume = false;
  bool _fullscreen = false;

  bool _online = false;
  bool _isHost = false;

  String _myId = '';

  String _roomCode = '';
  String _roomTitle = '';
  List<TogetherMember> _members = const <TogetherMember>[];
  TogetherRoomState? _remote;
  int _lastRev = -1;
  String _lastRevCode = '';

  final List<TogetherChatMessage> _messages = <TogetherChatMessage>[];

  /// 聊天列表单独通知：只有新消息才刷新，进度跳动不再重建整页。
  final ValueNotifier<List<TogetherChatMessage>> _chat =
      ValueNotifier<List<TogetherChatMessage>>(const []);

  /// 缓存的聊天列表子树：父级 setState 时不会重建（实例相同），
  /// 只有 _chat 通知时才刷新。
  late final Widget _chatView;

  /* 播放 */
  FxPlayer? _controller;
  String _videoId = '';
  int _ep = 1;
  String _videoLine = 'l1';
  String _videoTitle = '';
  String _videoCover = '';
  List<Episode> _episodes = const <Episode>[];
  List<LineInfo> _videoLines = const <LineInfo>[];
  String _linesVideoId = '';
  final TextEditingController _joinCtrl = TextEditingController();
  String _loadedKey = '';
  String _loadingKey = '';
  bool _videoLoading = false;
  String _videoError = '';
  int _videoSeq = 0;
  bool _endedSent = false;
  double _rate = 1;
  double? _resumePos;
  bool _resumePlaying = false;
  String _resumeKey = '';

  /// 播放进度单独通知：ticker 只改这个值，不再整页 setState。
  final ValueNotifier<double> _position = ValueNotifier<double>(0);

  Timer? _ticker;
  Timer? _heartbeat;
  Timer? _enterTimer;
  bool _downReported = false;
  bool _foreground = true;

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
    );
    WidgetsBinding.instance.addObserver(this);
    _chatView = ValueListenableBuilder<List<TogetherChatMessage>>(
      valueListenable: _chat,
      builder: (context, messages, _) => TogetherChatList(messages: messages),
    );
    _startTimers();
    final videoId = (widget.videoId ?? '').trim();
    if (videoId.isNotEmpty) {
      _videoId = videoId;
      _ep = widget.ep < 1 ? 1 : widget.ep;
      _startCreate(videoId, _ep);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopTimers();
    _enterTimer?.cancel();
    _joinCtrl.dispose();
    _enterTimer = null;
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
    _position.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    final active = state == AppLifecycleState.resumed;
    if (active == _foreground) return;
    _foreground = active;
    if (active) {
      _startTimers();
      _client.resumeHeartbeat();
      if (_client.connected) {
        // 回到前台先要一次服务端权威状态，再按服务器时间重算进度。
        _client.refreshRoom();
      } else {
        _client.connect();
      }
      _resyncAfterResume();
    } else {
      _stopTimers();
      _client.pauseHeartbeat();
    }
  }

  void _startTimers() {
    _ticker ??=
        Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
    _heartbeat ??=
        Timer.periodic(const Duration(seconds: 9), (_) => _hostHeartbeat());
  }

  void _stopTimers() {
    _ticker?.cancel();
    _heartbeat?.cancel();
    _ticker = null;
    _heartbeat = null;
  }

  void _resyncAfterResume() {
    final state = _remote;
    if (_stage != _TogetherStage.room || state == null) return;
    if (_isHost) {
      // 房主回前台：把本地真实播放状态/进度重新写回服务器，
      // 期间若系统暂停了播放，其他人也会跟着暂停而不是继续空跑。
      final controller = _controller;
      if (controller != null && controller.value.isInitialized) {
        final position = controller.value.position.inMilliseconds / 1000.0;
        final playing = controller.value.isPlaying;
        if (_online) {
          _client.sendState(
            playing ? 'play' : 'pause',
            position,
            videoId: _videoId,
            ep: _ep,
            line: _videoLine,
          );
        }
        _markRemote(playing ? 'play' : 'pause', position);
      }
    } else {
      _applyRemotePlayback(state);
    }
    _tick(force: true);
  }

  /* ------------------------------------------------------------ 网络回调 */

  void _onOpen(TogetherMember me) {
    if (!mounted) return;
    final first = _myId.isEmpty;
    setState(() {
      _online = true;
      if (me.id.isNotEmpty) _myId = me.id;
    });
    if (!first && _entered) {
      _appendSystem('已重新连接服务器');
      // 断线期间视频可能加载失败（key 已清空）：重连后重新对齐一次。
      _syncVideo();
    }
  }

  void _onDown() {
    if (!mounted) return;
    final wasOnline = _online;
    setState(() => _online = false);
    if (!_entered && _stage == _TogetherStage.entering) {
      _backToEntry();
      togetherToast(context, '连不上服务器，稍后再试');
      return;
    }
    if (wasOnline && _entered && !_downReported) {
      _downReported = true;
      _appendSystem('连接断开，正在自动重连…');
      togetherToast(context, '连接断开，正在自动重连…');
    }
  }

  void _onRoom(TogetherRoomInfo info) {
    if (!mounted) return;
    if (!_wantsRoom) {
      // 用户已取消进入，服务器却建好了房：顺手清理。
      _client.leave();
      return;
    }
    final resume = _roomCode.isNotEmpty;
    _restoreAfterResume = resume && _captureResume();
    setState(() {
      _stage = _TogetherStage.room;
      _entered = true;
      _online = true;
      _isHost = true;
      _roomCode = info.code;
      _roomTitle = info.title;
      if (info.videoId.isNotEmpty) _videoId = info.videoId;
      if (info.ep > 0) _ep = info.ep;
      if (info.line.isNotEmpty) _videoLine = info.line;
      // 成员列表无条件采用服务端快照（哪怕为空），避免最后一人退出后人数残留。
      _members = info.members;
      _remote = null;
      _lastRev = -1;
      _lastRevCode = '';
    });
    _downReported = false;
    _appendSystem('房间: ${info.code}');
    _loadDetail(_videoId);
    _syncVideo();
    _position.value = _displayPosition();
  }

  void _onState(TogetherRoomState state) {
    if (!mounted || !_wantsRoom) return;
    if (_stage == _TogetherStage.entering &&
        _roomCode.isNotEmpty &&
        state.code != _roomCode) {
      return; // 忽略上一个房间迟到的状态
    }
    // rev 去旧：同一房间只接受更新的权威状态。
    if (state.code.isNotEmpty &&
        state.code == _lastRevCode &&
        state.rev <= _lastRev) {
      return;
    }
    if (state.code.isNotEmpty) {
      _lastRevCode = state.code;
      _lastRev = state.rev;
    }
    final firstEnter = !_entered;
    final changedVideo = state.videoId.isNotEmpty && state.videoId != _videoId;
    if (state.members.isNotEmpty) {
      var host = false;
      for (final member in state.members) {
        if (member.id == _myId && member.host) host = true;
      }
      _isHost = host;
    }
    setState(() {
      _remote = state;
      _stage = _TogetherStage.room;
      _entered = true;
      _online = true;
      if (state.code.isNotEmpty) _roomCode = state.code;
      if (state.title.isNotEmpty) _roomTitle = state.title;
      // 无条件覆盖：成员离开后服务端快照可能变短甚至为空。
      _members = state.members;
      if (state.videoId.isNotEmpty) _videoId = state.videoId;
      if (state.ep > 0) _ep = state.ep;
      if (state.line.isNotEmpty) _videoLine = state.line;
    });
    _downReported = false;
    if (firstEnter) _appendSystem('房间: ${state.code}');
    if (changedVideo && !firstEnter && !_isHost) {
      _appendSystem('房主换了一部影片');
    }
    if (changedVideo) _loadDetail(_videoId);
    _syncVideo();
    _applyRemotePlayback(state);
    _position.value = _displayPosition();
    if (_restoreAfterResume && _isHost) {
      _restoreAfterResume = false;
      final controller = _controller;
      if (controller != null && controller.value.isInitialized) {
        final position = controller.value.position.inMilliseconds / 1000.0;
        final playing = controller.value.isPlaying;
        _client.sendState(
          playing ? 'play' : 'pause',
          position,
          videoId: _videoId,
          ep: _ep,
          line: _videoLine,
        );
        _markRemote(playing ? 'play' : 'pause', position);
        _resumePos = null;
        _resumeKey = '';
      }
    }
  }

  void _onChat(TogetherChatIncoming chat) {
    if (!mounted || chat.text.isEmpty) return;
    _appendMessage(TogetherChatMessage(
      text: chat.text,
      time: DateTime.now(),
      user: chat.name,
      avatar: chat.avatar,
      mine: chat.userId.isNotEmpty && chat.userId == _myId,
    ));
  }

  void _onSystem(String text) {
    if (!mounted || text.isEmpty) return;
    _appendSystem(text.replaceAll('加入了房间', '进入房间'));
  }

  void _onError(String code, String message) {
    if (!mounted) return;
    if (code == 'host_only') {
      togetherToast(context, '跟随房主');
      _bounceToAuthority();
      return;
    }
    if (code == 'bad_code') {
      togetherToast(context, message.isEmpty ? '房间号必须是 6 位数字' : message);
      return;
    }
    if (code == 'not_in_room') {
      // 取消进入时补发的 leave 可能落在服务器已经清理之后，静默处理。
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
      // 房间不存在 / 已解散 / 创建时作品失效，分别给明确文案。
      if (_stage == _TogetherStage.entering) {
        togetherToast(
          context,
          _enteringAsHost
              ? (message.isEmpty ? '创建房间失败，请稍后重试' : message)
              : '房间不存在，请检查房间号',
        );
        _backToEntry();
      } else if (_stage == _TogetherStage.room) {
        // 房间仍然有效时（例如 state 带了失效的 videoId）只提示，不退出。
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
    _enterTimer?.cancel();
    if (_fullscreen) unawaited(_exitFullscreen());
    final text = reason.isEmpty ? '房间已解散' : reason;
    _wantsRoom = false;
    setState(() {
      _stage = _TogetherStage.entry;
      _entered = false;
      _isHost = false;
      _roomCode = '';
      _remote = null;
      _members = const <TogetherMember>[];
      _clearMessages();
      _videoId = '';
      _videoTitle = '';
      _videoCover = '';
      _episodes = const <Episode>[];
      _ep = 1;
      _loadedKey = '';
      _loadingKey = '';
      _videoLoading = false;
      _videoError = '';
      _roomTitle = '';
      _videoLine = 'l1';
      _lastRev = -1;
      _lastRevCode = '';
    });
    _resumePos = null;
    _resumeKey = '';
    _restoreAfterResume = false;
    _downReported = false;
    _position.value = 0;
    _videoSeq++;
    unawaited(_disposeController());
    togetherToast(context, text);
  }

  /* ------------------------------------------------------------ 建房 / 加入 */

  void _startCreate(String videoId, int ep) {
    _clearMessages();
    _wantsRoom = true;
    _enteringAsHost = true;
    _entered = false;
    _leaving = false;
    _remote = null;
    _roomCode = '';
    _lastRev = -1;
    _lastRevCode = '';
    _stage = _TogetherStage.entering;
    _stageText = '正在创建房间…';
    _videoId = videoId;
    _ep = ep < 1 ? 1 : ep;
    _videoLine = 'l1';
    _loadedKey = '';
    _loadingKey = '';
    _videoError = '';
    _online = _client.connected;
    _client.createRoom(
      videoId: videoId,
      ep: _ep,
      line: _videoLine,
      title: _videoTitle.isEmpty ? '' : '$_videoTitle · 一起看',
    );
    _client.connect();
    _armEnterTimer();
    _loadDetail(videoId);
    if (mounted) setState(() {});
  }

  void _join(String code) {
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
    _remote = null;
    _roomCode = code;
    _lastRev = -1;
    _lastRevCode = '';
    _stage = _TogetherStage.entering;
    _stageText = '正在加入房间 $code…';
    _videoId = '';
    _videoTitle = '';
    _videoCover = '';
    _episodes = const <Episode>[];
    _ep = 1;
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
    _enterTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted || _entered || _stage != _TogetherStage.entering) return;
      _backToEntry();
      togetherToast(context, '连不上服务器，稍后再试');
    });
  }

  void _backToEntry() {
    _enterTimer?.cancel();
    if (_fullscreen) unawaited(_exitFullscreen());
    _wantsRoom = false;
    _client.leave();
    _resumePos = null;
    _resumeKey = '';
    _restoreAfterResume = false;
    _downReported = false;
    _position.value = 0;
    _videoSeq++;
    unawaited(_disposeController());
    if (!mounted) return;
    setState(() {
      _stage = _TogetherStage.entry;
      _entered = false;
      _isHost = false;
      _online = false;
      _roomCode = '';
      _roomTitle = '';
      _remote = null;
      _members = const <TogetherMember>[];
      _clearMessages();
      _videoId = '';
      _videoTitle = '';
      _videoCover = '';
      _episodes = const <Episode>[];
      _ep = 1;
      _videoLine = 'l1';
      _loadedKey = '';
      _loadingKey = '';
      _videoLoading = false;
      _videoError = '';
      _lastRev = -1;
      _lastRevCode = '';
    });
  }

  Future<void> _confirmExit() async {
    if (!mounted || _exiting || _leaving) return;
    if (_fullscreen) {
      await _exitFullscreen();
      return;
    }
    if (_stage == _TogetherStage.entry) {
      Navigator.of(context).pop();
      return;
    }
    if (_stage == _TogetherStage.entering) {
      if (_enteringAsHost) {
        _leaving = true;
        _client.leave();
        _videoSeq++;
        await _disposeController();
        if (!mounted) return;
        Navigator.of(context).pop();
      } else {
        _backToEntry();
      }
      return;
    }
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
    _client.leave();
    _videoSeq++;
    await _disposeController();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /* ------------------------------------------------------------ 全屏 */

  Future<void> _enterFullscreen() async {
    if (_fullscreen || _stage != _TogetherStage.room) return;
    FocusScope.of(context).unfocus();
    setState(() => _fullscreen = true);
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations(_landscape);
      SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    } catch (_) {
      // 桌面 / 模拟器上不支持也无所谓。
    }
  }

  Future<void> _exitFullscreen() async {
    if (!_fullscreen) return;
    if (mounted) {
      FocusScope.of(context).unfocus();
      setState(() => _fullscreen = false);
    }
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

  /* ------------------------------------------------------------ 同步 / 播放 */

  double _targetPosition(TogetherRoomState state) {
    var pos = state.position;
    if (state.playing && state.at > 0 && _client.synced) {
      pos += (_client.nowServerMs() - state.at) / 1000.0;
    }
    if (pos.isNaN || pos < 0) return 0;
    return pos > 86400 ? 86400 : pos;
  }

  double _displayPosition() {
    final controller = _controller;
    final state = _remote;
    if (_isHost && controller != null && controller.value.isInitialized) {
      return controller.value.position.inMilliseconds / 1000.0;
    }
    if (state != null) return _targetPosition(state);
    if (controller != null && controller.value.isInitialized) {
      return controller.value.position.inMilliseconds / 1000.0;
    }
    return 0;
  }

  void _tick({bool force = false}) {
    if (!mounted || !_foreground || _stage != _TogetherStage.room) return;
    final controller = _controller;
    final state = _remote;
    if (controller != null &&
        controller.value.isInitialized &&
        state != null &&
        !_isHost) {
      final target = _targetPosition(state);
      final current = controller.value.position.inMilliseconds / 1000.0;
      final drift = target - current;
      if (!state.playing) {
        _applyRate(1);
        if (drift.abs() > .6) _seekController(target);
      } else if (drift.abs() > 3) {
        // 误差太大：直接对齐，再让后续微调回归 1.0 倍速。
        _applyRate(1);
        _seekController(target);
      } else if (drift.abs() > .5) {
        // 平滑追赶：只改播放速率，不硬跳。
        _applyRate(drift > 0 ? 1.08 : .92);
      } else {
        _applyRate(1);
      }
    }
    // 只更新进度 ValueNotifier，不再每 500ms 重建整页。
    final value = _displayPosition();
    if (force || (value - _position.value).abs() >= .05) {
      _position.value = value;
    }
  }

  void _applyRate(double rate) {
    if ((_rate - rate).abs() < .02) return;
    _rate = rate;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    controller.setRate(rate).catchError((_) {});
  }

  void _seekController(double seconds) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    var value = seconds;
    if (value.isNaN || value < 0) value = 0;
    final max = controller.value.duration.inMilliseconds / 1000.0;
    if (max > 0 && value > max) value = max;
    controller
        .seekTo(Duration(milliseconds: (value * 1000).round()))
        .catchError((_) {});
  }

  void _applyRemotePlayback(TogetherRoomState state) {
    if (_isHost) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final target = _targetPosition(state);
    final current = controller.value.position.inMilliseconds / 1000.0;
    final drift = target - current;
    _applyRate(1);
    if (state.playing) {
      if (!controller.value.isPlaying) controller.play().catchError((_) {});
      if (drift.abs() > 1.5) _seekController(target);
    } else {
      if (controller.value.isPlaying) controller.pause().catchError((_) {});
      if (drift.abs() > .6) _seekController(target);
    }
  }

  void _markRemote(String playback, double position) {
    final state = _remote;
    if (state == null) return;
    final playing = playback == 'play';
    final ended = playback == 'ended';
    final changed = state.playing != playing || state.ended != ended;
    _remote = state.copyWith(
      playing: playing,
      ended: ended,
      position: position,
      at: _client.nowServerMs(),
    );
    // 位置由 ValueNotifier 驱动；只有播放/结束状态变了才需要重建页面。
    if (changed) setState(() {});
  }

  void _togglePlay() {
    if (!_isHost) {
      _hostOnlyToast();
      return;
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      togetherToast(context, '视频还没准备好');
      return;
    }
    final position = controller.value.position.inMilliseconds / 1000.0;
    if (controller.value.isPlaying) {
      controller.pause().catchError((_) {});
      if (_online) _client.sendState('pause', position);
      _markRemote('pause', position);
      setState(() {});
      return;
    }
    final atEnd = _endedSent ||
        (controller.value.duration > Duration.zero &&
            controller.value.position >=
                controller.value.duration - const Duration(milliseconds: 400));
    if (atEnd) _seekController(0);
    _endedSent = false;
    final start = atEnd ? 0.0 : position;
    controller.play().catchError((_) {});
    if (_online) _client.sendState('play', start);
    _markRemote('play', start);
    setState(() {});
  }

  void _seekTo(double seconds) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (!_isHost) {
      _hostOnlyToast();
      return;
    }
    var target = seconds;
    if (target.isNaN || target < 0) target = 0;
    final duration = controller.value.duration.inMilliseconds / 1000.0;
    if (duration > 0 && target > duration) target = duration;
    _seekController(target);
    _endedSent = false;
    if (_online) {
      _client.sendSeek(target);
      _markRemote(_remote?.playing == true ? 'play' : 'pause', target);
    }
    setState(() {});
  }

  void _bounceToAuthority() {
    final state = _remote;
    if (state == null) return;
    _applyRate(1);
    _seekController(_targetPosition(state));
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      if (state.playing) {
        controller.play().catchError((_) {});
      } else {
        controller.pause().catchError((_) {});
      }
    }
    setState(() {});
  }

  void _hostHeartbeat() {
    if (!mounted || !_isHost || !_online) return;
    final controller = _controller;
    final state = _remote;
    if (controller == null ||
        !controller.value.isInitialized ||
        state == null ||
        !controller.value.isPlaying) {
      return;
    }
    final position = controller.value.position.inMilliseconds / 1000.0;
    _client.sendState('play', position);
    _markRemote('play', position);
  }

  void _onVideoValue() {
    final controller = _controller;
    if (controller == null || !mounted) return;
    final value = controller.value;
    if (value.hasError && _videoError.isEmpty) {
      setState(() => _videoError = '播放中断，点视频区可重试');
      return;
    }
    if (_endedSent || !_isHost || !value.isInitialized) return;
    if (value.duration.inMilliseconds <= 0) return;
    if (value.position >= value.duration - const Duration(milliseconds: 400)) {
      _endedSent = true;
      final position = value.position.inMilliseconds / 1000.0;
      if (_online) _client.sendState('ended', position);
      _markRemote('ended', position);
    }
  }

  bool _captureResume() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return false;
    _resumePos = controller.value.position.inMilliseconds / 1000.0;
    _resumePlaying = controller.value.isPlaying;
    _resumeKey = '$_videoId|$_ep|$_videoLine';
    return true;
  }

  void _syncVideo() {
    if (_videoId.isEmpty) return;
    final key = '$_videoId|$_ep|$_videoLine';
    // 加载中和已加载都不要重复发请求；失败时 key 会被清空，下次同步可重试。
    if (key == _loadedKey || key == _loadingKey) return;
    _loadVideo(_videoId, _ep, _videoLine);
  }

  Future<void> _loadVideo(String videoId, int ep, String line) async {
    final key = '$videoId|$ep|$line';
    _loadingKey = key;
    final seq = ++_videoSeq;
    _endedSent = false;
    if (_resumePos != null && _resumeKey != '$videoId|$ep|$line') {
      _resumePos = null;
      _resumePlaying = false;
      _resumeKey = '';
    }
    await _disposeController();
    if (!mounted || seq != _videoSeq) return;
    _position.value = 0;
    setState(() {
      _videoLoading = true;
      _videoError = '';
    });

    // 一起看不能用房间状态里的 line（可能是 parse 线路）：
    // 先取详情，按顺序尝试所有非 parse 线路，每条线路内再试 backup。
    var lines = _linesVideoId == videoId
        ? _videoLines.where((l) => !l.needsParse).toList()
        : <LineInfo>[];
    if (lines.isEmpty) {
      try {
        final detail = await Api.detail(videoId);
        if (!mounted || seq != _videoSeq) return;
        _linesVideoId = videoId;
        _videoLines = detail.lines;
        if (_videoId == videoId) {
          setState(() {
            if (detail.title.isNotEmpty) _videoTitle = detail.title;
            _videoCover = togetherCoverUrl(detail.cover);
            _episodes = detail.allEpisodes;
          });
        }
        lines = detail.lines.where((l) => !l.needsParse).toList();
      } catch (_) {
        lines = <LineInfo>[];
      }
    }
    if (lines.isEmpty) {
      if (!mounted || seq != _videoSeq) return;
      _loadingKey = '';
      _loadedKey = '';
      setState(() {
        _videoLoading = false;
        _videoError = '房主暂未选择可播线路';
      });
      return;
    }

    for (final lineInfo in lines) {
      if (!mounted || seq != _videoSeq) return;
      PlayInfo? play;
      try {
        play = await Api.play(videoId, ep, lineInfo.id);
      } catch (_) {
        continue;
      }
      if (!mounted || seq != _videoSeq) return;
      if (play.type.trim().toLowerCase() == 'parse') continue;

      final urls = <String>[];
      final primary = play.url.trim();
      if (primary.isNotEmpty) urls.add(primary);
      for (final raw in play.backup) {
        final url = raw.trim();
        if (url.isNotEmpty && !urls.contains(url)) urls.add(url);
      }
      if (urls.isEmpty) continue;

      for (final url in urls) {
        if (!mounted || seq != _videoSeq) return;
        FxPlayer? controller;
        try {
          controller = FxPlayer.create();
          await controller.open(url, headers: play.headers);
          if (!mounted || seq != _videoSeq) {
            await _releasePlayer(controller);
            return;
          }
          await controller.setLooping(false);
          if (!mounted || seq != _videoSeq) {
            await _releasePlayer(controller);
            return;
          }
          final state = _remote;
          if (!_isHost && state != null) {
            await _seekAndMaybePlay(controller, state);
            if (!mounted || seq != _videoSeq) {
              await _releasePlayer(controller);
              return;
            }
          } else if (_isHost && _resumePos != null) {
            final position = _resumePos!;
            await controller.seekTo(
              Duration(milliseconds: (position * 1000).round()),
            );
            if (!mounted || seq != _videoSeq) {
              await _releasePlayer(controller);
              return;
            }
            if (_resumePlaying) {
              await controller.play();
              if (!mounted || seq != _videoSeq) {
                await _releasePlayer(controller);
                return;
              }
            }
            if (_online) {
              _client.sendState(
                _resumePlaying ? 'play' : 'pause',
                position,
                videoId: _videoId,
                ep: _ep,
                line: _videoLine,
              );
            }
            _resumePos = null;
            _resumeKey = '';
          }
          // 所有 await 都结束且页面/序号仍有效，才把实例交给页面。
          if (!mounted || seq != _videoSeq) {
            await _releasePlayer(controller);
            return;
          }
          _controller = controller;
          controller.addListener(_onVideoValue);
          _rate = 1;
          _loadingKey = '';
          _loadedKey = key;
          setState(() {
            _videoLoading = false;
            _videoError = '';
          });
          return;
        } catch (_) {
          try {
            if (controller != null) {
              controller.removeListener(_onVideoValue);
              if (identical(_controller, controller)) _controller = null;
              await _releasePlayer(controller);
            }
          } catch (_) {}
        }
      }
    }
    if (!mounted || seq != _videoSeq) return;
    // 全部线路都失败：清掉 key，让「重试」按钮 / 重连 / 下一次状态同步能再试。
    _loadingKey = '';
    _loadedKey = '';
    setState(() {
      _videoLoading = false;
      _videoError = '房主暂未选择可播线路';
    });
  }

  Future<void> _seekAndMaybePlay(
    FxPlayer controller,
    TogetherRoomState state,
  ) async {
    final target = _targetPosition(state);
    await controller.seekTo(Duration(milliseconds: (target * 1000).round()));
    if (state.playing) {
      await controller.play();
    } else {
      await controller.pause();
    }
  }

  Future<void> _disposeController() async {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    controller.removeListener(_onVideoValue);
    await _releasePlayer(controller);
  }

  /// 释放播放器：先暂停、再 stop，最后 dispose（离开房间时不能只静音）。
  Future<void> _releasePlayer(FxPlayer controller) async {
    try {
      await controller.pause();
    } catch (_) {}
    try {
      await controller.player.stop();
    } catch (_) {}
    try {
      await controller.dispose();
    } catch (_) {}
  }

  void _retryVideo() {
    if (!mounted) return;
    _loadedKey = '';
    _loadingKey = '';
    _videoError = '';
    _syncVideo();
  }

  Future<void> _loadDetail(String videoId) async {
    if (videoId.isEmpty) return;
    try {
      final detail = await Api.detail(videoId);
      if (!mounted || _videoId != videoId) return;
      setState(() {
        _linesVideoId = videoId;
        _videoLines = detail.lines;
        if (detail.title.isNotEmpty) _videoTitle = detail.title;
        _videoCover = togetherCoverUrl(detail.cover);
        _episodes = detail.allEpisodes;
      });
    } catch (_) {
      // 详情拿不到不影响房间与播放。
    }
  }

  /* ------------------------------------------------------------ 换剧 / 选集 */

  Future<void> _changeVideo() async {
    if (!_isHost) {
      _hostOnlyToast();
      return;
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: const BoxDecoration(
            color: Color(0xFFF9FBFF),
            borderRadius: BorderRadius.all(Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sheetTile(
                Icons.movie_filter_rounded,
                '换一部剧',
                '选一部新片，所有人一起切换',
                () => Navigator.of(ctx).pop('video'),
              ),
              _sheetTile(
                Icons.list_alt_rounded,
                '选集',
                _episodes.isEmpty
                    ? '暂无剧集信息'
                    : '当前第 $_ep 集，共 ${_episodes.length} 集',
                _episodes.isEmpty
                    ? null
                    : () => Navigator.of(ctx).pop('episode'),
              ),
              _sheetTile(
                Icons.close_rounded,
                '取消',
                '',
                () => Navigator.of(ctx).pop(),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'video') {
      final card = await showTogetherVideoPicker(context);
      if (!mounted || card == null) return;
      _videoTitle = card.title;
      _videoCover = togetherCoverUrl(card.cover);
      _episodes = const <Episode>[];
      if (!_online) {
        togetherToast(context, '未连接服务器，请稍后重试');
        return;
      }
      _client.sendState('pause', 0, videoId: card.id, ep: 1, line: 'l1');
      _appendSystem('房主换成了《${card.title}》');
      return;
    }
    if (choice == 'episode') {
      final episode = await showTogetherEpisodePicker(
        context,
        episodes: _episodes,
        current: _ep,
        title: _videoTitle,
      );
      if (!mounted || episode == null || episode == _ep) return;
      if (!_online) {
        togetherToast(context, '未连接服务器，请稍后重试');
        return;
      }
      // 服务器会广播 room_state 和「切换到第 N 集」系统消息。
      _client.sendEpisode(episode, line: _videoLine);
    }
  }

  Widget _sheetTile(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback? onTap,
  ) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? .45 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Fx.accent.withOpacity(.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 17, color: Fx.accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Fx.ink,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 9.5,
                          color: Fx.sub.withOpacity(.9),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (onTap != null)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: Fx.sub.withOpacity(.5),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /* ------------------------------------------------------------ 消息 */

  void _appendMessage(TogetherChatMessage message) {
    if (!mounted) return;
    _messages.add(message);
    _trimMessages();
    _publishChat();
  }

  void _appendSystem(String text) {
    if (text.isEmpty) return;
    _appendMessage(TogetherChatMessage.system(text));
  }

  void _trimMessages() {
    if (_messages.length > 200) {
      _messages.removeRange(0, _messages.length - 200);
    }
  }

  void _publishChat() {
    if (!mounted) return;
    _chat.value = _messages.isEmpty
        ? const <TogetherChatMessage>[]
        : List<TogetherChatMessage>.unmodifiable(_messages);
  }

  void _clearMessages() {
    _messages.clear();
    _publishChat();
  }

  bool _sendChat(String text) {
    if (!_client.connected) {
      togetherToast(context, '正在重连，消息发送失败，请点重试');
      return false;
    }
    // 服务器会把消息广播回所有人（包括自己），无需本地回显。
    if (!_client.sendChat(text)) {
      togetherToast(context, '发送失败，请点重试');
      return false;
    }
    return true;
  }

  void _hostOnlyToast() {
    togetherToast(context, '仅房主可操作');
  }

  void _showMembers() {
    final members = _members;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
          decoration: const BoxDecoration(
            color: Color(0xFFF9FBFF),
            borderRadius: BorderRadius.all(Radius.circular(24)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '房间成员',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: Fx.ink,
                      ),
                    ),
                  ),
                  Text(
                    '${members.length} 人',
                    style: TextStyle(
                      fontSize: 10.5,
                      color: Fx.sub.withOpacity(.9),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Flexible(
                child: members.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 26),
                        child: Text(
                          '暂无成员',
                          style: TextStyle(
                            fontSize: 12,
                            color: Fx.sub.withOpacity(.75),
                          ),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final member in members)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 5),
                              child: Row(
                                children: [
                                  TogetherAvatar(
                                    name: member.name,
                                    avatar: member.avatar,
                                    size: 30,
                                    host: member.host,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      member.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w600,
                                        color: Fx.ink,
                                      ),
                                    ),
                                  ),
                                  if (member.host)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Fx.gold.withOpacity(.16),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Text(
                                        '房主',
                                        style: TextStyle(
                                          fontSize: 9,
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF9A6A00),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                        ],
                      ),
              ),
              const SizedBox(height: 4),
              GestureDetector(
                onTap: () => Navigator.of(ctx).pop(),
                child: Container(
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.9),
                    borderRadius: BorderRadius.circular(19),
                  ),
                  child: const Text(
                    '关闭',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Fx.sub,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /* ------------------------------------------------------------ 加入 / 建房 */

  Future<void> _pickAndCreate() async {
    final card = await showTogetherVideoPicker(context);
    if (!mounted || card == null) return;
    _videoTitle = card.title;
    _videoCover = togetherCoverUrl(card.cover);
    _episodes = const <Episode>[];
    _startCreate(card.id, 1);
  }

  void _joinByInput() {
    final code = _joinCtrl.text.replaceAll(RegExp(r'\D'), '');
    if (code.length != 6) {
      togetherToast(context, '请输入 6 位房间号');
      return;
    }
    FocusScope.of(context).unfocus();
    _join(code);
  }

  /* ------------------------------------------------------------ UI */

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_fullscreen) {
          _exitFullscreen();
          return;
        }
        _confirmExit();
      },
      child: Scaffold(
        backgroundColor:
            _fullscreen ? Colors.black : const Color(0xFFF6F8FC),
        resizeToAvoidBottomInset: !_fullscreen,
        body: _fullscreen
            ? _buildFullscreen()
            : FxBackground(
                child: SafeArea(
                  bottom: false,
                  child: switch (_stage) {
                    _TogetherStage.entry => _buildEntry(),
                    _TogetherStage.entering => _buildEntering(),
                    _TogetherStage.room => _buildRoom(),
                  },
                ),
              ),
      ),
    );
  }

  Widget _buildFullscreen() {
    final controller = _controller;
    final duration = controller != null && controller.value.isInitialized
        ? controller.value.duration.inMilliseconds / 1000.0
        : 0.0;
    final title = _videoTitle.isNotEmpty
        ? _videoTitle
        : (_roomTitle.isNotEmpty ? _roomTitle : '一起看');
    return TogetherFullscreenView(
      controller: controller,
      chat: _chat,
      members: _members,
      roomCode: _roomCode,
      title: title,
      ep: _ep,
      isHost: _isHost,
      online: _online,
      position: _position,
      duration: duration,
      onExit: _exitFullscreen,
      onTogglePlay: _togglePlay,
      onSeek: _seekTo,
      onHostOnly: _hostOnlyToast,
      onShowMembers: _showMembers,
      onSendChat: _sendChat,
    );
  }

  String get _roomSubtitle {
    final count = _members.length;
    final net = _online ? '已连接' : '未连接';
    final role = _isHost ? '房主' : '跟随房主';
    return '$count 人 · $net · $role';
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
                onTap: _confirmExit,
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
                              color: Fx.accent.withOpacity(.11),
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
                            color: Fx.sub.withOpacity(.35),
                          ),
                          filled: true,
                          fillColor: Colors.white.withOpacity(.76),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 13),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(15),
                            borderSide: BorderSide(
                                color: Colors.white.withOpacity(.95)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(15),
                            borderSide: const BorderSide(
                                color: Fx.accent, width: 1.2),
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
                          color: Fx.accent2.withOpacity(.10),
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
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
            child: GradButton(
              text: '创建一起看房间',
              icon: Icons.add_rounded,
              height: 48,
              onTap: _pickAndCreate,
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
              style: TextStyle(fontSize: 10.5, color: Fx.sub.withOpacity(.9)),
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: _backToEntry,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.85),
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

  Widget _buildRoom() {
    // 键盘弹出时把视频区收起，保证聊天与输入框不被挤压。
    final keyboard = MediaQuery.of(context).viewInsets.bottom > 0;
    return Column(
      children: [
        _buildHeader(),
        if (!keyboard) ...[
          _buildVideo(),
          _buildInfoRow(),
          if (!_online) _buildNetBanner(),
        ] else
          const SizedBox(height: 4),
        const SizedBox(height: 2),
        Expanded(child: _buildChat()),
        _buildComposer(),
      ],
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 4),
      child: Row(
        children: [
          TogetherCircleButton(
            icon: Icons.arrow_back_ios_new_rounded,
            size: 36,
            iconSize: 15,
            onTap: _confirmExit,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (_roomCode.isEmpty) return;
                togetherCopy(context, _roomCode, message: '房间号已复制');
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          '房间 ${_roomCode.isEmpty ? '——' : _roomCode}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: Fx.ink,
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Icon(
                        Icons.copy_rounded,
                        size: 12,
                        color: Fx.sub.withOpacity(.6),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _roomSubtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 9.5,
                      color: Fx.sub.withOpacity(.9),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          TogetherPill(
            text: '邀请',
            icon: Icons.person_add_alt_1_rounded,
            height: 30,
            accent: true,
            onTap: _showInvite,
          ),
          const SizedBox(width: 6),
          TogetherPill(
            text: '换剧/选集',
            icon: Icons.swap_horiz_rounded,
            height: 30,
            locked: !_isHost,
            onTap: _changeVideo,
          ),
        ],
      ),
    );
  }

  Future<void> _showInvite() async {
    if (!mounted) return;
    if (_roomCode.isEmpty) {
      togetherToast(context, '房间号还没准备好，请稍候');
      return;
    }
    final title = _videoTitle.isNotEmpty
        ? _videoTitle
        : (_roomTitle.isNotEmpty ? _roomTitle : '一起看');
    final invite =
        '我在幻想影视一起看《$title》，房间号 $_roomCode，打开 App 输入房间号加入';
    var copied = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: Colors.white.withOpacity(.98),
          surfaceTintColor: Colors.transparent,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
          contentPadding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
          title: const Row(
            children: [
              Icon(Icons.celebration_rounded, size: 20, color: Fx.accent),
              SizedBox(width: 8),
              Text(
                '邀请好友一起看',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: Fx.ink,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Fx.accent.withOpacity(.10),
                      Fx.accent2.withOpacity(.10),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white),
                ),
                child: Column(
                  children: [
                    const Text(
                      '房间号',
                      style: TextStyle(fontSize: 10.5, color: Fx.sub),
                    ),
                    const SizedBox(height: 3),
                    SelectableText(
                      _roomCode,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w900,
                        color: Fx.ink,
                        letterSpacing: 6,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF4F7FC),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  invite,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: Fx.sub,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                '复制后发给好友，对方打开 App 输入房间号即可加入',
                style: TextStyle(fontSize: 10, color: Color(0xFFA6B1C2)),
              ),
              const SizedBox(height: 14),
              GradButton(
                text: copied ? '已复制' : '复制邀请文案',
                icon: copied
                    ? Icons.check_rounded
                    : Icons.copy_all_rounded,
                height: 44,
                onTap: () async {
                  await Clipboard.setData(ClipboardData(text: invite));
                  if (!mounted || !ctx.mounted) return;
                  setLocal(() => copied = true);
                  togetherToast(ctx, '邀请文案已复制');
                },
              ),
            ],
          ),
          actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text(
                '关闭',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Fx.sub,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideo() {
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;
    final hasCover = togetherCoverUrl(_videoCover).startsWith('http');
    // 屏幕较矮时按高度收缩，避免视频区把聊天/输入框挤出屏幕。
    final maxVideoHeight = MediaQuery.sizeOf(context).height * .32;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxVideoHeight),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Container(
              color: _videoBg,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (!ready && hasCover)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Opacity(
                          opacity: .4,
                          child: TogetherCover(
                            cover: _videoCover,
                            title: _videoTitle,
                            radius: 0,
                            showTitle: false,
                          ),
                        ),
                      ),
                    ),
                  if (!ready && hasCover)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.black.withOpacity(.35),
                                Colors.black.withOpacity(.62),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (ready)
                    Center(
                      child: AspectRatio(
                        aspectRatio: controller.value.aspectRatio > 0
                            ? controller.value.aspectRatio
                            : 16 / 9,
                        child: controller.buildVideo(),
                      ),
                    )
                  else
                    _buildVideoPlaceholder(),
                  Positioned(left: 8, top: 8, child: _buildSyncChip()),
                  if (ready) ...[
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _togglePlay,
                      ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Center(child: _buildCenterIcon(controller)),
                      ),
                    ),
                    Positioned(
                      left: 10,
                      right: 10,
                      bottom: 5,
                      child: _buildProgress(controller),
                    ),
                    Positioned(
                      right: 8,
                      top: 8,
                      child: _buildFullscreenButton(),
                    ),
                    // 已就绪后播放中途出错（hasError）也要能看到错误条 + 重试。
                    if (_videoError.isNotEmpty)
                      Positioned(
                        left: 8,
                        right: 8,
                        top: 34,
                        child: _buildVideoErrorBar(),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFullscreenButton() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _enterFullscreen,
      child: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(.44),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: Colors.white.withOpacity(.22)),
        ),
        child: const Icon(
          Icons.fullscreen_rounded,
          size: 19,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildCenterIcon(FxPlayer controller) {
    final playing = controller.value.isPlaying;
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.34),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withOpacity(.32)),
      ),
      child: Icon(
        _isHost
            ? (playing ? Icons.pause_rounded : Icons.play_arrow_rounded)
            : Icons.lock_outline_rounded,
        size: 22,
        color: Colors.white.withOpacity(.94),
      ),
    );
  }

  Widget _buildProgress(FxPlayer controller) {
    final total = controller.value.duration.inMilliseconds / 1000.0;
    // 进度每 500ms 只重建这一小块，不重建整页。
    return ValueListenableBuilder<double>(
      valueListenable: _position,
      builder: (context, position, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TogetherSeekBar(
            position: position,
            duration: total,
            enabled: _isHost,
            onSeek: _seekTo,
            onBlocked: _hostOnlyToast,
          ),
          const SizedBox(height: 1),
          Row(
            children: [
              Text(togetherFmt(position), style: _timeStyle),
              const Spacer(),
              if (!_isHost && _remote?.playing == true) ...[
                Text(
                  '跟随房主',
                  style: _timeStyle.copyWith(
                    color: Colors.white.withOpacity(.75),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Text(togetherFmt(total), style: _timeStyle),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSyncChip() {
    final state = _remote;
    final String text;
    if (!_online) {
      text = '未连接';
    } else if (_isHost) {
      text = state?.playing == true ? '房主 · 播放中' : '房主 · 已暂停';
    } else {
      text = state?.playing == true ? '跟随房主 · 播放中' : '跟随房主 · 已暂停';
    }
    final dot = _online ? const Color(0xFF57D3A3) : const Color(0xFFFF8A80);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.42),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(
            _online ? '$text · ${_client.rtt}ms' : text,
            style: const TextStyle(
              fontSize: 8.5,
              fontWeight: FontWeight.w600,
              color: Color(0xE6FFFFFF),
            ),
          ),
        ],
      ),
    );
  }

  /// 播放已就绪后出错（hasError）：视频区顶部错误条，所有角色都能重试。
  Widget _buildVideoErrorBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.62),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: Colors.white.withOpacity(.18)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 13,
            color: Color(0xFFFF8A80),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              _videoError,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 9.5,
                height: 1.2,
                color: Color(0xE6FFFFFF),
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _retryVideo,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(.18),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                '重试',
                style: TextStyle(
                  fontSize: 9.5,
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoPlaceholder() {
    final String text;
    if (_videoLoading) {
      text = '正在加载视频…';
    } else if (_videoError.isNotEmpty) {
      text = _videoError;
    } else if (_isHost) {
      text = '点击播放，和朋友一起看';
    } else {
      text = '等待房主播放';
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_videoLoading)
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
              ),
            )
          else
            Icon(
              _videoError.isNotEmpty
                  ? Icons.videocam_off_rounded
                  : Icons.movie_filter_rounded,
              size: 28,
              color: Colors.white.withOpacity(.5),
            ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10.5,
                height: 1.4,
                color: Colors.white.withOpacity(.72),
              ),
            ),
          ),
          // 非房主也会遇到视频加载失败（换线路/断线），必须一起给重试入口。
          if (!_videoLoading && _videoError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: GestureDetector(
                onTap: _retryVideo,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.16),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: const Text(
                    '重试',
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildInfoRow() {
    final title = _videoTitle.isNotEmpty
        ? _videoTitle
        : (_roomTitle.isNotEmpty ? _roomTitle : '一起看');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Fx.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '第 $_ep 集${_episodes.isNotEmpty ? ' / 共 ${_episodes.length} 集' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    color: Fx.sub.withOpacity(.9),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _showMembers,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: togetherGlass(radius: 11, opacity: .7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.people_alt_outlined,
                    size: 12,
                    color: Fx.sub.withOpacity(.9),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${_members.length} 人',
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w600,
                      color: Fx.sub.withOpacity(.95),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNetBanner() {
    const text = '连接已断开 · 正在自动重连…';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF3D6).withOpacity(.85),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              size: 12,
              color: Color(0xFF9A6A00),
            ),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 9, color: Color(0xFF9A6A00)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChat() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Container(
        decoration: togetherGlass(radius: 20, opacity: .58),
        clipBehavior: Clip.antiAlias,
        // 只监听新消息，网络状态变化不重建聊天列表。
        child: _chatView,
      ),
    );
  }

  Widget _buildComposer() {
    return SafeArea(
      top: false,
      child: TogetherComposer(
        // 断开时也允许输入：发送失败会保留文字并给重试按钮。
        enabled: true,
        hint: _online ? '随便说点啥吧...' : '正在重连，消息会保留可重试',
        onSend: _sendChat,
      ),
    );
  }
}

/* ========================================================================== */
/*  自定义进度条（白玻璃）                                                     */
/* ========================================================================== */

class TogetherSeekBar extends StatefulWidget {
  const TogetherSeekBar({
    super.key,
    required this.position,
    required this.duration,
    required this.enabled,
    required this.onSeek,
    required this.onBlocked,
  });

  final double position;
  final double duration;
  final bool enabled;
  final ValueChanged<double> onSeek;
  final VoidCallback onBlocked;

  @override
  State<TogetherSeekBar> createState() => _TogetherSeekBarState();
}

class _TogetherSeekBarState extends State<TogetherSeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final max = widget.duration > 0 ? widget.duration : 0.0;
    final shown = (_drag ?? widget.position).clamp(0.0, max <= 0 ? 1.0 : max);
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth <= 0 ? 1.0 : box.maxWidth;
        final ratio = max <= 0 ? 0.0 : (shown.toDouble() / max).clamp(0.0, 1.0);

        double valueAt(double dx) {
          if (max <= 0) return 0;
          return (dx / width).clamp(0.0, 1.0) * max;
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? null : widget.onBlocked,
          onTapUp: widget.enabled
              ? (details) {
                  final value = valueAt(details.localPosition.dx);
                  setState(() => _drag = null);
                  widget.onSeek(value);
                }
              : null,
          onHorizontalDragStart: widget.enabled
              ? (details) =>
                  setState(() => _drag = valueAt(details.localPosition.dx))
              : null,
          onHorizontalDragUpdate: widget.enabled
              ? (details) =>
                  setState(() => _drag = valueAt(details.localPosition.dx))
              : null,
          onHorizontalDragEnd: widget.enabled
              ? (_) {
                  final value = _drag;
                  setState(() => _drag = null);
                  if (value != null) widget.onSeek(value);
                }
              : null,
          onHorizontalDragCancel:
              widget.enabled ? () => setState(() => _drag = null) : null,
          child: SizedBox(
            height: 16,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    height: 3,
                    width: width,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(.26),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: ratio,
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        gradient: Fx.brand,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment(ratio * 2 - 1, 0),
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(.28),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

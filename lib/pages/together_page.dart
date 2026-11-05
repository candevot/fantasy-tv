import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../models.dart';
import '../services/fx_player.dart';
import '../theme.dart';
import '../widgets/player_theme.dart';
import '../widgets/together_chat.dart';
import '../widgets/together_client.dart';
import '../widgets/together_fullscreen.dart';
import '../widgets/together_picker.dart';
import '../widgets/together_room.dart';
import '../widgets/together_sheets.dart';
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

class TogetherPage extends StatefulWidget {
  const TogetherPage({super.key, this.videoId, this.ep = 1});

  /// 从详情页进入时直接创建房间；为空时显示一起看入口。
  final String? videoId;
  final int ep;

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
  int _lastRev = -1;
  String _lastRevCode = '';

  List<TogetherMember> _members = const <TogetherMember>[];

  final List<TogetherChatMessage> _messages = <TogetherChatMessage>[];
  final ValueNotifier<List<TogetherChatMessage>> _chat =
      ValueNotifier<List<TogetherChatMessage>>(const <TogetherChatMessage>[]);

  String _videoId = '';
  int _ep = 1;
  String _videoLine = 'l1';
  String _videoTitle = '';
  String _videoCover = '';
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

  final ValueNotifier<double> _position = ValueNotifier<double>(0);

  Timer? _ticker;
  Timer? _heartbeat;
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
    );
    WidgetsBinding.instance.addObserver(this);
    _startTimers();
    final videoId = (widget.videoId ?? '').trim();
    if (videoId.isNotEmpty) {
      _videoId = videoId;
      _ep = widget.ep < 1 ? 1 : widget.ep;
      _createRoom(videoId, _ep);
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
    _position.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      if (_stage == _TogetherStage.room) {
        // 不断连：socket 还在就直接要一次权威状态，否则重连。
        if (_client.connected) {
          _client.refreshRoom();
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
      _syncVideo();
      // 重连时 hello 先于 join，此时直接写 state 会被服务器拒绝；
      // 等 room_state 回来后再把房主本地进度写回。
      if (_isHost) _needsHostResync = true;
    }
  }

  void _onDown() {
    if (!mounted) return;
    final wasOnline = _online;
    setState(() => _online = false);
    if (!_entered && _stage == _TogetherStage.entering) {
      _backToEntry();
      togetherToast(context, '连不上一起看服务器，稍后再试');
      return;
    }
    if (_entered && wasOnline && !_downReported) {
      _downReported = true;
      if (_isHost) _needsHostResync = true;
      _appendSystem('连接断开，正在自动重连…');
      togetherToast(context, '连接断开，正在自动重连…');
    }
  }

  void _onRoom(TogetherRoomInfo info) {
    if (!mounted) return;
    if (!_wantsRoom) {
      // 用户已取消进入，服务器却建好了房：顺手清理，避免留空房。
      _client.leave();
      return;
    }
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
      _remote = null;
      _lastRev = -1;
      _lastRevCode = '';
    });
    _downReported = false;
    _position.value = 0;
    _syncVideo();
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
    if (changedVideo || changedEp) {
      _resumePos = null;
      _resumePlaying = false;
    }
    if (changedVideo || changedEp || changedLine) _syncVideo();
    if (!_isHost) {
      _applyRemotePlayback(state);
    } else if (_needsHostResync) {
      _needsHostResync = false;
      _resync();
    }
    _position.value = _displayPosition();
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

  /* ------------------------------------------------------------ 建房 / 加入 */

  void _createRoom(String videoId, int ep) {
    _clearMessages();
    _wantsRoom = true;
    _enteringAsHost = true;
    _entered = false;
    _leaving = false;
    _exiting = false;
    _remote = null;
    _roomCode = '';
    _lastRev = -1;
    _lastRevCode = '';
    _stage = _TogetherStage.entering;
    _stageText = '正在创建房间…';
    _videoId = videoId;
    _ep = ep < 1 ? 1 : ep;
    _videoLine = 'l1';
    _qualityKey = null;
    _playInfo = null;
    _detailVideoId = '';
    _lines = const <LineInfo>[];
    _episodes = const <Episode>[];
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
    _loadVideoTitle(videoId);
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
    _resumePos = null;
    _resumePlaying = false;
    _detailVideoId = '';
    _position.value = 0;
    unawaited(_disposeController());
    if (!mounted) return;
    setState(() {
      _stage = _TogetherStage.entry;
      _entered = false;
      _isHost = false;
      _online = _client.connected;
      _roomCode = '';
      _roomTitle = '';
      _remote = null;
      _members = const <TogetherMember>[];
      _messages.clear();
      _chat.value = const <TogetherChatMessage>[];
      _videoId = '';
      _videoTitle = '';
      _videoCover = '';
      _episodes = const <Episode>[];
      _lines = const <LineInfo>[];
      _ep = 1;
      _videoLine = 'l1';
      _playInfo = null;
      _qualityKey = null;
      _loadedKey = '';
      _loadingKey = '';
      _videoLoading = false;
      _videoError = '';
      _lastRev = -1;
      _lastRevCode = '';
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
    if (_fullscreen) await _exitFullscreen();
    if (!mounted) return;
    _client.leave();
    _videoSeq++;
    await _disposeController();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _saveRoomProgress() async {
    final controller = _controller;
    final position = controller != null && controller.value.isInitialized
        ? controller.value.position.inMilliseconds / 1000.0
        : _displayPosition();
    if (_videoId.isEmpty || _ep <= 0) return;
    // 0 秒不覆盖详情页原本的进度；有真实观看进度才回写。
    if (!position.isFinite || position <= .5) return;
    try {
      await fxSaveProgress(_videoId, _ep, position);
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
    _ticker ??=
        Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
    _heartbeat ??=
        Timer.periodic(const Duration(seconds: 9), (_) => _hostHeartbeat());
  }

  void _resync() {
    if (_stage != _TogetherStage.room) return;
    if (_isHost) {
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
      final state = _remote;
      if (state != null) _applyRemotePlayback(state);
    }
    _tick(force: true);
  }

  void _hostHeartbeat() {
    if (!mounted || !_isHost || !_online || !_foreground) return;
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

  /* ------------------------------------------------------------ 同步 */

  double _targetPosition(TogetherRoomState state) {
    var position = state.position;
    if (state.playing && state.at > 0 && _client.synced) {
      position += (_client.nowServerMs() - state.at) / 1000.0;
    }
    if (!position.isFinite || position < 0) return 0;
    return position > 86400 ? 86400 : position;
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
    final state = _remote;
    if (state != null) return _targetPosition(state);
    if (controller != null && controller.value.isInitialized) {
      return controller.value.position.inMilliseconds / 1000.0;
    }
    return 0;
  }

  void _tick({bool force = false}) {
    if (!mounted || _stage != _TogetherStage.room) return;
    final controller = _controller;
    final state = _remote;
    if (!_isHost &&
        controller != null &&
        controller.value.isInitialized &&
        state != null) {
      final target = _targetPosition(state);
      final current = controller.value.position.inMilliseconds / 1000.0;
      final drift = target - current;
      if (!state.playing) {
        _applyPlaybackRate(1);
        if (drift.abs() > .6) _seekController(target);
      } else if (drift.abs() > 3) {
        _applyPlaybackRate(1);
        _seekController(target);
      } else if (drift.abs() > .5) {
        _applyPlaybackRate(drift > 0 ? 1.08 : .92);
      } else {
        _applyPlaybackRate(1);
      }
    }
    final value = _displayPosition();
    if (force || (value - _position.value).abs() >= .05) {
      _position.value = value;
    }
  }

  void _applyPlaybackRate(double rate) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if ((controller.rate - rate).abs() < .02) return;
    controller.setRate(rate).catchError((_) {});
  }

  void _seekController(double seconds) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    var value = seconds;
    if (!value.isFinite || value < 0) value = 0;
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
    _applyPlaybackRate(1);
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
    if (changed && mounted) setState(() {});
    if (mounted) _position.value = position;
  }

  void _bounceToAuthority() {
    final state = _remote;
    if (state == null) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final target = _targetPosition(state);
    _applyPlaybackRate(1);
    _seekController(target);
    if (state.playing) {
      controller.play().catchError((_) {});
    } else {
      controller.pause().catchError((_) {});
    }
    _tick(force: true);
  }

  void _onVideoValue() {
    final controller = _controller;
    if (controller == null || !mounted) return;
    final value = controller.value;
    if (value.hasError && _videoError.isEmpty) {
      setState(() => _videoError = '播放中断，点重试即可恢复');
      return;
    }
    if (_endedSent || !_isHost || !value.isInitialized) return;
    if (value.duration.inMilliseconds <= 0) return;
    if (value.position >= value.duration - const Duration(milliseconds: 400)) {
      _endedSent = true;
      final position = value.position.inMilliseconds / 1000.0;
      if (_online) _client.sendState('ended', position);
      _markRemote('ended', position);
      if (mounted) setState(() {});
    }
  }

  /* ------------------------------------------------------------ 播放操作 */

  void _hostOnly() {
    togetherToast(context, '跟随房主');
  }

  void _togglePlay() {
    if (!_isHost) {
      _hostOnly();
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
    if (_online) _client.sendState('play', start);
    _markRemote('play', start);
    if (mounted) setState(() {});
  }

  void _seekTo(double seconds) {
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
    if (_online) {
      _client.sendSeek(target);
      _markRemote(_remote?.playing == true ? 'play' : 'pause', target);
    }
    if (mounted) _position.value = target;
  }

  void _seekBy(int seconds) {
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
    final value = rate.clamp(.5, 2.0).toDouble();
    _hostRate = value;
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      controller.setRate(value).catchError((_) {});
    }
    if (mounted) setState(() {});
    togetherToast(context, '${togetherRateLabel(value)} 倍速');
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
    final playableLines = _lines.where((line) => !line.needsParse).toList();
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
    if (!_online) {
      togetherToast(context, '未连接服务器，请稍后重试');
      return;
    }
    setState(() {
      _videoTitle = card.title;
      _videoCover = togetherCoverUrl(card.cover);
      _episodes = const <Episode>[];
      _qualityKey = null;
      _playInfo = null;
    });
    _client.sendState(
      'pause',
      0,
      videoId: card.id,
      ep: 1,
      line: 'l1',
    );
    togetherToast(context, '正在切换影片…');
  }

  Future<void> _pickEpisode() async {
    if (!_isHost) {
      _hostOnly();
      return;
    }
    if (_episodes.isEmpty) {
      togetherToast(context, '暂无剧集信息');
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
      togetherToast(context, '未连接服务器，请稍后重试');
      return;
    }
    _client.sendEpisode(episode, line: _videoLine);
  }

  void _nextEpisode() {
    if (!_isHost) {
      _hostOnly();
      return;
    }
    if (_episodes.isEmpty) {
      togetherToast(context, '暂无剧集信息');
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
      togetherToast(context, '已是最后一集');
      return;
    }
    if (!_online) {
      togetherToast(context, '未连接服务器，请稍后重试');
      return;
    }
    _client.sendEpisode(next, line: _videoLine);
  }

  Future<void> _pickQuality() async {
    if (!_isHost) {
      _hostOnly();
      return;
    }
    final items = _playInfo?.quality ?? const <QualityItem>[];
    if (items.length < 2) {
      togetherToast(context, '当前线路暂无更多清晰度');
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

  Future<void> _setQuality(String? key) async {
    if (!_isHost) {
      _hostOnly();
      return;
    }
    if (key == _qualityKey) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      togetherToast(context, '视频还没准备好');
      return;
    }
    _resumePos = controller.value.position.inMilliseconds / 1000.0;
    _resumePlaying = controller.value.isPlaying;
    setState(() => _qualityKey = key);
    _loadedKey = '';
    _loadingKey = '';
    _syncVideo();
    togetherToast(context, '正在切换清晰度…');
  }

  Future<void> _pickLine() async {
    if (!_isHost) {
      _hostOnly();
      return;
    }
    final playable = _lines.where((line) => !line.needsParse).toList();
    if (playable.length < 2) {
      togetherToast(context, '当前只有一条播放线路');
      return;
    }
    final picked = await showTogetherLineSheet(
      context,
      lines: playable,
      current: _videoLine,
    );
    if (!mounted || picked == null || picked == _videoLine) return;
    if (!_online) {
      togetherToast(context, '未连接服务器，请稍后重试');
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
    _client.sendState(
      playing ? 'play' : 'pause',
      position,
      videoId: _videoId,
      ep: _ep,
      line: picked,
    );
    togetherToast(context, '正在切换线路…');
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
    await showTogetherMembers(context, members: _members);
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
      final detail = await Api.detail(videoId);
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

  void _syncVideo() {
    if (_videoId.isEmpty) return;
    final key = '$_videoId|$_ep|$_videoLine';
    if (key == _loadedKey || key == _loadingKey) return;
    unawaited(_loadVideo(_videoId, _ep, _videoLine));
  }

  Future<void> _loadVideo(String videoId, int ep, String line) async {
    final key = '$videoId|$ep|$line';
    _loadingKey = key;
    final seq = ++_videoSeq;
    _endedSent = false;

    // 先摘掉旧 controller 并进入加载态（页面先重建为占位/加载浮层），
    // 再异步 pause → stop → dispose，避免旧画面在释放期间继续渲染。
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

    var playable = _lines.where((item) => !item.needsParse).toList();
    if (playable.isEmpty) {
      // 详情拿不到时仍尝试一次默认线路，避免房间完全不可看。
      playable = <LineInfo>[
        LineInfo(line.isEmpty ? 'l1' : line, '默认线路', 'hls', 0),
      ];
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
        play = await Api.play(videoId, ep, lineInfo.id);
      } catch (_) {
        continue;
      }
      if (!mounted || seq != _videoSeq) return;
      if (play.type.trim().toLowerCase() == 'parse') continue;
      _playInfo = play;

      final urls = <String>[];
      final primary = _qualityUrl(play);
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

          final duration = controller.value.duration.inMilliseconds / 1000.0;
          double target;
          bool shouldPlay;
          if (_isHost) {
            final resume = _resumePos;
            final state = _remote;
            if (resume != null) {
              target = resume;
              shouldPlay = _resumePlaying;
            } else if (state != null && state.playing) {
              target = _targetPosition(state);
              shouldPlay = true;
            } else {
              target = 0;
              shouldPlay = false;
            }
          } else {
            final state = _remote;
            target = state == null ? 0 : _targetPosition(state);
            shouldPlay = state?.playing ?? false;
          }
          if (!target.isFinite || target < 0) target = 0;
          if (duration > 0 && target > duration - 1) target = 0;
          if (target > 0) {
            await controller.seekTo(
              Duration(milliseconds: (target * 1000).round()),
            );
          }
          await controller.setRate(_isHost ? _hostRate : 1.0);
          if (shouldPlay) {
            await controller.play();
          } else {
            // 暂停态也先拉一帧，避免切集/切线路后黑屏。
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

          _resumePos = null;
          _resumePlaying = false;
          _loadingKey = '';
          _loadedKey = key;
          if (mounted) {
            setState(() {
              _videoLoading = false;
              _videoError = '';
            });
          }
          _position.value = target;
          if (!_isHost && _remote != null) {
            _applyRemotePlayback(_remote!);
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
    setState(() {
      _videoLoading = false;
      _videoError = '暂时无法播放，请重试或让房主切换线路';
    });
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
        List<TogetherChatMessage>.from(_messages));
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
    _videoTitle = card.title;
    _videoCover = togetherCoverUrl(card.cover);
    _episodes = const <Episode>[];
    _createRoom(card.id, 1);
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
      qualityLabel: fxPlayerQuality(_controller),
      qualityKey: _qualityKey,
      canChangeQuality: (_playInfo?.quality.length ?? 0) >= 2,
      qualities: _playInfo?.quality ?? const <QualityItem>[],
      rate: _isHost ? _hostRate : 1.0,
      onExit: () => unawaited(_exitFullscreen()),
      onExitRoom: () => unawaited(_confirmLeaveRoom()),
      onInvite: () => unawaited(_showInvite()),
      onMembers: () => unawaited(_showMembers()),
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
      onBack: () => unawaited(_confirmLeaveRoom()),
      onCopyCode: () {
        if (_roomCode.isEmpty) return;
        unawaited(togetherCopy(context, _roomCode, message: '房间号已复制'));
      },
      onInvite: () => unawaited(_showInvite()),
      onMembers: () => unawaited(_showMembers()),
      onMedia: () => unawaited(_showMediaSheet()),
      onTogglePlay: _togglePlay,
      onSeek: _seekTo,
      onEnterFullscreen: () => unawaited(_enterFullscreen()),
      onSendChat: _sendChat,
      onRetry: _retryVideo,
      onHostOnly: _hostOnly,
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
                            horizontal: 12,
                            vertical: 13,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(15),
                            borderSide: BorderSide(
                              color: Colors.white.withOpacity(.95),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(15),
                            borderSide:
                                const BorderSide(color: Fx.accent, width: 1.2),
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
                color: Fx.sub.withOpacity(.9),
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
}

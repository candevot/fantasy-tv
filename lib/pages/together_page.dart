import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/together_chat.dart';
import '../widgets/together_client.dart';
import '../widgets/together_picker.dart';
import '../widgets/together_ui.dart';

/* ========================================================================== */
/*  一起看                                                                     */
/*  广场：GET /api/together/rooms（失败空态） + 创建／加入房间                 */
/*  房间：16:9 视频（房主控制） + 聊天 + 服务器权威同步（API.md §4）            */
/* ========================================================================== */

enum _TogetherStage { lobby, entering, room }

class TogetherPage extends StatefulWidget {
  const TogetherPage({super.key, this.videoId, this.ep = 1});

  /// 从播放页带过来时直接建房，不再选片。
  final String? videoId;
  final int ep;

  @override
  State<TogetherPage> createState() => _TogetherPageState();
}

class _TogetherPageState extends State<TogetherPage> {
  static const Color _videoBg = Color(0xFF101722);
  static const TextStyle _timeStyle = TextStyle(
    fontSize: 9,
    fontWeight: FontWeight.w600,
    color: Color(0xCCFFFFFF),
  );

  late final TogetherClient _client;

  /* 页面 / 房间 */
  _TogetherStage _stage = _TogetherStage.lobby;
  bool _entered = false;
  bool _enteringAsHost = false;
  String _stageText = '';
  bool _exiting = false;

  bool _online = false;
  bool _demo = false;
  bool _isHost = false;

  String _myId = '';
  String _myName = '我';
  String _myAvatar = '';

  String _roomCode = '';
  String _roomTitle = '';
  List<TogetherMember> _members = const <TogetherMember>[];
  TogetherRoomState? _remote;
  int _lastRev = -1;
  String _lastRevCode = '';

  final List<TogetherChatMessage> _messages = <TogetherChatMessage>[];

  /* 播放 */
  VideoPlayerController? _controller;
  String _videoId = '';
  int _ep = 1;
  String _videoLine = 'l1';
  String _videoTitle = '';
  String _videoCover = '';
  List<Episode> _episodes = const <Episode>[];
  String _loadedKey = '';
  bool _videoLoading = false;
  String _videoError = '';
  int _videoSeq = 0;
  bool _endedSent = false;
  double _rate = 1;
  double? _resumePos;
  bool _resumePlaying = false;

  /* 广场 */
  List<TogetherRoomBrief> _rooms = const <TogetherRoomBrief>[];
  bool _roomsLoading = false;
  bool _roomsReachable = true;

  Timer? _ticker;
  Timer? _heartbeat;
  Timer? _enterTimer;
  bool _downReported = false;

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
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
    _heartbeat =
        Timer.periodic(const Duration(seconds: 9), (_) => _hostHeartbeat());
    final videoId = (widget.videoId ?? '').trim();
    if (videoId.isNotEmpty) {
      _videoId = videoId;
      _ep = widget.ep < 1 ? 1 : widget.ep;
      _startCreate(videoId, _ep);
    } else {
      _loadRooms();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _heartbeat?.cancel();
    _enterTimer?.cancel();
    _ticker = null;
    _heartbeat = null;
    _enterTimer = null;
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      controller.removeListener(_onVideoValue);
      controller.dispose().catchError((_) {});
    }
    _client.dispose();
    super.dispose();
  }

  /* ------------------------------------------------------------ 网络回调 */

  void _onOpen(TogetherMember me) {
    if (!mounted) return;
    final first = _myId.isEmpty;
    setState(() {
      _online = true;
      _downReported = false;
      if (me.id.isNotEmpty) _myId = me.id;
      if (me.name.isNotEmpty) _myName = me.name;
      _myAvatar = me.avatar;
      if (!first) _addSystem('已重新连接服务器');
    });
    if (_demo && _videoId.isNotEmpty) {
      // 演示中恢复连接 → 用真实房间替换本地演示房。
      _client.createRoom(
        videoId: _videoId,
        ep: _ep,
        line: _videoLine,
        title: _videoTitle.isEmpty ? '' : '$_videoTitle · 一起看',
      );
    }
  }

  void _onDown() {
    if (!mounted) return;
    final wasOnline = _online;
    setState(() => _online = false);
    if (!_entered && _stage == _TogetherStage.entering) {
      if (_enteringAsHost) {
        _degradeToDemo();
      } else {
        _backToLobby();
        togetherToast(context, '连不上服务器，稍后再试');
      }
      return;
    }
    if (wasOnline && _entered && !_downReported) {
      _downReported = true;
      setState(() => _addSystem('连接断开，3 秒后自动重连…'));
      togetherToast(context, '连接断开，正在重连…');
    }
  }

  void _onRoom(TogetherRoomInfo info) {
    if (!mounted) return;
    final resume = _roomCode.isNotEmpty && !_demo;
    if (resume) _captureResume();
    setState(() {
      _stage = _TogetherStage.room;
      _entered = true;
      _demo = false;
      _online = true;
      _isHost = true;
      _roomCode = info.code;
      _roomTitle = info.title;
      if (info.videoId.isNotEmpty) _videoId = info.videoId;
      if (info.ep > 0) _ep = info.ep;
      if (info.line.isNotEmpty) _videoLine = info.line;
      if (info.members.isNotEmpty) _members = info.members;
      _remote = null;
      _lastRev = -1;
      _lastRevCode = '';
      _addSystem('房间: ${info.code}');
    });
    _loadDetail(_videoId);
    _syncVideo();
  }

  void _onState(TogetherRoomState state) {
    if (!mounted) return;
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
      _demo = false;
      _online = true;
      if (state.code.isNotEmpty) _roomCode = state.code;
      if (state.title.isNotEmpty) _roomTitle = state.title;
      if (state.members.isNotEmpty) _members = state.members;
      if (state.videoId.isNotEmpty) _videoId = state.videoId;
      if (state.ep > 0) _ep = state.ep;
      if (state.line.isNotEmpty) _videoLine = state.line;
      if (firstEnter) _addSystem('房间: ${state.code}');
      if (changedVideo && !_isHost) _addSystem('房主换了一部影片');
    });
    if (changedVideo) _loadDetail(_videoId);
    _syncVideo();
    _applyRemotePlayback(state);
  }

  void _onChat(TogetherChatIncoming chat) {
    if (!mounted || chat.text.isEmpty) return;
    setState(() {
      _messages.add(TogetherChatMessage(
        text: chat.text,
        time: DateTime.now(),
        user: chat.name,
        avatar: chat.avatar,
        mine: chat.userId.isNotEmpty && chat.userId == _myId,
      ));
    });
  }

  void _onSystem(String text) {
    if (!mounted || text.isEmpty) return;
    final line = text.replaceAll('加入了房间', '进入房间');
    setState(() => _addSystem(line));
  }

  void _onError(String code, String message) {
    if (!mounted) return;
    if (code == 'host_only') {
      togetherToast(context, '跟随房主');
      _bounceToAuthority();
      return;
    }
    if (code == 'not_found' || code == 'room_full') {
      togetherToast(context, message.isEmpty ? '房间不存在或已解散' : message);
      if (_stage == _TogetherStage.entering) _backToLobby();
      return;
    }
    if (message.isNotEmpty) togetherToast(context, message);
  }

  void _onClosed(String reason) {
    if (!mounted) return;
    _enterTimer?.cancel();
    final text = reason.isEmpty ? '房间已解散' : reason;
    setState(() {
      _addSystem(text);
      _stage = _TogetherStage.lobby;
      _entered = false;
      _demo = false;
      _isHost = false;
      _roomCode = '';
      _remote = null;
      _members = const <TogetherMember>[];
      _messages.clear();
      _videoId = '';
      _videoTitle = '';
      _videoCover = '';
      _episodes = const <Episode>[];
      _ep = 1;
      _loadedKey = '';
      _videoLoading = false;
      _videoError = '';
    });
    _disposeController();
    togetherToast(context, text);
    _loadRooms();
  }

  /* ------------------------------------------------------------ 建房 / 加入 */

  void _startCreate(String videoId, int ep) {
    _enteringAsHost = true;
    _entered = false;
    _demo = false;
    _remote = null;
    _stage = _TogetherStage.entering;
    _stageText = '正在创建房间…';
    _videoId = videoId;
    _ep = ep < 1 ? 1 : ep;
    _videoLine = 'l1';
    _loadedKey = '';
    _videoError = '';
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
    _enteringAsHost = false;
    _entered = false;
    _demo = false;
    _remote = null;
    _stage = _TogetherStage.entering;
    _stageText = '正在加入房间 $code…';
    _videoId = '';
    _videoTitle = '';
    _videoCover = '';
    _episodes = const <Episode>[];
    _ep = 1;
    _loadedKey = '';
    _videoError = '';
    _client.joinRoom(code);
    _client.connect();
    _armEnterTimer();
    if (mounted) setState(() {});
  }

  void _armEnterTimer() {
    _enterTimer?.cancel();
    _enterTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted || _entered || _stage != _TogetherStage.entering) return;
      if (_enteringAsHost) {
        _degradeToDemo();
      } else {
        _backToLobby();
        togetherToast(context, '连不上服务器，稍后再试');
      }
    });
  }

  /// 连不上服务器时的优雅降级：单人演示房，聊天/播放仍然可用。
  void _degradeToDemo() {
    if (!mounted || _entered) return;
    _enterTimer?.cancel();
    _demo = true;
    _isHost = true;
    _online = false;
    _entered = true;
    _roomCode = '${100000 + math.Random().nextInt(900000)}';
    _roomTitle = _videoTitle.isEmpty ? '一起看' : '$_videoTitle · 一起看';
    _members = <TogetherMember>[
      TogetherMember(
        id: _myId.isEmpty ? 'me' : _myId,
        name: _myName,
        avatar: _myAvatar,
        host: true,
      ),
    ];
    setState(() {
      _stage = _TogetherStage.room;
      _addSystem('房间: $_roomCode');
      _addSystem('未连接服务器 · 当前为单人演示');
    });
    _loadedKey = '';
    _syncVideo();
    togetherToast(context, '未连接服务器，已进入单人演示');
  }

  void _backToLobby() {
    _enterTimer?.cancel();
    _client.leave();
    _resumePos = null;
    _disposeController();
    if (!mounted) return;
    setState(() {
      _stage = _TogetherStage.lobby;
      _entered = false;
      _demo = false;
      _isHost = false;
      _online = false;
      _roomCode = '';
      _roomTitle = '';
      _remote = null;
      _members = const <TogetherMember>[];
      _messages.clear();
      _videoId = '';
      _videoTitle = '';
      _videoCover = '';
      _episodes = const <Episode>[];
      _ep = 1;
      _videoLine = 'l1';
      _loadedKey = '';
      _videoLoading = false;
      _videoError = '';
      _lastRev = -1;
      _lastRevCode = '';
    });
    _loadRooms();
  }

  Future<void> _confirmExit() async {
    if (!mounted || _exiting) return;
    if (_stage == _TogetherStage.lobby) {
      Navigator.of(context).pop();
      return;
    }
    if (_stage == _TogetherStage.entering) {
      _client.leave();
      Navigator.of(context).pop();
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
    _client.leave();
    Navigator.of(context).pop();
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
    if ((_isHost || _demo) && controller != null && controller.value.isInitialized) {
      return controller.value.position.inMilliseconds / 1000.0;
    }
    if (state != null) return _targetPosition(state);
    if (controller != null && controller.value.isInitialized) {
      return controller.value.position.inMilliseconds / 1000.0;
    }
    return 0;
  }

  void _tick() {
    if (!mounted || _stage != _TogetherStage.room) return;
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
    setState(() {});
  }

  void _applyRate(double rate) {
    if ((_rate - rate).abs() < .02) return;
    _rate = rate;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    controller.setPlaybackSpeed(rate).catchError((_) {});
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
    setState(() {
      _remote = state.copyWith(
        playing: playback == 'play',
        ended: playback == 'ended',
        position: position,
        at: _client.nowServerMs(),
      );
    });
  }

  void _togglePlay() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      togetherToast(context, '视频还没准备好');
      return;
    }
    if (!_isHost) {
      _hostOnlyToast();
      return;
    }
    final position = controller.value.position.inMilliseconds / 1000.0;
    if (controller.value.isPlaying) {
      controller.pause().catchError((_) {});
      if (!_demo && _online) _client.sendState('pause', position);
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
    if (!_demo && _online) _client.sendState('play', start);
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
    if (!_demo && _online) {
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
    if (!mounted || !_isHost || _demo || !_online) return;
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
    if (value.position >=
        value.duration - const Duration(milliseconds: 400)) {
      _endedSent = true;
      final position = value.position.inMilliseconds / 1000.0;
      if (!_demo && _online) _client.sendState('ended', position);
      _markRemote('ended', position);
    }
  }

  void _captureResume() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    _resumePos = controller.value.position.inMilliseconds / 1000.0;
    _resumePlaying = controller.value.isPlaying;
  }

  void _syncVideo() {
    if (_videoId.isEmpty) return;
    final key = '$_videoId|$_ep|$_videoLine';
    if (key == _loadedKey) return;
    _loadedKey = key;
    _loadVideo(_videoId, _ep, _videoLine);
  }

  Future<void> _loadVideo(String videoId, int ep, String line) async {
    final seq = ++_videoSeq;
    _endedSent = false;
    await _disposeController();
    if (!mounted || seq != _videoSeq) return;
    setState(() {
      _videoLoading = true;
      _videoError = '';
    });
    PlayInfo? info;
    try {
      info = await Api.play(videoId, ep, line.isEmpty ? 'l1' : line);
    } catch (_) {
      info = null;
    }
    if (!mounted || seq != _videoSeq) return;
    final play = info;
    final urls = <String>[];
    if (play != null) {
      final primary = play.url.trim();
      if (primary.isNotEmpty) urls.add(primary);
      for (final raw in play.backup) {
        final url = raw.trim();
        if (url.isNotEmpty && !urls.contains(url)) urls.add(url);
      }
    }
    if (play == null || urls.isEmpty) {
      setState(() {
        _videoLoading = false;
        _videoError = play == null ? '暂时拿不到播放地址' : '当前线路没有可用地址';
      });
      return;
    }
    for (final url in urls) {
      if (!mounted || seq != _videoSeq) return;
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: play.headers,
      );
      try {
        await controller.initialize();
        if (!mounted || seq != _videoSeq) {
          await controller.dispose();
          return;
        }
        controller.addListener(_onVideoValue);
        await controller.setLooping(false);
        _controller = controller;
        _rate = 1;
        final state = _remote;
        if (!_isHost && state != null) {
          await _seekAndMaybePlay(controller, state);
        } else if (_isHost && _resumePos != null) {
          final position = _resumePos!;
          await controller.seekTo(
            Duration(milliseconds: (position * 1000).round()),
          );
          if (_resumePlaying) await controller.play();
          if (!_demo && _online) {
            _client.sendState(
              _resumePlaying ? 'play' : 'pause',
              position,
              videoId: _videoId,
              ep: _ep,
              line: _videoLine,
            );
          }
          _resumePos = null;
        }
        if (!mounted || seq != _videoSeq) return;
        setState(() {
          _videoLoading = false;
          _videoError = '';
        });
        return;
      } catch (_) {
        try {
          controller.removeListener(_onVideoValue);
          await controller.dispose();
        } catch (_) {}
      }
    }
    if (!mounted || seq != _videoSeq) return;
    setState(() {
      _videoLoading = false;
      _videoError = '播放失败，稍后再试';
    });
  }

  Future<void> _seekAndMaybePlay(
    VideoPlayerController controller,
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
    try {
      await controller.dispose();
    } catch (_) {}
  }

  void _retryVideo() {
    if (!mounted) return;
    _loadedKey = '';
    _videoError = '';
    _syncVideo();
  }

  Future<void> _loadDetail(String videoId) async {
    if (videoId.isEmpty) return;
    try {
      final detail = await Api.detail(videoId);
      if (!mounted || _videoId != videoId) return;
      setState(() {
        if (detail.title.isNotEmpty) _videoTitle = detail.title;
        _videoCover = detail.cover;
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
      _videoCover = card.cover;
      _episodes = const <Episode>[];
      _loadDetail(card.id);
      if (_demo || !_online) {
        setState(() {
          _videoId = card.id;
          _ep = 1;
          _videoLine = 'l1';
          _remote = null;
          _loadedKey = '';
          _addSystem('房主换成了《${card.title}》');
        });
        _syncVideo();
        return;
      }
      _client.sendState('pause', 0, videoId: card.id, ep: 1, line: 'l1');
      setState(() => _addSystem('房主换成了《${card.title}》'));
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
      if (_demo || !_online) {
        setState(() {
          _ep = episode;
          _loadedKey = '';
          _addSystem('房主切换到第 $episode 集');
        });
        _syncVideo();
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

  void _addSystem(String text) {
    if (text.isEmpty) return;
    _messages.add(TogetherChatMessage.system(text));
  }

  bool _sendChat(String text) {
    if (_demo || !_online) {
      setState(() {
        _messages.add(TogetherChatMessage(
          text: text,
          time: DateTime.now(),
          user: _myName,
          avatar: _myAvatar,
          mine: true,
          demo: true,
        ));
      });
      if (!_online && !_demo) togetherToast(context, '正在重连，消息暂未发出');
      return true;
    }
    // 服务器会把消息广播回所有人（包括自己），无需本地回显。
    _client.sendChat(text);
    return true;
  }

  void _hostOnlyToast() {
    togetherToast(context, '仅房主可操作');
  }

  void _showMembers() {
    final members = _members;
    if (members.isEmpty) return;
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

  /* ------------------------------------------------------------ 广场 */

  Future<void> _loadRooms() async {
    if (_roomsLoading) return;
    setState(() => _roomsLoading = true);
    final result = await TogetherClient.fetchLobby();
    if (!mounted) return;
    setState(() {
      _rooms = result.rooms;
      _roomsReachable = result.reachable;
      _roomsLoading = false;
    });
  }

  Future<void> _pickAndCreate() async {
    final card = await showTogetherVideoPicker(context);
    if (!mounted || card == null) return;
    _videoTitle = card.title;
    _videoCover = card.cover;
    _episodes = const <Episode>[];
    _startCreate(card.id, 1);
  }

  /* ------------------------------------------------------------ UI */

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _confirmExit();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF6F8FC),
        resizeToAvoidBottomInset: true,
        body: FxBackground(
          child: SafeArea(
            bottom: false,
            child: switch (_stage) {
              _TogetherStage.lobby => _buildLobby(),
              _TogetherStage.entering => _buildEntering(),
              _TogetherStage.room => _buildRoom(),
            },
          ),
        ),
      ),
    );
  }

  String get _roomSubtitle {
    final count = _members.isEmpty ? 1 : _members.length;
    final net = _demo ? '单人演示' : (_online ? '已连接' : '未连接');
    final role = _isHost ? '房主' : '跟随房主';
    return '$count 人 · $net · $role';
  }

  Widget _buildLobby() {
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
              TogetherCircleButton(
                icon: Icons.refresh_rounded,
                size: 34,
                iconSize: 17,
                onTap: _loadRooms,
              ),
            ],
          ),
        ),
        if (!_roomsReachable && !_roomsLoading)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3D6).withOpacity(.9),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.cloud_off_rounded,
                    size: 14,
                    color: Color(0xFF9A6A00),
                  ),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Text(
                      '连接不上服务器，仍可创建单人演示房间',
                      style: TextStyle(fontSize: 10, color: Color(0xFF9A6A00)),
                    ),
                  ),
                  GestureDetector(
                    onTap: _loadRooms,
                    child: const Text(
                      '重试',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF9A6A00),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        Expanded(child: _buildRoomList()),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
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

  Widget _buildRoomList() {
    if (_roomsLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
            const SizedBox(height: 10),
            Text(
              '正在找房间…',
              style: TextStyle(fontSize: 11, color: Fx.sub.withOpacity(.8)),
            ),
          ],
        ),
      );
    }
    if (_rooms.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 68,
                height: 68,
                decoration: togetherGlass(radius: 34, opacity: .7),
                child: Icon(
                  _roomsReachable ? Icons.groups_rounded : Icons.wifi_off_rounded,
                  size: 30,
                  color: Fx.accent.withOpacity(.85),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                _roomsReachable ? '广场上还没有房间' : '暂时连不上服务器',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Fx.ink,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                _roomsReachable
                    ? '创建房间，邀请朋友一起同步看片'
                    : '点下方按钮仍可先开一个单人演示',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10.5,
                  height: 1.5,
                  color: Fx.sub.withOpacity(.9),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
      itemCount: _rooms.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final room = _rooms[index];
        return _TogetherRoomCard(
          room: room,
          onTap: () => _join(room.code),
        );
      },
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
              onTap: _backToLobby,
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
    return Column(
      children: [
        _buildHeader(),
        _buildVideo(),
        _buildInfoRow(),
        if (_demo || !_online) _buildNetBanner(),
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
                            fontSize: 15,
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
          _buildMemberStack(),
          const SizedBox(width: 7),
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

  Widget _buildMemberStack() {
    final members = _members;
    if (members.isEmpty) return const SizedBox.shrink();
    final shown = members.take(3).toList();
    final extra = members.length - shown.length;
    const step = 18.0;
    const size = 26.0;
    final width = step * (shown.length - 1) + size + (extra > 0 ? 21.0 : 0);
    return SizedBox(
      width: width,
      height: 30,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * step,
              top: 2,
              child: TogetherAvatar(
                name: shown[i].name,
                avatar: shown[i].avatar,
                size: size,
                host: shown[i].host,
              ),
            ),
          if (extra > 0)
            Positioned(
              left: step * shown.length,
              top: 5,
              child: Container(
                width: 22,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.92),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '+$extra',
                  style: const TextStyle(
                    fontSize: 8.5,
                    fontWeight: FontWeight.w700,
                    color: Fx.sub,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildVideo() {
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Container(
            color: _videoBg,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (!ready && _videoCover.startsWith('http'))
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
                if (!ready && _videoCover.startsWith('http'))
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
                      child: VideoPlayer(controller),
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
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCenterIcon(VideoPlayerController controller) {
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

  Widget _buildProgress(VideoPlayerController controller) {
    final total = controller.value.duration.inMilliseconds / 1000.0;
    final position = _displayPosition();
    return Column(
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
                style: _timeStyle.copyWith(color: Colors.white.withOpacity(.75)),
              ),
              const SizedBox(width: 8),
            ],
            Text(togetherFmt(total), style: _timeStyle),
          ],
        ),
      ],
    );
  }

  Widget _buildSyncChip() {
    final state = _remote;
    final String text;
    if (_demo) {
      text = '单人演示';
    } else if (!_online) {
      text = '未连接';
    } else if (_isHost) {
      text = state?.playing == true ? '房主 · 播放中' : '房主 · 已暂停';
    } else {
      text = state?.playing == true ? '跟随房主 · 播放中' : '跟随房主 · 已暂停';
    }
    final dot = _demo
        ? Fx.gold
        : _online
            ? const Color(0xFF57D3A3)
            : const Color(0xFFFF8A80);
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
            _online && !_demo ? '$text · ${_client.rtt}ms' : text,
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
          if (!_videoLoading && _videoError.isNotEmpty && _isHost)
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
                    '${_members.isEmpty ? 1 : _members.length} 人',
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
    final text = _demo ? '未连接服务器 · 单人演示（联网后自动同步）' : '连接已断开 · 正在自动重连…';
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
        child: TogetherChatList(messages: _messages),
      ),
    );
  }

  Widget _buildComposer() {
    return SafeArea(
      top: false,
      child: TogetherComposer(
        enabled: _online || _demo,
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

/* ========================================================================== */
/*  广场房间卡                                                                 */
/* ========================================================================== */

class _TogetherRoomCard extends StatelessWidget {
  const _TogetherRoomCard({required this.room, required this.onTap});

  final TogetherRoomBrief room;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: togetherGlass(radius: 18, opacity: .72),
        child: Row(
          children: [
            TogetherCover(
              cover: room.cover,
              title: room.videoTitle,
              width: 50,
              height: 66,
              radius: 11,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    room.videoTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: Fx.ink,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.person_outline_rounded,
                        size: 11,
                        color: Fx.sub.withOpacity(.8),
                      ),
                      const SizedBox(width: 2),
                      Flexible(
                        child: Text(
                          room.host.isEmpty ? '房主' : room.host,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 9.5,
                            color: Fx.sub.withOpacity(.95),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.people_alt_outlined,
                        size: 11,
                        color: Fx.sub.withOpacity(.8),
                      ),
                      const SizedBox(width: 2),
                      Text(
                        '${room.members} 人',
                        style: TextStyle(
                          fontSize: 9.5,
                          color: Fx.sub.withOpacity(.95),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: Fx.accent.withOpacity(.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '房间 ${room.code}',
                          style: const TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: Fx.accent,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (room.ep > 0)
                        Text(
                          '第 ${room.ep} 集',
                          style: TextStyle(
                            fontSize: 9,
                            color: Fx.sub.withOpacity(.85),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: Fx.sub.withOpacity(.5),
            ),
          ],
        ),
      ),
    );
  }
}

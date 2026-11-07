import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:web_socket_channel/web_socket_channel.dart';

import '../api.dart';
import '../models.dart';
import 'together_sync.dart';
import 'together_ui.dart';

/* ========================================================================== */
/*  一起看 · 协议客户端                                                        */
/*  API.md §4：服务器权威同步 room_state{rev, at}，房主独占 state/seek/episode  */
/* ========================================================================== */

int togetherInt(dynamic v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? fallback;
  return fallback;
}

double togetherDouble(dynamic v, [double fallback = 0]) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? fallback;
  return fallback;
}

Map<String, dynamic> togetherMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

/// 服务器权威房间状态（`room_state`）。
class TogetherRoomState {
  const TogetherRoomState({
    required this.code,
    required this.title,
    required this.hostId,
    required this.members,
    required this.videoId,
    required this.ep,
    required this.line,
    required this.playing,
    required this.ended,
    required this.position,
    required this.serverTime,
    required this.seq,
    required this.rate,
    this.kind = '',
    this.liveChannel,
  });

  final String code;
  final String title;
  final String hostId;
  final List<TogetherMember> members;
  final String videoId;
  final int ep;
  final String line;
  final bool playing;
  final bool ended;
  final double position;

  /// 服务端毫秒时间戳：这份 position 对应的服务器时刻。
  final int serverTime;

  /// 权威版本号（服务端 `seq`，旧服务端为 `rev`），单调递增。
  final int seq;

  /// 房主播放倍速，成员跟随。
  final double rate;

  /// 房间类型：`live` = 直播一起看；普通剧集为空 / `video`。
  final String kind;

  /// 直播房解析出的频道（含线路）；普通房为 null。
  final LiveChannel? liveChannel;

  bool get isLive => kind == 'live' || liveChannel != null;

  /// 旧字段别名，保留给仍读 at / rev / line 的地方。
  int get at => serverTime;
  int get rev => seq;
  String get lineId => line;

  factory TogetherRoomState.fromJson(Map<String, dynamic> j) {
    final rawState = '${j['state'] ?? ''}';
    final rawPlaying = j['playing'];
    final playing = rawPlaying is bool ? rawPlaying : rawState == 'play';
    final serverAt = togetherInt(j['serverTime']);
    final serverTime = serverAt > 0 ? serverAt : togetherInt(j['at']);
    final rawSeq = togetherInt(j['seq']);
    final seq = rawSeq > 0 ? rawSeq : togetherInt(j['rev']);
    final title = '${j['title'] ?? '一起看'}';
    final live = togetherLiveChannel(j) ?? decodeLiveRoomTitle(title);
    final rawKind = '${j['kind'] ?? ''}'.trim();
    return TogetherRoomState(
      code: '${j['code'] ?? ''}',
      title: title,
      hostId: '${j['hostId'] ?? ''}',
      members: ((j['members'] ?? []) as List)
          .whereType<Map>()
          .map((e) => TogetherMember.fromJson(togetherMap(e)))
          .toList(),
      videoId: '${j['videoId'] ?? ''}',
      ep: togetherInt(j['ep'], 1),
      line: '${j['lineId'] ?? j['line'] ?? 'l1'}',
      playing: playing,
      ended: rawState == 'ended',
      position: togetherDouble(j['position']),
      serverTime: serverTime,
      seq: seq,
      rate: togetherClampRate(togetherDouble(j['rate'], 1)),
      kind: rawKind.isEmpty ? (live != null ? 'live' : '') : rawKind,
      liveChannel: live,
    );
  }

  TogetherRoomState copyWith({
    bool? playing,
    bool? ended,
    double? position,
    int? serverTime,
    int? ep,
    double? rate,
  }) {
    return TogetherRoomState(
      code: code,
      title: title,
      hostId: hostId,
      members: members,
      videoId: videoId,
      ep: ep ?? this.ep,
      line: line,
      playing: playing ?? this.playing,
      ended: ended ?? this.ended,
      position: position ?? this.position,
      serverTime: serverTime ?? this.serverTime,
      seq: seq,
      rate: rate ?? this.rate,
      kind: kind,
      liveChannel: liveChannel,
    );
  }
}

/// 从 room_state / create payload 里解析直播频道。
///
/// 新服务端给 `kind/channelId/lines`；老服务端只把频道编码在 title 里。
LiveChannel? togetherLiveChannel(Map<String, dynamic> j) {
  final kind = '${j['kind'] ?? j['roomKind'] ?? ''}'.trim();
  final id = '${j['channelId'] ?? ''}'.trim();
  final lines = j['lines'] ?? j['liveLines'];
  if (kind != 'live' && id.isEmpty && lines is! List) return null;
  final raw = <String, dynamic>{
    'id': id.isNotEmpty ? id : '${j['videoId'] ?? ''.trim()}',
    'title': '${j['liveName'] ?? j['channelName'] ?? j['name'] ?? ''}',
    'cover': '${j['liveCover'] ?? j['cover'] ?? ''}',
    'group': '${j['liveGroup'] ?? j['group'] ?? ''}',
    'lines': lines is List ? lines : const <Object?>[],
  };
  final channel = LiveChannel.tryFrom(raw);
  return channel;
}

/// `create` 的响应（`action: room`）。
class TogetherRoomInfo {
  const TogetherRoomInfo({
    required this.code,
    required this.title,
    required this.videoId,
    required this.ep,
    required this.line,
    required this.hostId,
    required this.members,
    this.kind = '',
    this.liveChannel,
  });

  final String code;
  final String title;
  final String videoId;
  final int ep;
  final String line;
  final String hostId;
  final List<TogetherMember> members;

  /// 直播房类型与频道数据。
  final String kind;
  final LiveChannel? liveChannel;

  factory TogetherRoomInfo.fromJson(Map<String, dynamic> j) {
    final title = '${j['title'] ?? '一起看'}';
    final live = togetherLiveChannel(j) ?? decodeLiveRoomTitle(title);
    return TogetherRoomInfo(
      code: '${j['code'] ?? ''}',
      title: title,
      videoId: '${j['videoId'] ?? ''}',
      ep: togetherInt(j['ep'], 1),
      line: '${j['line'] ?? 'l1'}',
      hostId: '${j['host'] ?? ''}',
      members: ((j['members'] ?? []) as List)
          .whereType<Map>()
          .map((e) => TogetherMember.fromJson(togetherMap(e)))
          .toList(),
      kind: '${j['kind'] ?? ''}'.trim().isEmpty
          ? (live != null ? 'live' : '')
          : '${j['kind']}'.trim(),
      liveChannel: live,
    );
  }
}

/// 收听到的聊天消息。
class TogetherChatIncoming {
  const TogetherChatIncoming({
    required this.userId,
    required this.name,
    required this.avatar,
    required this.text,
  });

  final String userId;
  final String name;
  final String avatar;
  final String text;
}

class TogetherClient {
  TogetherClient({
    required this.onOpen,
    required this.onDown,
    required this.onRoom,
    required this.onState,
    required this.onChat,
    required this.onSystem,
    required this.onError,
    required this.onClosed,
    this.onAuthFailed,
  });

  final void Function(TogetherMember me) onOpen;
  final void Function() onDown;
  final void Function(TogetherRoomInfo room) onRoom;
  final void Function(TogetherRoomState state) onState;
  final void Function(TogetherChatIncoming chat) onChat;
  final void Function(String text) onSystem;
  final void Function(String code, String message) onError;
  final void Function(String reason) onClosed;

  /// 重连前探测确认 token 已过期（HTTP 401）时回调；回调后不再重连。
  final void Function()? onAuthFailed;

  static const Duration _pingPeriod = Duration(seconds: 10);
  static const Duration _clockRefreshPeriod = Duration(seconds: 30);
  static const int _clockPingCount = 3;
  static const Duration _clockPingGap = Duration(milliseconds: 120);
  static const Duration _clockRoundTimeout = Duration(milliseconds: 1200);
  static final RegExp _codePattern = RegExp(r'^\d{6}$');

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _retry;
  Timer? _ping;
  Timer? _clockTimer;
  Timer? _openTimeout;
  bool _closed = false;
  bool _connecting = false;
  bool _connected = false;

  /// 断线重连退避：3s / 6s / 12s / 24s，上限 30s。
  int _retryAttempt = 0;
  int _retryDelaySec = 0;

  /// 正在用 HTTP 探测 token 是否过期，避免并发探测 / 探测期间又排重连。
  bool _authChecking = false;

  /// 已确认 token 过期：停止一切自动重连，等用户重新登录。
  bool _authFailed = false;

  /// 最近一次收到 pong 的本地时间；连续 2 个 ping 周期没有 pong 就主动重连。
  int _lastPongAt = 0;

  /// 刚发出 join（重连 / 回前台同步）在等房间回应：
  /// 只有这种 not_found 才代表原房间没了，房主才重建；
  /// 普通操作（如 state 带了不存在的 videoId）的 not_found 不能换房。
  bool _rejoining = false;

  /// 当前房间号 / 是否房主。断线重连先 rejoin 原房间，只有 not_found 才重建。
  String code = '';
  bool host = false;

  String _hostVideoId = '';
  int _hostEp = 1;
  String _hostLine = 'l1';
  String _hostTitle = '';
  String _hostKind = '';
  String _hostChannelId = '';
  Map<String, dynamic> _hostLive = const <String, dynamic>{};
  Map<String, dynamic>? _pendingCreate;

  String selfId = '';
  String selfName = '';
  String selfAvatar = '';

  /// 时钟偏移：serverTime - Date.now()，3 次 ping 的中位数，30 秒刷新一次。
  final TogetherClock _clock = TogetherClock();
  int _lastPingAt = 0;
  int _clockRound = 0;
  int _clockFinishedRound = 0;
  int _clockPingId = 0;
  final Map<int, List<int>> _clockOffsets = <int, List<int>>{};
  final Map<int, List<int>> _clockRtts = <int, List<int>>{};
  final Map<int, int> _clockPingRound = <int, int>{};

  bool get connected => _connected;

  /// 已有待发送的 create（重连/降级后由客户端统一补发，页面不要重复建房）。
  bool get hasPendingCreate => _pendingCreate != null;

  /// 至少完成过一轮 3 次 ping 的中位数校准，才敢用服务端时间推算进度。
  bool get synced => _clock.ready;

  /// 时钟偏移（毫秒），供调试 / 页面展示。
  int get clockOffset => _clock.offsetMs;

  /// 最近一次 RTT（毫秒）。
  int get rtt => _clock.rttMs;

  /// 时钟校准版本：每完成一轮 ping 校准 +1，页面据此发现 offset 台阶。
  int get clockVersion => _clock.version;

  /// 最近一次校准相对上一次的 offset 变化量（毫秒）。
  int get clockOffsetDeltaMs => _clock.lastOffsetDeltaMs;

  /// 下一次自动重连的等待秒数（0 表示未在重连）。
  int get retryDelaySeconds => _retryDelaySec;

  /// 房间号是否合法：只接受 6 位数字。
  static bool validCode(String code) => _codePattern.hasMatch(code.trim());

  /// 本地当前时间换算成服务器时钟：Date.now() + offset。
  int nowServerMs() =>
      _clock.nowServerMs(DateTime.now().millisecondsSinceEpoch);

  /* ------------------------------------------------------------ 连接 */

  void connect() {
    if (_closed || _authFailed || _connected || _connecting) return;
    _retry?.cancel();
    _retry = null;
    _connecting = true;
    try {
      final ws = Uri.parse(Api.wsBase);
      final uri = Api.token.isEmpty
          ? ws
          : ws.replace(queryParameters: <String, String>{
              ...ws.queryParameters,
              'token': Api.token,
            });
      final ch = WebSocketChannel.connect(uri);
      _channel = ch;
      // 连接失败会由 stream.onError 处理；ready 的错误必须被消费，否则是未处理异常。
      ch.ready.ignore();
      _sub = ch.stream.listen(
        _onData,
        onError: (_) => _fail(),
        onDone: _fail,
        cancelOnError: false,
      );
      _openTimeout?.cancel();
      _openTimeout = Timer(const Duration(seconds: 7), () {
        if (!_closed && !_connected) _fail();
      });
    } catch (_) {
      _fail();
    }
  }

  void _fail() {
    if (_closed) return;
    // onError / onDone / openTimeout 可能连着触发，只处理第一次。
    if (!_connected &&
        !_connecting &&
        _channel == null &&
        (_retry?.isActive ?? false)) {
      return;
    }
    final had = _connected;
    _connected = false;
    _connecting = false;
    _lastPongAt = 0;
    _stopClockSync();
    _clock.reset();
    _openTimeout?.cancel();
    _openTimeout = null;
    _ping?.cancel();
    _ping = null;
    final sub = _sub;
    _sub = null;
    if (sub != null) sub.cancel().ignore();
    final ch = _channel;
    _channel = null;
    if (ch != null) {
      // 连接失败的 sink.close() 可能永不返回，不能等待。
      try {
        ch.sink.close().ignore();
      } catch (_) {}
    }
    if (had || ch != null) onDown();
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_closed || _authFailed || _authChecking) return;
    _retry?.cancel();
    _retry = null;
    // token 过期时服务端通常直接关闭握手，表现和「网络不好」完全一样；
    // 连续失败 2 次后用一次 HTTP 探测确认 401，是过期就停止无限重连。
    if (Api.token.isNotEmpty && _retryAttempt >= 2) {
      _authChecking = true;
      unawaited(_probeAuthThenRetry());
      return;
    }
    _startRetryTimer();
  }

  void _startRetryTimer() {
    if (_closed || _authFailed) return;
    // 3 / 6 / 12 / 24 / 30 / 30…
    final seconds = math.min(30, 3 * (1 << math.min(_retryAttempt, 4)));
    _retryAttempt = math.min(_retryAttempt + 1, 8);
    _retryDelaySec = seconds;
    _retry = Timer(Duration(seconds: seconds), connect);
  }

  /// 重连前的 401 探测：网络本身不通时继续按退避重连，
  /// 确认 token 过期则回调 [onAuthFailed] 并彻底停止重连。
  Future<void> _probeAuthThenRetry() async {
    var expired = false;
    try {
      await Api.me();
    } on ApiException catch (e) {
      expired = e.code == 401;
    } catch (_) {
      // 超时 / 断网都不代表 token 失效，继续重连。
    }
    _authChecking = false;
    if (_closed) return;
    if (expired) {
      _authFailed = true;
      _retryDelaySec = 0;
      _retry?.cancel();
      _retry = null;
      onAuthFailed?.call();
      return;
    }
    _startRetryTimer();
  }

  void _startPing() {
    _ping?.cancel();
    ping();
    _ping = Timer.periodic(_pingPeriod, (_) => _pingTick());
    _startClockSync();
  }

  /// 切后台时暂停心跳，回前台再恢复，省电也避免后台误判超时。
  void pauseHeartbeat() {
    _ping?.cancel();
    _ping = null;
    _stopClockSync();
  }

  void resumeHeartbeat() {
    if (_closed || !_connected) return;
    _lastPongAt = DateTime.now().millisecondsSinceEpoch;
    _startPing();
  }

  void _pingTick() {
    if (_closed || !_connected) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastPongAt > 0 &&
        now - _lastPongAt >= _pingPeriod.inMilliseconds * 2) {
      // 两个 ping 周期都没有 pong：连接已经死了（半开 TCP），主动重连。
      _fail();
      return;
    }
    ping();
  }

  /// 心跳 ping（不带 id）：只测活，不参与时钟中位数。
  void ping() {
    if (_closed || !_connected) return;
    final t = DateTime.now().millisecondsSinceEpoch;
    _lastPingAt = t;
    _send({'action': 'ping', 't': t});
  }

  /// 3 次 ping 取中位数，然后每 30 秒重校一次。
  void _startClockSync() {
    _stopClockSync();
    _clockBurst();
    _clockTimer = Timer.periodic(_clockRefreshPeriod, (_) => _clockBurst());
  }

  void _stopClockSync() {
    _clockTimer?.cancel();
    _clockTimer = null;
    // 让已经排队的 burst 定时器失效，避免切后台后还继续发 ping。
    _clockFinishedRound = _clockRound;
    _clockOffsets.clear();
    _clockRtts.clear();
    _clockPingRound.clear();
  }

  void _clockBurst() {
    if (_closed || !_connected) return;
    final round = ++_clockRound;
    _clockOffsets[round] = <int>[];
    _clockRtts[round] = <int>[];
    for (var i = 0; i < _clockPingCount; i++) {
      Timer(_clockPingGap * i, () {
        if (_closed || !_connected || round <= _clockFinishedRound) return;
        final id = ++_clockPingId;
        final t = DateTime.now().millisecondsSinceEpoch;
        _clockPingRound[id] = round;
        _lastPingAt = t;
        _send({'action': 'ping', 't': t, 'id': id});
      });
    }
    // 弱网丢了 1–2 个 pong 时也别一直等：超时用已有样本收尾。
    Timer(_clockRoundTimeout, () => _finishClockRound(round));
  }

  void _finishClockRound(int round) {
    if (round <= _clockFinishedRound) return;
    final offsets = _clockOffsets.remove(round) ?? const <int>[];
    final rtts = _clockRtts.remove(round) ?? const <int>[];
    _clockFinishedRound = round;
    // 丢掉这一轮没收到 pong 的 ping id，避免长期运行后 Map 累积。
    _clockPingRound.removeWhere((_, pendingRound) => pendingRound <= round);
    if (offsets.isEmpty) return;
    _clock.update(
      offsetMs: TogetherClock.median(offsets),
      rttMs: TogetherClock.median(rtts),
    );
  }

  void _collectClockPong(Map<String, dynamic> msg, int sent, int recv) {
    final id = togetherInt(msg['id']);
    final round = id > 0 ? _clockPingRound.remove(id) : 0;
    if (round == null || round <= 0) return;
    final offsets = _clockOffsets[round];
    final rtts = _clockRtts[round];
    if (offsets == null || rtts == null) return;
    if (round <= _clockFinishedRound) return;
    final serverTime = togetherInt(msg['serverTime']);
    final serverAt = serverTime > 0 ? serverTime : togetherInt(msg['serverAt']);
    if (serverAt <= 0) return;
    offsets.add(serverAt - (sent + recv) ~/ 2);
    rtts.add(recv - sent);
    if (offsets.length >= _clockPingCount) _finishClockRound(round);
  }

  /// 回到前台时主动要一次权威状态（服务器对已在房间的连接会直接回 room_state）。
  void refreshRoom() {
    if (!_connected || code.isEmpty) return;
    _rejoining = true;
    _send({'action': 'join', 'code': code});
  }

  bool _send(Map<String, dynamic> payload) {
    final ch = _channel;
    if (ch == null || !_connected) return false;
    try {
      ch.sink.add(jsonEncode(payload));
      return true;
    } catch (_) {
      return false;
    }
  }

  /* ------------------------------------------------------------ 动作 */

  void createRoom({
    required String videoId,
    int ep = 1,
    String line = 'l1',
    String title = '',
    String kind = '',
    String channelId = '',
    Map<String, dynamic> live = const <String, dynamic>{},
  }) {
    _hostVideoId = videoId;
    _hostEp = ep < 1 ? 1 : ep;
    _hostLine = line.isEmpty ? 'l1' : line;
    _hostTitle = title;
    _hostKind = kind;
    _hostChannelId = channelId;
    _hostLive = live;
    host = true;
    code = '';
    _rejoining = false;
    _pendingCreate = _createPayload();
    if (_connected) {
      _send(_pendingCreate!);
    }
  }

  Map<String, dynamic> _createPayload() {
    if (_hostKind == 'live') {
      return <String, dynamic>{
        'action': 'create',
        // 直播频道 id 不是影片 id：不能传 videoId，否则服务端会报 not_found。
        'kind': 'live',
        'channelId': _hostChannelId,
        'line': _hostLine,
        if (_hostTitle.isNotEmpty) 'title': _hostTitle,
        ..._hostLive,
      };
    }
    return <String, dynamic>{
      'action': 'create',
      'videoId': _hostVideoId,
      'ep': _hostEp,
      'line': _hostLine,
      if (_hostTitle.isNotEmpty) 'title': _hostTitle,
    };
  }

  bool joinRoom(String roomCode) {
    final value = roomCode.trim();
    if (!validCode(value)) {
      onError('bad_code', '房间号必须是 6 位数字');
      return false;
    }
    code = value;
    host = false;
    _pendingCreate = null;
    _rejoining = true;
    if (_connected) {
      _send({'action': 'join', 'code': value});
    }
    return true;
  }

  /// 房主：写入权威状态（播放 / 暂停 / 切片）。
  void sendState(
    String state,
    double position, {
    String? videoId,
    int? ep,
    String? line,
    double? rate,
    bool live = false,
  }) {
    // 房主标记由服务器判定：即使本地标记过期，也让服务器拒绝并回发权威状态。
    if (videoId != null && videoId.isNotEmpty) _hostVideoId = videoId;
    if (ep != null && ep > 0) _hostEp = ep;
    if (line != null && line.isNotEmpty) _hostLine = line;
    _send({
      'action': 'state',
      'state': state,
      'playing': state == 'play',
      'position': position < 0 ? 0 : position,
      if (videoId != null && videoId.isNotEmpty) 'videoId': videoId,
      if (ep != null && ep > 0) 'ep': ep,
      if (line != null && line.isNotEmpty) 'line': line,
      if (rate != null && rate > 0) 'rate': rate,
      if (live) ...<String, dynamic>{
        'kind': 'live',
        'channelId': _hostChannelId,
        ..._hostLive,
      },
    });
  }

  /// 房主：修改倍速，立刻广播给成员。
  void sendRate(double rate) {
    _send({'action': 'rate', 'rate': rate});
  }

  /// 房主：拖动进度。
  void sendSeek(double position) {
    _send({'action': 'seek', 'position': position < 0 ? 0 : position});
  }

  /// 返回 false 表示没有发出去（未连接 / socket 写入失败），调用方保留输入。
  bool sendChat(String text) {
    final value = text.trim();
    if (value.isEmpty) return false;
    return _send({'action': 'chat', 'text': value});
  }

  /// 房主：切集 / 换线路（服务器会重置进度并广播）。
  void sendEpisode(int ep, {String? line}) {
    if (ep > 0) _hostEp = ep;
    if (line != null && line.isNotEmpty) _hostLine = line;
    _send({
      'action': 'episode',
      'ep': ep,
      if (line != null && line.isNotEmpty) 'line': line,
    });
  }

  void leave() {
    if (_connected && code.isNotEmpty) _send({'action': 'leave'});
    code = '';
    host = false;
    _pendingCreate = null;
    _rejoining = false;
  }

  void dispose() {
    _closed = true;
    _retry?.cancel();
    _ping?.cancel();
    _stopClockSync();
    _openTimeout?.cancel();
    _retry = null;
    _ping = null;
    _openTimeout = null;
    final sub = _sub;
    _sub = null;
    if (sub != null) sub.cancel().ignore();
    final ch = _channel;
    _channel = null;
    if (ch != null) {
      try {
        ch.sink.close().ignore();
      } catch (_) {}
    }
  }

  /* ------------------------------------------------------------ 收包 */

  void _onData(dynamic raw) {
    Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode('$raw');
      if (decoded is! Map) return;
      msg = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }
    switch ('${msg['action'] ?? ''}') {
      case 'hello':
        _onHello(msg);
        break;
      case 'room':
        final info = TogetherRoomInfo.fromJson(togetherMap(msg['room']));
        if (info.code.isEmpty) return;
        code = info.code;
        host = true;
        _pendingCreate = null;
        _rejoining = false;
        onRoom(info);
        break;
      case 'room_state':
        _rejoining = false;
        onState(TogetherRoomState.fromJson(msg));
        break;
      case 'chat':
        final user = togetherMap(msg['user']);
        onChat(TogetherChatIncoming(
          userId: '${user['id'] ?? ''}',
          name: '${user['name'] ?? '影迷'}',
          avatar: '${user['avatar'] ?? ''}',
          text: '${msg['text'] ?? ''}',
        ));
        break;
      case 'system':
        onSystem('${msg['text'] ?? ''}');
        break;
      case 'error':
        final errCode = '${msg['code'] ?? 'error'}';
        final errMsg = '${msg['msg'] ?? ''}';
        // 重连时先 join 旧房间号：房主只有在收到 not_found（原房间已解散）
        // 才重新 create；收到前保持原房号不变。
        final rejoinFailed = _rejoining;
        _rejoining = false;
        if (errCode == 'not_found' &&
            host &&
            rejoinFailed &&
            code.isNotEmpty &&
            _pendingCreate == null) {
          final payload = _createPayload();
          _pendingCreate = payload;
          onSystem('房间已失效，正在重新创建…');
          _send(payload);
          break;
        }
        if (errCode == 'not_found') {
          // create 本身失败（作品不存在）时不能再无限重发。
          final createFailed = _pendingCreate != null;
          _pendingCreate = null;
          // 只有 join / create 的 not_found 才代表房间没了；
          // state 带错 videoId 的 not_found 不能把房主踢出仍然存在的房间。
          if (rejoinFailed || createFailed) {
            code = '';
            host = false;
          }
        } else if (errCode == 'room_full' || _isPasswordError(errCode)) {
          code = '';
          host = false;
          _pendingCreate = null;
        }
        onError(errCode, errMsg);
        break;
      case 'closed':
        code = '';
        host = false;
        _pendingCreate = null;
        _rejoining = false;
        onClosed('${msg['reason'] ?? '房间已解散'}');
        break;
      case 'pong':
        _onPong(msg);
        break;
    }
  }

  void _onHello(Map<String, dynamic> msg) {
    _connected = true;
    _connecting = false;
    _retryAttempt = 0;
    _retryDelaySec = 0;
    _lastPongAt = DateTime.now().millisecondsSinceEpoch;
    _openTimeout?.cancel();
    _openTimeout = null;
    final user = togetherMap(msg['user']);
    selfId = '${user['id'] ?? ''}';
    selfName = '${user['name'] ?? '观众'}';
    selfAvatar = '${user['avatar'] ?? ''}';
    _startPing();
    // 断线重连：房主也先加入原房间号，只有服务端回 not_found 才重建，
    // 避免每次重连都换房；创建中的 create 仍优先重发。
    final pending = _pendingCreate;
    if (pending != null) {
      _send(pending);
    } else if (code.isNotEmpty) {
      _rejoining = true;
      _send({'action': 'join', 'code': code});
    }
    onOpen(TogetherMember(
      id: selfId,
      name: selfName,
      avatar: selfAvatar,
    ));
  }

  bool _isPasswordError(String code) {
    final lower = code.toLowerCase();
    return lower.contains('password') ||
        lower.contains('passwd') ||
        lower.contains('pwd');
  }

  void _onPong(Map<String, dynamic> msg) {
    final recv = DateTime.now().millisecondsSinceEpoch;
    _lastPongAt = recv;
    final sent = togetherInt(msg['t'], _lastPingAt);
    final serverTime = togetherInt(msg['serverTime']);
    final serverAt = serverTime > 0 ? serverTime : togetherInt(msg['serverAt']);
    if (serverAt <= 0 || sent <= 0) return;
    final id = togetherInt(msg['id']);
    if (id > 0) {
      _collectClockPong(msg, sent, recv);
      return;
    }
    // 兼容旧服务端（没有 id）：只在尚未完成中位数校准时兜底采一次。
    if (!_clock.ready) {
      _clock.update(
        offsetMs: serverAt - (sent + recv) ~/ 2,
        rttMs: recv - sent,
      );
    }
  }
}

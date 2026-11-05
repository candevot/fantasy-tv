import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../api.dart';
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
    required this.at,
    required this.rev,
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

  /// 服务端毫秒时间戳（客户端用 offset 换算成本地时钟）。
  final int at;

  /// 权威版本号，单调递增。
  final int rev;

  factory TogetherRoomState.fromJson(Map<String, dynamic> j) {
    final rawState = '${j['state'] ?? 'pause'}';
    return TogetherRoomState(
      code: '${j['code'] ?? ''}',
      title: '${j['title'] ?? '一起看'}',
      hostId: '${j['hostId'] ?? ''}',
      members: ((j['members'] ?? []) as List)
          .whereType<Map>()
          .map((e) => TogetherMember.fromJson(togetherMap(e)))
          .toList(),
      videoId: '${j['videoId'] ?? ''}',
      ep: togetherInt(j['ep'], 1),
      line: '${j['line'] ?? 'l1'}',
      playing: rawState == 'play',
      ended: rawState == 'ended',
      position: togetherDouble(j['position']),
      at: togetherInt(j['at']),
      rev: togetherInt(j['rev']),
    );
  }

  TogetherRoomState copyWith({
    bool? playing,
    bool? ended,
    double? position,
    int? at,
    int? ep,
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
      at: at ?? this.at,
      rev: rev,
    );
  }
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
  });

  final String code;
  final String title;
  final String videoId;
  final int ep;
  final String line;
  final String hostId;
  final List<TogetherMember> members;

  factory TogetherRoomInfo.fromJson(Map<String, dynamic> j) {
    return TogetherRoomInfo(
      code: '${j['code'] ?? ''}',
      title: '${j['title'] ?? '一起看'}',
      videoId: '${j['videoId'] ?? ''}',
      ep: togetherInt(j['ep'], 1),
      line: '${j['line'] ?? 'l1'}',
      hostId: '${j['host'] ?? ''}',
      members: ((j['members'] ?? []) as List)
          .whereType<Map>()
          .map((e) => TogetherMember.fromJson(togetherMap(e)))
          .toList(),
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
  });

  final void Function(TogetherMember me) onOpen;
  final void Function() onDown;
  final void Function(TogetherRoomInfo room) onRoom;
  final void Function(TogetherRoomState state) onState;
  final void Function(TogetherChatIncoming chat) onChat;
  final void Function(String text) onSystem;
  final void Function(String code, String message) onError;
  final void Function(String reason) onClosed;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _retry;
  Timer? _ping;
  Timer? _openTimeout;
  bool _closed = false;
  bool _connecting = false;
  bool _connected = false;

  /// 当前房间号 / 是否房主。断线重连后据此 rejoin（房主则重建）。
  String code = '';
  bool host = false;

  String _hostVideoId = '';
  int _hostEp = 1;
  String _hostLine = 'l1';
  String _hostTitle = '';
  Map<String, dynamic>? _pendingCreate;

  String selfId = '';
  String selfName = '';
  String selfAvatar = '';

  int _offset = 0;
  int _rtt = 0;
  int _lastPingAt = 0;
  final List<int> _samples = <int>[];

  bool get connected => _connected;

  /// 已有待发送的 create（重连/降级后由客户端统一补发，页面不要重复建房）。
  bool get hasPendingCreate => _pendingCreate != null;

  /// 至少收到过一次 pong，才敢用服务端时间推算进度。
  bool get synced => _samples.isNotEmpty;

  /// 最近一次 RTT（毫秒）。
  int get rtt => _rtt;

  int nowServerMs() => DateTime.now().millisecondsSinceEpoch + _offset;

  /* ------------------------------------------------------------ 连接 */

  void connect() {
    if (_closed || _connected || _connecting) return;
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
    final had = _connected;
    _connected = false;
    _connecting = false;
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
    if (_closed) return;
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 3), connect);
  }

  void _startPing() {
    _ping?.cancel();
    ping();
    _ping = Timer.periodic(const Duration(seconds: 10), (_) => ping());
  }

  void ping() {
    final t = DateTime.now().millisecondsSinceEpoch;
    _lastPingAt = t;
    _send({'action': 'ping', 't': t});
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
  }) {
    _hostVideoId = videoId;
    _hostEp = ep < 1 ? 1 : ep;
    _hostLine = line.isEmpty ? 'l1' : line;
    _hostTitle = title;
    host = true;
    code = '';
    _pendingCreate = _createPayload();
    if (_connected) {
      _send(_pendingCreate!);
    }
  }

  Map<String, dynamic> _createPayload() => <String, dynamic>{
        'action': 'create',
        'videoId': _hostVideoId,
        'ep': _hostEp,
        'line': _hostLine,
        if (_hostTitle.isNotEmpty) 'title': _hostTitle,
      };

  void joinRoom(String roomCode) {
    code = roomCode;
    host = false;
    _pendingCreate = null;
    if (_connected) {
      _send({'action': 'join', 'code': roomCode});
    }
  }

  /// 房主：写入权威状态（播放 / 暂停 / 切片）。
  void sendState(
    String state,
    double position, {
    String? videoId,
    int? ep,
    String? line,
  }) {
    // 房主标记由服务器判定：即使本地标记过期，也让服务器拒绝并回发权威状态。
    if (videoId != null && videoId.isNotEmpty) _hostVideoId = videoId;
    if (ep != null && ep > 0) _hostEp = ep;
    if (line != null && line.isNotEmpty) _hostLine = line;
    _send({
      'action': 'state',
      'state': state,
      'position': position < 0 ? 0 : position,
      if (videoId != null && videoId.isNotEmpty) 'videoId': videoId,
      if (ep != null && ep > 0) 'ep': ep,
      if (line != null && line.isNotEmpty) 'line': line,
    });
  }

  /// 房主：拖动进度。
  void sendSeek(double position) {
    _send({'action': 'seek', 'position': position < 0 ? 0 : position});
  }

  void sendChat(String text) {
    if (text.trim().isEmpty) return;
    _send({'action': 'chat', 'text': text.trim()});
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
  }

  void dispose() {
    _closed = true;
    _retry?.cancel();
    _ping?.cancel();
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
        onRoom(info);
        break;
      case 'room_state':
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
        if (errCode == 'not_found' &&
            host &&
            code.isNotEmpty &&
            _pendingCreate == null) {
          final payload = _createPayload();
          _pendingCreate = payload;
          onSystem('房间已失效，正在重新创建…');
          _send(payload);
          break;
        }
        if (errCode == 'not_found' || errCode == 'room_full') {
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
      _send({'action': 'join', 'code': code});
    }
    onOpen(TogetherMember(
      id: selfId,
      name: selfName,
      avatar: selfAvatar,
    ));
  }

  void _onPong(Map<String, dynamic> msg) {
    final recv = DateTime.now().millisecondsSinceEpoch;
    final sent = togetherInt(msg['t'], _lastPingAt);
    final serverAt = togetherInt(msg['serverAt']);
    if (serverAt <= 0 || sent <= 0) return;
    _rtt = recv - sent;
    _samples.add(serverAt - (sent + recv) ~/ 2);
    if (_samples.length > 5) _samples.removeAt(0);
    final sorted = List<int>.from(_samples)..sort();
    _offset = sorted[sorted.length ~/ 2];
  }
}

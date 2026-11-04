import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
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

/// 广场里的房间摘要（HTTP `GET /api/together/rooms` / WS `list`）。
class TogetherRoomBrief {
  const TogetherRoomBrief({
    required this.code,
    required this.title,
    required this.videoTitle,
    required this.cover,
    required this.host,
    required this.members,
    required this.ep,
    required this.playing,
  });

  final String code;
  final String title;
  final String videoTitle;
  final String cover;
  final String host;
  final int members;
  final int ep;
  final bool playing;

  factory TogetherRoomBrief.fromJson(Map<String, dynamic> j) {
    final title = '${j['title'] ?? '一起看'}';
    return TogetherRoomBrief(
      code: '${j['code'] ?? ''}',
      title: title,
      videoTitle: '${j['videoTitle'] ?? title}',
      cover: '${j['cover'] ?? ''}',
      host: '${j['host'] ?? j['hostName'] ?? ''}',
      members: togetherInt(j['members'], 1),
      ep: togetherInt(j['ep'], 1),
      playing: '${j['state'] ?? 'pause'}' == 'play',
    );
  }
}

/// 广场拉取结果：reachable 用来区分「没有房间」和「连不上服务器」。
class TogetherLobbyResult {
  const TogetherLobbyResult({required this.rooms, required this.reachable});
  final List<TogetherRoomBrief> rooms;
  final bool reachable;
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
      final ch = WebSocketChannel.connect(Uri.parse(Api.wsBase));
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
    sub?.cancel();
    final ch = _channel;
    _channel = null;
    try {
      ch?.sink.close();
    } catch (_) {}
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
    sub?.cancel();
    final ch = _channel;
    _channel = null;
    try {
      ch?.sink.close();
    } catch (_) {}
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
        if (errCode == 'not_found' || errCode == 'room_full') {
          code = '';
          host = false;
          _pendingCreate = null;
        }
        onError(errCode, '${msg['msg'] ?? ''}');
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
    // 断线重连：房主重建房间，成员按房间号 rejoin（在 onOpen 前发出，避免重复 create）。
    final pending = _pendingCreate;
    if (pending != null) {
      _send(pending);
    } else if (code.isNotEmpty) {
      if (host) {
        _send(_createPayload());
      } else {
        _send({'action': 'join', 'code': code});
      }
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

  /* ------------------------------------------------------------ 广场 */

  /// 先走约定的 HTTP 接口，失败再用 WS `list`，都失败就返回不可达。
  static Future<TogetherLobbyResult> fetchLobby() async {
    final viaHttp = await _roomsViaHttp();
    if (viaHttp != null) {
      return TogetherLobbyResult(rooms: viaHttp, reachable: true);
    }
    final viaWs = await _roomsViaWs();
    if (viaWs != null) {
      return TogetherLobbyResult(rooms: viaWs, reachable: true);
    }
    return const TogetherLobbyResult(rooms: <TogetherRoomBrief>[], reachable: false);
  }

  static Future<List<TogetherRoomBrief>?> _roomsViaHttp() async {
    try {
      final r = await http
          .get(Uri.parse('${Api.base}/together/rooms'))
          .timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) return null;
      final decoded = jsonDecode(utf8.decode(r.bodyBytes));
      dynamic list;
      if (decoded is List) {
        list = decoded;
      } else if (decoded is Map) {
        final data = decoded['data'] ?? decoded['rooms'] ?? decoded['items'];
        if (data is List) {
          list = data;
        } else if (data is Map) {
          list = data['rooms'] ?? data['items'] ?? data['list'];
        }
      }
      if (list is! List) return null;
      return list
          .whereType<Map>()
          .map((e) => TogetherRoomBrief.fromJson(togetherMap(e)))
          .where((e) => e.code.isNotEmpty)
          .toList();
    } catch (_) {
      return null;
    }
  }

  static Future<List<TogetherRoomBrief>?> _roomsViaWs() async {
    WebSocketChannel? channel;
    StreamSubscription<dynamic>? sub;
    final completer = Completer<List<TogetherRoomBrief>?>();
    void finish(List<TogetherRoomBrief>? value) {
      if (!completer.isCompleted) completer.complete(value);
    }

    try {
      channel = WebSocketChannel.connect(Uri.parse(Api.wsBase));
      sub = channel.stream.listen(
        (raw) {
          try {
            final decoded = jsonDecode('$raw');
            if (decoded is! Map) return;
            if ('${decoded['action']}' != 'rooms') return;
            final list = decoded['rooms'];
            if (list is! List) return;
            finish(list
                .whereType<Map>()
                .map((e) => TogetherRoomBrief.fromJson(togetherMap(e)))
                .where((e) => e.code.isNotEmpty)
                .toList());
          } catch (_) {
            // 忽略坏包，继续等下一次。
          }
        },
        onError: (_) => finish(null),
        onDone: () => finish(null),
        cancelOnError: false,
      );
      await channel.ready.timeout(const Duration(seconds: 5));
      channel.sink.add(jsonEncode({'action': 'list'}));
      return await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );
    } catch (_) {
      return null;
    } finally {
      await sub?.cancel();
      try {
        await channel?.sink.close();
      } catch (_) {}
    }
  }
}

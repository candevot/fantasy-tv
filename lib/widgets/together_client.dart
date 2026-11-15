import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:web_socket_channel/web_socket_channel.dart';

import '../api.dart';
import '../models.dart';
import 'together_host_credential.dart';
import 'together_sync.dart';
import 'together_ui.dart';

/* ========================================================================== */
/*  一起看 · 协议客户端                                                        */
/*                                                                            */
/*  TOGETHER_OPEN_CONTROL（2026-11-15）：房间没有房主权限了。play / pause /    */
/*  seek / next / prev / rate / switchLine / switchTitle / switchSource 谁发都  */
/*  算数，服务端只广播「最后一条 + 是谁操作的」。房间绑定「源 + 片 + 线路」。  */
/*                                                                            */
/*  协议里的 leaderId 不是权限，只是「谁在推进度心跳」：最后一条控制指令的      */
/*  发送者。别人一操作，主导权就换过去，不会有人被挡住。                       */
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

/// 房间绑定的线路（建房时从「源」里带进来的线路列表）。
///
/// 服务端只认 [name]：同一部片在咕噜源上有「金牌极速 / 旋风VIP / 电影天堂」
/// 三条，房间就存这三条，任何成员换线路都在这个列表里换。
class TogetherLine {
  const TogetherLine({
    required this.name,
    this.id = '',
    this.episodes = 0,
    this.quality = '',
    this.status = '',
  });

  final String name;
  final String id;
  final int episodes;
  final String quality;
  final String status;

  bool get isEmpty => name.trim().isEmpty;

  /// 画质提示：线路自带的 `quality` 优先，没有就从线路名里认
  /// （「幻想4K」「1080P」这类命名在源里很常见）。
  String get qualityLabel {
    final own = quality.trim();
    if (own.isNotEmpty) return own;
    final text = name.toUpperCase().replaceAll(' ', '');
    if (text.contains('4K') || text.contains('2160')) return '4K';
    if (text.contains('2K') || text.contains('1440')) return '2K';
    if (text.contains('1080') || text.contains('蓝光') || text.contains('超清')) {
      return '1080P';
    }
    if (text.contains('720') || text.contains('高清')) return '720P';
    return '';
  }

  /// 列表里的一行摘要：「金牌极速 · 1080P · 24 集」。
  String get subtitle {
    final parts = <String>[
      if (qualityLabel.isNotEmpty) qualityLabel,
      if (episodes > 0) '$episodes 集',
    ];
    return parts.join(' · ');
  }

  factory TogetherLine.fromJson(Map<String, dynamic> j) {
    final name = '${j['name'] ?? j['lineName'] ?? j['label'] ?? j['id'] ?? ''}'
        .trim();
    final id = '${j['id'] ?? j['line'] ?? j['lineId'] ?? ''}'.trim();
    return TogetherLine(
      name: name.isEmpty ? id : name,
      id: id.isEmpty ? name : id,
      episodes: togetherInt(j['episodes'] ?? j['count'] ?? j['ep']),
      quality: '${j['quality'] ?? j['resolution'] ?? ''}'.trim(),
      status: '${j['status'] ?? ''}'.trim(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        // id 空的时候用名字当 id：服务端按名字找线路，客户端按 id 起播，
        // 两者一致才不会出现「房间换了线、本地还播旧线」。
        'id': id.isEmpty ? name : id,
        'episodes': episodes,
        if (quality.isNotEmpty) 'quality': quality,
      };

  static List<TogetherLine> listFrom(dynamic raw) {
    if (raw is! List) return const <TogetherLine>[];
    final out = <TogetherLine>[];
    for (final item in raw) {
      final line = item is Map
          ? TogetherLine.fromJson(togetherMap(item))
          : TogetherLine(name: '$item'.trim(), id: '$item'.trim());
      if (!line.isEmpty) out.add(line);
    }
    return out;
  }
}

/// 「谁做了什么」：服务端 `op` 广播 / `room_state.by`。
class TogetherOp {
  const TogetherOp({
    required this.id,
    required this.name,
    required this.avatar,
    required this.action,
    required this.label,
    this.from = '',
    this.to = '',
  });

  final String id;
  final String name;
  final String avatar;

  /// `play` / `pause` / `seek` / `rate` / `episode` / `switchLine` /
  /// `switchTitle` / `switchSource`。
  final String action;

  /// 人话文案：「换了线路 → 幻想4K」。
  final String label;
  final String from;
  final String to;

  /// 聊天区 / 顶部提示里显示的整句。「小明 换了线路 → 幻想4K」。
  String get text => label.isEmpty ? '$name 操作了播放' : '$name $label';

  factory TogetherOp.fromJson(Map<String, dynamic> j) {
    final who = togetherMap(j['by']);
    return TogetherOp(
      id: '${who['id'] ?? ''}',
      name: '${who['name'] ?? j['name'] ?? '有人'}',
      avatar: '${who['avatar'] ?? ''}',
      action: '${j['op'] ?? j['action'] ?? ''}',
      label: '${j['label'] ?? ''}',
      from: '${j['from'] ?? ''}',
      to: '${j['to'] ?? ''}',
    );
  }
}


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
    this.leaderId = '',
    this.leaderName = '',
    this.by,
    this.sourceKey = '',
    this.sourceName = '',
    this.sourceKind = '',
    this.sourceApi = '',
    this.vodName = '',
    this.vodYear = 0,
    this.lines = const <TogetherLine>[],
    this.lineName = '',
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

  /// 当前主导者（最后一条控制指令的发送者）。**不是权限**：
  /// 任何人发指令都会顶掉它；只有他的进度心跳会被服务端当成权威。
  final String leaderId;
  final String leaderName;

  /// 最近一次操作（谁 + 做了什么），给 UI 显示「小明 换了线路 → 幻想4K」。
  final TogetherOp? by;

  /// 房间绑定的源：`hx` / `咕噜` / `剧圈` …
  final String sourceKey;
  final String sourceName;
  final String sourceKind;
  final String sourceApi;

  /// 房间绑定的片名 / 年份。
  final String vodName;
  final int vodYear;

  /// 房间绑定的线路列表（建房时那个源的线路，任何人都在这里面换）。
  final List<TogetherLine> lines;

  /// 当前线路的展示名。
  final String lineName;

  bool get isLive => kind == 'live' || liveChannel != null;

  /// 有没有绑定线路列表（老服务端 / 没传 lines 的房间没有）。
  bool get hasLines => lines.isNotEmpty;

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
      // 服务端字段类型不做保证：`members` 不是数组时 `as List` 会抛
      // TypeError，而 try 只包了 jsonDecode，异常会从 listen 回调里跑出去。
      members: (j['members'] is List ? j['members'] as List : const <Object?>[])
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
      leaderId: '${j['leaderId'] ?? ''}'.trim(),
      leaderName: '${j['leader'] ?? ''}'.trim(),
      by: j['by'] is Map ? TogetherOp.fromJson(togetherMap(j['by'])) : null,
      sourceKey: '${j['sourceKey'] ?? ''}'.trim(),
      sourceName: '${j['sourceName'] ?? ''}'.trim(),
      sourceKind: '${j['sourceKind'] ?? ''}'.trim(),
      sourceApi: '${j['sourceApi'] ?? ''}'.trim(),
      vodName: '${j['vodName'] ?? ''}'.trim(),
      vodYear: togetherInt(j['vodYear']),
      lines: TogetherLine.listFrom(j['lines']),
      lineName: '${j['lineName'] ?? ''}'.trim(),
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
      leaderId: leaderId,
      leaderName: leaderName,
      by: by,
      sourceKey: sourceKey,
      sourceName: sourceName,
      sourceKind: sourceKind,
      sourceApi: sourceApi,
      vodName: vodName,
      vodYear: vodYear,
      lines: lines,
      lineName: lineName,
    );
  }

  /// 这条线路名在本房间里是否合法（房间绑定了线路列表时按列表校验）。
  bool allowsLine(String name) {
    final key = name.trim();
    if (key.isEmpty) return false;
    if (lines.isEmpty) return true;
    for (final line in lines) {
      if (line.name == key || line.id == key) return true;
    }
    return false;
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
    this.leaderId = '',
    this.sourceKey = '',
    this.sourceName = '',
    this.sourceKind = '',
    this.sourceApi = '',
    this.vodName = '',
    this.vodYear = 0,
    this.lines = const <TogetherLine>[],
    this.lineName = '',
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

  /// 建房时绑定的「源 + 片 + 线路列表」。
  final String leaderId;
  final String sourceKey;
  final String sourceName;
  final String sourceKind;
  final String sourceApi;
  final String vodName;
  final int vodYear;
  final List<TogetherLine> lines;
  final String lineName;

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
      // 服务端字段类型不做保证：`members` 不是数组时 `as List` 会抛
      // TypeError，而 try 只包了 jsonDecode，异常会从 listen 回调里跑出去。
      members: (j['members'] is List ? j['members'] as List : const <Object?>[])
          .whereType<Map>()
          .map((e) => TogetherMember.fromJson(togetherMap(e)))
          .toList(),
      kind: '${j['kind'] ?? ''}'.trim().isEmpty
          ? (live != null ? 'live' : '')
          : '${j['kind']}'.trim(),
      liveChannel: live,
      leaderId: '${j['leaderId'] ?? ''}'.trim(),
      sourceKey: '${j['sourceKey'] ?? ''}'.trim(),
      sourceName: '${j['sourceName'] ?? ''}'.trim(),
      sourceKind: '${j['sourceKind'] ?? ''}'.trim(),
      sourceApi: '${j['sourceApi'] ?? ''}'.trim(),
      vodName: '${j['vodName'] ?? ''}'.trim(),
      vodYear: togetherInt(j['vodYear']),
      lines: TogetherLine.listFrom(j['lines']),
      lineName: '${j['lineName'] ?? ''}'.trim(),
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
    this.onUnreachable,
    this.onOp,
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

  /// 房间里有人操作播放 / 线路 / 片源时回调：「小明 换了线路 → 幻想4K」。
  ///
  /// 服务端已经广播给所有人（包括发起者），UI 只负责显示，不做权限判断。
  final void Function(TogetherOp op)? onOp;

  /// 连续失败 [giveUpAfterFailures] 次后回调（参数是当前 ws 地址）。
  ///
  /// 页面拿它显示「连不上 <地址>」+ 一个「重试」按钮，而不是让
  /// 「正在自动重连…」永远挂着。
  final void Function(String url)? onUnreachable;

  /// 房主操作合并窗口。
  ///
  /// 房主每次暂停 / 拖动 / 切集 / 改倍速都要**立刻**推一次 room_state，
  /// 不能等 9 秒心跳；但拖拽过程中 seek 会连续触发，逐条发给服务端等于
  /// 自己把房间消息刷爆。所以这里只对「可合并」的推送开一个 200ms 窗口：
  /// 窗口内只保留最后一次 payload，到点发一次。
  /// TOGETHER_OPEN_CONTROL（2026-11-15）：合并窗口按用户的验收口径取 300ms
  /// —— 拖动进度时会连续触发 seek，300ms 内只发最后一次，服务端不被打爆，
  /// 别人也不会被拖着一下一下硬跳。
  static const Duration hostPushWindow = Duration(milliseconds: 300);

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

  /// 连续连接失败超过这个次数就停止自动重连，交给页面显示「重试」按钮。
  ///
  /// 3+6+12+24 ≈ 45 秒；再往后每 30 秒一次的重连对用户没有任何意义，
  /// 却会一直显示「正在重连」—— 这正是要修的那个体验问题。
  static const int giveUpAfterFailures = 5;

  /// 自动重连失败次数（连上 hello 后清零）。
  int _failedAttempts = 0;

  /// 当前使用的 WebSocket 地址（错误提示里要写清楚，方便用户核对）。
  String get wsUrl => Api.wsBase;

  /// 已经连续失败几次。
  int get failedAttempts => _failedAttempts;

  /// 断线重连退避：3s / 6s / 12s / 24s，上限 30s。
  int _retryAttempt = 0;
  int _retryDelaySec = 0;

  /// 正在用 HTTP 探测 token 是否过期，避免并发探测 / 探测期间又排重连。
  bool _authChecking = false;

  /// 合并窗口里攒着的那一份房主 state（拖拽时只保留最后一次）。
  Map<String, dynamic>? _pendingHostState;

  /// 合并窗口定时器；非空表示有 payload 还没发出去。
  Timer? _hostPushTimer;

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
  final _hostCredential = TogetherHostCredential();

  String _hostVideoId = '';
  int _hostEp = 1;
  String _hostLine = 'l1';
  String _hostLineName = '';
  String _hostTitle = '';
  /* 房间绑定的「源 + 片 + 线路列表」：重连重建房间时原样带上。 */
  String _hostSourceKey = '';
  String _hostSourceName = '';
  String _hostSourceKind = '';
  String _hostSourceApi = '';
  String _hostVodName = '';
  int _hostVodYear = 0;
  List<TogetherLine> _hostLines = const <TogetherLine>[];
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

  /// 用户点了「重试」：清零失败次数并立刻重连（不等退避）。
  void retryNow() {
    if (_closed) return;
    _retry?.cancel();
    _retry = null;
    _retryAttempt = 0;
    _failedAttempts = 0;
    _retryDelaySec = 0;
    _connecting = false;
    connect();
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
    // 断线后合并窗口里的 seek 已经没有意义（重连再补发会把成员拽回旧位置）。
    _dropHostState();
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
    if (_failedAttempts >= giveUpAfterFailures) {
      // 不再无限重连：把地址交给页面，显示明确提示 + 「重试」按钮。
      _retryDelaySec = 0;
      _retry?.cancel();
      _retry = null;
      final url = wsUrl;
      onUnreachable?.call(url);
      return;
    }
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
    _failedAttempts++;
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
    _send(_hostCredential.joinPayload(code));
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
    String sourceKey = '',
    String sourceName = '',
    String sourceKind = '',
    String sourceApi = '',
    String vodName = '',
    int vodYear = 0,
    List<TogetherLine> lines = const <TogetherLine>[],
    String lineName = '',
  }) {
    _hostVideoId = videoId;
    _hostEp = ep < 1 ? 1 : ep;
    _hostLine = line.isEmpty ? 'l1' : line;
    _hostLineName = lineName;
    _hostTitle = title;
    _hostKind = kind;
    _hostChannelId = channelId;
    _hostLive = live;
    _hostSourceKey = sourceKey;
    _hostSourceName = sourceName;
    _hostSourceKind = sourceKind;
    _hostSourceApi = sourceApi;
    _hostVodName = vodName;
    _hostVodYear = vodYear;
    _hostLines = lines;
    host = true;
    _hostCredential.clear();
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
      if (_hostLineName.isNotEmpty) 'lineName': _hostLineName,
      if (_hostTitle.isNotEmpty) 'title': _hostTitle,
      // 房间绑定的「源 + 片 + 线路列表」：新成员进房间拿到的就是这一份。
      if (_hostSourceKey.isNotEmpty) 'sourceKey': _hostSourceKey,
      if (_hostSourceName.isNotEmpty) 'sourceName': _hostSourceName,
      if (_hostSourceKind.isNotEmpty) 'sourceKind': _hostSourceKind,
      if (_hostSourceApi.isNotEmpty) 'sourceApi': _hostSourceApi,
      if (_hostVodName.isNotEmpty) 'vodName': _hostVodName,
      if (_hostVodYear > 0) 'vodYear': _hostVodYear,
      if (_hostLines.isNotEmpty)
        'lines': <Map<String, dynamic>>[
          for (final line in _hostLines) line.toJson(),
        ],
    };
  }

  bool joinRoom(String roomCode) {
    final value = roomCode.trim();
    if (!validCode(value)) {
      onError('bad_code', '房间号必须是 6 位数字');
      return false;
    }
    if (value != code) _hostCredential.clear();
    code = value;
    host = false;
    _pendingCreate = null;
    _rejoining = true;
    if (_connected) {
      _send(_hostCredential.joinPayload(value));
    }
    return true;
  }

  /// 房主：写入权威状态（播放 / 暂停 / 切片）。
  ///
  /// [coalesce] 为真时走 [hostPushWindow] 合并窗口：窗口内连续多次调用只发
  /// 最后一次。服务端照常递增 rev，成员的 seq gate 照常判重，协议没变。
  void sendState(
    String state,
    double position, {
    String? videoId,
    int? ep,
    String? line,
    double? rate,
    bool live = false,
    bool coalesce = false,
    bool quiet = false,
    List<TogetherLine>? lines,
    String? lineName,
    String? op,
  }) {
    // 房主标记由服务器判定：即使本地标记过期，也让服务器拒绝并回发权威状态。
    if (videoId != null && videoId.isNotEmpty) _hostVideoId = videoId;
    if (ep != null && ep > 0) _hostEp = ep;
    if (line != null && line.isNotEmpty) _hostLine = line;
    final payload = <String, dynamic>{
      'action': 'state',
      'state': state,
      'playing': state == 'play',
      'position': position < 0 ? 0 : position,
      if (videoId != null && videoId.isNotEmpty) 'videoId': videoId,
      if (ep != null && ep > 0) 'ep': ep,
      if (line != null && line.isNotEmpty) 'line': line,
      if (rate != null && rate > 0) 'rate': rate,
      if (lineName != null && lineName.isNotEmpty) 'lineName': lineName,
      // 操作类型：只用于服务端拼「谁操作的」文案（跳到 12:34 / 暂停了 / 1.5x）。
      if (op != null && op.isNotEmpty) 'op': op,
      // 房间线路列表：详情页进来的房间详情是后到的，拉到后补一次绑定。
      if (lines != null && lines.isNotEmpty)
        'lines': <Map<String, dynamic>>[for (final l in lines) l.toJson()],
      // 纯进度心跳：服务端不接受它改「当前主导者」，也不认非主导者的心跳，
      // 避免两个人都开着播放器时互相把权威进度拽来拽去。
      if (quiet) 'quiet': true,
      if (live) ...<String, dynamic>{
        'kind': 'live',
        'channelId': _hostChannelId,
        ..._hostLive,
      },
    };
    if (coalesce) {
      _pendingHostState = payload;
      _hostPushTimer?.cancel();
      _hostPushTimer = Timer(hostPushWindow, _flushHostState);
      return;
    }
    // 不可合并的操作（暂停 / 切集 / 改倍速）先把手里的 seek 发掉，
    // 保证服务端收到的先后顺序和房主操作顺序一致。
    _flushHostState();
    _send(payload);
  }

  /// 把合并窗口里攒着的房主状态立刻发出去（幂等）。
  void _flushHostState() {
    _hostPushTimer?.cancel();
    _hostPushTimer = null;
    final pending = _pendingHostState;
    _pendingHostState = null;
    if (pending != null) _send(pending);
  }

  /// 丢弃合并窗口里的内容：断线 / 离开房间后不能把旧的 seek 补发出去。
  void _dropHostState() {
    _hostPushTimer?.cancel();
    _hostPushTimer = null;
    _pendingHostState = null;
  }

  /// 房主：修改倍速，立刻广播给成员。
  void sendRate(double rate) {
    _flushHostState();
    _send({'action': 'rate', 'rate': rate});
  }

  /// 房主：拖动进度。
  ///
  /// 只带 position 的 seek 会让服务端自己拼一份只改进度的状态；走
  /// [sendState] 才能带上播放态 / 倍速，成员同一份 room_state 里就拿到
  /// 全部权威字段。这里默认允许合并（拖拽连续触发时只发最后一次）。
  void sendSeek(
    double position, {
    String state = 'play',
    double? rate,
    bool coalesce = true,
  }) {
    sendState(
      state,
      position < 0 ? 0 : position,
      rate: rate,
      coalesce: coalesce,
    );
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
    _flushHostState();
    _send({
      'action': 'episode',
      'ep': ep,
      if (line != null && line.isNotEmpty) 'line': line,
    });
  }

  /* ------------------------------------------------------ 房间内多人操作 */

  /// 换线路（房间内任何人可发，限建房时那个源的线路）。
  ///
  /// 只换线路，**不动进度**：传上当前 position，服务端原样保留并广播，
  /// 所有人换完线路还是接着看原来的位置，不会从头开始。
  void sendSwitchLine(
    String name, {
    double? position,
    bool? playing,
    int? ep,
  }) {
    final value = name.trim();
    if (value.isEmpty) return;
    _hostLine = value;
    _hostLineName = value;
    _flushHostState();
    _send(<String, dynamic>{
      'action': 'switchLine',
      'name': value,
      if (position != null) 'position': position < 0 ? 0 : position,
      if (playing != null) 'playing': playing,
      if (ep != null && ep > 0) 'ep': ep,
    });
  }

  /// 换片 / 换源（房间内，三步选择器选完）：新的源、片、线路列表一起下发。
  void sendSwitchTitle({
    required String videoId,
    required String vodName,
    int vodYear = 0,
    String sourceKey = '',
    String sourceName = '',
    String sourceKind = '',
    String sourceApi = '',
    List<TogetherLine> lines = const <TogetherLine>[],
    String line = '',
    int ep = 1,
    double position = 0,
    bool playing = true,
  }) {
    if (videoId.trim().isEmpty) return;
    _hostVideoId = videoId.trim();
    _hostVodName = vodName;
    _hostVodYear = vodYear;
    _hostSourceKey = sourceKey;
    _hostSourceName = sourceName;
    _hostSourceKind = sourceKind;
    _hostSourceApi = sourceApi;
    if (lines.isNotEmpty) _hostLines = lines;
    _hostLine = line;
    _hostEp = ep < 1 ? 1 : ep;
    _flushHostState();
    _send(<String, dynamic>{
      'action': 'switchTitle',
      'videoId': _hostVideoId,
      'vodName': vodName,
      if (vodYear > 0) 'vodYear': vodYear,
      if (sourceKey.isNotEmpty) 'sourceKey': sourceKey,
      if (sourceName.isNotEmpty) 'sourceName': sourceName,
      if (sourceKind.isNotEmpty) 'sourceKind': sourceKind,
      if (sourceApi.isNotEmpty) 'sourceApi': sourceApi,
      if (lines.isNotEmpty)
        'lines': <Map<String, dynamic>>[for (final l in lines) l.toJson()],
      if (line.isNotEmpty) 'line': line,
      'ep': _hostEp,
      'position': position < 0 ? 0 : position,
      'playing': playing,
    });
  }

  /// 只换源（同一部片换到另一个源）：线路列表跟着换。
  void sendSwitchSource({
    required String sourceKey,
    String sourceName = '',
    String sourceKind = '',
    String sourceApi = '',
    List<TogetherLine> lines = const <TogetherLine>[],
    String line = '',
    double? position,
  }) {
    final key = sourceKey.trim();
    if (key.isEmpty) return;
    _hostSourceKey = key;
    _hostSourceName = sourceName.isEmpty ? key : sourceName;
    _hostSourceKind = sourceKind;
    _hostSourceApi = sourceApi;
    if (lines.isNotEmpty) _hostLines = lines;
    if (line.isNotEmpty) _hostLine = line;
    _flushHostState();
    _send(<String, dynamic>{
      'action': 'switchSource',
      'sourceKey': key,
      'sourceName': _hostSourceName,
      if (sourceKind.isNotEmpty) 'sourceKind': sourceKind,
      if (sourceApi.isNotEmpty) 'sourceApi': sourceApi,
      if (lines.isNotEmpty)
        'lines': <Map<String, dynamic>>[for (final l in lines) l.toJson()],
      if (line.isNotEmpty) 'line': line,
      if (position != null) 'position': position < 0 ? 0 : position,
    });
  }

  /// 记住房间当前绑定的源 / 片 / 线路：断线重连时若房间已解散，
  /// 用这份最新的绑定重建，而不是回到建房那一刻的旧片。
  void adoptRoom(TogetherRoomState state) {
    if (state.code.isEmpty || state.code != code) return;
    if (state.videoId.isNotEmpty) _hostVideoId = state.videoId;
    if (state.ep > 0) _hostEp = state.ep;
    if (state.line.isNotEmpty) _hostLine = state.line;
    if (state.lineName.isNotEmpty) _hostLineName = state.lineName;
    if (state.sourceKey.isNotEmpty) _hostSourceKey = state.sourceKey;
    if (state.sourceName.isNotEmpty) _hostSourceName = state.sourceName;
    if (state.sourceKind.isNotEmpty) _hostSourceKind = state.sourceKind;
    if (state.sourceApi.isNotEmpty) _hostSourceApi = state.sourceApi;
    if (state.vodName.isNotEmpty) _hostVodName = state.vodName;
    if (state.vodYear > 0) _hostVodYear = state.vodYear;
    if (state.lines.isNotEmpty) _hostLines = state.lines;
    if (_hostTitle.isEmpty && state.title.isNotEmpty) _hostTitle = state.title;
  }

  void leave() {
    if (_connected && code.isNotEmpty) _send({'action': 'leave'});
    _dropHostState();
    _hostCredential.clear();
    code = '';
    host = false;
    _pendingCreate = null;
    _rejoining = false;
  }

  void dispose() {
    _dropHostState();
    _hostCredential.clear();
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
        if (info.code.isEmpty || _pendingCreate == null) return;
        _hostCredential.clear();
        _hostCredential.capture(info.code, msg);
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
      case 'op':
        onOp?.call(TogetherOp.fromJson(msg));
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
          _hostCredential.clear();
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
            _hostCredential.clear();
            code = '';
            host = false;
          }
        } else if (errCode == 'room_full' || _isPasswordError(errCode)) {
          _hostCredential.clear();
          code = '';
          host = false;
          _pendingCreate = null;
        }
        onError(errCode, errMsg);
        break;
      case 'closed':
        _dropHostState();
        _hostCredential.clear();
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
    _failedAttempts = 0;
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
      _send(_hostCredential.joinPayload(code));
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

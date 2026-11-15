import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/api.dart';
import 'package:fantasy_tv/widgets/together_client.dart';

/* ========================================================================== */
/*  一起看 · 客户端报文回归（本地假服务器，不连外网）                          */
/*                                                                            */
/*  钉住 OPEN_CONTROL 的客户端半边：                                           */
/*   · 建房报文带「源 + 片 + 线路列表」；                                       */
/*   · switchLine 带线路名 + 当前进度（换线路不从头开始）；                     */
/*   · switchTitle 带新源 / 新片 / 新线路列表；                                 */
/*   · room_state 里的 leaderId / by 能落到状态上，op 广播能拿到「谁操作的」；   */
/*   · 进度心跳带 quiet（不抢主导者）。                                         */
/* ========================================================================== */

class _FakeServer {
  _FakeServer(this._server);

  final HttpServer _server;
  final List<Map<String, dynamic>> received = <Map<String, dynamic>>[];
  WebSocket? _socket;
  final Completer<void> connected = Completer<void>();

  int get port => _server.port;

  static Future<_FakeServer> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeServer(http);
    unawaited(fake._listen());
    return fake;
  }

  Future<void> _listen() async {
    await for (final request in _server) {
      final socket = await WebSocketTransformer.upgrade(request);
      _socket = socket;
      socket.add(jsonEncode(<String, dynamic>{
        'action': 'hello',
        'serverTime': DateTime.now().millisecondsSinceEpoch,
        'user': <String, dynamic>{'id': 'g_me', 'name': '我', 'avatar': ''},
      }));
      if (!connected.isCompleted) connected.complete();
      socket.listen((raw) {
        try {
          final msg = jsonDecode('$raw');
          if (msg is Map) received.add(Map<String, dynamic>.from(msg));
        } catch (_) {
          // 客户端只会发 JSON，解析不了就忽略。
        }
      });
    }
  }

  Map<String, dynamic>? lastOf(String action) {
    for (var i = received.length - 1; i >= 0; i--) {
      if (received[i]['action'] == action) return received[i];
    }
    return null;
  }

  void send(Map<String, dynamic> payload) {
    _socket?.add(jsonEncode(payload));
  }

  Future<void> close() async {
    await _socket?.close();
    await _server.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeServer server;
  late String oldWs;
  late TogetherClient client;

  final rooms = <TogetherRoomInfo>[];
  final states = <TogetherRoomState>[];
  final ops = <TogetherOp>[];

  setUp(() async {
    oldWs = Api.wsBase;
    rooms.clear();
    states.clear();
    ops.clear();
    server = await _FakeServer.start();
    Api.wsBase = 'ws://127.0.0.1:${server.port}/ws/together';
    client = TogetherClient(
      onOpen: (_) {},
      onDown: () {},
      onRoom: rooms.add,
      onState: states.add,
      onChat: (_) {},
      onSystem: (_) {},
      onError: (_, __) {},
      onClosed: (_) {},
      onOp: ops.add,
    );
  });

  tearDown(() async {
    client.dispose();
    await server.close();
    Api.wsBase = oldWs;
  });

  Future<void> connect() async {
    client.connect();
    await server.connected.future;
    // 等 hello 处理完（它会把 _connected 置真）。
    await Future<void>.delayed(const Duration(milliseconds: 60));
  }

  test('建房报文带源 + 片 + 线路列表', () async {
    await connect();
    client.createRoom(
      videoId: '@src:咕噜::9988',
      ep: 3,
      line: 'l_1',
      lineName: '金牌极速',
      title: '狂飙 · 一起看',
      sourceKey: '咕噜',
      sourceName: '咕噜',
      sourceKind: 'jar',
      sourceApi: 'csp_Gulu',
      vodName: '狂飙',
      vodYear: 2023,
      lines: const <TogetherLine>[
        TogetherLine(name: '金牌极速', id: 'l_1', episodes: 24),
        TogetherLine(name: '旋风VIP', id: 'l_2', episodes: 24, quality: '4K'),
      ],
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final create = server.lastOf('create');
    expect(create, isNotNull);
    expect(create!['videoId'], '@src:咕噜::9988');
    expect(create['sourceKey'], '咕噜');
    expect(create['sourceName'], '咕噜');
    expect(create['sourceKind'], 'jar');
    expect(create['sourceApi'], 'csp_Gulu');
    expect(create['vodName'], '狂飙');
    expect(create['vodYear'], 2023);
    expect(create['line'], 'l_1');
    expect(create['lineName'], '金牌极速');
    expect(create['ep'], 3);
    final lines = create['lines'] as List;
    expect(lines.length, 2);
    expect((lines[1] as Map)['name'], '旋风VIP');
    expect((lines[1] as Map)['quality'], '4K');
  });

  test('create 响应 → 房间绑定落到客户端状态', () async {
    await connect();
    client.createRoom(videoId: 'v_1', ep: 1, line: 'l_1');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    server.send(<String, dynamic>{
      'action': 'room',
      'room': <String, dynamic>{
        'code': '123456',
        'title': '狂飙 · 一起看',
        'videoId': 'v_1',
        'ep': 1,
        'line': 'l_1',
        'lineName': '金牌极速',
        'host': 'm_a',
        'leaderId': 'g_me',
        'sourceKey': '咕噜',
        'sourceName': '咕噜',
        'vodName': '狂飙',
        'lines': <Map<String, dynamic>>[
          {'name': '金牌极速', 'id': 'l_1', 'episodes': 24},
        ],
        'members': <Map<String, dynamic>>[
          {'id': 'g_me', 'name': '我', 'host': true, 'leader': true},
        ],
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(rooms, isNotEmpty);
    expect(client.code, '123456');
    expect(rooms.last.sourceKey, '咕噜');
    expect(rooms.last.lines.single.name, '金牌极速');
  });

  test('switchLine / switchTitle 报文带线路名与进度', () async {
    await connect();
    client.createRoom(videoId: 'v_1', ep: 1, line: 'l_1');
    await Future<void>.delayed(const Duration(milliseconds: 40));

    client.sendSwitchLine('旋风VIP', position: 120.5, playing: true, ep: 6);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final switchLine = server.lastOf('switchLine');
    expect(switchLine, isNotNull);
    expect(switchLine!['name'], '旋风VIP');
    // 换线路必须带上当前进度：服务端据此保持位置，不让人从头开始。
    expect(switchLine['position'], 120.5);
    expect(switchLine['playing'], isTrue);
    expect(switchLine['ep'], 6);

    client.sendSwitchTitle(
      videoId: '@src:剧圈::7788',
      vodName: '济公传',
      vodYear: 2010,
      sourceKey: '剧圈',
      sourceName: '剧圈',
      sourceKind: 'cms',
      lines: const <TogetherLine>[
        TogetherLine(name: '剧圈线路1', id: 'q_1', episodes: 12),
      ],
      line: '剧圈线路1',
      ep: 2,
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final switchTitle = server.lastOf('switchTitle');
    expect(switchTitle, isNotNull);
    expect(switchTitle!['videoId'], '@src:剧圈::7788');
    expect(switchTitle['vodName'], '济公传');
    expect(switchTitle['sourceKey'], '剧圈');
    expect((switchTitle['lines'] as List).single['name'], '剧圈线路1');
    expect(switchTitle['line'], '剧圈线路1');
    expect(switchTitle['ep'], 2);
  });

  test('进度心跳带 quiet，操作不带', () async {
    await connect();
    client.createRoom(videoId: 'v_1', ep: 1, line: 'l_1');
    await Future<void>.delayed(const Duration(milliseconds: 40));

    client.sendState('play', 10.0, quiet: true);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(server.lastOf('state')!['quiet'], isTrue);

    client.sendState('play', 20.0);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(server.lastOf('state')!.containsKey('quiet'), isFalse);
  });

  test('room_state / op 广播：leaderId 与「谁操作的」', () async {
    await connect();
    client.createRoom(videoId: 'v_1', ep: 1, line: 'l_1');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    client.joinRoom('123456');
    server.send(<String, dynamic>{
      'action': 'op',
      'by': <String, dynamic>{'id': 'g_b', 'name': '小明'},
      'op': 'switchLine',
      'label': '换了线路 → 幻想4K',
      'from': '金牌极速',
      'to': '幻想4K',
    });
    server.send(<String, dynamic>{
      'action': 'room_state',
      'code': '123456',
      'state': 'play',
      'position': 88.0,
      'serverTime': DateTime.now().millisecondsSinceEpoch,
      'seq': 9,
      'line': 'l_2',
      'lineName': '幻想4K',
      'leaderId': 'g_b',
      'by': <String, dynamic>{'id': 'g_b', 'name': '小明', 'action': 'switchLine'},
      'lines': <Map<String, dynamic>>[
        {'name': '金牌极速', 'id': 'l_1'},
        {'name': '幻想4K', 'id': 'l_2'},
      ],
      'members': <Map<String, dynamic>>[
        {'id': 'g_b', 'name': '小明', 'leader': true},
        {'id': 'g_me', 'name': '我'},
      ],
    });
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(ops, isNotEmpty);
    expect(ops.last.text, '小明 换了线路 → 幻想4K');
    expect(ops.last.from, '金牌极速');
    expect(states, isNotEmpty);
    final state = states.last;
    expect(state.leaderId, 'g_b');
    expect(state.lineName, '幻想4K');
    expect(state.by?.name, '小明');
    expect(state.allowsLine('幻想4K'), isTrue);
    expect(state.playing, isTrue);
    expect(state.position, 88.0);
  });
}

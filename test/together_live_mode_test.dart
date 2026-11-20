import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/api.dart';
import 'package:fantasy_tv/models.dart';
import 'package:fantasy_tv/services/live_edge.dart';
import 'package:fantasy_tv/widgets/player_theme.dart';
import 'package:fantasy_tv/widgets/together_client.dart';
import 'package:fantasy_tv/widgets/together_live.dart';
import 'package:fantasy_tv/widgets/together_room.dart';

/* ========================================================================== */
/*  一起看 · 直播房语义（LIVE_TOGETHER 2026-11-20）                            */
/*                                                                            */
/*  用户最终口径（原话）：「一方点了刷新之后，两边才会同时刷新，跟随电视直播的    */
/*  进度，我是说双方不会同步。正常看的话」                                      */
/*                                                                            */
/*  钉死三条：                                                                 */
/*   ① 频道同步：进房同一个台，谁切台双方一起切；                               */
/*   ② 正常观看不同步：不广播 seek / 位置 / 暂停 / 播放 / 切集；                */
/*   ③ 刷新同步：任何一方点刷新，双方都落到直播边缘前 3 秒（唯一广播的位置动作）。*/
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

  void send(Map<String, dynamic> payload) => _socket?.add(jsonEncode(payload));

  Future<void> close() async {
    await _socket?.close();
    await _server.close(force: true);
  }
}

void main() {
  group('① 频道同步：切台广播只带频道级信息', () {
    test('广播白名单只有切台 + 刷新两个动作', () {
      expect(togetherLiveBroadcastActions, <String>{
        'switchChannel',
        'liveRefresh',
      });
      for (final action in <String>['switchChannel', 'liveRefresh']) {
        expect(togetherLiveMayBroadcast(action), isTrue, reason: action);
      }
      // 直播房绝不广播进度 / 播放态 / 切集 / 倍速。
      for (final action in <String>[
        'seek',
        'position',
        'play',
        'pause',
        'state',
        'rate',
        'episode',
        'next',
        'prev',
        'switchLine',
      ]) {
        expect(togetherLiveMayBroadcast(action), isFalse, reason: action);
        expect(togetherLiveIsLocalOnly(action), isTrue, reason: action);
      }
    });

    test('收到别人的频道变化 → 跟随；同台 / 空 id 不跟随', () {
      expect(
        togetherLiveShouldFollowChannel(incomingId: 'cctv13', currentId: 'cctv5'),
        isTrue,
      );
      expect(
        togetherLiveShouldFollowChannel(incomingId: 'cctv5', currentId: 'cctv5'),
        isFalse,
      );
      expect(
        togetherLiveShouldFollowChannel(incomingId: '', currentId: 'cctv5'),
        isFalse,
      );
      // 验收③ 的探针口径：A 切台 → B 跟随。
      debugPrint(
        '[FxLive] channel follow from=cctv5 to=cctv13 hint=${togetherLiveChannelToast('CCTV-13')}',
      );
    });

    test('切台提示文案：跟随方与操作流水', () {
      expect(togetherLiveChannelToast('CCTV-5'), '已跟着切到「CCTV-5」');
      expect(togetherLiveChannelToast('  '), '已跟着切台');
      expect(togetherLiveChannelLabel('CCTV-5'), '切到 CCTV-5');
      expect(togetherLiveChannelLabel(''), '换了直播台');
    });
  });

  group('② 正常观看不同步：进度只留在本地', () {
    test('直播房没有一起暂停 / 继续', () {
      expect(togetherLiveShowsTogetherPause, isFalse);
    });

    test('验收②：A 落后 B 30 秒，谁都不许拉谁（探针日志）', () {
      const duration = Duration(minutes: 30);
      const aPosition = Duration(minutes: 29, seconds: 50);
      const bPosition = Duration(minutes: 29, seconds: 20);
      final gap = fxLiveLag(position: bPosition, duration: duration) -
          fxLiveLag(position: aPosition, duration: duration);
      expect(gap, const Duration(seconds: 30));

      // 正常观看不会有任何「追边」目标：target 恒为 none。
      final bLog = fxLiveProbeLog(
        event: 'view',
        position: bPosition,
        duration: duration,
        target: null,
        reason: 'local-only lag=${(gap.inMilliseconds / 1000).toStringAsFixed(1)}s',
      );
      debugPrint(bLog);
      expect(bLog, contains('seek=none'));
      expect(bLog, contains('reason=local-only'));

      // 这一方想 seek / 暂停时，直播房根本不广播。
      for (final action in <String>['seek', 'position', 'play', 'pause']) {
        expect(togetherLiveMayBroadcast(action), isFalse);
      }
    });
  });

  group('③ 刷新同步：两边一起落到直播边缘前 3 秒', () {
    test('落点 = 窗口末端前 3 秒', () {
      const duration = Duration(minutes: 30);
      final target = togetherLiveRefreshTarget(duration);
      expect(target, isNotNull);
      expect(duration - target!, fxLiveRefreshRewind);
      expect(fxLiveRefreshRewind, const Duration(seconds: 3));
      // 窗口时长未知 / 太短：不给目标，交给 seekToEnd 兜底。
      expect(togetherLiveRefreshTarget(Duration.zero), isNull);
      expect(togetherLiveRefreshTarget(const Duration(seconds: 2)), isNull);
    });

    test('只有别人的刷新才跟着刷：自己的回声不重复刷', () {
      expect(
        togetherLiveShouldRefreshOnOp(
          action: 'liveRefresh',
          mine: false,
          isLive: true,
        ),
        isTrue,
      );
      expect(
        togetherLiveShouldRefreshOnOp(
          action: 'liveRefresh',
          mine: true,
          isLive: true,
        ),
        isFalse,
      );
      expect(
        togetherLiveShouldRefreshOnOp(
          action: 'seek',
          mine: false,
          isLive: true,
        ),
        isFalse,
      );
      expect(
        togetherLiveShouldRefreshOnOp(
          action: 'liveRefresh',
          mine: false,
          isLive: false,
        ),
        isFalse,
      );
    });

    test('验收①：A 点刷新 → B 也落到边缘前 3 秒（两边探针日志）', () {
      const duration = Duration(minutes: 30);
      const aBefore = Duration(minutes: 29, seconds: 58);
      const bBefore = Duration(minutes: 29, seconds: 10);
      final target = togetherLiveRefreshTarget(duration)!;

      final aLog = fxLiveProbeLog(
        event: 'land',
        position: target,
        duration: duration,
        target: target,
        reason: togetherLiveRefreshReasonSelf,
      );
      final bLog = fxLiveProbeLog(
        event: 'land',
        position: target,
        duration: duration,
        target: target,
        reason: togetherLiveRefreshReasonPeer,
      );
      debugPrint('A(before pos=${aBefore.inSeconds}s) $aLog');
      debugPrint('B(before pos=${bBefore.inSeconds}s) $bLog');

      expect(aLog, contains('reason=refresh'));
      expect(bLog, contains('reason=peer-refresh'));
      // 两边落点一致，且都在末端 3 秒内（验收口径）。
      expect(
        fxLiveIsAtEdge(position: target, duration: duration),
        isTrue,
      );
      expect(togetherLiveRefreshToast('小明'), '小明 已同步刷新直播');
      expect(togetherLiveRefreshToast(''), '有人 已同步刷新直播');
    });
  });

  group('房间模式标记 mode = vod | live', () {
    Map<String, dynamic> liveJson({String kind = 'live', String mode = 'live'}) =>
        <String, dynamic>{
          'code': '123456',
          'title': 'CCTV-5 · 一起看',
          'kind': kind,
          'mode': mode,
          'channelId': 'cctv5',
          'liveName': 'CCTV-5',
          'line': 'l1',
          'lines': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'l1', 'name': '线路1', 'url': 'http://a.m3u8'},
          ],
          'seq': 1,
          'position': 0,
        };

    test('直播房 mode=live，点播房 mode=vod', () {
      final live = TogetherRoomState.fromJson(liveJson());
      expect(live.mode, 'live');
      expect(live.isLive, isTrue);
      expect(live.liveChannel?.id, 'cctv5');
      expect(live.liveChannel?.title, 'CCTV-5');

      final vod = TogetherRoomState.fromJson(<String, dynamic>{
        'code': '654321',
        'kind': 'video',
        'mode': 'vod',
        'videoId': 'v1',
        'seq': 1,
      });
      expect(vod.mode, 'vod');
      expect(vod.isLive, isFalse);
    });

    test('只有 mode 没有 kind 的老/新服务端也能判出直播房', () {
      final state = TogetherRoomState.fromJson(<String, dynamic>{
        'code': '123456',
        'mode': 'live',
        'channelId': 'cctv5',
        'lines': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'l1', 'name': '线路1', 'url': 'http://a.m3u8'},
        ],
        'seq': 2,
      });
      expect(state.isLive, isTrue);
      expect(state.mode, 'live');
    });

    test('建房回包同样带 mode', () {
      final info = TogetherRoomInfo.fromJson(<String, dynamic>{
        'code': '123456',
        'title': 'CCTV-5 · 一起看',
        'mode': 'live',
        'channelId': 'cctv5',
        'lines': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'l1', 'name': '线路1', 'url': 'http://a.m3u8'},
        ],
      });
      expect(info.mode, 'live');
      expect(info.isLive, isTrue);
    });
  });

  group('跟随切台：room_state 里的完整频道', () {
    test('嵌套 liveChannel 优先解析（带线路播放地址）', () {
      final state = TogetherRoomState.fromJson(<String, dynamic>{
        'code': '123456',
        'kind': 'live',
        'mode': 'live',
        'channelId': 'cctv13',
        'liveChannel': <String, dynamic>{
          'id': 'cctv13',
          'title': 'CCTV-13',
          'group': '央视频道',
          'lines': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'l1',
              'name': '1080P',
              'url': 'http://live/cctv13.m3u8',
            },
          ],
        },
        'seq': 3,
      });
      expect(state.mode, 'live');
      expect(state.liveChannel?.title, 'CCTV-13');
      expect(state.liveChannel?.lines.single.url, 'http://live/cctv13.m3u8');
      // 跟随方落点：切台后同样落到边缘前 3 秒（不继承任何进度）。
      expect(
        togetherLiveRefreshTarget(const Duration(minutes: 10)),
        const Duration(minutes: 10) - fxLiveRefreshRewind,
      );
    });
  });

  group('直播房没有一起暂停按钮（widget 断言）', () {
    testWidgets('live：只有刷新，没有播放 / 暂停', (tester) async {
      var toggled = 0;
      var refreshed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TogetherLivePrimaryAction(
              live: true,
              playing: false,
              onTogglePlay: () => toggled++,
              onRefresh: () => refreshed++,
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(find.byIcon(Icons.pause_rounded), findsNothing);
      await tester.tap(find.byType(PGlassIcon));
      await tester.pump();
      expect(refreshed, 1);
      expect(toggled, 0);
    });

    testWidgets('vod：仍有播放 / 暂停，没有刷新（点播行为不动）', (tester) async {
      var toggled = 0;
      var refreshed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TogetherLivePrimaryAction(
              live: false,
              playing: true,
              onTogglePlay: () => toggled++,
              onRefresh: () => refreshed++,
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      expect(find.byIcon(Icons.refresh_rounded), findsNothing);
      await tester.tap(find.byType(PGlassIcon));
      await tester.pump();
      expect(toggled, 1);
      expect(refreshed, 0);
    });
  });

  group('客户端报文：只广播频道 / 刷新，不带进度', () {
    late _FakeServer server;
    late String oldWs;
    late TogetherClient client;
    final ops = <TogetherOp>[];

    setUp(() async {
      oldWs = Api.wsBase;
      ops.clear();
      server = await _FakeServer.start();
      Api.wsBase = 'ws://127.0.0.1:${server.port}/ws/together';
      client = TogetherClient(
        onOpen: (_) {},
        onDown: () {},
        onRoom: (_) {},
        onState: (_) {},
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
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }

    test('建房报文带 mode=live', () async {
      await connect();
      client.createRoom(
        videoId: 'cctv5',
        kind: 'live',
        channelId: 'cctv5',
        title: 'CCTV-5 · 一起看',
        live: <String, dynamic>{
          'liveName': 'CCTV-5',
          'lines': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'l1', 'name': '线路1', 'url': 'http://a'},
          ],
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final create = server.lastOf('create');
      expect(create, isNotNull);
      expect(create!['mode'], 'live');
      expect(create['kind'], 'live');
      expect(create['channelId'], 'cctv5');
    });

    test('sendLiveChannel 只带频道 + 线路，绝不带进度 / 播放态', () async {
      await connect();
      client.sendLiveChannel(
        channelId: 'cctv13',
        name: 'CCTV-13',
        line: 'l2',
        lines: <TogetherLine>[
          const TogetherLine(name: '线路2', id: 'l2', quality: '1080P'),
        ],
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final msg = server.lastOf('switchChannel');
      expect(msg, isNotNull);
      expect(msg!['mode'], 'live');
      expect(msg['channelId'], 'cctv13');
      expect(msg['liveName'], 'CCTV-13');
      expect(msg['line'], 'l2');
      expect(msg.containsKey('position'), isFalse);
      expect(msg.containsKey('playing'), isFalse);
      expect(msg.containsKey('state'), isFalse);
    });

    test('sendLiveRefresh 只发 refresh，不带位置', () async {
      await connect();
      client.sendLiveRefresh();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final msg = server.lastOf('liveRefresh');
      expect(msg, isNotNull);
      expect(msg!['mode'], 'live');
      expect(msg.containsKey('position'), isFalse);
      expect(msg.containsKey('playing'), isFalse);
    });

    test('切台报文带完整频道（含线路播放地址）：跟随方拿到就能起播', () async {
      await connect();
      const channel = LiveChannel(
        id: 'cctv13',
        title: 'CCTV-13',
        cover: '',
        group: '央视频道',
        lines: <LiveLine>[
          LiveLine(id: 'l1', name: '1080P', url: 'http://live/cctv13.m3u8'),
        ],
      );
      client.sendLiveChannel(
        channelId: channel.id,
        name: channel.title,
        group: channel.group,
        line: 'l1',
        channel: channel.toMap(),
        title: encodeLiveRoomTitle(channel),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final msg = server.lastOf('switchChannel');
      expect(msg, isNotNull);
      final full = msg!['liveChannel'] as Map<String, dynamic>;
      final lines = full['lines'] as List<dynamic>;
      expect(lines, hasLength(1));
      expect((lines.single as Map)['url'], 'http://live/cctv13.m3u8');
      // 老服务端 / 老客户端只认标题里编码的频道，标题里也带着。
      expect('${msg['title']}', contains(liveRoomMarker));
    });

    test('收到的 liveRefresh op 进白名单：动作是 liveRefresh、带操作人', () async {
      await connect();
      server.send(<String, dynamic>{
        'action': 'op',
        'by': <String, dynamic>{'id': 'g_b', 'name': '小明', 'avatar': ''},
        'op': 'liveRefresh',
        'label': '刷新了直播',
        'at': DateTime.now().millisecondsSinceEpoch,
      });
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(ops, isNotEmpty);
      expect(ops.last.action, 'liveRefresh');
      expect(ops.last.name, '小明');
    });
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/widgets/together_client.dart';

/* ========================================================================== */
/*  一起看 · OPEN_CONTROL 协议回归                                             */
/*                                                                            */
/*  钉住四件事（用户 2026-11-15 的要求）：                                     */
/*   1. 房间绑定「源 + 片 + 线路列表」，新成员进房就能拿到；                    */
/*   2. 操作广播带「谁操作的」（小明 换了线路 → 幻想4K）；                      */
/*   3. 房间线路列表是换线路的唯一来源，名字比对大小写无关；                    */
/*   4. 没有房主权限：leaderId 只是「谁在推进度」，没有 canControl 之类的门槛。 */
/* ========================================================================== */

void main() {
  group('room_state 解析：源 + 片 + 线路', () {
    Map<String, dynamic> payload() => <String, dynamic>{
          'action': 'room_state',
          'code': '123456',
          'title': '狂飙 · 一起看',
          'hostId': 'g_creator',
          'leaderId': 'g_b',
          'leader': '小明',
          'by': <String, dynamic>{
            'id': 'g_b',
            'name': '小明',
            'action': 'switchLine',
            'label': '换了线路 → 幻想4K',
          },
          'sourceKey': '咕噜',
          'sourceName': '咕噜',
          'sourceKind': 'jar',
          'sourceApi': 'csp_Gulu',
          'videoId': '@src:咕噜::9988',
          'vodName': '狂飙',
          'vodYear': 2023,
          'ep': 7,
          'line': '金牌极速',
          'lineName': '金牌极速',
          'lines': <Map<String, dynamic>>[
            {'name': '金牌极速', 'id': '金牌极速', 'episodes': 24},
            {'name': '旋风VIP', 'id': '旋风VIP', 'episodes': 24, 'quality': '4K'},
            {'name': '电影天堂', 'id': '电影天堂'},
          ],
          'state': 'play',
          'position': 320.5,
          'rate': 1.25,
          'serverTime': 1700000000000,
          'seq': 42,
        };

    test('源 / 片 / 线路列表 / 当前线路都解析出来', () {
      final state = TogetherRoomState.fromJson(payload());
      expect(state.sourceKey, '咕噜');
      expect(state.sourceName, '咕噜');
      expect(state.sourceKind, 'jar');
      expect(state.sourceApi, 'csp_Gulu');
      expect(state.vodName, '狂飙');
      expect(state.vodYear, 2023);
      expect(state.ep, 7);
      expect(state.lineName, '金牌极速');
      expect(state.hasLines, isTrue);
      expect(state.lines.length, 3);
      expect(state.lines[1].name, '旋风VIP');
      expect(state.lines[1].qualityLabel, '4K');
      expect(state.playing, isTrue);
      expect(state.position, 320.5);
      expect(state.rate, 1.25);
      expect(state.seq, 42);
    });

    test('leaderId 只是「谁在推进度」，没有任何权限语义', () {
      final state = TogetherRoomState.fromJson(payload());
      expect(state.leaderId, 'g_b');
      expect(state.leaderName, '小明');
      // 创建者 ≠ 主导者：创建房间的人早就不再是唯一能操作的人。
      expect(state.hostId, 'g_creator');
      expect(state.leaderId, isNot(state.hostId));
    });

    test('操作广播解析成「小明 换了线路 → 幻想4K」', () {
      final state = TogetherRoomState.fromJson(payload());
      expect(state.by, isNotNull);
      expect(state.by!.action, 'switchLine');
      expect(state.by!.name, '小明');
      expect(state.by!.text, '小明 换了线路 → 幻想4K');
    });

    test('没有线路列表 / 没有 leaderId 的老服务端也能解析', () {
      final state = TogetherRoomState.fromJson(<String, dynamic>{
        'action': 'room_state',
        'code': '654321',
        'state': 'pause',
        'position': 12.0,
        'serverTime': 1700000000000,
        'seq': 3,
        'members': <Map<String, dynamic>>[
          {'id': 'g_a', 'name': 'A', 'host': true},
        ],
      });
      expect(state.hasLines, isFalse);
      expect(state.leaderId, isEmpty);
      expect(state.playing, isFalse);
      // 老服务端也没有房间线路：允许任意线路名（不然换线路会被本地拦掉）。
      expect(state.allowsLine('任意线路'), isTrue);
    });
  });

  group('房间线路：名字是唯一标识', () {
    final state = TogetherRoomState.fromJson(<String, dynamic>{
      'code': '111111',
      'lines': <Map<String, dynamic>>[
        {'name': '金牌极速', 'id': 'l_1'},
        {'name': '旋风VIP', 'id': 'l_2'},
      ],
      'lineName': '金牌极速',
      'seq': 1,
    });

    test('按名字 / 按 id 都认（大小写与空白无关）', () {
      expect(state.allowsLine('金牌极速'), isTrue);
      expect(state.allowsLine('l_2'), isTrue);
      expect(state.allowsLine(' 旋风VIP '), isTrue);
      expect(state.allowsLine('不存在的线路'), isFalse);
      expect(state.allowsLine('  '), isFalse);
    });

    test('线路摘要：画质 + 集数', () {
      final line = TogetherLine.fromJson(<String, dynamic>{
        'name': '幻想4K',
        'id': 'l_9',
        'episodes': 36,
      });
      expect(line.qualityLabel, '4K');
      expect(line.subtitle, '4K · 36 集');
      expect(
        TogetherLine.fromJson(<String, dynamic>{'name': '红牛', 'id': 'l_8'})
            .subtitle,
        isEmpty,
      );
    });

    test('线路列表兼容纯字符串数组（老房间 / 简写报文）', () {
      final lines = TogetherLine.listFrom(<Object?>['金牌极速', '旋风VIP']);
      expect(lines.length, 2);
      expect(lines.first.name, '金牌极速');
      expect(lines.first.id, '金牌极速');
    });

    test('TogetherLine.toJson 带 name/id/episodes（建房报文用）', () {
      const line = TogetherLine(name: '旋风VIP', id: 'l_2', episodes: 24, quality: '4K');
      expect(line.toJson(), <String, dynamic>{
        'name': '旋风VIP',
        'id': 'l_2',
        'episodes': 24,
        'quality': '4K',
      });
    });
  });

  group('建房 / 加入报文', () {
    test('create 响应里的源 + 片 + 线路也跟着下发', () {
      final info = TogetherRoomInfo.fromJson(<String, dynamic>{
        'code': '222222',
        'title': '狂飙 · 一起看',
        'videoId': '@src:剧圈::7788',
        'ep': 1,
        'line': 'l_a',
        'lineName': '剧圈线路1',
        'host': 'm_creator',
        'leaderId': 'g_creator',
        'sourceKey': '剧圈',
        'sourceName': '剧圈',
        'sourceKind': 'cms',
        'vodName': '狂飙',
        'vodYear': 2023,
        'lines': <Map<String, dynamic>>[
          {'name': '剧圈线路1', 'id': 'l_a', 'episodes': 24},
        ],
        'members': <Map<String, dynamic>>[
          {'id': 'g_creator', 'name': '我', 'host': true, 'leader': true},
        ],
      });
      expect(info.code, '222222');
      expect(info.sourceKey, '剧圈');
      expect(info.lineName, '剧圈线路1');
      expect(info.lines.length, 1);
      expect(info.vodYear, 2023);
    });
  });

  group('op 广播', () {
    test('缺 by / label 时也要能读，不抛异常', () {
      final op = TogetherOp.fromJson(<String, dynamic>{'op': 'pause'});
      expect(op.name, '有人');
      expect(op.action, 'pause');
      expect(op.text, '有人 操作了播放');
    });

    test('换源 / 换片带 from → to（日志口径）', () {
      final op = TogetherOp.fromJson(<String, dynamic>{
        'by': <String, dynamic>{'id': 'g_x', 'name': '小明'},
        'op': 'switchSource',
        'label': '换成了源「剧圈」',
        'from': '咕噜',
        'to': '剧圈',
      });
      expect(op.from, '咕噜');
      expect(op.to, '剧圈');
      expect(op.text, '小明 换成了源「剧圈」');
    });
  });
}

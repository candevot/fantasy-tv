import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TOGETHER_VOD_REGRESSION（2026-11-21）：修直播全屏切换时，把**点播一起看**
/// 的接线完整过一遍，确认没被最近的改动弄坏。
///
/// 行为级断言在 `together_*_test.dart`（86 个用例）里：进度策略、报文、
/// 全屏顶栏、直播房白名单都在那边。这里补的是**页面接线**——六个环节
/// 谁调谁、退出时谁清理，防止「策略对了但页面没接上」这种断线。
///
/// 对应验收清单：
///   ① 建房 / 加入：房主 create + connect，成员 join + connect；
///   ② 暂停 / 继续 / 拖动 / 切集：房主上报 op，成员按权威 state 跟随；
///   ③ 切线路：按线路名广播，成员映射到本地同名线路；
///   ④ 退出：leave + 释放播放器 + 清状态，不留在房间里；
///   ⑤ 一起看全屏：主画面 + 人数 + 可发言聊天三件都在；
///   ⑥ 直播房：只同步频道 / 刷新，不同步播放态，也不把人拉回进度。
void main() {
  group('① 建房 / 加入', () {
    test('房主建房：createRoom 带源 + 片 + 线路，然后 connect', () {
      final page = _read('lib/pages/together_page.dart');
      final create = _block(page, 'void _createRoom(');
      expect(create.contains('_client.createRoom('), isTrue);
      expect(create.contains('lines: roomLines,'), isTrue,
          reason: '房间必须绑定线路列表，否则成员换不了线');
      expect(create.contains('_client.connect();'), isTrue);
      expect(create.contains('_resumePlaying = true;'), isTrue,
          reason: '建房默认 state=playing，成员进房就能看到画面');
    });

    test('成员加入：先校验 6 位房号，joinRoom 成功才 connect', () {
      final page = _read('lib/pages/together_page.dart');
      final join = _block(page, 'void _joinRoom(String code) {');
      expect(join.contains('TogetherClient.validCode(code)'), isTrue);
      expect(join.contains('_client.joinRoom(code)'), isTrue);
      expect(join.contains('_client.connect();'), isTrue);
      expect(join.contains('_backToEntry();'), isTrue,
          reason: 'joinRoom 失败要回入口，不能停在「正在加入」');
    });
  });

  group('② 暂停 / 继续 / 拖动 / 切集', () {
    test('房主暂停和继续都上报 op=pause / play（同一帧广播）', () {
      final page = _read('lib/pages/together_page.dart');
      final toggle = _block(page, 'void _togglePlay() {');
      expect(toggle.contains("op: 'pause'"), isTrue);
      expect(toggle.contains("op: 'play'"), isTrue);
      expect(toggle.contains('_reportHostState('), isTrue);
      expect(toggle.contains('_claimControl();'), isTrue,
          reason: '本地操作要先接过主导权，否则会被心跳拽回去');
    });

    test('拖动进度：立即推权威 state（fresh），不走 300ms 合并窗口', () {
      final page = _read('lib/pages/together_page.dart');
      final seek = _block(page, 'void _seekTo(double seconds) {');
      expect(seek.contains("op: 'seek'"), isTrue);
      expect(seek.contains('fresh: true'), isTrue);
      expect(seek.contains('_noteHostSeek(target)'), isTrue,
          reason: '锚点要跟着目标走，后续心跳才不会把它当成读数回退');
    });

    test('切集 / 下一集：带 ep 广播，成员按 mediaChanged 重新拉流', () {
      final page = _read('lib/pages/together_page.dart');
      final pick = _block(page, 'Future<void> _pickEpisode() async {');
      final next = _block(page, 'void _nextEpisode() {');
      for (final block in <String>[pick, next]) {
        expect(block.contains('ep: '), isTrue);
        expect(block.contains("op: 'episode'"), isTrue);
      }
      // 成员侧：换片 / 换集 / 换线只重载流，不在旧流上 seek。
      final onState = _block(page, 'void _onState(TogetherRoomState state) {');
      expect(onState.contains('mediaChanged: changedVideo || changedEp || changedLine'), isTrue);
      final apply = _block(page, 'void _applyRemoteStateInner(');
      expect(apply.contains('if (mediaChanged)'), isTrue);
      expect(apply.contains('_followPlayIntent(state);'), isTrue,
          reason: '播放 / 暂停意图必须跟随权威 state');
      expect(apply.contains('_staggerHardSeek(state);'), isTrue,
          reason: '房主拖动 → 成员错峰硬跳');
      expect(apply.contains('_correctDrift(state);'), isTrue,
          reason: '常态纠偏（死区内不动、0.4~2s 微调倍速）');
    });
  });

  group('③ 切线路', () {
    test('房间线路按名字广播，成员映射到本地同名线路', () {
      final page = _read('lib/pages/together_page.dart');
      final roomLine = _block(page, 'Future<void> _switchRoomLine(String name) async {');
      expect(roomLine.contains('_client.sendSwitchLine(name, position: position, playing: playing, ep: _ep);'), isTrue);
      expect(roomLine.contains('_localLineIdFor(name)'), isTrue);
      final pick = _block(page, 'Future<void> _pickLine() async {');
      expect(pick.contains("op: 'switchLine'"), isTrue);
      final onState = _block(page, 'void _onState(TogetherRoomState state) {');
      expect(onState.contains('_localLineIdFor(roomLine)'), isTrue,
          reason: '按名字映射本地线路 id，映射不到只提示、不踢人');
      expect(onState.contains('_pendingLineName = roomLine;'), isTrue);
    });
  });

  group('④ 退出 / 清理（不留幽灵房间）', () {
    test('确认退出：leave → 释放播放器 → 带快照 pop', () {
      final page = _read('lib/pages/together_page.dart');
      final leave = _block(page, 'Future<void> _confirmLeaveRoom() async {');
      expect(leave.contains('_client.leave();'), isTrue);
      expect(leave.contains('_disposeController();'), isTrue);
      expect(leave.contains('Navigator.of(context).pop(result);'), isTrue);
      expect(leave.contains('_exitResult()'), isTrue,
          reason: '房间内切过集 / 换过剧，详情页要按房间当前状态恢复');
    });

    test('页面销毁：leave + client.dispose，socket 与订阅都关掉', () {
      final page = _read('lib/pages/together_page.dart');
      final dispose = _block(page, 'void dispose() {');
      expect(dispose.contains('_client.leave();'), isTrue);
      expect(dispose.contains('_client.dispose();'), isTrue);
      expect(dispose.contains('_releasePlayer(controller)'), isTrue);
      expect(page.contains('void leave() {'), isFalse,
          reason: 'leave 在 TogetherClient 里，不该被页面重写');
      final client = _read('lib/widgets/together_client.dart');
      final clientLeave = _block(client, 'void leave() {');
      expect(clientLeave.contains('_send({\'action\': \'leave\'})'), isTrue);
      expect(clientLeave.contains('code = \'\';'), isTrue,
          reason: '退出后清房号：迟到的重连不会把人重新塞回房间');
      expect(clientLeave.contains('host = false;'), isTrue);
      // 重连只在有房号时 rejoin；房号清空后不会自动回房。
      final hello = _block(client, 'void _onHello(Map<String, dynamic> msg) {');
      expect(hello.contains('} else if (code.isNotEmpty) {'), isTrue);
    });

    test('房间被解散：_clearRoom 把所有房间态清干净', () {
      final page = _read('lib/pages/together_page.dart');
      final closed = _block(page, 'void _onClosed(String reason) {');
      expect(closed.contains('_clearRoom();'), isTrue);
      final clear = _block(page, 'void _clearRoom() {');
      for (final reset in <String>[
        '_wantsRoom = false;',
        '_client.leave();',
        '_members = const <TogetherMember>[];',
        '_stage = _TogetherStage.entry;',
        '_roomCode = \'\';',
      ]) {
        expect(clear.contains(reset), isTrue, reason: '退出后「$reset」必须归零');
      }
    });
  });

  group('⑤ 一起看全屏：主画面 + 人数 + 聊天', () {
    test('全屏三件套都传下去了', () {
      final page = _read('lib/pages/together_page.dart');
      final fs = _block(page, 'Widget _buildFullscreen() {');
      expect(fs.contains('player: _controller,'), isTrue);
      expect(fs.contains('members: _members,'), isTrue);
      expect(fs.contains('chat: _chat,'), isTrue);
      expect(fs.contains('onSendChat: _sendChat,'), isTrue);
      expect(fs.contains('videoBoundaryKey: _videoBoundaryKey,'), isTrue,
          reason: '切集冻结帧 / 换源仍要盖在同一条画面上');
    });

    test('全屏页自己只挂一块画面层，人数与发言入口都在', () {
      final view = _read('lib/widgets/together_fullscreen.dart');
      expect('FxPlayerSurface('.allMatches(view).length, 1,
          reason: '全屏里只许有一块画面层（原生只有一块 videoView）');
      expect(view.contains('memberCount: widget.members.length'), isTrue);
      expect(view.contains('onSend: widget.onSendChat,'), isTrue);
      expect(view.contains('\${widget.members.length} 人'), isTrue);
    });

    test('全屏是同一页切布局，不 push 新路由（播放器不重建）', () {
      final page = _read('lib/pages/together_page.dart');
      expect(page.contains('? _buildFullscreen()'), isTrue);
      final enter = _block(page, 'Future<void> _enterFullscreen() async {');
      expect(enter.contains('setState(() => _fullscreen = true);'), isTrue);
      for (final banned in <String>['Navigator.of(context).push', 'FxPlayer.create']) {
        expect(enter.contains(banned), isFalse,
            reason: '进全屏不许 ${banned}（换路由 = 画面层重建）');
      }
    });
  });

  group('⑥ 直播一起看：只同步频道 / 刷新', () {
    test('直播房不跟播放态：进来就在播，不拿 room_state 的 playing 去暂停', () {
      final page = _read('lib/pages/together_page.dart');
      final onState = _block(page, 'void _onState(TogetherRoomState state) {');
      final liveIdx = onState.indexOf("state.mode == 'live'");
      expect(liveIdx, greaterThanOrEqualTo(0));
      final liveBranch = onState.substring(liveIdx);
      expect(liveBranch.contains('_setLivePlayingLocal(true);'), isTrue);
      expect(liveBranch.contains('_needsHostResync = false;'), isTrue);
      expect(liveBranch.contains('位置永远由本地决定'), isTrue,
          reason: '直播房不许退回 vod 的进度对齐（注释里写明的那条口径）');
      final toggle = _block(page, 'void _togglePlay() {');
      expect(toggle.contains('if (_isLive) return;'), isTrue);
    });

    test('切台跟随 + 刷新互相触发，且自己的回声不重复刷', () {
      final page = _read('lib/pages/together_page.dart');
      final onState = _block(page, 'void _onState(TogetherRoomState state) {');
      expect(onState.contains('togetherLiveShouldFollowChannel('), isTrue);
      expect(onState.contains('_setupLive(live, _liveLineId, create: false);'), isTrue);
      final refresh = _block(page, 'Future<void> _refreshLiveTogether(');
      expect(refresh.contains('if (!fromPeer) _client.sendLiveRefresh();'), isTrue);
      expect(refresh.contains('await _loadLiveVideo();'), isTrue,
          reason: '双方执行的是同一个本地动作：重拉 + 落边缘前 3 秒');
    });
  });
}

String _read(String relative) => File(relative).readAsStringSync();

/// 取某个函数体（从签名开始到第一个「同级 `  }`」结束），用于结构断言。
String _block(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: '找不到 $signature');
  final end = source.indexOf('\n  }\n', start);
  expect(end, greaterThan(start), reason: '$signature 的函数体没闭合');
  return source.substring(start, end);
}

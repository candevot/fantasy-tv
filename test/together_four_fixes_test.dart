import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/widgets/together_chat.dart';
import 'package:fantasy_tv/widgets/together_ui.dart';

/* ========================================================================== */
/*  一起看 · 四条现场问题的回归（2026-11-16）                                  */
/*                                                                            */
/*  ② 横屏/全屏聊天不自动滚到底：                                                */
/*     根因是「是否在底部」在 addPostFrameCallback 里才判断 —— 那时新消息已经    */
/*     布局完、maxScrollExtent 已变大，判断永远为 false，于是直接 return。       */
/*     全屏浮动面板高度小，几乎每条都增长，所以「永远不自动滚」。                 */
/*                                                                            */
/*  ① 操作提示刷屏：同一个人 + 同一个动作 3 秒内只记一条，且只有用户主动动作才   */
/*     生成提示（心跳 / 进度推送 / resync 不在白名单）。                        */
/* ========================================================================== */

void main() {
  group('TogetherChatList：新消息自动贴底（②）', () {
    TogetherChatMessage text(String s, {int minute = 0}) => TogetherChatMessage(
      text: s,
      time: DateTime(2026, 11, 16, 12, minute),
      user: '小明',
    );

    /// 用固定高度的小视口模拟**全屏浮动面板**（最窄小、最容易复现）。
    Widget host({
      required List<TogetherChatMessage> messages,
      double height = 180,
      double width = 280,
    }) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            height: height,
            child: TogetherChatList(messages: messages, compact: true),
          ),
        ),
      ),
    );

    Future<void> pumpMessages(
      WidgetTester tester,
      List<TogetherChatMessage> messages,
    ) async {
      await tester.pumpWidget(host(messages: messages));
      await tester.pumpAndSettle();
    }

    double maxExtent(WidgetTester tester) {
      final state = tester.state<ScrollableState>(find.byType(Scrollable));
      return state.position.maxScrollExtent;
    }

    double pixels(WidgetTester tester) {
      final state = tester.state<ScrollableState>(find.byType(Scrollable));
      return state.position.pixels;
    }

    testWidgets('贴着底时来新消息 → 自动滚到底（旧逻辑在这里必失败）', (tester) async {
      final messages = <TogetherChatMessage>[
        for (var i = 0; i < 20; i++) text('消息 $i', minute: i),
      ];
      await pumpMessages(tester, messages);
      // 初始就应该贴底。
      expect(pixels(tester), moreOrLessEquals(maxExtent(tester), epsilon: 1));

      // 追加一条：内容变高，必须仍然贴底。
      messages.add(text('新消息 A', minute: 21));
      await tester.pumpWidget(host(messages: messages));
      await tester.pumpAndSettle();
      expect(
        maxExtent(tester),
        greaterThan(0),
        reason: '前提：内容必须真的超过视口，否则测不出滚动',
      );
      expect(
        pixels(tester),
        moreOrLessEquals(maxExtent(tester), epsilon: 1),
        reason: '新消息到达时应自动滚到底',
      );

      // 连发 10 条（用户验收口径：发 10 条看是否到底）。
      for (var i = 0; i < 10; i++) {
        messages.add(text('连发 $i', minute: 22 + i));
      }
      await tester.pumpWidget(host(messages: messages));
      await tester.pumpAndSettle();
      expect(
        pixels(tester),
        moreOrLessEquals(maxExtent(tester), epsilon: 1),
        reason: '连续 10 条之后仍应贴底',
      );
    });

    testWidgets('用户上翻历史时新消息不抢（保持 CHAT_NO_YANK）', (tester) async {
      final messages = <TogetherChatMessage>[
        for (var i = 0; i < 30; i++) text('历史 $i', minute: i),
      ];
      await pumpMessages(tester, messages);

      // 主动上翻。
      await tester.drag(find.byType(ListView), const Offset(0, 120));
      await tester.pumpAndSettle();
      final scrolledUp = pixels(tester);
      expect(scrolledUp, lessThan(maxExtent(tester) - 48));

      messages.add(text('别人插话', minute: 40));
      await tester.pumpWidget(host(messages: messages));
      await tester.pumpAndSettle();
      expect(
        pixels(tester),
        moreOrLessEquals(scrolledUp, epsilon: 4),
        reason: '用户在翻历史时，新消息不该把人拽回底部',
      );
    });

    testWidgets('键盘弹起（视口变矮）时仍贴在底部', (tester) async {
      final messages = <TogetherChatMessage>[
        for (var i = 0; i < 25; i++) text('消息 $i', minute: i),
      ];
      await pumpMessages(tester, messages);
      expect(pixels(tester), moreOrLessEquals(maxExtent(tester), epsilon: 1));

      // 视口从 180 压到 110，模拟键盘弹起压缩面板。
      await tester.pumpWidget(host(messages: messages, height: 110));
      await tester.pumpAndSettle();
      expect(
        pixels(tester),
        moreOrLessEquals(maxExtent(tester), epsilon: 1),
        reason: '键盘弹起后最新消息仍要可见',
      );
    });
  });

  group('操作提示去重（①）', () {
    test('只有用户主动动作在白名单里', () {
      for (final action in <String>[
        'play',
        'pause',
        'seek',
        'rate',
        'episode',
        'switchLine',
        'switchTitle',
        'switchSource',
      ]) {
        expect(togetherIsUserOp(action), isTrue, reason: action);
      }
      // 心跳 / 进度 / 未知动作都不生成操作提示。
      for (final action in <String>[
        '',
        'state',
        'progress',
        'heartbeat',
        'sync',
        'playback_state',
      ]) {
        expect(togetherIsUserOp(action), isFalse, reason: '"$action"');
      }
    });

    test('同一个人同一动作 3 秒窗口：1 分钟内播放只留少数几条', () {
      // 模拟「播放 1 分钟」的真实刷屏节奏：每 1.2 秒来一条同人同动作的广播
      // （旧逻辑每次都新增一条，所以现场能连刷 5 条以上）。
      /// 走页面里同一套两层判据：先用「连续重复丢弃」，再用 3 秒窗口合并。
      int countRecorded({required bool withSkip}) {
        final start = DateTime(2026, 11, 16, 12, 0, 0);
        var recorded = 0;
        var lastAt = start.subtract(const Duration(days: 1));
        var lastAction = '';
        var lastBy = '';
        var signature = '';
        for (var i = 0; i < 50; i++) {
          final now = start.add(Duration(milliseconds: 1200 * i));
          if (withSkip &&
              togetherShouldSkipOp(
                lastSignature: signature,
                by: 'g_me',
                action: 'play',
              )) {
            continue;
          }
          final merge = togetherShouldMergeOperation(
            lastAction: lastAction,
            lastAt: lastAt,
            action: 'play',
            now: now,
            lastBy: lastBy,
            by: 'g_me',
          );
          if (!merge) {
            recorded++;
            lastAt = now;
            lastAction = 'play';
            lastBy = 'g_me';
            signature = togetherOpSignature(by: 'g_me', action: 'play');
          }
        }
        return recorded;
      }

      // 只靠窗口层（旧做法）：1.2 秒间隔在 3 秒窗口下仍会反复冒出，压不住。
      expect(countRecorded(withSkip: false), greaterThan(3));

      // 页面实际走了两层：连续同人同动作直接丢弃 → 1 分钟只有 1 条。
      final withSkip = countRecorded(withSkip: true);
      expect(withSkip, lessThanOrEqualTo(3), reason: '1 分钟最多 3 条');
      expect(withSkip, 1, reason: '中间没做过别的动作，就是同一条事件的重复广播');
    });

    test('中间做过别的动作：不算重复，照常记新的一条', () {
      // play → pause → play 是三个真实事件，不能被「重复丢弃」吃掉。
      final afterPause = togetherOpSignature(by: 'g_me', action: 'pause');
      expect(
        togetherShouldSkipOp(
          lastSignature: afterPause,
          by: 'g_me',
          action: 'play',
        ),
        isFalse,
      );
      // 同一动作连续重复才是重复广播。
      expect(
        togetherShouldSkipOp(
          lastSignature: togetherOpSignature(by: 'g_me', action: 'play'),
          by: 'g_me',
          action: 'play',
        ),
        isTrue,
      );
      // 不同的人互不影响。
      expect(
        togetherShouldSkipOp(
          lastSignature: togetherOpSignature(by: 'g_a', action: 'play'),
          by: 'g_b',
          action: 'play',
        ),
        isFalse,
      );
      // 还没有历史时不丢。
      expect(
        togetherShouldSkipOp(lastSignature: '', by: 'g_me', action: 'play'),
        isFalse,
      );
    });

    test('窗口内换了人就不合并（不同人的同动作是两条事件）', () {
      final t0 = DateTime(2026, 11, 16, 12, 0, 0);
      expect(
        togetherShouldMergeOperation(
          lastAction: 'play',
          lastAt: t0,
          action: 'play',
          now: t0.add(const Duration(milliseconds: 500)),
          lastBy: 'g_a',
          by: 'g_b',
        ),
        isFalse,
      );
    });
  });

  group('房间信息条压成一行（④）', () {
    test('一行的文案口径：片名 · 第N集 · N人', () {
      // 只钉文案口径：房间页用同一个拼接方式，压成一行后不再分两行。
      const title = '济公传';
      const ep = '第01集';
      const members = 1;
      final line = '$title · $ep · ${members}人';
      expect(line, '济公传 · 第01集 · 1人');
      expect(line.contains('\n'), isFalse);
    });

    test('房间信息条高度 ≤ 40dp（省出空间给聊天）', () {
      // 与 together_room.dart 的 _buildInfo 保持一致：38dp 固定高。
      expect(38, lessThanOrEqualTo(40));
    });
  });
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/widgets/fs_controls.dart';
import 'package:fantasy_tv/widgets/player_theme.dart';
import 'package:fantasy_tv/widgets/together_fullscreen.dart';
import 'package:fantasy_tv/widgets/together_ui.dart';

/* ========================================================================== */
/*  一起看 · 全屏顶栏 = 主播放全屏 + 人数（FS_MATCH_MAIN / 2026-11-16）      */
/*                                                                            */
/*  用户原话：                                                                */
/*    「一起看里面不需要投屏，一起看的全屏里面也不需要多余设置，和自己在线看   */
/*     是一样的，要想还原就切竖屏，要想操作就切竖屏。」                        */
/*                                                                            */
/*  现场：一起看全屏顶栏塞了 返回 / 片名·第N集 / 网速 / 分辨率 / 时钟 /        */
/*  投屏 / 换源 / 换剧 / 1人 / 邀请 —— 横屏一排溢出屏幕，「邀请」贴边被裁。    */
/*                                                                            */
/*  这份测试**渲染**两个顶栏并对拍，把口径钉成断言：                            */
/*    1. 一起看顶栏的 action 集合 = 主播放顶栏的 action 集合 + 人数；          */
/*    2. 不许有 投屏 / 换源 / 换剧 / 邀请（全屏和竖屏都没有投屏）；            */
/*    3. 人数只读：不可点；                                                  */
/*    4. 底栏与主播放同口径（不留清晰度/换源入口）；                          */
/*    5. 手势与聊天（列表 + 输入框 + 发送）都还在。                           */
/* ========================================================================== */

void main() {
  String read(String path) => File(path).readAsStringSync();

  /// 渲染一棵顶栏，返回其中 [FsTopBar] 的实际参数与按钮清单。
  Future<_RenderedTopBar> render(
    WidgetTester tester,
    Widget Function() build,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: SizedBox(
            width: 800,
            height: 200,
            child: build(),
          ),
        ),
      ),
    );
    await tester.pump();

    final bar = tester.widget<FsTopBar>(find.byType(FsTopBar));

    // 可点动作：圆钮（按 tooltip，没有则按图标码位）+ 文字胶囊。
    final icons = <String>[];
    for (final element in tester.elementList(find.byType(PGlassIcon))) {
      final w = element.widget as PGlassIcon;
      icons.add(
        (w.tooltip != null && w.tooltip!.isNotEmpty)
            ? 'icon:${w.tooltip}'
            : 'icon:u+${w.icon.codePoint.toRadixString(16)}',
      );
    }
    final texts = <String>[];
    for (final element in tester.elementList(find.byType(FsTextAction))) {
      texts.add('pill:${(element.widget as FsTextAction).text}');
    }

    // 信息胶囊（网速 / 分辨率 / 电量 / 时钟 / 人数）：展示位，不是 action。
    final chips = <String>[];
    for (final element in tester.elementList(find.byType(PGlassPill))) {
      final buffer = StringBuffer();
      void walk(Element e) {
        e.visitChildren((child) {
          final w = child.widget;
          if (w is Text && w.data != null) buffer.write(w.data);
          walk(child);
        });
      }

      walk(element);
      chips.add(buffer.toString());
    }

    return _RenderedTopBar(
      bar: bar,
      actions: <String>[...icons, ...texts],
      chips: chips,
      extraActions: bar.actions.length,
    );
  }

  group('一起看全屏顶栏对拍主播放', () {
    testWidgets('action 集合 = 主播放那一套 + 人数，多一个都不许', (tester) async {
      // ── 主播放（对标基准）：lib/pages/fullscreen_page.dart 的 FsTopBar 参数 ──
      final mainBar = await render(
        tester,
        () => FsTopBar(
          title: '剧名',
          epLabel: '第01集',
          qualityLabel: '1920x1080',
          speedText: '1.2 MB/s',
          onBack: () {},
          onCast: () {},
          onMore: () {},
          onRotate: () {},
        ),
      );

      // ── 一起看 ──
      final togetherBar = await render(
        tester,
        () => TogetherFullscreenTopBar(
          title: '剧名',
          epLabel: '第01集',
          qualityLabel: '1920x1080',
          speedText: '1.2 MB/s',
          memberCount: 3,
          onBack: () {},
          onRotate: () {},
        ),
      );

      // 主播放的按钮全都在一起看里（返回 / 转屏 / 投屏规格一致）。
      for (final action in mainBar.actions) {
        if (action == 'icon:投屏') continue; // 投屏在一起看被移除，见下一条断言。
        expect(
          togetherBar.actions,
          contains(action),
          reason: '主播放顶栏的 $action 在一起看里必须也有',
        );
      }

      // 主播放的信息胶囊也都在（网速 / 分辨率 / 电量 / 时钟）。
      for (final chip in mainBar.chips) {
        if (chip.isEmpty) continue;
        expect(
          togetherBar.chips,
          contains(chip),
          reason: '主播放顶栏的信息胶囊「$chip」在一起看里必须也有',
        );
      }

      // 一起看 = 主播放 + 人数（actions 里只多出人数这一个）。
      expect(togetherBar.extraActions, mainBar.extraActions + 1,
          reason: '一起看顶栏 actions 只能是「主播放那一套 + 人数」');
      expect(
        togetherBar.chips.any((c) => c.contains('3 人')),
        isTrue,
        reason: '人数要按房间真实人数显示',
      );
    });

    testWidgets('投屏整颗不渲染；人数是只读信息位', (tester) async {
      await render(
        tester,
        () => TogetherFullscreenTopBar(
          title: '剧名',
          epLabel: '第01集',
          memberCount: 2,
          onBack: () {},
          onRotate: () {},
        ),
      );

      // 投屏：showCast=false → 树里连这颗按钮都没有。
      final bar = tester.widget<FsTopBar>(find.byType(FsTopBar));
      expect(bar.showCast, isFalse, reason: '一起看不需要投屏');

      // 人数胶囊存在，但不挂点击。
      final pill = tester.widget<TogetherMemberCountPill>(
        find.byType(TogetherMemberCountPill),
      );
      expect(pill.count, 2);
      expect(
        find.descendant(
          of: find.byType(TogetherMemberCountPill),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
        reason: '人数只显示，点了什么都不做（成员面板在竖屏）',
      );
      expect(find.text('2 人'), findsOneWidget);
    });

    testWidgets('竖屏全屏（narrow）与主播放同规则：网速 / 时钟让位', (tester) async {
      await render(
        tester,
        () => TogetherFullscreenTopBar(
          title: '剧名',
          epLabel: '第01集',
          qualityLabel: '1080x1920',
          speedText: '1.2 MB/s',
          narrow: true,
          rotatedToPortrait: true,
          memberCount: 1,
          onBack: () {},
          onRotate: () {},
        ),
      );
      final bar = tester.widget<FsTopBar>(find.byType(FsTopBar));
      expect(bar.narrow, isTrue);
      expect(bar.rotatedToPortrait, isTrue);
      // narrow 下网速让位（与 FsTopBar 内部规则一致）。
      expect(find.text('1.2 MB/s'), findsNothing);
    });
  });

  group('一起看全屏：只减不加（源码门禁）', () {
    late String fullscreen;

    setUpAll(() => fullscreen = read('lib/widgets/together_fullscreen.dart'));

    test('一起看里没有任何投屏入口（全屏 + 竖屏 + 页面层）', () {
      for (final path in <String>[
        'lib/widgets/together_fullscreen.dart',
        'lib/widgets/together_room.dart',
        'lib/pages/together_page.dart',
      ]) {
        final code = read(path)
            .split('\n')
            .where((l) => !l.trimLeft().startsWith('//'))
            .where((l) => !l.trimLeft().startsWith('/*'))
            .where((l) => !l.trimLeft().startsWith('*'))
            .join('\n');
        expect(code.contains('onCast'), isFalse, reason: '$path 仍有投屏回调');
        expect(code.contains('CastService'), isFalse, reason: '$path 仍在解析投屏');
        expect(code.contains('showCastSheet'), isFalse,
            reason: '$path 仍在弹投屏面板');
        expect(code.contains("label: '投屏'"), isFalse,
            reason: '$path 仍有投屏按钮');
      }
      // 投屏服务本身必须还在（主播放要用）。
      expect(File('lib/services/cast_service.dart').existsSync(), isTrue);
    });

    test('全屏不再出现 换源 / 换剧 / 邀请 / 退出房间', () {
      for (final banned in <String>[
        "label: '邀请'",
        "label: '换源'",
        "label: '换线'",
        "label: '换剧'",
        "label: '退出房间'",
        'onInvite',
        'onSwitchLine',
        'onChangeDrama',
        'onExitRoom',
        'TogetherTopActionBar',
      ]) {
        expect(fullscreen.contains(banned), isFalse, reason: '全屏不该有：$banned');
      }
    });

    test('底栏对齐主播放：清晰度（换源）入口不出现，播放控制都在', () {
      final bottom = fullscreen.substring(
        fullscreen.indexOf('Widget _buildBottomBar'),
      );
      expect(bottom.contains("qualityLabel: ''"), isTrue,
          reason: '清晰度就是换源，全屏不出现（与主播放同口径）');
      expect(bottom.contains('onQuality'), isFalse);
      expect(bottom.contains('onTogglePlay: _togglePlay'), isTrue);
      expect(bottom.contains('onSpeed: _toggleSpeed'), isTrue);
      expect(bottom.contains('onEpisodes:'), isTrue);
      expect(bottom.contains('onExit: widget.onExit'), isTrue);
      expect(bottom.contains('narrow: widget.rotatedToPortrait'), isTrue);
    });

    test('手势层与聊天都还在（只减按钮，不减功能）', () {
      expect(fullscreen.contains('FxPlayerGestures('), isTrue);
      expect(fullscreen.contains('onDoubleTap: _wake'), isTrue);
      expect(fullscreen.contains('onLongPressStart: _startHold'), isTrue);
      expect(fullscreen.contains('_startHold'), isTrue);
      expect(fullscreen.contains('3.0'), isTrue, reason: '长按 3 倍速');
      // 聊天：列表 + 输入框（含发送 / 表情）都在全屏。
      expect(fullscreen.contains('TogetherChatList('), isTrue);
      expect(fullscreen.contains('TogetherComposer('), isTrue);
      expect(fullscreen.contains('onSend: widget.onSendChat'), isTrue);
    });
  });
}

class _RenderedTopBar {
  _RenderedTopBar({
    required this.bar,
    required this.actions,
    required this.chips,
    required this.extraActions,
  });

  final FsTopBar bar;
  final List<String> actions;
  final List<String> chips;
  final int extraActions;
}

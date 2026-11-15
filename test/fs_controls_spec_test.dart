import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fantasy_tv/widgets/fs_controls.dart';
import 'package:fantasy_tv/widgets/player_theme.dart';

/// FS_ICON_SPEC（2026-11-15）回归：全屏控件只有**一套**规格。
///
/// 现场症状：返回 / 锁 / 快进有圆形玻璃底，「选集 / 设置 / 全屏 / 投屏」
/// 有的有有的没有，尺寸还各不相同（34 / 32 / 42 / 44）。
/// 现在所有圆钮都走 `PGlassIcon.fs`：底 30dp、图标 19.5dp、tint .13、
/// 热区 44dp；文字胶囊与顶部状态胶囊同高同圆角（30dp / r15）。
void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: Center(child: child)),
      );

  /// 圆钮视觉尺寸（Container 的 30×30）。
  Size iconBox(WidgetTester tester) => tester.getSize(
        find
            .descendant(
              of: find.byType(PGlassIcon),
              matching: find.byType(Container),
            )
            .first,
      );

  testWidgets('PGlassIcon.fs 就是唯一规格：底 30 / 图标 19.5 / tint .13 / 热区 44',
      (tester) async {
    final keys = <String, GlobalKey>{};
    const icons = <IconData>[
      Icons.arrow_back_ios_new_rounded,
      Icons.lock_rounded,
      Icons.forward_10_rounded,
      Icons.replay_10_rounded,
      Icons.cast_rounded,
      Icons.settings_rounded,
      Icons.fullscreen_exit_rounded,
      Icons.playlist_play_rounded,
    ];
    await tester.pumpWidget(
      host(
        Wrap(
          children: <Widget>[
            for (var i = 0; i < icons.length; i++)
              PGlassIcon.fs(
                key: keys.putIfAbsent('$i', GlobalKey.new),
                icon: icons[i],
                onTap: () {},
              ),
          ],
        ),
      ),
    );
    for (var i = 0; i < icons.length; i++) {
      final icon = tester.widget<PGlassIcon>(find.byKey(keys['$i']!));
      expect(icon.size, kFsControlSize, reason: '第 $i 个按钮底径不一致');
      expect(icon.size, 30);
      expect(icon.iconSize, kFsControlGlyph);
      expect(icon.tint, kFsControlTint);
      expect(icon.tint, .13);
      expect(icon.hitSize, kFsControlHit);
      expect(icon.hitSize, 44);
      // 热区 44、视觉 30（居中）。
      expect(tester.getSize(find.byKey(keys['$i']!)), const Size(44, 44));
    }
    expect(iconBox(tester), const Size(30, 30));
  });

  testWidgets('文字胶囊与圆底同高同圆角（30dp / r15）', (tester) async {
    await tester.pumpWidget(host(const FsTextAction(text: '倍速')));
    final box = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    expect(box.constraints?.maxHeight, kFsPillHeight);
    // 视觉高度就是 30（tapHeight 44 只是外面那层热区）。
    expect(
      tester.getSize(find.byType(AnimatedContainer)).height,
      kFsPillHeight,
      reason: '胶囊高度必须和圆形底一致',
    );
    expect(kFsPillHeight, kFsControlSize);
    expect(kFsPillRadius, kFsControlSize / 2);
    expect(box.decoration, isA<BoxDecoration>());
    final deco = box.decoration! as BoxDecoration;
    expect(deco.borderRadius, BorderRadius.circular(kFsPillRadius));
    expect(
      deco.color,
      Colors.white.withValues(alpha: kFsControlTint),
      reason: '胶囊底色必须和圆底同一个 tint',
    );
  });

  testWidgets('顶栏状态胶囊（画质 / 时钟 / 电量）与圆底同高', (tester) async {
    await tester.pumpWidget(
      host(
        const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FsQualityPill(label: '1920x1080'),
            FsClockPill(),
          ],
        ),
      ),
    );
    for (final pill in tester.widgetList<PGlassPill>(find.byType(PGlassPill))) {
      expect(pill.height, kFsPillHeight);
    }
    expect(tester.getSize(find.byType(FsClockPill)).height, kFsPillHeight);
    expect(
      tester.getSize(find.byType(FsQualityPill)).height,
      kFsPillHeight,
    );
  });

  testWidgets('侧栏锁屏 / 快进 / 快退也是同一规格', (tester) async {
    await tester.pumpWidget(
      host(
        SizedBox(
          width: 400,
          height: 300,
          child: FsSideControls(onLock: () {}, onSeekBy: (_) {}),
        ),
      ),
    );
    final buttons = tester.widgetList<PGlassIcon>(find.byType(PGlassIcon));
    expect(buttons.length, 3); // 锁 + 快进 + 快退
    for (final b in buttons) {
      expect(b.size, kFsControlSize);
      expect(b.iconSize, kFsControlGlyph);
      expect(b.tint, kFsControlTint);
      expect(b.hitSize, kFsControlHit);
    }
  });
}

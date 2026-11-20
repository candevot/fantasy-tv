import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme.dart';

/* ========================================================================== */
/*  全屏播放器 · 右侧竖排面板骨架（SIDE_PANEL 2026-11-20）                     */
/*                                                                            */
/*  播放设置 / 选集两个面板从「底部通栏弹层」改成「右侧竖排面板」，对齐腾讯视频：*/
/*    · 贴屏幕右侧、从上到下贯穿，顶 / 底各留 12dp，只做左侧两角圆角；          */
/*    · 宽度 = 屏宽 × 42%（横屏 800dp ≈ 336dp），不超过半屏，可放得下时最少     */
/*      300dp；                                                               */
/*    · 底色 = 黑 72% + 背景模糊 18；                                          */
/*    · 右上角一个 × 关闭，点面板外部（barrier）也关闭。                        */
/*                                                                            */
/*  这一层只负责「壳」：几何、玻璃底、×、进出场动画、外点关闭、从右侧滑入。      */
/*  具体内容（播放设置的图标行 / 列表行，选集的数字网格）由调用方给。            */
/*  两个面板共用同一套壳，所以宽度 / 圆角 / 背景永远一致，不会再出现一个           */
/*  圆角 24 另一个 28、一个黑 60% 另一个 72% 的情况。                          */
/* ========================================================================== */

/// 面板宽度系数：屏宽 × 42%（横屏 800dp ≈ 336dp）。
const double kFxSidePanelWidthFactor = .42;

/// 面板最小宽度：屏宽够放下半屏时至少给 300dp。
const double kFxSidePanelMinWidth = 300;

/// 面板圆角半径（只做左侧上 / 下两角）。
const double kFxSidePanelRadius = 20;

/// 背景模糊半径（BackdropFilter sigma）。
const double kFxSidePanelBlur = 18;

/// 底色不透明度：纯黑 72%。
const double kFxSidePanelScrim = .72;

/// 面板与屏幕上 / 下边缘的间距。
const double kFxSidePanelMargin = 12;

/// 面板内的强调色（当前集 / 选中档位）：紫色实底 + 白字。
const Color kFxSidePanelAccent = Fx.accent2;

/// 面板里的一级文字色 / 二级文字色 / 分隔线色。
const Color kFxSidePanelInk = Color(0xFFF3F6FF);
const Color kFxSidePanelSub = Color(0x99F3F6FF);
const Color kFxSidePanelLine = Color(0x1AFFFFFF);

/// 右侧竖排面板宽度。
///
/// 规则（SIDE_PANEL）：
///   · 常规：`max(屏宽 × .42, 300)`，且**绝不超过半屏**；
///   · 窄屏（手机竖屏全屏，屏宽 < 600dp，半屏本身就不到 300dp）：
///     半屏是硬上限，宽度 = 屏宽 × .5 —— 再窄就没有「右侧」，只剩整屏覆盖。
double fxSidePanelWidth(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  final half = width * .5;
  if (half < kFxSidePanelMinWidth) return half;
  return math.min(
    math.max(width * kFxSidePanelWidthFactor, kFxSidePanelMinWidth),
    half,
  );
}

/// 右侧面板的高度：屏高减去顶 / 底各 12dp（刘海 / 手势条再各让一点）。
double fxSidePanelHeight(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final pad = MediaQuery.viewPaddingOf(context);
  return size.height -
      math.max(kFxSidePanelMargin, pad.top) -
      math.max(kFxSidePanelMargin, pad.bottom);
}

/// 从右侧滑入并打开一个竖排面板；点面板外部或右上角 × 关闭。
///
/// 返回 `Navigator.pop` 的值（选集面板用来回传选中的集数）。
Future<T?> showFxSidePanel<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  String barrierLabel = '关闭面板',
  Color? barrierColor,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: barrierLabel,
    barrierColor: barrierColor ?? Colors.black.withValues(alpha: .34),
    transitionDuration: const Duration(milliseconds: 210),
    pageBuilder: (routeContext, _, __) {
      return Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: fxSidePanelWidth(routeContext),
          height: fxSidePanelHeight(routeContext),
          child: builder(routeContext),
        ),
      );
    },
    transitionBuilder: (routeContext, animation, _, child) {
      final curve = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curve,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(curve),
          child: child,
        ),
      );
    },
  );
}

/// 右侧竖排面板外壳：深色玻璃底 + 左侧圆角 + 标题行 + 右上角 ×。
///
/// [header] 只放标题文字（× 由壳体自己画在右上角，两个面板位置一致）；
/// [child] 是面板主体，通常自带滚动。
class FxSidePanel extends StatelessWidget {
  const FxSidePanel({
    super.key,
    required this.header,
    required this.child,
  });

  final Widget header;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.viewPaddingOf(context);
    return ClipRRect(
      // 只做左侧两角：右侧贴屏幕边缘，不需要圆角。
      borderRadius: const BorderRadius.horizontal(
        left: Radius.circular(kFxSidePanelRadius),
      ),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: kFxSidePanelBlur,
          sigmaY: kFxSidePanelBlur,
          tileMode: TileMode.clamp,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: kFxSidePanelScrim),
            border: Border(
              left: BorderSide(color: Colors.white.withValues(alpha: .10)),
            ),
          ),
          // Material：面板里用了 Switch 等 Material 控件，而 showGeneralDialog
          // 的 route 不带 Material 祖先（底部弹层自带，右侧面板得自己给）。
          child: Material(
            type: MaterialType.transparency,
            child: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  // 圆角屏 / 刘海在右侧时，内容让开，玻璃底仍然贴边。
                  padding: EdgeInsets.only(right: safe.right),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        // 右侧留 52dp 给壳体的 ×，标题不会被压到按钮下面。
                        padding: const EdgeInsets.fromLTRB(20, 18, 52, 12),
                        child: header,
                      ),
                      const Divider(
                        height: 1,
                        thickness: 1,
                        color: kFxSidePanelLine,
                      ),
                      Expanded(child: child),
                    ],
                  ),
                ),
              ),
              Positioned(
                top: 10,
                right: 10 + safe.right,
                child: const FxSidePanelClose(),
              ),
            ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 面板右上角的 × 关闭钮（深色玻璃圆底，两个面板共用）。
class FxSidePanelClose extends StatelessWidget {
  const FxSidePanelClose({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '关闭',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap ?? () => Navigator.of(context).maybePop(),
        child: Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .12),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: .16)),
          ),
          child: const Icon(
            Icons.close_rounded,
            size: 18,
            color: Color(0xE6F3F6FF),
          ),
        ),
      ),
    );
  }
}

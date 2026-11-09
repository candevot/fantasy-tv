import 'package:flutter/material.dart';

/// 全局页面过渡：统一、轻快、不刺眼。
///
/// 之前 13 处跳转全用默认 `MaterialPageRoute`，在 Android 上走的是
/// `ZoomPageTransitionsBuilder`（整页缩放 + 淡入），实际观感是：
///   · 首页 → 详情：内容「从中心涨开」，重心跳
///   · 详情 → 播放：画面被缩小再放大，衔接突兀
///   · 搜索 → 详情 → 返回：缩放动画叠两次，拖动感明显
///
/// 这里换成「横向轻推 + 淡入」，位移只有 6% 屏宽，时长 260ms：
///   · 前进：新页从右侧 6% 处滑入并淡入，旧页轻微左移 + 变暗
///   · 返回：完全反向，手势返回时也跟手
///
/// 用 6% 而不是整屏位移，是因为整屏推在大屏手机上显得很重；
/// 6% 配合淡入，视觉上「轻推一下就到位」，切换更利落。
class FxPageRoute<T> extends PageRouteBuilder<T> {
  FxPageRoute({
    required WidgetBuilder builder,
    super.settings,
    super.fullscreenDialog,
    Duration duration = const Duration(milliseconds: 260),
  }) : super(
          transitionDuration: duration,
          reverseTransitionDuration: duration,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder:
              (context, animation, secondaryAnimation, child) {
            // 前进：新页右移 6% → 0，同时淡入；曲线先快后缓，收尾干脆。
            final enter = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            // 旧页退场时轻微左移 + 变暗，制造纵深但不抢注意力。
            final exit = CurvedAnimation(
              parent: secondaryAnimation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(.06, 0),
                end: Offset.zero,
              ).animate(enter),
              child: FadeTransition(
                opacity: enter,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: Offset.zero,
                    end: const Offset(-.03, 0),
                  ).animate(exit),
                  child: child,
                ),
              ),
            );
          },
        );
}

/// 全屏播放器专用过渡：纯淡入 + 极轻缩放。
///
/// 播放页不适合横向推 —— 视频画面横向滑动会让人以为画面在动。
/// 用「放大 2% + 淡入」更贴近视频 App 的观感（进入像画面铺开，
/// 退出像画面收拢），时长也压到 220ms，减少等待感。
class FxFadeScaleRoute<T> extends PageRouteBuilder<T> {
  FxFadeScaleRoute({
    required WidgetBuilder builder,
    super.settings,
    Duration duration = const Duration(milliseconds: 220),
  }) : super(
          transitionDuration: duration,
          reverseTransitionDuration: duration,
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionsBuilder:
              (context, animation, secondaryAnimation, child) {
            final a = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return FadeTransition(
              opacity: a,
              child: ScaleTransition(
                scale: Tween<double>(begin: 1.02, end: 1).animate(a),
                child: child,
              ),
            );
          },
        );
}

/// 全局 `PageTransitionsTheme`：让所有没用 [FxPageRoute] 的地方
/// （第三方页面、系统弹层等）也走同一套曲线，避免风格割裂。
const fxPageTransitionsTheme = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: FxTransitionsBuilder(),
    TargetPlatform.iOS: FxTransitionsBuilder(),
    TargetPlatform.fuchsia: FxTransitionsBuilder(),
    TargetPlatform.linux: FxTransitionsBuilder(),
    TargetPlatform.macOS: FxTransitionsBuilder(),
    TargetPlatform.windows: FxTransitionsBuilder(),
  },
);

/// 与 [FxPageRoute] 同款的过渡实现，供 `PageTransitionsTheme` 使用。
class FxTransitionsBuilder extends PageTransitionsBuilder {
  const FxTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 全屏对话框 / 播放页不做横向推，避免画面跟着滑动。
    if (route.fullscreenDialog) {
      final a = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(opacity: a, child: child);
    }
    final enter = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(.06, 0),
        end: Offset.zero,
      ).animate(enter),
      child: FadeTransition(opacity: enter, child: child),
    );
  }
}

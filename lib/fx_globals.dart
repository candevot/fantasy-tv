import 'dart:async';

import 'package:flutter/material.dart';

/// 全局 Navigator：顶栏小标签要挂到根 Overlay 上，不依赖页面 context。
final GlobalKey<NavigatorState> fxNavigatorKey = GlobalKey<NavigatorState>();

/// 全局 ScaffoldMessenger。
///
/// 网络层（HTTP 401）和后台回调没有 BuildContext，却仍需要给用户
/// 一句提示；由 `MaterialApp.scaffoldMessengerKey` 挂上后统一从这里弹。
final GlobalKey<ScaffoldMessengerState> fxMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// 与 [fxToast] 同款的全局提示；没有可用的 messenger 时静默放弃。
void fxGlobalToast(String message) {
  final messenger = fxMessengerKey.currentState;
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        message,
        style: const TextStyle(
          color: Color(0xFF1B2430),
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
      backgroundColor: Colors.white.withValues(alpha: .96),
      elevation: 4,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(18, 0, 18, 18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      duration: const Duration(seconds: 2),
    ),
  );
}

/// 顶栏小标签当前文案；null 表示不显示。
///
/// 播放期间只允许「已投屏」「跟随房主」两个必要状态走这里，2 秒自动消失，
/// 半透明、很小、贴顶部安全区，不遮挡画面。
final ValueNotifier<String?> fxTopTagText = ValueNotifier<String?>(null);

OverlayEntry? _fxTopTagEntry;
Timer? _fxTopTagTimer;

/// 亮一个顶栏小标签（已有标签时直接覆盖文案并重新计时）。
void fxShowTopTag(String text) {
  final overlay = fxNavigatorKey.currentState?.overlay;
  if (overlay == null) return;
  fxTopTagText.value = text;
  if (_fxTopTagEntry == null) {
    final created = OverlayEntry(builder: (_) => const FxTopTagView());
    _fxTopTagEntry = created;
    overlay.insert(created);
  }
  _fxTopTagTimer?.cancel();
  _fxTopTagTimer = Timer(const Duration(seconds: 2), fxHideTopTag);
}

/// 立刻收起顶栏小标签。
void fxHideTopTag() {
  _fxTopTagTimer?.cancel();
  _fxTopTagTimer = null;
  fxTopTagText.value = null;
  final entry = _fxTopTagEntry;
  _fxTopTagEntry = null;
  if (entry == null) return;
  try {
    entry.remove();
  } catch (_) {
    // Overlay 已随页面销毁：忽略。
  }
}

/// 顶栏小标签本体：不参与命中测试，点击穿透到播放器。
class FxTopTagView extends StatelessWidget {
  const FxTopTagView({super.key});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        alignment: Alignment.topCenter,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ValueListenableBuilder<String?>(
              valueListenable: fxTopTagText,
              builder: (context, text, _) {
                if (text == null || text.isEmpty) {
                  return const SizedBox.shrink();
                }
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .45),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: .4,
                      height: 1.2,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

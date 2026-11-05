import 'package:flutter/material.dart';

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

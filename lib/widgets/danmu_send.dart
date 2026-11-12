import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// 发送弹幕气泡 —— 全屏播放时从底部弹出的输入条。
///
/// 交互对齐 B站/腾讯：
///   · 弹出时自动聚焦，弹出键盘
///   · 左侧「发送」按钮，右侧字符计数
///   · 点击遮罩或返回键关闭
///   · 空内容时发送按钮禁用
class DanmuSendSheet extends StatefulWidget {
  const DanmuSendSheet({super.key, required this.onSend});

  /// 返回 null 表示取消；返回文字表示发送。
  final ValueChanged<String> onSend;

  @override
  State<DanmuSendSheet> createState() => _DanmuSendSheetState();
}

class _DanmuSendSheetState extends State<DanmuSendSheet> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
  static const int _maxLen = 50;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    widget.onSend(t);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final canSend = _text.text.trim().isNotEmpty;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        decoration: const BoxDecoration(
          color: Color(0xFF16181D),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 34,
              height: 3,
              decoration: BoxDecoration(
                color: const Color(0xFF3A3F4A),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF23262E),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF31353F)),
                    ),
                    child: Center(
                      child: TextField(
                        controller: _text,
                        focusNode: _focus,
                        maxLength: _maxLen,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _submit(),
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(_maxLen),
                        ],
                        style: const TextStyle(
                          fontSize: 13.5,
                          color: Colors.white,
                        ),
                        cursorColor: Fx.accent,
                        decoration: const InputDecoration(
                          isDense: true,
                          counterText: '',
                          border: InputBorder.none,
                          hintText: '发个弹幕吧…',
                          hintStyle: TextStyle(
                            fontSize: 13,
                            color: Color(0xFF7C8595),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: canSend ? _submit : null,
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    decoration: BoxDecoration(
                      gradient: canSend ? Fx.brand : null,
                      color: canSend ? null : const Color(0xFF23262E),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Center(
                      child: Text(
                        '发送',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: canSend
                              ? Colors.white
                              : const Color(0xFF5E6675),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Text(
                  '弹幕保存在本机，不会上传',
                  style: TextStyle(fontSize: 10.5, color: Color(0xFF6B7484)),
                ),
                const Spacer(),
                Text(
                  '${_text.text.characters.length}/$_maxLen',
                  style: const TextStyle(
                      fontSize: 10.5, color: Color(0xFF6B7484)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 弹出输入条。
Future<void> showDanmuSendSheet(
  BuildContext context, {
  required ValueChanged<String> onSend,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: .35),
    builder: (_) => DanmuSendSheet(onSend: onSend),
  );
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme.dart';
import 'together_chat.dart';

/// 悬浮聊天层：一起看房间观看时不占屏幕，只留一个半透明小标志。
///
/// 交互：
///  - 平时只有一个直径 40 的圆形小标志，带未读数角标（对方发几条就显示几）；
///  - 点一下展开一个**透明气泡**：里面是最新几条消息 + 一行输入框；
///  - 自己发出的文字会以「悬浮字条」形式浮在屏幕上方，几秒后自动淡出；
///  - 再点一次（或点空白）收起，回到只有小标志的状态。
///
/// 设计目的：一起看时画面不被聊天区挤压，同时消息又不丢。
class TogetherFloatingChat extends StatefulWidget {
  const TogetherFloatingChat({
    super.key,
    required this.chat,
    required this.onSend,
    this.enabled = true,
    this.visible = true,
  });

  final ValueListenable<List<TogetherChatMessage>> chat;
  final bool Function(String text) onSend;
  final bool enabled;

  /// 全屏 / 沉浸时也可整体隐藏（直播场景不需要）。
  final bool visible;

  @override
  State<TogetherFloatingChat> createState() => _TogetherFloatingChatState();
}

class _TogetherFloatingChatState extends State<TogetherFloatingChat> {
  bool _open = false;
  int _seen = 0;
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// 悬浮字条：最近发出的几条，几秒后自动消失。
  final List<_FloatLine> _floats = <_FloatLine>[];
  Timer? _floatTimer;

  @override
  void initState() {
    super.initState();
    widget.chat.addListener(_onChat);
    _seen = widget.chat.value.length;
  }

  @override
  void didUpdateWidget(covariant TogetherFloatingChat oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chat != widget.chat) {
      oldWidget.chat.removeListener(_onChat);
      widget.chat.addListener(_onChat);
    }
  }

  @override
  void dispose() {
    widget.chat.removeListener(_onChat);
    _floatTimer?.cancel();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChat() {
    if (!mounted) return;
    final list = widget.chat.value;
    if (list.isEmpty) return;
    final last = list.last;
    // 对方（或系统）的新消息：气泡收起时浮一条字条 + 累加未读。
    final isSelf = last.mine;
    if (!_open && !isSelf && !last.system) {
      _pushFloat(last.text, fromPeer: true);
    }
    if (!_open) {
      setState(() => _seen = list.length);
    } else {
      setState(() => _seen = list.length);
    }
  }

  void _pushFloat(String text, {bool fromPeer = false}) {
    if (text.trim().isEmpty) return;
    _floats.add(_FloatLine(text.trim(), fromPeer));
    // 最多保留 4 条，超出的从最早开始淡出。
    while (_floats.length > 4) {
      _floats.removeAt(0);
    }
    _floatTimer?.cancel();
    _floatTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      setState(() => _floats.clear());
    });
    setState(() {});
  }

  void _toggle() {
    setState(() {
      _open = !_open;
      if (_open) {
        _seen = widget.chat.value.length;
        _floats.clear();
      }
    });
    if (_open) {
      // 展开后自动聚焦，用户直接就能打字。
      Future<void>.delayed(const Duration(milliseconds: 120), () {
        if (mounted) _focus.requestFocus();
      });
    } else {
      _focus.unfocus();
    }
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    if (!widget.onSend(text)) return;
    _input.clear();
    _pushFloat(text);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();
    final unread = (widget.chat.value.length - _seen).clamp(0, 99);
    return Stack(
      children: [
        // 点气泡以外的任意位置收起，变回小图标。
        // 用透明全屏层拦截：只在展开时出现，收起时完全不占交互。
        if (_open)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggle,
              child: const SizedBox.expand(),
            ),
          ),
        // 悬浮字条：屏幕上方居中偏左，不挡字幕区。
        Positioned(
          left: 16,
          right: 72,
          top: MediaQuery.viewPaddingOf(context).top + 64,
          child: IgnorePointer(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in _floats) _FloatBubble(line: line),
              ],
            ),
          ),
        ),
        // 小标志 / 气泡：贴右下角并让出安全区；键盘弹起时整体上移，
        // 否则输入框会被键盘挡住（之前放在视频区 Expanded 里，
        // 键盘一弹就被压出屏幕）。
        Positioned(
          right: 12 + MediaQuery.viewPaddingOf(context).right,
          bottom: 24 +
              MediaQuery.viewPaddingOf(context).bottom +
              MediaQuery.viewInsetsOf(context).bottom,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (_open) _buildBubble(context),
              if (_open) const SizedBox(height: 8),
              _buildFab(unread),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFab(int unread) {
    return GestureDetector(
      onTap: _toggle,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              // 半透明：不干扰观看，又能看见。
              color: Colors.black.withValues(alpha: .38),
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: .22),
                width: 1,
              ),
            ),
            child: Icon(
              _open ? Icons.close_rounded : Icons.chat_bubble_outline_rounded,
              size: 19,
              color: Colors.white.withValues(alpha: .82),
            ),
          ),
          if (unread > 0)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                constraints: const BoxConstraints(minWidth: 17),
                decoration: BoxDecoration(
                  color: Fx.accent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  unread >= 99 ? '99+' : '$unread',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 10,
                    height: 1.35,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 透明小聊天框：最新消息 + 输入行，整体半透明。
  Widget _buildBubble(BuildContext context) {
    final messages = widget.chat.value;
    final recent = messages.length <= 6
        ? messages
        : messages.sublist(messages.length - 6);
    return Container(
      width: 250,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .42),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: .16)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (recent.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '还没有消息',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: .5),
                ),
              ),
            )
          else
            for (final m in recent)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: RichText(
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    style: TextStyle(
                      fontSize: 11.5,
                      height: 1.35,
                      color: Colors.white.withValues(alpha: .88),
                    ),
                    children: [
                      if (!m.system)
                        TextSpan(
                          text: '${m.user} ',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: .5),
                          ),
                        ),
                      TextSpan(text: m.text),
                    ],
                  ),
                ),
              ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .10),
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: TextField(
                    controller: _input,
                    focusNode: _focus,
                    enabled: widget.enabled,
                    style: const TextStyle(fontSize: 12, color: Colors.white),
                    cursorColor: Fx.accent,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: widget.enabled ? '说点什么…' : '正在重连…',
                      hintStyle: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: .42),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: _send,
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: Fx.accent.withValues(alpha: .85),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.arrow_upward_rounded,
                    size: 17,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FloatLine {
  const _FloatLine(this.text, this.fromPeer);
  final String text;
  final bool fromPeer;
}

/// 悬浮字条：淡入 + 半透明底，几秒后整批淡出。
class _FloatBubble extends StatelessWidget {
  const _FloatBubble({required this.line});

  final _FloatLine line;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 6),
          child: child,
        ),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .34),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          line.text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.35,
            fontWeight: line.fromPeer ? FontWeight.w600 : FontWeight.w500,
            color: Colors.white.withValues(alpha: line.fromPeer ? .95 : .8),
            shadows: const [Shadow(color: Colors.black54, blurRadius: 3)],
          ),
        ),
      ),
    );
  }
}

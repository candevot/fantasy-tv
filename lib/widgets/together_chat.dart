import 'package:flutter/material.dart';

import '../theme.dart';
import 'together_ui.dart';

/// 一起看聊天消息。system = 居中系统行，mine = 右侧自己。
class TogetherChatMessage {
  const TogetherChatMessage({
    required this.text,
    required this.time,
    this.user = '',
    this.avatar = '',
    this.mine = false,
    this.system = false,
  });

  final String text;
  final DateTime time;
  final String user;
  final String avatar;
  final bool mine;
  final bool system;

  factory TogetherChatMessage.system(
    String text, {
    DateTime? time,
  }) =>
      TogetherChatMessage(
        text: text,
        time: time ?? DateTime.now(),
        system: true,
      );

  factory TogetherChatMessage.fromServer(
    Map<String, dynamic> j, {
    required bool mine,
  }) {
    final rawUser = j['user'];
    final user = rawUser is Map ? Map<String, dynamic>.from(rawUser) : const <String, dynamic>{};
    final at = j['at'];
    return TogetherChatMessage(
      text: '${j['text'] ?? ''}',
      time: at is num && at > 0
          ? DateTime.fromMillisecondsSinceEpoch(at.toInt())
          : DateTime.now(),
      user: '${user['name'] ?? '影迷'}',
      avatar: '${user['avatar'] ?? ''}',
      mine: mine,
    );
  }
}

/// 聊天流：系统行居中、别人居左、自己居右，新消息自动贴底。
class TogetherChatList extends StatefulWidget {
  const TogetherChatList({super.key, required this.messages});

  final List<TogetherChatMessage> messages;

  @override
  State<TogetherChatList> createState() => _TogetherChatListState();
}

class _TogetherChatListState extends State<TogetherChatList>
    with WidgetsBindingObserver {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollToBottom(jump: true);
  }

  @override
  void didUpdateWidget(covariant TogetherChatList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_signature(widget.messages) != _signature(oldWidget.messages)) {
      _scrollToBottom();
    }
  }

  String _signature(List<TogetherChatMessage> messages) {
    if (messages.isEmpty) return '';
    final last = messages.last;
    // 消息上限会裁掉最旧一条：长度不变但最后一条变了也要贴底。
    return '${messages.length}|${last.time.microsecondsSinceEpoch}|'
        '${last.user}|${last.text}|${last.system}';
  }

  @override
  void didChangeMetrics() {
    // 键盘弹出 / 收起时列表高度变化，保持最新消息可见。
    _scrollToBottom();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (jump) {
        _scroll.jumpTo(target);
      } else {
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 28,
              color: Fx.sub.withOpacity(.45),
            ),
            const SizedBox(height: 8),
            Text(
              '还没有人说话，来打个招呼吧',
              style: TextStyle(fontSize: 11, color: Fx.sub.withOpacity(.75)),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: widget.messages.length,
      itemBuilder: (context, i) {
        final message = widget.messages[i];
        return message.system
            ? _SystemLine(message: message)
            : _ChatBubble(message: message);
      },
    );
  }
}

class _SystemLine extends StatelessWidget {
  const _SystemLine({required this.message});

  final TogetherChatMessage message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Center(
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * .82,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.42),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: Colors.white.withOpacity(.56)),
          ),
          child: Text(
            '${message.text}  ${togetherClock(message.time)}',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 9.5,
              height: 1.4,
              color: Fx.sub.withOpacity(.9),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.message});

  final TogetherChatMessage message;

  @override
  Widget build(BuildContext context) {
    final mine = message.mine;
    final maxWidth = MediaQuery.of(context).size.width * .68;
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        gradient: mine ? Fx.brand : null,
        color: mine ? null : Colors.white.withOpacity(.82),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(mine ? 16 : 5),
          bottomRight: Radius.circular(mine ? 5 : 16),
        ),
        border: mine
            ? null
            : Border.all(color: Colors.white.withOpacity(.95), width: 1),
        boxShadow: [
          BoxShadow(
            color: mine
                ? Fx.accent.withOpacity(.18)
                : const Color(0xFF50729F).withOpacity(.07),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Text(
        message.text,
        style: TextStyle(
          fontSize: 13,
          height: 1.42,
          color: mine ? Colors.white : Fx.ink,
        ),
      ),
    );

    final meta = Text(
      mine ? '我 · ${togetherClock(message.time)}' : '${message.user} · ${togetherClock(message.time)}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: mine ? TextAlign.right : TextAlign.left,
      style: TextStyle(
        fontSize: 9,
        color: Fx.sub.withOpacity(.72),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!mine) ...[
            TogetherAvatar(
              name: message.user,
              avatar: message.avatar,
              size: 28,
            ),
            const SizedBox(width: 7),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment:
                  mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: meta,
                ),
                const SizedBox(height: 3),
                bubble,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部聊天输入：表情 + 输入框「随便说点啥吧...」+ 发送。
class TogetherComposer extends StatefulWidget {
  const TogetherComposer({
    super.key,
    required this.onSend,
    this.enabled = true,
    this.hint,
  });

  /// 返回 true 表示已发出 / 已本地展示，输入框才清空。
  final bool Function(String text) onSend;
  final bool enabled;

  /// 自定义输入提示（重连 / 在线文案不同）。
  final String? hint;

  @override
  State<TogetherComposer> createState() => _TogetherComposerState();
}

class _TogetherComposerState extends State<TogetherComposer> {
  static const _emojis = <String>[
    '😀', '😂', '🥰', '😍', '😎', '🤔', '😭', '😅',
    '🤣', '😡', '👍', '👏', '🙌', '❤️', '🔥', '🌹',
    '🍿', '🎉', '👀', '😴', '🤯', '🤝', '💯', '✨',
  ];

  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _emojiOpen = false;
  bool _failed = false;
  String _failedText = '';

  @override
  void initState() {
    super.initState();
    _text.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _text.removeListener(_onTextChanged);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    if (!mounted) return;
    if (_failed && _text.text.trim() != _failedText) {
      setState(() => _failed = false);
      return;
    }
    setState(() {});
  }

  void _toggleEmoji() {
    if (!widget.enabled) return;
    setState(() => _emojiOpen = !_emojiOpen);
    if (_emojiOpen) FocusScope.of(context).unfocus();
  }

  void _insert(String emoji) {
    final value = _text.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final text = value.text.replaceRange(start, end, emoji);
    _text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
  }

  void _submit() {
    if (!widget.enabled) return;
    final text = _text.text.trim();
    if (text.isEmpty) return;
    final accepted = widget.onSend(text);
    if (!mounted) return;
    if (accepted) {
      _text.clear();
      setState(() {
        _emojiOpen = false;
        _failed = false;
        _failedText = '';
      });
    } else {
      // 发送失败：输入内容原样保留，按钮变成「重试」。
      setState(() {
        _failed = true;
        _failedText = text;
        _emojiOpen = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasText = _text.text.trim().isNotEmpty;
    final canSend = widget.enabled && hasText;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      decoration: togetherGlass(radius: 25, opacity: .8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_emojiOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
              child: Wrap(
                spacing: 2,
                runSpacing: 2,
                children: [
                  for (final emoji in _emojis)
                    GestureDetector(
                      onTap: () => _insert(emoji),
                      child: Container(
                        width: 34,
                        height: 32,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(.42),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(emoji, style: const TextStyle(fontSize: 19)),
                      ),
                    ),
                ],
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleEmoji,
                child: Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _emojiOpen
                        ? Fx.accent.withOpacity(.12)
                        : Colors.white.withOpacity(.5),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.emoji_emotions_outlined,
                    size: 21,
                    color: widget.enabled
                        ? (_emojiOpen ? Fx.accent : Fx.ink.withOpacity(.72))
                        : Fx.sub.withOpacity(.4),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: TextField(
                  controller: _text,
                  focusNode: _focus,
                  enabled: widget.enabled,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _submit(),
                  onTap: () {
                    if (_emojiOpen) setState(() => _emojiOpen = false);
                  },
                  maxLength: 300,
                  buildCounter: (
                    _, {
                    required currentLength,
                    required isFocused,
                    maxLength,
                  }) =>
                      null,
                  style: const TextStyle(fontSize: 13.5, color: Fx.ink),
                  decoration: InputDecoration(
                    isDense: true,
                    counterText: '',
                    hintText: widget.hint ??
                        (widget.enabled ? '随便说点啥吧...' : '正在重连，稍后可以聊天'),
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: Fx.sub.withOpacity(.7),
                    ),
                    border: InputBorder.none,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                  ),
                ),
              ),
              if (_failed) ...[
                const SizedBox(width: 4),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _submit,
                  child: Container(
                    height: 38,
                    padding: const EdgeInsets.symmetric(horizontal: 9),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Fx.accent.withOpacity(.12),
                      borderRadius: BorderRadius.circular(19),
                      border: Border.all(color: Fx.accent.withOpacity(.22)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.refresh_rounded,
                          size: 15,
                          color: Fx.accent,
                        ),
                        const SizedBox(width: 3),
                        const Text(
                          '重试',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Fx.accent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 4),
              GestureDetector(
                onTap: (_failed || canSend) ? _submit : null,
                child: Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: (_failed || canSend) ? Fx.brand : null,
                    color: (_failed || canSend)
                        ? null
                        : Colors.white.withOpacity(.55),
                    shape: BoxShape.circle,
                    boxShadow: (_failed || canSend)
                        ? [
                            BoxShadow(
                              color: Fx.accent.withOpacity(.3),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ]
                        : null,
                  ),
                  child: Icon(
                    _failed
                        ? Icons.refresh_rounded
                        : Icons.arrow_upward_rounded,
                    size: 21,
                    color: (_failed || canSend)
                        ? Colors.white
                        : Fx.sub.withOpacity(.5),
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

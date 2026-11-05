import 'package:flutter/material.dart';

import '../theme.dart';
import 'together_ui.dart';

/// 一起看聊天消息。
///
/// [system] 是房间系统提示（居中一行），[mine] 决定气泡靠右还是靠左；
/// 无论左右，列表里都会展示头像、昵称、时间和内容。
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

  factory TogetherChatMessage.system(String text, {DateTime? time}) =>
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
    final user = rawUser is Map
        ? Map<String, dynamic>.from(rawUser)
        : const <String, dynamic>{};
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

/// 聊天消息列表：空态、自动贴底、系统行、左右气泡。
///
/// 只依赖消息列表本身，房间页/全屏小面板共用；[compact] 时缩小头像、
/// 字号和气泡最大宽度，适配 ≤40%×45% 的全屏聊天面板。
class TogetherChatList extends StatefulWidget {
  const TogetherChatList({
    super.key,
    required this.messages,
    this.compact = false,
    this.emptyText = togetherChatEmptyText,
    this.padding,
  });

  final List<TogetherChatMessage> messages;
  final bool compact;
  final String emptyText;
  final EdgeInsets? padding;

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
    return '${messages.length}|${last.time.microsecondsSinceEpoch}|'
        '${last.user}|${last.text}|${last.system}';
  }

  @override
  void didChangeMetrics() {
    // 键盘弹起 / 收起、面板高度变化时保持最新消息可见。
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
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.forum_outlined,
                size: widget.compact ? 24 : 30,
                color: Fx.sub.withValues(alpha: .42),
              ),
              SizedBox(height: widget.compact ? 6 : 8),
              Text(
                widget.emptyText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: widget.compact ? 11 : 12,
                  height: 1.4,
                  color: Fx.sub.withValues(alpha: .78),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: widget.padding ??
          EdgeInsets.fromLTRB(
            widget.compact ? 8 : 12,
            widget.compact ? 8 : 12,
            widget.compact ? 8 : 12,
            widget.compact ? 8 : 12,
          ),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: widget.messages.length,
      itemBuilder: (context, i) {
        final message = widget.messages[i];
        return message.system
            ? _SystemLine(message: message, compact: widget.compact)
            : _ChatBubble(message: message, compact: widget.compact);
      },
    );
  }
}

class _SystemLine extends StatelessWidget {
  const _SystemLine({required this.message, required this.compact});

  final TogetherChatMessage message;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.sizeOf(context).width * .82;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 3 : 5),
      child: Center(
        child: Container(
          constraints: BoxConstraints(maxWidth: maxWidth),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 10,
            vertical: compact ? 4 : 5,
          ),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .46),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: Colors.white.withValues(alpha: .58)),
          ),
          child: Text(
            '${message.text}  ${togetherClock(message.time)}',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: compact ? 9 : 9.5,
              height: 1.4,
              color: Fx.sub.withValues(alpha: .9),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.message, required this.compact});

  final TogetherChatMessage message;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final mine = message.mine;
    final screen = MediaQuery.sizeOf(context).width;
    // 全屏小面板宽度只有屏宽 40%，气泡最大宽度要跟着收。
    final maxWidth = screen * (compact ? .28 : .68);
    final avatarSize = compact ? 22.0 : 28.0;
    final name =
        mine ? '我' : (message.user.trim().isEmpty ? '影迷' : message.user);
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 9 : 12,
        vertical: compact ? 6 : 9,
      ),
      decoration: BoxDecoration(
        gradient: mine ? Fx.brand : null,
        color: mine ? null : Colors.white.withValues(alpha: .84),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(mine ? 16 : 5),
          bottomRight: Radius.circular(mine ? 5 : 16),
        ),
        border: mine
            ? null
            : Border.all(color: Colors.white.withValues(alpha: .95), width: 1),
        boxShadow: [
          BoxShadow(
            color: mine
                ? Fx.accent.withValues(alpha: .18)
                : const Color(0xFF50729F).withValues(alpha: .07),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Text(
        message.text,
        style: TextStyle(
          fontSize: compact ? 11.5 : 13,
          height: 1.42,
          color: mine ? Colors.white : Fx.ink,
        ),
      ),
    );

    final meta = Text(
      '$name · ${togetherClock(message.time)}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: mine ? TextAlign.right : TextAlign.left,
      style: TextStyle(
        fontSize: compact ? 8 : 9,
        color: Fx.sub.withValues(alpha: .72),
      ),
    );

    final avatar = TogetherAvatar(
      name: name,
      avatar: message.avatar,
      size: avatarSize,
      host: false,
    );

    final column = Flexible(
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
    );

    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 3 : 5),
      child: Row(
        mainAxisAlignment:
            mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: mine
            ? [column, const SizedBox(width: 6), avatar]
            : [avatar, const SizedBox(width: 6), column],
      ),
    );
  }
}

/// 底部聊天输入条：表情 + 输入框 + 发送。
///
/// [onSend] 返回 true 表示消息已发出，输入框才清空；返回 false 时保留文字，
/// 发送键变成「重试」，避免弱网下丢消息。
class TogetherComposer extends StatefulWidget {
  const TogetherComposer({
    super.key,
    required this.onSend,
    this.enabled = true,
    this.hint,
    this.compact = false,
  });

  final bool Function(String text) onSend;
  final bool enabled;
  final String? hint;

  /// 全屏聊天面板里用紧凑尺寸（无外边距、两行表情）。
  final bool compact;

  @override
  State<TogetherComposer> createState() => _TogetherComposerState();
}

class _TogetherComposerState extends State<TogetherComposer> {
  static const _emojis = <String>[
    '😀',
    '😂',
    '🥰',
    '😍',
    '😎',
    '🤔',
    '😭',
    '😅',
    '🤣',
    '😡',
    '👍',
    '👏',
    '🙌',
    '❤️',
    '🔥',
    '🌹',
    '🍿',
    '🎉',
    '👀',
    '😴',
    '🤯',
    '🤝',
    '💯',
    '✨',
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
      _focus.requestFocus();
    } else {
      setState(() {
        _failed = true;
        _failedText = text;
        _emojiOpen = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;
    final hasText = _text.text.trim().isNotEmpty;
    final canSend = widget.enabled && hasText;
    final actionSize = compact ? 30.0 : 38.0;
    final emojis = compact ? _emojis.take(16).toList() : _emojis;
    return Container(
      margin: compact
          ? const EdgeInsets.fromLTRB(6, 2, 6, 6)
          : const EdgeInsets.fromLTRB(12, 8, 12, 10),
      padding: EdgeInsets.all(compact ? 4 : 6),
      decoration: togetherGlass(radius: compact ? 16 : 25, opacity: .8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_emojiOpen)
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 2 : 6,
                compact ? 2 : 4,
                compact ? 2 : 6,
                compact ? 3 : 6,
              ),
              child: Wrap(
                spacing: compact ? 1 : 2,
                runSpacing: compact ? 1 : 2,
                children: [
                  for (final emoji in emojis)
                    GestureDetector(
                      onTap: () => _insert(emoji),
                      child: Container(
                        width: compact ? 26 : 34,
                        height: compact ? 24 : 32,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .42),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          emoji,
                          style: TextStyle(fontSize: compact ? 14 : 19),
                        ),
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
                  width: actionSize,
                  height: actionSize,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _emojiOpen
                        ? Fx.accent.withValues(alpha: .12)
                        : Colors.white.withValues(alpha: .5),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.emoji_emotions_outlined,
                    size: compact ? 17 : 21,
                    color: widget.enabled
                        ? (_emojiOpen ? Fx.accent : Fx.ink.withValues(alpha: .72))
                        : Fx.sub.withValues(alpha: .4),
                  ),
                ),
              ),
              SizedBox(width: compact ? 2 : 4),
              Expanded(
                child: TextField(
                  controller: _text,
                  focusNode: _focus,
                  enabled: widget.enabled,
                  minLines: 1,
                  maxLines: compact ? 2 : 4,
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
                  style: TextStyle(
                    fontSize: compact ? 12 : 13.5,
                    color: Fx.ink,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    counterText: '',
                    hintText: widget.hint ??
                        (widget.enabled ? '说点什么…' : '正在重连，稍后可以聊天'),
                    hintStyle: TextStyle(
                      fontSize: compact ? 11.5 : 13,
                      color: Fx.sub.withValues(alpha: .7),
                    ),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: compact ? 7 : 10,
                    ),
                  ),
                ),
              ),
              if (_failed) ...[
                SizedBox(width: compact ? 2 : 4),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _submit,
                  child: Container(
                    height: actionSize,
                    padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 9),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Fx.accent.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(actionSize / 2),
                      border: Border.all(color: Fx.accent.withValues(alpha: .22)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.refresh_rounded,
                          size: 15,
                          color: Fx.accent,
                        ),
                        if (!compact) ...[
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
                      ],
                    ),
                  ),
                ),
              ],
              SizedBox(width: compact ? 2 : 4),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: (_failed || canSend) ? _submit : null,
                child: Container(
                  width: actionSize,
                  height: actionSize,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: (_failed || canSend) ? Fx.brand : null,
                    color: (_failed || canSend)
                        ? null
                        : Colors.white.withValues(alpha: .55),
                    shape: BoxShape.circle,
                    boxShadow: (_failed || canSend)
                        ? [
                            BoxShadow(
                              color: Fx.accent.withValues(alpha: .3),
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
                    size: compact ? 17 : 21,
                    color: (_failed || canSend)
                        ? Colors.white
                        : Fx.sub.withValues(alpha: .5),
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

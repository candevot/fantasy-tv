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
    this.action = '',
  });

  final String text;
  final DateTime time;
  final String user;
  final String avatar;
  final bool mine;

  /// 系统条目：整行居中，没有头像和气泡。
  final bool system;

  /// 操作流水（「小明 换了线路 → 幻想4K」）的动作 key。
  ///
  /// 非空表示这是一条**操作提示**：和进出房间那种系统提示分开渲染
  /// （操作提示用半透明黑底、浅灰白字，样式更低调）；同一个 key 的
  /// 连续操作在 1 秒内会被合并成一条。
  final String action;

  bool get isOperation => action.isNotEmpty;

  factory TogetherChatMessage.system(String text, {DateTime? time}) =>
      TogetherChatMessage(
        text: text,
        time: time ?? DateTime.now(),
        system: true,
      );

  /// 操作流水：「小明 换了线路 → 幻想4K」。
  factory TogetherChatMessage.operation(
    String text, {
    required String action,
    DateTime? time,
  }) => TogetherChatMessage(
    text: text,
    time: time ?? DateTime.now(),
    system: true,
    action: action,
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
    this.transparent = false,
  });

  final List<TogetherChatMessage> messages;
  final bool compact;

  /// 全屏（盖在画面上）模式：气泡/昵称/系统条全部半透明，不挡画面。
  ///
  /// 竖屏房间页保持不透明（浅色卡片），全屏一起看才透明。
  final bool transparent;
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

  /// 新消息自动贴底；用户主动上翻时不抢。
  ///
  /// CHAT_NO_YANK（2026-11-15）：以前每次消息变化都 animateTo 到底，
  /// 用户正在往上翻历史，一来新消息就被拽回底部。现在只在「本来就贴着
  /// 底」（离底部 48dp 内）或者 [jump] 时跟随。
  void _scrollToBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      final target = position.maxScrollExtent;
      final atBottom = position.maxScrollExtent - position.pixels <= 48;
      if (!jump && !atBottom) return;
      if (jump || atBottom) {
        _scroll.jumpTo(target);
        return;
      }
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
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
      padding:
          widget.padding ??
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
        if (message.isOperation) {
          return _OperationLine(
            message: message,
            compact: widget.compact,
            transparent: widget.transparent,
          );
        }
        return message.system
            ? _SystemLine(
                message: message,
                compact: widget.compact,
                transparent: widget.transparent,
              )
            : _ChatBubble(
                message: message,
                compact: widget.compact,
                transparent: widget.transparent,
              );
      },
    );
  }
}

/// 操作流水：整行通栏的一条，居中小字。
///
/// 和普通聊天气泡**明显分开**：没有头像、没有气泡尖角、不靠左也不靠右，
/// 通栏一条窄条（半透明黑底 + 浅灰白小字），一眼就能看出「这是房间动作，
/// 不是某个人在说话」。
class _OperationLine extends StatelessWidget {
  const _OperationLine({
    required this.message,
    required this.compact,
    this.transparent = false,
  });

  final TogetherChatMessage message;
  final bool compact;
  final bool transparent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 6 : 8),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 8 : 10,
          vertical: compact ? 4 : 5,
        ),
        decoration: BoxDecoration(
          // 半透明黑：浅色房间页 / 全屏画面之上都能看清，又不抢戏。
          color: Colors.black.withValues(alpha: .55),
          borderRadius: BorderRadius.circular(compact ? 8 : 10),
        ),
        child: Text(
          message.text,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: compact ? 10.5 : 11.5,
            height: 1.3,
            fontWeight: FontWeight.w500,
            color: const Color(0xFFE6E9EF),
          ),
        ),
      ),
    );
  }
}

/// 系统提示（进入 / 离开房间）：比操作流水更轻，只有一行灰字。
class _SystemLine extends StatelessWidget {
  const _SystemLine({
    required this.message,
    required this.compact,
    this.transparent = false,
  });

  final TogetherChatMessage message;
  final bool compact;
  final bool transparent;

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.sizeOf(context).width * .82;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 4 : 5),
      child: Center(
        child: Container(
          constraints: BoxConstraints(maxWidth: maxWidth),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 9,
            vertical: 3,
          ),
          decoration: transparent
              ? null
              : BoxDecoration(
                  color: Colors.white.withValues(alpha: .46),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: .58),
                  ),
                ),
          child: Text(
            message.text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: compact ? 9.5 : 10,
              height: 1.3,
              color: transparent
                  ? Colors.white.withValues(alpha: .74)
                  : Fx.sub.withValues(alpha: .92),
              shadows: transparent
                  ? const [Shadow(color: Colors.black54, blurRadius: 3)]
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// 普通聊天气泡：左边头像 + 头像正下方昵称，右边气泡（自己的镜像）。
///
/// 布局规范（2026-11-15 定稿）：
/// ```text
///   ┌────┐
///   │头像│  ┌──────────────┐
///   └────┘  │ 这个线路好卡   │
///    小明    └──────────────┘
/// ```
class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    required this.message,
    required this.compact,
    this.transparent = false,
  });

  final TogetherChatMessage message;
  final bool compact;
  final bool transparent;

  /// 昵称灰：和正文不同色，一眼能分出来。
  static const Color _nameColor = Color(0xFF8A93A3);

  @override
  Widget build(BuildContext context) {
    final mine = message.mine;
    final screen = MediaQuery.sizeOf(context).width;
    // 全屏小面板宽度只有屏宽 40%，气泡最大宽度要跟着收。
    final maxWidth = screen * (compact ? .30 : .64);
    final avatarSize = compact ? 24.0 : 32.0;
    final name = mine
        ? '我'
        : (message.user.trim().isEmpty ? '影迷' : message.user);

    // 自己：主题色（半透明版 75%）；别人：浅色主题纯白卡片，全屏里半透明黑。
    final bubbleColor = mine
        ? (transparent ? Fx.accent.withValues(alpha: .75) : Fx.accent)
        : (transparent ? Colors.black.withValues(alpha: .55) : Colors.white);
    final textColor = mine
        ? Colors.white
        : (transparent ? const Color(0xFFE6E9EF) : Fx.ink);

    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 12,
        vertical: compact ? 7 : 9,
      ),
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(14),
          topRight: const Radius.circular(14),
          // 自己右下角 4dp、别人左下角 4dp：气泡「指向」自己那一侧。
          bottomLeft: Radius.circular(mine ? 14 : 4),
          bottomRight: Radius.circular(mine ? 4 : 14),
        ),
        border: transparent || mine
            ? null
            : Border.all(color: const Color(0xFFEFF3FA)),
        boxShadow: transparent
            ? null
            : [
                BoxShadow(
                  color: Fx.accent.withValues(alpha: mine ? .16 : .05),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      // CHAT_LONG（2026-11-15）：接收侧限高。
      //
      // 发送侧限 300 字（输入框 maxLength），但对面可能是别的客户端 / 老版本，
      // 一条几千字的消息会把气泡撑到十几屏，聊天区完全看不到别人说话。
      // 这里最多 10 行 + 省略号。
      child: Text(
        message.text,
        maxLines: 10,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: compact ? 12 : 14,
          height: 1.35,
          color: textColor,
        ),
      ),
    );

    // 头像 + 昵称一组：昵称在头像正下方、居中对齐。
    final avatarColumn = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TogetherAvatar(
          name: name,
          avatar: message.avatar,
          size: avatarSize,
          host: false,
        ),
        const SizedBox(height: 3),
        SizedBox(
          width: avatarSize + (compact ? 10 : 16),
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: compact ? 9.5 : 11,
              height: 1.2,
              fontWeight: FontWeight.w500,
              color: transparent
                  ? Colors.white.withValues(alpha: .84)
                  : _nameColor,
              shadows: transparent
                  ? const [Shadow(color: Colors.black54, blurRadius: 3)]
                  : null,
            ),
          ),
        ),
      ],
    );

    final body = Flexible(
      child: Padding(
        // 气泡顶端和头像顶端对齐（头像下方还有昵称，不用再抬高）。
        padding: const EdgeInsets.only(top: 1),
        child: bubble,
      ),
    );

    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 6 : 7),
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: mine
            ? [body, const SizedBox(width: 10), avatarColumn]
            : [avatarColumn, const SizedBox(width: 10), body],
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
    this.transparent = false,
  });

  final bool Function(String text) onSend;
  final bool enabled;
  final String? hint;

  /// 全屏（盖在画面上）：半透明胶囊，聚焦时才稍微实一点。
  final bool transparent;

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
    final transparent = widget.transparent;
    final focused = _focus.hasFocus;
    return Container(
      margin: compact
          ? const EdgeInsets.fromLTRB(6, 2, 6, 6)
          : const EdgeInsets.fromLTRB(12, 8, 12, 10),
      padding: EdgeInsets.all(compact ? 4 : 6),
      decoration: transparent
          ? BoxDecoration(
              // 半透明胶囊：不聚焦时几乎只有一层淡淡的玻璃，
              // 一聚焦就把底子加实一点，保证输入看得清。
              color: Colors.white.withValues(alpha: focused ? .30 : .16),
              borderRadius: BorderRadius.circular(compact ? 16 : 25),
              border: Border.all(
                color: Colors.white.withValues(alpha: focused ? .42 : .24),
              ),
            )
          : togetherGlass(radius: compact ? 16 : 25, opacity: .8),
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
                        : Colors.white.withValues(
                            alpha: widget.transparent ? .22 : .5,
                          ),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.emoji_emotions_outlined,
                    size: compact ? 17 : 21,
                    color: widget.enabled
                        ? (_emojiOpen
                              ? Fx.accent
                              : (widget.transparent
                                    ? Colors.white.withValues(alpha: .86)
                                    : Fx.ink.withValues(alpha: .72)))
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
                  buildCounter:
                      (
                        _, {
                        required currentLength,
                        required isFocused,
                        maxLength,
                      }) => null,
                  style: TextStyle(
                    fontSize: compact ? 12 : 13.5,
                    color: transparent ? Colors.white : Fx.ink,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    counterText: '',
                    hintText:
                        widget.hint ??
                        (widget.enabled ? '说点什么…' : '正在重连，稍后可以聊天'),
                    hintStyle: TextStyle(
                      fontSize: compact ? 11.5 : 13,
                      color: transparent
                          ? Colors.white.withValues(alpha: .62)
                          : Fx.sub.withValues(alpha: .7),
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
                      border: Border.all(
                        color: Fx.accent.withValues(alpha: .22),
                      ),
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

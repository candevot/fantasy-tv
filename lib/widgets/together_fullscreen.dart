import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../theme.dart';
import 'together_chat.dart';
import 'together_ui.dart';

/// 一起看 · 全屏播放。
///
/// 横屏铺满视频，控件 3 秒自动隐藏；聊天以半透明玻璃气泡悬浮在视频上，
/// 可拖动、可收起，新消息会浮出提示并累计未读角标。
class TogetherFullscreenView extends StatefulWidget {
  const TogetherFullscreenView({
    super.key,
    required this.controller,
    required this.messages,
    required this.members,
    required this.roomCode,
    required this.title,
    required this.ep,
    required this.isHost,
    required this.online,
    required this.position,
    required this.duration,
    required this.onExit,
    required this.onTogglePlay,
    required this.onSeek,
    required this.onHostOnly,
    required this.onShowMembers,
  });

  final VideoPlayerController? controller;
  final List<TogetherChatMessage> messages;
  final List<TogetherMember> members;
  final String roomCode;
  final String title;
  final int ep;
  final bool isHost;
  final bool online;
  final double position;
  final double duration;
  final VoidCallback onExit;
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onSeek;
  final VoidCallback onHostOnly;
  final VoidCallback onShowMembers;

  @override
  State<TogetherFullscreenView> createState() => _TogetherFullscreenViewState();
}

class _TogetherFullscreenViewState extends State<TogetherFullscreenView> {
  static const Duration _autoHide = Duration(seconds: 3);

  bool _controls = true;
  Timer? _hideTimer;
  double? _dragPosition;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_autoHide, () {
      if (!mounted) return;
      setState(() => _controls = false);
    });
  }

  void _showControls({bool autoHide = true}) {
    _hideTimer?.cancel();
    if (!_controls) setState(() => _controls = true);
    if (autoHide) _scheduleHide();
  }

  void _toggleControls() {
    if (_controls) {
      _hideTimer?.cancel();
      setState(() => _controls = false);
    } else {
      _showControls();
    }
  }

  void _act(VoidCallback action) {
    _showControls();
    action();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final ready = controller != null && controller.value.isInitialized;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (ready)
            Center(
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio > 0
                    ? controller.value.aspectRatio
                    : 16 / 9,
                child: VideoPlayer(controller),
              ),
            )
          else
            _buildPlaceholder(),
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
            ),
          ),
          AnimatedOpacity(
            opacity: _controls ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            child: IgnorePointer(
              ignoring: !_controls,
              child: _buildControls(context, controller, ready),
            ),
          ),
          Positioned.fill(
            child: TogetherFloatingChat(
              messages: widget.messages,
              members: widget.members,
              online: widget.online,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '正在加载视频…',
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withOpacity(.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls(
    BuildContext context,
    VideoPlayerController? controller,
    bool ready,
  ) {
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0, .28, .56, 1],
                colors: [
                  Colors.black.withOpacity(.58),
                  Colors.transparent,
                  Colors.transparent,
                  Colors.black.withOpacity(.66),
                ],
              ),
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 12, 6),
            child: Column(
              children: [
                _buildTopBar(context),
                Expanded(
                  child: Center(
                    child: _buildPlayButton(controller, ready),
                  ),
                ),
                _buildBottomBar(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Row(
      children: [
        _glassButton(
          Icons.arrow_back_ios_new_rounded,
          () => _act(widget.onExit),
          tooltip: '退出全屏',
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '第 ${widget.ep} 集 · 房间 ${widget.roomCode}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 9.5,
                  color: Colors.white.withOpacity(.68),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _buildStatusChip(),
        const SizedBox(width: 6),
        _buildMembersChip(),
      ],
    );
  }

  Widget _buildStatusChip() {
    final color =
        widget.online ? const Color(0xFF57D3A3) : const Color(0xFFFF8A80);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.40),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withOpacity(.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(
            widget.online ? '已连接' : '重连中',
            style: const TextStyle(
              fontSize: 8.5,
              fontWeight: FontWeight.w600,
              color: Color(0xE6FFFFFF),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMembersChip() {
    final count = widget.members.isEmpty ? 1 : widget.members.length;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _act(widget.onShowMembers),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(.40),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withOpacity(.16)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.people_alt_outlined,
              size: 12,
              color: Color(0xE6FFFFFF),
            ),
            const SizedBox(width: 4),
            Text(
              '$count 人',
              style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: Color(0xE6FFFFFF),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayButton(VideoPlayerController? controller, bool ready) {
    if (!ready) return const SizedBox.shrink();
    final playing = controller?.value.isPlaying == true;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _act(widget.onTogglePlay),
      child: Container(
        width: 62,
        height: 62,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(.38),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withOpacity(.34)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(.25),
              blurRadius: 18,
            ),
          ],
        ),
        child: Icon(
          widget.isHost
              ? (playing ? Icons.pause_rounded : Icons.play_arrow_rounded)
              : Icons.lock_outline_rounded,
          size: 32,
          color: Colors.white.withOpacity(.96),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final duration = widget.duration > 0 ? widget.duration : 0.0;
    final shown = (_dragPosition ?? widget.position)
        .clamp(0.0, duration <= 0 ? 0.0 : duration)
        .toDouble();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              togetherFmt(shown),
              style: _timeStyle,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _FsSeekBar(
                position: shown,
                duration: duration,
                enabled: widget.isHost,
                onBlocked: () => _act(widget.onHostOnly),
                onScrub: (value) {
                  if (!mounted) return;
                  setState(() => _dragPosition = value);
                  _showControls();
                },
                onSeek: (value) {
                  _showControls();
                  widget.onSeek(value);
                },
              ),
            ),
            const SizedBox(width: 8),
            Text(
              togetherFmt(duration),
              style: _timeStyle,
            ),
            const SizedBox(width: 8),
            _glassButton(
              Icons.fullscreen_exit_rounded,
              () => _act(widget.onExit),
              size: 30,
              iconSize: 17,
              tooltip: '退出全屏',
            ),
          ],
        ),
        if (!widget.isHost)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '跟随房主 · 进度由房主统一控制',
              style: TextStyle(
                fontSize: 8.5,
                color: Colors.white.withOpacity(.62),
              ),
            ),
          ),
      ],
    );
  }

  static const TextStyle _timeStyle = TextStyle(
    fontSize: 9.5,
    fontWeight: FontWeight.w600,
    color: Color(0xD9FFFFFF),
  );

  Widget _glassButton(
    IconData icon,
    VoidCallback onTap, {
    double size = 34,
    double iconSize = 16,
    String? tooltip,
  }) {
    final button = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(.38),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withOpacity(.20)),
        ),
        child: Icon(icon, size: iconSize, color: Colors.white),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}

/// 全屏时浮在视频上的聊天玻璃气泡。
class TogetherFloatingChat extends StatefulWidget {
  const TogetherFloatingChat({
    super.key,
    required this.messages,
    required this.members,
    required this.online,
  });

  final List<TogetherChatMessage> messages;
  final List<TogetherMember> members;
  final bool online;

  @override
  State<TogetherFloatingChat> createState() => _TogetherFloatingChatState();
}

class _TogetherFloatingChatState extends State<TogetherFloatingChat> {
  final ScrollController _scroll = ScrollController();

  bool _collapsed = false;
  int _unread = 0;
  Offset? _offset;

  String _signature = '';
  String _hintUser = '';
  String _hintText = '';
  String _hintAvatar = '';
  bool _hintVisible = false;
  Timer? _hintTimer;

  @override
  void initState() {
    super.initState();
    _signature = _lastSignature(widget.messages);
    _scrollToBottom(jump: true);
  }

  @override
  void didUpdateWidget(covariant TogetherFloatingChat oldWidget) {
    super.didUpdateWidget(oldWidget);
    final signature = _lastSignature(widget.messages);
    if (signature == _signature) return;
    _signature = signature;
    if (widget.messages.isEmpty) return;
    final message = widget.messages.last;
    if (message.system) {
      _scrollToBottom();
      return;
    }
    if (message.mine) {
      _scrollToBottom();
      return;
    }
    _showHint(message, countUnread: _collapsed);
    _scrollToBottom();
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  String _lastSignature(List<TogetherChatMessage> messages) {
    if (messages.isEmpty) return '';
    final last = messages.last;
    return '${last.time.microsecondsSinceEpoch}|${last.user}|'
        '${last.text}|${last.system}';
  }

  void _showHint(TogetherChatMessage message, {bool countUnread = false}) {
    if (message.text.trim().isEmpty) return;
    _hintTimer?.cancel();
    setState(() {
      _hintUser = message.user.isEmpty ? '影迷' : message.user;
      _hintText = message.text;
      _hintAvatar = message.avatar;
      _hintVisible = true;
      if (countUnread) _unread++;
    });
    _hintTimer = Timer(const Duration(milliseconds: 2800), () {
      if (!mounted) return;
      setState(() => _hintVisible = false);
    });
  }

  void _scrollToBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _collapsed || !_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (jump) {
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

  void _toggleCollapsed() {
    _hintTimer?.cancel();
    setState(() {
      _collapsed = !_collapsed;
      _hintVisible = false;
      if (!_collapsed) _unread = 0;
    });
    if (!_collapsed) _scrollToBottom(jump: true);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final pad = media.padding;
    final keyboard = media.viewInsets.bottom;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final width = math.min(320.0, math.max(240.0, size.width * .34));
        final expandedHeight =
            math.min(320.0, math.max(150.0, size.height * .66));
        final height = _collapsed ? 46.0 : expandedHeight;
        final minLeft = pad.left + 10;
        final minTop = pad.top + 10;
        final maxLeft = math.max(minLeft, size.width - pad.right - width - 10);
        final maxTop = math.max(
          minTop,
          size.height - pad.bottom - keyboard - height - 68,
        );

        var offset = _offset ?? Offset(maxLeft, maxTop);
        offset = Offset(
          offset.dx.clamp(minLeft, maxLeft).toDouble(),
          offset.dy.clamp(minTop, maxTop).toDouble(),
        );
        _offset = offset;

        return Stack(
          children: [
            Positioned(
              left: offset.dx,
              top: offset.dy,
              width: width,
              child: _buildBubble(
                minLeft: minLeft,
                maxLeft: maxLeft,
                minTop: minTop,
                maxTop: maxTop,
                expandedHeight: expandedHeight,
              ),
            ),
            Positioned(
              left: pad.left + 16,
              right: pad.right + 16,
              top: pad.top + 56,
              child: IgnorePointer(
                ignoring: !_hintVisible,
                child: AnimatedOpacity(
                  opacity: _hintVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: AnimatedSlide(
                    offset: _hintVisible ? Offset.zero : const Offset(0, -.28),
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOut,
                    child: Center(child: _buildHint()),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBubble({
    required double minLeft,
    required double maxLeft,
    required double minTop,
    required double maxTop,
    required double expandedHeight,
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(.30),
            blurRadius: 26,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            height: _collapsed ? null : expandedHeight,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xD91C2534),
                  Color(0xA6101722),
                ],
              ),
              border: Border.all(color: Colors.white.withOpacity(.24)),
            ),
            child: Column(
              mainAxisSize: _collapsed ? MainAxisSize.min : MainAxisSize.max,
              children: [
                _buildHeader(
                  minLeft: minLeft,
                  maxLeft: maxLeft,
                  minTop: minTop,
                  maxTop: maxTop,
                ),
                if (!_collapsed) ...[
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: Colors.white.withOpacity(.12),
                  ),
                  Expanded(child: _buildMessages()),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader({
    required double minLeft,
    required double maxLeft,
    required double minTop,
    required double maxTop,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleCollapsed,
      onPanUpdate: (details) {
        final current = _offset ?? Offset(maxLeft, maxTop);
        final next = current + details.delta;
        setState(() {
          _offset = Offset(
            next.dx.clamp(minLeft, maxLeft).toDouble(),
            next.dy.clamp(minTop, maxTop).toDouble(),
          );
        });
      },
      child: SizedBox(
        height: 46,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Icon(
                Icons.drag_indicator_rounded,
                size: 15,
                color: Colors.white.withOpacity(.42),
              ),
              const SizedBox(width: 4),
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: widget.online
                      ? const Color(0xFF57D3A3)
                      : const Color(0xFFFF8A80),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              const Text(
                '聊天',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '${widget.members.isEmpty ? 1 : widget.members.length}人',
                style: TextStyle(
                  fontSize: 9,
                  color: Colors.white.withOpacity(.58),
                ),
              ),
              const Spacer(),
              if (_unread > 0) _buildUnreadBadge(),
              if (_unread > 0) const SizedBox(width: 5),
              Icon(
                _collapsed
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: Colors.white.withOpacity(.72),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUnreadBadge() {
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: Fx.brand,
        borderRadius: BorderRadius.circular(9),
        boxShadow: [
          BoxShadow(
            color: Fx.accent.withOpacity(.40),
            blurRadius: 8,
          ),
        ],
      ),
      child: Text(
        _unread > 99 ? '99+' : '$_unread',
        style: const TextStyle(
          fontSize: 8.5,
          fontWeight: FontWeight.w800,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildMessages() {
    if (widget.messages.isEmpty) {
      return Center(
        child: Text(
          '还没有人说话，来打个招呼吧',
          style: TextStyle(
            fontSize: 10.5,
            color: Colors.white.withOpacity(.56),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: widget.messages.length,
      itemBuilder: (context, index) {
        return _buildMessageRow(widget.messages[index]);
      },
    );
  }

  Widget _buildMessageRow(TogetherChatMessage message) {
    if (message.system) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Align(
          alignment: Alignment.center,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${message.text}  ${togetherClock(message.time)}',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 8.5,
                height: 1.35,
                color: Colors.white.withOpacity(.62),
              ),
            ),
          ),
        ),
      );
    }

    final name =
        message.mine ? '我' : (message.user.isEmpty ? '影迷' : message.user);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TogetherAvatar(
            name: name,
            avatar: message.avatar,
            size: 24,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          color: message.mine
                              ? const Color(0xFFB9D0FF)
                              : Colors.white.withOpacity(.88),
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      togetherClock(message.time),
                      style: TextStyle(
                        fontSize: 8,
                        color: Colors.white.withOpacity(.38),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: message.mine
                        ? Fx.accent.withOpacity(.36)
                        : Colors.white.withOpacity(.13),
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(10),
                      topRight: const Radius.circular(10),
                      bottomLeft: Radius.circular(message.mine ? 10 : 3),
                      bottomRight: Radius.circular(message.mine ? 3 : 10),
                    ),
                    border: Border.all(
                      color: Colors.white.withOpacity(.10),
                    ),
                  ),
                  child: Text(
                    message.text,
                    style: const TextStyle(
                      fontSize: 11,
                      height: 1.4,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHint() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        _hintTimer?.cancel();
        setState(() {
          _collapsed = false;
          _unread = 0;
          _hintVisible = false;
        });
        _scrollToBottom(jump: true);
      },
      child: Container(
        constraints: const BoxConstraints(maxWidth: 460),
        padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
        decoration: BoxDecoration(
          color: const Color(0xD9161C26),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withOpacity(.20)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(.34),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TogetherAvatar(
              name: _hintUser,
              avatar: _hintAvatar,
              size: 24,
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '$_hintUser：',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    TextSpan(
                      text: _hintText,
                      style: TextStyle(color: Colors.white.withOpacity(.84)),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 全屏底部进度条：细线 + 白色圆点，只有房主可以拖动。
class _FsSeekBar extends StatefulWidget {
  const _FsSeekBar({
    required this.position,
    required this.duration,
    required this.enabled,
    required this.onSeek,
    required this.onBlocked,
    required this.onScrub,
  });

  final double position;
  final double duration;
  final bool enabled;
  final ValueChanged<double> onSeek;
  final VoidCallback onBlocked;
  final ValueChanged<double?> onScrub;

  @override
  State<_FsSeekBar> createState() => _FsSeekBarState();
}

class _FsSeekBarState extends State<_FsSeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final max = widget.duration > 0 ? widget.duration : 0.0;
    final shown =
        (_drag ?? widget.position).clamp(0.0, max <= 0 ? 1.0 : max).toDouble();
    return LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth <= 0 ? 1.0 : box.maxWidth;
        final ratio = max <= 0 ? 0.0 : (shown / max).clamp(0.0, 1.0);

        double valueAt(double dx) {
          if (max <= 0) return 0;
          return (dx / width).clamp(0.0, 1.0) * max;
        }

        void scrub(double value) {
          setState(() => _drag = value);
          widget.onScrub(value);
        }

        void finish() {
          final value = _drag;
          setState(() => _drag = null);
          widget.onScrub(null);
          if (value != null) widget.onSeek(value);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.enabled ? null : widget.onBlocked,
          onTapUp: widget.enabled
              ? (details) {
                  final value = valueAt(details.localPosition.dx);
                  setState(() => _drag = null);
                  widget.onScrub(null);
                  widget.onSeek(value);
                }
              : null,
          onHorizontalDragStart: widget.enabled
              ? (details) => scrub(valueAt(details.localPosition.dx))
              : null,
          onHorizontalDragUpdate: widget.enabled
              ? (details) => scrub(valueAt(details.localPosition.dx))
              : null,
          onHorizontalDragEnd: widget.enabled ? (_) => finish() : null,
          onHorizontalDragCancel: widget.enabled
              ? () {
                  setState(() => _drag = null);
                  widget.onScrub(null);
                }
              : null,
          child: SizedBox(
            height: 22,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    height: 3,
                    width: width,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(.26),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: ratio.toDouble(),
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        gradient: Fx.brand,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment(ratio * 2 - 1, 0),
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(.30),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

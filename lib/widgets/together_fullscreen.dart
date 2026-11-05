import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../services/fx_player.dart';
import '../theme.dart';
import 'fs_panels.dart';
import 'player_more_panel.dart';
import 'player_theme.dart';
import 'together_chat.dart';
import 'together_ui.dart';

/// 一起看 · 全屏播放。
///
/// 横屏铺满视频，控件 3 秒自动隐藏；聊天默认收起为左下角一个 32dp 小圆钮，
/// 点开是半透明玻璃小面板（靠左下、内含消息与输入框），有新消息只亮红点。
class TogetherFullscreenView extends StatefulWidget {
  const TogetherFullscreenView({
    super.key,
    required this.controller,
    required this.chat,
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
    required this.onEpisodes,
    required this.onNext,
    required this.onQuality,
    required this.onInvite,
    required this.onExitRoom,
    required this.onSendChat,
  });

  final FxPlayer? controller;

  /// 聊天消息只在有新消息时更新，避免整页跟着进度刷新。
  final ValueListenable<List<TogetherChatMessage>> chat;
  final List<TogetherMember> members;
  final String roomCode;
  final String title;
  final int ep;
  final bool isHost;
  final bool online;
  final ValueListenable<double> position;
  final double duration;
  final VoidCallback onExit;
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onSeek;
  final VoidCallback onHostOnly;
  final VoidCallback onShowMembers;
  final VoidCallback onEpisodes;
  final VoidCallback onNext;
  final VoidCallback onQuality;
  final VoidCallback onInvite;
  final VoidCallback onExitRoom;

  /// 返回 false 表示发送失败，输入框会保留文字。
  final bool Function(String text) onSendChat;

  @override
  State<TogetherFullscreenView> createState() => _TogetherFullscreenViewState();
}

class _TogetherFullscreenViewState extends State<TogetherFullscreenView> {
  static const Duration _autoHide = Duration(seconds: 3);

  bool _controls = true;
  bool _locked = false;
  Timer? _hideTimer;
  double _rate = 1.0;

  /// 全屏默认撑满（cover）；关掉「撑满全屏」后 contain。
  bool _fillScreen = true;

  @override
  void initState() {
    super.initState();
    _rate = widget.controller?.rate ?? 1.0;
    _scheduleHide();
    unawaited(_loadFillScreen());
  }

  Future<void> _loadFillScreen() async {
    final value = await fxLoadFillScreen();
    if (!mounted) return;
    setState(() => _fillScreen = value);
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
    if (_locked) return;
    _hideTimer?.cancel();
    if (!_controls) setState(() => _controls = true);
    if (autoHide) _scheduleHide();
  }

  void _toggleControls() {
    if (_locked) return;
    if (_controls) {
      _hideTimer?.cancel();
      setState(() => _controls = false);
    } else {
      _showControls();
    }
  }

  void _lock() {
    _hideTimer?.cancel();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _locked = true;
      _controls = false;
    });
  }

  void _unlock() {
    setState(() {
      _locked = false;
      _controls = true;
    });
    _scheduleHide();
  }

  Future<void> _openSpeed() async {
    if (!widget.isHost) {
      _act(widget.onHostOnly);
      return;
    }
    final rate = await showFxSpeedSheet(context, _rate);
    if (!mounted || rate == null) return;
    setState(() => _rate = rate);
    final controller = widget.controller;
    if (controller != null) {
      unawaited(controller.setRate(rate));
    }
    _showControls();
  }

  void _onQualityTap() {
    if (!widget.isHost) {
      _act(widget.onHostOnly);
      return;
    }
    _act(widget.onQuality);
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
            Positioned.fill(
              child: FxPlayerSurface(
                player: controller,
                fit: _fillScreen ? BoxFit.cover : BoxFit.contain,
                // 字幕避开底部控件，也不压到聊天面板（面板被限制在字幕带上方）。
                subtitleBottom: 92,
              ),
            )
          else
            _buildPlaceholder(),
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _locked ? null : _toggleControls,
            ),
          ),
          AnimatedOpacity(
            opacity: _controls && !_locked ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            child: IgnorePointer(
              ignoring: !_controls || _locked,
              child: _buildControls(context, controller, ready),
            ),
          ),
          // 锁屏后只留解锁钮，聊天也一并收起。
          if (_locked)
            Positioned.fill(
              child: SafeArea(
                child: Align(
                  alignment: const Alignment(-.96, 0),
                  child: Opacity(
                    opacity: .66,
                    child: _glassButton(
                      Icons.lock_rounded,
                      _unlock,
                      size: 42,
                      iconSize: 20,
                      tooltip: '点击解锁',
                    ),
                  ),
                ),
              ),
            ),
          if (!_locked)
            Positioned.fill(
              child: ValueListenableBuilder<List<TogetherChatMessage>>(
                valueListenable: widget.chat,
                builder: (context, messages, _) => TogetherFloatingChat(
                  messages: messages,
                  members: widget.members,
                  online: widget.online,
                  onSendChat: widget.onSendChat,
                ),
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
    FxPlayer? controller,
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
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: _glassButton(
                Icons.lock_outline_rounded,
                _lock,
                size: 38,
                iconSize: 18,
                tooltip: '锁定屏幕',
              ),
            ),
          ),
        ),
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 12, 0),
            child: Column(
              children: [
                _buildTopBar(context),
                Expanded(
                  child: Center(
                    child: _buildPlayButton(controller, ready),
                  ),
                ),
                ValueListenableBuilder<double>(
                  valueListenable: widget.position,
                  builder: (context, position, _) => FsBottomBar(
                    position: Duration(
                      milliseconds: (position * 1000).round(),
                    ),
                    duration: Duration(
                      milliseconds:
                          (widget.duration.clamp(0, 86400) * 1000).round(),
                    ),
                    playing: controller?.value.isPlaying == true,
                    rate: _rate,
                    qualityLabel: _qualityLabel(controller),
                    onSeek: (d) {
                      _showControls();
                      widget.onSeek(d.inMilliseconds / 1000.0);
                    },
                    onTogglePlay: () => _act(widget.onTogglePlay),
                    onNext: () => _act(widget.onNext),
                    onSpeed: () => unawaited(_openSpeed()),
                    onQuality: _onQualityTap,
                    onEpisodes: () => _act(widget.onEpisodes),
                    onExit: () => _act(widget.onExit),
                    compact: MediaQuery.sizeOf(context).width < 700,
                    bottomInset: MediaQuery.paddingOf(context).bottom,
                  ),
                ),
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
        const SizedBox(width: 6),
        _glassButton(
          Icons.group_add_rounded,
          () => _act(widget.onInvite),
          size: 28,
          iconSize: 15,
          tooltip: '邀请好友',
        ),
        const SizedBox(width: 4),
        _glassButton(
          Icons.logout_rounded,
          () => _act(widget.onExitRoom),
          size: 28,
          iconSize: 15,
          tooltip: '退出房间',
        ),
      ],
    );
  }

  String _qualityLabel(FxPlayer? controller) {
    final label = fxPlayerQuality(controller);
    return label.isEmpty ? '清晰度' : label;
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
    final count = widget.members.length;
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

  Widget _buildPlayButton(FxPlayer? controller, bool ready) {
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

/// 全屏聊天：收起时只在左下角留一个 32dp 玻璃圆钮（未读亮红点）；
/// 点开后弹出小面板，宽 ≤ 屏宽 40%、高 ≤ 屏高 45%，靠左下，
/// 面板内含消息列表和输入框，可拖动、再点圆钮收起。
class TogetherFloatingChat extends StatefulWidget {
  const TogetherFloatingChat({
    super.key,
    required this.messages,
    required this.members,
    required this.online,
    required this.onSendChat,
  });

  final List<TogetherChatMessage> messages;
  final List<TogetherMember> members;
  final bool online;

  /// 返回 false 表示发送失败，输入框会保留文字。
  final bool Function(String text) onSendChat;

  @override
  State<TogetherFloatingChat> createState() => _TogetherFloatingChatState();
}

class _TogetherFloatingChatState extends State<TogetherFloatingChat> {
  /// 默认收起后画面上只剩这个 32dp 小圆钮。
  static const double _fabSize = 32;

  /// 展开面板宽高上限（同时不超过屏宽 40% / 屏高 45%）。
  static const double _panelWidthMax = 340;
  static const double _panelHeightMax = 340;

  final ScrollController _scroll = ScrollController();

  bool _open = false;
  int _unread = 0;

  /// 面板拖动后的左上角；null 表示停在默认的左下角。
  Offset? _offset;
  String _signature = '';

  @override
  void initState() {
    super.initState();
    _signature = _lastSignature(widget.messages);
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
      if (_open) _scrollToBottom();
      return;
    }
    if (!_open) {
      // 收起时新消息只在圆钮上显示红点，不弹任何遮挡画面的提示。
      if (!message.mine) setState(() => _unread++);
      return;
    }
    // 展开时跟随新消息；用户正翻旧消息就不抢滚动。
    if (_nearBottom) _scrollToBottom();
  }

  /// 当前是否贴着底部；用户在翻旧消息时不抢滚动。
  bool get _nearBottom {
    if (!_scroll.hasClients) return true;
    final position = _scroll.position;
    if (!position.hasContentDimensions) return true;
    return position.maxScrollExtent - position.pixels < 36;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String _lastSignature(List<TogetherChatMessage> messages) {
    if (messages.isEmpty) return '';
    final last = messages.last;
    return '${last.time.microsecondsSinceEpoch}|${last.user}|'
        '${last.text}|${last.system}';
  }

  void _scrollToBottom({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_open || !_scroll.hasClients) return;
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

  void _toggleOpen() {
    setState(() {
      _open = !_open;
      if (_open) {
        _unread = 0;
        _offset = null;
      }
    });
    if (_open) {
      _scrollToBottom(jump: true);
    } else {
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  void _drag(
    Offset delta, {
    required double minLeft,
    required double maxLeft,
    required double minTop,
    required double maxTop,
  }) {
    final current = _offset ?? Offset(minLeft, maxTop);
    final next = current + delta;
    setState(() {
      _offset = Offset(
        next.dx.clamp(minLeft, maxLeft).toDouble(),
        next.dy.clamp(minTop, maxTop).toDouble(),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final pad = media.padding;
    final keyboard = media.viewInsets.bottom;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final width = math.min(_panelWidthMax, size.width * .40);
        // 圆钮靠左下，抬到底部控制栏（进度条 + 按钮行）上方，避免互相遮挡。
        final fabBottom = pad.bottom + 104;
        // 面板默认在圆钮上方；键盘弹出时抬到键盘上方，输入框不被挡。
        final openBottom = keyboard > 0
            ? math.max(pad.bottom + 144, keyboard + 8)
            : pad.bottom + 144;
        final height = math.min(
          _panelHeightMax,
          math.min(
            size.height * .45,
            math.max(
              96.0,
              size.height - openBottom - pad.top - 8,
            ),
          ),
        );

        final minLeft = pad.left + 8;
        final minTop = pad.top + 8;
        final maxLeft = math.max(minLeft, size.width - pad.right - width - 8);
        final maxTop = math.max(
          minTop,
          size.height - openBottom - height,
        );
        var offset = _offset ?? Offset(minLeft, maxTop);
        offset = Offset(
          offset.dx.clamp(minLeft, maxLeft).toDouble(),
          offset.dy.clamp(minTop, maxTop).toDouble(),
        );
        _offset = offset;

        return Stack(
          children: [
            if (_open)
              Positioned(
                left: offset.dx,
                top: offset.dy,
                width: width,
                child: _buildPanel(
                  width: width,
                  height: height,
                  minLeft: minLeft,
                  maxLeft: maxLeft,
                  minTop: minTop,
                  maxTop: maxTop,
                ),
              ),
            Positioned(
              left: pad.left + 14,
              bottom: fabBottom,
              child: _buildFab(),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFab() {
    return Semantics(
      button: true,
      label: _open ? '收起聊天' : '打开聊天',
      child: Tooltip(
        message: _open ? '收起聊天' : '聊天',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleOpen,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: _fabSize,
                height: _fabSize,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(.42),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withOpacity(.24)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(.25),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Icon(
                  _open
                      ? Icons.close_rounded
                      : Icons.chat_bubble_outline_rounded,
                  size: 16,
                  color: Colors.white.withOpacity(.94),
                ),
              ),
              if (_unread > 0 && !_open)
                Positioned(
                  right: -1,
                  top: -1,
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF4D4F),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.black.withOpacity(.55),
                        width: 1.2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPanel({
    required double width,
    required double height,
    required double minLeft,
    required double maxLeft,
    required double minTop,
    required double maxTop,
  }) {
    return Container(
      width: width,
      height: height,
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
              children: [
                _buildHeader(
                  minLeft: minLeft,
                  maxLeft: maxLeft,
                  minTop: minTop,
                  maxTop: maxTop,
                ),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: Colors.white.withOpacity(.12),
                ),
                Expanded(child: _buildMessages()),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: Colors.white.withOpacity(.12),
                ),
                _TogetherFullscreenComposer(
                  onSend: widget.onSendChat,
                ),
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
      onPanUpdate: (details) => _drag(
        details.delta,
        minLeft: minLeft,
        maxLeft: maxLeft,
        minTop: minTop,
        maxTop: maxTop,
      ),
      child: SizedBox(
        height: 38,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9),
          child: Row(
            children: [
              Icon(
                Icons.drag_indicator_rounded,
                size: 14,
                color: Colors.white.withOpacity(.42),
              ),
              const SizedBox(width: 2),
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: widget.online
                      ? const Color(0xFF57D3A3)
                      : const Color(0xFFFF8A80),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
              const Text(
                '聊天',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '${widget.members.length}人',
                style: TextStyle(
                  fontSize: 9,
                  color: Colors.white.withOpacity(.58),
                ),
              ),
              const Spacer(),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleOpen,
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: Colors.white.withOpacity(.72),
                ),
              ),
            ],
          ),
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
            fontSize: 10,
            color: Colors.white.withOpacity(.56),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
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
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Align(
          alignment: Alignment.center,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
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
                fontSize: 8,
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
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TogetherAvatar(
            name: name,
            avatar: message.avatar,
            size: 22,
          ),
          const SizedBox(width: 6),
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
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: message.mine
                              ? const Color(0xFFB9D0FF)
                              : Colors.white.withOpacity(.88),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      togetherClock(message.time),
                      style: TextStyle(
                        fontSize: 7.5,
                        color: Colors.white.withOpacity(.38),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
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
                      fontSize: 10.5,
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
}

/// 聊天面板内部输入条：窄面板里单行显示，发送失败保留文字并可重试。
class _TogetherFullscreenComposer extends StatefulWidget {
  const _TogetherFullscreenComposer({required this.onSend});

  final bool Function(String text) onSend;

  @override
  State<_TogetherFullscreenComposer> createState() =>
      _TogetherFullscreenComposerState();
}

class _TogetherFullscreenComposerState
    extends State<_TogetherFullscreenComposer> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
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

  void _submit() {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    final accepted = widget.onSend(text);
    if (!mounted) return;
    if (accepted) {
      _text.clear();
      setState(() => _failed = false);
    } else {
      setState(() {
        _failed = true;
        _failedText = text;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasText = _text.text.trim().isNotEmpty;
    final canSend = _failed || hasText;
    return Container(
      height: 36,
      margin: const EdgeInsets.fromLTRB(7, 6, 7, 7),
      padding: const EdgeInsets.fromLTRB(9, 0, 3, 0),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.42),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(.22)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _text,
              focusNode: _focus,
              minLines: 1,
              maxLines: 1,
              maxLength: 300,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _submit(),
              buildCounter: (
                _, {
                required currentLength,
                required isFocused,
                maxLength,
              }) =>
                  null,
              style: const TextStyle(fontSize: 11, color: Colors.white),
              cursorColor: Colors.white,
              decoration: InputDecoration(
                isDense: true,
                counterText: '',
                hintText: '发条弹幕…',
                hintStyle: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withOpacity(.44),
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 9),
              ),
            ),
          ),
          if (_failed)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _submit,
              child: Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.14),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.refresh_rounded,
                  size: 14,
                  color: Colors.white,
                ),
              ),
            ),
          const SizedBox(width: 3),
          GestureDetector(
            onTap: canSend ? _submit : null,
            child: Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: canSend ? Fx.brand : null,
                color: canSend ? null : Colors.white.withOpacity(.13),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _failed ? Icons.refresh_rounded : Icons.arrow_upward_rounded,
                size: 15,
                color: canSend ? Colors.white : Colors.white.withOpacity(.42),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

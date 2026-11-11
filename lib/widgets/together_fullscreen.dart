import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../models.dart';
import '../services/fx_player.dart';
import '../theme.dart';
import 'fs_controls.dart';
import 'player_gestures.dart';
import 'player_theme.dart';
import 'together_chat.dart';
import 'together_ui.dart';

/* ========================================================================== */
/*  一起看 · 全屏一起看                                                       */
/*                                                                            */
/*  与播放器全屏同一套控件规范（顶栏 / 左右侧锁屏与 ±10s / 底部进度条 / 3 秒    */
/*  自动隐藏 / 锁屏 / 手势层）。聊天只保留左下角 32dp 圆钮（未读红点），点开    */
/*  是 ≤40%×45% 的小面板，消息和输入都在面板内，没有横条输入框。               */
/* ========================================================================== */

class TogetherFullscreenView extends StatefulWidget {
  const TogetherFullscreenView({
    super.key,
    required this.player,
    required this.position,
    required this.chat,
    required this.members,
    required this.roomCode,
    required this.title,
    required this.cover,
    required this.ep,
    required this.episodes,
    required this.isHost,
    required this.online,
    required this.loading,
    required this.errorText,
    required this.qualityLabel,
    required this.qualityKey,
    required this.canChangeQuality,
    required this.qualities,
    required this.rate,
    required this.videoBoundaryKey,
    required this.videoEpoch,
    required this.frozenFrame,
    required this.frozenFrameOpaque,
    required this.onExit,
    required this.onExitRoom,
    required this.onInvite,
    required this.onMembers,
    required this.onSwitchLine,
    required this.onChangeDrama,
    required this.onTogglePlay,
    required this.onSeek,
    required this.onSeekBy,
    required this.onNext,
    required this.onEpisodes,
    required this.onRate,
    required this.onQuality,
    required this.onRetry,
    required this.onHostOnly,
    required this.onSendChat,
    this.isLive = false,
  });

  final FxPlayer? player;
  final ValueListenable<double> position;
  final ValueListenable<List<TogetherChatMessage>> chat;
  final List<TogetherMember> members;

  final String roomCode;
  final String title;
  final String cover;
  final int ep;
  final List<Episode> episodes;

  final bool isHost;
  final bool online;
  final bool loading;
  final String errorText;

  final String qualityLabel;
  final String? qualityKey;
  final bool canChangeQuality;
  final List<QualityItem> qualities;
  final double rate;

  /// 视频最后一帧：切剧 / 切集 / 换线路时顶住黑屏，首帧就绪后淡出。
  final GlobalKey videoBoundaryKey;
  final int videoEpoch;
  final ui.Image? frozenFrame;
  final bool frozenFrameOpaque;

  final VoidCallback onExit;
  final VoidCallback onExitRoom;
  final VoidCallback onInvite;
  final VoidCallback onMembers;

  /// 顶栏换源 / 换剧；页面统一做房主校验，成员点击提示「跟随房主」。
  final VoidCallback onSwitchLine;
  final VoidCallback onChangeDrama;

  /// 页面统一做房主校验；成员点击时页面提示「跟随房主」。
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onSeek;
  final ValueChanged<int> onSeekBy;
  final VoidCallback onNext;
  final VoidCallback onEpisodes;
  final ValueChanged<double> onRate;
  final ValueChanged<String?> onQuality;
  final VoidCallback onRetry;
  final VoidCallback onHostOnly;
  final bool Function(String text) onSendChat;

  /// 直播房：隐藏进度 / 选集 / 倍速 / 换剧，显示 LIVE。
  final bool isLive;

  @override
  State<TogetherFullscreenView> createState() => _TogetherFullscreenViewState();
}

class _TogetherFullscreenViewState extends State<TogetherFullscreenView> {
  bool _controls = true;
  Timer? _hideTimer;

  bool _locked = false;
  bool _unlockVisible = false;
  Timer? _unlockTimer;

  bool _showSpeed = false;
  bool _showQuality = false;

  bool _holding = false;
  double? _rateBeforeHold;

  bool _chatOpen = false;
  int _unread = 0;
  int _seenCount = 0;
  String _lastMessageKey = '';

  /// 聊天面板拖动后的位置（dx=左距 / dy=底距，左下为原点）；
  /// null 表示没拖过，跟随安全区与键盘自动摆放。
  Offset? _chatPos;

  @override
  void initState() {
    super.initState();
    _syncChatState(reset: true);
    widget.chat.addListener(_onChatChanged);
    _scheduleHide();
  }

  @override
  void didUpdateWidget(covariant TogetherFullscreenView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chat != widget.chat) {
      oldWidget.chat.removeListener(_onChatChanged);
      widget.chat.addListener(_onChatChanged);
      _syncChatState(reset: true);
    }
    if (oldWidget.loading && !widget.loading) _wake();
  }

  @override
  void dispose() {
    widget.chat.removeListener(_onChatChanged);
    _hideTimer?.cancel();
    _unlockTimer?.cancel();
    // 长按快进中直接退出全屏时，把倍速恢复成进入长按前的值。
    if (_holding) {
      final player = widget.player;
      final restore = _rateBeforeHold ?? widget.rate;
      if (player != null && player.value.isInitialized) {
        unawaited(player.setRate(restore));
      }
      _holding = false;
    }
    super.dispose();
  }

  /* ------------------------------------------------------------ 聊天未读 */

  String _messageKey(List<TogetherChatMessage> messages) {
    if (messages.isEmpty) return '';
    final last = messages.last;
    return '${messages.length}|${last.time.microsecondsSinceEpoch}|'
        '${last.user}|${last.text}|${last.system}';
  }

  void _syncChatState({bool reset = false}) {
    final messages = widget.chat.value;
    final key = _messageKey(messages);
    _lastMessageKey = key;
    _seenCount = messages.length;
    if (reset) _unread = 0;
  }

  void _onChatChanged() {
    final messages = widget.chat.value;
    final key = _messageKey(messages);
    if (key == _lastMessageKey) return;
    final previous = _seenCount;
    final previousKey = _lastMessageKey;
    _lastMessageKey = key;
    _seenCount = messages.length;
    if (messages.isEmpty) {
      _unread = 0;
    } else if (_chatOpen) {
      _unread = 0;
    } else if (previousKey.isNotEmpty && messages.length > previous) {
      _unread = math.min(99, _unread + messages.length - previous);
    } else if (previousKey.isNotEmpty) {
      // 列表裁剪后长度不变，但最后一条变了：仍算一条新消息。
      _unread = math.min(99, _unread + 1);
    } else {
      _unread = math.min(99, _unread + 1);
    }
    if (mounted) setState(() {});
  }

  /* ------------------------------------------------------------ 控件显隐 */

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(togetherFullscreenControlsAutoHide, () {
      if (!mounted) return;
      if (_locked || _chatOpen || _showSpeed || _showQuality) return;
      if (_controls) setState(() => _controls = false);
    });
  }

  void _wake() {
    if (_locked) return;
    _hideTimer?.cancel();
    if (!_controls && mounted) setState(() => _controls = true);
    _scheduleHide();
  }

  void _hideControls() {
    _hideTimer?.cancel();
    if (mounted) {
      setState(() {
        _controls = false;
        _showSpeed = false;
        _showQuality = false;
      });
    }
  }

  void _toggleControls() {
    if (_chatOpen) {
      _closeChat();
      return;
    }
    if (_controls) {
      _hideControls();
    } else {
      _wake();
    }
  }

  void _onSurfaceTap() {
    if (_locked) return;
    _toggleControls();
  }

  void _seekTo(double seconds) {
    widget.onSeek(seconds);
    _wake();
  }

  /* ------------------------------------------------------------ 锁屏 */

  void _unlock() {
    _unlockTimer?.cancel();
    setState(() {
      _locked = false;
      _unlockVisible = false;
    });
    _wake();
  }

  void _startUnlockTimer() {
    _unlockTimer?.cancel();
    _unlockTimer = Timer(togetherUnlockAutoHide, () {
      if (!mounted || !_locked) return;
      setState(() => _unlockVisible = false);
    });
  }

  void _onLockedTap() {
    if (_unlockVisible) {
      _unlockTimer?.cancel();
      setState(() => _unlockVisible = false);
    } else {
      setState(() => _unlockVisible = true);
      _startUnlockTimer();
    }
  }

  /* ------------------------------------------------------------ 长按 3x */

  void _startHold() {
    if (!widget.isHost) {
      widget.onHostOnly();
      return;
    }
    final player = widget.player;
    if (player == null || !player.value.isInitialized) return;
    _rateBeforeHold = player.rate;
    unawaited(player.setRate(3.0));
    _hideTimer?.cancel();
    setState(() {
      _holding = true;
      _controls = false;
      _showSpeed = false;
      _showQuality = false;
    });
  }

  void _endHold() {
    if (!_holding) return;
    final player = widget.player;
    final restore = _rateBeforeHold ?? widget.rate;
    _rateBeforeHold = null;
    if (player != null && player.value.isInitialized) {
      unawaited(player.setRate(restore));
    }
    if (!mounted) {
      _holding = false;
      return;
    }
    setState(() => _holding = false);
  }

  /* ------------------------------------------------------------ 弹层 / 聊天 */

  void _openChat() {
    FocusScope.of(context).unfocus();
    _hideTimer?.cancel();
    setState(() {
      _chatOpen = true;
      _controls = false;
      _showSpeed = false;
      _showQuality = false;
      _unread = 0;
    });
  }

  void _closeChat() {
    FocusScope.of(context).unfocus();
    setState(() => _chatOpen = false);
    _wake();
  }

  /* ------------------------------------------------------------ 布局 */

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final player = widget.player;
    final ready = player != null && player.value.isInitialized;

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildVideo(player, pad, ready),
          if (!_locked && player != null)
            Positioned.fill(
              child: FxPlayerGestures(
                player: player,
                enabled: widget.errorText.isEmpty,
                enableSeek: !widget.isLive,
                onTap: _onSurfaceTap,
                onDoubleTap: _wake,
                onSeek: (value) => _seekTo(value.inMilliseconds / 1000.0),
                onLongPressStart: _startHold,
                onLongPressEnd: _endHold,
                onGestureStart: _hideControls,
                resetBrightnessOnDispose: true,
              ),
            ),
          if (!widget.loading && widget.errorText.isEmpty && ready)
            Positioned.fill(
              child: AnimatedBuilder(
                animation: player,
                builder: (context, _) {
                  final value = player.value;
                  if (!value.isInitialized || !value.isBuffering) {
                    return const SizedBox.shrink();
                  }
                  // 只认 libmpv cache-buffering-state 的真实填充进度；
                  // 拿不到就不显示数字，只给「缓冲中…」+ 不确定转圈。
                  final percent = value.bufferingPercent;
                  return FxLoadingOverlay(
                    title: percent == null ? '缓冲中…' : '缓冲中 ${percent.round()}%',
                    percent: percent,
                    speedText: value.speedText,
                    dim: false,
                    compact: true,
                  );
                },
              ),
            ),
          if (widget.loading)
            Positioned.fill(
              child: widget.player == null
                  ? FxLoadingOverlay(
                      title: fxLoadingEpisodeText(widget.ep),
                      dim: widget.frozenFrame == null,
                    )
                  : AnimatedBuilder(
                      animation: widget.player!,
                      builder: (context, _) => FxLoadingOverlay(
                        title: fxLoadingEpisodeText(widget.ep),
                        percent: widget.player!.value.bufferingPercent,
                        speedText: widget.player!.value.speedText,
                        // 有最后一帧时不再压暗，让切换过程继续看得到画面。
                        dim: widget.frozenFrame == null,
                      ),
                    ),
            ),
          if (!_locked)
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_controls,
                child: AnimatedOpacity(
                  opacity: _controls ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: _buildControls(player, pad),
                ),
              ),
            ),
          if (widget.errorText.isNotEmpty)
            Positioned.fill(child: _buildError()),
          // 掉线 / 重连期间：顶栏常驻小标，不弹 toast、不打断观看。
          if (!widget.online)
            Positioned(
              top: pad.top + 8,
              left: 0,
              right: 0,
              child: const IgnorePointer(
                child: Center(child: _ReconnectBadge()),
              ),
            ),
          if (!_locked) _buildChatLayer(pad, keyboard),
          if (_locked)
            Positioned.fill(
              child: SafeArea(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _onLockedTap,
                      child: const SizedBox.expand(),
                    ),
                    if (_unlockVisible) FsUnlockButton(onUnlock: _unlock),
                  ],
                ),
              ),
            ),
          if (_holding)
            Positioned(
              top: pad.top + 10,
              left: 0,
              right: 0,
              child: const Center(
                child: _FsBadge(text: '3.0x 快进中'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildVideo(FxPlayer? player, EdgeInsets pad, bool ready) {
    final controlsHeight = 100.0 + pad.bottom;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (player == null || !ready) ...[
          const ColoredBox(color: Colors.black),
          if (widget.cover.startsWith('http'))
            IgnorePointer(
              child: Opacity(
                opacity: .26,
                child: TogetherCover(
                  cover: widget.cover,
                  title: widget.title,
                  radius: 0,
                  showTitle: false,
                ),
              ),
            ),
        ] else
          ClipRect(
            child: SizedBox.expand(
              child: RepaintBoundary(
                key: widget.videoBoundaryKey,
                child: FxPlayerSurface(
                  key: ValueKey<int>(widget.videoEpoch),
                  player: player,
                  subtitleBottom: controlsHeight + 12,
                ),
              ),
            ),
          ),
        // 切剧 / 切集 / 换线路：最后一帧淡出，真实画面淡入，不黑屏闪。
        if (widget.frozenFrame != null)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: widget.frozenFrameOpaque ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: FxAspectBox(
                  child: (context, fit) => RawImage(
                    image: widget.frozenFrame,
                    fit: fit,
                    filterQuality: FilterQuality.low,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 一起看全屏的控件全部交给 betterplayer 内置。
  ///
  /// 原来这里是 FsTopBar + FsSideControls + FsQualityPanel + FsSpeedPanel
  /// + FsBottomBar 一整套自绘控件，换成 betterplayer 后会和内置控件叠成
  /// 上下两层（用户报的「新旧两个重叠」）。只保留左上角返回 + 房间信息。
  Widget _buildControls(FxPlayer? player, EdgeInsets pad) {
    return Positioned(
      left: 0,
      top: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded,
                    color: Colors.white, size: 22),
                tooltip: '返回',
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black.withValues(alpha: .38),
                ),
                onPressed: widget.onExit,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  Widget _buildError() {
    return Container(
      color: Colors.black.withValues(alpha: .46),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 340),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .96),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .20),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, color: Fx.sub, size: 28),
            const SizedBox(height: 6),
            Text(
              widget.errorText,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Fx.ink,
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _errorAction('重试', widget.onRetry),
                const SizedBox(width: 10),
                _errorAction('退出全屏', widget.onExit),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorAction(String text, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          gradient: Fx.brand,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Fx.accent.withValues(alpha: .25),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  /* ------------------------------------------------------------ 聊天层 */

  Widget _buildChatLayer(EdgeInsets pad, double keyboard) {
    if (!_chatOpen) {
      return Positioned(
        left: 14,
        bottom: 118 + pad.bottom,
        child: _buildChatFab(),
      );
    }
    final size = MediaQuery.sizeOf(context);
    final maxWidth = math.min(size.width * .40, 420.0);
    final maxHeight = math.min(size.height * .45, 420.0);
    final available = keyboard > 0
        ? math.max(130.0, size.height - keyboard - pad.top - 24)
        : size.height - pad.top - pad.bottom - 24;
    final panelHeight = math.min(maxHeight, available);
    final bottom = keyboard > 0 ? keyboard + 10 : 14 + pad.bottom;
    // 面板可拖动：记录左下角位置并夹回屏内（键盘弹起时不低于键盘）。
    final origin = Offset(14, bottom);
    final pos = _chatPos ?? origin;
    final minDx = 8.0;
    final maxDx = math.max(minDx, size.width - maxWidth - 8);
    final minDy = keyboard > 0 ? keyboard + 8 : 8.0;
    final maxDy = math.max(minDy, size.height - panelHeight - 8);
    final left = pos.dx.clamp(minDx, maxDx).toDouble();
    final dy = pos.dy.clamp(minDy, maxDy).toDouble();
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _closeChat,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: left,
          bottom: dy,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: Container(
              width: maxWidth,
              height: panelHeight,
              decoration: BoxDecoration(
                color: const Color(0xFFF7FAFF).withValues(alpha: .96),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white.withValues(alpha: .92)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .28),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 6, 4),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanUpdate: (d) => setState(
                          () => _chatPos = (_chatPos ?? origin) + d.delta,
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.forum_rounded,
                              size: 14,
                              color: Fx.accent,
                            ),
                            const SizedBox(width: 5),
                            const Expanded(
                              child: Text(
                                '聊天',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: Fx.ink,
                                ),
                              ),
                            ),
                            Text(
                              widget.online
                                  ? '${widget.members.length} 人'
                                  : '重连中',
                              style: TextStyle(
                                fontSize: 9,
                                color: Fx.sub.withValues(alpha: .9),
                              ),
                            ),
                            const SizedBox(width: 2),
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _closeChat,
                              child: Container(
                                width: 24,
                                height: 24,
                                alignment: Alignment.center,
                                child: Icon(
                                  Icons.close_rounded,
                                  size: 15,
                                  color: Fx.sub.withValues(alpha: .8),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: ValueListenableBuilder<List<TogetherChatMessage>>(
                        valueListenable: widget.chat,
                        builder: (context, messages, _) => TogetherChatList(
                          messages: messages,
                          compact: true,
                        ),
                      ),
                    ),
                    TogetherComposer(
                      compact: true,
                      enabled: true,
                      hint: widget.online ? '说点什么…' : '正在重连…',
                      onSend: widget.onSendChat,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChatFab() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _openChat,
      child: Tooltip(
        message: '聊天',
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .52),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withValues(alpha: .32)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .18),
                    blurRadius: 12,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: const Icon(
                Icons.forum_outlined,
                size: 17,
                color: Colors.white,
              ),
            ),
            if (_unread > 0)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  constraints:
                      const BoxConstraints(minWidth: 12, minHeight: 12),
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF5252),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.white, width: 1),
                  ),
                  child: Text(
                    _unread > 9 ? '9+' : '$_unread',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 7.5,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 顶部 / 中央短提示胶囊（3.0x 快进中）。
/// 全屏一起看顶栏的 LIVE 胶囊。
class _LivePill extends StatelessWidget {
  const _LivePill();

  @override
  Widget build(BuildContext context) {
    return PGlassPill(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 6, color: Color(0xFFFF5A5A)),
          SizedBox(width: 4),
          Text(
            'LIVE',
            style: TextStyle(
              color: Colors.white,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: .5,
              shadows: [Shadow(color: Colors.black54, blurRadius: 3)],
            ),
          ),
        ],
      ),
    );
  }
}

class _FsBadge extends StatelessWidget {
  const _FsBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .52),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: .28)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}


/// 掉线 / 自动重连期间的顶栏小标（常驻、不参与点击）。
class _ReconnectBadge extends StatelessWidget {
  const _ReconnectBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .52),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: .28)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 6, color: Color(0xFFFF8A80)),
          SizedBox(width: 5),
          Text('重连中',
            style: TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
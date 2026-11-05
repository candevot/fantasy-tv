import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../models.dart';
import '../services/fx_player.dart';
import '../theme.dart';
import 'fs_controls.dart';
import 'fs_panels.dart';
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

  bool _fillScreen = true;

  @override
  void initState() {
    super.initState();
    _syncChatState(reset: true);
    widget.chat.addListener(_onChatChanged);
    _scheduleHide();
    unawaited(_loadFillScreen());
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

  Future<void> _loadFillScreen() async {
    final value = await fxLoadFillScreen();
    if (!mounted) return;
    setState(() => _fillScreen = value);
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

  void _togglePlay() {
    widget.onTogglePlay();
    _wake();
  }

  void _seekTo(double seconds) {
    widget.onSeek(seconds);
    _wake();
  }

  void _seekBy(int seconds) {
    widget.onSeekBy(seconds);
    _wake();
  }

  /* ------------------------------------------------------------ 锁屏 */

  void _lock() {
    FocusScope.of(context).unfocus();
    _hideTimer?.cancel();
    _unlockTimer?.cancel();
    setState(() {
      _locked = true;
      _unlockVisible = true;
      _controls = false;
      _chatOpen = false;
      _showSpeed = false;
      _showQuality = false;
    });
    _endHold();
    _startUnlockTimer();
  }

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

  void _toggleSpeed() {
    if (!widget.isHost) {
      widget.onHostOnly();
      return;
    }
    _hideTimer?.cancel();
    setState(() {
      _showSpeed = !_showSpeed;
      _showQuality = false;
      _controls = true;
    });
    if (!_showSpeed) _scheduleHide();
  }

  void _toggleQuality() {
    if (!widget.isHost) {
      widget.onHostOnly();
      return;
    }
    if (!widget.canChangeQuality) {
      togetherToast(context, '当前线路暂无更多清晰度');
      return;
    }
    _hideTimer?.cancel();
    setState(() {
      _showQuality = !_showQuality;
      _showSpeed = false;
      _controls = true;
    });
    if (!_showQuality) _scheduleHide();
  }

  void _openSpeedPanel(double value) {
    widget.onRate(value);
    setState(() => _showSpeed = false);
    _wake();
  }

  void _openQualityPanel(String? key) {
    widget.onQuality(key);
    setState(() => _showQuality = false);
    _wake();
  }

  void _runHost(VoidCallback action) {
    if (!widget.isHost) {
      widget.onHostOnly();
      return;
    }
    action();
    _wake();
  }

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
                  // 真实已缓冲位置 ÷ 总时长；时长未知时用不确定转圈，
                  // 不能把 bufferingPercentage 当百分比直接写到 100%。
                  final percent = fxBufferedPercent(
                    value.buffered,
                    value.duration,
                  );
                  return FxLoadingOverlay(
                    title: percent == null ? '加载中…' : '缓冲中 ${percent.round()}%',
                    percent: percent,
                    dim: false,
                    compact: true,
                  );
                },
              ),
            ),
          if (widget.loading)
            Positioned.fill(
              child: FxLoadingOverlay(title: fxLoadingEpisodeText(widget.ep)),
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
                  fit: _fillScreen ? BoxFit.cover : BoxFit.contain,
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
                duration: const Duration(milliseconds: 300),
                child: RawImage(
                  image: widget.frozenFrame,
                  fit: _fillScreen ? BoxFit.cover : BoxFit.contain,
                  filterQuality: FilterQuality.low,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildControls(FxPlayer? player, EdgeInsets pad) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _buildTopBar(pad),
        ),
        Positioned.fill(
          child: FsSideControls(
            onLock: _lock,
            onSeekBy: _seekBy,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_showQuality)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FsQualityPanel(
                      items: widget.qualities,
                      currentKey: widget.qualityKey,
                      showSource: true,
                      onPick: _openQualityPanel,
                    ),
                  ),
                ),
              if (_showSpeed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FsSpeedPanel(
                      rate: widget.rate,
                      onPick: _openSpeedPanel,
                    ),
                  ),
                ),
              _buildBottomBar(player, pad),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTopBar(EdgeInsets pad) {
    return Container(
      padding: EdgeInsets.fromLTRB(14, 8, 10, 18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withOpacity(.52), Colors.black.withOpacity(0)],
        ),
      ),
      child: Row(
        children: [
          PGlassIcon(
            icon: Icons.arrow_back_ios_new_rounded,
            size: 34,
            iconSize: 17,
            tint: .16,
            tooltip: '退出全屏',
            onTap: widget.onExit,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.title.trim().isEmpty ? '一起看' : widget.title.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _epLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 7),
          PGlassIcon(
            icon: Icons.alt_route_rounded,
            size: 32,
            iconSize: 17,
            tooltip: '换源',
            onTap: widget.onSwitchLine,
          ),
          const SizedBox(width: 7),
          PGlassIcon(
            icon: Icons.movie_filter_rounded,
            size: 32,
            iconSize: 17,
            tooltip: '换剧',
            onTap: widget.onChangeDrama,
          ),
          if (widget.qualityLabel.isNotEmpty) ...[
            const SizedBox(width: 12),
            FsQualityPill(label: widget.qualityLabel),
          ],
          const SizedBox(width: 8),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onMembers,
            child: PGlassPill(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.people_alt_outlined,
                    size: 13,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${widget.members.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      shadows: [Shadow(color: Colors.black54, blurRadius: 3)],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 7),
          PGlassIcon(
            icon: Icons.person_add_alt_1_rounded,
            size: 32,
            iconSize: 17,
            tooltip: '邀请好友',
            onTap: widget.onInvite,
          ),
          const SizedBox(width: 7),
          PGlassIcon(
            icon: Icons.logout_rounded,
            size: 32,
            iconSize: 17,
            tooltip: widget.isHost ? '解散房间' : '退出房间',
            onTap: widget.onExitRoom,
          ),
        ],
      ),
    );
  }

  String get _epLabel {
    for (final episode in widget.episodes) {
      if (episode.n == widget.ep) {
        return fxEpisodeLabel(episode.n, episode.name);
      }
    }
    return fxEpisodeLabel(widget.ep);
  }

  Widget _buildBottomBar(FxPlayer? player, EdgeInsets pad) {
    final compact = MediaQuery.sizeOf(context).width < 700;
    return AnimatedBuilder(
      animation: player ?? const AlwaysStoppedAnimation<double>(0),
      builder: (context, _) {
        final value = player?.value;
        return ValueListenableBuilder<double>(
          valueListenable: widget.position,
          builder: (context, position, _) {
            final shown = Duration(
              milliseconds:
                  (position.isFinite && position > 0 ? position * 1000 : 0)
                      .round(),
            );
            return FsBottomBar(
              position: shown,
              duration: value?.duration ?? Duration.zero,
              buffered: value?.buffered ?? Duration.zero,
              playing: value?.isInitialized == true && value!.isPlaying,
              rate: widget.rate,
              qualityLabel: widget.canChangeQuality ? '清晰度' : '',
              qualityActive:
                  widget.canChangeQuality && widget.qualityKey != null,
              compact: compact,
              bottomInset: pad.bottom,
              onSeek: (target) => _seekTo(target.inMilliseconds / 1000.0),
              onTogglePlay: _togglePlay,
              onNext: () => _runHost(widget.onNext),
              onSpeed: _toggleSpeed,
              onQuality: _toggleQuality,
              onEpisodes: () => _runHost(widget.onEpisodes),
              onExit: widget.onExit,
            );
          },
        );
      },
    );
  }

  Widget _buildError() {
    return Container(
      color: Colors.black.withOpacity(.46),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 340),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.96),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(.20),
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
              color: Fx.accent.withOpacity(.25),
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
          left: 14,
          bottom: bottom,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: Container(
              width: maxWidth,
              height: panelHeight,
              decoration: BoxDecoration(
                color: const Color(0xFFF7FAFF).withOpacity(.96),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white.withOpacity(.92)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(.28),
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
                              color: Fx.sub.withOpacity(.9),
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
                                color: Fx.sub.withOpacity(.8),
                              ),
                            ),
                          ),
                        ],
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
                color: Colors.black.withOpacity(.52),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white.withOpacity(.32)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(.18),
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
class _FsBadge extends StatelessWidget {
  const _FsBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.52),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(.28)),
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

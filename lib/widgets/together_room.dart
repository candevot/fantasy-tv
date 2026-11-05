import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../models.dart';
import '../services/fx_player.dart';
import '../theme.dart';
import 'player_theme.dart';
import 'together_chat.dart';
import 'together_ui.dart';

/* ========================================================================== */
/*  一起看 · 竖屏房间页                                                       */
/*                                                                            */
/*  结构：顶部栏（返回/房间号/成员/邀请/换剧选集）→ 固定高度视频区 →            */
/*        剧名·集数·成员头像 → 聊天列表（占剩余高度）→ 底部输入条。            */
/*  视频区高度只由屏幕高度决定，不随键盘变化；键盘只压缩聊天列表。             */
/* ========================================================================== */

class TogetherRoomView extends StatefulWidget {
  const TogetherRoomView({
    super.key,
    required this.player,
    required this.position,
    required this.chat,
    required this.roomCode,
    required this.roomTitle,
    required this.videoTitle,
    required this.cover,
    required this.ep,
    required this.episodes,
    required this.members,
    required this.isHost,
    required this.online,
    required this.loading,
    required this.errorText,
    required this.onBack,
    required this.onCopyCode,
    required this.onInvite,
    required this.onMembers,
    required this.onMedia,
    required this.onTogglePlay,
    required this.onSeek,
    required this.onEnterFullscreen,
    required this.onSendChat,
    required this.onRetry,
    required this.onHostOnly,
  });

  final FxPlayer? player;
  final ValueListenable<double> position;
  final ValueListenable<List<TogetherChatMessage>> chat;

  final String roomCode;
  final String roomTitle;
  final String videoTitle;
  final String cover;
  final int ep;
  final List<Episode> episodes;
  final List<TogetherMember> members;

  final bool isHost;
  final bool online;
  final bool loading;
  final String errorText;

  final VoidCallback onBack;
  final VoidCallback onCopyCode;
  final VoidCallback onInvite;
  final VoidCallback onMembers;
  final VoidCallback onMedia;

  /// 页面统一做房主校验：成员点击时提示「跟随房主」。
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onSeek;
  final VoidCallback onEnterFullscreen;
  final bool Function(String text) onSendChat;
  final VoidCallback onRetry;

  /// 成员操作被拒绝时的统一提示。
  final VoidCallback onHostOnly;

  @override
  State<TogetherRoomView> createState() => _TogetherRoomViewState();
}

class _TogetherRoomViewState extends State<TogetherRoomView> {
  bool _controls = true;
  Timer? _hideTimer;
  DateTime? _lastTapAt;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void didUpdateWidget(covariant TogetherRoomView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.loading && !widget.loading) _wake();
    if (oldWidget.errorText != widget.errorText &&
        widget.errorText.isNotEmpty) {
      _wake();
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(togetherControlsAutoHide, () {
      if (!mounted) return;
      if (_controls) setState(() => _controls = false);
    });
  }

  void _wake() {
    _hideTimer?.cancel();
    if (!_controls && mounted) setState(() => _controls = true);
    _scheduleHide();
  }

  void _toggleControls() {
    final show = !_controls;
    _hideTimer?.cancel();
    if (mounted) setState(() => _controls = show);
    if (show) _scheduleHide();
  }

  /// 单击显隐控件；300ms 内第二次点击 = 双击播放/暂停（页面做房主校验）。
  void _onSurfaceTapUp(TapUpDetails details) {
    final now = DateTime.now();
    final last = _lastTapAt;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 300)) {
      _lastTapAt = null;
      widget.onTogglePlay();
      _wake();
      return;
    }
    _lastTapAt = now;
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

  String get _epLabel {
    for (final episode in widget.episodes) {
      if (episode.n == widget.ep) {
        return fxEpisodeLabel(episode.n, episode.name);
      }
    }
    return fxEpisodeLabel(widget.ep);
  }

  String get _title {
    if (widget.videoTitle.trim().isNotEmpty) return widget.videoTitle.trim();
    if (widget.roomTitle.trim().isNotEmpty) return widget.roomTitle.trim();
    return '一起看';
  }

  int get _episodeCount {
    final main = fxMainEpisodeCount(widget.episodes);
    return main > 0 ? main : widget.episodes.length;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom > 0;
    final fixedVideoHeight = math.max(
      togetherRoomVideoMin,
      media.size.height * togetherRoomVideoRatio,
    );
    final chromeEstimate =
        52.0 + (keyboard ? 0.0 : 78.0) + 68.0 + media.padding.bottom;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 极矮屏幕 + 键盘的兜底：优先保证输入条和视频区仍然存在。
        var videoHeight = fixedVideoHeight;
        final overflow = videoHeight + chromeEstimate - constraints.maxHeight;
        if (overflow > 0) {
          videoHeight = math.max(togetherRoomVideoMin, videoHeight - overflow);
        }
        return Column(
          children: [
            _buildHeader(context),
            SizedBox(
              height: videoHeight,
              child: _buildVideo(context),
            ),
            if (!keyboard) _buildInfo(context),
            Expanded(child: _buildChat(context)),
            SafeArea(
              top: false,
              child: TogetherComposer(
                enabled: true,
                compact: keyboard,
                hint: widget.online ? '说点什么…' : '正在重连，消息会保留可重试',
                onSend: widget.onSendChat,
              ),
            ),
          ],
        );
      },
    );
  }

  /* ------------------------------------------------------------ 顶部栏 */

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 10, 6),
      child: Row(
        children: [
          TogetherCircleButton(
            icon: Icons.arrow_back_ios_new_rounded,
            size: 34,
            iconSize: 15,
            onTap: widget.onBack,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onCopyCode,
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      '房间 ${widget.roomCode.isEmpty ? '——' : widget.roomCode}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: Fx.ink,
                        letterSpacing: .2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.copy_rounded,
                    size: 12,
                    color: Fx.sub.withOpacity(.65),
                  ),
                  if (!widget.online) ...[
                    const SizedBox(width: 5),
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: Color(0xFFFF8A80),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          TogetherPill(
            text: '${widget.members.length}',
            icon: Icons.people_alt_outlined,
            height: 30,
            onTap: widget.onMembers,
          ),
          const SizedBox(width: 6),
          TogetherPill(
            text: '邀请',
            icon: Icons.person_add_alt_1_rounded,
            height: 30,
            accent: true,
            onTap: widget.onInvite,
          ),
          const SizedBox(width: 6),
          TogetherPill(
            text: '换剧/选集',
            icon: Icons.swap_horiz_rounded,
            height: 30,
            locked: !widget.isHost,
            onTap: widget.onMedia,
          ),
        ],
      ),
    );
  }

  /* ------------------------------------------------------------ 视频区 */

  Widget _buildVideo(BuildContext context) {
    final player = widget.player;
    final ready = player != null && player.value.isInitialized;
    final hasCover = widget.cover.startsWith('http');
    return Container(
      color: Colors.black,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (!ready && hasCover)
              IgnorePointer(
                child: Opacity(
                  opacity: .34,
                  child: TogetherCover(
                    cover: widget.cover,
                    title: _title,
                    radius: 0,
                    showTitle: false,
                  ),
                ),
              ),
            if (ready)
              FxPlayerSurface(
                player: player,
                fit: BoxFit.contain,
                subtitleBottom: 76,
              )
            else
              _buildVideoPlaceholder(),
            if (widget.loading)
              const Positioned.fill(
                child: FxLoadingOverlay(
                  title: '正在加载视频…',
                  dim: false,
                  compact: true,
                ),
              ),
            if (ready)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: _onSurfaceTapUp,
                  child: const SizedBox.expand(),
                ),
              ),
            if (ready)
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: !_controls,
                  child: AnimatedOpacity(
                    opacity: _controls ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: _buildOverlay(player),
                  ),
                ),
              ),
            // 连接 / 同步状态常驻左上角，不参与控件显隐。
            Positioned(
              left: 8,
              top: 8,
              child: IgnorePointer(child: _buildSyncChip()),
            ),
            if (widget.errorText.isNotEmpty)
              Positioned.fill(child: _buildError(context)),
          ],
        ),
      ),
    );
  }

  Widget _buildOverlay(FxPlayer player) {
    final playing = player.value.isPlaying;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          left: 8,
          right: 8,
          bottom: 6,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              PGlassIcon(
                icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: 34,
                iconSize: 20,
                tint: .20,
                tooltip: playing ? '暂停' : '播放',
                onTap: _togglePlay,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _RoomProgress(
                  position: widget.position,
                  duration: player.value.duration,
                  enabled: widget.isHost,
                  onSeek: _seekTo,
                  onBlocked: widget.onHostOnly,
                ),
              ),
              const SizedBox(width: 6),
              PGlassIcon(
                icon: Icons.fullscreen_rounded,
                size: 32,
                iconSize: 19,
                tint: .20,
                tooltip: '全屏一起看',
                onTap: () {
                  _wake();
                  widget.onEnterFullscreen();
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSyncChip() {
    final stateText = widget.isHost ? '房主' : '跟随房主';
    final dot =
        widget.online ? const Color(0xFF57D3A3) : const Color(0xFFFF8A80);
    final status = widget.online ? stateText : '连接中…';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.46),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withOpacity(.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(
            status,
            style: const TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              color: Color(0xE6FFFFFF),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoPlaceholder() {
    final loading = widget.loading;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            loading ? Icons.movie_filter_rounded : Icons.ondemand_video_rounded,
            size: 30,
            color: Colors.white.withOpacity(.45),
          ),
          const SizedBox(height: 8),
          Text(
            loading ? '正在加载视频…' : (widget.isHost ? '点击播放，和朋友一起看' : '等待房主播放'),
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withOpacity(.72),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    return Container(
      color: Colors.black.withOpacity(.34),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 330),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: const Color(0xFF1B2430).withOpacity(.92),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(.16)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              size: 24,
              color: Colors.white70,
            ),
            const SizedBox(height: 6),
            Text(
              widget.errorText,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _errorAction('重试', widget.onRetry),
                if (widget.isHost) ...[
                  const SizedBox(width: 10),
                  _errorAction('换剧/选集', widget.onMedia),
                ],
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          gradient: Fx.brand,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  /* ------------------------------------------------------------ 信息区 */

  Widget _buildInfo(BuildContext context) {
    final count = _episodeCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: togetherGlass(radius: 16, opacity: .62),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: Fx.ink,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  count > 0 ? '$_epLabel · 共 $count 集' : _epLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: Fx.sub.withOpacity(.92),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 28,
                    child: widget.members.isEmpty
                        ? Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '等待成员加入',
                              style: TextStyle(
                                fontSize: 10,
                                color: Fx.sub.withOpacity(.7),
                              ),
                            ),
                          )
                        : ListView.separated(
                            scrollDirection: Axis.horizontal,
                            physics: const BouncingScrollPhysics(),
                            itemCount: widget.members.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 5),
                            itemBuilder: (context, i) {
                              final member = widget.members[i];
                              return Tooltip(
                                message: member.host
                                    ? '${member.name}（房主）'
                                    : member.name,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: widget.onMembers,
                                  child: TogetherAvatar(
                                    name: member.name,
                                    avatar: member.avatar,
                                    size: 26,
                                    host: member.host,
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ),
                const SizedBox(width: 6),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onMembers,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.people_outline_rounded,
                        size: 12,
                        color: Fx.sub.withOpacity(.8),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '${widget.members.length} 人',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                          color: Fx.sub.withOpacity(.9),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /* ------------------------------------------------------------ 聊天 */

  Widget _buildChat(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Container(
        decoration: togetherGlass(radius: 18, opacity: .60),
        clipBehavior: Clip.antiAlias,
        child: ValueListenableBuilder<List<TogetherChatMessage>>(
          valueListenable: widget.chat,
          builder: (context, messages, _) =>
              TogetherChatList(messages: messages),
        ),
      ),
    );
  }
}

/* ========================================================================== */
/*  房间视频区进度条：房主可拖，成员拖动只提示「跟随房主」                      */
/* ========================================================================== */

class _RoomProgress extends StatefulWidget {
  const _RoomProgress({
    required this.position,
    required this.duration,
    required this.enabled,
    required this.onSeek,
    required this.onBlocked,
  });

  final ValueListenable<double> position;
  final Duration duration;
  final bool enabled;
  final ValueChanged<double> onSeek;
  final VoidCallback onBlocked;

  @override
  State<_RoomProgress> createState() => _RoomProgressState();
}

class _RoomProgressState extends State<_RoomProgress> {
  DateTime? _lastBlockedAt;

  void _blocked() {
    final now = DateTime.now();
    final last = _lastBlockedAt;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 900)) {
      return;
    }
    _lastBlockedAt = now;
    widget.onBlocked();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: widget.position,
      builder: (context, position, _) {
        final clamped = position.isFinite && position > 0 ? position : 0.0;
        final total = widget.duration.inMilliseconds / 1000.0;
        final duration = total.isFinite && total > 0 ? total : 0.0;
        final shown = Duration(milliseconds: (clamped * 1000).round());
        final all = Duration(milliseconds: (duration * 1000).round());
        final bar = PProgressBar(
          position: shown,
          duration: all,
          height: 3,
          touchHeight: 24,
          thumbSize: 10,
          showThumb: true,
          enabled: widget.enabled,
          onSeek: (value) => widget.onSeek(value.inMilliseconds / 1000.0),
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.enabled)
              bar
            else
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _blocked,
                onHorizontalDragStart: (_) => _blocked(),
                onHorizontalDragUpdate: (_) {},
                onHorizontalDragEnd: (_) {},
                child: IgnorePointer(
                  child: PProgressBar(
                    position: shown,
                    duration: all,
                    height: 3,
                    touchHeight: 24,
                    thumbSize: 10,
                    showThumb: true,
                    enabled: false,
                    onSeek: (_) {},
                  ),
                ),
              ),
            const SizedBox(height: 1),
            Row(
              children: [
                Text(
                  fxTime(shown),
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: Color(0xE6FFFFFF),
                    shadows: [Shadow(color: Colors.black54, blurRadius: 3)],
                  ),
                ),
                const Spacer(),
                if (!widget.enabled)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      '跟随房主',
                      style: TextStyle(
                        fontSize: 8.5,
                        color: Colors.white.withOpacity(.72),
                      ),
                    ),
                  ),
                Text(
                  fxTime(all),
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: Color(0xE6FFFFFF),
                    shadows: [Shadow(color: Colors.black54, blurRadius: 3)],
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

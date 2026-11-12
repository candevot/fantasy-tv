import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../models.dart';
import '../services/fx_player.dart';
import '../theme.dart';
import '../services/app_settings.dart';
import 'danmu_layer.dart';
import 'player_theme.dart';
import 'together_chat.dart';
import 'together_floating_chat.dart';
import 'together_ui.dart';

/* ========================================================================== */
/*  一起看 · 竖屏房间页                                                       */
/*                                                                            */
/*  结构：顶部栏（返回/房间号/成员/邀请/换源/换剧）→ 固定高度视频区 →          */
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
    required this.onSwitchLine,
    required this.onChangeDrama,
    required this.onEpisodes,
    required this.videoBoundaryKey,
    required this.videoEpoch,
    required this.frozenFrame,
    required this.frozenFrameOpaque,
    required this.onTogglePlay,
    required this.onSeek,
    required this.onEnterFullscreen,
    required this.onSendChat,
    required this.onRetry,
    required this.onHostOnly,
    this.onSyncToHost,
    this.syncOffsetSeconds = 0,
    this.keyboardVisible = false,
    this.isLive = false,
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

  /// 顶栏「换源 / 换剧」和视频区「选集」；页面统一做房主校验。
  final VoidCallback onSwitchLine;
  final VoidCallback onChangeDrama;
  final VoidCallback onEpisodes;

  /// 切剧 / 切集 / 换线路时保留的最后一帧，首帧就绪后淡出。
  final GlobalKey videoBoundaryKey;
  final int videoEpoch;
  final ui.Image? frozenFrame;
  final bool frozenFrameOpaque;

  /// 页面统一做房主校验：成员点击时提示「跟随房主」。
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onSeek;
  final VoidCallback onEnterFullscreen;
  final bool Function(String text) onSendChat;
  final VoidCallback onRetry;

  /// 成员操作被拒绝时的统一提示。
  final VoidCallback onHostOnly;

  /// 手动「同步房主进度」。成员侧显示；房主不需要（他就是权威）。
  final VoidCallback? onSyncToHost;

  /// 与房主的进度偏差（秒，正数=自己落后）。为 0 或房主时按钮不高亮。
  final double syncOffsetSeconds;

  /// 键盘是否弹起。由页面层（Scaffold 之上）读取 viewInsets 传入：
  /// Scaffold 在 resizeToAvoidBottomInset=true 时会把 body 的 viewInsets 清零。
  final bool keyboardVisible;

  /// 直播房：隐藏进度、选集、换剧，显示 LIVE。
  final bool isLive;

  @override
  State<TogetherRoomView> createState() => _TogetherRoomViewState();
}

class _TogetherRoomViewState extends State<TogetherRoomView> {
  bool _controls = true;
  Timer? _hideTimer;

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

  /// 点击画面只显隐控件，绝不播放 / 暂停。
  void _onSurfaceTap() => _toggleControls();

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
    final keyboard = widget.keyboardVisible;
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
        return Stack(
          children: [
            Column(
              children: [
                _buildHeader(context),
            SizedBox(
              height: videoHeight,
              child: _buildVideo(context),
            ),
            if (!keyboard) _buildInfo(context),
            // 聊天改成悬浮层（右下角小标志 + 透明气泡），不再占屏幕。
            // 观看时画面不被挤压，消息又不丢：未读数标在标志上。
            Expanded(
              child: Stack(
                children: [
                  // 键盘弹起时旧消息列表让位（气泡里能看到最新几条），
                  // 避免「列表 + 气泡 + 键盘」三份内容挤在一起。
                  if (!keyboard) _buildChat(context),
                ],
                  ),
                ),
              ],
            ),
            // 悬浮聊天叠在整页最上层：不受视频区 / 键盘压缩影响。
            // 注意不能 Positioned.fill —— 那样会铺满全屏挡住视频区手势
            // （点击暂停、双击全屏、拖动进度全都点不到）。这里让子组件
            // 自己用 Stack + 局部 Positioned 定位，只占它实际需要的那块。
            // 只让悬浮层自己那小块参与命中测试：TogetherFloatingChat 内部
            // 是 Stack，收起时只有小标志有 GestureDetector，其余区域不拦截，
            // 视频区手势照常。
            Positioned.fill(
              child: TogetherFloatingChat(
                chat: widget.chat,
                onSend: widget.onSendChat,
                enabled: widget.online,
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
                    color: Fx.sub.withValues(alpha: .65),
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
          // 手动对齐房主进度：成员侧才显示。偏差 >1 秒才高亮，
          // 平时保持低调，不抢「邀请 / 换源」的视觉位置。
          if (!widget.isHost && !widget.isLive && widget.onSyncToHost != null) ...[
            const SizedBox(width: 6),
            _SyncToHostPill(
              offsetSeconds: widget.syncOffsetSeconds,
              onTap: widget.onSyncToHost!,
            ),
          ],
          const SizedBox(width: 6),
          TogetherPill(
            text: widget.isLive ? '换线' : '换源',
            height: 30,
            locked: !widget.isHost,
            onTap: widget.onSwitchLine,
          ),
          if (!widget.isLive) ...[
            const SizedBox(width: 6),
            TogetherPill(
              text: '换剧',
              height: 30,
              locked: !widget.isHost,
              onTap: widget.onChangeDrama,
            ),
          ],
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
            // 弹幕层：小窗也支持（用户要求一起看、播放详情、全屏都有弹幕）
            if (ready && !widget.isLive)
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: player,
                  builder: (context, _) => ValueListenableBuilder<double>(
                    valueListenable: widget.position,
                    builder: (context, pos, _) => DanmuLayer(
                      title: widget.videoTitle,
                      ep: widget.ep,
                      epName: '',
                      position: Duration(
                        milliseconds:
                            (pos.isFinite && pos > 0 ? pos * 1000 : 0).round(),
                      ),
                      playing: player.value.isPlaying,
                      enabled: AppSettings.instance.danmuEnabled,
                      opacity: AppSettings.instance.danmuOpacity,
                      fontSize: AppSettings.instance.danmuFontSize,
                      areaRatio: 0.55,
                    ),
                  ),
                ),
              ),
            if (ready)
              RepaintBoundary(
                key: widget.videoBoundaryKey,
                child: FxPlayerSurface(
                  key: ValueKey<int>(widget.videoEpoch),
                  player: player,
                  subtitleBottom: 76,
                ),
              )
            else
              _buildVideoPlaceholder(),
            // 切剧 / 切集 / 换线路：最后一帧顶住，首帧就绪后淡出。
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
            if (widget.loading)
              Positioned.fill(
                child: FxLoadingOverlay(
                  title: widget.isLive ? '正在加载直播…' : '正在加载视频…',
                  dim: false,
                  compact: true,
                ),
              )
            else if (ready)
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
                      title:
                          percent == null ? '缓冲中…' : '缓冲中 ${percent.round()}%',
                      percent: percent,
                      dim: false,
                      compact: true,
                    );
                  },
                ),
              ),
            if (ready)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _onSurfaceTap,
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
              if (widget.isLive)
                const Expanded(child: _RoomLiveBadge())
              else
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
              if (!widget.isLive) ...[
                PGlassIcon(
                  icon: Icons.list_alt_rounded,
                  size: 32,
                  iconSize: 19,
                  tint: .20,
                  tooltip: '选集',
                  onTap: widget.onEpisodes,
                ),
                const SizedBox(width: 6),
              ],
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
    // 房间内掉线即进入自动重连（客户端会回原房间号），顶栏小标显示「重连中」。
    final status = widget.online ? stateText : '重连中';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .46),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: .16)),
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
            color: Colors.white.withValues(alpha: .45),
          ),
          const SizedBox(height: 8),
          Text(
            widget.isLive
                ? (loading ? '正在加载直播…' : '等待房主开始直播')
                : (loading
                    ? '正在加载视频…'
                    : (widget.isHost ? '点击播放，和朋友一起看' : '等待房主播放')),
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withValues(alpha: .72),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: .34),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 330),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: const Color(0xFF1B2430).withValues(alpha: .92),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: .16)),
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
                  _errorAction(
                    widget.isLive ? '换线路' : '换剧/选集',
                    widget.isLive ? widget.onSwitchLine : widget.onMedia,
                  ),
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
                  widget.isLive
                      ? '直播中'
                      : (count > 0 ? '$_epLabel · 共 $count 集' : _epLabel),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: widget.isLive
                        ? const Color(0xFFFF5A5A)
                        : Fx.sub.withValues(alpha: .92),
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
                                color: Fx.sub.withValues(alpha: .7),
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
                        color: Fx.sub.withValues(alpha: .8),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '${widget.members.length} 人',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                          color: Fx.sub.withValues(alpha: .9),
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

/// 直播房视频区底部的 LIVE 标识（替代进度条）。
class _RoomLiveBadge extends StatelessWidget {
  const _RoomLiveBadge();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFFFF4D4F).withValues(alpha: .20),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFFF6B6B).withValues(alpha: .5)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 6, color: Color(0xFFFF5A5A)),
            SizedBox(width: 5),
            Text(
              'LIVE',
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: .5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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
                        color: Colors.white.withValues(alpha: .72),
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

/// 「同步房主」按钮：显示与房主的进度偏差，点一下立刻对齐。
///
/// 设计取舍：一起看默认自动纠偏（倍速微调 + 超阈值硬跳），但网络差的一方
/// 偶尔会持续落后。与其让它反复自动硬跳，不如给用户一个明确的手动入口，
/// 偏差可见、一键追平，避免「一直来回跳」的观感。
class _SyncToHostPill extends StatelessWidget {
  const _SyncToHostPill({required this.offsetSeconds, required this.onTap});

  /// 正数 = 自己落后房主，负数 = 自己领先。
  final double offsetSeconds;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final off = offsetSeconds.abs();
    final behind = offsetSeconds > 0;
    // 1 秒以内算同步良好，不高亮、不显示秒数。
    final synced = off < 1.0;
    final label = synced
        ? '已同步'
        : '${behind ? '落后' : '领先'} ${off.toStringAsFixed(off >= 10 ? 0 : 1)}s';
    return TogetherPill(
      text: label,
      icon: synced
          ? Icons.check_circle_outline_rounded
          : Icons.sync_rounded,
      height: 30,
      // 不同步时才用强调色，平时是普通胶囊。
      accent: !synced,
      onTap: onTap,
    );
  }
}

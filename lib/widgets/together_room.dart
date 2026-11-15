import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../models.dart';
import '../services/fx_player.dart';
import '../theme.dart';
import 'fs_controls.dart';
import 'player_theme.dart';
import 'together_chat.dart';
import 'together_floating_chat.dart';
import 'together_top_actions.dart';
import 'together_ui.dart';

/* ========================================================================== */
/*  一起看 · 竖屏房间页                                                       */
/*                                                                            */
/*  结构：顶部栏（返回/房间号/成员/邀请/换源/换剧）→ 固定高度视频区 →          */
/*        剧名·集数·成员头像 → 聊天列表（占剩余高度）→ 底部输入条。            */
/*  视频区高度只由屏幕高度决定，不随键盘变化；键盘只压缩聊天列表。             */
/*  投屏不在一起看：入口已在页面层与两个视图里全部移除（2026-11-16）。          */
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
    required this.loadingText,
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
    required this.onSeekBegin,
    required this.onEnterFullscreen,
    required this.onSendChat,
    required this.onRetry,
    required this.onHostOnly,
    this.onSyncToHost,
    this.syncOffsetSeconds = 0,
    this.keyboardVisible = false,
    this.isLive = false,
    this.opText = '',
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

  /// 加载层文案：由页面用 [fxLoadingLineText] 生成（「正在加载 幻想蓝光 · 第01集」），
  /// 与主播放页逐字一致；空串时退回不带线路名的写法。
  final String loadingText;
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

  /// 手指按下进度条那一刻：页面拿它「接手主导权」，拖动途中不被别人的
  /// 1 秒心跳拽回去。
  final VoidCallback onSeekBegin;
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

  /// 最近一次房间操作：「小明 换了线路 → 幻想4K」。空串时整行不渲染。
  final String opText;

  @override
  State<TogetherRoomView> createState() => _TogetherRoomViewState();
}

class _TogetherRoomViewState extends State<TogetherRoomView> {
  /// ORIENT_FADE（2026-11-14）：横竖屏切换时压一层淡黑过渡。
  ///
  /// 竖屏 ↔ 横屏是布局重排，不压一下就是「画面突然跳成另一个样子」。
  /// 但不能给整页做缩放/位移 —— 里面是 PlatformView（ExoPlayer 原生视图），
  /// 混合合成下不跟随 Flutter 变换，只能做透明度。
  bool? _lastCompact;
  double _orientDim = 0;
  bool _controls = true;
  Timer? _hideTimer;

  /// 画面上的「谁操作的」小条：出现 3 秒后自动收起，不常驻挡画面。
  bool _opVisible = false;
  Timer? _opTimer;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void didUpdateWidget(covariant TogetherRoomView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.opText != widget.opText && widget.opText.isNotEmpty) {
      _showOpChip();
    }
    if (oldWidget.loading && !widget.loading) _wake();
    if (oldWidget.errorText != widget.errorText &&
        widget.errorText.isNotEmpty) {
      _wake();
    }
  }

  /// 顶部操作提示：显示 3 秒后自己淡出。
  void _showOpChip() {
    _opTimer?.cancel();
    if (mounted) setState(() => _opVisible = true);
    _opTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _opVisible = false);
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _opTimer?.cancel();
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
    // CHAT_FULLSCREEN（2026-11-14）：横屏（全屏播放）时不再渲染竖屏那块
    // 聊天列表 —— 它是一张浅色卡片，横屏时会压住画面。
    // 用布局约束判断，不用 MediaQuery：某些机型上旋转后 MediaQuery
    // 还没刷新，判断会失效（之前横屏聊天卡照样盖住视频就是这个原因）。
    final keyboard = widget.keyboardVisible;
    final fixedVideoHeight = math.max(
      togetherRoomVideoMin,
      media.size.height * togetherRoomVideoRatio,
    );
    final chromeEstimate =
        52.0 + (keyboard ? 0.0 : 78.0) + 68.0 + media.padding.bottom;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 高度小于 560 视为横屏（全屏）布局。
        //
        // ROOM_KEYBOARD（2026-11-15）：用**屏幕高度**判断，不看当前约束高度。
        // 竖屏房间是 `resizeToAvoidBottomInset: true`，键盘弹起后 constraints
        // 会被压掉 300dp 以上（800 → 500），按它算会误判成横屏：聊天面板
        // （连同刚补上的输入条）被整块隐藏 —— 用户一点输入框、键盘一起来，
        // 框就没了，等于竖屏还是聊不了天。屏幕高度不受键盘影响；旋转时它
        // 照样跟着变，横屏判定不受影响。
        final screenHeight = math.max(media.size.height, constraints.maxHeight);
        final compact = screenHeight < 560;
        if (_lastCompact != null && _lastCompact != compact) {
          _lastCompact = compact;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() => _orientDim = .6);
            Future<void>.delayed(const Duration(milliseconds: 140), () {
              if (mounted) setState(() => _orientDim = 0);
            });
          });
        } else {
          _lastCompact = compact;
        }
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
                SizedBox(height: videoHeight, child: _buildVideo(context)),
                if (!keyboard) _buildInfo(context),
                // 聊天改成悬浮层（右下角小标志 + 透明气泡），不再占屏幕。
                // 观看时画面不被挤压，消息又不丢：未读数标在标志上。
                Expanded(
                  child: Stack(
                    children: [
                      // CHAT_KEEP_TYPING（2026-11-15）：竖屏聊天面板（含输入条）
                      // 在键盘弹起时必须留在树里 —— 输入框一旦被移出 widget 树，
                      // 焦点立刻丢失、键盘随之收起，字打不进去。
                      // 键盘压缩的是这块 Expanded，视频区高度不变（见上面
                      // chromeEstimate 的兜底）。横屏（compact）仍然不渲染它，
                      // 那里用悬浮气泡。
                      if (!compact)
                        Positioned.fill(child: _buildChat(context)),
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
            // CHAT_NO_BUBBLE_PORTRAIT（2026-11-14）：竖屏已经有聊天面板，
            // 不需要再叠一层透明小窗；只有横屏（全屏）才用悬浮气泡。
            if (compact)
              Positioned.fill(
                child: TogetherFloatingChat(
                  chat: widget.chat,
                  onSend: widget.onSendChat,
                  enabled: widget.online,
                ),
              ),
            // 横竖屏切换的过渡：一层淡黑快速压下再抬起，
            // 把布局重排的跳变盖住（不能动 PlatformView 的变换）。
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _orientDim,
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  child: const ColoredBox(color: Colors.black),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /* ------------------------------------------------------------ 顶部栏 */

  /// 竖屏顶栏（TOPBAR_44 / 2026-11-16 用户实测重排）。
  ///
  /// 现场：`<- 房间 320551 (复制)   [1人][邀请][投屏][☆我在操作][换源][换剧]`
  /// —— 左边「房间 320551」占着一大片空白，右边 6 个胶囊被
  /// `FittedBox(scaleDown)` 硬压成一串小字（7~9sp、热区十几 dp），点不准。
  ///
  /// FS_MATCH_MAIN（2026-11-16）：**一起看不需要投屏** —— 竖屏那颗「投屏」
  /// 已整颗移除（CastService / CastSheet 本身不动，主播放页照旧在用），
  /// 全屏那边同样不出现。
  ///
  /// 现在的版式：
  ///   · 左：返回 + 房间号（复制图标同行）+ **内联状态**（我在操作 / 已同步 /
  ///     落后 x s）—— 状态本来就不是按钮，内联到左边就不再占一个按钮位；
  ///   · 右：只有真正要点的动作，邀请 / 换源 / 换剧常驻，1人按 priority
  ///     收进「更多」；每项热区 ≥44dp、字号 ≥12.5sp、图标 15dp；
  ///   · 放不下就**换行**（Wrap），绝不缩放 —— 见 [TogetherTopActionBar]。
  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          TogetherCircleButton(
            icon: Icons.arrow_back_ios_new_rounded,
            size: 34,
            iconSize: 15,
            tooltip: '退出房间',
            onTap: widget.onBack,
          ),
          const SizedBox(width: 2),
          // 左侧：房间号 + 复制 + 内联状态。Expanded 让它吃掉中间空白，
          // 右侧动作区按自身宽度贴右（不再用 Spacer 留一大片空）。
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onCopyCode,
              child: Row(
                children: <Widget>[
                  Flexible(
                    child: Text(
                      '房间 ${widget.roomCode.isEmpty ? '——' : widget.roomCode}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: Fx.ink,
                        letterSpacing: .2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 3),
                  Icon(
                    Icons.copy_rounded,
                    size: 13,
                    color: Fx.sub.withValues(alpha: .7),
                  ),
                  if (!widget.online) ...<Widget>[
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
                  if (!widget.isLive) ...<Widget>[
                    const SizedBox(width: 8),
                    Flexible(child: _buildInlineStatus()),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          // 右侧动作区：每一项都是 44dp 热区，放不下换行 / 进「更多」。
          //
          // TOPBAR_44：宽度预算按**屏幕宽度**算，不用 Expanded 平分 ——
          // 平分会让左侧房间号把剩余空间吃光，480dp 屏也会把「1人」挤进更多。
          TogetherTopActionBar(
            actions: _headerActions(),
            dark: false,
            maxWidth: togetherHeaderActionsBudget(
              MediaQuery.sizeOf(context).width,
            ),
          ),
        ],
      ),
    );
  }

  /// 顶栏左侧的内联状态（原来是「☆ 我在操作」/「已同步」那个胶囊）。
  ///
  /// 状态不是操作入口，占一个 44dp 按钮位太浪费：房主显示「我在操作」，
  /// 成员显示「已同步」或「落后 x.xs」；成员的落后项仍然可点（手动对齐）。
  Widget _buildInlineStatus() {
    if (widget.isHost) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.star_outline_rounded,
            size: 13,
            color: Fx.sub.withValues(alpha: .85),
          ),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              '我在操作',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Fx.sub.withValues(alpha: .9),
              ),
            ),
          ),
        ],
      );
    }
    final offset = widget.syncOffsetSeconds;
    final synced = offset.abs() < 1 || widget.onSyncToHost == null;
    final label = synced ? '已同步' : '落后 ${offset.toStringAsFixed(1)}s';
    final text = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          synced
              ? Icons.check_circle_outline_rounded
              : Icons.sync_problem_rounded,
          size: 13,
          color: synced
              ? Fx.sub.withValues(alpha: .8)
              : Fx.accent.withValues(alpha: .95),
        ),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: synced
                  ? Fx.sub.withValues(alpha: .85)
                  : Fx.accent.withValues(alpha: .95),
            ),
          ),
        ),
      ],
    );
    if (widget.onSyncToHost == null) return text;
    // 落后时给一个不占版面的点击区（44dp 高，视觉仍是文字）。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onSyncToHost,
      child: SizedBox(height: 44, child: Center(child: text)),
    );
  }

  /// 顶栏动作：邀请 / 换源 / 换剧常驻，1人按 priority 收进「更多」。
  ///
  /// 投屏不在这里：一起看整体没有投屏入口（用户明确要求）。
  List<TogetherActionItem> _headerActions() {
    return <TogetherActionItem>[
      TogetherActionItem(
        id: 'members',
        label: '${widget.members.length}人',
        icon: Icons.people_alt_outlined,
        showLabel: true,
        priority: 2,
        onTap: widget.onMembers,
      ),
      TogetherActionItem(
        id: 'invite',
        label: '邀请',
        icon: Icons.person_add_alt_1_rounded,
        showLabel: true,
        always: true,
        priority: 0,
        onTap: widget.onInvite,
      ),
      TogetherActionItem(
        id: 'line',
        label: widget.isLive ? '换线' : '换源',
        icon: Icons.alt_route_rounded,
        showLabel: true,
        always: true,
        priority: 1,
        onTap: widget.onSwitchLine,
      ),
      if (!widget.isLive)
        TogetherActionItem(
          id: 'drama',
          label: '换剧',
          icon: Icons.movie_filter_rounded,
          showLabel: true,
          always: true,
          priority: 1,
          onTap: widget.onChangeDrama,
        ),
    ];
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
              RepaintBoundary(
                key: widget.videoBoundaryKey,
                child: FxPlayerSurface(
                  key: ValueKey<int>(widget.videoEpoch),
                  player: player,
                  subtitleBottom: 76,
                ),
              )
            // 加载中不挂占位层：加载层已经有圆环 + 一行文案，两层叠在一起
            // 就是「两个加载动画」的观感（用户报过）。
            else if (!widget.loading)
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
            // 加载层：只跟着 widget.loading 走。
            //
            // FIRST_FRAME：这里不按「首帧是否渲染」加挂加载层 —— 一起看
            // 的房间会被同步纠偏频繁 seek，首帧标记每次 seek 都会回落到
            // false，挂上去就是每秒闪一次加载层。主播放页 / 全屏页才按
            // 首帧收放（那里没有自动纠偏 seek）。
            if (widget.loading)
              Positioned.fill(
                child: FxLoadingOverlay(
                  // 与主播放同一句「正在加载 线路名 · 第01集」；直播沿用原句。
                  title: widget.isLive
                      ? '正在加载直播…'
                      : (widget.loadingText.isEmpty
                            ? fxLoadingEpisodeText(widget.ep)
                            : widget.loadingText),
                  dim: widget.frozenFrame == null,
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
                    // FIRST_FRAME：首帧没上屏时由上面的加载层负责。
                    if (!value.hasRenderedFirstFrame) {
                      return const SizedBox.shrink();
                    }
                    // BUFFER_UI（2026-11-15）：转圈 + 实时网速，不画百分比。
                    return FxLoadingOverlay(
                      title: '缓冲中…',
                      speedText: fxSpeedLabel(
                        value.bytesLoadedPerSec > 0
                            ? value.bytesLoadedPerSec.toDouble()
                            : value.bytesPerSecond,
                      ),
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
            // 「谁操作的」：小明 换了线路 → 幻想4K
            //
            // OP_CHIP（2026-11-15）：放到画面顶部**居中**、宽度只包住文字，
            // 3 秒后自动淡出 —— 之前是左上角整行 8~屏宽，压住画面左上角
            // 那片（人脸 / 字幕起始位置）不放。完整的操作流水在聊天区里。
            if (_opVisible && widget.opText.isNotEmpty)
              Positioned(
                left: 24,
                right: 24,
                top: 10,
                child: IgnorePointer(
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: _opVisible ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 260),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .55),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          widget.opText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFFE6E9EF),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (widget.errorText.isNotEmpty)
              Positioned.fill(child: _buildError(context)),
          ],
        ),
      ),
    );
  }

  /// 画面上的控件条：**完全对齐主播放竖屏控件**
  /// （player_page 的 `_buildControls`）——
  /// 播放/暂停 30dp、进度条 3dp 粗 + 40dp 热区 + 15dp 白色圆钮、
  /// 全屏 30dp，同样的 tint .13、同样的 6dp 间距、同样的 tooltip 文案。
  /// 唯一的不同是命中框按 44dp 放（一起看画面小、手指更容易点空）。
  Widget _buildOverlay(FxPlayer player) {
    final playing = player.value.isPlaying;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned(
          left: 10,
          right: 8,
          bottom: 4,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              PGlassIcon.fs(
                icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                tooltip: playing ? '暂停' : '播放',
                onTap: _togglePlay,
              ),
              const SizedBox(width: 6),
              if (widget.isLive)
                const Expanded(child: _RoomLiveBadge())
              else
                Expanded(
                  child: _RoomProgress(
                    position: widget.position,
                    duration: player.value.duration,
                    // 谁都能拖：拖动会广播给房间（服务端只广播，不校验身份）。
                    onSeek: _seekTo,
                    onSeekBegin: widget.onSeekBegin,
                  ),
                ),
              const SizedBox(width: 6),
              if (!widget.isLive)
                FsTextAction(
                  text: '选集',
                  icon: Icons.list_alt_rounded,
                  tapHeight: 44,
                  onTap: widget.onEpisodes,
                ),
              const SizedBox(width: 6),
              PGlassIcon.fs(
                icon: Icons.fullscreen_rounded,
                tooltip: '全屏',
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
    // 没有房主权限了：这里只显示「我在带动播放」还是「跟着别人」。
    final stateText = widget.isHost ? '我在操作' : '同步中';
    final dot = widget.online
        ? const Color(0xFF57D3A3)
        : const Color(0xFFFF8A80);
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
                ? '等待开始直播'
                : (widget.isHost ? '点击播放，和朋友一起看' : '跟着房间播放'),
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withValues(alpha: .72),
            ),
          ),
        ],
      ),
    );
  }

  /// 失败卡片：与主播放竖屏的 `_buildError` 同一套（白玻璃卡片 /
  /// 云朵图标 / 渐变胶囊按钮），不再用一起看自己的深色卡片。
  Widget _buildError(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: .36),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 330),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .94),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .18),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, color: Fx.sub, size: 26),
            const SizedBox(height: 4),
            Text(
              widget.errorText,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Fx.ink, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _errorAction('重试', widget.onRetry),
                // 现在谁都能换线路 / 换片，错误页的第二个动作对所有人都给。
                const SizedBox(width: 10),
                _errorAction(
                  widget.isLive ? '换线路' : '换剧/选集',
                  widget.isLive ? widget.onSwitchLine : widget.onMedia,
                ),
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

  /* ------------------------------------------------------------ 信息区 */

  /// 房间信息条（ROOM_INFO_ONELINE / 2026-11-16）。
  ///
  /// 现场：`济公传 / 第01集 / 共58集 / 1人` 两行 + 头像行占了一整块玻璃卡片，
  /// 聊天区被挤得只剩两三条。现在压成**一行**：`片名 · 第N集 · N人`，
  /// 高度从约 76dp 降到 34dp，省出来的空间全部给聊天列表。
  ///
  /// 成员头像不再单独占一行：点「N人」就是成员面板，那里看得更清楚；
  /// 直播房用「直播中」替掉集数。
  Widget _buildInfo(BuildContext context) {
    final count = _episodeCount;
    final epText = widget.isLive
        ? '直播中'
        : (count > 0 ? '$_epLabel · 共 $count 集' : _epLabel);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      child: SizedBox(
        // 44dp 高：一行文字 + 可点的「N人」，热区也够。
        height: 38,
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '$_title · $epText · ${widget.members.length}人',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  color: Fx.ink,
                ),
              ),
            ),
            const SizedBox(width: 6),
            // 成员入口：视觉只是个小图标，热区 44dp。
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onMembers,
              child: SizedBox(
                height: 44,
                width: 44,
                child: Center(
                  child: Icon(
                    Icons.groups_2_outlined,
                    size: 18,
                    color: Fx.sub.withValues(alpha: .85),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /* ------------------------------------------------------------ 聊天 */

  Widget _buildChat(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 键盘弹起 / 极矮屏幕时这块 Expanded 会只剩几十 dp：
        // 列表和输入条一起硬塞会 overflow，所以放不下时只留输入条。
        final showList = constraints.maxHeight > 150;
        return Column(
          children: [
            if (showList)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                  child: Container(
                    decoration: togetherGlass(radius: 18, opacity: .60),
                    clipBehavior: Clip.antiAlias,
                    child:
                        ValueListenableBuilder<List<TogetherChatMessage>>(
                          valueListenable: widget.chat,
                          builder: (context, messages, _) =>
                              TogetherChatList(messages: messages),
                        ),
                  ),
                ),
              ),
            // CHAT_COMPOSER_PORTRAIT（2026-11-15）：竖屏房间底部输入条。
            // 之前这里只有只读列表，输入框只在横屏全屏的悬浮聊天里，竖屏
            // 根本没法说话。复用全屏那个组件（样式一致），区别只有：
            // 这一层放在页面底色上、组件自身是不透明玻璃胶囊
            // （transparent 保持默认 false），全屏那层才用半透明浮在画面上。
            // 页面是 `SafeArea(bottom: false)`：输入条自己要躲开手势条 /
            // 三键导航，否则最后一排按钮压进系统导航区点不到。
            Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.paddingOf(context).bottom,
              ),
              child: TogetherComposer(
                enabled: widget.online,
                hint: widget.online ? '说点什么…' : '正在重连…',
                onSend: widget.onSendChat,
              ),
            ),
          ],
        );
      },
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
          border: Border.all(
            color: const Color(0xFFFF6B6B).withValues(alpha: .5),
          ),
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

class _RoomProgress extends StatelessWidget {
  const _RoomProgress({
    required this.position,
    required this.duration,
    required this.onSeek,
    required this.onSeekBegin,
  });

  final ValueListenable<double> position;
  final Duration duration;
  final ValueChanged<double> onSeek;

  /// 手指落下：页面「接手主导权」，拖动途中不被别人的心跳拽回。
  final VoidCallback onSeekBegin;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: position,
      builder: (context, position, _) {
        final clamped = position.isFinite && position > 0 ? position : 0.0;
        final total = duration.inMilliseconds / 1000.0;
        final safeDuration = total.isFinite && total > 0 ? total : 0.0;
        return FxSeekRow(
          // 和主播放竖屏完全同一组参数（粗 3 / 热区 40 / 圆钮 15 / 时间宽 40）
          position: Duration(milliseconds: (clamped * 1000).round()),
          duration: Duration(milliseconds: (safeDuration * 1000).round()),
          height: 3,
          // TAP44：热区按 44dp 给（主播放 34），画面小的时候更好拖。
          touchHeight: 44,
          thumbSize: 15,
          labelWidth: 40,
          gap: 6,
          timeFontSize: 10.5,
          onSeek: (value) => onSeek(value.inMilliseconds / 1000.0),
          onScrubStart: onSeekBegin,
        );
      },
    );
  }
}


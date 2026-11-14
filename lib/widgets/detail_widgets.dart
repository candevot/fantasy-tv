import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';
import 'player_theme.dart';

/* ========================================================================== */
/*  详情页专用「白底 + 黑色线框」组件                                          */
/* ========================================================================== */

/// 详情页视觉令牌（白底 + 黑色线框 + 红色选集）。
///
/// 全部颜色都从 [Theme.of] 的 brightness 推出来，不在组件里写死
/// [Colors.white]：浅色下是纯白底 + black87 线框，深色下自动反成深底 +
/// 白色线框。现在 App 还是 `ThemeMode.light`（见 main.dart），但以后上深色
/// 时这一页不需要再改一遍。
class FxDetailSkin {
  const FxDetailSkin({required this.dark});

  /// 是否深色主题。
  final bool dark;

  static FxDetailSkin of(BuildContext context) =>
      FxDetailSkin(dark: Theme.of(context).brightness == Brightness.dark);

  /// 页面底色：纯白 / 近黑。
  Color get page => dark ? const Color(0xFF0E1014) : Colors.white;

  /// 卡片、圆钮、胶囊的底色。
  Color get surface => dark ? const Color(0xFF1A1D22) : Colors.white;

  /// 1px 浅灰描边（未选中）。
  Color get hairline =>
      dark ? Colors.white.withValues(alpha: .16) : const Color(0xFFEAEDF2);

  /// 极淡投影。
  Color get shadow => dark
      ? Colors.black.withValues(alpha: .55)
      : const Color(0xFF1B2430).withValues(alpha: .07);

  /// 标题 / 主文字：black87。
  Color get ink => dark ? Colors.white : Colors.black87;

  /// 正文 / 简介 / 按钮下标签：black54。
  Color get body => dark ? Colors.white70 : Colors.black54;

  /// 辅助小字（提示、时间、查看全部）：black38。
  Color get hint => dark ? Colors.white38 : Colors.black38;

  /// 线框图标本色。
  Color get icon => dark ? Colors.white : Colors.black87;

  /// 图标反色（压在 [ink] 实心圆上）。
  Color get onInk => dark ? Colors.black87 : Colors.white;

  /// 浅灰胶囊底。
  Color get chip => dark ? Colors.white.withValues(alpha: .08) : const Color(0xFFF3F5F8);

  /// 浅灰胶囊里的文字。
  Color get chipText => dark ? Colors.white70 : Colors.black54;

  /// 选集红：未选中描边 + 红字，选中红底。
  Color get red => dark ? const Color(0xFFFF6B62) : const Color(0xFFE5342C);

  /// 红底上的文字。
  Color get onRed => Colors.white;

  /// 圆钮统一的极淡阴影。
  List<BoxShadow> get softShadow => <BoxShadow>[
        BoxShadow(
          color: shadow,
          blurRadius: 10,
          offset: const Offset(0, 3),
        ),
      ];
}

/// 跑马灯：文字超宽时两段循环左移，收窄时静止。
class DetailMarqueeText extends StatefulWidget {
  const DetailMarqueeText(
    this.text, {
    super.key,
    this.style,
    this.gap = 56,
    this.period = const Duration(seconds: 12),
  });

  final String text;
  final TextStyle? style;
  final double gap;
  final Duration period;

  @override
  State<DetailMarqueeText> createState() => _DetailMarqueeTextState();
}

class _DetailMarqueeTextState extends State<DetailMarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: widget.period)..repeat();
  }

  @override
  void didUpdateWidget(covariant DetailMarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _c
        ..reset()
        ..repeat();
    }
    if (oldWidget.period != widget.period) {
      _c.duration = widget.period;
      _c
        ..reset()
        ..repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(
          widget.style ??
              const TextStyle(fontSize: 11.5, color: Fx.sub, height: 1.2),
        );
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: 1,
          textDirection: Directionality.of(context),
        )..layout();
        final textW = painter.width;
        painter.dispose();
        if (textW <= maxW || !maxW.isFinite) {
          return ClipRect(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.text,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
                style: style,
              ),
            ),
          );
        }
        final distance = textW + widget.gap;
        return ClipRect(
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final dx = -distance * Curves.linear.transform(_c.value);
              return OverflowBox(
                maxWidth: double.infinity,
                alignment: Alignment.centerLeft,
                child: Transform.translate(
                  offset: Offset(dx, 0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(widget.text,
                          maxLines: 1, softWrap: false, style: style),
                      SizedBox(width: widget.gap),
                      Text(widget.text,
                          maxLines: 1, softWrap: false, style: style),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// 集数文案：非「第N集」统一规范成「第N集」，
/// 预告 / 花絮 / 拉片 / 解说显示原名前 8 字 + 序号。
String detailEpisodeLabel(Episode e) => fxEpisodeLabel(e.n, e.name);

/// 公告条 / 跑马灯提示条。
///
/// [bare] = true 时只有文字和图标，没有胶囊底色（用于防诈提示行）。
class DetailNoticeBar extends StatelessWidget {
  const DetailNoticeBar({
    super.key,
    required this.text,
    this.onClose,
    this.bare = false,
    this.icon = Icons.campaign_rounded,
    this.height = 32,
    this.period = const Duration(seconds: 12),
  });

  final String text;
  final VoidCallback? onClose;
  final bool bare;
  final IconData icon;
  final double height;
  final Duration period;

  @override
  Widget build(BuildContext context) {
    final textStyle = TextStyle(
      fontSize: bare ? 11 : 11.5,
      height: 1.2,
      color: bare ? Fx.sub : Fx.ink.withValues(alpha: .78),
      fontWeight: bare ? FontWeight.w400 : FontWeight.w600,
    );
    final row = Row(
      children: [
        Icon(icon, size: bare ? 14 : 15, color: bare ? Fx.sub : Fx.accent),
        const SizedBox(width: 6),
        Expanded(
          child: SizedBox(
            height: bare ? 16 : 18,
            child: DetailMarqueeText(
              text,
              style: textStyle,
              period: period,
              gap: bare ? 64 : 48,
            ),
          ),
        ),
        if (onClose != null) ...[
          const SizedBox(width: 4),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
            child: Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .82),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white),
              ),
              child: const Icon(Icons.close_rounded, size: 13, color: Fx.sub),
            ),
          ),
        ],
      ],
    );
    if (bare) return row;
    return Container(
      height: height,
      padding: const EdgeInsets.only(left: 10, right: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .70),
        borderRadius: BorderRadius.circular(height / 2),
        border: Border.all(color: Colors.white.withValues(alpha: .95)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF50729F).withValues(alpha: .08),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: row,
    );
  }
}

/// 「视频 / 评论 N」双 Tab。
class DetailTabs extends StatelessWidget {
  const DetailTabs({
    super.key,
    required this.index,
    required this.onChanged,
    this.commentCount,
  });

  final int index;
  final ValueChanged<int> onChanged;
  final String? commentCount;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _tab(context, 0, '视频', null),
        const SizedBox(width: 16),
        _tab(
            context,
            1,
            '评论',
            (commentCount == null || commentCount!.isEmpty)
                ? null
                : commentCount),
      ],
    );
  }

  Widget _tab(BuildContext context, int value, String label, String? count) {
    final skin = FxDetailSkin.of(context);
    final active = index == value;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 180),
                  style: TextStyle(
                    fontSize: active ? 18.5 : 16,
                    height: 1.15,
                    fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                    color: active ? skin.ink : skin.body,
                  ),
                  child: Text(label),
                ),
                if (count != null) ...[
                  const SizedBox(width: 5),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      count,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: active ? skin.body : skin.hint,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 5),
            // 选中态：加粗 + 黑色下划线（不再用蓝色渐变）。
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              width: active ? 22 : 0,
              height: 2.5,
              decoration: BoxDecoration(
                color: skin.ink,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 5 个圆钮之一（收藏 / 下载 / 刷新 / 反馈 / 一起看）。
///
/// 统一规格：直径 [circleSize] 的圆形按钮，底色 [FxDetailSkin.surface]
/// （浅色纯白）+ 1px 浅灰描边 + 极淡投影；图标一律黑色线框
/// [FxDetailSkin.icon] / size [iconSize]，下方 12px 深灰标签。
/// [active] 只切换「实心图标 + 加粗标签」，换色交给图标形状本身。
class DetailActionButton extends StatelessWidget {
  const DetailActionButton({
    super.key,
    required this.icon,
    required this.label,
    this.activeIcon,
    this.onTap,
    this.active = false,
  });

  /// 圆钮直径。
  static const double circleSize = 56;

  /// 图标尺寸。
  static const double iconSize = 24;

  /// 线框图标（`Icons.*_outlined` 系列）。
  final IconData icon;

  /// 选中态用的实心图标；不传就沿用 [icon]。
  final IconData? activeIcon;
  final String label;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final skin = FxDetailSkin.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: circleSize,
            height: circleSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: skin.surface,
              shape: BoxShape.circle,
              border: Border.all(
                color: active ? skin.ink : skin.hairline,
                width: 1,
              ),
              boxShadow: skin.softShadow,
            ),
            child: Icon(
              active ? (activeIcon ?? icon) : icon,
              size: iconSize,
              color: skin.icon,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              height: 1.15,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              color: skin.body,
            ),
          ),
        ],
      ),
    );
  }
}

/// 横滑线路卡：线路名 + 共 N 集。
/// 哪些线路会带广告。
///
/// 量子和红牛都是免费采集站，播放前会有贴片 / 悬浮广告，
/// 用户要求在线路名上直接标出来，免得点进去才发现。
bool fxLineHasAds(String name) {
  final n = name.trim();
  return n.contains('量子') || n.contains('红牛');
}

class DetailLineCard extends StatelessWidget {
  const DetailLineCard({
    super.key,
    required this.name,
    required this.count,
    required this.active,
    this.onTap,
    this.subtitle,
    this.unstable = false,
    this.ads = false,
    this.width = 102,
  });

  final String name;
  final int count;
  final bool active;
  final VoidCallback? onTap;

  /// 第二行文案；为空时显示「共 N 集」（直播线路用清晰度 / 线路名）。
  final String? subtitle;

  /// 服务端标记 degraded 的线路：照常显示、可点，只在卡片名后补灰色小字。
  final bool unstable;

  /// 带广告的免费站线路（量子 / 红牛）：名字后打「广告」标记。
  final bool ads;

  /// 卡片宽度；直播线路文字更长时可适当加宽。
  final double width;

  @override
  Widget build(BuildContext context) {
    final skin = FxDetailSkin.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: skin.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active ? skin.ink : skin.hairline,
            width: active ? 1.4 : 1,
          ),
          boxShadow: skin.softShadow,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text.rich(
              TextSpan(
                text: name,
                children: [
                  // degraded 线路绝不隐藏，只在名字后补一行灰色小字。
                  if (unstable)
                    TextSpan(
                      text: ' · 不稳',
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w500,
                        color: skin.hint,
                      ),
                    ),
                  if (ads)
                    TextSpan(
                      text: ' 广告',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: skin.red,
                      ),
                    ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                color: skin.ink,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle ?? '共$count集',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                color: active ? skin.ink : skin.body,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单集小胶囊。
///
/// 规格（参考图）：未选中 = 白底 + 1px 红边 + 红字；
/// 选中 = 红底 + 白字（播放中等号图标也是白色）。
class DetailEpisodeChip extends StatelessWidget {
  const DetailEpisodeChip({
    super.key,
    required this.label,
    required this.active,
    this.cached = false,
    this.onTap,
  });

  final String label;
  final bool active;

  /// 该集已有本地缓存；点击会优先播放本地文件。
  final bool cached;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final skin = FxDetailSkin.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 77,
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? skin.red : skin.surface,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: active ? skin.red : skin.red.withValues(alpha: .62),
            width: 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (active) ...[
                  Icon(Icons.graphic_eq_rounded,
                      size: 13, color: skin.onRed),
                  const SizedBox(width: 3),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      color: active ? skin.onRed : skin.red,
                    ),
                  ),
                ),
              ],
            ),
            if (cached)
              Text(
                '已下载',
                maxLines: 1,
                style: TextStyle(
                  fontSize: 8,
                  height: 1.15,
                  fontWeight: FontWeight.w600,
                  color: active
                      ? skin.onRed.withValues(alpha: .86)
                      : skin.hint,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 集数横滑条：打开时自动把当前集滚到可视区。
class DetailEpisodeStrip extends StatefulWidget {
  const DetailEpisodeStrip({
    super.key,
    required this.episodes,
    required this.current,
    required this.onSelect,
    this.isCached,
  });

  final List<Episode> episodes;
  final int current;
  final ValueChanged<int> onSelect;

  /// 判断某集是否已下载；用于在剧集胶囊上显示已下载角标。
  final bool Function(int ep)? isCached;

  @override
  State<DetailEpisodeStrip> createState() => _DetailEpisodeStripState();
}

class _DetailEpisodeStripState extends State<DetailEpisodeStrip> {
  final ScrollController _c = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealCurrent(false));
  }

  @override
  void didUpdateWidget(covariant DetailEpisodeStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.current != widget.current ||
        oldWidget.episodes.length != widget.episodes.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealCurrent(true));
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _revealCurrent(bool animate) {
    if (!mounted || !_c.hasClients) return;
    final index = widget.episodes.indexWhere((e) => e.n == widget.current);
    if (index < 0) return;
    final max = _c.position.maxScrollExtent;
    if (max <= 0) return;
    final target = (index * 85.0 - 40).clamp(0.0, max).toDouble();
    if (animate) {
      _c.animateTo(target,
          duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
    } else {
      _c.jumpTo(target);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: ListView.separated(
        controller: _c,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: widget.episodes.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final e = widget.episodes[i];
          return DetailEpisodeChip(
            label: detailEpisodeLabel(e),
            active: e.n == widget.current,
            cached: widget.isCached?.call(e.n) ?? false,
            onTap: () => widget.onSelect(e.n),
          );
        },
      ),
    );
  }
}

/// 小标题 + 右侧操作。
class DetailSectionTitle extends StatelessWidget {
  const DetailSectionTitle({
    super.key,
    required this.title,
    this.trailing,
  });

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final skin = FxDetailSkin.of(context);
    return Row(
      children: [
        Container(
          width: 3,
          height: 15,
          decoration: BoxDecoration(
            color: skin.ink,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 7),
        Text(
          title,
          style: TextStyle(
            fontSize: 16.5,
            fontWeight: FontWeight.w800,
            color: skin.ink,
          ),
        ),
        const Spacer(),
        if (trailing != null) trailing!,
      ],
    );
  }
}

/// 评论条目：头像 / 昵称 / 评分 / 内容 / 时间 / 点赞。
class DetailCommentTile extends StatelessWidget {
  const DetailCommentTile({
    super.key,
    required this.item,
    this.liked = false,
    this.onLike,
  });

  final CommentItem item;
  final bool liked;
  final VoidCallback? onLike;

  @override
  Widget build(BuildContext context) {
    final skin = FxDetailSkin.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 9),
      decoration: BoxDecoration(
        color: skin.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: skin.hairline),
        boxShadow: skin.softShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _avatar(context),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.user.isEmpty ? '影迷' : item.user,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: skin.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    _stars(item.score, skin),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _timeText(item.time),
                style: TextStyle(fontSize: 9.5, color: skin.hint),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            item.content,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.55,
              color: skin.ink,
            ),
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onLike,
                child: Row(
                  children: [
                    Icon(
                      liked
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      size: 14,
                      color: liked ? skin.red : skin.body,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '${item.likes + (liked ? 1 : 0)}',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: liked ? skin.red : skin.body,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Icon(Icons.chat_bubble_outline_rounded,
                  size: 13, color: skin.body),
              const SizedBox(width: 3),
              Text(
                '${item.replies}',
                style: TextStyle(fontSize: 10.5, color: skin.body),
              ),
              const Spacer(),
              Text(
                '举报',
                style: TextStyle(fontSize: 10, color: skin.hint),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _timeText(String raw) {
    final t = DateTime.tryParse(raw)?.toLocal();
    if (t == null) return raw;
    final diff = DateTime.now().difference(t);
    if (diff.isNegative || diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}';
  }

  Widget _avatar(BuildContext context) {
    final fallback = Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        gradient: Fx.brand,
        shape: BoxShape.circle,
      ),
      child: Text(
        item.user.isEmpty ? '影' : item.user.substring(0, 1),
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    final url = item.avatar.trim();
    if (url.isEmpty || url.startsWith('data:')) return fallback;
    return ClipOval(
      child: FxNetworkImage(
        url: url,
        width: 34,
        height: 34,
        cacheWidth: (34 * MediaQuery.devicePixelRatioOf(context))
            .round()
            .clamp(34, 256),
        fit: BoxFit.cover,
        fallback: fallback,
      ),
    );
  }

  Widget _stars(num score, FxDetailSkin skin) {
    var stars = score <= 0
        ? 0
        : (score <= 5 ? score.round() : (score / 2).round()).clamp(0, 5);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 5; i++)
          Icon(
            i < stars ? Icons.star_rounded : Icons.star_border_rounded,
            size: 12,
            color: i < stars ? skin.ink : skin.hairline,
          ),
        if (score > 0) ...[
          const SizedBox(width: 4),
          Text(
            score.toStringAsFixed(1),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: skin.body,
            ),
          ),
        ],
      ],
    );
  }
}

/// 评论底部输入框（游客态：只提示登录）。
class DetailCommentInput extends StatelessWidget {
  const DetailCommentInput({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final skin = FxDetailSkin.of(context);
    return Container(
      decoration: BoxDecoration(
        color: skin.surface,
        border: Border(top: BorderSide(color: skin.hairline, width: 1)),
        boxShadow: skin.softShadow,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: skin.chip,
                  shape: BoxShape.circle,
                ),
                child: Text('幻',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: skin.ink)),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onTap,
                  child: Container(
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: skin.chip,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.edit_outlined, size: 14, color: skin.hint),
                        const SizedBox(width: 6),
                        Expanded(
                          child: TextField(
                            readOnly: true,
                            showCursor: false,
                            onTap: onTap,
                            style: TextStyle(fontSize: 12, color: skin.ink),
                            decoration: InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              hintText: '说点什么… 登录后参与评论',
                              hintStyle:
                                  TextStyle(fontSize: 11.5, color: skin.hint),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: skin.ink,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.send_rounded,
                      size: 17, color: skin.onInk),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/* ========================================================================== */
/*  选集弹层：网格 + 每页 30 + 分页                                            */
/* ========================================================================== */

Future<int?> showDetailEpisodeSheet(
  BuildContext context, {
  required List<Episode> episodes,
  required int current,
  int pageSize = 30,
  bool Function(int ep)? isCached,
}) {
  if (episodes.isEmpty) return Future<int?>.value();
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: .32),
    builder: (sheetContext) => _DetailEpisodeSheet(
      episodes: episodes,
      current: current,
      pageSize: pageSize,
      isCached: isCached,
    ),
  );
}

Future<String?> showDetailFeedbackSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: .32),
    builder: (sheetContext) {
      final skin = FxDetailSkin.of(sheetContext);
      return Container(
        padding: EdgeInsets.fromLTRB(
            20, 16, 20, 20 + MediaQuery.of(sheetContext).padding.bottom),
        decoration: BoxDecoration(
          color: skin.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: skin.hairline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text('反馈问题',
                style: TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w800, color: skin.ink)),
            const SizedBox(height: 4),
            Text('选择最接近的问题，我们会尽快处理',
                style: TextStyle(fontSize: 11.5, color: skin.hint)),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final reason in const [
                  '无法播放',
                  '线路失效',
                  '播放卡顿',
                  '画面/字幕错误',
                  '内容报错',
                  '其他问题',
                ])
                  ChipTag(
                    reason,
                    onTap: () => Navigator.of(sheetContext).pop(reason),
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

class _DetailEpisodeSheet extends StatefulWidget {
  const _DetailEpisodeSheet({
    required this.episodes,
    required this.current,
    required this.pageSize,
    this.isCached,
  });

  final List<Episode> episodes;
  final int current;
  final int pageSize;
  final bool Function(int ep)? isCached;

  @override
  State<_DetailEpisodeSheet> createState() => _DetailEpisodeSheetState();
}

class _DetailEpisodeSheetState extends State<_DetailEpisodeSheet> {
  late int _page;
  late final PageController _pc;

  int get _pages =>
      (widget.episodes.length + widget.pageSize - 1) ~/ widget.pageSize;

  @override
  void initState() {
    super.initState();
    final idx = widget.episodes.indexWhere((e) => e.n == widget.current);
    _page = idx <= 0 ? 0 : idx ~/ widget.pageSize;
    _pc = PageController(initialPage: _page);
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final skin = FxDetailSkin.of(context);
    final screenH = MediaQuery.of(context).size.height;
    return Container(
      height: screenH * .66,
      decoration: BoxDecoration(
        color: skin.page,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 9),
          Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: skin.hairline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 10, 4),
            child: Row(
              children: [
                Text('选集',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: skin.ink)),
                const SizedBox(width: 8),
                Text(
                  '共 ${fxMainEpisodeCount(widget.episodes)} 集',
                  style: TextStyle(fontSize: 11, color: skin.hint),
                ),
                const Spacer(),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).maybePop(),
                  child: Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: skin.chip,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.close_rounded,
                        size: 18, color: skin.body),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: PageView.builder(
              controller: _pc,
              itemCount: _pages,
              onPageChanged: (p) => setState(() => _page = p),
              itemBuilder: (context, page) {
                final s = page * widget.pageSize;
                final e = (s + widget.pageSize)
                    .clamp(0, widget.episodes.length)
                    .toInt();
                final c = e - s;
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1.65,
                  ),
                  itemCount: c,
                  itemBuilder: (context, i) {
                    final ep = widget.episodes[s + i];
                    final active = ep.n == widget.current;
                    final cached = widget.isCached?.call(ep.n) ?? false;
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(context).pop(ep.n),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        alignment: Alignment.center,
                        // 同一套选集规格：未选中白底 + 红边 + 红字，
                        // 选中红底白字。弹层一屏 30 格，未选中的红边
                        // 降一档透明度，避免整页红框。
                        decoration: BoxDecoration(
                          color: active ? skin.red : skin.surface,
                          borderRadius: BorderRadius.circular(11),
                          border: Border.all(
                            color: active
                                ? skin.red
                                : skin.red.withValues(alpha: .45),
                          ),
                          boxShadow: active ? null : skin.softShadow,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              detailEpisodeLabel(ep),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight:
                                    active ? FontWeight.w700 : FontWeight.w500,
                                color: active ? skin.onRed : skin.red,
                              ),
                            ),
                            if (cached) ...[
                              const SizedBox(height: 1),
                              Text(
                                '已下载',
                                maxLines: 1,
                                style: TextStyle(
                                  fontSize: 8,
                                  height: 1.1,
                                  fontWeight: FontWeight.w600,
                                  color: active
                                      ? skin.onRed.withValues(alpha: .86)
                                      : skin.hint,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
                16, 4, 16, 8 + MediaQuery.of(context).padding.bottom),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _pageButton(
                  icon: Icons.chevron_left_rounded,
                  label: '上一页',
                  enabled: _page > 0,
                  onTap: () {
                    _pc.animateToPage(_page - 1,
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut);
                  },
                ),
                const SizedBox(width: 14),
                Text(
                  '第 ${_page + 1} / $_pages 页',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: skin.body),
                ),
                const SizedBox(width: 14),
                _pageButton(
                  icon: Icons.chevron_right_rounded,
                  label: '下一页',
                  enabled: _page < _pages - 1,
                  onTap: () {
                    _pc.animateToPage(_page + 1,
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _pageButton({
    required IconData icon,
    required String label,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final skin = FxDetailSkin.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: skin.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: skin.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: enabled ? skin.ink : skin.hairline),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: enabled ? skin.ink : skin.hint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

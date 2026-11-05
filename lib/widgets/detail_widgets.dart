import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';
import 'player_theme.dart';

/* ========================================================================== */
/*  详情页专用白玻璃组件（只被 detail_page.dart 使用）                        */
/* ========================================================================== */

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
      color: bare ? Fx.sub : Fx.ink.withOpacity(.78),
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
                color: Colors.white.withOpacity(.82),
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
        color: Colors.white.withOpacity(.70),
        borderRadius: BorderRadius.circular(height / 2),
        border: Border.all(color: Colors.white.withOpacity(.95)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF50729F).withOpacity(.08),
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
                    fontSize: active ? 19.5 : 17,
                    height: 1.15,
                    fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                    color: active ? Fx.ink : Fx.sub,
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
                        color: active ? Fx.accent : Fx.sub,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 5),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              width: active ? 22 : 0,
              height: 3,
              decoration: BoxDecoration(
                gradient: Fx.brand,
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
class DetailActionButton extends StatelessWidget {
  const DetailActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 47,
            height: 47,
            decoration: BoxDecoration(
              color: active
                  ? color.withOpacity(.15)
                  : Colors.white.withOpacity(.88),
              shape: BoxShape.circle,
              border: Border.all(
                color: active ? color.withOpacity(.60) : Colors.white,
                width: active ? 1.4 : 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: color.withOpacity(active ? .18 : .08),
                  blurRadius: 16,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Icon(icon, size: 23, color: color),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? color : Fx.sub,
            ),
          ),
        ],
      ),
    );
  }
}

/// 横滑线路卡：线路名 + 共 N 集。
class DetailLineCard extends StatelessWidget {
  const DetailLineCard({
    super.key,
    required this.name,
    required this.count,
    required this.active,
    this.onTap,
    this.subtitle,
    this.width = 102,
  });

  final String name;
  final int count;
  final bool active;
  final VoidCallback? onTap;

  /// 第二行文案；为空时显示「共 N 集」（直播线路用清晰度 / 线路名）。
  final String? subtitle;

  /// 卡片宽度；直播线路文字更长时可适当加宽。
  final double width;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: width,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: active
              ? Fx.accent.withOpacity(.09)
              : Colors.white.withOpacity(.72),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active
                ? Fx.accent.withOpacity(.85)
                : Colors.white.withOpacity(.92),
            width: active ? 1.4 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF50729F).withOpacity(.08),
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: active ? Fx.accent : Fx.ink,
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
                color: active ? Fx.accent : Fx.sub,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单集小胶囊。
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
          color: active
              ? Fx.accent.withOpacity(.09)
              : Colors.white.withOpacity(.72),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(
            color: active ? Fx.accent : Colors.white.withOpacity(.92),
            width: active ? 1.4 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (active) ...[
                  const Icon(Icons.graphic_eq_rounded,
                      size: 13, color: Fx.accent),
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
                      color: active ? Fx.accent : Fx.sub,
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
                  color: const Color(0xFF2FA985).withOpacity(.92),
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
    return Row(
      children: [
        Container(
          width: 4,
          height: 16,
          decoration: BoxDecoration(
            gradient: Fx.brand,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 16.5,
            fontWeight: FontWeight.w800,
            color: Fx.ink,
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
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 11, 12, 9),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.62),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(.92)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF50729F).withOpacity(.07),
            blurRadius: 18,
            offset: const Offset(0, 5),
          ),
        ],
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
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: Fx.ink,
                      ),
                    ),
                    const SizedBox(height: 3),
                    _stars(item.score),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _timeText(item.time),
                style: const TextStyle(fontSize: 9.5, color: Color(0xFFA6B1C2)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            item.content,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.55,
              color: Fx.ink,
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
                      color: liked ? const Color(0xFFFF6B8A) : Fx.sub,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '${item.likes + (liked ? 1 : 0)}',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: liked ? const Color(0xFFFF6B8A) : Fx.sub,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              const Icon(Icons.chat_bubble_outline_rounded,
                  size: 13, color: Fx.sub),
              const SizedBox(width: 3),
              Text(
                '${item.replies}',
                style: const TextStyle(fontSize: 10.5, color: Fx.sub),
              ),
              const Spacer(),
              const Text(
                '举报',
                style: TextStyle(fontSize: 10, color: Color(0xFFA6B1C2)),
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

  Widget _stars(num score) {
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
            color: i < stars ? Fx.gold : const Color(0xFFC9D2E0),
          ),
        if (score > 0) ...[
          const SizedBox(width: 4),
          Text(
            score.toStringAsFixed(1),
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: Fx.gold,
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
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.92),
        border: const Border(top: BorderSide(color: Colors.white, width: 1)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF50729F).withOpacity(.10),
            blurRadius: 22,
            offset: const Offset(0, -4),
          ),
        ],
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
                decoration: const BoxDecoration(
                  gradient: Fx.brand,
                  shape: BoxShape.circle,
                ),
                child: const Text('幻',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
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
                      color: Colors.white.withOpacity(.80),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: Colors.white),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.edit_rounded, size: 13, color: Fx.sub),
                        const SizedBox(width: 6),
                        Expanded(
                          child: TextField(
                            readOnly: true,
                            showCursor: false,
                            onTap: onTap,
                            style: const TextStyle(fontSize: 12),
                            decoration: const InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              hintText: '说点什么… 登录后参与评论',
                              hintStyle:
                                  TextStyle(fontSize: 11.5, color: Fx.sub),
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
                    gradient: Fx.brand,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Fx.accent.withOpacity(.30),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.send_rounded,
                      size: 17, color: Colors.white),
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
    barrierColor: Colors.black.withOpacity(.32),
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
    barrierColor: Colors.black.withOpacity(.32),
    builder: (sheetContext) {
      return Container(
        padding: EdgeInsets.fromLTRB(
            20, 16, 20, 20 + MediaQuery.of(sheetContext).padding.bottom),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                  color: const Color(0xFFE3E9F3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text('反馈问题',
                style: TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w800, color: Fx.ink)),
            const SizedBox(height: 4),
            const Text('选择最接近的问题，我们会尽快处理',
                style: TextStyle(fontSize: 11.5, color: Fx.sub)),
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
    final screenH = MediaQuery.of(context).size.height;
    return Container(
      height: screenH * .66,
      decoration: const BoxDecoration(
        color: Color(0xFFF7FAFF),
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 9),
          Container(
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFE3E9F3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 10, 4),
            child: Row(
              children: [
                const Text('选集',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: Fx.ink)),
                const SizedBox(width: 8),
                Text(
                  '共 ${fxMainEpisodeCount(widget.episodes)} 集',
                  style: const TextStyle(fontSize: 11, color: Fx.sub),
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
                      color: Colors.white.withOpacity(.85),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white),
                    ),
                    child: const Icon(Icons.close_rounded,
                        size: 18, color: Fx.sub),
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
                        decoration: BoxDecoration(
                          gradient: active ? Fx.brand : null,
                          color: active ? null : Colors.white.withOpacity(.82),
                          borderRadius: BorderRadius.circular(11),
                          border: Border.all(
                            color: active
                                ? Fx.accent
                                : Colors.white.withOpacity(.95),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color:
                                  (active ? Fx.accent : const Color(0xFF50729F))
                                      .withOpacity(active ? .22 : .06),
                              blurRadius: 10,
                              offset: const Offset(0, 3),
                            ),
                          ],
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
                                color: active ? Colors.white : Fx.ink,
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
                                      ? Colors.white.withOpacity(.86)
                                      : const Color(0xFF2FA985),
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
                  style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: Fx.sub),
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
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(enabled ? .85 : .35),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 16, color: enabled ? Fx.ink : const Color(0xFFC4CDDA)),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: enabled ? Fx.ink : const Color(0xFFC4CDDA),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

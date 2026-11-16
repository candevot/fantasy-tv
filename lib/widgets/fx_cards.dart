import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';

/* ========================================================================== */
/*  通用海报 / 分区 / 骨架组件（首页、分类、排行榜、搜索共用）                 */
/* ========================================================================== */

/// 分类 key → 中文
String fxCategoryName(String key) {
  switch (key) {
    case 'juji':
      return '剧集';
    case 'movie':
      return '电影';
    case 'zongyi':
      return '综艺';
    case 'manhua':
      return '动漫';
    case 'duanju':
      return '短剧';
    case 'live':
      return '直播';
    default:
      return key.isEmpty ? '影视' : key;
  }
}

/// 封面地址：统一走 [Api.imgProxy]；本站 / 本机 http 地址直连。
String fxCoverUrl(String url) => Api.imgProxy(url);

/// 封面是否可用：空串 / data: 占位图 / 非 http(s)、协议相对、站内相对地址都算无效。
/// 无效时 FxCover 统一显示灰底 + 影片图标的占位图。
bool fxUsableCover(String url) {
  final u = url.trim();
  if (u.isEmpty || u.startsWith('data:')) return false;
  if (u.startsWith('//')) return true;
  final lower = u.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) return true;
  if (u.startsWith('/')) return true;
  return false;
}

/// 网络封面：统一走图片代理；加载中灰底微光，失败 / 空地址 / 非法 URL
/// 显示灰底影片图标，首帧 150ms 淡入。
class FxCover extends StatelessWidget {
  const FxCover({
    super.key,
    required this.url,
    required this.title,
    this.radius = 14,
    this.fit = BoxFit.cover,
    this.big = false,
    this.showText = true,
  });

  final String url;
  final String title;
  final double radius;
  final BoxFit fit;
  final bool big;
  final bool showText;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 按真实显示宽度 × 屏幕像素比解码：同一张 2K 海报在 4 列网格里
          // 只解码到实际像素宽度，滚动时内存和 GPU 上传都小一个数量级。
          // 首页 precache 用同一宽度，预加载和正式加载共享缓存。
          final dpr = MediaQuery.devicePixelRatioOf(context);
          final width = constraints.maxWidth;
          final cacheWidth = width.isFinite && width > 0
              ? (width * dpr).round().clamp(64, 4096).toInt()
              : null;
          // COVER_EMPTY（2026-11-14）：CMS 后台的 `vod_pic` 还是空的，
          // 列表 / 详情 / 收藏 / 历史全都会拿到空封面。空封面不再显示灰块 +
          // 小图标，改成「片名首字 + 渐变底」的占位块：一眼能看出是哪部片，
          // 也不引入任何第三方图床（后端补上 `vod_pic` 后自动换成真图）。
          //
          // COVER_FIX（2026-11-15）：外站封面（肥猫 jar 的 `vod_pic`）经常是
          // 空串 / 源站相对地址 —— 老逻辑把它补成我们旧后端的地址，图永远
          // 回不来，用户看到的是一块**空白**（灰底 shimmer 卡满 10 秒）。
          // 现在这块首字占位贯穿三态：加载中（loading）、失败（fallback）、
          // 空地址（直接显示），任何情况下都不再是空白块。
          final placeholder = title.trim().isEmpty
              ? null
              : _FxCoverInitial(title: title, big: big);
          return ColoredBox(
            color: const Color(0xFFE6E9EF),
            child: FxNetworkImage(
              url: url,
              fit: fit,
              cacheWidth: cacheWidth,
              filterQuality: big ? FilterQuality.medium : FilterQuality.low,
              fallback: placeholder,
              loading: placeholder,
              fallbackIconSize: big ? 44 : 30,
              semanticLabel: title.trim().isEmpty ? null : title,
            ),
          );
        },
      ),
    );
  }
}

/// 海报下方「片名 + 来源 + 状态」文字在当前系统字号下的高度。
/// 网格 / 横滑列表用它算 mainAxisExtent，1.3 倍大字体下也不会裁字。
/// [withSource] 为 true 时多留一行来源小字（10.5sp + 2dp 间距）；
/// 列表里没有任何来源时保持原高度，不白占位。
double fxPosterMetaExtent(
  BuildContext context, {
  bool withSource = false,
  int titleLines = 1,
}) {
  final scaler = MediaQuery.textScalerOf(context);
  final source = withSource ? 2 + scaler.scale(10.5 * 1.2) : 0.0;
  final lines = titleLines < 1 ? 1 : titleLines;
  // TITLE_2LINE（2026-11-16）：片名允许两行时高度必须跟着加，
  // 否则第二行被裁掉一半（3 列改 2 列后片名更容易超一行）。
  final title = scaler.scale(12.5 * 1.3) * lines;
  return 8 + title + source + scaler.scale(11 * 1.2) + 3;
}

/// 片名下的来源小字：10.5sp、灰 #8A8FA3、单行省略。
class FxSourceLabel extends StatelessWidget {
  const FxSourceLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        fontSize: 10.5,
        height: 1.2,
        fontWeight: FontWeight.w400,
        color: Color(0xFF8A8FA3),
      ),
    );
  }
}

/// 已知来源站点：线路名常带「4K / 影视 / 线路2」等后缀，
/// 统一归到站点前缀（幻想4K → 幻想、红牛影视 → 红牛、腾讯视频 → 腾讯）。
const List<String> _fxSourceBrands = <String>[
  '幻想',
  '红牛',
  '腾讯',
  '爱奇艺',
  '优酷',
  '芒果',
  '搜狐',
  '哔哩',
  '乐视',
  '咪咕',
  '暴风',
  'PPTV',
];

/// 把线路名（lines[0].name）归并成来源前缀；认不出来时取名称首段。
/// 纯技术串（ffm3u8 / hls / play_from）不是给人看的来源名，返回空串由 UI 隐藏。
String fxSourceBrand(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return '';
  final lower = s.toLowerCase();
  for (final brand in _fxSourceBrands) {
    if (lower.contains(brand.toLowerCase())) return brand;
  }
  var base = s.split(RegExp(r'[\s·・•|｜/\\_\-–—:：]+')).first.trim();
  base = base
      .replaceFirst(
        RegExp(r'(?:4[kK]|8[kK]|1080[pP]|高清|超清|蓝光|影视|视频|影院|片库|线路\d*)+$'),
        '',
      )
      .trim();
  if (base.isEmpty) return '';
  // 没有汉字的短串多半是 vod_play_from / 清晰度标记，不当来源展示。
  if (!RegExp(r'[\u4e00-\u9fa5]').hasMatch(base)) {
    if (base.length <= 3 ||
        lower.contains('m3u8') ||
        lower.contains('http') ||
        lower.contains('parse')) {
      return '';
    }
  }
  return base;
}

/// 列表行第二行的进度文案：第N集 / 全N集 / 已完结。
String fxListEpisodeText(VideoCard item) {
  final badge = fxBadgeText(item);
  if (badge != null && badge != '新') {
    // 角标是「更新至12集」，列表行里写成更短的「第12集」。
    if (badge.startsWith('更新至')) return '第${badge.substring(3)}';
    return badge;
  }
  final direct = RegExp(r'第\s*(\d+)\s*集').firstMatch(item.status);
  if (direct != null) return '第${direct.group(1)}集';
  // 电影接口也会给 episodes=1，单集不是「全1集」，不占进度文案。
  if (item.episodes > 1) return '全${item.episodes}集';
  return '';
}

/// 列表行第二行：进度 · 年份 · 类型。
String fxListMetaLine(VideoCard item) {
  final episode = fxListEpisodeText(item);
  final type = item.type.isNotEmpty ? item.type : fxCategoryName(item.category);
  return <String>[
    if (episode.isNotEmpty) episode,
    if (item.year > 0) '${item.year}',
    if (type.isNotEmpty) type,
  ].join(' · ');
}

/// 右侧集数徽标文案；没有集数信息时返回 null，由 UI 改画箭头。
String? fxListBadge(VideoCard item) {
  final badge = fxBadgeText(item);
  if (badge != null && badge != '新') {
    if (badge.startsWith('更新至')) return badge.substring(3);
    return badge;
  }
  if (item.episodes > 1) return '全${item.episodes}集';
  return null;
}

/// 海报角标文案：新 / 更新至N集 / 全N集 / 已完结。
/// 服务端 status 文案很杂（更新至10集 / 全29集 / 已完结 / HD / 第261104期），
/// 只认这四类；认不出来的老片不显示角标，当年的新片显示「新」。
String? fxBadgeText(VideoCard item) {
  final s = item.status.trim();
  if (s.isNotEmpty) {
    if (s.contains('完结')) return '已完结';
    final full = RegExp(r'全\s*(\d+)\s*集').firstMatch(s);
    if (full != null) return '全${full.group(1)}集';
    final fullTail = RegExp(r'(\d+)\s*集全').firstMatch(s);
    if (fullTail != null) return '全${fullTail.group(1)}集';
    final updating = RegExp(r'更新至\s*第?\s*(\d+)\s*集').firstMatch(s);
    if (updating != null) return '更新至${updating.group(1)}集';
    final variety = RegExp(r'更新至\s*第?\s*(\d+)\s*期').firstMatch(s);
    if (variety != null) return '更新至${variety.group(1)}期';
  }
  return item.year == DateTime.now().year ? '新' : null;
}

/// 海报左上角小角标
class FxPosterBadge extends StatelessWidget {
  const FxPosterBadge(this.text, {super.key});

  final String text;

  LinearGradient get _gradient {
    if (text == '新') {
      return const LinearGradient(
        colors: [Color(0xFFFF6B6B), Color(0xFFFF9A3D)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
    }
    if (text.startsWith('更新')) {
      return const LinearGradient(
        colors: [Color(0xFF5B8CFF), Color(0xFF8E6BFF)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
    }
    if (text.startsWith('全')) {
      return const LinearGradient(
        colors: [Color(0xFF2FA985), Color(0xFF5BC8A8)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
    }
    return const LinearGradient(
      colors: [Color(0xCC2B3440), Color(0xCC4A5566)],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 84),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        gradient: _gradient,
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .16),
            blurRadius: 5,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 9.5,
          height: 1.15,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// 海报底部那条半透明信息条上的文字：**只写真实集数状态**
/// （更新至第26集 / 全27集 / 完结），没有状态时返回空串 ——
/// 不能拿「年份 · 类型」凑数，那样每张卡底部都写「2026 · 电影」，很吵。
String fxPosterEpisodeLine(VideoCard item) => item.status.trim();

/// 海报下方唯一的一行状态：优先服务端 status，其次「年份 · 类型」。
String fxPosterStatusLine(VideoCard item) {
  final s = item.status.trim();
  if (s.isNotEmpty) return s;
  final parts = <String>[
    if (item.year > 0) '${item.year}',
    if (item.type.isNotEmpty) item.type else fxCategoryName(item.category),
  ];
  return parts.join(' · ');
}

/// 左上角「年份」角标（影视壳那种：半透明深色玻璃 + 白字）。
///
/// SHELL_GRID（2026-11-17）：壳的 3 列网格里，海报左上角是蓝色年份角标
/// （2026 / 2025…），不是「更新 / 全 N 集」那种角标 —— 集数信息挪到海报
/// 底部的半透明条（见 [FxPosterStatusOverlay]）。
class FxYearBadge extends StatelessWidget {
  const FxYearBadge(this.year, {super.key});

  final int year;

  @override
  Widget build(BuildContext context) {
    if (year <= 0) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        // 半透明深色玻璃：不是实心黑块，海报透得出来。
        color: const Color(0xFF2B3440).withValues(alpha: .55),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withValues(alpha: .22)),
      ),
      child: Text(
        '$year',
        maxLines: 1,
        style: const TextStyle(
          fontSize: 9.5,
          height: 1.15,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// 海报底部的半透明信息条：`更新至第26集` / `全27集` / `完结`。
///
/// GLASS_UI（2026-11-17）：用户要求「渐变到透明（底部深、顶部透明），
/// 不要实心黑条」，所以底色是 LinearGradient 而不是纯色。
class FxPosterStatusOverlay extends StatelessWidget {
  const FxPosterStatusOverlay(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(7, 12, 7, 5),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0),
              Colors.black.withValues(alpha: .28),
              Colors.black.withValues(alpha: .62),
            ],
            stops: const [0, .45, 1],
          ),
          borderRadius: BorderRadius.vertical(
            bottom: Radius.circular(0),
          ),
        ),
        child: Text(
          text.trim(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 10,
            height: 1.2,
            fontWeight: FontWeight.w500,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

/// 2:3 海报 + 左上角标（年份 / 更新）+ 海报底部集数条 + 片名 + 状态
///
/// SHELL_GRID（2026-11-17）：3 列网格用的就是这一套 —— `showYearBadge`
/// 打开左上年份角标、`statusOverlay` 打开海报底部的「更新至第 N 集」渐变条、
/// `centerTitle` 让片名居中一行。首页 / 分类页 / 搜索网格都走它。
class FxPosterTile extends StatelessWidget {
  const FxPosterTile({
    super.key,
    required this.item,
    this.onTap,
    this.radius = 12,
    this.showBadge = true,
    this.titleSize = 12.5,
    this.showTitle = true,
    this.showStatus = true,
    this.showYearBadge = false,
    this.statusOverlay = false,
    this.centerTitle = false,
    this.titleLines = 2,
  });

  final VideoCard item;
  final VoidCallback? onTap;
  final double radius;
  final bool showBadge;
  final double titleSize;
  final bool showTitle;
  final bool showStatus;

  /// 左上角显示「年份」角标（壳的 3 列网格用）；为 false 时退回原来的
  /// 「新 / 更新 / 全 N 集」角标。
  final bool showYearBadge;

  /// 海报底部叠一条「更新至第 N 集 / 全 N 集 / 完结」的渐变信息条。
  /// 打开它一般把 [showStatus] 关掉，避免同一句话出现两次。
  final bool statusOverlay;

  /// 片名居中（壳的网格卡片是居中的）。
  final bool centerTitle;

  /// 片名最多几行（3 列网格给 1 行，搜索结果给 2 行）。
  final int titleLines;

  @override
  Widget build(BuildContext context) {
    final badge = showBadge ? fxBadgeText(item) : null;
    final yearBadge = showYearBadge && item.year > 0;
    return RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          crossAxisAlignment:
              centerTitle ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FxCover(url: item.cover, title: item.title, radius: radius),
                  if (yearBadge)
                    Positioned(
                      left: 5,
                      top: 5,
                      child: FxYearBadge(item.year),
                    )
                  else if (badge != null)
                    Positioned(
                      left: 5,
                      top: 5,
                      child: FxPosterBadge(badge),
                    ),
                  if (statusOverlay)
                    FxPosterStatusOverlay(fxPosterEpisodeLine(item)),
                ],
              ),
            ),
            if (showTitle) ...[
              const SizedBox(height: 5),
              Text(
                item.title,
                textAlign: centerTitle ? TextAlign.center : TextAlign.start,
                maxLines: titleLines,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: titleSize,
                  height: 1.3,
                  fontWeight: FontWeight.w500,
                  color: Fx.ink,
                ),
              ),
              if (!centerTitle && item.sourceLabel.trim().isNotEmpty) ...[
                const SizedBox(height: 2),
                FxSourceLabel(item.sourceLabel.trim()),
              ],
            ],
            if (showStatus) ...[
              const SizedBox(height: 2),
              Text(
                fxPosterStatusLine(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  height: 1.2,
                  fontWeight: FontWeight.w400,
                  color: Fx.sub,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 搜索结果单列列表行：84×112 海报 + 两行片名 + 进度/年份/类型 + 来源小字，
/// 右侧按有无集数信息显示徽标或箭头。行高由内容撑开，大字体不裁字。
class FxSearchResultTile extends StatelessWidget {
  const FxSearchResultTile({super.key, required this.item, this.onTap});

  final VideoCard item;
  final VoidCallback? onTap;

  static const double _posterWidth = 84;
  static const double _posterHeight = 112;

  @override
  Widget build(BuildContext context) {
    final meta = fxListMetaLine(item);
    final source = fxSourceBrand(item.sourceLabel);
    final badge = fxListBadge(item);
    return GlassCard(
      padding: const EdgeInsets.all(8),
      radius: 18,
      opacity: .62,
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _posterWidth,
            height: _posterHeight,
            child: FxCover(
              url: item.cover,
              title: item.title,
              radius: 10,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.25,
                    fontWeight: FontWeight.w600,
                    color: Fx.ink,
                  ),
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.2,
                      fontWeight: FontWeight.w400,
                      color: Fx.sub,
                    ),
                  ),
                ],
                if (source.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '来源：$source',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      height: 1.2,
                      fontWeight: FontWeight.w400,
                      color: Color(0xFF8A8FA3),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: _posterHeight,
            child: Align(
              alignment: Alignment.center,
              child: badge != null
                  ? Container(
                      constraints: const BoxConstraints(maxWidth: 78),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: Fx.accent.withValues(alpha: .10),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        badge,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10.5,
                          height: 1.2,
                          fontWeight: FontWeight.w600,
                          color: Fx.accent,
                        ),
                      ),
                    )
                  : const Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: Color(0xFFB3BECD),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 分区标题：标题左 + 「更多 ›」右
class FxSectionTitle extends StatelessWidget {
  const FxSectionTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.onMore,
    this.moreText = '更多',
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onMore;
  final String moreText;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 3,
            height: 16,
            decoration: BoxDecoration(
              gradient: Fx.brand,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(title,
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w600, color: Fx.ink)),
          if (subtitle != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w400, color: Fx.sub),
              ),
            ),
          ] else
            const Spacer(),
          if (onMore != null)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onMore,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(moreText,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            color: Fx.sub)),
                    const Icon(Icons.chevron_right_rounded,
                        size: 16, color: Fx.sub),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 首页分区：4 列海报横滑（2:3 / 圆角 12 / 间距 8），最多 [maxItems] 条。
class FxSectionRow extends StatelessWidget {
  const FxSectionRow({
    super.key,
    required this.title,
    required this.items,
    this.onMore,
    this.onTapItem,
    this.visibleCount = 4,
    this.gap = 8,
    this.horizontalPadding = 16,
    this.maxItems = 10,
  });

  final String title;
  final List<VideoCard> items;
  final VoidCallback? onMore;
  final ValueChanged<VideoCard>? onTapItem;
  final int visibleCount;
  final double gap;
  final double horizontalPadding;
  final int maxItems;

  @override
  Widget build(BuildContext context) {
    final list = items.take(maxItems).toList();
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FxSectionTitle(title: title, onMore: onMore, moreText: '更多'),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (ctx, cons) {
            final available = cons.maxWidth -
                horizontalPadding * 2 -
                gap * (visibleCount - 1);
            final itemWidth = available <= 0 ? 72.0 : available / visibleCount;
            final withSource = list.any((e) => e.sourceLabel.trim().isNotEmpty);
            return SizedBox(
              height: itemWidth * 1.5 +
                  fxPosterMetaExtent(context, withSource: withSource),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                physics: const BouncingScrollPhysics(),
                itemCount: list.length,
                separatorBuilder: (_, __) => SizedBox(width: gap),
                itemBuilder: (ctx, i) {
                  final item = list[i];
                  return SizedBox(
                    width: itemWidth,
                    child: FxPosterTile(
                      item: item,
                      onTap: onTapItem == null ? null : () => onTapItem!(item),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ],
    );
  }
}

/* ------------------------------------------------------------ 骨架屏 */

/// 骨架屏呼吸动画容器
class FxSkeletonPulse extends StatefulWidget {
  const FxSkeletonPulse({super.key, required this.child});

  final Widget child;

  @override
  State<FxSkeletonPulse> createState() => _FxSkeletonPulseState();
}

class _FxSkeletonPulseState extends State<FxSkeletonPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (ctx, child) =>
          Opacity(opacity: .55 + .35 * _controller.value, child: child),
      child: widget.child,
    );
  }
}

/// 骨架屏占位块
class FxSkeletonBox extends StatelessWidget {
  const FxSkeletonBox({
    super.key,
    this.width,
    this.height,
    this.radius = 12,
  });

  final double? width;
  final double? height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .62),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white.withValues(alpha: .9)),
      ),
    );
  }
}

/// 3 列 / N 列海报网格骨架屏
class FxPosterGridSkeleton extends StatelessWidget {
  const FxPosterGridSkeleton({
    super.key,
    this.crossAxisCount = 4,
    this.itemCount = 12,
    this.padding = const EdgeInsets.fromLTRB(16, 4, 16, 0),
    this.spacing = 8,
    this.showTitle = true,
  });

  final int crossAxisCount;
  final int itemCount;
  final EdgeInsets padding;
  final double spacing;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, cons) {
        final width = (cons.maxWidth -
                padding.horizontal -
                spacing * (crossAxisCount - 1)) /
            crossAxisCount;
        return Padding(
          padding: padding,
          child: Wrap(
            spacing: spacing,
            runSpacing: 14,
            children: [
              for (var i = 0; i < itemCount; i++)
                SizedBox(
                  width: width,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FxSkeletonBox(height: width * 1.5, radius: 12),
                      if (showTitle) ...[
                        const SizedBox(height: 7),
                        FxSkeletonBox(
                            height: 12, width: width * .78, radius: 4),
                        const SizedBox(height: 5),
                        FxSkeletonBox(
                            height: 10, width: width * .52, radius: 4),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 4 列海报横滑骨架屏（首页分区用）
class FxPosterRowSkeleton extends StatelessWidget {
  const FxPosterRowSkeleton({
    super.key,
    this.count = 4,
    this.gap = 8,
    this.horizontalPadding = 16,
  });

  final int count;
  final double gap;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, cons) {
        final width =
            (cons.maxWidth - horizontalPadding * 2 - gap * (count - 1)) / count;
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < count; i++) ...[
                if (i != 0) SizedBox(width: gap),
                SizedBox(
                  width: width,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FxSkeletonBox(height: width * 1.5, radius: 12),
                      const SizedBox(height: 7),
                      FxSkeletonBox(height: 12, width: width * .78, radius: 4),
                      const SizedBox(height: 5),
                      FxSkeletonBox(height: 10, width: width * .52, radius: 4),
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// 搜索结果单列列表骨架屏：与 FxSearchResultTile 同尺寸（84×112 海报）。
class FxResultListSkeleton extends StatelessWidget {
  const FxResultListSkeleton({
    super.key,
    this.count = 6,
    this.padding = EdgeInsets.zero,
  });

  final int count;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Column(
        children: [
          for (var i = 0; i < count; i++) ...[
            if (i != 0) const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .62),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white.withValues(alpha: .9)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const FxSkeletonBox(width: 84, height: 112, radius: 10),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: .82,
                          child: const FxSkeletonBox(height: 15, radius: 4),
                        ),
                        const SizedBox(height: 6),
                        FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: .54,
                          child: const FxSkeletonBox(height: 15, radius: 4),
                        ),
                        const SizedBox(height: 9),
                        FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: .70,
                          child: const FxSkeletonBox(height: 12, radius: 4),
                        ),
                        const SizedBox(height: 6),
                        FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: .42,
                          child: const FxSkeletonBox(height: 11, radius: 4),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 排行榜列表骨架屏
class FxRankListSkeleton extends StatelessWidget {
  const FxRankListSkeleton({
    super.key,
    this.count = 6,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 0),
  });

  final int count;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      physics: const NeverScrollableScrollPhysics(),
      padding: padding,
      itemCount: count,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (ctx, i) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .62),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: .9)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const FxSkeletonBox(width: 30, height: 36, radius: 10),
            const SizedBox(width: 8),
            const FxSkeletonBox(width: 66, height: 99, radius: 10),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 99,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FxSkeletonBox(height: 14, width: 130, radius: 4),
                    const SizedBox(height: 8),
                    FxSkeletonBox(height: 11, width: 90, radius: 4),
                    const SizedBox(height: 8),
                    FxSkeletonBox(height: 11, radius: 4),
                    const SizedBox(height: 5),
                    FxSkeletonBox(height: 11, width: 160, radius: 4),
                    const Spacer(),
                    FxSkeletonBox(height: 11, width: 74, radius: 4),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 空封面占位块（COVER_EMPTY）：片名首字 + 按片名生成的渐变底。
///
/// 只服务于「后端 `vod_pic` 为空 / 图挂了」这一种情况：
///   · 不请求任何外部图床（不引入不可靠的第三方封面源）；
///   · 同一个片名永远得到同一组颜色，翻页 / 刷新都不会变色；
///   · 外层 FxCover 已经做过 ClipRRect，这里只负责填满 + 居中首字。
class _FxCoverInitial extends StatelessWidget {
  const _FxCoverInitial({required this.title, required this.big});

  final String title;
  final bool big;

  /// 片名 → 稳定色相（0-359）：同一部片在任何页面都是同一个颜色。
  static int _hueOf(String seed) {
    var hash = 0;
    for (final unit in seed.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return hash % 360;
  }

  @override
  Widget build(BuildContext context) {
    final text = title.trim();
    if (text.isEmpty) return const SizedBox.shrink();
    final base =
        HSLColor.fromAHSL(1, _hueOf(text).toDouble(), .52, .63).toColor();
    final initial = text.characters.first;
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.biggest.shortestSide;
        final size = (side.isFinite ? side : 64) * (big ? .30 : .42);
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                base,
                Color.lerp(base, Fx.accent2, .55) ?? base,
              ],
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            initial,
            maxLines: 1,
            style: TextStyle(
              fontSize: size.clamp(16.0, 96.0).toDouble(),
              fontWeight: FontWeight.w700,
              color: Colors.white.withValues(alpha: .92),
              height: 1,
            ),
          ),
        );
      },
    );
  }
}

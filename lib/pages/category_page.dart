import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'detail_page.dart';

/* ========================================================================== */
/*  公共内容组件 / 工具（放在允许修改的页面文件内，避免新增文件或改主题）      */
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

/// 封面地址：相对代理地址补全，data: 地址原样返回
String fxCoverUrl(String url) {
  if (url.isEmpty) return url;
  if (url.startsWith('data:')) return url;
  return Api.abs(url);
}

int fxInt(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v == null) return fallback;
  return int.tryParse('$v') ?? fallback;
}

String fxStr(Object? v, [String fallback = '']) => v == null ? fallback : '$v';

/// 网络错误 → 友好文案
String fxErrorText(Object e) {
  if (e is ApiException) return e.message;
  final s = e.toString();
  if (s.contains('TimeoutException')) return '连接超时，请检查网络后重试';
  if (s.contains('SocketException')) return '网络不可用，请检查连接';
  if (s.contains('HandshakeException')) return '安全连接失败，请稍后重试';
  if (s.contains('FormatException')) return '数据解析失败，请稍后重试';
  return '网络开小差了，请稍后重试';
}

/// 秒 → mm:ss / h:mm:ss
String fxDurationText(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

String fxBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String _two(int n) => n.toString().padLeft(2, '0');

/// 时间戳 → 相对时间
String fxTimeAgo(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final diff = now.difference(d);
  if (diff.isNegative || diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  final sameDay = now.year == d.year && now.month == d.month && now.day == d.day;
  if (sameDay) return '今天 ${_two(d.hour)}:${_two(d.minute)}';
  final yesterday = now.subtract(const Duration(days: 1));
  if (yesterday.year == d.year &&
      yesterday.month == d.month &&
      yesterday.day == d.day) {
    return '昨天 ${_two(d.hour)}:${_two(d.minute)}';
  }
  if (now.year == d.year) return '${d.month} 月 ${d.day} 日';
  return '${d.year}/${d.month}/${d.day}';
}

/// 网络封面：加载失败（含服务器的 data:image/svg+xml）时展示渐变占位
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

  static const List<List<Color>> _palettes = [
    [Color(0xFFAFC8FF), Color(0xFF7C8CFF)],
    [Color(0xFFC9BEFF), Color(0xFF8E6BFF)],
    [Color(0xFFA4E4DE), Color(0xFF5B9BFF)],
    [Color(0xFFFFD0DC), Color(0xFF9C7BFF)],
    [Color(0xFFB8DCFF), Color(0xFF63C7C0)],
  ];

  @override
  Widget build(BuildContext context) {
    final colors = _palettes[title.hashCode.abs() % _palettes.length];
    final usable = url.isNotEmpty && !url.startsWith('data:');
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
        fit: StackFit.expand,
        children: [
          _placeholder(colors),
          if (usable)
            Image.network(
              fxCoverUrl(url),
              fit: fit,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              loadingBuilder: (context, child, progress) {
                if (progress == null) return child;
                return _placeholder(colors);
              },
              errorBuilder: (context, error, stack) => _placeholder(colors),
            ),
        ],
      ),
    );
  }

  Widget _placeholder(List<Color> colors) {
    final iconSize = big ? 46.0 : 32.0;
    final titleSize = big ? 13.0 : 10.5;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: -34,
            right: -28,
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(.18),
              ),
            ),
          ),
          Positioned(
            bottom: -40,
            left: -30,
            child: Container(
              width: 130,
              height: 130,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(.10),
              ),
            ),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: iconSize,
                    height: iconSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withOpacity(.20),
                      border: Border.all(color: Colors.white.withOpacity(.38)),
                    ),
                    child: Icon(Icons.play_arrow_rounded,
                        color: Colors.white, size: iconSize * .58),
                  ),
                  if (showText && title.isNotEmpty) ...[
                    const SizedBox(height: 7),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: titleSize,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withOpacity(.94),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class FxStatusTag extends StatelessWidget {
  const FxStatusTag(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.34),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 9.5, color: Colors.white),
      ),
    );
  }
}

/// 2:3 圆角海报卡片 + 标题
class FxPosterCard extends StatelessWidget {
  const FxPosterCard({
    super.key,
    required this.item,
    this.onTap,
    this.width,
    this.showSubtitle = true,
    this.showRating = true,
  });

  final VideoCard item;
  final VoidCallback? onTap;
  final double? width;
  final bool showSubtitle;
  final bool showRating;

  String get _sub {
    final parts = <String>[
      if (item.year > 0) '${item.year}',
      fxCategoryName(item.category),
      if (item.episodes > 0) '${item.episodes} 集',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final card = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: 2 / 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              FxCover(url: item.cover, title: item.title),
              if (showRating && item.rating > 0)
                Positioned(top: 6, right: 6, child: RatingBadge(item.rating)),
              if (item.status.isNotEmpty)
                Positioned(left: 6, bottom: 6, child: FxStatusTag(item.status)),
            ],
          ),
        ),
        const SizedBox(height: 7),
        Text(
          item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              fontSize: 12.5, fontWeight: FontWeight.w600, color: Fx.ink),
        ),
        if (showSubtitle) ...[
          const SizedBox(height: 3),
          Text(
            _sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10.5, color: Fx.sub),
          ),
        ],
      ],
    );
    final tappable = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: card,
    );
    return width == null ? tappable : SizedBox(width: width, child: tappable);
  }
}

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
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 4,
            height: 17,
            decoration: BoxDecoration(
              gradient: Fx.brand,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 9),
          Text(title,
              style: const TextStyle(
                  fontSize: 17.5, fontWeight: FontWeight.w800, color: Fx.ink)),
          if (subtitle != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10.5, color: Fx.sub),
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
                        style: const TextStyle(fontSize: 12, color: Fx.sub)),
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

class FxErrorView extends StatelessWidget {
  const FxErrorView({
    super.key,
    required this.message,
    required this.onRetry,
    this.compact = false,
  });

  final String message;
  final VoidCallback onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: GlassCard(
          padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: Fx.accent.withOpacity(.10),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.cloud_off_rounded,
                    size: 28, color: Fx.accent),
              ),
              const SizedBox(height: 13),
              const Text('加载失败',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Fx.ink)),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, height: 1.5, color: Fx.sub),
              ),
              const SizedBox(height: 16),
              GradButton(
                  text: '重试',
                  icon: Icons.refresh_rounded,
                  onTap: onRetry,
                  height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

class FxEmptyView extends StatelessWidget {
  const FxEmptyView({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.actionText,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? actionText;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(.7),
                border: Border.all(color: Colors.white),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF50729F).withOpacity(.08),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Icon(icon, size: 32, color: Fx.accent.withOpacity(.8)),
            ),
            const SizedBox(height: 14),
            Text(title,
                style: const TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: Fx.ink)),
            if (subtitle != null) ...[
              const SizedBox(height: 5),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 12, height: 1.55, color: Fx.sub),
              ),
            ],
            if (actionText != null && onAction != null) ...[
              const SizedBox(height: 16),
              GradButton(text: actionText!, onTap: onAction, height: 40),
            ],
          ],
        ),
      ),
    );
  }
}

class FxLoadingView extends StatelessWidget {
  const FxLoadingView({super.key, this.label = '正在加载…'});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              valueColor: AlwaysStoppedAnimation<Color>(Fx.accent),
            ),
          ),
          const SizedBox(height: 12),
          Text(label, style: const TextStyle(fontSize: 12, color: Fx.sub)),
        ],
      ),
    );
  }
}

/// 二级页统一外壳：液态背景 + 玻璃返回键 + 居中标题
class FxPageScaffold extends StatelessWidget {
  const FxPageScaffold({
    super.key,
    required this.title,
    required this.child,
    this.actions,
  });

  final String title;
  final Widget child;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: FxBackground(
        child: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 52,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Text(title,
                        style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: Fx.ink)),
                    Positioned(
                      left: 12,
                      child: GestureDetector(
                        onTap: () => Navigator.maybePop(context),
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(.72),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white),
                          ),
                          child: const Icon(
                              Icons.arrow_back_ios_new_rounded,
                              size: 16,
                              color: Fx.ink),
                        ),
                      ),
                    ),
                    if (actions != null && actions!.isNotEmpty)
                      Positioned(
                        right: 14,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: actions!,
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

/// 二级页右上角玻璃文字按钮
class FxTextAction extends StatelessWidget {
  const FxTextAction(this.text, {super.key, this.onTap, this.icon});
  final String text;
  final VoidCallback? onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.7),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: Fx.sub),
              const SizedBox(width: 3),
            ],
            Text(text, style: const TextStyle(fontSize: 11, color: Fx.sub)),
          ],
        ),
      ),
    );
  }
}


/* ========================================================================== */
/*  分类页                                                                     */
/* ========================================================================== */

class _Opt {
  const _Opt(this.value, this.label);
  final String value;
  final String label;
}

class CategoryPage extends StatefulWidget {
  const CategoryPage({
    super.key,
    this.initialType = '',
    this.initialTitle,
    this.standalone = false,
  });

  final String initialType;
  final String? initialTitle;
  final bool standalone;

  @override
  State<CategoryPage> createState() => _CategoryPageState();
}

class _CategoryPageState extends State<CategoryPage> {
  static const List<_Opt> _types = [
    _Opt('', '全部'),
    _Opt('juji', '剧集'),
    _Opt('movie', '电影'),
    _Opt('zongyi', '综艺'),
    _Opt('manhua', '动漫'),
    _Opt('duanju', '短剧'),
    _Opt('live', '直播'),
  ];
  static const List<_Opt> _areas = [
    _Opt('', '全部'),
    _Opt('内地', '内地'),
    _Opt('港台', '港台'),
    _Opt('日韩', '日韩'),
    _Opt('欧美', '欧美'),
    _Opt('其他', '其他'),
  ];
  static const List<_Opt> _years = [
    _Opt('', '全部'),
    _Opt('2026', '2026'),
    _Opt('2025', '2025'),
    _Opt('2024', '2024'),
    _Opt('2023', '2023'),
    _Opt('2022', '2022'),
    _Opt('2021', '2021'),
    _Opt('2020', '2020'),
    _Opt('2019', '2019'),
    _Opt('2018', '2018'),
  ];
  static const List<_Opt> _sorts = [
    _Opt('latest', '最新'),
    _Opt('rating', '评分'),
    _Opt('hot', '热度'),
  ];

  final ScrollController _scroll = ScrollController();
  final List<VideoCard> _items = [];
  late String _type = widget.initialType;
  String _area = '';
  String _year = '';
  String _sort = 'latest';
  int _page = 1;
  int _req = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _moreError = false;
  String? _error;

  /// 已有内容时刷新失败：单独记错误并用 toast 提示，不占用首屏错误态，
  /// 也不阻塞继续上拉加载。
  String? _refreshError;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load(reset: true, clear: true);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    if (p.pixels >= p.maxScrollExtent - 320) _load(reset: false);
  }

  Future<void> _load({required bool reset, bool clear = false}) async {
    if (reset) {
      final req = ++_req;
      // 保留现有内容的刷新失败不该占整页错误态，否则上拉会被 _error 卡死。
      final refreshing = !clear && _items.isNotEmpty;
      setState(() {
        _loading = true;
        _loadingMore = false;
        _error = null;
        _refreshError = null;
        _moreError = false;
        _hasMore = true;
        _page = 1;
        if (clear) _items.clear();
      });
      try {
        final list = await Api.category(
            type: _type, area: _area, year: _year, sort: _sort, page: 1);
        if (!mounted || req != _req) return;
        setState(() {
          _items
            ..clear()
            ..addAll(list);
          _page = 1;
          _loading = false;
          _error = null;
          _refreshError = null;
          _hasMore = list.length >= 20;
        });
      } catch (e) {
        if (!mounted || req != _req) return;
        final message = fxErrorText(e);
        if (refreshing) {
          setState(() {
            _loading = false;
            _refreshError = message;
          });
          _toast('刷新失败：$message');
        } else {
          setState(() {
            _loading = false;
            _error = message;
          });
        }
      }
      return;
    }

    if (_loading || _loadingMore || !_hasMore) return;
    final req = _req;
    final next = _page + 1;
    setState(() {
      _loadingMore = true;
      _moreError = false;
    });
    try {
      final list = await Api.category(
          type: _type, area: _area, year: _year, sort: _sort, page: next);
      if (!mounted || req != _req) return;
      setState(() {
        _items.addAll(list);
        _page = next;
        _loadingMore = false;
        _refreshError = null;
        _hasMore = list.length >= 20;
      });
    } catch (e) {
      if (!mounted || req != _req) return;
      setState(() {
        _loadingMore = false;
        _moreError = true;
      });
    }
  }

  void _reload() {
    _load(reset: true, clear: true);
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xEE1B2430),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ));
  }

  Future<void> _pick(String title, List<_Opt> options, String current,
      void Function(String) apply) async {
    final v = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(.22),
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
        decoration: const BoxDecoration(
          color: Color(0xFFFBFDFF),
          borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 15),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDCE4F0),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(title,
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Fx.ink)),
              const SizedBox(height: 15),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final o in options)
                    ChipTag(o.label,
                        active: o.value == current,
                        onTap: () => Navigator.pop(ctx, o.value)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (v == null || !mounted) return;
    apply(v);
    _reload();
  }

  void _openDetail(String id) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DetailPage(id: id)),
    );
  }

  bool get _filtered =>
      _type.isNotEmpty ||
      _area.isNotEmpty ||
      _year.isNotEmpty ||
      _sort != 'latest';

  String _valueOf(List<_Opt> list, String v) {
    for (final o in list) {
      if (o.value == v) return o.label;
    }
    return v.isEmpty ? '全部' : v;
  }

  @override
  Widget build(BuildContext context) {
    final body = SafeArea(
      bottom: widget.standalone,
      child: _buildContent(context),
    );
    if (!widget.standalone) return body;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: FxBackground(child: body),
    );
  }

  Widget _buildContent(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final itemWidth = (width - 36 - 20) / 3;
    return RefreshIndicator(
      color: Fx.accent,
      backgroundColor: Colors.white,
      onRefresh: () => _load(reset: true),
      child: CustomScrollView(
        controller: _scroll,
        physics:
            const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        slivers: [
          SliverToBoxAdapter(child: _header()),
          if (_refreshError != null && _items.isNotEmpty)
            SliverToBoxAdapter(child: _refreshBanner()),
          if (_items.isEmpty && _loading)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: FxLoadingView(label: '正在加载片库…'),
            )
          else if (_items.isEmpty && _error != null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: FxErrorView(message: _error!, onRetry: _reload),
            )
          else if (_items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: FxEmptyView(
                icon: Icons.video_library_outlined,
                title: '这个筛选下还没有片子',
                subtitle: '换个类型或年份试试',
                actionText: _filtered ? '重置筛选' : null,
                onAction: _filtered
                    ? () {
                        setState(() {
                          _type = '';
                          _area = '';
                          _year = '';
                          _sort = 'latest';
                        });
                        _reload();
                      }
                    : null,
              ),
            )
          else ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 16,
                  mainAxisExtent: itemWidth * 1.5 + 46,
                ),
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) {
                    final item = _items[i];
                    return FxPosterCard(
                      item: item,
                      onTap: () => _openDetail(item.id),
                    );
                  },
                  childCount: _items.length,
                ),
              ),
            ),
            SliverToBoxAdapter(child: _footer()),
            SliverToBoxAdapter(
              child: SizedBox(height: widget.standalone ? 28 : 104),
            ),
          ],
        ],
      ),
    );
  }

  Widget _refreshBanner() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
      child: GestureDetector(
        onTap: () => _load(reset: true),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF3E6),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFFFD9AE)),
          ),
          child: Row(
            children: [
              const Icon(Icons.refresh_rounded,
                  size: 14, color: Color(0xFFB26A1F)),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  '刷新失败：${_refreshError!} · 点击重试',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFFB26A1F)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (widget.standalone) ...[
                GestureDetector(
                  onTap: () => Navigator.maybePop(context),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(.72),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white),
                    ),
                    child: const Icon(Icons.arrow_back_ios_new_rounded,
                        size: 17, color: Fx.ink),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              const Text('分类',
                  style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: Fx.ink,
                      letterSpacing: -.3)),
              const Spacer(),
              if (_filtered)
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _type = '';
                      _area = '';
                      _year = '';
                      _sort = 'latest';
                    });
                    _reload();
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(.7),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.restart_alt_rounded,
                            size: 14, color: Fx.sub),
                        SizedBox(width: 2),
                        Text('重置',
                            style: TextStyle(fontSize: 11, color: Fx.sub)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            widget.initialTitle == null
                ? '精选好剧，随心看'
                : '${widget.initialTitle} · 为你精选',
            style: const TextStyle(fontSize: 11.5, color: Fx.sub),
          ),
          const SizedBox(height: 13),
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _filterPill('类型', _valueOf(_types, _type), _type.isNotEmpty,
                    () => _pick('选择类型', _types, _type, (v) => _type = v)),
                const SizedBox(width: 8),
                _filterPill('地区', _valueOf(_areas, _area), _area.isNotEmpty,
                    () => _pick('选择地区', _areas, _area, (v) => _area = v)),
                const SizedBox(width: 8),
                _filterPill('年份', _valueOf(_years, _year), _year.isNotEmpty,
                    () => _pick('选择年份', _years, _year, (v) => _year = v)),
                const SizedBox(width: 8),
                _filterPill('排序', _valueOf(_sorts, _sort), _sort != 'latest',
                    () => _pick('排序方式', _sorts, _sort, (v) => _sort = v)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.grid_view_rounded, size: 13, color: Fx.sub),
              const SizedBox(width: 5),
              Text('已加载 ${_items.length} 部',
                  style: const TextStyle(fontSize: 11, color: Fx.sub)),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _filterPill(
      String label, String value, bool active, VoidCallback onTap) {
    final color = active ? Fx.accent : Fx.ink;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: active
              ? Fx.accent.withOpacity(.10)
              : Colors.white.withOpacity(.72),
          borderRadius: BorderRadius.circular(17),
          border: Border.all(
            color: active ? Fx.accent.withOpacity(.55) : Colors.white,
            width: active ? 1.1 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 11.5, color: active ? Fx.accent : Fx.sub)),
            const SizedBox(width: 3),
            Text(value,
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: color)),
            const SizedBox(width: 1),
            Icon(Icons.expand_more_rounded,
                size: 15, color: active ? Fx.accent : Fx.sub),
          ],
        ),
      ),
    );
  }

  Widget _footer() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 22),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Fx.accent),
            ),
          ),
        ),
      );
    }
    if (_moreError) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: GestureDetector(
            onTap: () => _load(reset: false),
            child: const Text('加载失败，点击重试',
                style: TextStyle(fontSize: 12, color: Fx.accent)),
          ),
        ),
      );
    }
    if (!_hasMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 22),
        child: Center(
          child: Text('— 已经到底啦 —',
              style: TextStyle(fontSize: 11, color: Color(0xFFA6B1C2))),
        ),
      );
    }
    return const SizedBox(height: 16);
  }
}

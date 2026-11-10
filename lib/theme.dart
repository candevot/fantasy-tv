import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'api.dart';
import 'utils/fx_route.dart';

/// 大字体上限：跟随系统字号，但最多放大到 1.3 倍。
/// 超过 1.3 倍的极端字号会把固定高度的卡片 / 导航撑破，统一在根部截断。
TextScaler fxClampTextScaler(TextScaler scaler) =>
    scaler.clamp(maxScaleFactor: 1.3);

/// 幻想影视 · 白色液态玻璃主题
class Fx {
  static const Color ink = Color(0xFF1B2430);
  static const Color sub = Color(0xFF6B7686);
  static const Color accent = Color(0xFF5B8CFF);
  static const Color accent2 = Color(0xFF8E6BFF);
  static const Color gold = Color(0xFFFFB020);
  static const LinearGradient brand = LinearGradient(
    colors: [Color(0xFF5B8CFF), Color(0xFF8E6BFF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

class FxTheme {
  static ThemeData get data {
    final base = ThemeData.light(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: const Color(0xFFF6F8FC),
      colorScheme: base.colorScheme.copyWith(
        primary: Fx.accent,
        secondary: Fx.accent2,
        surface: Colors.white,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: Fx.ink,
        displayColor: Fx.ink,
      ),
      splashFactory: InkSparkle.splashFactory,
      // 全局页面过渡：横向轻推 + 淡入（见 utils/fx_route.dart）。
      // 默认的 ZoomPageTransitionsBuilder 是「整页从中心涨开」，
      // 首页→详情→播放连切两次时重心乱跳，观感很生硬。
      pageTransitionsTheme: fxPageTransitionsTheme,
    );
  }
}

/* ========================================================================== */
/*  网络图片：统一代理 / 微光占位 / 淡入                                      */
/* ========================================================================== */

const Color _fxImageBase = Color(0xFFE6E9EF);
const Color _fxImageHighlight = Color(0xFFF4F6FA);

/// 图片代理后的 [ImageProvider]；空地址 / 非法地址返回 null。
///
/// 与 [FxNetworkImage] 使用完全相同的 URL 和 cacheWidth，首页
/// [precacheImage] 才能命中同一份缓存，不会重复请求。
ImageProvider<Object>? fxImageProvider(
  String url, {
  int? cacheWidth,
  int? cacheHeight,
}) {
  final src = Api.imgProxy(url);
  if (src.isEmpty) return null;
  return ResizeImage.resizeIfNeeded(
    cacheWidth,
    cacheHeight,
    NetworkImage(src),
  );
}

/// 灰底 + 渐变微光的加载占位，1.2s 循环。
/// TickerMode 关闭（页面被盖住 / Tab 切走 / 应用退到后台）时自动暂停。
class FxShimmer extends StatefulWidget {
  const FxShimmer({super.key});

  @override
  State<FxShimmer> createState() => _FxShimmerState();
}

class _FxShimmerState extends State<FxShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          return Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(-2.4 + 4.8 * t, 0),
                end: Alignment(0.4 + 4.8 * t, 0),
                colors: const <Color>[
                  _fxImageBase,
                  _fxImageHighlight,
                  _fxImageBase,
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 图片失败 / 地址无效占位：灰底 + 影片图标（不出现纯白块）。
class FxImageFallback extends StatelessWidget {
  const FxImageFallback({
    super.key,
    this.icon = Icons.movie_outlined,
    this.iconSize = 30,
    this.iconColor = const Color(0xFF98A4B5),
  });

  final IconData icon;
  final double iconSize;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _fxImageBase,
      child: Center(
        child: Icon(icon, size: iconSize, color: iconColor),
      ),
    );
  }
}

/// 首帧 150ms 淡入：占位切到图片时不闪。
class FxFadeIn extends StatelessWidget {
  const FxFadeIn({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 150),
  });

  final Widget child;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: duration,
      curve: Curves.easeOut,
      child: child,
      builder: (context, value, child) => Opacity(opacity: value, child: child),
    );
  }
}

/// 统一网络图组件：
/// - 地址统一走 [Api.imgProxy]，本站 / 本机地址直连；
/// - 加载中灰底微光，失败显示图标，首帧 150ms 淡入；
/// - 同一 URL 复用 ImageProvider 缓存，列表回收不重复请求。
class FxNetworkImage extends StatelessWidget {
  const FxNetworkImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.cacheWidth,
    this.cacheHeight,
    this.filterQuality = FilterQuality.low,
    this.fallback,
    this.fallbackIcon = Icons.movie_outlined,
    this.fallbackIconSize = 30,
    this.semanticLabel,
  });

  final String url;
  final BoxFit fit;
  final double? width;
  final double? height;
  final int? cacheWidth;
  final int? cacheHeight;
  final FilterQuality filterQuality;
  final Widget? fallback;
  final IconData fallbackIcon;
  final double fallbackIconSize;
  final String? semanticLabel;

  Widget _fallback() {
    final custom = fallback;
    if (custom != null) return custom;
    return FxImageFallback(
      icon: fallbackIcon,
      iconSize: fallbackIconSize,
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = fxImageProvider(
      url,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
    );
    Widget image;
    if (provider == null) {
      image = _fallback();
    } else {
      image = Image(
        image: provider,
        width: width,
        height: height,
        fit: fit,
        filterQuality: filterQuality,
        semanticLabel: semanticLabel,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded) return child;
          if (frame == null) return const FxShimmer();
          return FxFadeIn(child: child);
        },
        errorBuilder: (context, error, stackTrace) => _fallback(),
      );
    }
    if (width == null && height == null) return image;
    return SizedBox(width: width, height: height, child: image);
  }
}

/// 液态光斑背景
class FxBackground extends StatefulWidget {
  const FxBackground({super.key, required this.child});
  final Widget child;

  @override
  State<FxBackground> createState() => _FxBackgroundState();
}

class _FxBackgroundState extends State<FxBackground>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// 背景只是缓慢流动的光斑，30fps 肉眼无差别，比 60fps 少一半重绘。
  static const Duration _frameInterval = Duration(milliseconds: 33);
  static const double _loopSeconds = 18;

  late final Ticker _ticker = createTicker(_onTick);
  final ValueNotifier<double> _phase = ValueNotifier<double>(0);

  Duration _lastTick = Duration.zero;
  double _phaseBase = 0;
  bool _tickerMode = true;
  bool _resumed = true;
  // getValuesNotifier 的类型是 TickerModeData，取 .enabled 才是 bool。
  ValueListenable<TickerModeData>? _modeNotifier;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 跟随最近的 TickerMode：被 IndexedStack 隐藏的 Tab、被新页面盖住的
    // 路由、以及显式 TickerMode(enabled:false) 都会自动暂停动画。
    // getValuesNotifier 的值是 TickerModeData，.enabled 才是 bool。
    final mode = TickerMode.getValuesNotifier(context);
    if (!identical(mode, _modeNotifier)) {
      _modeNotifier?.removeListener(_onTickerModeChanged);
      _modeNotifier = mode..addListener(_onTickerModeChanged);
      _tickerMode = mode.value.enabled;
    }
    _syncTicker();
  }

  void _onTickerModeChanged() {
    _tickerMode = _modeNotifier?.value.enabled ?? true;
    _syncTicker();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _syncTicker();
  }

  void _syncTicker() {
    if (!mounted) return;
    if (_tickerMode && _resumed) {
      // 用 isActive 而不是 isTicking：muted / 引擎暂停时 isTicking 为 false，
      // 但 Ticker 仍处于 active，直接 start 会触发「started twice」。
      if (!_ticker.isActive) {
        _lastTick = Duration.zero;
        _ticker.start();
      }
    } else if (_ticker.isActive) {
      // Ticker 重新 start 后 elapsed 会从 0 开始，先把当前相位记下来，
      // 恢复时不会瞬间跳一帧。
      _phaseBase = _phase.value;
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    if (elapsed - _lastTick < _frameInterval) return;
    _lastTick = elapsed;
    _phase.value =
        (_phaseBase + elapsed.inMicroseconds / 1000000) % _loopSeconds;
  }

  @override
  void dispose() {
    _modeNotifier?.removeListener(_onTickerModeChanged);
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0xFFF7FAFF),
                  Color(0xFFFDFBFF),
                  Color(0xFFF4FAFF)
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
        ),
        Positioned.fill(
          // 单独成层：背景每帧重绘时，页面内容不需要跟着重绘。
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _phase,
              builder: (_, __) {
                final t = _phase.value / _loopSeconds * math.pi * 2;
                return CustomPaint(
                  painter: _BlobPainter(t),
                  isComplex: true,
                  willChange: true,
                );
              },
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _BlobPainter extends CustomPainter {
  _BlobPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    void blob(Offset c, double r, Color color) {
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [color.withValues(alpha: .55), color.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: c, radius: r));
      canvas.drawCircle(c, r, paint);
    }

    blob(
        Offset(size.width * .18 + 24 * math.cos(t),
            size.height * .14 + 18 * math.sin(t)),
        size.width * .55,
        const Color(0xFFBBD6FF));
    blob(
        Offset(size.width * .92 + 20 * math.sin(t * .8),
            size.height * .42 + 24 * math.cos(t * .7)),
        size.width * .5,
        const Color(0xFFDCCFFF));
    blob(Offset(size.width * .3, size.height * .92 + 20 * math.sin(t * .6)),
        size.width * .55, const Color(0xFFCFF0EA));
  }

  @override
  bool shouldRepaint(_BlobPainter old) => old.t != t;
}

/// 玻璃卡片
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 20,
    this.onTap,
    this.margin,
    this.opacity = .62,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final VoidCallback? onTap;
  final EdgeInsets? margin;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    // 卡片自带大范围阴影 + 半透明背景，单独成层后滚动时不会带着
    // 整页一起重绘（列表里的卡片都已由 Sliver 自动分层，这里兜住
    // 非列表场景，同时让列表卡片的边界固定落在卡片本身）。
    final box = RepaintBoundary(
      child: Container(
        margin: margin,
        padding: padding,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: opacity),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: Colors.white.withValues(alpha: .9), width: 1),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF50729F).withValues(alpha: .10),
              blurRadius: 30,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: child,
      ),
    );
    if (onTap == null) return box;
    return GestureDetector(onTap: onTap, child: box);
  }
}

/// 渐变胶囊按钮
class GradButton extends StatelessWidget {
  const GradButton(
      {super.key, required this.text, this.onTap, this.height = 46, this.icon});

  final String text;
  final VoidCallback? onTap;
  final double height;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: Fx.brand,
          borderRadius: BorderRadius.circular(height / 2),
          boxShadow: [
            BoxShadow(
              color: Fx.accent.withValues(alpha: .35),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(width: 6),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(text,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 小胶囊标签
class ChipTag extends StatelessWidget {
  const ChipTag(this.text, {super.key, this.active = false, this.onTap});
  final String text;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: active
              ? Fx.accent.withValues(alpha: .12)
              : Colors.white.withValues(alpha: .7),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? Fx.accent : Colors.white.withValues(alpha: .9),
            width: active ? 1.2 : 1,
          ),
        ),
        child: Text(text,
            style: TextStyle(
              fontSize: 13,
              color: active ? Fx.accent : Fx.sub,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            )),
      ),
    );
  }
}

/// 评分角标
class RatingBadge extends StatelessWidget {
  const RatingBadge(this.score, {super.key});
  final num score;

  @override
  Widget build(BuildContext context) {
    // 服务端已把未知评分输出 null（模型里退化成 0）；这里再兜底一次：
    // 0 / 负数 / >10 都不渲染角标，避免出现假的 0.0 / 10.0。
    if (!score.isFinite || score <= 0 || score > 10) {
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(score.toStringAsFixed(1),
          style: const TextStyle(
              color: Fx.gold, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }
}

/// 通用标题栏
class FxAppBar extends StatelessWidget implements PreferredSizeWidget {
  const FxAppBar({super.key, required this.title, this.actions, this.onBack});
  final String title;
  final List<Widget>? actions;
  final VoidCallback? onBack;

  @override
  Size get preferredSize => const Size.fromHeight(52);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      automaticallyImplyLeading: false,
      title: Text(title,
          style: const TextStyle(
              fontSize: 17, fontWeight: FontWeight.w700, color: Fx.ink)),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
        onPressed: onBack ?? () => Navigator.maybePop(context),
      ),
      actions: actions,
    );
  }
}

/* ========================================================================== */
/*  全局兜底错误组件（main.dart / ErrorWidget.builder 使用）                    */
/* ========================================================================== */

/// 渲染错误兜底：不依赖 MaterialApp / Theme / MediaQuery / Scaffold，
/// 即使 build 阶段抛错、或错误发生在 App 之外，也不会出现灰屏。
class FxFatalErrorView extends StatelessWidget {
  const FxFatalErrorView({
    super.key,
    this.title = '页面开小差了',
    this.message = '这部分内容没能显示出来，返回上一页再试试',
  });

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      constraints: const BoxConstraints(maxWidth: 340),
      padding: const EdgeInsets.fromLTRB(24, 26, 24, 22),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .94),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF50729F).withValues(alpha: .14),
            blurRadius: 30,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: Fx.accent.withValues(alpha: .10),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.sentiment_dissatisfied_rounded,
                size: 28, color: Fx.accent),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Fx.ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              height: 1.5,
              color: Fx.sub,
            ),
          ),
        ],
      ),
    );
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        color: const Color(0xFFF6F8FC),
        child: LayoutBuilder(
          builder: (_, constraints) {
            final minHeight = constraints.maxHeight.isFinite
                ? math.max(0.0, constraints.maxHeight - 32)
                : 0.0;
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: minHeight),
                child: Center(child: card),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 启动失败提示条：首页顶部显示，带「重试」入口，不阻塞其它页面。
class FxErrorBanner extends StatelessWidget {
  const FxErrorBanner({
    super.key,
    required this.message,
    this.title = '部分服务未就绪',
    this.onRetry,
    this.retrying = false,
  });

  final String title;
  final String message;
  final VoidCallback? onRetry;
  final bool retrying;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 11, 10, 11),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .94),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFFFD9A8)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF50729F).withValues(alpha: .14),
            blurRadius: 22,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Fx.gold.withValues(alpha: .12),
              shape: BoxShape.circle,
            ),
            child:
                const Icon(Icons.cloud_off_rounded, size: 19, color: Fx.gold),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Fx.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    height: 1.35,
                    color: Fx.sub,
                  ),
                ),
              ],
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: retrying ? null : onRetry,
              child: Container(
                constraints: const BoxConstraints(minWidth: 52),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Fx.accent.withValues(alpha: .10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: retrying
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: Fx.accent,
                        ),
                      )
                    : const Text(
                        '重试',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Fx.accent,
                        ),
                      ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

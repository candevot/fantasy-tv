import 'dart:math' as math;

import 'package:flutter/material.dart';

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
    );
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
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 18))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
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
                colors: [Color(0xFFF7FAFF), Color(0xFFFDFBFF), Color(0xFFF4FAFF)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, __) {
              final t = _c.value * math.pi * 2;
              return CustomPaint(painter: _BlobPainter(t));
            },
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
          colors: [color.withOpacity(.55), color.withOpacity(0)],
        ).createShader(Rect.fromCircle(center: c, radius: r));
      canvas.drawCircle(c, r, paint);
    }

    blob(Offset(size.width * .18 + 24 * math.cos(t), size.height * .14 + 18 * math.sin(t)),
        size.width * .55, const Color(0xFFBBD6FF));
    blob(Offset(size.width * .92 + 20 * math.sin(t * .8), size.height * .42 + 24 * math.cos(t * .7)),
        size.width * .5, const Color(0xFFDCCFFF));
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
    final box = Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(opacity),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white.withOpacity(.9), width: 1),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF50729F).withOpacity(.10),
            blurRadius: 30,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
    if (onTap == null) return box;
    return GestureDetector(onTap: onTap, child: box);
  }
}

/// 渐变胶囊按钮
class GradButton extends StatelessWidget {
  const GradButton({super.key, required this.text, this.onTap, this.height = 46, this.icon});

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
              color: Fx.accent.withOpacity(.35),
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
                      color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
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
          color: active ? Fx.accent.withOpacity(.12) : Colors.white.withOpacity(.7),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: active ? Fx.accent : Colors.white.withOpacity(.9),
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
        color: Colors.black.withOpacity(.45),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(score.toStringAsFixed(1),
          style: const TextStyle(color: Fx.gold, fontSize: 11, fontWeight: FontWeight.w700)),
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
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Fx.ink)),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
        onPressed: onBack ?? () => Navigator.maybePop(context),
      ),
      actions: actions,
    );
  }
}

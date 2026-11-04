import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'auth.dart';
import 'theme.dart';
import 'pages/home_page.dart';
import 'pages/category_page.dart';
import 'pages/rank_page.dart';
import 'pages/mine_page.dart';
import 'pages/detail_page.dart';
import 'pages/search_page.dart';
import 'pages/together_page.dart';
import 'pages/player_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Api.init();
  await Auth.instance.init();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarContrastEnforced: false,
  ));
  runApp(const FantasyApp());
}

class FantasyApp extends StatelessWidget {
  const FantasyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '幻想影视',
      debugShowCheckedModeBanner: false,
      theme: FxTheme.data,
      home: const SplashPage(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
        child: child ?? const SizedBox.shrink(),
      ),
    );
  }
}

/// 启动动画：液态光斑汇聚 + 幻字玻璃反光
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 2000))
    ..forward();

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        Navigator.of(context).pushReplacement(PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 350),
          pageBuilder: (_, __, ___) => const RootShell(),
          transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
        ));
      }
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedBuilder(
        animation: _c,
        builder: (context, __) {
          final t = _c.value;
          final pop = Curves.easeOutBack.transform((t / .5).clamp(0.0, 1.0));
          final fadeText = Curves.easeOut.transform(((t - .45) / .35).clamp(0.0, 1.0));
          final sheen = ((t - .42) / .3).clamp(0.0, 1.0); // 玻璃反光扫过
          return Stack(
            fit: StackFit.expand,
            children: [
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFFF7FAFF), Color(0xFFFDFBFF), Color(0xFFF4FAFF)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
              ),
              CustomPaint(painter: _SplashBlobPainter(t)),
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Opacity(
                      opacity: (t / .3).clamp(0.0, 1.0),
                      child: Transform.scale(
                        scale: .72 + .28 * pop,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(30),
                          child: SizedBox(
                            width: 118,
                            height: 118,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                const DecoratedBox(
                                  decoration: BoxDecoration(gradient: Fx.brand),
                                ),
                                // 高光扫过
                                Transform.translate(
                                  offset: Offset((sheen * 2 - 1) * 150, 0),
                                  child: Transform.rotate(
                                    angle: .35,
                                    child: Container(
                                      width: 46,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [
                                            Colors.white.withOpacity(0),
                                            Colors.white.withOpacity(.55),
                                            Colors.white.withOpacity(0),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const Center(
                                  child: Text('幻',
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 62,
                                          fontWeight: FontWeight.w900)),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 26),
                    Opacity(
                      opacity: fadeText,
                      child: Transform.translate(
                        offset: Offset(0, 12 * (1 - fadeText)),
                        child: const Text('幻想影视',
                            style: TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                color: Fx.ink,
                                letterSpacing: 3)),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Opacity(
                      opacity: fadeText,
                      child: const Text('高清 · 免费 · 无广告',
                          style: TextStyle(fontSize: 12, color: Fx.sub, letterSpacing: 1.5)),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 40,
                child: Opacity(
                  opacity: fadeText * .8,
                  child: const Text('FANTASY  TV',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 10, letterSpacing: 6, color: Color(0xFF9AA6B8))),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SplashBlobPainter extends CustomPainter {
  _SplashBlobPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    // 光斑从四周向中心汇聚（0→0.45），之后缓慢散开
    final conv = t < .45 ? Curves.easeOutCubic.transform(t / .45) : 1.0;
    final spread = t < .45 ? 0.0 : Curves.easeOutSine.transform(((t - .45) / .55).clamp(0.0, 1.0));
    final center = Offset(size.width / 2, size.height * .42);
    void blob(double angle, double dist, double radius, Color color, double phase) {
      final d = dist * (1 - conv * .55) * (1 + spread * .35);
      final c = Offset(
        center.dx + d * math.cos(angle + phase * .3 + t),
        center.dy + d * math.sin(angle + phase * .3 + t),
      );
      final r = radius * (.75 + .25 * conv);
      final paint = Paint()
        ..shader = RadialGradient(colors: [
          color.withOpacity(.5 * conv),
          color.withOpacity(0),
        ]).createShader(Rect.fromCircle(center: c, radius: r));
      canvas.drawCircle(c, r, paint);
    }

    blob(-2.4, size.width * .42, size.width * .52, const Color(0xFFBBD6FF), 0);
    blob(-0.6, size.width * .5, size.width * .5, const Color(0xFFDCCFFF), 1);
    blob(1.2, size.width * .45, size.width * .55, const Color(0xFFCFF0EA), 2);
  }

  @override
  bool shouldRepaint(_SplashBlobPainter old) => old.t != t;
}

/// 主框架：4 个 Tab
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _i = 0;

  static const _tabs = [
    (icon: Icons.home_rounded, label: '首页'),
    (icon: Icons.grid_view_rounded, label: '分类'),
    (icon: Icons.local_fire_department_rounded, label: '排行榜'),
    (icon: Icons.person_rounded, label: '我的'),
  ];

  @override
  Widget build(BuildContext context) {
    final pages = [
      const HomePage(),
      const CategoryPage(),
      const RankPage(),
      const MinePage(),
    ];
    return Scaffold(
      extendBody: true,
      body: FxBackground(
        child: IndexedStack(index: _i, children: pages),
      ),
      bottomNavigationBar: Padding(
        padding: EdgeInsets.only(
            left: 14, right: 14, bottom: 10 + MediaQuery.of(context).padding.bottom * .4),
        child: Container(
          height: 62,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.78),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: Colors.white.withOpacity(.95)),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF5B7BAF).withOpacity(.16),
                blurRadius: 26,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: List.generate(_tabs.length, (i) {
              final on = i == _i;
              final tab = _tabs[i];
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _i = i),
                child: SizedBox(
                  width: 68,
                  height: 62,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(tab.icon,
                          size: 23, color: on ? Fx.accent : const Color(0xFF9AA6B8)),
                      const SizedBox(height: 2),
                      Text(tab.label,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: on ? Fx.accent : const Color(0xFF9AA6B8),
                            fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                          )),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

/// 统一导航
class Nav {
  static Future<void> detail(BuildContext c, String id) => Navigator.of(c).push(
      MaterialPageRoute(builder: (_) => DetailPage(id: id)));

  static Future<void> search(BuildContext c) =>
      Navigator.of(c).push(MaterialPageRoute(builder: (_) => const SearchPage()));

  static Future<void> together(BuildContext c, {String? videoId, int? ep}) =>
      Navigator.of(c).push(MaterialPageRoute(
          builder: (_) => TogetherPage(videoId: videoId, ep: ep ?? 1)));

  static Future<void> player(BuildContext c, {required String id, int ep = 1, String line = ''}) =>
      Navigator.of(c).push(MaterialPageRoute(
          builder: (_) => PlayerPage(videoId: id, ep: ep, line: line)));
}

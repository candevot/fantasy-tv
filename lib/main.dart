import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
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

/// 启动动画：液态光斑汇聚 + logo 呼吸
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..forward();

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        Navigator.of(context).pushReplacement(
          PageRouteBuilder(
            transitionDuration: const Duration(milliseconds: 350),
            pageBuilder: (_, __, ___) => const RootShell(),
            transitionsBuilder: (_, a, __, child) =>
                FadeTransition(opacity: a, child: child),
          ),
        );
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
      body: FxBackground(
        child: Center(
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, __) {
              final t = Curves.easeOutCubic.transform(_c.value);
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Opacity(
                    opacity: t.clamp(0.0, 1.0),
                    child: Transform.scale(
                      scale: .82 + .18 * t,
                      child: Container(
                        width: 118,
                        height: 118,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(30),
                          gradient: Fx.brand,
                          boxShadow: [
                            BoxShadow(
                              color: Fx.accent.withOpacity(.35 * t),
                              blurRadius: 40,
                              offset: const Offset(0, 16),
                            ),
                          ],
                        ),
                        alignment: Alignment.center,
                        child: const Text('幻',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 62,
                                fontWeight: FontWeight.w900)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 26),
                  Opacity(
                    opacity: t,
                    child: const Text('幻想影视',
                        style: TextStyle(
                            fontSize: 26, fontWeight: FontWeight.w800, color: Fx.ink, letterSpacing: 2)),
                  ),
                  const SizedBox(height: 8),
                  Opacity(
                    opacity: t,
                    child: const Text('高清 4K · 多线路 · 纯净追剧',
                        style: TextStyle(fontSize: 12, color: Fx.sub, letterSpacing: 1.5)),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
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

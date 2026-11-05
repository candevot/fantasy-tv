import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

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

void main() {
  // 所有 Dart 异步异常的最后一道网；Framework / 平台异常另行接管。
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    _installErrorHandlers();
    try {
      await Boot.run();
    } catch (e, st) {
      // 兜底中的兜底：无论启动流程发生什么，都必须进入主界面。
      AppLog.write('boot', e, st);
    }
    runApp(const FantasyApp());
  }, (error, stack) {
    AppLog.write('zone', error, stack);
  });
}

/// 全局异常兜底：框架异常、平台异常、渲染异常都落日志 + 友好占位。
void _installErrorHandlers() {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    AppLog.write('flutter', details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    AppLog.write('platform', error, stack);
    // 已记录并展示兜底 UI，不再让引擎直接崩掉。
    return true;
  };
  // 任何 build / layout / paint 异常都渲染友好占位，而不是灰色 ErrorWidget。
  ErrorWidget.builder = (_) => const FxFatalErrorView();
}

/// 启动流程：每一步都容错，失败只标记状态，绝不阻塞进入主界面。
class Boot {
  Boot._();

  /// 非空时首页顶部展示启动失败提示 + 重试入口。
  static final ValueNotifier<String?> failure = ValueNotifier<String?>(null);

  static bool _running = false;

  static Future<void> run() async {
    if (_running) return;
    _running = true;
    String? failed;

    try {
      MediaKit.ensureInitialized();
    } catch (e, st) {
      AppLog.write('boot.media_kit', e, st);
    }

    try {
      await Api.init().timeout(const Duration(seconds: 5));
    } catch (e, st) {
      AppLog.write('boot.api', e, st);
      failed = '配置加载失败，已使用默认线路';
    }

    try {
      await Auth.instance.init().timeout(const Duration(seconds: 5));
    } catch (e, st) {
      AppLog.write('boot.auth', e, st);
      failed ??= '登录状态读取失败，部分功能可能不可用';
    }

    try {
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
    } catch (e, st) {
      AppLog.write('boot.chrome', e, st);
    }

    failure.value = failed;
    _running = false;
  }
}

/// 本地崩溃日志：`<ApplicationSupport>/logs/app.log`，只保留最近 200 条。
class AppLog {
  AppLog._();

  static const int maxEntries = 200;
  static Future<void> _queue = Future<void>.value();

  /// 日志本身绝不抛异常，避免二次崩溃；写入串行排队防止并发截断。
  static void write(String scope, Object error, [StackTrace? stack]) {
    final buffer = StringBuffer()
      ..write(DateTime.now().toIso8601String())
      ..write(' [')
      ..write(scope)
      ..write('] ')
      ..write(_oneLine('$error'));
    if (stack != null) {
      buffer
        ..write(' | ')
        ..write(_oneLine('$stack'));
    }
    var entry = buffer.toString();
    if (entry.length > 4000) entry = '${entry.substring(0, 4000)}…';
    _queue = _queue.then((_) => _appendSafe(entry));
  }

  static String _oneLine(String text) =>
      text.replaceAll('\r', ' ').replaceAll('\n', ' ⏎ ');

  static Future<void> _appendSafe(String entry) async {
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/logs');
      if (!await dir.exists()) await dir.create(recursive: true);
      final file = File('${dir.path}/app.log');
      var lines = <String>[];
      if (await file.exists()) lines = await file.readAsLines();
      lines.add(entry);
      if (lines.length > maxEntries) {
        lines = lines.sublist(lines.length - maxEntries);
      }
      await file.writeAsString('${lines.join('\n')}\n', flush: true);
    } catch (_) {
      // 存储不可用时静默放弃，不影响 App 运行。
    }
  }
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
                      child: const Text('高画 · 免费 · 无广',
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
        child: Stack(
          children: [
            IndexedStack(index: _i, children: pages),
            if (_i == 0)
              Positioned(
                top: 0,
                left: 14,
                right: 14,
                child: SafeArea(
                  bottom: false,
                  child: ValueListenableBuilder<String?>(
                    valueListenable: Boot.failure,
                    builder: (_, message, __) {
                      if (message == null) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _BootRetryBanner(message: message),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
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

class _BootRetryBanner extends StatefulWidget {
  const _BootRetryBanner({required this.message});

  final String message;

  @override
  State<_BootRetryBanner> createState() => _BootRetryBannerState();
}

class _BootRetryBannerState extends State<_BootRetryBanner> {
  bool _retrying = false;

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    await Boot.run();
    if (mounted) setState(() => _retrying = false);
  }

  @override
  Widget build(BuildContext context) {
    return FxErrorBanner(
      message: widget.message,
      onRetry: _retry,
      retrying: _retrying,
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

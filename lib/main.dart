import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'auth.dart';
import 'fx_globals.dart';
import 'services/app_update_service.dart';
import 'services/download_service.dart';
import 'theme.dart';
import 'widgets/update_dialog.dart';
import 'pages/home_page.dart';
import 'pages/live_all_page.dart';
import 'pages/rank_page.dart';
import 'pages/mine_page.dart';
import 'pages/detail_page.dart';
import 'pages/search_page.dart';
import 'pages/together_page.dart';
import 'pages/player_page.dart';
import 'utils/fx_route.dart';

void main() {
  // 所有 Dart 异步异常的最后一道网；Framework / 平台异常另行接管。
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    _installErrorHandlers();
    // IMAGE_CACHE（2026-11-12）：调大图片缓存。
    //
    // Flutter 默认 1000 张 / 100MB。首页一轮就要 66 张不同地址的海报，
    // 加上每个卡片按显示宽度做 ResizeImage，同一张图会以不同 cacheWidth
    // 各存一份 —— 100MB 很容易撑爆。
    //
    // 一旦超标，ImageCache 按 LRU 淘汰，正在显示的图被淘汰后
    // 回来时重新解码；表现就是「部分封面空白，滑动一下才出来」。
    //
    // 这里放宽到 2000 张 / 512MB：常规浏览量完全装得下，
    // 系统内存紧张时 Flutter 仍会自行回收。
    PaintingBinding.instance.imageCache
      ..maximumSize = 2000
      ..maximumSizeBytes = 512 * 1024 * 1024;
    // 首帧只负责出界面：配置 / 登录态 / 内核初始化全部挪到首帧之后，
    // 启动阶段任何网络或磁盘等待都不再挡住首屏。
    runApp(const FantasyApp());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(Boot.run());
    });
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

    // 下载服务启动即恢复队列（幂等）：暂停中的任务保持暂停，不自动跑。
    // 放在首帧之后，不阻塞启动；失败只记日志，不影响进入主界面。
    unawaited(
      DownloadService.instance.init().catchError(
        (Object error, StackTrace stack) {
          AppLog.write('boot.downloads', error, stack);
        },
      ),
    );

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

class FantasyApp extends StatefulWidget {
  const FantasyApp({super.key});

  @override
  State<FantasyApp> createState() => _FantasyAppState();
}

class _FantasyAppState extends State<FantasyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 下载任务跑在主 isolate 里；切后台只记录状态，不暂停、不取消任务。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    DownloadService.instance.handleLifecycle(state);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '幻想影视',
      debugShowCheckedModeBanner: false,
      theme: FxTheme.data,
      // 全局提示入口：网络 401 这类没有 BuildContext 的地方也能弹 SnackBar。
      scaffoldMessengerKey: fxMessengerKey,
      // 顶栏小标签（已投屏 / 跟随房主）挂根 Overlay 用，播放页不弹遮挡提示。
      navigatorKey: fxNavigatorKey,
      // 深色模式下也固定浅色主题：自绘玻璃卡片是按浅色校准的，
      // 跟随系统切到深色会出现低对比度 / 白底白字。
      darkTheme: FxTheme.data,
      themeMode: ThemeMode.light,
      home: const SplashPage(),
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          // 大字体最多跟随到 1.3 倍，再大就统一截断，避免固定高度布局溢出。
          data: mq.copyWith(textScaler: fxClampTextScaler(mq.textScaler)),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}

/// 启动动画：液态光斑汇聚 + 幻字玻璃反光
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage>
    with SingleTickerProviderStateMixin {
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
          transitionsBuilder: (_, a, __, child) =>
              FadeTransition(opacity: a, child: child),
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
          final fadeText =
              Curves.easeOut.transform(((t - .45) / .35).clamp(0.0, 1.0));
          final sheen = ((t - .42) / .3).clamp(0.0, 1.0); // 玻璃反光扫过
          return Stack(
            fit: StackFit.expand,
            children: [
              const DecoratedBox(
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
                                            Colors.white.withValues(alpha: 0),
                                            Colors.white.withValues(alpha: .55),
                                            Colors.white.withValues(alpha: 0),
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
                          style: TextStyle(
                              fontSize: 12, color: Fx.sub, letterSpacing: 1.5)),
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
                          fontSize: 10,
                          letterSpacing: 6,
                          color: Color(0xFF9AA6B8))),
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
    final spread = t < .45
        ? 0.0
        : Curves.easeOutSine.transform(((t - .45) / .55).clamp(0.0, 1.0));
    final center = Offset(size.width / 2, size.height * .42);
    void blob(
        double angle, double dist, double radius, Color color, double phase) {
      final d = dist * (1 - conv * .55) * (1 + spread * .35);
      final c = Offset(
        center.dx + d * math.cos(angle + phase * .3 + t),
        center.dy + d * math.sin(angle + phase * .3 + t),
      );
      final r = radius * (.75 + .25 * conv);
      final paint = Paint()
        ..shader = RadialGradient(colors: [
          color.withValues(alpha: .5 * conv),
          color.withValues(alpha: 0),
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

  /// 首次进入的 Tab 才创建页面：分类 / 排行榜 / 我的都要在 initState
  /// 里请求数据，全部预建会让启动瞬间并发 4 个请求。
  final Set<int> _visited = <int>{0};

  static const _tabs = [
    (icon: Icons.home_rounded, label: '首页'),
    (icon: Icons.live_tv_rounded, label: '直播'),
    (icon: Icons.local_fire_department_rounded, label: '排行榜'),
    (icon: Icons.person_rounded, label: '我的'),
  ];

  Timer? _updateTimer;

  @override
  void initState() {
    super.initState();
    // 进主界面后延迟 ~1.7s 再查更新：避开启动动画 / 首页首屏请求。
    // 每次冷启动只查一次；本次会话弹过（版本没变）就不再弹。
    _updateTimer = Timer(const Duration(milliseconds: 1700), _checkUpdateOnStart);
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  /// 启动自动检查更新：失败（网络 / 超时 5s）静默返回，绝不打扰启动。
  Future<void> _checkUpdateOnStart() async {
    if (!mounted || !AppUpdateService.claimStartupCheck()) return;
    final info = await AppUpdateService.checkQuietly();
    if (info == null || !mounted) return;
    if (!AppUpdateService.shouldPrompt(info.versionCode)) return;
    await showAppUpdateDialog(context, info);
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      const HomePage(),
      const LiveAllPage(),
      const RankPage(),
      const MinePage(),
    ];
    return Scaffold(
      extendBody: true,
      body: FxBackground(
        child: Stack(
          children: [
            IndexedStack(
              index: _i,
              children: [
                // 只让当前 Tab 的动画 / 定时器运行；隐藏 Tab 的
                // 背景光斑、骨架呼吸、banner 轮播全部暂停。
                for (var i = 0; i < pages.length; i++)
                  if (_visited.contains(i))
                    TickerMode(enabled: i == _i, child: pages[i])
                  else
                    const SizedBox.shrink(),
              ],
            ),
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
            left: 14,
            right: 14,
            bottom: 10 + MediaQuery.of(context).padding.bottom * .4),
        child: _FxBottomBar(
          index: _i,
          items: _tabs,
          onTap: (i) {
            if (i == _i) return;
            setState(() {
              _i = i;
              _visited.add(i);
            });
          },
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
  static Future<void> detail(BuildContext c, String id,
          {int ep = 1, String line = ''}) =>
      Navigator.of(c).push(FxPageRoute(
          builder: (_) => DetailPage(id: id, ep: ep, line: line)));

  static Future<void> search(BuildContext c) => Navigator.of(c)
      .push(FxPageRoute(builder: (_) => const SearchPage()));

  static Future<TogetherExitResult?> together(
    BuildContext c, {
    String? videoId,
    int? ep,
    String line = '',
    double position = 0,
    bool playing = false,
  }) =>
      Navigator.of(c).push<TogetherExitResult>(FxPageRoute(
          builder: (_) => TogetherPage(
                videoId: videoId,
                ep: ep ?? 1,
                line: line,
                position: position,
                playing: playing,
              )));

  static Future<void> player(BuildContext c,
          {required String id, int ep = 1, String line = ''}) =>
      Navigator.of(c).push(FxPageRoute(
          builder: (_) => PlayerPage(videoId: id, ep: ep, line: line)));
}

/// 底部导航：胶囊式悬浮栏 + 会滑动的选中高亮。
///
/// NAV_SLIDE（2026-11-14 用户给了参考录屏）：
///   之前选中项只是变个颜色，切换时没有任何过渡，看着是「跳」的。
///   参考 App 的做法是：一整块圆角高亮在图标之间滑过去，
///   同时带一点柔和的光晕，图标 / 文字颜色跟着渐变。
///
/// 实现要点：
///   · 用等宽布局算位置，AnimatedPositioned 只做 left 的补间 —— 
///     比「每个 item 各自动画」省事，也不会出现两块高亮重叠。
///   · 高亮本身用渐变 + accent 光晕，不用图片，跟着主题色走。
///   · 图标做 0.92 → 1 的轻微放大，跟滑动同时收尾。
class _FxBottomBar extends StatelessWidget {
  const _FxBottomBar({
    required this.index,
    required this.items,
    required this.onTap,
  });

  final int index;
  final List<({IconData icon, String label})> items;
  final ValueChanged<int> onTap;

  static const Duration _dur = Duration(milliseconds: 320);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 62,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .80),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: Colors.white.withValues(alpha: .95)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF5B7BAF).withValues(alpha: .16),
            blurRadius: 26,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (ctx, cons) {
          final itemW = cons.maxWidth / items.length;
          return Stack(
            children: [
              // 滑动高亮：整块圆角在图标之间平移
              AnimatedPositioned(
                duration: _dur,
                curve: Curves.easeOutCubic,
                left: itemW * index + 7,
                width: itemW - 14,
                top: 6,
                bottom: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Fx.accent.withValues(alpha: .18),
                        Fx.accent.withValues(alpha: .07),
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Fx.accent.withValues(alpha: .20),
                        blurRadius: 14,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
              ),
              Row(
                children: List.generate(items.length, (i) {
                  final on = i == index;
                  final item = items[i];
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onTap(i),
                    child: SizedBox(
                      width: itemW,
                      height: 62,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // 颜色渐变 + 轻微放大：和高亮滑动同一个时长收尾
                          TweenAnimationBuilder<double>(
                            // end 变化时才补间：选中 1、未选中 0
                            tween: Tween<double>(begin: 0, end: on ? 1 : 0),
                            duration: _dur,
                            curve: Curves.easeOutCubic,
                            builder: (ctx, t, _) {
                              return Transform.scale(
                                scale: .92 + .08 * t,
                                child: Icon(
                                  item.icon,
                                  size: 23,
                                  color: Color.lerp(
                                    const Color(0xFF9AA6B8),
                                    Fx.accent,
                                    t,
                                  ),
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 2),
                          AnimatedDefaultTextStyle(
                            duration: _dur,
                            curve: Curves.easeOutCubic,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: on ? Fx.accent : const Color(0xFF9AA6B8),
                              fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                            ),
                            child: Text(item.label),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ],
          );
        },
      ),
    );
  }
}

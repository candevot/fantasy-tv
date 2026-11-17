/// 幻想影视 · TVBox jar 源（`{"type":3,"api":"csp_Xxx","ext":"…"}`）的 Dart 侧封装。
///
/// 分工：
///   · 原生（`android_src/kotlin/.../JarSpiderLoader.kt` + `JarSpiderPlugin.kt`）
///     负责装 jar、`DexClassLoader` 加载、反射调 Spider、超时与兜底；
///   · 这里负责**调通道** + **把 TVBox 的 JSON 转成我们的模型**
///     （[VideoCard] / [VideoDetail] / [PlayInfo]），页面完全不感知差异。
///
/// 转换为什么能这么薄：TVBox 的 `vod_play_from` / `vod_play_url` 与苹果CMS
/// 完全同构，所以直接复用 `cms_source.dart` 的 `parseLines` 切线路、复用
/// `cms_api.dart` 的 `cardOf` / `detailOf` 出模型 —— 线路判定（直链 / 需要
/// 解析）、集名补齐、空线路过滤这些坑都已经在那里踩过了。
///
/// 线程：原生侧自带后台线程并做 25 秒超时，通道返回的永远是
/// 「JSON 字符串」或「带 error 字段的 JSON」，所以这里只会抛 [ApiException]，
/// 调用方（source_hub / cms_bridge）按普通片源一样 try/catch 即可。
///
/// 已知限制（写清楚，别让用户以为是 bug）：
///   · `playerContent` 返回 `parse:1`（需要 WebView 嗅探的线路）时无法解析，
///     抛「该线路需要网页解析」，与 TVBox 之外的播放器行为一致；
///   · `api` 是类名，同一个 jar 里多个站点靠 `ext` 区分，所以缓存键是
///     `api + ext`，不能只用 `api`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

import '../api.dart';
import '../models.dart';
import 'cms_api.dart';
import 'cms_client.dart';
import 'cms_source.dart';
import 'jar_log.dart';

/// 当前 jar 的安装状态。
class JarStatus {
  const JarStatus({
    required this.installed,
    required this.path,
    required this.md5,
    required this.size,
    this.bundled = false,
    this.source = '',
  });

  const JarStatus.missing()
      : installed = false,
        path = '',
        md5 = '',
        size = 0,
        bundled = false,
        source = '';

  final bool installed;
  final String path;
  final String md5;
  final int size;

  /// 来自内置 assets（没有手动安装时也能用）。
  final bool bundled;

  /// downloaded / manual / bundled（原生记录）。
  final String source;

  /// 手动安装的那一份（区别于内置 / 自动下载，设置页文案用）。
  String get shortMd5 => md5.length <= 8 ? md5 : md5.substring(0, 8);

  /// 「1.5 MB」这种人看的体积。
  String get sizeLabel {
    if (size <= 0) return '未知大小';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(0)} KB';
    return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// jar 安装进度阶段（原生 `jarInstallProgress` 的 phase 字段）。
enum JarInstallPhase { start, download, verify, install, done, error }

/// 一次安装的进度快照。
///
/// 原生每 250ms 回传一次（下载阶段），`percent < 0` 表示服务器没给
/// Content-Length，进度不确定（此时 UI 显示滚动条而不是百分比）。
class JarInstallProgress {
  const JarInstallProgress({
    required this.phase,
    this.received = 0,
    this.total = 0,
    this.percent = -1,
    this.url = '',
  });

  factory JarInstallProgress.fromMap(Object? raw) {
    final map = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final phase = switch ('${map['phase'] ?? ''}') {
      'start' => JarInstallPhase.start,
      'download' => JarInstallPhase.download,
      'verify' => JarInstallPhase.verify,
      'install' => JarInstallPhase.install,
      'done' => JarInstallPhase.done,
      'error' => JarInstallPhase.error,
      _ => JarInstallPhase.download,
    };
    return JarInstallProgress(
      phase: phase,
      received: _intOf(map['received']),
      total: _intOf(map['total']),
      percent: _intOf(map['percent'], fallback: -1),
      url: _text(map['url']),
    );
  }

  final JarInstallPhase phase;
  final int received;
  final int total;

  /// 0–100；-1 = 不确定。
  final int percent;
  final String url;

  bool get determinate => percent >= 0;

  /// 0..1，给 LinearProgressIndicator 用。
  double? get fraction => determinate ? (percent / 100).clamp(0, 1) : null;

  String get label => switch (phase) {
        JarInstallPhase.start => '准备下载 jar…',
        JarInstallPhase.download => determinate
            ? '正在下载 jar $percent%'
            : '正在下载 jar（${_mb(received)}）',
        JarInstallPhase.verify => '校验 md5 / jar 结构…',
        JarInstallPhase.install => '正在安装…',
        JarInstallPhase.done => 'jar 安装完成',
        JarInstallPhase.error => 'jar 安装失败',
      };

  static String _mb(int bytes) {
    if (bytes <= 0) return '0 MB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// jar 自检结果（原生 `selfTest`）。
///
/// 成功只看 [ok]；失败时 [stage] + [code] + [error] 足够定位到
/// 「类找不到 / 方法签名不匹配 / 缺依赖 / 源站挂了」这四类问题。
class JarSelfTest {
  const JarSelfTest({
    required this.ok,
    required this.api,
    required this.stage,
    this.code = '',
    this.error = '',
    this.className = '',
    this.classes = 0,
    this.items = 0,
    this.sample = '',
    this.elapsedMs = 0,
    this.md5 = '',
    this.size = 0,
    this.source = '',
    this.jarPath = '',
    this.jarPerms = '',
    this.jarWritable = false,
  });

  factory JarSelfTest.fromMap(Object? raw) {
    final map = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    return JarSelfTest(
      ok: map['ok'] == true,
      api: _text(map['api']),
      stage: _text(map['stage']),
      code: _text(map['code']),
      error: _text(map['error']),
      className: _text(map['className']),
      classes: _intOf(map['classes']),
      items: _intOf(map['items']),
      sample: _text(map['sample']),
      elapsedMs: _intOf(map['elapsedMs']),
      md5: _text(map['md5']),
      size: _intOf(map['size']),
      source: _text(map['source']),
      jarPath: _text(map['jarPath']),
      jarPerms: _text(map['jarPerms']),
      jarWritable: map['jarWritable'] == true,
    );
  }

  final bool ok;
  final String api;

  /// done / jar / classloader / resolve / instantiate / init / call / parse / loader。
  final String stage;
  final String code;
  final String error;
  final String className;
  final int classes;
  final int items;
  final String sample;
  final int elapsedMs;
  final String md5;
  final int size;
  final String source;
  final String jarPath;

  /// jar 的 9 位权限（`444` / `644` / `unknown`）。
  ///
  /// DEX_READONLY（2026-11-15）：Android 14 起 DexClassLoader 只接受只读文件，
  /// `444` 才算合格；自检失败时把这两个字段显示出来，用户截图就能定位。
  final String jarPerms;

  /// jar 是否仍然可写（可写 = Android 14 必拒）。
  final bool jarWritable;

  /// 一句话结论（设置页 / 提示条直接用）。
  String get summary {
    if (ok) {
      final extra = sample.isEmpty ? '' : '，首条「$sample」';
      return '$api 自检通过：$classes 个分类 / $items 条数据$extra'
          '（${elapsedMs}ms）';
    }
    final stageText = switch (stage) {
      'jar' => '没装 jar',
      'classloader' => '加载 jar 失败',
      'resolve' => '找不到类',
      'instantiate' => '实例化失败',
      'init' => 'init 失败',
      'call' => '调用失败',
      'parse' => '返回不是 JSON',
      'loader' => '加载器异常',
      _ => '自检失败',
    };
    final detail = error.isEmpty ? code : error;
    // Android 14 的「Writable dex file」：原生 chmod 444 没成功。
    // 用户唯一能做的就是重装（安装流程会重新 chmod），所以文案要指路。
    if (code == 'jar_not_readonly') {
      return '$api 自检失败（jar 权限不对）：$detail\n'
          'Android 14 只加载只读 jar（要 444），重装一次 jar 源插件即可自动改正';
    }
    final permsText = jarPerms.isEmpty ? '' : '，权限 $jarPerms';
    return '$api 自检失败（$stageText${code.isEmpty ? '' : '/$code'}）'
        '$permsText：$detail';
  }
}

/// jar 首页里的一个分类（`type_id` + `type_name`）。
class JarClass {
  const JarClass(this.tid, this.name);

  final String tid;
  final String name;
}

/// 一次 `searchContent` 尝试的结果（quick 的取值 + 条数 + 耗时 + 失败原因）。
///
/// JAR_SEARCH_FALLBACK（2026-11-15）：`quick` 到底该传什么，各源实现不一样 ——
/// 线上这份 jar 里几乎没有一个源真的读它（反编译核对：`Gulu` /
/// `SaoHuo` / `Jpys` / `Gz360` / `AppGet` / `AppQi` / `AppRJ` / `AppYQK` /
/// `YGP` 的 `searchContent(str, z)` 里都没有对 `z` 的分支，`Hxq` / `Gulu`
/// 只是把 `z` 原样转给三参版本），而 `Bili` 干脆无视关键词。所以两种模式
/// **都要试**，失败/空就换另一种，谁先出结果用谁 —— 不能像上一版那样
/// 押死 `quick=false`，也不能像更早那样押死 `true`（`true` 时缓存型实现
/// 会直接回整段首页）。
class JarSearchAttempt {
  const JarSearchAttempt({
    required this.quick,
    required this.count,
    required this.elapsed,
    this.error = '',
    this.timedOut = false,
  });

  /// 这次传的 quick。
  final bool quick;

  /// 转换后能用的卡片条数。
  final int count;

  final Duration elapsed;

  /// 失败原因（成功时为空串）。
  final String error;

  /// 是不是超时（超时和报错在日志里要分开看）。
  final bool timedOut;

  bool get ok => error.isEmpty;

  String get mode => quick ? 'quick=true' : 'quick=false';

  /// `quick=false → 3 条 耗时 897ms` / `quick=true → 0 条 (empty) 耗时 1204ms`
  String describe() {
    final ms = elapsed.inMilliseconds;
    if (timedOut) return '$mode → 超时 耗时 ${ms}ms';
    if (!ok) return '$mode → 出错($error) 耗时 ${ms}ms';
    if (count == 0) return '$mode → 0 条 (empty) 耗时 ${ms}ms';
    return '$mode → $count 条 耗时 ${ms}ms';
  }
}

/// 一个源一轮搜索的完整报告（日志 + 页面状态都用它）。
class JarSearchReport {
  const JarSearchReport({required this.cards, required this.attempts});

  final List<VideoCard> cards;
  final List<JarSearchAttempt> attempts;

  /// 是不是靠回退（第二次 quick）才拿到的结果。
  bool get usedFallback =>
      attempts.length > 1 && attempts.first.count == 0 && attempts.last.count > 0;

  /// 最后一次尝试（日志 / 状态文案用）。
  JarSearchAttempt? get last => attempts.isEmpty ? null : attempts.last;

  /// 全部尝试都超时（页面显示「超时」而不是「空」）。
  bool get allTimedOut =>
      attempts.isNotEmpty && attempts.every((a) => a.timedOut);

  /// 全部尝试都报错（含 no_class / call_failed）。
  bool get allFailed =>
      attempts.isNotEmpty && attempts.every((a) => !a.ok && !a.timedOut);

  String get note {
    for (final attempt in attempts.reversed) {
      if (!attempt.ok) return attempt.error;
    }
    return '';
  }
}

/// 一次 detail 调用的产物：给 UI 的模型 + 给播放用的原始线路（带集地址）。
class _JarDetail {
  _JarDetail(this.video, this.lines);

  final VideoDetail video;
  final List<CmsLine> lines;
}

/// jar 源的服务入口（全静态，无状态依赖，方便任何页面直接调）。
class JarSpider {
  JarSpider._();

  /// 与 MainActivity 里注册的通道名必须一致。
  static const MethodChannel channel = MethodChannel('fantasy_tv/spider');

  /// 自检默认测的类：`csp_Douban`（肥猫 jar 里必然有、且不需要 ext）。
  static const String defaultSelfTestApi = 'csp_Douban';

  /// 自检超时：原生 25 秒，这里给 30 秒余量。
  static const Duration selfTestTimeout = Duration(seconds: 30);

  /// 单次取数据超时：**12 秒**（JAR_TIMEOUT 2026-11-15）。
  ///
  /// 原来这里和原生都是 8 秒。实测不够：`Gulu.searchContent` 自带
  /// 「最多 3 次重试 + 500ms×2ⁿ 退避」（反编译：`Thread.sleep(Math.pow(2,i)*500)`，
  /// 光睡眠就有 500+1000+2000=3.5 秒），再叠上 `GuluCrypto` 的握手和加密请求，
  /// 8 秒经常是「刚好在最后一次重试前被杀掉」—— 用户看到的就是咕噜一条都没有。
  /// 单源给到 12 秒；原生 `DEFAULT_TIMEOUT_MS` 同步改 12 秒，两边别再错位。
  static const Duration timeout = Duration(seconds: 12);

  /// Dart 侧同时问 jar 的最大源数（JAR_CONCURRENCY 2026-11-15）。
  ///
  /// 原生 `JarSpiderLoader.WORKER_THREADS` 是同一个数：原生线程池只有这么多
  /// 线程，Dart 一次发 41 个请求并不会更快 —— 排在队列里的那些会**连着排队
  /// 时间一起**算进 `guard()` 的超时，于是「还没开始跑就先超时了」。
  /// 两边对齐之后：最多 6 个源同时在跑，其余排队，队列长度由
  /// `cms_bridge` 的并发闸门控制。
  /// 同时搜多少个源（ALL_PARALLEL 2026-11-18）。
  ///
  /// 用户要求：**每个源实时并行同时搜，不是一个等一个**。
  /// 配置里 71 个源，这里给 72 —— 一轮全部同时发出去，谁先回谁先上屏。
  /// 原生侧 `WORKER_THREADS` 必须同步（否则在原生队列里排队）。
  ///
  ///
  /// 用户口径：**要影视壳那样「一下加载许多」，不是一条一条来**。
  /// 实测 41 个源、单源 12 秒预算，并发 6 的话排在后面的 30+ 个源根
  /// 本轮不到（搜「济公传」时只跑了 16/41 个）。壳是多源并行。
  /// 这里提到 20 —— 原生线程池必须同步提到 20（JarSpiderLoader）。
  ///
  /// INIT_TIMEOUT（2026-11-16）：线上这份 `hx_all.json` 其实是 **116 个 type3
  /// 源**。116 源 / 20 并发 / 12 秒单源预算，实测 12 秒内跑完 82 个、
  /// 20 秒跑完 111 个 —— 所以 20 这个数够用，真正卡住并发的不是它，
  /// 而是原生侧「实例化 + init」曾整段在全局锁里（`csp_SaoHuo.init()` 33 秒，
  /// 一个慢源堵死全部）。那个问题在 JarSpiderLoader 里单独修了。
  static const int maxConcurrentSearches = 72;

  /// 一轮搜索里单个源的**总**预算（quick=false + quick=true 两次尝试之和）。
  ///
  /// 略小于 [timeout]：留给通道往返和 JSON 解析，保证源级超时先于整体超时生效，
  /// 页面能明确显示「这个源超时了」，而不是含糊的「整轮没查完」。
  static const Duration searchBudget = Duration(seconds: 11);

  /// 安装 jar 的超时：下载 + 校验，给足 4 分钟。
  static const Duration installTimeout = Duration(minutes: 4);

  /// TVBox 默认的 VIP 解析标记：交给 jar 自己决定怎么用。
  ///
  /// PROTOCOL_FACE（2026-11-15 · 阶段 1）：壳交给 `playerContent(flag, id, flags)`
  /// 的第三个参数是**配置里的 `flags` 数组**（`VodConfig.get().getFlags()`，
  /// 真配置里有 33 条：`youku` / `优酷` / `优 酷` / `腾讯视频` …）。我们原来
  /// 传的是一份写死的名单，配置里写 `flags` 的 jar 源拿不到它自己那套线路名，
  /// 于是「同一个 jar 在壳里能出地址、在我们这儿空」。
  ///
  /// 现在这份列表可以被配置替换（[setVipFlags]）；配置里没有 `flags` 时
  /// 保持这份默认值，行为与改造前一致。
  static const List<String> defaultVipFlags = <String>[
    'youku',
    'qq',
    'iqiyi',
    'qiyi',
    'letv',
    'sohu',
    'tudou',
    'pptv',
    'mgtv',
    'wasu',
    'bilibili',
  ];

  static List<String> _vipFlags = defaultVipFlags;

  /// 当前生效的线路名表（默认值，或配置里的 `flags`）。
  static List<String> get vipFlags => _vipFlags;

  /// 用配置里的 `flags` 替换（空数组表示「没配」，保持默认）。
  static void setVipFlags(List<String> flags) {
    final cleaned = <String>[
      for (final item in flags)
        if (item.trim().isNotEmpty) item.trim(),
    ];
    _vipFlags = cleaned.isEmpty ? defaultVipFlags : List<String>.unmodifiable(cleaned);
  }

  static const int _detailCacheLimit = 60;
  static const int _classCacheLimit = 24;

  static JarStatus? _status;

  /// 安装进度广播（原生 `jarInstallProgress` → Dart）。
  static final StreamController<JarInstallProgress> _progress =
      StreamController<JarInstallProgress>.broadcast();

  static bool _progressHooked = false;

  static final Map<String, _JarDetail> _details = <String, _JarDetail>{};

  static final Map<String, List<JarClass>> _classes = <String, List<JarClass>>{};

  /// 通道只在 Android 上存在（桌面 / Web 调试时直接报错，别静默返回空）。
  ///
  /// [debugForceSupported] 只给单元测试用：`flutter test` 跑在 Linux 上，
  /// `Platform.isAndroid` 恒为 false，不给个开关就没法测 quick 回退 / 超时
  /// 这些纯逻辑（JAR_SEARCH_FALLBACK 2026-11-15）。
  static bool debugForceSupported = false;

  static bool get supported =>
      debugForceSupported || (!kIsWeb && Platform.isAndroid);

  /// 最后一次拿到的状态（可能为 null：还没查过）。
  static JarStatus? get cachedStatus => _status;

  /// 安装进度流（广播；多个页面可以同时听）。
  static Stream<JarInstallProgress> get installProgress {
    _hookProgress();
    return _progress.stream;
  }

  /// 挂一次通道回调：原生用 `invokeMethod('jarInstallProgress')` 回传进度。
  static void _hookProgress() {
    if (_progressHooked) return;
    _progressHooked = true;
    try {
      channel.setMethodCallHandler((call) async {
        if (call.method == 'jarInstallProgress') {
          _progress.add(JarInstallProgress.fromMap(call.arguments));
        }
        return null;
      });
    } catch (_) {
      // 桌面 / 测试环境没有通道：进度拿不到，安装照常。
    }
  }

  /* ------------------------------------------------------------ 通道 */

  /// 查 / 装 jar 的状态。`fresh` 为 true 时强制问原生。
  static Future<JarStatus> status({bool fresh = false}) async {
    final hit = _status;
    if (!fresh && hit != null) return hit;
    if (!supported) {
      _status = const JarStatus.missing();
      return _status!;
    }
    try {
      final raw = await channel.invokeMethod<Object?>('status').timeout(timeout);
      final map = _mapOf(raw);
      _status = JarStatus(
        installed: map['installed'] == true,
        path: _text(map['path']),
        md5: _text(map['md5']),
        size: _intOf(map['size']),
        bundled: map['bundled'] == true,
        source: _text(map['source']),
      );
    } catch (_) {
      _status = const JarStatus.missing();
    }
    return _status!;
  }

  /// 从地址安装 jar（下载 → 校验 md5 → 落盘 → 换加载器）。
  ///
  /// [md5] 可选：填了就强校验，不匹配直接失败（防止下到错误页面）。
  static Future<JarStatus> install(String url, {String md5 = ''}) async {
    final address = url.trim();
    if (address.isEmpty) throw ApiException('先填 jar 下载地址');
    _hookProgress();
    final map = await _invoke(
      'jarInstall',
      <String, Object?>{'url': address, 'md5': md5.trim()},
      wait: installTimeout,
    );
    final status = JarStatus(
      installed: map['ok'] == true,
      path: _text(map['path']),
      md5: _text(map['md5']),
      size: _intOf(map['size']),
    );
    _resetCaches();
    _status = status;
    return status;
  }

  /// 用安装包内置的 `assets/spiders/spider.jar` 安装（不联网）。
  ///
  /// 服务器没放 jar / 首次启动没网时的兜底：CI 把
  /// `assets/spiders/spider.jar` 打进 APK，这里让原生解到 filesDir 并生效。
  static Future<JarStatus> installBundled() async {
    _hookProgress();
    final map = await _invoke(
      'installBundled',
      const <String, Object?>{},
      wait: installTimeout,
    );
    final status = JarStatus(
      installed: map['ok'] == true,
      path: _text(map['path']),
      md5: _text(map['md5']),
      size: _intOf(map['size']),
      bundled: true,
      source: 'bundled',
    );
    _resetCaches();
    _status = status;
    return status;
  }

  /// 自检：装完 jar 后真的调一次 `homeContent`，能返回 JSON 才算成功。
  ///
  /// 失败时返回 [JarSelfTest]，`stage` / `code` / `error` 说明卡在哪
  /// （类找不到 / 方法签名不匹配 / 缺依赖 / 源站异常），不抛异常，
  /// 页面直接把 [JarSelfTest.summary] 显示出来。
  static Future<JarSelfTest> selfTest({
    String api = defaultSelfTestApi,
    String ext = '',
  }) async {
    final target = api.trim().isEmpty ? defaultSelfTestApi : api.trim();
    if (!supported) {
      return JarSelfTest(
        ok: false,
        api: target,
        stage: 'jar',
        code: 'unsupported',
        error: 'jar 源只在 Android 客户端上可用',
      );
    }
    Map<String, dynamic> map;
    try {
      map = await _invoke(
        'selfTest',
        <String, Object?>{'api': target, 'ext': ext},
        wait: selfTestTimeout,
      );
    } catch (e) {
      return JarSelfTest(
        ok: false,
        api: target,
        stage: 'loader',
        code: 'exception',
        error: '$e',
      );
    }
    if (_text(map['error']).isNotEmpty && map['ok'] != false) {
      // 原生把通道级错误放在 error 字段（_invoke 已抛），这里兜底。
      map = <String, dynamic>{...map, 'ok': false, 'code': map['code']};
    }
    return JarSelfTest.fromMap(map);
  }

  /// 从本地文件安装（真机 adb push 上来之后用）。
  static Future<JarStatus> installFromPath(String path) async {
    final target = path.trim();
    if (target.isEmpty) throw ApiException('先填 jar 文件路径');
    final map = await _invoke(
      'installFromPath',
      <String, Object?>{'path': target},
      wait: installTimeout,
    );
    final status = JarStatus(
      installed: map['ok'] == true,
      path: _text(map['path']),
      md5: _text(map['md5']),
      size: _intOf(map['size']),
    );
    _resetCaches();
    _status = status;
    return status;
  }

  /// 卸载：删掉已装的 jar 与原生加载器（type 3 源会暂时没有内容）。
  static Future<void> uninstall() async {
    _resetCaches();
    _status = const JarStatus.missing();
    if (!supported) return;
    try {
      await channel.invokeMethod<Object?>('uninstall').timeout(timeout);
    } catch (_) {
      // 删除失败（已删 / 权限）没有可做的补救。
    }
  }

  /// 释放原生加载器（换 jar / 退出时）。
  static Future<void> destroy() async {
    _resetCaches();
    _status = null;
    if (!supported) return;
    try {
      await channel.invokeMethod<Object?>('destroy').timeout(timeout);
    } catch (_) {
      // 释放失败没有可做的补救，忽略。
    }
  }

  /* ------------------------------------------------------------ 取数据 */

  /// 首页分类（category 需要 type_id，`type_id` 和我们的频道键不是一套）。
  static Future<List<JarClass>> homeClasses({
    required String api,
    required String ext,
  }) async {
    final key = _key(api, ext);
    final hit = _classes[key];
    if (hit != null) return hit;
    final body = await _spider('home', <String, Object?>{
      'api': api,
      'ext': ext,
      'filter': false,
    });
    final list = classesOf(body);
    if (_classes.length >= _classCacheLimit && !_classes.containsKey(key)) {
      _classes.remove(_classes.keys.first);
    }
    _classes[key] = list;
    return list;
  }

  /// 我们的频道键（movie / tv / ...）→ 这个 jar 源自己的 `type_id`。
  static Future<String> typeIdOfChannel(
    String api,
    String ext,
    String channelKey,
  ) async {
    final wanted = channelKey.trim();
    if (wanted.isEmpty) return '';
    final list = await homeClasses(api: api, ext: ext);
    for (final item in list) {
      if (channelKeyOfClassName(item.name) == wanted) return item.tid;
    }
    return '';
  }

  /// 搜索（单次，不来回退 —— 内部用；调用方一般用 [searchWithFallback]）。
  ///
  /// SEARCH_QUICK（2026-11-15）：[quick] 默认 **false**。
  ///
  /// FongMi / TVBox 里 `searchContent(key, quick)` 的 `quick` 是「快速搜索」：
  /// 为 true 时允许 spider 直接用**本地 / 首页那批缓存**回答，不真去站点搜。
  /// 我们原来写死 true，等于给每个 jar 源开了「走缓存」的许可 —— 某些源实现
  /// 得很粗糙（把缓存整段返回、不做关键词过滤），搜索词就被无视了，列表里
  /// 出现与该词毫无关系的片（现场：搜「济公传」出来「背着善宰跑」「与恶魔
  /// 有约」这类首页热门）。
  ///
  /// 但**线上这份 jar 里几乎没有源读 quick**（反编译核对见 [JarSearchAttempt]
  /// 注释），所以单靠改它既治不了脏结果、也可能让只实现了快速搜索的源回空。
  /// 现在统一走 [searchWithFallback]：两种模式都试 + 客户端相关性闸门兜底。
  static Future<List<VideoCard>> search({
    required String api,
    required String ext,
    required String key,
    int page = 1,
    bool quick = false,
    String label = '',
    Duration? wait,
  }) async {
    final q = key.trim();
    if (q.isEmpty) return const <VideoCard>[];
    final body = await _spider(
      'search',
      <String, Object?>{
        'api': api,
        'ext': ext,
        'key': q,
        'quick': quick,
        'page': page < 1 ? 1 : page,
      },
      wait: wait,
    );
    return cardsOf(body);
  }

  /// 搜索（**两种 quick 都试**，JAR_SEARCH_FALLBACK 2026-11-15）。
  ///
  /// 顺序：先 `quick=false`（真搜索，脏结果最少）；**返回空 / 抛异常 / 超时**
  /// 就回退 `quick=true`（有些源只实现了快速模式，或者慢搜索会被站点掐）。
  /// 谁先给出非空结果就用谁；两种都空就把空结果交出去，由上层闸门 / 页面
  /// 显示「暂无相关结果」。
  ///
  /// 每次尝试都会写一行日志（[fxJarLog]），格式固定，真机排查一条 grep 够：
  ///
  /// ```
  /// [JarSearch] source=咕噜 key=济公传 quick=false → 3 条 耗时 897ms
  /// [JarSearch] source=咕噜 key=济公传 quick=true → 0 条 (empty) 耗时 1204ms
  /// ```
  ///
  /// [budget] 是这个源的总预算（两次尝试共享），默认 [searchBudget]。
  static Future<JarSearchReport> searchWithFallback({
    required String api,
    required String ext,
    required String key,
    int page = 1,
    String label = '',
    Duration? budget,
  }) async {
    final q = key.trim();
    final who = label.trim().isEmpty ? api.trim() : label.trim();
    if (q.isEmpty) {
      return const JarSearchReport(cards: <VideoCard>[], attempts: <JarSearchAttempt>[]);
    }
    final total = budget ?? searchBudget;
    final deadline = DateTime.now().add(total);
    final attempts = <JarSearchAttempt>[];

    for (final quick in const <bool>[false, true]) {
      final left = deadline.difference(DateTime.now());
      if (left <= const Duration(milliseconds: 300)) {
        // 预算用完：记一条，别让第二个模式把整轮搜索拖过 12 秒。
        fxJarLog('source=$who key=$q ${quick ? 'quick=true' : 'quick=false'} → 跳过(预算已用完)');
        break;
      }
      // quick=false 拿大头（真搜索本来就是慢的），quick=true 用剩余预算。
      final slice = quick
          ? left
          : (left > const Duration(seconds: 7) ? const Duration(seconds: 7) : left);
      final started = DateTime.now();
      try {
        final cards = await search(
          api: api,
          ext: ext,
          key: q,
          page: page,
          quick: quick,
          label: who,
          wait: slice,
        );
        final attempt = JarSearchAttempt(
          quick: quick,
          count: cards.length,
          elapsed: DateTime.now().difference(started),
        );
        attempts.add(attempt);
        fxJarLog('source=$who key=$q ${attempt.describe()}');
        if (cards.isNotEmpty) return JarSearchReport(cards: cards, attempts: attempts);
      } on ApiException catch (e) {
        final attempt = JarSearchAttempt(
          quick: quick,
          count: 0,
          elapsed: DateTime.now().difference(started),
          error: e.message,
          timedOut: e.kind == ApiErrorKind.timeout,
        );
        attempts.add(attempt);
        fxJarLog('source=$who key=$q ${attempt.describe()}');
      } catch (e) {
        final attempt = JarSearchAttempt(
          quick: quick,
          count: 0,
          elapsed: DateTime.now().difference(started),
          error: '$e',
        );
        attempts.add(attempt);
        fxJarLog('source=$who key=$q ${attempt.describe()}');
      }
    }
    fxJarLog('source=$who key=$q 两种模式都没结果（已试 ${attempts.length} 次）');
    return JarSearchReport(cards: const <VideoCard>[], attempts: attempts);
  }


  /// 分类列表。
  static Future<List<VideoCard>> category({
    required String api,
    required String ext,
    required String tid,
    int page = 1,
    bool filter = false,
    Map<String, String> extend = const <String, String>{},
  }) async {
    final id = tid.trim();
    if (id.isEmpty) return const <VideoCard>[];
    final body = await _spider('category', <String, Object?>{
      'api': api,
      'ext': ext,
      'tid': id,
      'page': page < 1 ? 1 : page,
      'filter': filter,
      'extend': extend,
    });
    return cardsOf(body);
  }

  /// 详情（走缓存，播放时不用再请求一次）。
  static Future<VideoDetail> detail({
    required String api,
    required String ext,
    required String vodId,
  }) async {
    final entry = await _detailEntry(api: api, ext: ext, vodId: vodId);
    return entry.video;
  }

  /// 播放地址：拿详情里的集地址交给 `playerContent`。
  ///
  /// [lineName] 是详情页传回来的线路名（也接受线路 id），
  /// [ep] 从 1 开始。
  static Future<PlayInfo> play({
    required String api,
    required String ext,
    required String vodId,
    required String lineName,
    required int ep,
  }) async {
    final entry = await _detailEntry(api: api, ext: ext, vodId: vodId);
    if (entry.lines.isEmpty) throw ApiException('该影片暂无播放地址');
    final line = findLine(entry.lines, lineName) ?? entry.lines.first;
    final index = ep < 1 ? 1 : ep;
    final address = line.urlAt(index);
    if (address == null || address.trim().isEmpty) {
      throw ApiException('该线路没有可用播放地址');
    }
    // flag 必须是 vod_play_from 里的那一段（不是显示名）：jar 用它区分线路。
    final flag = (line.info.from ?? '').trim().isEmpty
        ? line.info.displayName
        : line.info.from!.trim();
    final body = await _spider(
      'player',
      <String, Object?>{
        'api': api,
        'ext': ext,
        'flag': flag,
        'id': address,
        'vipFlags': vipFlags,
      },
      logTag: fxJarPlayTag,
    );
    try {
      final info = playOf(body, lineName: line.info.displayName);
      fxJarLog(
        'play api=$api vodId=$vodId line=${line.info.displayName} ep=$ep '
        'flag=$flag parse=${_intOf(body['parse'])} url=${fxJarClip(info.url, max: 120)}',
        tag: fxJarPlayTag,
      );
      return info;
    } on ApiException catch (e) {
      // 「加载不了」的具体原因只有这里看得见：是没给 url、还是这条线路要
      // WebView 嗅探（parse=1 且不是直链）。原始返回已经在上面那行打过了。
      fxJarLog(
        'play api=$api vodId=$vodId line=${line.info.displayName} ep=$ep '
        '→ 失败：${e.message}',
        tag: fxJarPlayTag,
      );
      rethrow;
    }
  }

  /* ------------------------------------------------------------ 转换（纯函数，可单测） */

  /// `{"list":[…]}` → 卡片列表（TVBox 的 `vod_*` 字段与 CMS 同构）。
  static List<VideoCard> cardsOf(Object? body) {
    final out = <VideoCard>[];
    for (final vod in _vodsOf(body)) {
      // UNUSABLE_RECORD（2026-11-15）：**带了播放字段却一条能播的线路都没有**
      // 的记录直接丢掉（空壳）。注意 TVBox 的搜索响应本来就不带
      // `vod_play_from` / `vod_play_url`，那种卡片必须保留 —— 只判「有字段
      // 但全空」这一种，不能把整个搜索结果误杀。
      if (!_playableOrUnspecified(vod)) continue;
      try {
        final card = CmsApi.cardOf(vod);
        if (card.id.trim().isEmpty) continue;
        out.add(card);
      } catch (_) {
        // 单条坏数据不影响整页
      }
    }
    return out;
  }

  /// 这条记录能不能留：没给播放字段（搜索接口常态）= 能留；
  /// 给了但全是空段 / 占位 = 空壳，丢掉。
  static bool _playableOrUnspecified(Map<String, dynamic> vod) {
    final hasField = vod.containsKey('vod_play_url') ||
        vod.containsKey('vod_play_from');
    if (!hasField) return true;
    return CmsApi.usableLineCount(vod) > 0;
  }

  /// `{"list":[{…vod…}]}` → 详情（线路 / 选集全走 cms_source 的既有规则）。
  static VideoDetail detailOf(
    Object? body, {
    String fallbackId = '',
    String root = '',
  }) {
    final vod = _firstVod(body);
    if (vod == null) throw ApiException('这个源没有返回影片信息');
    final normalized = _normalizeVod(vod, fallbackId: fallbackId, root: root);
    final lines = parseLines(normalized);
    if (lines.isEmpty) {
      throw ApiException('这个源没给播放地址（可能是需要网页解析的线路）');
    }
    return CmsApi.detailOf(normalized, lines);
  }

  /// `{"parse":0,"url":"…","header":{…}}` → [PlayInfo]。
  static PlayInfo playOf(Object? body, {String lineName = ''}) {
    final map = body is Map ? Map<String, dynamic>.from(body) : <String, dynamic>{};
    final url = _text(map['url']);
    final parse = _intOf(map['parse']);
    if (url.isEmpty) {
      throw ApiException(_text(map['msg']).isEmpty ? '这个源没有给出播放地址' : _text(map['msg']));
    }
    // parse != 0：TVBox 会交给 WebView 去嗅探，这里没有嗅探器；
    // 但有些源会把直链也标成 1，所以先看地址本身能不能直接播。
    if (parse != 0 && !isMediaUrl(url)) {
      throw ApiException('这条线路需要网页解析，换一条线路试试');
    }
    final headers = <String, String>{};
    final rawHeader = map['header'];
    if (rawHeader is Map) {
      for (final entry in rawHeader.entries) {
        final key = '${entry.key}'.trim();
        if (key.isEmpty) continue;
        headers[key] = '${entry.value}'.trim();
      }
    }
    if (!headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
      headers['User-Agent'] = kDefaultVideoUserAgent;
    }
    return PlayInfo(
      url: url,
      type: url.toLowerCase().contains('.m3u8') ? 'hls' : 'mp4',
      lineName: lineName,
      parsePage: '',
      quality: const <QualityItem>[],
      backup: const <String>[],
      headers: headers,
      direct: parse == 0,
    );
  }

  /// `{"class":[{"type_id":1,"type_name":"电影"}]}` → 分类列表。
  static List<JarClass> classesOf(Object? body) {
    final map = _mapOrNull(body);
    if (map == null) return const <JarClass>[];
    final out = <JarClass>[];
    for (final entry in _listOf(map['class'])) {
      if (entry is! Map) continue;
      final m = Map<String, dynamic>.from(entry);
      final tid = _text(m['type_id']);
      final name = _text(m['type_name']);
      if (tid.isEmpty || name.isEmpty) continue;
      out.add(JarClass(tid, name));
    }
    return out;
  }

  /* ------------------------------------------------------------ 内部 */

  static String _key(String api, String ext) => '${api.trim()}|$ext';

  static void _resetCaches() {
    _details.clear();
    _classes.clear();
  }

  /// 详情 + 原始线路（播放要用集地址）。
  static Future<_JarDetail> _detailEntry({
    required String api,
    required String ext,
    required String vodId,
  }) async {
    final id = vodId.trim();
    if (id.isEmpty) throw ApiException('没有影片 id');
    final key = '${_key(api, ext)}|$id';
    final hit = _details[key];
    if (hit != null) return hit;
    final body = await _spider(
      'detail',
      <String, Object?>{
        'api': api,
        'ext': ext,
        'ids': <String>[id],
      },
      logTag: fxJarDetailTag,
    );
    final vod = _firstVod(body);
    if (vod == null) {
      fxJarLog('detail api=$api vodId=$id → 没有解析到 vod 记录', tag: fxJarDetailTag);
      throw ApiException('这个源没有返回影片信息');
    }
    final normalized = _normalizeVod(vod, fallbackId: id, root: api);
    final lines = parseLines(normalized);
    fxJarLog(
      'detail api=$api vodId=$id play_from="${_text(normalized['vod_play_from'])}" '
      'play_url_len=${_text(normalized['vod_play_url']).length} lines=${lines.length}',
      tag: fxJarDetailTag,
    );
    if (lines.isEmpty) {
      fxJarLog(
        'detail api=$api vodId=$id → 线路解析为空（这个源可能只给网页解析线路）',
        tag: fxJarDetailTag,
      );
      throw ApiException('这个源没给播放地址（可能是需要网页解析的线路）');
    }
    final entry = _JarDetail(CmsApi.detailOf(normalized, lines), lines);
    if (_details.length >= _detailCacheLimit && !_details.containsKey(key)) {
      _details.remove(_details.keys.first);
    }
    _details[key] = entry;
    return entry;
  }

  /// 调一个取数方法，返回解析后的 JSON（带 error 字段时抛 [ApiException]）。
  ///
  /// [wait] 本次调用的超时（默认 [timeout]）。[logTag] 非空时把**原始返回**
  /// 截断后写一行日志 —— 详情 / 播放打不开时，光看「加载失败」定位不了是
  /// `detailContent` 没给线路还是 `playerContent` 没给地址（JAR_LOG 2026-11-15）。
  static Future<Map<String, dynamic>> _spider(
    String method,
    Map<String, Object?> args, {
    Duration? wait,
    String logTag = '',
  }) async {
    // _invoke 已经把原生返回的 {"error": …} 转成 ApiException。
    final body = await _invoke(method, args, wait: wait);
    if (logTag.isNotEmpty) {
      fxJarLog(
        '$method api=${args['api']} '
        'ids=${args['ids'] ?? args['id'] ?? ''} '
        'raw=${fxJarClip(_jsonText(body))}',
        tag: logTag,
      );
    }
    return body;
  }

  static String _jsonText(Object? body) {
    try {
      return jsonEncode(body);
    } catch (_) {
      return '$body';
    }
  }

  /// 真正调通道：把「返回值是 String / Map」「平台异常」「超时」统一成 Map 或 [ApiException]。
  static Future<Map<String, dynamic>> _invoke(
    String method,
    Map<String, Object?> args, {
    Duration? wait,
  }) async {
    if (!supported) {
      throw ApiException('jar 源只在 Android 客户端上可用');
    }
    Object? raw;
    try {
      raw = await channel
          .invokeMethod<Object?>(method, args)
          .timeout(wait ?? timeout);
    } on MissingPluginException {
      throw ApiException('这个安装包没有内置 jar 源支持，请更新到最新版本');
    } on PlatformException catch (e) {
      throw ApiException(e.message ?? 'jar 源调用失败（${e.code}）');
    } on TimeoutException {
      throw ApiException('jar 源响应超时', kind: ApiErrorKind.timeout);
    }
    final map = _mapOf(raw);
    final error = _text(map['error']);
    if (error.isNotEmpty) {
      throw ApiException(
        error,
        kind: _text(map['code']) == 'timeout'
            ? ApiErrorKind.timeout
            : ApiErrorKind.business,
      );
    }
    return map;
  }

  /// 原生可能回 String（JSON 字符串）、Map，或 null。
  static Map<String, dynamic> _mapOf(Object? raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String) {
      final parsed = _decode(raw);
      if (parsed is Map) return Map<String, dynamic>.from(parsed);
      if (parsed == null && raw.trim().isNotEmpty) {
        throw ApiException('jar 源返回的不是 JSON');
      }
    }
    return <String, dynamic>{};
  }

  static Map<String, dynamic>? _mapOrNull(Object? body) {
    if (body is Map) return Map<String, dynamic>.from(body);
    return null;
  }

  static Object? _decode(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  /// 各种外壳里掏 `list`：`{"list":[…]}` / `{"data":{"list":[…]}}` / 裸数组。
  static List<Object?> _listOf(Object? raw) {
    Object? value = raw;
    if (value is Map) {
      final map = Map<String, dynamic>.from(value);
      value = map['list'] ?? map['videos'] ?? map['data'] ?? map['result'];
      if (value is Map) {
        final inner = Map<String, dynamic>.from(value);
        value = inner['list'] ?? inner['videos'] ?? inner['data'];
      }
    }
    if (value is List) return value;
    return const <Object?>[];
  }

  static List<Map<String, dynamic>> _vodsOf(Object? body) {
    final out = <Map<String, dynamic>>[];
    for (final e in _listOf(body)) {
      if (e is! Map) continue;
      out.add(Map<String, dynamic>.from(e));
    }
    return out;
  }

  static Map<String, dynamic>? _firstVod(Object? body) {
    final list = _vodsOf(body);
    if (list.isEmpty) return null;
    return list.first;
  }

  /// 规整一条 vod：`vod_id` 补成字符串（有的源给数组 / 数字），
  /// `vod_play_from` / `vod_play_url` 一并补成字符串。
  static Map<String, dynamic> _normalizeVod(
    Map<String, dynamic> vod, {
    required String fallbackId,
    String root = '',
  }) {
    final out = Map<String, dynamic>.from(vod);
    var id = _text(out['vod_id']);
    if (id.isEmpty) {
      final rawId = out['vod_id'];
      if (rawId is List && rawId.isNotEmpty) id = _text(rawId.first);
      if (id.isEmpty) id = fallbackId;
    }
    out['vod_id'] = id;
    // COVER_FIX（2026-11-15）：`vod_pic` 一律先归一化 —— 空串 / 源站相对地址
    // 在 UI 上会变成一块**空白封面**（老逻辑把它补成我们已下线的旧后端）。
    // 这里能补就补成绝对地址，补不出来就置空串，让 UI 走「首字占位」。
    if (out.containsKey('vod_pic')) {
      out['vod_pic'] = Api.coverOf(_text(out['vod_pic']), root: root);
    }
    for (final key in <String>['vod_play_from', 'vod_play_url', 'vod_name']) {
      final value = out[key];
      if (value == null) {
        out[key] = '';
      } else if (value is! String) {
        out[key] = '$value';
      }
    }
    return out;
  }
}

String _text(Object? raw) {
  if (raw == null) return '';
  return raw.toString().trim();
}

int _intOf(Object? raw, {int fallback = 0}) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(_text(raw)) ?? fallback;
}

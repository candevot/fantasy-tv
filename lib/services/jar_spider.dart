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
    return '$api 自检失败（$stageText${code.isEmpty ? '' : '/$code'}）：$detail';
  }
}

/// jar 首页里的一个分类（`type_id` + `type_name`）。
class JarClass {
  const JarClass(this.tid, this.name);

  final String tid;
  final String name;
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

  /// 单次取数据超时：**8 秒**（TIMEOUT_UNIFY 2026-11-15）。
  ///
  /// 和原生 `JarSpiderLoader.DEFAULT_TIMEOUT_MS` 取同一个值。原来这里是 30
  /// 秒、原生 25 秒，比用户能忍的等待长得多：jar 没装 / 源站死了的时候，
  /// 详情页会先转 8 秒（页面自己的超时）再转 30 秒（这里），用户看到的就是
  /// 「加载失败，请求超时」之前那段无尽转圈。统一 8 秒，失败立刻有文案。
  static const Duration timeout = Duration(seconds: 8);

  /// 安装 jar 的超时：下载 + 校验，给足 4 分钟。
  static const Duration installTimeout = Duration(minutes: 4);

  /// TVBox 默认的 VIP 解析标记：交给 jar 自己决定怎么用。
  static const List<String> vipFlags = <String>[
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
  static bool get supported => !kIsWeb && Platform.isAndroid;

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

  /// `homeContent` 的原始 JSON：`{"class":[…],"filters":{…},"list":[…]}`。
  ///
  /// FATCAT_HOME（2026-11-15）：首页推荐现在直接铺肥猫 jar 源的首页，
  /// 所以要把**整个** homeContent 交给上层（既要 `class` 做分类映射，
  /// 也要 `list` 做推荐位），不能只留分类。
  static Future<Map<String, dynamic>> home({
    required String api,
    required String ext,
  }) =>
      _spider('home', <String, Object?>{
        'api': api,
        'ext': ext,
        'filter': false,
      });

  /// 首页分类（category 需要 type_id，`type_id` 和我们的频道键不是一套）。
  static Future<List<JarClass>> homeClasses({
    required String api,
    required String ext,
  }) async {
    final key = _key(api, ext);
    final hit = _classes[key];
    if (hit != null) return hit;
    final body = await home(api: api, ext: ext);
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

  /// 搜索。
  static Future<List<VideoCard>> search({
    required String api,
    required String ext,
    required String key,
    int page = 1,
    bool quick = true,
  }) async {
    final q = key.trim();
    if (q.isEmpty) return const <VideoCard>[];
    final body = await _spider('search', <String, Object?>{
      'api': api,
      'ext': ext,
      'key': q,
      'quick': quick,
      'page': page < 1 ? 1 : page,
    });
    return cardsOf(body);
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
    final body = await _spider('player', <String, Object?>{
      'api': api,
      'ext': ext,
      'flag': flag,
      'id': address,
      'vipFlags': vipFlags,
    });
    return playOf(body, lineName: line.info.displayName);
  }

  /* ------------------------------------------------------------ 转换（纯函数，可单测） */

  /// `{"list":[…]}` → 卡片列表（TVBox 的 `vod_*` 字段与 CMS 同构）。
  static List<VideoCard> cardsOf(Object? body) {
    final out = <VideoCard>[];
    for (final vod in _vodsOf(body)) {
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

  /// `{"list":[{…vod…}]}` → 详情（线路 / 选集全走 cms_source 的既有规则）。
  static VideoDetail detailOf(Object? body, {String fallbackId = ''}) {
    final vod = _firstVod(body);
    if (vod == null) throw ApiException('这个源没有返回影片信息');
    final normalized = _normalizeVod(vod, fallbackId: fallbackId);
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
    final body = await _spider('detail', <String, Object?>{
      'api': api,
      'ext': ext,
      'ids': <String>[id],
    });
    final vod = _firstVod(body);
    if (vod == null) throw ApiException('这个源没有返回影片信息');
    final normalized = _normalizeVod(vod, fallbackId: id);
    final lines = parseLines(normalized);
    if (lines.isEmpty) {
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
  static Future<Map<String, dynamic>> _spider(
    String method,
    Map<String, Object?> args,
  ) async {
    // _invoke 已经把原生返回的 {"error": …} 转成 ApiException。
    return _invoke(method, args);
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
  }) {
    final out = Map<String, dynamic>.from(vod);
    var id = _text(out['vod_id']);
    if (id.isEmpty) {
      final rawId = out['vod_id'];
      if (rawId is List && rawId.isNotEmpty) id = _text(rawId.first);
      if (id.isEmpty) id = fallbackId;
    }
    out['vod_id'] = id;
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

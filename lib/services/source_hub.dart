import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../models.dart';
import 'cms_api.dart';
import 'cms_client.dart';
import 'jar_spider.dart';
import 'tvbox_crypto.dart';

/// 片源的种类。
enum KSourceKind {
  /// `type: 1` —— 苹果CMS 接口（`/api.php/provide/vod/`）。
  cms,

  /// `type: 0` —— 直接给 JSON / 列表的地址（TVBox 里常说的「直接地址」）。
  direct,

  /// `type: "live"` —— 直播播放列表（M3U / TXT / JSON）。
  live,

  /// `type: 3` —— TVBox 的 jar 解析插件（`api` 是 jar 里的类名，`ext` 是站点配置）。
  ///
  /// 走 `JAR_SPIDER` 通道：原生 DexClassLoader 加载 `spider.jar`，反射调
  /// `com.github.catvod.crawler.Spider`，返回的 JSON 在 jar_spider.dart 里
  /// 转成 [VideoCard] / [VideoDetail] / [PlayInfo]。
  jar,

  /// `type: 4`（python 解析脚本）—— 暂不支持。
  unsupported,
}

/// 片源从哪来。
enum KSourceOrigin {
  /// 云端配置下发（后台 `/api/config`）。
  cloud,

  /// 用户在设置里自加（含 TVBox 导入）。
  user,
}

/// 一个片源：云端下发的 / 用户自加的，都是这一种结构。
///
/// 与后台约定的字段与 TVBox 的 `sites` 保持一致：
/// `key` / `name` / `type` / `api` / `enabled` / `builtin`。
@immutable
class KSource {
  const KSource({
    required this.key,
    required this.name,
    required this.api,
    required this.kind,
    required this.origin,
    this.builtin = false,
    this.enabled = true,
    this.tag = '',
    this.reason = '',
    this.ext = '',
  });

  final String key;
  final String name;
  final String api;
  final KSourceKind kind;
  final KSourceOrigin origin;

  /// 云端下发的内置源（可删、可一键恢复）。
  final bool builtin;

  /// 云端配的开关；用户自加的源恒为 true。
  final bool enabled;

  /// 来源备注（目前只有 TVBox 导入会填）。
  final String tag;

  /// TVBox 的 `ext`：jar 源里常用来区分同一个类下的不同站点
  /// （例如肥猫 / 饭太硬 / 二小都用 `csp_Xxx`，靠 ext 指向各自的地址）。
  final String ext;

  /// 不可用原因（目前只有 type 4 会填）。
  final String reason;

  bool get usable =>
      kind != KSourceKind.unsupported && api.trim().isNotEmpty && enabled;

  bool get isLive => kind == KSourceKind.live;

  /// 能否参与搜索 / 分类（直播源不参与内容检索）。
  ///
  /// jar 源也算：它的内容检索走 `JAR_SPIDER` 通道，和 CMS 一样能搜能分类。
  bool get searchable =>
      usable &&
      (kind == KSourceKind.cms ||
          kind == KSourceKind.direct ||
          kind == KSourceKind.jar);

  String get kindLabel {
    switch (kind) {
      case KSourceKind.cms:
        return 'CMS 接口';
      case KSourceKind.direct:
        return '直接地址';
      case KSourceKind.live:
        return '直播列表';
      case KSourceKind.jar:
        return 'jar 插件';
      case KSourceKind.unsupported:
        return '暂不支持';
    }
  }

  String get originLabel =>
      origin == KSourceOrigin.cloud ? '云端' : '自加';

  KSource copyWith({
    String? name,
    String? api,
    KSourceKind? kind,
    bool? enabled,
    String? ext,
  }) =>
      KSource(
        key: key,
        name: name ?? this.name,
        api: api ?? this.api,
        kind: kind ?? this.kind,
        origin: origin,
        builtin: builtin,
        enabled: enabled ?? this.enabled,
        tag: tag,
        reason: reason,
        ext: ext ?? this.ext,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'key': key,
        'name': name,
        'api': api,
        'kind': kind.name,
        'origin': origin.name,
        'builtin': builtin,
        'enabled': enabled,
        'tag': tag,
        'reason': reason,
        'ext': ext,
      };

  static KSource? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final key = _text(m['key']);
    final api = _text(m['api']);
    if (key.isEmpty || api.isEmpty) return null;
    final kind = KSourceKind.values.firstWhere(
      (k) => k.name == _text(m['kind']),
      orElse: () => KSourceKind.cms,
    );
    final origin = KSourceOrigin.values.firstWhere(
      (o) => o.name == _text(m['origin']),
      orElse: () => KSourceOrigin.user,
    );
    return KSource(
      key: key,
      name: _text(m['name']).isEmpty ? key : _text(m['name']),
      api: api,
      kind: kind,
      origin: origin,
      builtin: m['builtin'] == true,
      enabled: m['enabled'] != false,
      tag: _text(m['tag']),
      reason: _text(m['reason']),
      ext: _text(m['ext']),
    );
  }
}

/// TVBox 导入结果。
class TvBoxImport {
  const TvBoxImport({
    required this.added,
    required this.skipped,
    this.notes = const <String>[],
  });

  /// 成功加入的源数量。
  final int added;

  /// 跳过（type 3/4、地址为空）的源数量。
  final int skipped;

  /// 逐条说明（给设置页展示，别让用户猜为什么少了几个源）。
  final List<String> notes;
}

/// 一轮检索的源分组：自己的先查先渲染，外部的并行后台查、陆续追加。
///
/// 两组的源数加起来就是进度文案里的分母（幻想 7 + 肥猫 41 = 48）。
class SourceSearchPlan {
  const SourceSearchPlan({required this.own, required this.external});

  /// 我们自己的一批（云端下发的幻想线路 + 主站采集库）。
  final List<KSource> own;

  /// 外部那批（肥猫的 jar 源 + 用户自加）。
  final List<KSource> external;

  int get total => own.length + external.length;

  bool get isEmpty => total == 0;
}

/// 片源中心：云端配置 + 本地增删 + 多源检索。
///
/// 三件事：
///   1. **配置下发**：拉 `GET /api/config`，解析 `cloud_sources`（片源）
///      与 `live_url`（直播接口地址）；拉不到就用本地缓存，缓存也没有就用
///      内置空表 —— 任何一步失败都不能让 App 起不来。
///   2. **可删可恢复**：删掉的内置源只记一个 key 黑名单，云端的原始列表
///      一直留着，「恢复默认」= 清空黑名单，不需要重新拉配置。
///   3. **多源合并**：搜索 / 分类并行查所有启用的源，按「片名 + 年份」
///      去重，结果带上来源标记（云端 / 自加 / 采集库）；搜索分成
///      「自己的」和「外部的」两组渐进返回，见 [searchPlan]。
///
/// id 约定：外部源的影片 id 会编码成 `@src:<源key>::<vod_id>`，
/// 详情 / 播放据此路由回原来的源；主站采集库的 id 保持原样不动。
class SourceHub extends ChangeNotifier {
  SourceHub._();

  static final SourceHub instance = SourceHub._();

  /// 配置地址：`--dart-define=FX_CONFIG=…` 可覆盖，默认打主站 `/api/config`。
  static const String configOverride = String.fromEnvironment(
    'FX_CONFIG',
    defaultValue: '',
  );

  /// 播放器 UA：猫源那类站按 UA 分流 —— 浏览器 UA 拿到的是一张介绍页
  /// （HTML），只有播放器 UA 才回配置本身。肥猫回的配置还是加密的。
  static const String tvBoxUserAgent = 'okhttp/3.12.12';

  /// 默认 TVBox 配置地址（肥猫）。设置页的「配置地址」预填它，
  /// 首次启动也自动拉一次导入 —— 装完就有源，不用用户自己去别处找。
  static const String defaultTvBoxUrl = 'http://肥猫.net/';

  /// 首次自动导入的超时：失败静默，绝不拦首屏。
  static const Duration autoImportTimeout = Duration(seconds: 3);

  /// 中文域名 → punycode。
  ///
  /// Dart 的 `Uri` / `HttpClient` 不认非 ASCII 主机：`Uri.parse` 会把主机
  /// 百分号编码（`%E8%82%A5%E7%8C%AB.net`），`HttpClient.getUrl` 随即抛
  /// `FormatException`。所以展示可以用 `http://肥猫.net/`，发请求前换成
  /// punycode。表里没有的域名就按原样试，报错照常抛给调用方。
  static const Map<String, String> asciiHosts = <String, String>{
    '肥猫.net': 'xn--z7x900a.net',
  };

  /// 配置缓存有效期：6 小时内不重复拉取（手动刷新不受限）。
  static const Duration cacheTtl = Duration(hours: 6);

  /// 云端配置 `/api/config` 的超时：**3 秒**（TIMEOUT_UNIFY 2026-11-15）。
  ///
  /// 实测这份配置 0.14 秒就回来了，3 秒已经是很宽的余量；原来给 6 秒，
  /// 弱网下一次首屏要白等 6 秒才铺片源。列表 / 搜索 / 详情各自另有 8 秒。
  static const Duration timeout = Duration(seconds: 3);

  static const String _kCloud = 'fx_sources_cloud_v1';
  static const String _kLiveUrl = 'fx_sources_live_url_v1';
  static const String _kRemoved = 'fx_sources_removed_v1';
  static const String _kUser = 'fx_sources_user_v1';
  static const String _kFetchedAt = 'fx_sources_fetched_at_v1';
  static const String _kAutoImported = 'fx_sources_auto_tvbox_v1';

  /// 配置地址 → 能真正发出去的 [Uri]（顺手把中文域名换成 punycode）。
  static Uri requestUri(String raw) {
    var url = raw.trim();
    for (final entry in asciiHosts.entries) {
      if (url.contains(entry.key)) {
        url = url.replaceFirst(entry.key, entry.value);
      }
    }
    try {
      return Uri.parse(url);
    } on FormatException {
      throw ApiException('配置地址不合法：$raw');
    }
  }

  /// 外部源 id 前缀。主站 id 不带这个前缀，两套编号互不干扰。
  static const String idMark = '@src:';

  /// 「肥猫」那份 TVBox 配置自动导入时打的标记。
  ///
  /// 片源管理页只把这一批算成一条「肥猫」，不逐个列出来 —— 41 个 jar 源
  /// 一个个铺在设置页里，用户既看不清也管不过来。
  static const String fatCatTag = '肥猫';

  /// 手动「导入 TVBox」时打的标记（老版本自动导入也用它，一并归到肥猫那条）。
  static const String tvBoxTag = 'TVBox';

  /// 单源检索超时：超时按「这个源没结果」处理，不拖住其它源。
  static const Duration sourceTimeout = Duration(seconds: 8);

  /* ------------------------------------------------------ jar 插件可用性 */

  /// jar 插件（`spider.jar`）是否已安装；null = 还没查过。
  bool? _jarReady;

  Future<void>? _jarChecking;

  /// jar 插件是否可用（没查过按「不可用」算，绝不乐观）。
  bool get jarReady => _jarReady == true;

  /// 这台设备的源列表里有没有 jar 源（决定要不要自动装 spider.jar）。
  bool get hasJarSources => _user.any((s) => s.kind == KSourceKind.jar);

  /// 有 jar 源、但插件没装 —— 这正是「肥猫的源完全不加载」的原因。
  bool get jarMissing =>
      _jarReady == false && _user.any((s) => s.kind == KSourceKind.jar);

  /// 给页面用的可读提示（没什么可说的就空串）。
  ///
  /// JAR_NOTICE（2026-11-15）：`assets/spiders/spider.jar` 并没有打进 APK
  /// （`android_src/libs/api.jar` 只是 Spider 基类，不是源本身的 jar），
  /// 所以肥猫那 41 个 jar 源在「没手动装 jar」的机器上**一个都跑不起来**。
  /// 以前这些源照样进检索队列，每个 8 秒超时后被静默当成「没结果」，
  /// 用户看到的是「肥猫完全不加载」而且毫无解释。现在直接跳过并给出这句。
  String get jarNotice => jarMissing
      ? '肥猫的 ${bundledSources.length} 个 jar 源需要先装 jar 插件（spider.jar）才能出内容，'
          '到「片源管理 → 安装 jar 插件」装好后重新搜索'
      : '';

  /// 查一次 jar 插件状态（结果缓存，失败按「没装」处理）。
  Future<void> ensureJarStatus() {
    final running = _jarChecking;
    if (running != null) return running;
    if (_jarReady != null) return Future<void>.value();
    final task = () async {
      try {
        final status = await JarSpider.status().timeout(
          const Duration(seconds: 2),
          onTimeout: () => const JarStatus.missing(),
        );
        _jarReady = status.installed;
      } catch (_) {
        // 通道没起来 / 非 Android：按没装处理，jar 源跳过。
        _jarReady = false;
      }
    }();
    _jarChecking = task;
    return task.whenComplete(() {
      _jarChecking = null;
    });
  }

  /// jar 装好 / 卸载后强制重查（片源页装完 jar 调一次）。
  void invalidateJarStatus() {
    _jarReady = null;
    _jarChecking = null;
  }

  /// 这个源是不是「肥猫」那批量导入的一批。
  static bool isBundledSource(KSource source) =>
      source.tag == fatCatTag || source.tag == tvBoxTag;

  List<KSource> _cloud = const <KSource>[];
  List<KSource> _user = const <KSource>[];
  Set<String> _removed = <String>{};
  String _liveUrl = '';
  int _fetchedAt = 0;
  String _error = '';
  bool _refreshing = false;
  bool _loaded = false;
  Future<void>? _booting;

  /* ------------------------------------------------------------ 读取 */

  /// 云端下发的全部源（含已被用户删掉的，UI 用 [isRemoved] 标注）。
  List<KSource> get cloudSources => List<KSource>.unmodifiable(_cloud);

  /// 用户自加的源（不含「肥猫」那批量导入的一批）。
  ///
  /// 「我的源」区只列这些：肥猫那 41 个 jar 源在界面上归成一条内置项，
  /// 混在这里会让用户以为是自己加的。
  List<KSource> get userSources => List<KSource>.unmodifiable(<KSource>[
        for (final s in _user)
          if (!isBundledSource(s)) s,
      ]);

  /// 「肥猫」带来的源（TVBox 配置批量导入），界面只算一条。
  List<KSource> get bundledSources => List<KSource>.unmodifiable(<KSource>[
        for (final s in _user)
          if (isBundledSource(s)) s,
      ]);

  /// 我们自己的一批源（云端下发的幻想线路）：检索时先查、先渲染。
  List<KSource> get ownSources => List<KSource>.unmodifiable(<KSource>[
        for (final s in visibleCloud)
          if (s.searchable) s,
      ]);

  /// 是否已被用户删掉（只对云端内置源有意义）。
  bool isRemoved(String key) => _removed.contains(key.trim());

  /// 云端源里当前生效的（没被删、enabled 不为 false）。
  List<KSource> get visibleCloud => <KSource>[
        for (final s in _cloud)
          if (!_removed.contains(s.key) && s.enabled) s,
      ];

  /// 参与搜索 / 分类的源：云端生效的 + 用户自加的全部。
  ///
  /// 同一个地址只留一份（云端和用户各加一遍很常见），直播源不在此列。
  List<KSource> get querySources {
    final out = <KSource>[];
    final seen = <String>{};
    void take(KSource s) {
      if (!s.searchable) return;
      // jar 插件没装：这些源一次也查不出来（原生只会回 no_jar），
      // 跳过它们，别让每次搜索白等 8 秒（JAR_NOTICE）。
      if (s.kind == KSourceKind.jar && _jarReady == false) return;
      // jar 源的 api 是类名，同一个类靠 ext 区分不同站点（肥猫 / 饭太硬 / 二小
      // 常常共用一个 csp_Xxx），只按 api 去重会把它们合并成一个源。
      final key = s.kind == KSourceKind.jar
          ? '${s.api.trim()}|${s.ext}'
          : s.api.trim();
      if (!seen.add(key)) return;
      out.add(s);
    }

    for (final s in visibleCloud) {
      take(s);
    }
    for (final s in _user) {
      take(s);
    }
    return out;
  }

  /// 云端直播接口地址：优先配置里的 `live_url`，否则取 `type: live` 的源。
  String get liveUrl {
    final direct = _liveUrl.trim();
    if (direct.isNotEmpty) return direct;
    for (final s in visibleCloud) {
      if (s.kind == KSourceKind.live && s.api.trim().isNotEmpty) {
        return s.api.trim();
      }
    }
    for (final s in _user) {
      if (s.isLive && s.api.trim().isNotEmpty) return s.api.trim();
    }
    return '';
  }

  /// 云端配置里是不是显式配了直播地址（设置页用它提示）。
  bool get hasCloudLiveUrl => liveUrl.isNotEmpty;

  /// 检索源统计文案：「幻想 7 + 肥猫 41」。
  ///
  /// 片源页原来写「48 个源参与检索」，用户看不出这 48 个是怎么来的 ——
  /// 拆成我们自己那 7 条 + 肥猫那一条（内部 41 个 jar 源）才对得上界面。
  String get retrievalLabel {
    final parts = <String>[
      '幻想 ${ownSources.length}',
      '肥猫 ${bundledSources.length}',
    ];
    final mine = <KSource>[
      for (final s in userSources)
        if (s.searchable) s,
    ];
    if (mine.isNotEmpty) parts.add('自加 ${mine.length}');
    return parts.join(' + ');
  }

  /// 一轮检索要查的源，按「自己的」/「外部的」分组。
  ///
  /// 自己的那批（云端下发的幻想线路）先查先渲染；外部那批（肥猫的 jar 源 +
  /// 用户自加）并行在后台查，谁先回来谁先追加到列表下面。
  SourceSearchPlan get searchPlan {
    String keyOf(KSource s) => s.kind == KSourceKind.jar
        ? '${s.api.trim()}|${s.ext}'
        : s.api.trim();
    final own = <KSource>[];
    final external = <KSource>[];
    final ownSeen = <String>{};
    final extSeen = <String>{};
    bool usable(KSource s) =>
        s.searchable && !(s.kind == KSourceKind.jar && _jarReady == false);
    for (final s in visibleCloud) {
      if (!usable(s)) continue;
      if (!ownSeen.add(keyOf(s))) continue;
      own.add(s);
    }
    for (final s in _user) {
      if (!usable(s)) continue;
      final key = keyOf(s);
      // 已经在我们自己的那批里出现过的地址，不再查第二遍。
      if (ownSeen.contains(key)) continue;
      if (!extSeen.add(key)) continue;
      external.add(s);
    }
    return SourceSearchPlan(own: own, external: external);
  }

  DateTime? get fetchedAt =>
      _fetchedAt <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(_fetchedAt);

  String get lastError => _error;

  bool get refreshing => _refreshing;

  bool get loaded => _loaded;

  /// 至少要读过一次本地缓存（[ensureReady] 内完成）。
  ///
  /// BOOT_RESILIENT（2026-11-15）：**失败的初始化不能被缓存下来**。
  /// 原来 `_booting` 一旦持有一个抛过异常的 Future，之后每一次
  /// `ensureReady()` 都会立刻拿到同一个失败 —— 搜索流在
  /// `await hub.ensureReady()` 当场炸掉，而那个异常没人收，流既不 close
  /// 也不 error，页面就永远停在骨架屏（用户实测的「一直转圈」）。
  /// 现在失败时把 `_booting` 清空，下次调用重新初始化。
  Future<void> ensureReady() {
    final running = _booting;
    if (running != null) return running;
    final task = _boot();
    _booting = task;
    // 失败后允许重试：清掉缓存，下次 ensureReady 重新走一遍 _boot。
    unawaited(task.then<void>((_) {}, onError: (Object _) {
      if (identical(_booting, task)) _booting = null;
    }));
    return task;
  }

  Future<void> _boot() async {
    await _loadCache();
    // 首次启动：后台把默认 TVBox 配置（肥猫）导一次，不挡首屏。
    unawaited(_importDefaultTvBoxOnce());
    // 缓存过期或从来没拉过：后台补一次，不挡首屏。
    final age = _fetchedAt <= 0
        ? null
        : DateTime.now().difference(
            DateTime.fromMillisecondsSinceEpoch(_fetchedAt),
          );
    if (age == null || age > cacheTtl) unawaited(refresh());
  }

  /// 首次启动自动导入默认配置（[defaultTvBoxUrl]）。
  ///
  /// 触发条件：没成功导过、且用户手上还没有自加源（老用户升级上来不该被
  /// 突然塞一堆源，删过源的也不重灌）。3 秒超时、失败静默并且**不写标记**，
  /// 下次启动再试 —— 首屏不等它，网络差也就是没有这些源而已。
  Future<void> _importDefaultTvBoxOnce() async {
    try {
      final sp = await SharedPreferences.getInstance();
      if (sp.getBool(_kAutoImported) == true) return;
      if (_user.isNotEmpty) {
        await sp.setBool(_kAutoImported, true);
        return;
      }
      final result = await importTvBox(
        defaultTvBoxUrl,
        timeout: autoImportTimeout,
        tag: fatCatTag,
      );
      if (result.added > 0) {
        await sp.setBool(_kAutoImported, true);
      }
    } catch (_) {
      // 静默：没网 / 超时 / 配置换了格式，都当没这回事。
    }
  }

  /* ------------------------------------------------------------ 云端配置 */

  List<String> get _configCandidates {
    final out = <String>[];
    if (configOverride.trim().isNotEmpty) out.add(configOverride.trim());
    out.add('${CmsApi.root}/api/config');
    out.add('${CmsApi.root}/api/config.json');
    return out;
  }

  /// 拉云端配置。返回是否成功；失败时保留缓存并记录 [lastError]。
  Future<bool> refresh() async {
    if (_refreshing) return false;
    _refreshing = true;
    notifyListeners();
    var ok = false;
    var error = '';
    for (final url in _configCandidates) {
      try {
        final r = await http
            .get(Uri.parse(url), headers: const <String, String>{
              'accept': 'application/json',
            })
            .timeout(timeout);
        if (r.statusCode >= 400) {
          error = 'HTTP ${r.statusCode}';
          continue;
        }
        final body = jsonDecode(utf8.decode(r.bodyBytes, allowMalformed: true));
        final map = _configMap(body);
        if (map == null) {
          error = '配置格式不对';
          continue;
        }
        _applyConfig(map);
        await _saveAll();
        _error = '';
        _fetchedAt = DateTime.now().millisecondsSinceEpoch;
        await _saveFetchedAt();
        ok = true;
        break;
      } on TimeoutException {
        error = '配置请求超时';
      } on FormatException {
        error = '配置不是合法 JSON';
      } catch (e) {
        error = '$e';
      }
    }
    _refreshing = false;
    _error = ok ? '' : (error.isEmpty ? '配置拉取失败' : error);
    _loaded = true;
    notifyListeners();
    return ok;
  }

  /// 兼容三种外壳：裸对象 / `{data:{…}}` / `{code:1,data:{…}}`。
  Map<String, dynamic>? _configMap(Object? body) {
    if (body is Map) {
      final map = Map<String, dynamic>.from(body);
      if (map['cloud_sources'] is List || map['live_url'] is String) return map;
      final data = map['data'];
      if (data is Map) return Map<String, dynamic>.from(data);
      if (data is List) return <String, dynamic>{'cloud_sources': data};
      if (map['list'] is List) {
        // 后台把配置存成列表接口的形态也认。
        return <String, dynamic>{'cloud_sources': map['list']};
      }
      // 空配置也算配置：允许后台先建一份空表，App 就用内置零自定义源。
      if (map.isEmpty) return map;
      return map;
    }
    if (body is List) return <String, dynamic>{'cloud_sources': body};
    return null;
  }

  void _applyConfig(Map<String, dynamic> map) {
    final raw = map['cloud_sources'] ?? map['sources'];
    final parsed = <KSource>[];
    final seen = <String>{};
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        final s = _cloudOf(Map<String, dynamic>.from(e));
        if (s == null) continue;
        if (!seen.add(s.key)) continue;
        parsed.add(s);
      }
    }
    _cloud = parsed;
    final live = _firstText(<Object?>[
      map['live_url'],
      map['live_api'],
      map['live'],
      map['live_playlist'],
    ]);
    // 后台删掉 live_url 时要跟着清空：否则页面会一直显示上一次下发的地址
    // （IP 已经换掉了，地址还挂在片源管理页上）。
    _liveUrl = live;
  }

  /// 取第一个非空文本（配置里同一项可能有多种写法）。
  static String _firstText(List<Object?> values) {
    for (final value in values) {
      final text = _text(value);
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  KSource? _cloudOf(Map<String, dynamic> m) {
    final key = _text(m['key']);
    final api = _text(m['api']);
    if (key.isEmpty || api.isEmpty) return null;
    final name = _text(m['name']).isEmpty ? key : _text(m['name']);
    final kind = kindOf(m['type']);
    return KSource(
      key: key,
      name: name,
      api: api,
      kind: kind,
      origin: KSourceOrigin.cloud,
      builtin: m['builtin'] != false,
      enabled: m['enabled'] != false,
      reason: _reasonOf(m['type'], kind),
      ext: _textOfExt(m['ext']),
    );
  }

  /// 后台 / TVBox 的 `type` → 我们的种类。
  static KSourceKind kindOf(Object? raw) {
    if (raw is num) return _kindOfNumber(raw.toInt());
    final text = _text(raw).toLowerCase();
    if (text.contains('live') || text.contains('直播')) return KSourceKind.live;
    final n = int.tryParse(text);
    if (n != null) return _kindOfNumber(n);
    // 没写 type：按 CMS 接口处理（苹果CMS 是最常见的形态）。
    return KSourceKind.cms;
  }

  static KSourceKind _kindOfNumber(int n) {
    switch (n) {
      case 0:
        return KSourceKind.direct;
      case 1:
        return KSourceKind.cms;
      case 3:
        return KSourceKind.jar;
      case 4:
        return KSourceKind.unsupported;
      default:
        return KSourceKind.unsupported;
    }
  }

  static String _reasonOf(Object? raw, KSourceKind kind) {
    if (kind != KSourceKind.unsupported) return '';
    final text = _text(raw);
    final n = int.tryParse(text);
    if (n == 4) return 'type 4（python 解析脚本）暂不支持';
    return 'type $text 暂不支持';
  }

  /* ------------------------------------------------------------ 增删改 */

  /// 删掉一个云端内置源（只记黑名单，云端原始配置不动）。
  Future<void> removeCloud(String key) async {
    final k = key.trim();
    if (k.isEmpty) return;
    _removed = <String>{..._removed, k};
    await _saveRemoved();
    notifyListeners();
  }

  /// 恢复默认：被删掉的内置源全部回来。
  Future<void> restoreDefaults() async {
    if (_removed.isEmpty) return;
    _removed = <String>{};
    await _saveRemoved();
    notifyListeners();
  }

  /// 用户自加一个源。地址为空抛 [ApiException]，由 UI 直接 toast。
  Future<KSource> addUser({
    required String name,
    required String api,
    Object? type = 1,
    String tag = '',
    String ext = '',
  }) async {
    final address = api.trim();
    if (address.isEmpty) throw ApiException('填一下片源地址');
    final kind = kindOf(type);
    // JAR_CLASS（2026-11-15）：jar 插件源的 `api` 是**类名**（`csp_Xxx`），
    // 不是网址。这里原来一律要求 http(s)://，于是「添加片源 → jar 插件」
    // 永远保存失败（弹窗却特意提示「填 jar 里的类名」）。updateUser 早就按
    // kind 分别校验，这里对齐。
    if (kind != KSourceKind.jar &&
        !address.startsWith('http://') &&
        !address.startsWith('https://')) {
      throw ApiException('片源地址要以 http(s):// 开头');
    }
    var label = name.trim();
    if (label.isEmpty) {
      final host = Uri.tryParse(address)?.host ?? '';
      label = host.isEmpty ? '我的片源' : host;
    }
    final source = KSource(
      key: _newUserKey(label),
      name: label,
      api: address,
      kind: kind,
      origin: KSourceOrigin.user,
      enabled: true,
      tag: tag,
      reason: _reasonOf(type, kind),
      ext: ext.trim(),
    );
    _user = <KSource>[..._user, source];
    await _saveUser();
    notifyListeners();
    return source;
  }

  /// 修改一个用户自加源（云端源不允许改，只能删了再恢复）。
  Future<void> updateUser(
    String key, {
    String? name,
    String? api,
    Object? type,
    String? ext,
  }) async {
    final k = key.trim();
    if (k.isEmpty) return;
    final next = <KSource>[];
    for (final s in _user) {
      if (s.key != k) {
        next.add(s);
        continue;
      }
      final address = (api ?? s.api).trim();
      if (address.isEmpty) throw ApiException('填一下片源地址');
      final kind = type == null ? s.kind : kindOf(type);
      final label = (name ?? s.name).trim();
      next.add(KSource(
        key: s.key,
        name: label.isEmpty ? s.name : label,
        api: address,
        kind: kind,
        origin: s.origin,
        builtin: false,
        enabled: true,
        tag: s.tag,
        reason: _reasonOf(type, kind),
        ext: (ext ?? s.ext).trim(),
      ));
    }
    _user = next;
    await _saveUser();
    notifyListeners();
  }

  Future<void> removeUser(String key) async {
    final k = key.trim();
    final next = <KSource>[
      for (final s in _user)
        if (s.key != k) s,
    ];
    if (next.length == _user.length) return;
    _user = next;
    await _saveUser();
    notifyListeners();
  }

  /// TVBox / 猫源导入：粘贴 JSON 或填一个配置地址，解析 `sites` 数组。
  ///
  /// 收 `type: 1`（CMS 接口）、`type: 0`（直接地址）、`type: 3`（jar 插件，
  /// `api` 是类名、`ext` 是站点配置，需要先装好 `spider.jar`）；
  /// `type: 4`（python 脚本）标记「暂不支持」后跳过。
  /// 是否指向本站苹果CMS 接口（App 内置源，导入时应跳过）。
  static bool _isOurOwnApi(String api) {
    final u = api.trim().toLowerCase();
    if (u.isEmpty) return false;
    final root = CmsApi.root.toLowerCase();
    if (root.isNotEmpty && u.startsWith(root)) return true;
    return u.contains('125.94.244.87/api.php') ||
        u.contains('api.php/provide/vod');
  }

  Future<TvBoxImport> importTvBox(
    String input, {
    Duration? timeout,
    String tag = tvBoxTag,
  }) async {
    final text = input.trim();
    if (text.isEmpty) throw ApiException('先粘贴 TVBox 配置或填一个地址');
    String body = text;
    if (text.startsWith('http://') || text.startsWith('https://')) {
      try {
        final r = await http
            .get(requestUri(text), headers: const <String, String>{
              'accept': '*/*',
              // 猫源那类站按 UA 分流：浏览器 UA 给的是介绍页（HTML），
              // 播放器 UA 才给配置（肥猫给的就是加密配置）。
              'user-agent': tvBoxUserAgent,
            })
            .timeout(timeout ?? const Duration(seconds: 12));
        if (r.statusCode >= 400) throw ApiException.server(r.statusCode);
        // 加密配置是纯 ASCII 的 hex，用 bodyBytes 兜住乱码更稳。
        body = utf8.decode(r.bodyBytes, allowMalformed: true);
      } on TimeoutException {
        throw ApiException.timeout();
      } on http.ClientException {
        throw ApiException.network();
      }
    }
    // 加密配置（`$#key#$` + AES-CBC）：先解出明文 JSON，再走下面同一套解析。
    final plain = decodeTvBoxConfig(body);
    final config = plain ?? body;
    final rawSites = _sitesOf(config);
    if (rawSites.isEmpty) {
      throw ApiException(
        plain == null && isTvBoxEncrypted(body)
            ? '这份配置是加密的，但解不开（密文被截断或换了加密方式），换个地址试试'
            : '没解析到 sites 数组，检查一下配置内容',
      );
    }
    // 排除指向本站接口的源：那是 App 内置的七个源（幻想腾讯/全部线路/4K/1080P/
    // 爱奇艺/量子/红牛），导入云端配置时再进来一份只会让源列表重复。
    var selfSkipped = 0;
    final sites = <Map<String, dynamic>>[];
    for (final s in rawSites) {
      final api = _text(s['api']);
      if (api.isNotEmpty && _isOurOwnApi(api)) {
        selfSkipped++;
        continue;
      }
      sites.add(s);
    }
    if (sites.isEmpty) {
      throw ApiException(
        selfSkipped > 0 ? '这份配置里的源都是本站内置的，没有需要导入的' : '没解析到 sites 数组，检查一下配置内容',
      );
    }

    final notes = <String>[];
    final added = <KSource>[];
    // 去重键：普通源看地址；jar 源看「类名 + ext」（同类不同 ext 是不同的站点）。
    final taken = <String>{
      for (final s in _user)
        s.kind == KSourceKind.jar ? '${s.api.trim()}|${s.ext}' : s.api.trim(),
    };
    var skipped = 0;
    var jarNotice = false;
    for (final site in sites) {
      final name = _text(site['name']).isEmpty
          ? _text(site['key'])
          : _text(site['name']);
      final api = _text(site['api']);
      final ext = _textOfExt(site['ext']);
      final kind = kindOf(site['type']);
      if (api.isEmpty) {
        skipped++;
        notes.add('「$name」没有地址，已跳过');
        continue;
      }
      if (kind == KSourceKind.unsupported) {
        skipped++;
        notes.add('「$name」${_reasonOf(site['type'], kind)}，已跳过');
        continue;
      }
      if (kind == KSourceKind.live) {
        skipped++;
        notes.add('「$name」是直播列表，请到「直播」页添加');
        continue;
      }
      final dedupeKey =
          kind == KSourceKind.jar ? '$api|$ext' : api;
      if (!taken.add(dedupeKey)) {
        skipped++;
        continue;
      }
      if (kind == KSourceKind.jar) jarNotice = true;
      added.add(KSource(
        key: _newUserKey(name.isEmpty ? 'tvbox' : name),
        name: name.isEmpty ? 'TVBox 片源' : name,
        api: api,
        kind: kind,
        origin: KSourceOrigin.user,
        enabled: true,
        tag: tag,
        ext: ext,
      ));
    }
    if (jarNotice) {
      final jar = JarSpider.cachedStatus ?? await JarSpider.status();
      notes.add(jar.installed
          ? 'jar 源已导入，解析交给本地的 spider.jar'
          : '导入了 jar 源，但还没装 spider.jar：到片源页点「安装 jar 插件」，这些源才能出内容');
    }
    if (added.isNotEmpty) {
      _user = <KSource>[..._user, ...added];
      await _saveUser();
      notifyListeners();
    }
    return TvBoxImport(
      added: added.length,
      skipped: skipped,
      notes: notes,
    );
  }

  List<Map<String, dynamic>> _sitesOf(String body) {
    Object? raw;
    try {
      raw = jsonDecode(body);
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
    List<Object?> list = const <Object?>[];
    if (raw is Map) {
      final map = Map<String, dynamic>.from(raw);
      final sites = map['sites'] ?? map['api_site'] ?? map['list'];
      if (sites is List) {
        list = sites;
      } else if (sites is Map) {
        // `api_site` 是 {key: {name, api, type}}，key 要补进每一项。
        list = <Object?>[
          for (final entry in sites.entries)
            if (entry.value is Map)
              <String, dynamic>{
                'key': '${entry.key}',
                ...Map<String, dynamic>.from(entry.value as Map),
              },
        ];
      }
    } else if (raw is List) {
      list = raw;
    }
    final out = <Map<String, dynamic>>[];
    for (final e in list) {
      if (e is! Map) continue;
      out.add(Map<String, dynamic>.from(e));
    }
    return out;
  }

  String _newUserKey(String name) {
    final base = name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fa5]+'), '_');
    final head = base.isEmpty ? 'src' : base;
    var key = 'u_$head';
    var i = 1;
    final used = <String>{
      for (final s in _cloud) s.key,
      for (final s in _user) s.key,
    };
    while (used.contains(key)) {
      i++;
      key = 'u_${head}_$i';
    }
    return key;
  }

  /* ------------------------------------------------------------ 多源检索 */

  /// 并行查所有启用源，合并去重。
  ///
  /// [seen] 由调用方传入时，会先把主站采集库的结果记进去，跨源去重一并对齐；
  /// 返回的卡片 id 已编码成 `@src:<key>::<id>`，详情 / 播放按它路由。
  Future<List<VideoCard>> searchAll(
    String keyword,
    int page, {
    Set<String>? seen,
  }) async {
    await ensureReady();
    final sources = querySources;
    if (sources.isEmpty) return const <VideoCard>[];
    final lists = await Future.wait(<Future<List<VideoCard>>>[
      for (final s in sources) _searchOne(s, keyword, page),
    ]);
    return _merge(sources, lists, seen ?? <String>{});
  }

  /// 并行按分类查所有启用源（分类映射用各源自己的 class 列表）。
  Future<List<VideoCard>> categoryAll(
    String channelKey,
    int page, {
    Set<String>? seen,
  }) async {
    final key = channelKey.trim();
    if (key.isEmpty || key == 'recommend') return const <VideoCard>[];
    await ensureReady();
    final sources = querySources;
    if (sources.isEmpty) return const <VideoCard>[];
    final lists = await Future.wait(<Future<List<VideoCard>>>[
      for (final s in sources) _categoryOne(s, key, page),
    ]);
    return _merge(sources, lists, seen ?? <String>{});
  }

  Future<List<VideoCard>> _searchOne(
    KSource source,
    String keyword,
    int page,
  ) async {
    final q = keyword.trim();
    if (q.isEmpty) return const <VideoCard>[];
    try {
      if (source.kind == KSourceKind.jar) {
        return await JarSpider.search(
          api: source.api,
          ext: source.ext,
          key: q,
          page: page,
        );
      }
      return await CmsClient.of(source.api).search(q, page);
    } catch (_) {
      return const <VideoCard>[];
    }
  }

  /// 查单个源并加工成可直接上列表的样子：带来源标记、id 编码成
  /// `@src:<key>::<vod_id>`。
  ///
  /// 渐进检索用这个：外部源一个比一个慢，谁先回来就先交给页面渲染。
  /// 单源超过 [sourceTimeout] 一律当「这个源没结果」，不阻塞其它源。
  Future<List<VideoCard>> searchPrepared(
    KSource source,
    String keyword,
    int page,
  ) async {
    final cards = await _searchOne(source, keyword, page).timeout(
      sourceTimeout,
      onTimeout: () => const <VideoCard>[],
    );
    return <VideoCard>[
      for (final card in cards)
        if (!isLiveCard(card))
          relabel(
            card,
            label: source.originLabel,
            id: encodeId(source.key, card.id),
          ),
    ];
  }

  Future<List<VideoCard>> _categoryOne(
    KSource source,
    String channelKey,
    int page,
  ) async {
    try {
      if (source.kind == KSourceKind.jar) {
        // jar 源的分类 id 来自它自己的 homeContent（class 列表），
        // 先按名字映射到我们的频道键，再拿它真实的 type_id 去取列表。
        final typeId = await JarSpider.typeIdOfChannel(
          source.api,
          source.ext,
          channelKey,
        );
        if (typeId.isEmpty) return const <VideoCard>[];
        return await JarSpider.category(
          api: source.api,
          ext: source.ext,
          tid: typeId,
          page: page,
        );
      }
      final client = CmsClient.of(source.api);
      await client.classes();
      final typeId = client.typeIdOfChannel(channelKey);
      if (typeId <= 0) return const <VideoCard>[];
      return await client.list(type: typeId, page: page);
    } catch (_) {
      return const <VideoCard>[];
    }
  }

  List<VideoCard> _merge(
    List<KSource> sources,
    List<List<VideoCard>> lists,
    Set<String> seen,
  ) {
    final out = <VideoCard>[];
    for (var i = 0; i < sources.length && i < lists.length; i++) {
      final source = sources[i];
      final label = source.originLabel;
      for (final card in lists[i]) {
        if (isLiveCard(card)) continue;
        if (!seen.add(dedupeKey(card))) continue;
        out.add(relabel(
          card,
          label: label,
          id: encodeId(source.key, card.id),
        ));
      }
    }
    return out;
  }

  /* ------------------------------------------------------------ id 路由 */

  /// 外部源的 id 编码（主站 id 不做任何加工）。
  static String encodeId(String sourceKey, String vodId) =>
      '$idMark$sourceKey::$vodId';

  /// 编码 id → 源（源已被删掉 / 认不出来时返回 null）。
  KSource? decodeSource(String id) {
    final raw = id.trim();
    if (!raw.startsWith(idMark)) return null;
    final rest = raw.substring(idMark.length);
    final at = rest.indexOf('::');
    if (at <= 0) return null;
    final key = rest.substring(0, at);
    for (final s in _cloud) {
      if (s.key == key) return s;
    }
    for (final s in _user) {
      if (s.key == key) return s;
    }
    return null;
  }

  /// 编码 id → 源里的原始 vod_id。
  static String rawIdOf(String id) {
    final raw = id.trim();
    if (!raw.startsWith(idMark)) return raw;
    final rest = raw.substring(idMark.length);
    final at = rest.indexOf('::');
    if (at < 0) return raw;
    return rest.substring(at + 2);
  }

  /* ------------------------------------------------------------ 卡片工具 */

  /// 跨源去重键：片名（去空白与标点）+ 年份 + **片源分组**。
  ///
  /// SOURCE_SPLIT（2026-11-15）：服务端把同一部剧按片源拆成多条记录
  /// （hx=幻想 / xo=官采切片），两条都对、都要出现。所以去重只在
  /// 「同一片源内」生效：片名+年份+片源 完全相同才算重复。
  static String dedupeKey(VideoCard card) =>
      '${normTitle(card.title)}|${card.year}|${card.fromSource}';

  static String normTitle(String raw) {
    final text = raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\u3000·・•,，。.、:：;；!！?？\-—_/\\|｜()（）\[\]【】]'), '');
    return text;
  }

  /// 直播内容不能出现在搜索 / 分类 / 排行里（直播有独立入口）。
  static bool isLiveCard(VideoCard card) {
    final text = '${card.category}${card.type}${card.status}';
    if (text.contains('直播') || text.contains('频道')) return true;
    final label = card.sourceLabel;
    return label == '直播' || label == 'live';
  }

  /// 复制一张卡片，换掉来源标记（可选换 id）。
  static VideoCard relabel(
    VideoCard card, {
    required String label,
    String? id,
  }) =>
      VideoCard(
        id: id ?? card.id,
        title: card.title,
        cover: card.cover,
        rating: card.rating,
        year: card.year,
        status: card.status,
        episodes: card.episodes,
        category: card.category,
        type: card.type,
        area: card.area,
        heat: card.heat,
        desc: card.desc,
        time: card.time,
        rank: card.rank,
        tags: card.tags,
        sourceLabel: label,
        // SOURCE_SPLIT：换标记不能把片源分组弄丢，去重键要用它。
        fromSource: card.fromSource,
      );

  /* ------------------------------------------------------------ 持久化 */

  Future<void> _loadCache() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final cloudRaw = sp.getString(_kCloud);
      if (cloudRaw != null && cloudRaw.trim().isNotEmpty) {
        _cloud = _decodeList(cloudRaw);
      }
      final userRaw = sp.getString(_kUser);
      if (userRaw != null && userRaw.trim().isNotEmpty) {
        _user = _decodeList(userRaw);
      }
      final removedRaw = sp.getStringList(_kRemoved);
      if (removedRaw != null) _removed = removedRaw.toSet();
      _liveUrl = sp.getString(_kLiveUrl) ?? '';
      _fetchedAt = sp.getInt(_kFetchedAt) ?? 0;
    } catch (_) {
      // 缓存坏了就当没有：下次 refresh 会重新写一遍。
    }
    _loaded = true;
    _notifySafely();
  }

  /// 通知监听者，但绝不让监听者的异常污染调用链（BOOT_RESILIENT）。
  ///
  /// `notifyListeners()` 里任何一个监听者抛异常都会原样冒出来 —— 在
  /// [_boot] 里就意味着「读缓存失败」，进而把 _booting 变成失败的 Future。
  void _notifySafely() {
    try {
      notifyListeners();
    } catch (_) {
      // 某个页面监听坏了不该拖垮片源索引。
    }
  }

  /// 缓存里的 JSON 数组 → 源列表（坏条目直接丢）。
  List<KSource> _decodeList(String raw) {
    final body = jsonDecode(raw);
    if (body is! List) return const <KSource>[];
    final out = <KSource>[];
    for (final e in body) {
      final s = KSource.fromMap(e);
      if (s != null) out.add(s);
    }
    return out;
  }

  Future<void> _saveAll() async {    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
        _kCloud,
        jsonEncode(<Map<String, dynamic>>[for (final s in _cloud) s.toMap()]),
      );
      await sp.setString(
        _kUser,
        jsonEncode(<Map<String, dynamic>>[for (final s in _user) s.toMap()]),
      );
      await sp.setString(_kLiveUrl, _liveUrl);
      await sp.setStringList(_kRemoved, _removed.toList());
    } catch (_) {}
  }

  Future<void> _saveUser() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
        _kUser,
        jsonEncode(<Map<String, dynamic>>[for (final s in _user) s.toMap()]),
      );
    } catch (_) {}
  }

  Future<void> _saveRemoved() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(_kRemoved, _removed.toList());
    } catch (_) {}
  }

  Future<void> _saveFetchedAt() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_kFetchedAt, _fetchedAt);
    } catch (_) {}
  }

  /// 调试用：清掉本地片源缓存（不动云端配置）。
  ///
  /// 顺带清掉「默认配置已自动导入」的标记：恢复默认就该把肥猫那份重新导回来
  /// （下次启动时生效）。
  Future<void> resetLocal() async {
    _removed = <String>{};
    _user = const <KSource>[];
    _liveUrl = '';
    _fetchedAt = 0;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_kCloud);
      await sp.remove(_kUser);
      await sp.remove(_kRemoved);
      await sp.remove(_kLiveUrl);
      await sp.remove(_kFetchedAt);
      await sp.remove(_kAutoImported);
    } catch (_) {}
    notifyListeners();
  }
}

/// 任意值 → 去空白的文本（配置字段可能是 null / 数字 / 字符串）。
String _text(Object? raw) {
  if (raw == null) return '';
  return raw.toString().trim();
}

/// TVBox 的 `ext` → 交给 jar 源的原样文本。
///
/// `ext` 有时是字符串（一个地址、一个标记），有时是一整段对象
/// （`{"site_urls":[…],"url_key":"…"}`）。后者必须按 JSON 编码，
/// 直接 `toString()` 得到的是 `{site_urls: [...]}` —— 不是合法 JSON，
/// jar 那边 `JSON.parse` 一挂，这个源就永远空列表。
String _textOfExt(Object? raw) {
  if (raw is Map || raw is List) return jsonEncode(raw);
  return _text(raw);
}

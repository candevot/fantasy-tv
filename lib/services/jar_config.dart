/// jar 源的**线上配置**（`hx_all.json`）：`api` + 完整 `ext`。
///
/// 用户口径（2026-11-21）：「四个 jar 源的 api + ext 不再内置硬编码，改成启动
/// 时拉接口，接口挂了用本地缓存的上一次配置，不能因此全不可用」。
///
/// 这一层只做三件事：
///   1. 拉 `http://125.94.244.87/hx_all.json`，从 `sites` 里按 key / name
///      取出白名单里那几个源的**原始配置**（`api` / `ext` / `name`）；
///   2. 拉成功就把整份配置落盘（`SharedPreferences`），**下次接口挂了用缓存**；
///   3. 缓存也没有时退回 [kBuiltinJarSources]（最后一次实测可用的那份）。
///
/// 为什么不把 ext 抄进代码：同一台服务器上的 `橘汁` / `剧圈` 都靠 ext 里的
/// pkg / host / 签名区分站点，抄错一个字整条线路就空（实测：`csp_AppDrama`
/// 传空 ext 直接 `NullPointerException`，`csp_App99` 传空 ext 报
/// `IllegalArgumentException: Empty key`）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'jar_sources.dart';

/// 线上配置文件（和服务端同一台机器，直出静态 JSON）。
const String kJarConfigEndpoint = 'http://125.94.244.87/hx_all.json';

/// 拉取 + 缓存的入口（全局单例）。
class JarConfig {
  JarConfig._();

  static final JarConfig instance = JarConfig._();

  /// 缓存键：整份 `hx_all.json` 原文（不是解析后的对象，方便以后字段变化）。
  static const String _kCache = 'fx_jar_config_json';

  /// 测试里关掉网络（`flutter test` 里没有外网，也不该每个用例等 3 秒）。
  static bool networkEnabled = true;

  /// 失败重试间隔：接口只挂一次不该让每次搜索都白等 8 秒。
  static const Duration retryAfter = Duration(minutes: 5);

  List<FxJarSourceDef> _defs = kBuiltinJarSources;
  bool _loaded = false;
  bool _fromNetwork = false;
  String _lastError = '';
  DateTime _lastTry = DateTime.fromMillisecondsSinceEpoch(0);

  /// 当前生效的源定义（接口 → 缓存 → 内置 的顺序取到的）。
  List<FxJarSourceDef> get defs => _defs;

  /// 这一份是不是接口拉下来的（诊断 / 测试用）。
  bool get fromNetwork => _fromNetwork;

  /// 最近一次失败原因（空串 = 没失败过）。
  String get lastError => _lastError;

  /// 已经从任一层拿到过配置（保证不会每帧重复拉）。
  bool get loaded => _loaded;

  /// 测试 / 换账号时重置。
  void reset() {
    _defs = kBuiltinJarSources;
    _loaded = false;
    _fromNetwork = false;
    _lastError = '';
    _lastTry = DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// 保证拿到一份配置。
  ///
  /// 顺序：内存 → 网络（3 秒超时）→ 缓存 → 内置。任何一步成功就停；
  /// **永远不抛异常**，最差也是内置那份可用配置。
  Future<void> ensureLoaded({bool force = false}) async {
    if (_loaded && !force) return;
    final now = DateTime.now();
    if (!force && _lastTry != DateTime.fromMillisecondsSinceEpoch(0)) {
      if (now.difference(_lastTry) < retryAfter) return;
    }
    _lastTry = now;

    // 1) 网络
    if (networkEnabled) try {
      final res = await http
          .get(Uri.parse(kJarConfigEndpoint))
          .timeout(const Duration(seconds: 3));
      if (res.statusCode == 200 && res.body.trim().isNotEmpty) {
        final parsed = parseSitesJson(res.body);
        if (parsed.isNotEmpty) {
          _defs = parsed;
          _loaded = true;
          _fromNetwork = true;
          _lastError = '';
          unawaited(_writeCache(res.body));
          return;
        }
        _lastError = '接口里没有白名单源';
      } else {
        _lastError = 'HTTP ${res.statusCode}';
      }
    } catch (e) {
      _lastError = '$e';
    }

    // 2) 缓存
    try {
      final sp = await SharedPreferences.getInstance();
      final cached = sp.getString(_kCache) ?? '';
      if (cached.trim().isNotEmpty) {
        final parsed = parseSitesJson(cached);
        if (parsed.isNotEmpty) {
          _defs = parsed;
          _loaded = true;
          _fromNetwork = false;
          return;
        }
      }
    } catch (_) {
      // 缓存读不出来就继续往下走内置那份。
    }

    // 3) 内置兜底（最后一次实测可用的配置，见 kBuiltinJarSources）。
    _defs = kBuiltinJarSources;
    _loaded = true;
    _fromNetwork = false;
  }

  Future<void> _writeCache(String body) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kCache, body);
    } catch (_) {
      // 写不进去只影响下次离线兜底，不影响本轮。
    }
  }

  /// 从 `hx_all.json` 原文里取出白名单源的配置。
  ///
  /// 只认 [kEnabledJarSources] 里的名字（`fxJarLabelOf` 前缀匹配，
  /// `剧圈99` / `剧圈 • APP` 都能命中 `剧圈`）；同一个 key 出现多次时
  /// 以**第一条带 ext 的**为准 —— 线上 `剧圈99` 带 ext，`半日99` 是另一个
  /// 站点，不能混。
  static List<FxJarSourceDef> parseSitesJson(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return const <FxJarSourceDef>[];
    }
    final sites = _sitesOf(decoded);
    if (sites.isEmpty) return const <FxJarSourceDef>[];

    final out = <FxJarSourceDef>[];
    final seen = <String>{};
    for (final site in sites) {
      final api = _text(site['api']);
      if (!api.startsWith('csp_')) continue;
      final name = _text(site['name']);
      final key = _text(site['key']);
      final label = _labelOf(name).isNotEmpty ? _labelOf(name) : _labelOf(key);
      if (label.isEmpty || !seen.add(label)) continue;
      final ext = encodeExt(site['ext']);
      // 白名单里的源都是「类名 + 可选 ext」：没有 ext 的（咕噜）也要收，
      // 否则接口一旦调整顺序就会把咕噜整条漏掉。
      out.add(FxJarSourceDef(key: label, name: name.isEmpty ? label : name, api: api, ext: ext));
    }
    // 顺序按白名单排，详情页大类顺序才不会随接口变化。
    out.sort((a, b) {
      final ia = kEnabledJarSources.indexOf(a.key);
      final ib = kEnabledJarSources.indexOf(b.key);
      return (ia < 0 ? 99 : ia).compareTo(ib < 0 ? 99 : ib);
    });
    return out;
  }

  static String _labelOf(String raw) => fxJarLabelOf(raw);

  /// `ext` 在 TVBox 里可以是对象 / 字符串 / 缺失；交给 jar 的一律是 **JSON 串**。
  static String encodeExt(Object? ext) {
    if (ext == null) return '';
    if (ext is String) return ext.trim();
    if (ext is Map || ext is List) {
      try {
        return jsonEncode(ext);
      } catch (_) {
        return '';
      }
    }
    return '$ext';
  }

  static List<Map<String, Object?>> _sitesOf(Object? decoded) {
    Object? raw;
    if (decoded is Map) {
      raw = decoded['sites'];
    } else if (decoded is List) {
      raw = decoded;
    }
    if (raw is! List) return const <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      for (final item in raw)
        if (item is Map) Map<String, Object?>.from(item),
    ];
  }

  static String _text(Object? v) {
    if (v == null) return '';
    if (v is String) return v.trim();
    return '$v'.trim();
  }
}

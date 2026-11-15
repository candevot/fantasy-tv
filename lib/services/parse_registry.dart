/// 解析器注册表与寻址（PROTOCOL_FACE 2026-11-15，移植阶段 1）。
///
/// 壳（FongMi / OK影视）的「解析」是一张**注册表 + 寻址协议**：
///
/// ```text
/// 播放地址本身                     → 用哪个解析器
/// ─────────────────────────────────────────────────────────────
/// json:https://jx.x/?url=          → 现造一个 type 1（Json）解析器
/// parse:虾米                       → 按名字在 parses 里查
/// 站点级 playUrl = parse:虾米       → 站点统一交给某个解析器（优先于上面两条）
/// 以上都不命中                      → 用默认解析器（parses[0]）
/// ```
/// 依据：`player/ParseJob.java:60-67`（`setParse()`）、
/// `model/SiteViewModel.java:203-205`（站点级 `playUrl`）、
/// `api/config/VodConfig.java:200-203`（`initParse`）。
///
/// 我们这边原来**没有注册表**：外部 CMS 的解析线路在 `cms_client.dart:337`
/// 一条 `throw` 打死（「这条线路需要解析，请换本站采集库线路播放」），
/// 而 `parses` 字段在配置里被整个丢掉 —— 于是壳里能用的一整类源，
/// 在我们这儿「看起来能填、实际走错分支」。
///
/// 本文件只做**寻址与分派**（纯逻辑，不联网），真正的请求在
/// `cms_client.dart` 的发起点里按 [ParseRoute.kind] 执行。
library;

import 'tvbox_config.dart';

/// 一条解析线路的执行形态。
enum FxParseKind {
  /// 直链：不需要任何解析器（`direct`）。
  direct,

  /// `parse.url + 播放地址` → 返回 JSON 的 `url` 字段（壳 type 1「Json」）。
  json,

  /// 拿到网页后从 HTML 里抠视频地址（壳 type 0「嗅探」的 HTTP 版；
  /// WebView 版属于后续阶段）。
  sniff,

  /// Json 扩展 / Json 聚合 / 超级解析（壳 type 2/3/4）：依赖壳自己的 loader，
  /// 本阶段只登记、不执行 —— 输出可读的「暂不支持」而不是假装失败。
  unsupported,
}

/// 一次寻址的结果：交给谁、怎么执行。
class ParseRoute {
  const ParseRoute({
    required this.kind,
    this.name = '',
    this.url = '',
    this.header = const <String, String>{},
    this.playUrl = '',
    this.click = '',
    this.type = 0,
  });

  /// 不需要解析（地址本身就是直链）。
  static const ParseRoute direct = ParseRoute(kind: FxParseKind.direct);

  final FxParseKind kind;

  /// 命中的解析器名字（日志 / 报错文案要有它，否则用户不知道换哪个）。
  final String name;

  /// 解析器地址（`json` / `sniff` 的执行模板：后面直接拼播放地址）。
  final String url;

  final Map<String, String> header;

  /// 站点级 `playUrl` 原文（命中的就是它时留着排查）。
  final String playUrl;

  final String click;

  /// 壳的 `Parse.type`（0..4），日志用。
  final int type;

  bool get needsParse => kind != FxParseKind.direct;

  /// 能不能真正跑通（不给用户「点了没反应」的错觉）。
  bool get runnable =>
      kind == FxParseKind.json || kind == FxParseKind.sniff ||
      kind == FxParseKind.direct;

  /// 拼出实际请求地址：`parse.url + 播放地址`（壳 `jsonParse` 的写法）。
  String requestUrlFor(String address) {
    final base = url.trim();
    final target = address.trim();
    if (base.isEmpty) return target;
    // 模板里已经带 `%s` / `{url}` 的，按占位符替换（少数配置这么写）。
    if (base.contains('%s')) return base.replaceFirst('%s', target);
    if (base.contains('{url}')) return base.replaceAll('{url}', target);
    return '$base$target';
  }
}

/// 解析器注册表：`parses` 的一份运行时视图。
class ParseRegistry {
  ParseRegistry([List<FxParse> parses = const <FxParse>[]])
      : parses = List<FxParse>.unmodifiable(parses);

  /// 空注册表：所有寻址都退化成「直链 / 不支持」，与改造前行为一致。
  static final ParseRegistry empty = ParseRegistry();

  final List<FxParse> parses;

  bool get isEmpty => parses.isEmpty;

  /// 按名字取解析器（壳 `VodConfig.getParse(name)`）。
  FxParse? byName(String name) {
    final want = name.trim();
    if (want.isEmpty) return null;
    for (final item in parses) {
      if (item.name == want) return item;
    }
    // 名字可能带「 • 」这类后缀（配置里站点名常这么写），再宽松找一轮。
    for (final item in parses) {
      if (item.name.toLowerCase() == want.toLowerCase()) return item;
    }
    return null;
  }

  /// 某一类型下的全部解析器（壳 `getParses(type)`）。
  List<FxParse> ofType(int type) =>
      <FxParse>[for (final item in parses) if (item.type == type) item];

  /// 某一类型 + 线路名过滤（壳 `getParses(type, flag)`：`ext.flag` 为空表示都能）。
  List<FxParse> ofTypeFor(int type, String flag) {
    final all = ofType(type);
    if (flag.trim().isEmpty) return all;
    final hit = <FxParse>[for (final item in all) if (item.serves(flag)) item];
    return hit.isEmpty ? all : hit;
  }

  /// 默认解析器（壳取 `parses[0]`；注入了「超级解析」时壳会把它排在最前，
  /// 我们不注入 —— 没有 type 4 的执行能力，排在前面只会每单都失败）。
  FxParse? get defaultParse {
    if (parses.isEmpty) return null;
    for (final item in parses) {
      if (item.type == 0 || item.type == 1) return item;
    }
    return parses.first;
  }

  /// 寻址：一段播放地址 / 站点配置 → 用哪个解析器。
  ///
  /// 判定顺序（与壳一致，只多一条「站点级优先」）：
  ///   1. `站点 playUrl` 非空 → 按它寻址（`parse:名字` / `json:地址` / 裸地址）；
  ///   2. 地址本身 `json:` 前缀 → 现造 Json 解析器（壳 `Parse.get(1, …)`）；
  ///   3. 地址本身 `parse:` 前缀 → 按名字查注册表（壳 `getParse(name)`）；
  ///   4. 其余 → 默认解析器；注册表空则返回 [ParseRoute.direct]。
  ///
  /// [isDirect] 由调用方给（它知道 `rules` 嗅探规则），本函数不重复判定。
  ParseRoute route(
    String address, {
    String sitePlayUrl = '',
    Map<String, String> header = const <String, String>{},
    String click = '',
    bool Function(String address)? isDirect,
  }) {
    final target = address.trim();
    final direct = isDirect?.call(target) ?? _looksDirect(target);
    if (direct) return ParseRoute.direct;

    final explicit = _routeOf(sitePlayUrl, isSiteConfig: true);
    if (explicit != null) {
      return ParseRoute(
        kind: explicit.kind,
        name: explicit.name,
        url: explicit.url,
        header: header.isEmpty ? explicit.header : header,
        playUrl: sitePlayUrl.trim(),
        click: click.isEmpty ? explicit.click : click,
        type: explicit.type,
      );
    }

    final fromAddress = _routeOf(target);
    if (fromAddress != null) {
      return ParseRoute(
        kind: fromAddress.kind,
        name: fromAddress.name,
        url: fromAddress.url,
        header: header.isEmpty ? fromAddress.header : header,
        click: click.isEmpty ? fromAddress.click : click,
        type: fromAddress.type,
      );
    }

    final fallback = defaultParse;
    if (fallback == null) {
      return ParseRoute(
        kind: FxParseKind.unsupported,
        header: header,
        click: click,
        playUrl: sitePlayUrl.trim(),
      );
    }
    return ParseRoute(
      kind: _kindOfType(fallback.type),
      name: fallback.name,
      url: fallback.url,
      header: header.isEmpty ? fallback.header : header,
      click: click.isEmpty ? fallback.click : click,
      playUrl: sitePlayUrl.trim(),
      type: fallback.type,
    );
  }

  /// `json:<地址>` / `parse:<名字>` / 裸地址 → 路由（不命中返回 null）。
  ///
  /// [isSiteConfig] 只对「站点级 playUrl」为真：那里的裸 http(s) 地址表示
  /// 「站点统一交给这个解析接口」，而**播放地址本身**是裸 http(s) 时只是普通
  /// 网页 / 令牌，不能当成解析接口 —— 这个区别混淆过一次，会把所有网页地址
  /// 都送进 Json 解析器。
  ParseRoute? _routeOf(String raw, {bool isSiteConfig = false}) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    if (text.startsWith('json:')) {
      final url = text.substring(5).trim();
      if (url.isEmpty) return null;
      // 壳这里是 `Parse.get(1, url)`：现造一个 Json 解析器，不查注册表。
      return ParseRoute(
        kind: FxParseKind.json,
        name: 'json',
        url: url,
        type: 1,
      );
    }
    if (text.startsWith('parse:')) {
      final name = text.substring(6).trim();
      final hit = byName(name);
      if (hit != null) {
        return ParseRoute(
          kind: _kindOfType(hit.type),
          name: hit.name,
          url: hit.url,
          header: hit.header,
          click: hit.click,
          type: hit.type,
        );
      }
      // 名字没登记：仍然按「默认解析器」执行，但把名字带出去（日志能看出
      // 是配置写错了名字，而不是解析器坏了）。
      final fallback = defaultParse;
      return ParseRoute(
        kind: fallback == null
            ? FxParseKind.unsupported
            : _kindOfType(fallback.type),
        name: name,
        url: fallback?.url ?? '',
        header: fallback?.header ?? const <String, String>{},
        type: fallback?.type ?? 0,
      );
    }
    if (isSiteConfig &&
        (text.startsWith('http://') || text.startsWith('https://'))) {
      // 站点级 `playUrl` 直接给地址：等价 `json:` 之外的一种「模板地址」。
      return ParseRoute(kind: FxParseKind.json, name: 'playUrl', url: text, type: 1);
    }
    return null;
  }

  static FxParseKind _kindOfType(int type) {
    switch (type) {
      case 0:
        return FxParseKind.sniff;
      case 1:
        return FxParseKind.json;
      default:
        return FxParseKind.unsupported;
    }
  }

  /// 没有外部判定时用的兜底：像媒体直链就算直链。
  static bool _looksDirect(String address) {
    final text = address.trim().toLowerCase();
    if (text.isEmpty) return false;
    if (!text.startsWith('http://') && !text.startsWith('https://')) return false;
    return RegExp(r'\.(m3u8|mp4|mkv|flv|mov|ts)(\?|#|$)').hasMatch(text);
  }

  /// 从 `TvBoxConfig` 建注册表。
  factory ParseRegistry.of(TvBoxConfig config) => ParseRegistry(config.parses);

  /* ---------------------------------------------------------- 全局实例 */

  static ParseRegistry _active = ParseRegistry.empty;

  /// 当前生效的注册表（配置刷新时由 [install] 换掉）。
  ///
  /// 为什么用全局而不是注入：寻址在四条互不相识的链路上被问到
  /// （详情页 / 播放页 / 下载 / 一起看），逐个注入要改十几个调用点；
  /// 而「注册表」本来就是**整个 App 一份**的配置，与壳的 `VodConfig.get()`
  /// 同一语义。读的地方全是同步的，不涉及 IO。
  static ParseRegistry get active => _active;

  /// 装一份注册表（配置解析完调一次）。
  static void install(ParseRegistry registry) {
    _active = registry;
  }

  /// 单测用：恢复空表。
  static void resetForTest() {
    _active = ParseRegistry.empty;
  }
}

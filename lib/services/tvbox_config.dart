/// TVBox 配置协议的**纯解析层**（PROTOCOL_FACE 2026-11-15，移植阶段 1）。
///
/// 为什么单独一个文件：壳（FongMi 5.16 / OK影视）的配置是 TVBox 的**全量协议**
/// —— `sites` / `parses` / `flags` / `ads` / `hosts` / `rules` / `doh` /
/// `spider` / `lives` / `depot`。我们这边原来只认 `cloud_sources` +
/// `live_url` + `sites` 的 7 个字段（`source_hub.dart`），其余全部丢弃，
/// 于是「依赖这些字段的源在我们这儿看起来能填、实际走错分支」：
///   · 带 `parse:` / `json:` 的线路一律报「需要网页解析」；
///   · 单源 `timeout` 被全局 12 秒覆盖，慢源被误杀；
///   · 站点级 `header` 丢掉 → 要 Referer / Cookie 的源直接 403；
///   · `rules` 丢掉 → 「直链还是解析」只能靠后缀猜；
///   · `hosts` / `doh` 丢掉 → DNS 只能听运营商的。
///
/// 这个文件只做「JSON 对象 → 强类型模型」，**不联网、不 import flutter**，
/// 所以：
///   · `tools/probe_tvbox_config.dart` 可以用 `dart run` 直接拿真实配置跑
///     （`http://125.94.244.87/hx_all.json` 的统计就是它出的）；
///   · `test/tvbox_config_test.dart` 能覆盖「缺字段兜底」这种最容易写错的地方；
///   · `source_hub.dart` 只负责把模型搬进 `KSource`，解析规则不再散落在 UI 层。
///
/// 依据（只取**字段名与默认值**，代码全部自写）：
/// `fm-516/.../api/config/VodConfig.java:139-290`（depot / initList / initSite /
/// initParse）、`bean/Site.java:44-107`（12 个字段与默认值）、
/// `bean/Parse.java:28-37,153-186`、`bean/Rule.java:14-27`、`bean/Doh.java`、
/// `catvod/.../net/OkDns.java:41-43`（`host=ip` 格式）。
library;

import 'dart:convert';

/* ------------------------------------------------------------ 站点 */

/// 站点级请求画像：壳 `Site` 里那 12 个字段（`Site.java:44-107`）。
///
/// 默认值与壳逐条对齐：`type` 0、`timeout` 缺省走全局（壳是 TIMEOUT_PLAY 15s）、
/// `searchable` / `changeable` / `quickSearch` 缺省都是 1、`categories` 空表
/// 表示「不限分类」、`header` 空表表示不额外加头。
class FxSite {
  const FxSite({
    required this.key,
    required this.name,
    required this.api,
    this.type = 0,
    this.ext = '',
    this.jar = '',
    this.click = '',
    this.playUrl = '',
    this.timeout = 0,
    this.header = const <String, String>{},
    this.categories = const <String>[],
    this.searchable = 1,
    this.changeable = 1,
    this.quickSearch = 1,
    this.style = '',
    this.extras = const <String, Object?>{},
  });

  /// 站点 identity（id 路由 / 冷却 / 失败记账都用它）。
  final String key;

  final String name;

  /// `type: 1` 的 CMS 地址；`type: 3` 的类名（`csp_Xxx`）。
  final String api;

  /// TVBox 的 `type`：0 直接地址 / 1 CMS / 3 jar / 4 python。
  final int type;

  /// 站点级 ext（交给 jar 源 / 作为 `extend` 参数发给 CMS）。
  final String ext;

  /// 站点级 jar：空表示用全局 `spider`（壳 `Site.objectFrom` 的语义）。
  final String jar;

  /// 解析时注入的点击脚本（壳 `ParseJob.getClick()` 用它）。
  final String click;

  /// 站点级「解析头」：`parse:<名字>` 或 `json:<地址>`（壳
  /// `SiteViewModel.playerContent` 里 `result.setPlayUrl(site.getPlayUrl())`）。
  final String playUrl;

  /// 单源超时（秒）；0 = 没配，用全局默认。
  final int timeout;

  /// 站点级请求头（Referer / Cookie / UA 三件套最常见）。
  final Map<String, String> header;

  /// 分类白名单（空 = 不限）。
  final List<String> categories;

  /// 1 可搜 / 0 不可搜（壳还会用 2 表示「用户手动关掉」）。
  final int searchable;

  /// 1 可换源 / 0 不可（播放页换源白名单）。
  final int changeable;

  /// 1 允许快搜 / 0 不允许（`SearchTask` 里 `quick && !isQuickSearch()` → 空）。
  final int quickSearch;

  /// 卡片样式（壳 `Style.java`）；纯 UI，本阶段只保留原样。
  final String style;

  /// 配置里出现但本阶段不消费的键（`hide` / `indexs` / `playerType` 等），
  /// 原样留着，免得下游想用时又要回去翻原始 JSON。
  final Map<String, Object?> extras;

  bool get searchableEnabled => searchable != 0;

  bool get changeableEnabled => changeable != 0;

  bool get quickSearchEnabled => quickSearch != 0;

  /// 单源超时：配了就用配置的（至少 1 秒），没配返回 null 交给全局默认。
  Duration? get timeoutOrNull =>
      timeout <= 0 ? null : Duration(seconds: timeout < 1 ? 1 : timeout);

  /// `playerType`（壳 `Site.playerType`，每源播放内核）：我们单内核，
  /// 只保留数值供 UI 标注，不参与播放决策。
  int get playerType => _extraInt('playerType');

  int get hide => _extraInt('hide');

  int get indexs => _extraInt('indexs');

  int _extraInt(String key) {
    final raw = extras[key];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse('${raw ?? ''}'.trim()) ?? 0;
  }

  /// 从 `sites` 的一项解析；`key` / `api` 都空时返回 null。
  static FxSite? from(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, Object?>.from(raw);
    final api = _text(m['api']);
    // key 缺省用 name 兜（TVBox 里两者常常只写一个）。
    final key = _text(m['key']).isEmpty ? _text(m['name']) : _text(m['key']);
    if (api.isEmpty || key.isEmpty) return null;
    final name = _text(m['name']).isEmpty ? key : _text(m['name']);
    return FxSite(
      key: key,
      name: name,
      api: api,
      type: _int(m['type']),
      ext: _textOfExt(m['ext']),
      jar: _text(m['jar']),
      click: _text(m['click']),
      playUrl: _text(m['playUrl']),
      timeout: _int(m['timeout']),
      header: fxHeaderOf(m['header']),
      categories: fxStringList(m['categories']),
      searchable: _flag(m['searchable'], 1),
      changeable: _flag(m['changeable'], 1),
      quickSearch: _flag(m['quickSearch'], 1),
      style: _textOfExt(m['style']),
      extras: m,
    );
  }
}

/* ------------------------------------------------------------ 解析器 */

/// 一条解析器注册项（壳 `Parse`：`name` / `type` / `url` / `ext`）。
///
/// `type` 的语义（`ParseJob.doInBackground` 的 switch）：
///   · 0 嗅探（WebView / HTTP 页面里找视频地址）
///   · 1 Json（`url + 播放地址` 返回 `{url: "…"}`）
///   · 2 Json 扩展 / 3 Json 聚合 / 4 超级解析（依赖壳自身的 loader，本阶段不跑）
class FxParse {
  const FxParse({
    required this.name,
    required this.type,
    required this.url,
    this.header = const <String, String>{},
    this.flag = const <String>[],
    this.click = '',
  });

  final String name;
  final int type;
  final String url;
  final Map<String, String> header;

  /// `ext.flag`：这条解析器只服务哪些线路名（空 = 不限）。
  final List<String> flag;

  final String click;

  /// 名字 + 类型 + 地址都能空到这个程度：视为无效项。
  bool get isEmpty => name.isEmpty && url.isEmpty;

  static FxParse? from(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, Object?>.from(raw);
    final name = _text(m['name']);
    final url = _text(m['url']);
    if (name.isEmpty && url.isEmpty) return null;
    final ext = m['ext'];
    Map<String, String> header = const <String, String>{};
    List<String> flag = const <String>[];
    if (ext is Map) {
      header = fxHeaderOf(ext['header']);
      flag = fxStringList(ext['flag']);
    } else if (ext is String && ext.trim().isNotEmpty) {
      // 少数配置把 ext 写成 JSON 字符串，能解就解，解不开就当没写。
      try {
        final decoded = jsonDecode(ext);
        if (decoded is Map) {
          header = fxHeaderOf(decoded['header']);
          flag = fxStringList(decoded['flag']);
        }
      } catch (_) {
        // 忽略：ext 不是 JSON 就当空。
      }
    }
    return FxParse(
      name: name,
      type: _int(m['type']),
      url: url,
      header: header,
      flag: flag,
      click: _text(m['click']),
    );
  }

  /// 落盘用（协议面要能跨启动保留，配置拉不到时按上一份解析）。
  Map<String, Object?> toMap() => <String, Object?>{
        'name': name,
        'type': type,
        'url': url,
        if (click.isNotEmpty) 'click': click,
        if (header.isNotEmpty || flag.isNotEmpty)
          'ext': <String, Object?>{
            if (flag.isNotEmpty) 'flag': flag,
            if (header.isNotEmpty) 'header': header,
          },
      };

  /// 这条解析器能不能服务 `flag`（线路名）。
  ///
  /// 口径照壳（`VodConfig.getParses(type, flag)`）：`ext.flag` **必须显式
  /// 包含**这个线路名才算命中 —— 空 `flag` 的解析器不算「服务所有线路」。
  /// 「一条都没命中时退回全部」这一层由调用方（`ParseRegistry.ofTypeFor`）做，
  /// 因为那是「候选为空」的兜底，不是单条解析器的语义。
  bool serves(String flagName) {
    final want = flagName.trim();
    if (want.isEmpty) return false;
    for (final item in flag) {
      if (item.trim() == want) return true;
    }
    return false;
  }
}

/* ------------------------------------------------------------ DNS */

/// DoH 候选（壳 `Doh`：`name` / `url` / `ips`）。
class FxDoh {
  const FxDoh({required this.name, required this.url, this.ips = const <String>[]});

  final String name;
  final String url;

  /// 引导用的 IP（DoH 域名本身也要解析，壳用 `bootstrapDnsHosts`）。
  final List<String> ips;

  Map<String, Object?> toMap() => <String, Object?>{
        if (name.isNotEmpty) 'name': name,
        'url': url,
        if (ips.isNotEmpty) 'ips': ips,
      };

  static FxDoh? from(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, Object?>.from(raw);
    final url = _text(m['url']);
    if (url.isEmpty) return null;
    return FxDoh(
      name: _text(m['name']),
      url: url,
      ips: fxStringList(m['ips']),
    );
  }
}

/* ------------------------------------------------------------ 广告域名 */

/// 配置里的 `ads`（广告域名）的运行时视图。
///
/// 壳用它过滤**解析结果**里来自广告域的候选（`VodConfig.get().getAds()`）。
/// 我们不做广告拦截那一套（HLS 代理层已经删了 ad 标签），只做一件最便宜的
/// 事：解析器给出多个候选地址时，跳过落在 `ads` 域名里的那个 —— 少了它就会
/// 「解析出来的地址一播就是广告片」，用户以为我们播错了集。
class FxAds {
  FxAds([List<String> ads = const <String>[]])
      : ads = List<String>.unmodifiable(<String>[
          for (final item in ads)
            if (item.trim().isNotEmpty) item.trim().toLowerCase(),
        ]);

  static final FxAds none = FxAds();

  final List<String> ads;

  static FxAds _active = FxAds.none;

  /// 当前生效的广告域名表。
  static FxAds get active => _active;

  /// 装一份（配置解析完调一次）。
  static void install(FxAds ads) {
    _active = ads;
  }

  static void resetForTest() {
    _active = FxAds.none;
  }

  bool get isEmpty => ads.isEmpty;

  /// 这条地址是不是落在广告域名上。
  bool matches(String url) {
    if (ads.isEmpty) return false;
    final text = url.trim().toLowerCase();
    if (text.isEmpty) return false;
    final host = Uri.tryParse(text)?.host.toLowerCase() ?? text;
    for (final ad in ads) {
      if (ad.isEmpty) continue;
      if (host == ad || host.endsWith('.$ad') || host.contains(ad)) return true;
    }
    return false;
  }
}

/* ------------------------------------------------------------ 整份配置 */

/// 一份 TVBox 配置（合并 depot 之后的结果）。
///
/// 除了 `sites`，其余字段都是「协议面」，本阶段全都解析出来并且**有落点**：
///   · [parses] → `ParseRegistry`（`json:` / `parse:` 寻址）；
///   · [rules]  → `FxSniffer`（直链还是解析）；
///   · [hosts] / [doh] → `FxDns`（钉 IP / 换 DoH 端点）；
///   · [flags] / [ads] → 透传给 jar 源 / 解析结果过滤；
///   · [spider] → 全局 jar（站点级 `jar` 为空时用它）。
class TvBoxConfig {
  const TvBoxConfig({
    this.sites = const <FxSite>[],
    this.parses = const <FxParse>[],
    this.flags = const <String>[],
    this.ads = const <String>[],
    this.hosts = const <String>[],
    this.rules = const <Map<String, Object?>>[],
    this.doh = const <FxDoh>[],
    this.spider = '',
    this.liveUrl = '',
    this.logo = '',
    this.depotUrls = const <String>[],
    this.siteCount = 0,
    this.skippedSites = 0,
  });

  final List<FxSite> sites;

  final List<FxParse> parses;

  /// 全局线路名表（`flags`），透传给 jar 源的 `playerContent`。
  final List<String> flags;

  /// 广告域名（解析结果的域名过滤）。
  final List<String> ads;

  /// `host=ip` 形式的 DNS 钉 IP 表（壳 `OkDns.addAll` 的入参格式）。
  final List<String> hosts;

  /// 嗅探规则原始表（`FxSniffer` 消费，这里保留原始形状便于透传 / 落盘）。
  final List<Map<String, Object?>> rules;

  final List<FxDoh> doh;

  /// 全局 jar 地址。
  final String spider;

  /// 直播源地址（`lives[0]` 或 `live_url`）。
  final String liveUrl;

  final String logo;

  /// depot：`{urls:[…]}` 形态的「配置合集」，合并后这里保留原表供排查。
  final List<String> depotUrls;

  /// `sites` 原表条数（含被跳过的），用于「识别到多少 sites」的统计。
  final int siteCount;

  /// 被跳过的条数（没有 api 之类）。
  final int skippedSites;

  bool get isEmpty =>
      sites.isEmpty &&
      parses.isEmpty &&
      flags.isEmpty &&
      ads.isEmpty &&
      hosts.isEmpty &&
      rules.isEmpty &&
      doh.isEmpty &&
      spider.isEmpty &&
      liveUrl.isEmpty;

  /// 带 timeout 的站点条数（验证脚本要报这个数）。
  int get sitesWithTimeout =>
      sites.where((s) => s.timeout > 0).length;

  /// 带站点级 header 的条数。
  int get sitesWithHeader =>
      sites.where((s) => s.header.isNotEmpty).length;

  /// 有没有真正的「协议面」内容（parses / flags / ads / hosts / rules / doh /
  /// spider 至少一样非空）。
  ///
  /// 用来区分「TVBox 配置」和「我们后台那份 `/api/config`」：后者只有
  /// `cloud_sources` + `live_url`，如果拿它去覆盖协议面，导入过的解析器注册表
  /// 会被清空 —— 而这种退化不会报错，只会让带 `parse:` 的线路又变回「需要
  /// 网页解析」。
  bool get hasProtocolSections =>
      parses.isNotEmpty ||
      flags.isNotEmpty ||
      ads.isNotEmpty ||
      hosts.isNotEmpty ||
      rules.isNotEmpty ||
      doh.isNotEmpty ||
      spider.isNotEmpty;

  /// 是 TVBox 协议配置（而不是我们后台的 `/api/config`）。
  bool get looksLikeTvBox =>
      sites.isNotEmpty ||
      parses.isNotEmpty ||
      rules.isNotEmpty ||
      hosts.isNotEmpty ||
      spider.isNotEmpty;

  /// `host=ip` → `{host: ip}`（解析失败的条目直接丢）。
  Map<String, String> get hostsMap {
    final out = <String, String>{};
    for (final line in hosts) {
      final at = line.indexOf('=');
      if (at <= 0) continue;
      final host = line.substring(0, at).trim();
      final ip = line.substring(at + 1).trim();
      if (host.isEmpty || ip.isEmpty) continue;
      out[host] = ip;
    }
    return out;
  }

  /// 第一个可用的 DoH 地址（壳按用户在设置里选的，我们没这个设置项，
  /// 取配置里的第一个）。
  String get dohUrl {
    for (final item in doh) {
      if (item.url.isNotEmpty) return item.url;
    }
    return '';
  }

  /// 解析一份配置（裸对象 / `{data:{…}}` / `{urls:[…]}` depot 都认）。
  ///
  /// [baseUrl] 用来把 `urls` 里的相对地址补全（depot 里常见 `./a.json`）。
  static TvBoxConfig parse(Object? body, {String baseUrl = ''}) {
    final map = _mapOf(body);
    if (map == null) return const TvBoxConfig();
    return fromMap(map, baseUrl: baseUrl);
  }

  static TvBoxConfig fromMap(
    Map<String, Object?> map, {
    String baseUrl = '',
  }) {
    final sites = <FxSite>[];
    var rawCount = 0;
    var skipped = 0;
    for (final item in fxListOf(map, 'sites', 'api_site', 'list')) {
      rawCount++;
      final site = FxSite.from(item);
      if (site == null) {
        skipped++;
        continue;
      }
      sites.add(site);
    }
    final parses = <FxParse>[
      for (final item in fxListOf(map, 'parses'))
        if (FxParse.from(item) case final parse?) parse,
    ];
    final doh = <FxDoh>[
      for (final item in fxListOf(map, 'doh'))
        if (FxDoh.from(item) case final item?) item,
    ];
    final rules = <Map<String, Object?>>[
      for (final item in fxListOf(map, 'rules'))
        if (item is Map) Map<String, Object?>.from(item),
    ];
    final spider = _text(map['spider']);
    return TvBoxConfig(
      sites: sites,
      parses: parses,
      flags: fxStringList(map['flags']),
      ads: fxStringList(map['ads']),
      hosts: fxStringList(map['hosts']),
      rules: rules,
      doh: doh,
      spider: spider,
      liveUrl: _liveUrlOf(map),
      logo: _text(map['logo']),
      depotUrls: depotUrlsOf(map),
      siteCount: rawCount,
      skippedSites: skipped,
    );
  }

  /// depot 形态：`{urls:[…]}`（壳 `parseDepot`，`VodConfig.java:139-145`）。
  static List<String> depotUrlsOf(Object? body) {
    final map = _mapOf(body);
    if (map == null) return const <String>[];
    final raw = map['urls'];
    final out = <String>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is String) {
          final text = item.trim();
          if (text.isNotEmpty) out.add(text);
          continue;
        }
        if (item is Map) {
          // `{url: …, name: …}` 形态。
          final url = _text(item['url']);
          if (url.isNotEmpty) out.add(url);
        }
      }
    }
    return out;
  }

  /// 把 depot 里的多份配置合并成一份（**后面的补前面的**）。
  ///
  /// 合并口径：
  ///   · `sites` 按 `key` 去重，先出现的赢（配置里的顺序就是站点顺序）；
  ///   · `parses` 按「名字 + type」去重；
  ///   · `flags` / `ads` / `hosts` 取并集，保持出现顺序；
  ///   · `rules` / `doh` 取并集（`rules` 按 name 去重，`doh` 按 url 去重）；
  ///   · `spider` / `liveUrl` / `logo` 取第一个非空。
  TvBoxConfig merge(TvBoxConfig other) {
    final keyed = <String, FxSite>{};
    final ordered = <FxSite>[];
    for (final site in <FxSite>[...sites, ...other.sites]) {
      if (keyed.containsKey(site.key)) continue;
      keyed[site.key] = site;
      ordered.add(site);
    }
    final parseSeen = <String>{};
    final mergedParses = <FxParse>[];
    for (final parse in <FxParse>[...parses, ...other.parses]) {
      if (!parseSeen.add('${parse.name}|${parse.type}')) continue;
      mergedParses.add(parse);
    }
    final ruleSeen = <String>{};
    final mergedRules = <Map<String, Object?>>[];
    for (final rule in <Map<String, Object?>>[...rules, ...other.rules]) {
      final name = _text(rule['name']);
      if (name.isNotEmpty && !ruleSeen.add(name)) continue;
      mergedRules.add(rule);
    }
    final dohSeen = <String>{};
    final mergedDoh = <FxDoh>[];
    for (final item in <FxDoh>[...doh, ...other.doh]) {
      if (!dohSeen.add(item.url)) continue;
      mergedDoh.add(item);
    }
    return TvBoxConfig(
      sites: ordered,
      parses: mergedParses,
      flags: _union(flags, other.flags),
      ads: _union(ads, other.ads),
      hosts: _union(hosts, other.hosts),
      rules: mergedRules,
      doh: mergedDoh,
      spider: spider.isNotEmpty ? spider : other.spider,
      liveUrl: liveUrl.isNotEmpty ? liveUrl : other.liveUrl,
      logo: logo.isNotEmpty ? logo : other.logo,
      depotUrls: _union(depotUrls, other.depotUrls),
      siteCount: siteCount + other.siteCount,
      skippedSites: skippedSites + other.skippedSites,
    );
  }

  /// 协议面的落盘形态（**不含 sites** —— 站点单独存，重复存两份会让
  /// 「删过的站点」在恢复时又冒出来）。
  Map<String, Object?> protocolToMap() => <String, Object?>{
        'parses': <Object?>[for (final p in parses) p.toMap()],
        'flags': flags,
        'ads': ads,
        'hosts': hosts,
        'rules': rules,
        'doh': <Object?>[for (final d in doh) d.toMap()],
        if (spider.isNotEmpty) 'spider': spider,
        if (liveUrl.isNotEmpty) 'live_url': liveUrl,
        if (logo.isNotEmpty) 'logo': logo,
      };

  /// 从 [protocolToMap] 的形态还原（落盘读回用）。
  static TvBoxConfig fromProtocolMap(Object? raw) {
    final map = _mapOf(raw);
    if (map == null) return const TvBoxConfig();
    return fromMap(map);
  }

  /// 一份给人看的摘要（日志 / 验证脚本共用）。
  String summary() => 'sites=${sites.length}/$siteCount'
      ' parses=${parses.length}'
      ' flags=${flags.length}'
      ' ads=${ads.length}'
      ' hosts=${hosts.length}'
      ' rules=${rules.length}'
      ' doh=${doh.length}'
      ' timeout=${sitesWithTimeout}'
      ' header=${sitesWithHeader}'
      ' spider=${spider.isEmpty ? '无' : '有'}';
}

/* ------------------------------------------------------------ 工具 */

Map<String, Object?>? _mapOf(Object? body) {
  if (body is Map) return Map<String, Object?>.from(body);
  return null;
}

List<Object?> fxListOf(Map<String, Object?> map, String key1,
    [String? key2, String? key3]) {
  for (final key in <String?>[key1, key2, key3]) {
    if (key == null) continue;
    final raw = map[key];
    if (raw is List) return raw;
    if (raw is Map) {
      // `{key: {…}}` 形态（TVBox 的 `api_site`）：把 key 补进每一项。
      return <Object?>[
        for (final entry in raw.entries)
          if (entry.value is Map)
            <String, Object?>{
              'key': '${entry.key}',
              ...Map<String, Object?>.from(entry.value as Map),
            },
      ];
    }
  }
  return const <Object?>[];
}

String _liveUrlOf(Map<String, Object?> map) {
  final direct = _text(map['live_url']);
  if (direct.isNotEmpty) return direct;
  for (final item in fxListOf(map, 'lives')) {
    if (item is Map) {
      final url = _text(item['url']);
      if (url.isNotEmpty) return url;
    } else if (item is String && item.trim().isNotEmpty) {
      return item.trim();
    }
  }
  return '';
}

String _text(Object? raw) {
  if (raw == null) return '';
  if (raw is String) return raw.trim();
  return '$raw'.trim();
}

int _int(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(_text(raw)) ?? 0;
}

/// 壳的「三态开关」：缺省给 [fallback]，`"false"` / `"0"` 也算关。
int _flag(Object? raw, int fallback) {
  if (raw == null) return fallback;
  if (raw is bool) return raw ? 1 : 0;
  final text = _text(raw).toLowerCase();
  if (text.isEmpty) return fallback;
  if (text == 'false' || text == 'no' || text == 'off') return 0;
  if (text == 'true' || text == 'yes' || text == 'on') return 1;
  final n = int.tryParse(text);
  return n == null ? fallback : n;
}

/// `ext` / `style` 这类「可能是字符串、也可能是对象」的字段。
///
/// 直接 `toString()` 会得到 `{a: b}`（不是合法 JSON），jar 那边 `JSON.parse`
/// 一挂，这个源就永远空列表 —— 所以对象一律按 JSON 编码。
String _textOfExt(Object? raw) {
  if (raw is Map || raw is List) return jsonEncode(raw);
  return _text(raw);
}

/// 请求头：大小写不敏感地摊平成 `{k: v}`，非字符串值转字符串。
Map<String, String> fxHeaderOf(Object? raw) {
  Object? value = raw;
  if (value is String) {
    final text = value.trim();
    if (text.isEmpty) return const <String, String>{};
    try {
      value = jsonDecode(text);
    } catch (_) {
      return const <String, String>{};
    }
  }
  if (value is! Map) return const <String, String>{};
  final out = <String, String>{};
  value.forEach((k, v) {
    final key = _text(k);
    if (key.isEmpty) return;
    final text = _text(v);
    if (text.isEmpty) return;
    out[key] = text;
  });
  return out;
}

/// 字符串数组（容忍 `"a,b"` / 单个字符串 / 混着数字）。
List<String> fxStringList(Object? raw) {
  if (raw == null) return const <String>[];
  if (raw is String) {
    final text = raw.trim();
    if (text.isEmpty) return const <String>[];
    return <String>[
      for (final part in text.split(','))
        if (part.trim().isNotEmpty) part.trim(),
    ];
  }
  if (raw is List) {
    final out = <String>[];
    for (final item in raw) {
      final text = _text(item);
      if (text.isNotEmpty) out.add(text);
    }
    return out;
  }
  return const <String>[];
}

List<String> _union(List<String> a, List<String> b) {
  final out = <String>[...a];
  final seen = <String>{...a};
  for (final item in b) {
    if (seen.add(item)) out.add(item);
  }
  return out;
}

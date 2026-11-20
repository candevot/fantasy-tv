import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../models.dart';
import 'cms_api.dart';
import 'cms_client.dart';
import 'cms_request.dart';
import 'dns_profile.dart';
import 'fallback_match.dart' show fxNormTitle;
import 'jar_sources.dart';
import 'jar_log.dart';
import 'jar_spider.dart';
import 'source_log.dart';
import 'parse_registry.dart';
import 'sniff_rules.dart';
import 'source_failure.dart';
import 'tvbox_config.dart';

/// 片源的种类。
enum KSourceKind {
  /// `type: 1` —— 苹果CMS 接口（`/api.php/provide/vod/`）。
  cms,

  /// `type: 0` —— 直接给 JSON / 列表的地址（TVBox 里常说的「直接地址」）。
  direct,

  /// `type: "live"` —— 直播播放列表（M3U / TXT / JSON）。
  live,

  /// `type: 3` —— TVBox 的 jar 解析插件（`spider.jar` 里 `csp_*` 那批源）。
  ///
  /// JAR_RESTORE（2026-11-21）：只服务**搜索**和**播放解析**两处；
  /// 首页 / 分类 / 排行榜永远只用我们自己的片源。能不能用、用哪几个，
  /// 由 [SourceHub.jarSources]（白名单 + 用户开关，见 `jar_sources.dart`）决定。
  jar,

  /// `type: 4`（python 解析脚本）—— 暂不支持。
  unsupported,
}

/// 片源从哪来。
enum KSourceOrigin {
  /// 云端配置下发（后台 `/api/config`）。
  cloud,

  /// 用户自加（历史值，App 已没有添加片源的入口）。
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
    this.timeout = 0,
    this.header = const <String, String>{},
    this.playUrl = '',
    this.click = '',
    this.categories = const <String>[],
    this.jar = '',
    this.searchableFlag = 1,
    this.changeable = 1,
    this.quickSearch = 1,
    this.style = '',
    this.playerType = 0,
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

  /* ---------------------------------------------- 壳 Site 的协议字段 */

  /// 单源超时（秒，壳 `Site.timeout`）；0 = 没配，用 [SourceHub.sourceTimeout]。
  ///
  /// PROTOCOL_FACE（2026-11-15 · 第 3 条）：以前全局 12 秒一刀切，慢源在
  /// 12 秒被误杀、快源白白占着并发 —— 壳是「每个源自己报超时」（默认 15 秒）。
  final int timeout;

  /// 站点级请求头（壳 `Site.header`）：要 Referer / Cookie 的源不再 403。
  final Map<String, String> header;

  /// 站点级「解析头」（壳 `Site.playUrl`）：`parse:名字` / `json:地址`。
  final String playUrl;

  /// 站点级点击脚本（壳 `Site.click`，解析页面要按钮才出地址时用）。
  final String click;

  /// 分类白名单（壳 `Site.categories`；空 = 不限）。
  final List<String> categories;

  /// 站点级 jar（壳 `Site.jar`；空 = 用全局 `spider`）。
  final String jar;

  /// 壳 `Site.searchable`：1 可搜 / 0 不可搜。
  ///
  /// 与既有的 [searchable] getter 不同：那个还要看「地址 / 种类」能不能搜，
  /// 这里只表达配置里的开关意图（配置没写就是 1）。
  final int searchableFlag;

  /// 壳 `Site.changeable`：1 允许在播放页被换源选到。
  final int changeable;

  /// 壳 `Site.quickSearch`：1 允许快搜。
  final int quickSearch;

  /// 壳 `Site.style`（卡片样式）：纯 UI，本阶段只原样保存。
  final String style;

  /// 壳 `Site.playerType`（每源播放内核）：我们单内核，只留数值供标注。
  final int playerType;

  /// 这个源自己的超时（没配返回 null，交给全局默认）。
  Duration? get ownTimeout =>
      timeout <= 0 ? null : Duration(seconds: timeout < 1 ? 1 : timeout);

  bool get changeableEnabled => changeable != 0;

  bool get quickSearchEnabled => quickSearch != 0;

  /// 交给 [CmsClient] 的站点画像（请求头 / ext / 超时 / 解析头）。
  CmsSiteProfile get cmsProfile => CmsSiteProfile(
        key: key,
        header: header,
        ext: ext,
        timeout: ownTimeout,
        playUrl: playUrl,
        click: click,
        directKind: kind == KSourceKind.direct,
        quickSearch: quickSearch != 0,
      );

  bool get usable =>
      kind != KSourceKind.unsupported && api.trim().isNotEmpty && enabled;

  bool get isLive => kind == KSourceKind.live;

  /// 能否参与搜索 / 分类（直播源不参与内容检索）。
  ///
  /// jar 源也算：它的内容检索走 `JAR_SPIDER` 通道，和 CMS 一样能搜能分类。
  bool get searchable =>
      usable &&
      searchableFlag != 0 &&
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

  /// 片源管理页的管理口径（这份配置是云端下发的，还是自己加的）。
  ///
  /// **搜索结果卡片不要用这个** —— 那是 [resultLabel] 的活。
  String get originLabel =>
      origin == KSourceOrigin.cloud ? '云端' : '自加';

  /// 我们自己的 hx 库 api 特征（按地址判定，不看名字）。
  static const String hxApiMark = '125.94.244.87/api.php';

  /// 我们自己的源在卡片上的唯一叫法（SOURCE_LABEL，别再加别的说法）。
  static const String ownResultLabel = '幻想';

  /// 这算不算「我们自己的 hx 库」：内容和主站采集库是同一套 `vod_id`。
  bool get isOwnLibrary =>
      kind != KSourceKind.jar && api.contains(hxApiMark);

  /// 源自己的短名字：TVBox 的站点名是「名字 • 类型」
  /// （`咕噜 • APP` / `豆瓣 • 首页` / `玩偶 • 4K`），只留名字那一段，
  /// 别把「 • APP」这种后缀带进来源标注。
  ///
  /// SOURCE_SHORTNAME（2026-11-15）：线上肥猫配置的名字长这样 ——
  /// `🕊┃︎咕噜┃APP`、`🐼┃豆瓣┃预告`、`⭕┃韩圈 ┃APP`：emoji + `┃` 分段。
  /// 老实现「遇到第一个分隔符就砍」，于是**每一条的标注都只剩一个 emoji**，
  /// 日志里也变成 `source=🕊`，排查时完全看不出是哪个源。
  /// 现在按分隔符切段，**跳过纯 emoji / 空白段**，取第一个有字的段。
  String get shortName {
    final text = name.trim();
    if (text.isEmpty) return '';
    final parts = text
        .split(RegExp(r'[•·｜|┃]'))
        .map(_cleanSegment)
        .where((e) => e.isNotEmpty)
        .toList();
    for (final part in parts) {
      if (_hasWord(part)) return part;
    }
    return parts.isEmpty ? _cleanSegment(text) : parts.first;
  }

  /// 去掉段里的隐形字符（变体选择符 U+FE0E/FE0F、零宽空格、BOM…）。
  ///
  /// 线上配置里 `🕊┃︎咕噜┃APP` 的 `︎` 就是 U+FE0E：直接 trim 掉不掉，
  /// 结果标注变成「︎咕噜」，看着像名字前面多了个方框。
  static String _cleanSegment(String raw) => raw
      .replaceAll(RegExp(r'[\uFE00-\uFE0F\u200B-\u200F\u2060\uFEFF]'), '')
      .trim();

  /// 这一段里有没有「文字」（汉字 / 字母 / 数字）—— 只有 emoji 的段不算。
  static bool _hasWord(String text) =>
      RegExp(r'[\u4e00-\u9fa5A-Za-z0-9]').hasMatch(text);

  /// 卡片下方的来源标注：**只看 api 特征**，不看它是不是云端下发的。
  ///
  /// SOURCE_LABEL（2026-11-15）：同一个源以前有两种写法 —— 云端下发的源按
  /// [origin] 标「云端」，另几条线路切片按线路名标「幻想」，于是搜「济公传」
  /// 时同一部片出现「来源：云端」和「来源：幻想」两个标签，看着像两个站。
  /// 现在的规则：
  ///   · 含 [hxApiMark]（我们自己的 hx 库）→ 永远只叫「幻想」
  ///   · `csp_` 开头的肥猫 jar 源 → 用它自己的名字（咕噜 / 剧圈 / 豆瓣 …）
  ///   · 其余（用户自加的源）→ 它自己的名字
  ///   · 认不出来的（直播 / 暂不支持 / api 为空 / 没名字）→ 空串，不标
  ///
  /// 注意：「幻想4K / 幻想1080P / 幻想爱奇艺 / 量子 / 红牛 / SH4K / shvip」
  /// 是**线路名**，不是来源标注，别混进来。
  String get resultLabel {
    final raw = api.trim();
    if (raw.isEmpty) return '';
    if (kind == KSourceKind.live || kind == KSourceKind.unsupported) return '';
    if (raw.contains(hxApiMark)) return ownResultLabel;
    return shortName;
  }

  /// 卡片 id 的路由形态。
  ///
  /// 我们自己的 hx 库和主站采集库是同一套 `vod_id`，卡片就用裸 id ——
  /// 详情 / 播放走主站接口，永远能找到。以前统一编码成 `@src:<key>::<id>`，
  /// 云端配置换 key / 删源之后 `decodeSource` 认不出来，找片子就成了
  /// 「该视频已失效」（ID_RETRY 2026-11-15）。外部源仍然要编码，
  /// 否则 id 会跑到主站库里查，串到别的片。
  String cardIdOf(String vodId) => isOwnLibrary ? vodId : SourceHub.encodeId(key, vodId);

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
        // PROTOCOL_FACE：协议字段必须一起带过去，否则 `updateUser` 改个名字
        // 就把站点的 timeout / header 丢了 —— 这类「一改就退化」最难查。
        timeout: timeout,
        header: header,
        playUrl: playUrl,
        click: click,
        categories: categories,
        jar: jar,
        searchableFlag: searchableFlag,
        changeable: changeable,
        quickSearch: quickSearch,
        style: style,
        playerType: playerType,
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
        // 协议字段（落盘后重启仍然生效；缺字段的老缓存按默认值读回）。
        if (timeout > 0) 'timeout': timeout,
        if (header.isNotEmpty) 'header': header,
        if (playUrl.isNotEmpty) 'playUrl': playUrl,
        if (click.isNotEmpty) 'click': click,
        if (categories.isNotEmpty) 'categories': categories,
        if (jar.isNotEmpty) 'jar': jar,
        if (searchableFlag != 1) 'searchable': searchableFlag,
        if (changeable != 1) 'changeable': changeable,
        if (quickSearch != 1) 'quickSearch': quickSearch,
        if (style.isNotEmpty) 'style': style,
        if (playerType != 0) 'playerType': playerType,
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
    final site = FxSite.from(m);
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
      timeout: site?.timeout ?? 0,
      header: site?.header ?? const <String, String>{},
      playUrl: site?.playUrl ?? '',
      click: site?.click ?? '',
      categories: site?.categories ?? const <String>[],
      jar: site?.jar ?? '',
      searchableFlag: site?.searchable ?? 1,
      changeable: site?.changeable ?? 1,
      quickSearch: site?.quickSearch ?? 1,
      style: site?.style ?? '',
      playerType: site?.playerType ?? 0,
    );
  }
}

/// 一轮检索的源分组：自己的先查先渲染，外部的并行后台查、陆续追加。
///
/// 两组的源数加起来就是进度文案里的分母（幻想 7 + 肥猫 41 = 48）。
class SourceSearchPlan {
  const SourceSearchPlan({required this.own, required this.external});

  /// 我们自己的一批（云端下发的幻想线路 + 主站采集库）。
  final List<KSource> own;

  /// jar 源那批（白名单里用户开着的那几个）。
  ///
  /// 它们的卡片不直接上屏：搜索期先跟自有结果按「片名 + 年份」对齐 ——
  /// 我们有的片合并线路，没有的片才新增一条卡片（见 `cms_bridge` 的 jar 波次）。
  final List<KSource> external;

  int get total => own.length + external.length;

  bool get isEmpty => total == 0;
}

/// 单个源一轮检索的结局（JAR_PROGRESS 2026-11-15）。
///
/// 页面要用它显示「已查 12/41 源 · 命中 3 · 空 20 · 超时 2」，
/// 日志要用它区分「真的没有」和「根本没跑起来」。
enum SourceSearchStatus {
  /// 有结果。
  ok,

  /// 跑了，但一条都没有（站点就是没这部片）。
  empty,

  /// 超时（源级 12 秒兜底，或 jar 通道自己报的超时）。
  timeout,

  /// 出错：类找不到（`no_class`）、jar 抛异常（`call_failed`）、站点报错……
  error;

  /// 页面上给人看的三个字。
  String get label => switch (this) {
        SourceSearchStatus.ok => '有结果',
        SourceSearchStatus.empty => '空',
        SourceSearchStatus.timeout => '超时',
        SourceSearchStatus.error => '出错',
      };
}

/// [SourceHub.searchSource] 的产物：加工好的卡片 + 这个源发生了什么。
class SourceSearchResult {
  const SourceSearchResult({
    required this.source,
    required this.cards,
    required this.status,
    required this.elapsed,
    this.rawCount = 0,
    this.note = '',
    this.quickFallback = false,
  });

  final KSource source;

  /// 已经 relabel + 编码好 id 的卡片（可直接上列表）。
  final List<VideoCard> cards;

  final SourceSearchStatus status;

  final Duration elapsed;

  /// jar 侧转换前的条数（调试：转换是否误杀）。
  final int rawCount;

  /// 失败原因 / 备注（超时、no_class、站点报错原文）。
  final String note;

  /// 是不是靠 quick=true 回退才拿到的结果。
  final bool quickFallback;

  String get label => source.resultLabel;

  bool get hasCards => cards.isNotEmpty;
}

/// 片源中心：云端配置 + 多源检索（只有我们自己的源）。
///
/// 两件事：
///   1. **配置下发**：拉 `GET /api/config`，解析 `cloud_sources`（幻想线路）
///      与 `live_url`（直播接口地址）；拉不到就用本地缓存，缓存也没有就用
///      内置空表 —— 任何一步失败都不能让 App 起不来。
///   2. **多源检索**：搜索 / 分类并行查云端下发的幻想线路，按「片名 + 年份」
///      去重，结果统一标「幻想」（见 [KSource.resultLabel]）。
///
/// jar 源（TVBox `type: 3`）**只在搜索和播放解析时**参与：片源表里保留
/// 白名单内的那几条（见 `jar_sources.dart`），首页 / 分类 / 排行榜永远只用
/// 我们自己的片源。TVBox 配置导入、用户自加源、换源面板仍然不存在。
///
/// id 约定：老记录里可能还带 `@src:<源key>::<vod_id>` 前缀（详情 / 播放
/// 据此路由回它自己的源）；主站 hx 库与主站采集库是同一套编号，id 保持
/// 原样不动（见 [KSource.cardIdOf]）。
class SourceHub extends ChangeNotifier {
  SourceHub._();

  static final SourceHub instance = SourceHub._();

  /// 配置地址：`--dart-define=FX_CONFIG=…` 可覆盖，默认打主站 `/api/config`。
  static const String configOverride = String.fromEnvironment(
    'FX_CONFIG',
    defaultValue: '',
  );

  /// 云端配置 `/api/config` 的超时：**3 秒**（TIMEOUT_UNIFY 2026-11-15）。
  ///
  /// 实测这份配置 0.14 秒就回来了，3 秒已经是很宽的余量；原来给 6 秒，
  /// 弱网下一次首屏要白等 6 秒才铺片源。列表 / 搜索 / 详情各自另有 8 秒。
  static const Duration timeout = Duration(seconds: 3);

  /// 配置缓存有效期：6 小时内不重复拉取（手动刷新不受限）。
  static const Duration cacheTtl = Duration(hours: 6);

  static const String _kCloud = 'fx_sources_cloud_v1';
  static const String _kLiveUrl = 'fx_sources_live_url_v1';
  static const String _kRemoved = 'fx_sources_removed_v1';
  static const String _kFetchedAt = 'fx_sources_fetched_at_v1';

  /// 协议面（`parses` / `flags` / `ads` / `hosts` / `rules` / `doh` / `spider`）
  /// 的落盘键 —— 配置拉不到时也要能按上一份继续解析。
  static const String _kProtocol = 'fx_sources_protocol_v1';

  /// 源级失败账本的落盘键（[SourceFailureLedger]）。
  static const String _kSourceFailure = 'fx_source_failure_v1';

  /// jar 源启停的落盘键（设置 → 片源管理里逐个开关）。
  ///
  /// 存的是「用户显式改过的结果」：没有这个键时按白名单
  /// [kEnabledJarSources] 给默认值（默认开的只有用户挑中的那几个）。
  static const String _kJarEnabled = 'fx_jar_enabled_v1';

  /// 「幻想」这个默认源在界面上的名字。
  static const String ownSourceName = '幻想';

  /* ------------------------------------------------------ 非影视源 */

  /// 源名里出现这些词 = 非影视源（网盘 / 课堂 / 体育 / 音频 / 配置中心）。
  ///
  /// SOURCE_BLOCK（2026-11-17）：云端配置里偶尔混进这类源，它们不参与
  /// 搜索 / 分类，也不参与首页取数。判定写死成关键词，不靠人工维护名单。
  static const List<String> blockedNameWords = <String>[
    '网盘', '云盘', '课堂', '教育', '儿童', '少儿', '体育', '看球',
    'FM', 'DJ', '听书', '音乐', '相声', '小品', '戏曲', '教学',
    '养生', '配置',
  ];

  /// 这个源是不是「非影视源」：名字命中黑名单词、`type=0`（直接地址），
  /// 或者 `api` 是一个 `.py` 脚本（我们没有 Python 运行时）。
  static bool isBlockedSource(KSource source) =>
      blockedReasonOf(source).isNotEmpty;

  /// 不可用的原因（空串 = 可用）。
  static String blockedReasonOf(KSource source) {
    final api = source.api.trim().toLowerCase();
    if (api.isEmpty) return '没有地址';
    if (api.endsWith('.py') || api.contains('.py?') || api.contains('.py/')) {
      return 'Python 脚本，暂不支持';
    }
    if (source.kind == KSourceKind.direct) return '直接地址，不是影视接口';
    final name = '${source.name} ${source.shortName}'.toUpperCase();
    for (final word in blockedNameWords) {
      if (name.contains(word.toUpperCase())) return '非影视源（$word）';
    }
    return '';
  }

  /// 这个源能不能参与内容检索 / 作为首页默认源。
  static bool usableForContent(KSource source) =>
      source.searchable && !isBlockedSource(source);


  static const String idMark = '@src:';

  /// 单源检索超时：超时按「这个源没结果」处理，不拖住其它源。
  ///
  /// 幻想那几条线路是同一个主站接口，正常 0.6~4 秒回来；12 秒是给弱网留的
  /// 兜底，到点就把它判成「这个源没结果」，不影响其它源已经上屏的内容。
  static const Duration sourceTimeout = Duration(seconds: 12);

  List<KSource> _cloud = const <KSource>[];
  Set<String> _removed = <String>{};

  /// jar 源的启停（key = 白名单里的源名）。null = 还没读过磁盘，
  /// 此时按 [kEnabledJarSources] 给默认值。
  Set<String>? _jarEnabled;

  /// jar 插件是否可用（null = 还没查过）。
  bool? _jarReady;
  String _liveUrl = '';
  int _fetchedAt = 0;
  String _error = '';
  bool _refreshing = false;
  bool _loaded = false;
  Future<void>? _booting;

  /// 配置里的协议面（parses / flags / ads / hosts / rules / doh / spider）。
  ///
  /// PROTOCOL_FACE（2026-11-15 · 阶段 1 第 1 条）：这七个顶层键以前被整个
  /// 丢掉，于是「依赖它们的源在壳里能用、在我们这儿不能用」。
  TvBoxConfig _protocol = const TvBoxConfig();

  /// 源级失败账本（第 8 条：失败记本地表，N 分钟内不再全量重试）。
  late final SourceFailureLedger _failures = SourceFailureLedger(
    store: PrefsSourceFailureStore(
      read: _readFailureBody,
      write: _writeFailureBody,
    ),
  );

  /// 配置里的协议面（只读快照，诊断 / 单测用）。
  TvBoxConfig get protocol => _protocol;

  /// 解析器注册表（`json:` / `parse:` 寻址用）。
  ParseRegistry get parsers => ParseRegistry.of(_protocol);

  /// 嗅探规则（「直链还是解析」的判定）。
  FxSniffer get sniffer => FxSniffer.fromConfig(_protocol.rules);

  /// 广告域名表。
  List<String> get ads => List<String>.unmodifiable(_protocol.ads);

  /// 配置里的 DNS 画像（hosts / doh）。
  DnsProfile get dnsProfile => DnsProfile.fromConfig(_protocol);

  /// 源级失败账本（页面可以显示「哪些源在冷却」）。
  SourceFailureLedger get failures => _failures;

  /// 把协议面装进全局消费方：解析注册表 / 嗅探规则 / 站点画像 / 原生 DNS。
  ///
  /// 这四处都是「配置的消费者」，以前一个都不存在；装的时候要**幂等**：
  /// 配置每 6 小时刷一次，重复装不能有副作用（DNS 那边按签名去重，
  /// 画像 / 注册表是整体替换）。
  void _applyProtocolSections(TvBoxConfig config) {
    _protocol = config;
    ParseRegistry.install(parsers);
    FxSniffer.install(sniffer);
    // `ads` → 解析结果的广告域过滤。
    FxAds.install(FxAds(config.ads));
    _installCmsProfiles();
    unawaited(DnsProfileInstaller.install(dnsProfile).then<void>((_) {}));
    fxSourceLog('配置协议面 ${config.summary()}');
  }

  /// 把所有源的站点画像交给 [CmsClient]（详情 / 播放那条链路也能拿到）。
  void _installCmsProfiles() {
    final profiles = <String, CmsSiteProfile>{};
    for (final s in _cloud) {
      if (s.api.trim().isEmpty) continue;
      profiles[s.api.trim()] = s.cmsProfile;
    }
    CmsClient.installProfiles(profiles);
  }

  Future<String?> _readFailureBody() async {
    try {
      final sp = await SharedPreferences.getInstance();
      return sp.getString(_kSourceFailure);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeFailureBody(String body) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kSourceFailure, body);
    } catch (_) {
      // 写不进去只是下次启动不记得，不影响本轮检索。
    }
  }

  /* ------------------------------------------------------------ 读取 */

  /// 云端下发的全部源（含已被删掉的，检索前按 [removed] 过滤）。
  List<KSource> get cloudSources => List<KSource>.unmodifiable(_cloud);

  /// 云端源里当前生效的（没被删、enabled 不为 false）。
  List<KSource> get visibleCloud => <KSource>[
        for (final s in _cloud)
          if (!_removed.contains(s.key) && s.enabled) s,
      ];

  /* ------------------------------------------------------ 首页当前源 */

  /// 首页 / 分类 / 排行榜用的就是「幻想」这一套（`src=hx`），
  /// 没有「换源」这回事：外部源接入层已经整层拆掉。
  static const String ownSourceKey = '@own';

  /* ------------------------------------------------------------- jar 源 */

  /// jar 源（`type: 3`）在片源表里的白名单标签（`咕噜` / `橘汁` …）。
  ///
  /// 不在 [kEnabledJarSources] 里的一律返回空串 —— 设置页不显示、
  /// 搜索不发请求、播放解析也不认。
  static String jarLabelOf(KSource source) {
    if (source.kind != KSourceKind.jar) return '';
    final byName = fxJarLabelOf(source.name);
    if (byName.isNotEmpty) return byName;
    return fxJarLabelOf(source.key);
  }

  /// 把内置目录里的那几条 jar 源补进片源表。
  ///
  /// 为什么需要补：云端 `/api/config` 目前只下发一条 CMS 源，没有 jar 站点，
  /// 但用户点名的这四个源要能在「片源管理」里看到、要能手动启停，所以
  /// 类名 / `ext` 内置在 `jar_sources.dart`；云端将来真下发了同名的 jar 站点，
  /// 以云端那份为准（`ext` 可能更新），内置的只做兜底。
  void _injectJarCatalog() {
    final jar = <KSource>[
      for (final s in _cloud)
        if (s.kind == KSourceKind.jar && jarLabelOf(s).isNotEmpty) s,
    ];
    final out = <KSource>[
      for (final s in _cloud)
        if (s.kind != KSourceKind.jar) s,
      ...jar,
    ];
    for (final def in kBuiltinJarSources) {
      final label = fxJarLabelOf(def.name);
      if (label.isEmpty) continue;
      if (jar.any((s) => jarLabelOf(s) == label)) continue;
      out.add(
        KSource(
          key: label,
          name: def.name,
          api: def.api,
          kind: KSourceKind.jar,
          origin: KSourceOrigin.cloud,
          ext: def.ext,
        ),
      );
    }
    _cloud = out;
  }

  /// jar 源的默认开关：白名单里的都算「用户挑中的」，默认启用。
  bool _jarDefaultEnabled(String label) => kEnabledJarSources.contains(label);

  /// 这个 jar 源当前是否启用（用户改过就按用户的，没改过按白名单）。
  bool jarSourceEnabled(String label) {
    final key = fxJarLabelOf(label).isEmpty ? label : fxJarLabelOf(label);
    if (key.isEmpty) return false;
    final saved = _jarEnabled;
    if (saved != null) return saved.contains(key);
    return _jarDefaultEnabled(key);
  }

  /// 设置页里逐个开关 jar 源。
  ///
  /// 第一次改动时把「当前默认值」整体落盘，之后再改只动这一条 ——
  /// 这样用户关掉咕噜不会把另外三个也一起关掉。
  Future<void> setJarSourceEnabled(String label, bool enabled) async {
    final key = fxJarLabelOf(label).isEmpty ? label.trim() : fxJarLabelOf(label);
    if (key.isEmpty) return;
    final next = <String>{
      for (final l in kEnabledJarSources)
        if (jarSourceEnabled(l)) l,
    };
    if (enabled) {
      next.add(key);
    } else {
      next.remove(key);
    }
    _jarEnabled = next;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(_kJarEnabled, next.toList()..sort());
    } catch (_) {
      // 写不进去只是下次启动回到默认值，本轮照样生效。
    }
  }

  /// 参与搜索的 jar 源：白名单 ∩ 用户开着 ∩ 没被删。
  ///
  /// **顺序就是白名单顺序**（咕噜 / 橘汁 / 剧圈 / 下饭），不受云端配置里的
  /// 排列影响 —— 详情页大类 chip 的顺序、搜索发车顺序都以它为准。
  List<KSource> get jarSources {
    final byLabel = <String, KSource>{};
    for (final s in visibleCloud) {
      final label = jarLabelOf(s);
      if (label.isEmpty) continue;
      byLabel.putIfAbsent(label, () => s);
    }
    return <KSource>[
      for (final label in kEnabledJarSources)
        if (byLabel[label] != null && jarSourceEnabled(label))
          byLabel[label]!,
    ];
  }

  /// 有没有启用中的 jar 源。
  bool get hasJarSources => jarSources.isNotEmpty;

  /// jar 插件（`spider.jar`）是否已装好。
  ///
  /// 没装就**不**去敲那四个 jar 源（每个都要现下载 dex / 初始化，白等十几秒），
  /// 搜索流直接跳过；设置页里给一句可读的提示。
  bool get jarReady => _jarReady == true;

  /// jar 源现在是「开着但插件没装」的状态（界面据此提示去装）。
  bool get jarMissing => _jarReady == false && hasJarSources;

  /// jar 插件没装时的可读提示（装好了返回空串）。
  String get jarNotice {
    if (!jarMissing) return '';
    return 'jar 源需要先安装 spider.jar：设置 → 片源管理 → 安装 / 更新';
  }

  /// 查一次 jar 插件状态（幂等，结果缓存）。
  Future<void> ensureJarStatus() {
    if (_jarReady != null) return Future<void>.value();
    return refreshJarStatus();
  }

  /// 重新查询 jar 插件状态。
  Future<void> refreshJarStatus() async {
    try {
      if (!JarSpider.supported) {
        _jarReady = false;
        notifyListeners();
        return;
      }
      final status = await JarSpider.status();
      _jarReady = status.installed;
      fxJarLog(
        'jar 插件状态 installed=${status.installed} '
        'md5=${status.shortMd5} size=${status.sizeLabel}',
      );
    } catch (e) {
      _jarReady = false;
      fxJarLog('jar 插件状态查询失败 err=$e');
    }
    notifyListeners();
  }

  /// 装好 / 卸掉 jar 之后把状态清掉重查（`JarPluginManager` 装完会调）。
  void invalidateJarStatus() {
    _jarReady = null;
    notifyListeners();
  }

  /// 参与搜索 / 分类的源：只有我们自己的那批（云端下发的幻想线路）。
  ///
  /// 同一个地址只留一份，直播源 / 非影视源不在此列。
  List<KSource> get querySources {
    final out = <KSource>[];
    final seen = <String>{};
    for (final s in visibleCloud) {
      // jar 源单独走 [jarSources]：它是「搜索 + 播放解析」专用的一批，
      // 不进自有源的检索计划（首页 / 分类 / 排行永远只有自有源）。
      if (s.kind == KSourceKind.jar) continue;
      // SOURCE_BLOCK：网盘 / 课堂 / 体育 / 音频 / 配置文件这类源不参与检索。
      if (!usableForContent(s)) continue;
      // FAIL_LEDGER（第 8 条）：这个源正在冷却 —— 批量检索跳过它，
      // 别让一轮搜索在死源上白等。用户主动点进详情 / 播放不受影响。
      if (_failures.shouldSkip(s.key)) continue;
      if (!seen.add(s.api.trim())) continue;
      out.add(s);
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
    return '';
  }

  /// 云端配置里是不是显式配了直播地址（设置页用它提示）。
  bool get hasCloudLiveUrl => liveUrl.isNotEmpty;

  /// 一轮检索要查的源：`own` = 自有源（云端下发的幻想线路），
  /// `external` = 启用的 jar 源（白名单里那几个，见 [jarSources]）。
  SourceSearchPlan get searchPlan =>
      SourceSearchPlan(own: querySources, external: jarSources);

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
    // 缓存过期或从来没拉过：后台补一次，不挡首屏。
    final age = _fetchedAt <= 0
        ? null
        : DateTime.now().difference(
            DateTime.fromMillisecondsSinceEpoch(_fetchedAt),
          );
    if (age == null || age > cacheTtl) unawaited(refresh());
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
    // 协议面：我们自己的 `/api/config` 也可能带 `parses` / `rules` / `hosts`
    // （后台直接把 TVBox 配置透传过来就是这个形状），一并接管。
    //
    // 但**只有真的带了协议面才接管**：后台那份配置通常只有 `cloud_sources`
    // + `live_url`，拿它去覆盖会把导入过的解析器注册表 / 嗅探规则 / hosts
    // 全清空 —— 这种退化不报错，只会让 `parse:` 线路又变回「需要网页解析」。
    final protocol = TvBoxConfig.fromMap(Map<String, Object?>.from(map));
    if (protocol.hasProtocolSections) {
      _applyProtocolSections(protocol);
    }
    // 云端没下发 jar 站点时把内置目录补进来（用户挑中的那四个源）。
    _injectJarCatalog();
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
    // 站点字段统一走 `FxSite`（TVBox 协议的唯一解析口径）：壳的 `Site` 有
    // 15 个字段，我们原来只认 7 个。`key` 缺省时按 `name` 兜 —— TVBox 配置
    // 里只写 name 的站点很常见。
    final site = FxSite.from(m);
    if (site == null) return null;
    final kind = kindOf(m['type']);
    // type 4（python 脚本）等仍不支持，解析阶段就丢掉；type 3（jar 插件）
    // 保留下来，但只有白名单里的源会被 [SourceHub.jarSources] 选出来。
    if (kind == KSourceKind.unsupported) return null;
    return KSource(
      key: site.key,
      name: site.name,
      api: site.api,
      kind: kind,
      origin: KSourceOrigin.cloud,
      builtin: m['builtin'] != false,
      enabled: m['enabled'] != false,
      reason: _reasonOf(m['type'], kind),
      ext: site.ext,
      timeout: site.timeout,
      header: site.header,
      playUrl: site.playUrl,
      click: site.click,
      categories: site.categories,
      jar: site.jar,
      searchableFlag: site.searchable,
      changeable: site.changeable,
      quickSearch: site.quickSearch,
      style: site.style,
      playerType: site.playerType,
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
        // type 3 是 TVBox 的 jar 插件源（`spider.jar`）。是否真的参与检索
        // 由白名单决定（见 `jar_sources.dart` 的 [kEnabledJarSources]）。
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

  /// 调试用：清掉本地片源缓存（下次启动重新拉云端配置）。
  Future<void> resetLocal() async {
    _cloud = const <KSource>[];
    _removed = <String>{};
    _liveUrl = '';
    _fetchedAt = 0;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_kCloud);
      await sp.remove(_kRemoved);
      await sp.remove(_kLiveUrl);
      await sp.remove(_kFetchedAt);
      await sp.remove(_kProtocol);
      await sp.remove(_kSourceFailure);
      // 老版本留下的片源管理键：一并清掉，避免升级后还挂着旧数据。
      await sp.remove('fx_sources_user_v1');
      await sp.remove('fx_sources_auto_tvbox_v1');
      await sp.remove('fx_home_source_v1');
      await sp.remove('fx_sources_pinned_v1');
      await sp.remove('fx_sources_bundled_hidden_v1');
    } catch (_) {}
    _protocol = const TvBoxConfig();
    ParseRegistry.install(ParseRegistry.empty);
    FxSniffer.install(FxSniffer.none);
    FxAds.install(FxAds.none);
    CmsClient.installProfiles(const <String, CmsSiteProfile>{});
    await _failures.clear();
    notifyListeners();
  }

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
    final result = await searchSource(source, keyword, page);
    return result.cards;
  }

  /// 单个源的检索结局（JAR_PROGRESS 2026-11-15）。
  ///
  /// 为什么要它：上一版 `_searchOne` 把 jar 抛出来的东西**一律 catch 成空列表**，
  /// 于是「类找不到 / 超时 / 站点报错 / 真没有」在页面上全都长成一个样子
  /// —— 用户只看到「肥猫源搜不到」，日志里连一行都没有。现在每个源都带
  /// 自己的结局 + 耗时 + 失败原因，页面按结局显示进度，日志按结局写一行。
  Future<SourceSearchResult> searchSource(
    KSource source,
    String keyword,
    int page,
  ) async {
    final q = keyword.trim();
    final label = source.resultLabel;
    if (q.isEmpty) {
      return SourceSearchResult(
        source: source,
        cards: const <VideoCard>[],
        status: SourceSearchStatus.empty,
        elapsed: Duration.zero,
      );
    }
    final started = DateTime.now();
    Duration spent() => DateTime.now().difference(started);
    // SITE_TIMEOUT（第 3 条）：慢源用它自己配的 `timeout`，不再被全局 12 秒
    // 一刀切；没配的源仍然走 [SourceHub.sourceTimeout]（行为与改造前一致）。
    final limit = source.ownTimeout ?? sourceTimeout;
    // 站点画像：header / ext / playUrl 交给 CmsClient（详情、播放那条链路
    // 也从这里拿到同一份画像，见 CmsClient.installProfiles）。
    CmsClient.installProfiles(<String, CmsSiteProfile>{
      ..._cmsProfilesSnapshot(),
      source.api.trim(): source.cmsProfile,
    });

    /// 记账：成功清账，失败进冷却（下一轮批量检索跳过它）。
    void record(SourceSearchStatus status, String note) {
      switch (status) {
        case SourceSearchStatus.ok:
          unawaited(_failures.recordSuccess(source.key));
        case SourceSearchStatus.empty:
          // 源通着、只是没这部片：只记次数，不冷却。
          unawaited(_failures.recordFailure(
            source.key,
            SourceFailureKind.empty,
            note: note,
          ));
        case SourceSearchStatus.timeout:
          unawaited(_failures.recordFailure(
            source.key,
            SourceFailureKind.timeout,
            note: note,
          ));
        case SourceSearchStatus.error:
          unawaited(_failures.recordFailure(
            source.key,
            _failureKindOf(note),
            note: note,
          ));
      }
    }

    List<VideoCard> prepared(List<VideoCard> cards) => <VideoCard>[
          for (final card in cards)
            if (!isLiveCard(card))
              relabel(
                card,
                label: label,
                id: source.cardIdOf(card.id),
                // COVER_FIX（2026-11-15）：外部源的 `vod_pic` 经常是**源站
                // 相对地址**（`upload/vod/1.jpg`）或空串。这里按这个源自己的
                // 站点根补全；补不出来（jar 源只给类名 `csp_Gulu`，没有站点
                // 根）就交给 UI 显示首字占位 —— 关键是**不许**再补成我们旧
                // 后端的地址，那种图永远 404，用户看到的是一块空白。
                cover: Api.coverOf(card.cover, root: source.api),
              ),
        ];

    if (source.kind == KSourceKind.jar) {
      // jar 源（`type: 3`）：走原生 `fantasy_tv/spider` 通道，两种 quick 都在
      // [JarSpider.searchWithFallback] 里试过，这里只加一层源级兜底超时。
      try {
        final report = await JarSpider.searchWithFallback(
          api: source.api,
          ext: source.ext,
          key: q,
          page: page,
          label: label,
        ).timeout(limit);
        final cards = prepared(report.cards);
        final status = cards.isNotEmpty
            ? SourceSearchStatus.ok
            : report.allTimedOut
                ? SourceSearchStatus.timeout
                : report.allFailed
                    ? SourceSearchStatus.error
                    : SourceSearchStatus.empty;
        if (cards.isEmpty) {
          fxJarLog(
            'source=$label key=$q 结局=${status.name}'
            '${report.note.isEmpty ? '' : ' err=${fxJarClip(report.note, max: 120)}'}'
            ' 耗时=${spent().inMilliseconds}ms',
          );
        }
        record(status, report.note);
        return SourceSearchResult(
          source: source,
          cards: cards,
          status: status,
          elapsed: spent(),
          rawCount: report.cards.length,
          note: report.note,
          quickFallback: report.usedFallback,
        );
      } on TimeoutException {
        fxJarLog(
          'source=$label key=$q 结局=timeout（源级 ${limit.inSeconds}s 兜底）'
          ' 耗时=${spent().inMilliseconds}ms',
        );
        record(SourceSearchStatus.timeout, '源级超时');
        return SourceSearchResult(
          source: source,
          cards: const <VideoCard>[],
          status: SourceSearchStatus.timeout,
          elapsed: spent(),
          note: '源级超时',
        );
      } catch (e) {
        fxJarLog(
          'source=$label key=$q 结局=error err=${fxJarClip('$e', max: 120)}'
          ' 耗时=${spent().inMilliseconds}ms',
        );
        record(SourceSearchStatus.error, '$e');
        return SourceSearchResult(
          source: source,
          cards: const <VideoCard>[],
          status: SourceSearchStatus.error,
          elapsed: spent(),
          note: '$e',
        );
      }
    }

    try {
      final cards = await CmsClient.of(source.api)
          .search(q, page)
          .timeout(limit);
      final out = prepared(cards);
      final status =
          out.isEmpty ? SourceSearchStatus.empty : SourceSearchStatus.ok;
      record(status, '');
      return SourceSearchResult(
        source: source,
        cards: out,
        status: status,
        elapsed: spent(),
        rawCount: cards.length,
      );
    } on TimeoutException {
      fxSourceLog(
        'source=$label key=$q 结局=timeout（站点级 ${limit.inSeconds}s）'
        ' 耗时=${spent().inMilliseconds}ms',
      );
      record(SourceSearchStatus.timeout, '源级超时');
      return SourceSearchResult(
        source: source,
        cards: const <VideoCard>[],
        status: SourceSearchStatus.timeout,
        elapsed: spent(),
        note: '源级超时',
      );
    } catch (e) {
      record(SourceSearchStatus.error, '$e');
      return SourceSearchResult(
        source: source,
        cards: const <VideoCard>[],
        status: SourceSearchStatus.error,
        elapsed: spent(),
        note: '$e',
      );
    }
  }

  /// 失败类型归类：jar 的「类找不到 / 通道异常」算崩溃（壳的 `crash` 熔断），
  /// 其余算普通出错。
  static SourceFailureKind _failureKindOf(String note) {
    final text = note.toLowerCase();
    if (text.contains('no_class') ||
        text.contains('no_jar') ||
        text.contains('classnotfound') ||
        text.contains('channel') ||
        text.contains('crash')) {
      return SourceFailureKind.crash;
    }
    return SourceFailureKind.error;
  }

  /// 当前所有源的画像快照（安装单个源的画像时用，别把别人的冲掉）。
  Map<String, CmsSiteProfile> _cmsProfilesSnapshot() => <String, CmsSiteProfile>{
        for (final s in _cloud)
          if (s.api.trim().isNotEmpty) s.api.trim(): s.cmsProfile,
      };

  /// 查单个源并加工成可直接上列表的样子：来源标记按 [KSource.resultLabel]
  /// 判定，id 按 [KSource.cardIdOf] 路由（我们自己的库用裸 id，外部源编成
  /// `@src:<key>::<vod_id>`）。
  ///
  /// 渐进检索用这个：外部源一个比一个慢，谁先回来就先交给页面渲染。
  /// 单源超过 [sourceTimeout] 一律当「这个源没结果」，不阻塞其它源。
  Future<List<VideoCard>> searchPrepared(
    KSource source,
    String keyword,
    int page,
  ) async {
    final result = await searchSource(source, keyword, page);
    return result.cards;
  }

  Future<List<VideoCard>> _categoryOne(
    KSource source,
    String channelKey,
    int page,
  ) async {
    try {
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
      final label = source.resultLabel;
      for (final card in lists[i]) {
        if (isLiveCard(card)) continue;
        if (!seen.add(dedupeKey(card))) continue;
        out.add(relabel(
          card,
          label: label,
          id: source.cardIdOf(card.id),
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

  /// 两张卡片是不是「同一条记录」（DEDUPE_LINES 2026-11-15）。
  ///
  /// 判据：片名（归一化）+ 年份要一致，且片源分组相同**或任一方为空**。
  /// 「片源分组为空」= 线路切片 / 外部源 / 老数据，它们没有 `vod_from`，
  /// 会并进同名的片源记录里 —— 这正是搜索「济公传」时那条重复且点不开的
  /// 记录被主库记录吸收的判据。hx 与 xo 两条不同片源的记录不算同一条
  /// （SOURCE_SPLIT 要求它们并存）。
  static bool sameRecord(VideoCard a, VideoCard b) {
    if (a.id.trim().isNotEmpty && a.id.trim() == b.id.trim()) return true;
    final ta = normTitle(a.title);
    if (ta.isEmpty || ta != normTitle(b.title)) return false;
    final fa = a.fromSource.trim();
    final fb = b.fromSource.trim();
    if (fa != fb && fa.isNotEmpty && fb.isNotEmpty) return false;
    if (a.year > 0 && b.year > 0 && a.year != b.year) return false;
    return true;
  }

  /// 同名记录里谁更该留下（DEDUPE_LINES 2026-11-15）。
  ///
  /// 规则：**可用线路多的优先**；线路数一样时**片源分组非空的优先**
  /// （主库记录 `hx`/`xo` 的线路表是全的；线路切片 / 外部源的卡片没有
  /// `vod_from`，主站搜索接口给它的线路常常是截断的一条）。
  /// 两条都不满足（完全同级）时保持先到的那条，列表不会跟着批次顺序乱跳。
  static bool betterRecord(VideoCard candidate, VideoCard current) {
    if (candidate.lineCount != current.lineCount) {
      return candidate.lineCount > current.lineCount;
    }
    final cFrom = candidate.fromSource.trim().isNotEmpty;
    final oFrom = current.fromSource.trim().isNotEmpty;
    return cFrom && !oFrom;
  }

  /// 片名归一化（去大小写 / 空白 / 标点）。
  ///
  /// FX_FALLBACK（2026-11-15）：规则本体搬到 `fallback_match.dart`
  /// 的 [fxNormTitle]，播放失败后的跨源匹配用的是**同一个函数** ——
  /// 两处各写一套归一化，迟早会出现「搜索页认作同一部、换源却认不出来」。
  static String normTitle(String raw) => fxNormTitle(raw);

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
    String? cover,
  }) =>
      VideoCard(
        id: id ?? card.id,
        title: card.title,
        cover: cover ?? card.cover,
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
        // LINES_COUNT：线路数也一起带上 —— 丢了它，同名记录去重就会以为
        // 两边都是 0 条线路，赢家变成「谁先到」，等于没修。
        lineCount: card.lineCount,
      );

  /* ------------------------------------------------------------ 持久化 */

  Future<void> _loadCache() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final cloudRaw = sp.getString(_kCloud);
      if (cloudRaw != null && cloudRaw.trim().isNotEmpty) {
        _cloud = _decodeList(cloudRaw);
      }
      final removedRaw = sp.getStringList(_kRemoved);
      if (removedRaw != null) _removed = removedRaw.toSet();
      final jarRaw = sp.getStringList(_kJarEnabled);
      if (jarRaw != null) _jarEnabled = jarRaw.toSet();
      _liveUrl = sp.getString(_kLiveUrl) ?? '';
      _fetchedAt = sp.getInt(_kFetchedAt) ?? 0;
      final protocolRaw = sp.getString(_kProtocol);
      if (protocolRaw != null && protocolRaw.trim().isNotEmpty) {
        _applyProtocolSections(
          TvBoxConfig.fromProtocolMap(jsonDecode(protocolRaw)),
        );
      } else {
        // 老缓存没有协议面：先把已有的源画像装上（详情 / 播放那条链路要用）。
        _installCmsProfiles();
      }
    } catch (_) {
      // 缓存坏了就当没有：下次 refresh 会重新写一遍。
    }
    // 不管缓存里有没有 jar 站点，白名单里那几条都要在片源表里（设置页能开关）。
    _injectJarCatalog();
    // 源级失败账本：读盘失败按空表处理（多试一次源总比一直白等强）。
    await _failures.ensureLoaded();
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
      await sp.setString(_kLiveUrl, _liveUrl);
      await sp.setStringList(_kRemoved, _removed.toList());
      await sp.setString(_kProtocol, jsonEncode(_protocol.protocolToMap()));
    } catch (_) {}
  }

  Future<void> _saveFetchedAt() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_kFetchedAt, _fetchedAt);
    } catch (_) {}
  }


}

/// 任意值 → 去空白的文本（配置字段可能是 null / 数字 / 字符串）。
String _text(Object? raw) {
  if (raw == null) return '';
  return raw.toString().trim();
}

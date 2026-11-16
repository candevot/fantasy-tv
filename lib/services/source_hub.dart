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
import 'jar_log.dart';
import 'jar_spider.dart';
import 'parse_registry.dart';
import 'sniff_rules.dart';
import 'source_failure.dart';
import 'tvbox_config.dart';
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

/// 片源中心：云端配置 + 本地增删 + 多源检索。
///
/// 三件事：
///   1. **配置下发**：拉 `GET /api/config`，解析 `cloud_sources`（片源）
///      与 `live_url`（直播接口地址）；拉不到就用本地缓存，缓存也没有就用
///      内置空表 —— 任何一步失败都不能让 App 起不来。
///   2. **可删可恢复**：删掉的内置源只记一个 key 黑名单，云端的原始列表
///      一直留着，「恢复默认」= 清空黑名单，不需要重新拉配置。
///   3. **多源合并**：搜索 / 分类并行查所有启用的源，按「片名 + 年份」
///      去重，结果带上来源标记（幻想 / 肥猫 / 自加，见
///      [KSource.resultLabel]）；搜索分成「自己的」和「外部的」两组渐进
///      返回，见 [searchPlan]。
///
/// id 约定：外部源的影片 id 会编码成 `@src:<源key>::<vod_id>`，
/// 详情 / 播放据此路由回原来的源；我们自己的 hx 库和主站采集库是同一套
/// 编号，id 保持原样不动（见 [KSource.cardIdOf]）。
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

  /// 协议面（`parses` / `flags` / `ads` / `hosts` / `rules` / `doh` / `spider`）
  /// 的落盘键 —— 配置拉不到时也要能按上一份继续解析。
  static const String _kProtocol = 'fx_sources_protocol_v1';

  /// 源级失败账本的落盘键（[SourceFailureLedger]）。
  static const String _kSourceFailure = 'fx_source_failure_v1';

  /// 首页当前用哪个源（源选择面板的结果）；空串 = 幻想（默认）。
  static const String _kHomeSource = 'fx_home_source_v1';

  /// 「推荐 / 置顶」标记（片源管理里手动钉上去的源）。
  static const String _kPinned = 'fx_sources_pinned_v1';

  /// 肥猫那一批（TVBox 批量导入）是否被用户在片源管理里删掉。
  static const String _kBundledHidden = 'fx_sources_bundled_hidden_v1';

  /// 「幻想」这个默认源在界面上的名字（源选择面板固定第一项）。
  ///
  /// SOURCE_PICK_DEFAULT（2026-11-17）：壳（FongMi / OK影视）的源面板里
  /// 默认选中它自己那份配置的源（咕噜）；我们是「幻想」，所以幻想必须
  /// **永远排第一、永远是默认选中**，咕噜 / 豆瓣 / 配置中心这些肥猫源
  /// 一律排在它后面。默认源的 key 用空串表示，这样它不依赖云端配置里
  /// 某个具体 key（换 key / 重新下发也不会把默认项弄丢）。
  static const String ownSourceName = '幻想';

  /// 源面板标题的后缀（壳的写法是「名字 · APP」）。
  static const String sourceTitleSuffix = ' · APP';

  /* ------------------------------------------------------ 非影视源 */

  /// 源名里出现这些词 = 非影视源（网盘 / 课堂 / 体育 / 音频 / 配置中心）。
  ///
  /// SOURCE_BLOCK（2026-11-17）：壳的源面板里这些源也是 ⊘ 状态。用户口径：
  /// 「照常列出（能看到全部）但点不动，不参与首页/分类/排行榜的默认源，
  /// 也不参与搜索」。判定写死成关键词，不靠人工维护名单 —— 肥猫配置里这类
  /// 源有几十个，名字还会变（「夸克·网盘」「123·云盘」「小学·课堂」…）。
  static const List<String> blockedNameWords = <String>[
    '网盘', '云盘', '课堂', '教育', '儿童', '少儿', '体育', '看球',
    'FM', 'DJ', '听书', '音乐', '相声', '小品', '戏曲', '教学',
    '养生', '配置',
  ];

  /// 这个源是不是「非影视源」：名字命中黑名单词、`type=0`（直接地址），
  /// 或者 `api` 是一个 `.py` 脚本（我们没有 Python 运行时）。
  static bool isBlockedSource(KSource source) =>
      blockedReasonOf(source).isNotEmpty;

  /// 不可用的原因（空串 = 可用）。源面板拿它显示一行小字。
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
  ///
  /// JAR_TIMEOUT（2026-11-15）：从 8 秒放宽到 **12 秒**。8 秒是「jar 通道
  /// 自身超时」的值，套在源级上就变成了「源级和通道级同时到点」—— jar 那边
  /// 刚要说「超时」我们已经先把它判死了，日志里全是一致的 8000ms，
  /// 分不清是谁先放弃。现在源级 12 秒 > 通道 12 秒内的两次尝试预算
  /// （[JarSpider.searchBudget] = 11 秒），层次清楚：**先由 jar 报「这个源
  /// 超时/出错」，源级只兜底**。
  static const Duration sourceTimeout = Duration(seconds: 12);

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
      // 状态出来之后标题可能要降级（默认源是 jar 源、但没装 jar），
      // 通知一次让首页 / 片源页跟着变。
      _notifySafely();
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
  String _homeKey = '';
  Set<String> _pinned = <String>{};
  bool _bundledHidden = false;
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

  /// 全局线路名表（透传给 jar 源的 `playerContent`）。
  List<String> get flags => List<String>.unmodifiable(_protocol.flags);

  /// 广告域名表。
  List<String> get ads => List<String>.unmodifiable(_protocol.ads);

  /// 全局 jar（站点级 `jar` 为空时用它）。
  String get spider => _protocol.spider;

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
    // `flags` → jar 源的 `playerContent(flag, id, flags)`（壳同一语义）。
    JarSpider.setVipFlags(config.flags);
    // `ads` → 解析结果的广告域过滤。
    FxAds.install(FxAds(config.ads));
    _installCmsProfiles();
    unawaited(DnsProfileInstaller.install(dnsProfile).then<void>((_) {}));
    fxJarLog('配置协议面 ${config.summary()}');
  }

  /// 把所有源的站点画像交给 [CmsClient]（详情 / 播放那条链路也能拿到）。
  void _installCmsProfiles() {
    final profiles = <String, CmsSiteProfile>{};
    for (final s in <KSource>[..._cloud, ..._user]) {
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
  ///
  /// 用户在片源管理里删掉这一条时只置 [bundledHidden]：导入结果原样留着，
  /// 「恢复」不需要重新联网拉配置。
  List<KSource> get bundledSources => List<KSource>.unmodifiable(
        _bundledHidden
            ? const <KSource>[]
            : <KSource>[
                for (final s in _user)
                  if (isBundledSource(s)) s,
              ],
      );

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

  /// 云端源里被用户删掉的（片源管理的「已移除」分组，可恢复）。
  List<KSource> get removedCloudSources => <KSource>[
        for (final s in _cloud)
          if (_removed.contains(s.key)) s,
      ];

  /* ------------------------------------------------------ 首页当前源 */

  /// 首页 / 分类 / 排行榜当前用哪个源。
  ///
  /// 三种取值（SOURCE_PICK_ORDER，2026-11-17 定稿）：
  ///   · 空串 = **自动**：配置里的第一个源（壳的默认项，肥猫配置里就是咕噜）；
  ///   · [ownSourceKey]（`@own`）= 幻想（我们自己的 hx 库）；
  ///   · 其它 = 某个具体源的 key。
  String get homeSourceKey => _homeKey;

  /// 「幻想」这个默认项在面板里的 key（它不是云端 key，用一个固定标记）。
  static const String ownSourceKey = '@own';

  /// 这个源现在**真能出内容**吗（jar 源要先装 jar 插件）。
  ///
  /// 用它做「标题降级」的判据：默认源是咕噜、但这台机器没装 jar 插件时，
  /// 首页实际取到的是幻想的内容 —— 标题就必须显示「幻想 · APP」，
  /// 绝不能出现「标题写咕噜、内容是幻想」的错位。
  bool canServeContent(KSource source) {
    if (!usableForContent(source)) return false;
    if (source.kind == KSourceKind.jar) return _jarReady != false;
    return true;
  }

  /// 配置里的第一个源：肥猫那批按导入顺序，其次自加源，最后云端幻想线路。
  ///
  /// 壳的默认源就是「配置 sites 的第一条」，这里按同一口径取，
  /// **不做任何重排**（推荐 / 置顶只影响片源管理页里的排序）。
  KSource? get firstConfigSource {
    for (final s in bundledSources) {
      if (canServeContent(s)) return s;
    }
    for (final s in userSources) {
      if (canServeContent(s)) return s;
    }
    for (final s in visibleCloud) {
      if (canServeContent(s)) return s;
    }
    return null;
  }

  /// 当前选中的源；null = 幻想（主站 hx 库那条默认路径）。
  KSource? get homeSource {
    final key = _homeKey.trim();
    if (key == ownSourceKey) return null;
    if (key.isEmpty) return firstConfigSource;
    for (final s in _cloud) {
      // 选中的源出不了内容（没装 jar / 非影视源 / 被删掉）→ 标题和内容都
      // 降级到幻想，不留「标题写咕噜、内容是幻想」的错位。
      if (s.key == key) return canServeContent(s) ? s : firstConfigSource;
    }
    for (final s in _user) {
      if (s.key == key) return canServeContent(s) ? s : firstConfigSource;
    }
    // 源被删了 / 被禁用了：当作「自动」，回到配置第一个可用源
    // （没有就是幻想）。
    return firstConfigSource;
  }

  /// 当前是不是选中了「幻想」。
  bool get isOwnSourceSelected => homeSource == null;

  /// 首页标题栏上的源名（壳的写法「名字 · APP」里那个名字）。
  String get homeSourceName {
    final picked = homeSource;
    if (picked == null) return ownSourceName;
    final short = picked.shortName;
    return short.isEmpty ? picked.name : short;
  }

  /// 首页标题栏那一行字：`咕噜 · APP` / `幻想 · APP`。
  String get homeSourceTitle => '$homeSourceName$sourceTitleSuffix';

  /// 选中一个源作为首页的数据源（[ownSourceKey] = 幻想）。
  ///
  /// 传进来一个不认识 / 已被删掉的 key 会被忽略，不会把首页弄成空白。
  Future<void> selectHomeSource(String key) async {
    final want = key.trim();
    if (want.isNotEmpty && want != ownSourceKey) {
      final known = <KSource>[..._cloud, ..._user]
          .any((s) => s.key == want && usableForContent(s));
      if (!known) return;
    }
    if (_homeKey == want) return;
    _homeKey = want;
    await _saveHomeSource();
    notifyListeners();
  }

  /// 源面板里的条目：**就是配置里的原始顺序**，一项都不重排。
  ///
  /// 顺序（定稿口径）：肥猫那批（sites 原顺序：咕噜 / 豆瓣 / 配置中心 / …）
  /// → 自加源 → 云端幻想线路。面板把「幻想」单列成最后一行（它不是一个
  /// sites 条目，是我们自己的 hx 库）。
  List<KSource> get pickerSources => <KSource>[
        // 非影视源也照常列出（用户要求「能看到全部」），面板把它们画成
        // ⊘ 不可选；这里只滤掉彻底不可搜 / 已删掉的条目。
        for (final s in bundledSources)
          if (s.searchable) s,
        for (final s in userSources)
          if (s.searchable) s,
        for (final s in visibleCloud)
          if (s.searchable) s,
      ];

  /* ------------------------------------------------------ 推荐 / 置顶 */

  /// 这个源被标成「推荐」了吗（片源管理里手动点的）。
  bool isPinned(String key) => _pinned.contains(key.trim());

  /// 推荐 / 取消推荐。标记会持久化，并影响源面板与片源管理的排序。
  Future<void> togglePinned(String key) async {
    final k = key.trim();
    if (k.isEmpty) return;
    if (!_pinned.remove(k)) _pinned.add(k);
    await _savePinned();
    notifyListeners();
  }

  /* ------------------------------------------------------ 肥猫那一批 */

  /// 肥猫（TVBox 批量导入）那一批是否被删掉了。
  bool get bundledHidden => _bundledHidden;

  /// 删掉 / 恢复肥猫那一批（只隐藏，不销毁导入结果 —— 恢复不需要联网）。
  Future<void> setBundledHidden(bool hidden) async {
    if (_bundledHidden == hidden) return;
    _bundledHidden = hidden;
    await _saveBundledHidden();
    notifyListeners();
  }

  /// 参与搜索 / 分类的源：云端生效的 + 用户自加的全部。
  ///
  /// 同一个地址只留一份（云端和用户各加一遍很常见），直播源不在此列。
  List<KSource> get querySources {
    final out = <KSource>[];
    final seen = <String>{};
    void take(KSource s) {
      // SOURCE_BLOCK：网盘 / 课堂 / 体育 / 音频 / 配置文件这类源
      // 不参与检索（面板里仍会列出来，只是点不动）。
      if (!usableForContent(s)) return;
      // FAIL_LEDGER（第 8 条）：这个源正在冷却 —— 批量检索跳过它，
      // 别让一轮搜索在死源上白等。用户主动点进详情 / 播放不受影响。
      if (_failures.shouldSkip(s.key)) return;
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
        usableForContent(s) &&
        !(s.kind == KSourceKind.jar && _jarReady == false) &&
        // 冷却中的源不参与本轮（`SourceFailureLedger`）。
        !_failures.shouldSkip(s.key);
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

  /// 一份 [FxSite] → 我们自己的源（导入 TVBox 时用）。
  KSource _sourceOf(
    FxSite site, {
    required String key,
    required String tag,
    required KSourceOrigin origin,
    required bool builtin,
  }) {
    final kind = kindOf(site.type);
    return KSource(
      key: key,
      name: site.name,
      api: site.api,
      kind: kind,
      origin: origin,
      builtin: builtin,
      enabled: true,
      tag: tag,
      reason: _reasonOf(site.type, kind),
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

  /// 恢复**单个**被删掉的云端源（片源管理「已移除」分组里的「恢复」）。
  ///
  /// RESTORE_ONE（2026-11-17）：用户要的是「删错了能挑一条恢复」，
  /// 不想为了一条源把其它删掉的全放回来 —— 那等于把「删」白做一遍。
  Future<void> restoreCloud(String key) async {
    final k = key.trim();
    if (k.isEmpty || !_removed.contains(k)) return;
    _removed = <String>{..._removed}..remove(k);
    await _saveRemoved();
    notifyListeners();
  }

  /// 这个源的「恢复」是否可用（被删掉、且云端配置里还有它）。
  bool canRestoreCloud(String key) => isRemoved(key);

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
    _installCmsProfiles();
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
    _installCmsProfiles();
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
    _installCmsProfiles();
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
    final config = await _loadTvBoxConfig(
      text,
      timeout: timeout ?? const Duration(seconds: 12),
      depth: 0,
    );
    if (config.sites.isEmpty) {
      throw ApiException(
        _lastConfigHint.isEmpty ? '没解析到 sites 数组，检查一下配置内容' : _lastConfigHint,
      );
    }
    // 协议面先装上：parses / rules / hosts / doh 与导入是同一份配置里的东西，
    // 少装一步就是「源导进来了，但解析器一个都没注册」（第 1 条）。
    _applyProtocolSections(config);
    _lastConfigHint = '';

    final notes = <String>[];
    final added = <KSource>[];
    // 去重键：普通源看地址；jar 源看「类名 + ext」（同类不同 ext 是不同的站点）。
    final taken = <String>{
      for (final s in _user)
        s.kind == KSourceKind.jar ? '${s.api.trim()}|${s.ext}' : s.api.trim(),
    };
    var skipped = 0;
    var selfSkipped = 0;
    var jarNotice = false;
    for (final site in config.sites) {
      final name = site.name;
      final api = site.api;
      final kind = kindOf(site.type);
      // 排除指向本站接口的源：那是 App 内置的七个源（幻想腾讯/全部线路/4K/
      // 1080P/爱奇艺/量子/红牛），导入云端配置时再进来一份只会让源列表重复。
      if (_isOurOwnApi(api)) {
        selfSkipped++;
        continue;
      }
      if (kind == KSourceKind.unsupported) {
        skipped++;
        notes.add('「$name」${_reasonOf(site.type, kind)}，已跳过');
        continue;
      }
      if (kind == KSourceKind.live) {
        skipped++;
        notes.add('「$name」是直播列表，请到「直播」页添加');
        continue;
      }
      final dedupeKey = kind == KSourceKind.jar ? '$api|${site.ext}' : api;
      if (!taken.add(dedupeKey)) {
        skipped++;
        continue;
      }
      if (kind == KSourceKind.jar) jarNotice = true;
      added.add(_sourceOf(
        site,
        key: _newUserKey(name.isEmpty ? 'tvbox' : name),
        tag: tag,
        origin: KSourceOrigin.user,
        builtin: false,
      ));
    }
    if (selfSkipped > 0 && added.isEmpty) {
      throw ApiException('这份配置里的源都是本站内置的，没有需要导入的');
    }
    final withTimeout = added.where((s) => s.timeout > 0).length;
    final withHeader = added.where((s) => s.header.isNotEmpty).length;
    if (withTimeout > 0 || withHeader > 0) {
      notes.add('识别到 $withTimeout 个带 timeout、$withHeader 个带 header 的站点');
    }
    if (config.parses.isNotEmpty) {
      notes.add('导入 ${config.parses.length} 个解析器'
          '${config.flags.isEmpty ? '' : '、${config.flags.length} 条线路名'}');
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
      _installCmsProfiles();
      notifyListeners();
    }
    return TvBoxImport(
      added: added.length,
      skipped: skipped,
      notes: notes,
    );
  }

  /// 最近一次配置加载给不出的原因（导入报错要用它说人话）。
  String _lastConfigHint = '';

  /// 读一份配置（地址 / 文本都行），**递归展开 depot**，返回合并后的结果。
  ///
  /// DEPOT（第 1 条 · 壳 `VodConfig.parseDepot()`）：TVBox 生态里很常见一种
  /// 「订阅合集」配置 —— 顶层只有 `{urls: ["a.json", "b.json"]}`，
  /// 真正的站点在子配置里。我们原来只认 `sites`，这种配置一条都导不进来。
  ///
  /// 合并口径见 [TvBoxConfig.merge]；子配置的相对地址按父配置地址补全。
  Future<TvBoxConfig> _loadTvBoxConfig(
    String input, {
    required Duration timeout,
    required int depth,
    String baseUrl = '',
  }) async {
    if (depth > 3) {
      // 递归上限：配置互相引用（A→B→A）时不能无限拉。
      return const TvBoxConfig();
    }
    var body = input;
    var sourceUrl = baseUrl;
    if (input.startsWith('http://') || input.startsWith('https://')) {
      sourceUrl = input;
      try {
        final r = await http
            .get(requestUri(input), headers: const <String, String>{
              'accept': '*/*',
              // 猫源那类站按 UA 分流：浏览器 UA 给的是介绍页（HTML），
              // 播放器 UA 才给配置（肥猫给的就是加密配置）。
              'user-agent': tvBoxUserAgent,
            })
            .timeout(timeout);
        if (r.statusCode >= 400) throw ApiException.server(r.statusCode);
        // 加密配置是纯 ASCII 的 hex，用 bodyBytes 兜住乱码更稳。
        body = utf8.decode(r.bodyBytes, allowMalformed: true);
      } on TimeoutException {
        _lastConfigHint = '配置请求超时';
        throw ApiException.timeout();
      } on http.ClientException {
        _lastConfigHint = '配置地址连不上';
        throw ApiException.network();
      }
    }
    // 加密配置（`$#key#$` + AES-CBC）：先解出明文 JSON，再走下面同一套解析。
    final plain = decodeTvBoxConfig(body);
    final text = plain ?? body;
    Object? parsed;
    try {
      parsed = jsonDecode(text);
    } catch (_) {
      _lastConfigHint = '配置不是合法 JSON';
      return const TvBoxConfig();
    }
    // depot：`{urls:[…]}` → 逐个拉下来合并（第一个是主配置）。
    final depot = TvBoxConfig.depotUrlsOf(parsed);
    if (depot.isNotEmpty) {
      var merged = const TvBoxConfig();
      for (final url in depot) {
        final absolute = _resolveConfigUrl(url, sourceUrl);
        if (absolute.isEmpty) continue;
        try {
          final child = await _loadTvBoxConfig(
            absolute,
            timeout: timeout,
            depth: depth + 1,
            baseUrl: absolute,
          );
          merged = merged.merge(child);
        } catch (_) {
          // 子配置挂了不影响其它几份（合集里常年有一两条是死的）。
        }
      }
      return merged;
    }
    final config = TvBoxConfig.parse(parsed, baseUrl: sourceUrl);
    if (config.sites.isEmpty && plain == null && isTvBoxEncrypted(body)) {
      _lastConfigHint = '这份配置是加密的，但解不开（密文被截断或换了加密方式），换个地址试试';
    }
    return config;
  }

  /// depot 里的相对地址（`./a.json` / `../b.json` / `a.json`）按父配置补全。
  static String _resolveConfigUrl(String url, String baseUrl) {
    final text = url.trim();
    if (text.isEmpty) return '';
    if (text.startsWith('http://') || text.startsWith('https://')) return text;
    final base = Uri.tryParse(baseUrl.trim());
    if (base == null || !base.hasScheme) return '';
    final parsed = Uri.tryParse(text);
    if (parsed == null) return '';
    return base.resolveUri(parsed).toString();
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
      try {
        // 两种 quick 都在 [JarSpider.searchWithFallback] 里试过了，
        // 这里只给它一层「源级」兜底超时，别让某个源把整轮拖死。
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
      fxJarLog(
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
        for (final s in <KSource>[..._cloud, ..._user])
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
      final userRaw = sp.getString(_kUser);
      if (userRaw != null && userRaw.trim().isNotEmpty) {
        _user = _decodeList(userRaw);
      }
      final removedRaw = sp.getStringList(_kRemoved);
      if (removedRaw != null) _removed = removedRaw.toSet();
      _homeKey = (sp.getString(_kHomeSource) ?? '').trim();
      final pinnedRaw = sp.getStringList(_kPinned);
      if (pinnedRaw != null) _pinned = pinnedRaw.toSet();
      _bundledHidden = sp.getBool(_kBundledHidden) ?? false;
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
      await sp.setString(
        _kUser,
        jsonEncode(<Map<String, dynamic>>[for (final s in _user) s.toMap()]),
      );
      await sp.setString(_kLiveUrl, _liveUrl);
      await sp.setStringList(_kRemoved, _removed.toList());
      await sp.setString(_kHomeSource, _homeKey);
      await sp.setStringList(_kPinned, _pinned.toList());
      await sp.setBool(_kBundledHidden, _bundledHidden);
      await sp.setString(_kProtocol, jsonEncode(_protocol.protocolToMap()));
    } catch (_) {}
  }

  Future<void> _saveHomeSource() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kHomeSource, _homeKey);
    } catch (_) {}
  }

  Future<void> _savePinned() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setStringList(_kPinned, _pinned.toList());
    } catch (_) {}
  }

  Future<void> _saveBundledHidden() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_kBundledHidden, _bundledHidden);
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
    _homeKey = '';
    _pinned = <String>{};
    _bundledHidden = false;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(_kCloud);
      await sp.remove(_kUser);
      await sp.remove(_kRemoved);
      await sp.remove(_kLiveUrl);
      await sp.remove(_kFetchedAt);
      await sp.remove(_kAutoImported);
      await sp.remove(_kProtocol);
      await sp.remove(_kSourceFailure);
      await sp.remove(_kHomeSource);
      await sp.remove(_kPinned);
      await sp.remove(_kBundledHidden);
    } catch (_) {}
    _protocol = const TvBoxConfig();
    ParseRegistry.install(ParseRegistry.empty);
    FxSniffer.install(FxSniffer.none);
    FxAds.install(FxAds.none);
    JarSpider.setVipFlags(const <String>[]);
    CmsClient.installProfiles(const <String, CmsSiteProfile>{});
    await _failures.clear();
    notifyListeners();
  }
}

/// 任意值 → 去空白的文本（配置字段可能是 null / 数字 / 字符串）。
String _text(Object? raw) {
  if (raw == null) return '';
  return raw.toString().trim();
}

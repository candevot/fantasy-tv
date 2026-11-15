/// 嗅探规则（`rules`）的纯判定层（PROTOCOL_FACE 2026-11-15，移植阶段 1）。
///
/// 壳用 `rules` 回答一个问题：**一段地址是「能直接播的直链」还是「待解析的
/// 网页 / 令牌」**（`Sniffer.isVideoFormat()`）。我们原来靠后缀猜
/// （`play_path.dart` 的 `_mediaExt`），于是：
///   · 抖音 / 火山那类 `https://…/video/tos/cn…`（**没有** `.mp4` 后缀）
///     被当成网页去解析，解析器当然拿不到东西；
///   · 磁力 / 广告站那类「域名 + 关键词」的黑名单完全不生效，广告地址被当成
///     待播地址塞给播放器，白等一个超时窗口。
///
/// 规则形态（`bean/Rule.java:14-27`，与 TVBox 生态一致）：
/// ```json
/// {"name":"农民","hosts":["toutiaovod.com"],"regex":["video/tos/cn"]}
/// ```
///   · `hosts`  命中哪些域名（**子串或正则**，不是精确匹配）；
///   · `regex`  命中哪些关键词 / 正则 → 判定为「是视频地址」；
///   · `exclude` 命中即判定「不是视频地址」（优先级最高，先判）；
///   · `script` 网站的点击脚本（本阶段只保留，给后面的 WebView 嗅探用）。
///
/// 判定顺序照壳（`Sniffer.java:30-38`）：exclude → regex → 内置 SNIFFER 正则。
///
/// 这个文件只用 `dart:core` 的正则能力，**不 import flutter**，
/// `test/sniff_rules_test.dart` 和 `tools/probe_tvbox_config.dart` 可直接跑。
library;

/// 内置的「像视频地址」正则（壳 `Sniffer.SNIFFER` 的等价物，自己写的版本）。
///
/// 与壳保持同一形状：http(s) + 够长的路径 + 媒体后缀；额外认 `video/tos`
/// 这类无后缀的字节流地址（抖音 / 字节系 CDN 的形态）。
final RegExp _snifferPattern = RegExp(
  r'''https?://[^\s]{12,}\.(?:m3u8|mp4|mkv|flv|mp3|m4a|aac|mpd)(?:\?.*)?'''
  r'''|https?://.*?video/tos[^\s]*'''
  r'''|rtmp:[^\s]+''',
  caseSensitive: false,
);

/// 「一定不是视频直链」的形态（壳在 regex 全不命中后还会判这三条）。
bool _looksLikeWrapper(String url) {
  final text = url.toLowerCase();
  return text.contains('url=http') ||
      text.contains('v=http') ||
      text.contains('.html');
}

/// 一条嗅探规则。
class FxRule {
  const FxRule({
    this.name = '',
    this.hosts = const <String>[],
    this.regex = const <String>[],
    this.script = const <String>[],
    this.exclude = const <String>[],
  });

  final String name;
  final List<String> hosts;
  final List<String> regex;
  final List<String> script;
  final List<String> exclude;

  static const FxRule empty = FxRule();

  bool get isEmpty =>
      hosts.isEmpty && regex.isEmpty && script.isEmpty && exclude.isEmpty;

  static FxRule from(Object? raw) {
    if (raw is! Map) return empty;
    return FxRule(
      name: _text(raw['name']),
      hosts: _list(raw['hosts']),
      regex: _list(raw['regex']),
      script: _list(raw['script']),
      exclude: _list(raw['exclude']),
    );
  }

  /// 这条规则管不管这个 host（壳 `Util.containOrMatch`：先子串，再正则）。
  bool matchesHost(String host) {
    final want = host.trim().toLowerCase();
    if (want.isEmpty) return false;
    for (final item in hosts) {
      final key = item.trim().toLowerCase();
      if (key.isEmpty) continue;
      if (want == key || want.contains(key)) return true;
      final re = _tryRegExp(key);
      if (re != null && re.hasMatch(want)) return true;
    }
    return false;
  }
}

/// 一组嗅探规则 + 判定入口。
///
/// 全局只装一份（配置变更时替换），判定函数保持同步、无 IO —— 它在
/// 详情页 / 播放页 / 下载 / 一起看的路径上都会被问。
class FxSniffer {
  FxSniffer([List<FxRule> rules = const <FxRule>[]])
      : rules = List<FxRule>.unmodifiable(rules);

  /// 空规则表：所有判定都退回「按后缀 / 形态猜」，与改造前行为一致。
  static final FxSniffer none = FxSniffer();

  final List<FxRule> rules;

  /// 从配置的 `rules` 原始表构造。
  static FxSniffer fromConfig(Object? raw) {
    if (raw is! List) return FxSniffer.none;
    final out = <FxRule>[];
    for (final item in raw) {
      final rule = FxRule.from(item);
      if (rule.isEmpty) continue;
      out.add(rule);
    }
    return FxSniffer(out);
  }

  bool get isEmpty => rules.isEmpty;

  /// 这条地址命中的规则（没命中返回 [FxRule.empty]）。
  ///
  /// 壳的 host 判定会把地址自身的 host 和 `url=` 查询参数里的 host
  /// **拼在一起**做匹配 —— 解析器地址常把真实地址塞在 `?url=` 里，
  /// 只匹配外层 host 会漏掉全部二次跳转。
  FxRule ruleFor(String address) {
    if (rules.isEmpty) return FxRule.empty;
    final text = address.trim();
    if (text.isEmpty) return FxRule.empty;
    final hosts = <String>[];
    final uri = Uri.tryParse(text);
    if (uri != null) {
      if (uri.host.isNotEmpty) hosts.add(uri.host);
      final inner = uri.queryParameters['url'] ?? uri.queryParameters['v'];
      if (inner != null && inner.trim().isNotEmpty) {
        final innerUri = Uri.tryParse(inner.trim());
        if (innerUri != null && innerUri.host.isNotEmpty) hosts.add(innerUri.host);
      }
    }
    if (hosts.isEmpty) return FxRule.empty;
    for (final rule in rules) {
      for (final host in hosts) {
        if (rule.matchesHost(host)) return rule;
      }
    }
    return FxRule.empty;
  }

  /// 这条规则给的点击脚本（WebView 嗅探用；本阶段只透出，不执行）。
  List<String> scriptsFor(String address) => ruleFor(address).script;

  /// 这段地址是不是「直接的视频地址」。
  ///
  /// [rulesEmptyFallback] 在没有规则可用时由调用方决定怎么判 —— 这里直接
  /// 走「内置 SNIFFER 正则」，也就是壳在规则全不命中时的行为。
  bool isVideoFormat(String address) {
    final text = address.trim();
    if (text.isEmpty) return false;
    final rule = ruleFor(text);
    for (final item in rule.exclude) {
      final key = item.trim();
      if (key.isEmpty) continue;
      if (text.contains(key)) return false;
      final re = _tryRegExp(key);
      if (re != null && re.hasMatch(text)) return false;
    }
    for (final item in rule.regex) {
      final key = item.trim();
      if (key.isEmpty) continue;
      if (text.contains(key)) return true;
      final re = _tryRegExp(key);
      if (re != null && re.hasMatch(text)) return true;
    }
    if (_looksLikeWrapper(text)) return false;
    return _snifferPattern.hasMatch(text);
  }

  /// 命中规则名（日志 / 排查用；没命中返回空串）。
  String ruleNameOf(String address) => ruleFor(address).name;

  /* ---------------------------------------------------------- 全局实例 */

  static FxSniffer _active = FxSniffer.none;

  /// 当前生效的规则表（配置刷新时由 [install] 换掉）。
  ///
  /// 与 `ParseRegistry.active` 同样的理由：直链判定在详情页 / 播放页 / 下载 /
  /// 一起看四条链路都被问到，全局一份最省事，且语义上它本来就是「配置」。
  static FxSniffer get active => _active;

  /// 装一份规则表（配置解析完调一次）。
  static void install(FxSniffer sniffer) {
    _active = sniffer;
  }

  /// 单测用：恢复空表。
  static void resetForTest() {
    _active = FxSniffer.none;
  }
}

String _text(Object? raw) {
  if (raw == null) return '';
  if (raw is String) return raw.trim();
  return '$raw'.trim();
}

List<String> _list(Object? raw) {
  if (raw == null) return const <String>[];
  if (raw is String) {
    final text = raw.trim();
    return text.isEmpty ? const <String>[] : <String>[text];
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

/// 把一段文本当正则编译；不像正则 / 编译失败就返回 null（只做子串匹配）。
RegExp? _tryRegExp(String pattern) {
  if (pattern.isEmpty) return null;
  // 没有任何正则元字符的，走子串匹配就够了，也避免 `[` 这类半截正则抛异常。
  if (!RegExp(r'[\\^$.|?*+()\[\]{}]').hasMatch(pattern)) return null;
  try {
    return RegExp(pattern, caseSensitive: false);
  } catch (_) {
    return null;
  }
}

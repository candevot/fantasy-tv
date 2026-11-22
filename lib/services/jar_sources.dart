/// jar 源（TVBox `type: 3`）的**启用白名单 + 内置源目录 + 融合索引**。
///
/// 这一层是 JAR_RESTORE（2026-11-21）新增的「闸门」，被删掉的那几个服务
/// （`jar_spider` / `jar_plugin` / `jar_log` / `tvbox_crypto` / `search_group`）
/// 本身原样恢复，不改；能不能用、用哪几个，全部由这里决定：
///
///   1. [kEnabledJarSources] —— 用户点名的源（按**源名**匹配，兼容配置里
///      `咕噜 • APP` 这类带后缀的写法，见 [fxJarLabelOf]）；
///   2. [kBuiltinJarSources] —— 内置目录。云端 `/api/config` 只下发了一条
///      CMS 源，没有 jar 站点，所以这四个源的类名 / `ext` 内置在这里
///      （取值来自服务器上的 `hx_all.json`，2026-11-16 实测口径）；
///   3. [JarMergeIndex] —— 搜索期的融合索引：哪部片在哪个 jar 源里也有，
///      详情页据此把 jar 的子线路合并进我们那条记录。
///
/// **不恢复的行为**（用户没要）：TVBox 配置导入、首页 / 分类 / 排行榜使用
/// jar 源。这里只为「搜索 + 详情 + 播放解析」服务。
///
/// 启动自动安装 spider.jar 的口径在 JAR_BOOT（2026-11-21）**改回来了**：
/// 用户要求「首次进 App 自动装」，实现放在 `jar_plugin.dart`
/// （`JarPluginManager.bootSilently`），不在这一层。
library;

import '../models.dart';
import 'fallback_match.dart' show fxNormTitle;

/// 用户挑中的 jar 源（**默认启用名单**，也是设置页「片源管理」的唯一内容）。
///
/// 空列表 = 全部不启用（保留这个语义：清空名单就退回「没有 jar 源」）。
/// 匹配是「源名前缀」：配置里叫 `咕噜 • APP` 也能命中 `咕噜`。
/// 白名单：**只放服务器上实测真能出线路的源**（2026-11-21 服务器 jar 实测）。
///
///   · `咕噜`（`csp_Gulu`，ext 空）—— search/detail 全通，八仙 15 条线路；
///   · `剧圈`（App99 系 + host/buildSignature）—— 两参 search 通，济公传 2 条，
///     但必须带真 `ext`，稳定性不如咕噜，**暂不启用**；
///   · `橘汁`（AppDrama 系）—— homeContent 正常但 searchContent **恒空**
///     （换关键词 / 换 ext 都空），已从白名单去掉；
///   · `下饭`（JuXiaFan 系）—— searchContent 25～49 秒后回空列表，已去掉。
///
/// 去掉的源**不再出现在任何界面**：不显示大类、不置灰、不占位。
// KEEP_GULU_ONLY（2026-11-21）：用户最终只要「咕噜」一个 jar 源。
// 剧圈/橘汁/下饭 实测不可用（剧圈要特殊两参+真 ext 才行、橘汁搜索恒空、下饭类损坏），
// 一律不入白名单。
const List<String> kEnabledJarSources = <String>['咕噜'];

/// 内置 jar 源目录：类名 + `ext`。
///
/// 这份只是**兜底**（接口 `hx_all.json` 和本地缓存都拿不到时用它，
/// 见 `jar_config.dart`）。现在只有「咕噜」一条：`csp_Gulu` 不需要 `ext`。
///
/// KEEP_GULU_ONLY（2026-11-21）：剧圈那条（App99 系 + 真 `ext`）已经**从内置
/// 目录删除** —— 它必须带 host / 包名 / 签名才不抛 `Empty key`，而用户最终只要
/// 咕噜一个源。留个注释备查，别让它悄悄回到兜底里：
/// ```
/// // 剧圈（App99 系 jar 类，key: '剧圈', name: '剧圈 • APP'）
/// ext: '{"host":"http://124.221.3.182:19987/app/bn","versionName":"1.2.0",'
///      '"name":"剧圈圈","package":"com.qingtangxiaozhuan.xyz","buildNumber":"2002",'
///      '"buildSignature":"054FA8DDA4319C6B6A9B954CA5777541C993F00B1B0BD4394F7EDE48184C4594"}'
/// ```
class FxJarSourceDef {
  const FxJarSourceDef({
    required this.key,
    required this.name,
    required this.api,
    this.ext = '',
  });

  /// 源的稳定 key（= 用户点名的短名，同时也是线路名的大类前缀）。
  final String key;

  /// 配置里的完整名字（`咕噜 • APP`）。
  final String name;

  /// jar 里的类名（`csp_Gulu`）。
  final String api;

  /// TVBox 的 `ext`：字符串或 JSON 串，原样交给 jar。
  final String ext;

  Map<String, Object?> toMap() => <String, Object?>{
        'key': key,
        'name': name,
        'api': api,
        'type': 3,
        if (ext.isNotEmpty) 'ext': ext,
      };
}

/// 内置目录（只放白名单里那几个；别的肥猫源一概不出现）。
///
/// KEEP_GULU_ONLY：只剩咕噜一条（剧圈那条已删，见上面的注释）。
const List<FxJarSourceDef> kBuiltinJarSources = <FxJarSourceDef>[
  FxJarSourceDef(key: '咕噜', name: '咕噜 • APP', api: 'csp_Gulu'),
];

/// 白名单匹配：源名 / key 以名单里的某一项**开头**即命中。
///
/// 线上配置名字长这样：`咕噜 • APP`、`🕊┃︎咕噜┃APP`、`剧圈 • APP`，
/// 去掉 emoji 与分隔符后按前缀比，不要求逐字相等。
String fxJarLabelOf(String nameOrKey) {
  final raw = nameOrKey.trim();
  if (raw.isEmpty) return '';
  if (kEnabledJarSources.contains(raw)) return raw;
  final cleaned = _stripDecor(raw);
  for (final label in kEnabledJarSources) {
    if (cleaned.startsWith(label)) return label;
  }
  return '';
}

/// 去掉 emoji / 分隔符 / 隐形字符，只留文字与数字（比对用）。
String _stripDecor(String raw) {
  final buf = StringBuffer();
  for (final rune in raw.runes) {
    final ch = String.fromCharCode(rune);
    if (RegExp(r'[\u4e00-\u9fa5A-Za-z0-9]').hasMatch(ch)) buf.write(ch);
  }
  return buf.toString();
}

/// 白名单里的源名（给 UI 展示大类标题用）。
List<String> get kJarLabels => kEnabledJarSources;

/* -------------------------------------------------- 设置页的源状态 */

/// 一个 jar 源在「设置 → 片源管理」里的状态。
///
/// 用户口径（2026-11-21）：「显示每个源的状态：可用 / jar 未安装 / 已停用」。
/// 三种状态互斥，判定顺序见 [fxJarSourceStateOf]。
enum FxJarSourceState {
  /// jar 已装 + 源开着 → 搜索 / 详情会向它发请求。
  available,

  /// 源开着，但 spider.jar 没装 → 线路一条都出不来（chips 置灰）。
  jarMissing,

  /// 用户自己关掉了这个源。
  disabled,
}

/// 状态判定：**用户关掉的优先显示「已停用」**。
///
/// 一个关掉的源为什么置灰，用户自己刚改过，比「jar 没装」更直接；
/// 反过来，一个开着的源置灰才是 jar 的问题 —— 那才需要提示去装。
FxJarSourceState fxJarSourceStateOf({
  required bool installed,
  required bool enabled,
}) {
  if (!enabled) return FxJarSourceState.disabled;
  return installed ? FxJarSourceState.available : FxJarSourceState.jarMissing;
}

/// 状态的展示文案（`可用` / `jar 未安装` / `已停用`）。
String fxJarSourceStateLabel(FxJarSourceState state) => switch (state) {
      FxJarSourceState.available => '可用',
      FxJarSourceState.jarMissing => 'jar 未安装',
      FxJarSourceState.disabled => '已停用',
    };

/// 「我们自己的线路」那个大类的 key。
const String kOwnLineGroupKey = 'own';

/// 我们自己的线路在两大类里的显示名。
const String kOwnLineGroupLabel = '幻想';

/// 子线路名和大类名完全相同时的显示名。
///
/// 服务端采集入库的 `vod_play_from` 里有一条**裸名字** `咕噜`（咕噜 4K 经
/// playerContent 解析后的主线路，见 `glu_collect.php`）。它属于「咕噜」大类，
/// 第二行再显示一次「咕噜」纯属重复，所以显示成「默认」。
const String kBareLineSubName = '默认';

/* ------------------------------------------------------------ 线路 id */

/// jar 线路 id 的标记前缀：`jar::<源名>::<jar 的 vod_id>::<线路 flag>`。
///
/// 为什么要编码：jar 的线路 id 和自有线路的 id 是两套编号，播放时必须知道
/// 「哪条线路属于哪个 jar 源、jar 里是哪部片、哪一段 flag」才能现场解析。
/// 编码进 id 之后，播放器 / 历史 / 房间线路都能原样透传，不需要额外的会话状态。
const String kFxJarLineMark = 'jar::';

/// 组装 jar 线路 id。
String fxJarLineId(String label, String vodId, String from) =>
    '$kFxJarLineMark${Uri.encodeComponent(label)}::'
    '${Uri.encodeComponent(vodId)}::${Uri.encodeComponent(from)}';

/// 一条 jar 线路的身份。
class FxJarLineRef {
  const FxJarLineRef({
    required this.label,
    required this.vodId,
    required this.from,
  });

  /// 白名单里的源名（咕噜 / 橘汁 / 剧圈 / 下饭）。
  final String label;

  /// jar 源里的 `vod_id`。
  final String vodId;

  /// jar 的线路 flag（= `vod_play_from` 那一段）。
  final String from;

  @override
  String toString() => 'FxJarLineRef($label, $vodId, $from)';
}

/// 解析 jar 线路 id；不是 jar 线路返回 null。
FxJarLineRef? fxParseJarLineId(String id) {
  final text = id.trim();
  if (!text.startsWith(kFxJarLineMark)) return null;
  final parts = text.substring(kFxJarLineMark.length).split('::');
  if (parts.length < 3) return null;
  String dec(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }

  final label = dec(parts[0]).trim();
  final vodId = dec(parts[1]).trim();
  final from = dec(parts.sublist(2).join('::')).trim();
  if (label.isEmpty || vodId.isEmpty) return null;
  return FxJarLineRef(label: label, vodId: vodId, from: from);
}

/// 这条线路是不是 jar 源的线路。
bool fxIsJarLine(LineInfo line) => fxParseJarLineId(line.id) != null;

/* ------------------------------------------------------------ 大类分组 */

/// 线路名 → 大类（返回空串 = 不属于任何 jar 大类，归「幻想」）。
///
/// LINE_PREFIX（2026-11-21 用户实测 bug）：服务端采集入库的线路名**本身就带
/// 源名前缀** —— 库里 `vod_play_from` 有 `咕噜`、`咕噜·量子资源`、`咕噜·暴风资源`。
///
/// 旧实现只认 `咕噜·`（**必须带分隔符**），于是裸名字那条 `咕噜` 落进了
/// 「幻想」大类：详情页第一行选中「幻想」、第二行赫然出现「咕噜 / 幻想爱奇艺
/// / 红牛」，而且「咕噜」被高亮 —— 就是用户截图里那个错。
///
/// 现在按**前缀**判，分隔符可有可无：
///   · `咕噜`、`咕噜·量子资源`、`咕噜·4K`  → 咕噜大类
///   · `剧圈·…`、`橘汁·…`、`下饭·…`        → 各自的 jar 大类
///   · `量子`、`SH4K`、`幻想爱奇艺`、`红牛`  → 幻想大类
///
/// 注意 `咕噜·量子资源`（咕噜源自己的子线路）和自有的 `量子` 是**两条不同的
/// 线路**：前者进咕噜大类、后者留在幻想大类，两者互不影响、也不许互相覆盖。
String fxLineGroupLabelOfName(String name) {
  final raw = name.trim();
  if (raw.isEmpty) return '';
  // 装饰字符（emoji / 竖线 / 空格）先剥掉再比：`🕊┃︎咕噜┃APP` 也算咕噜。
  final plain = _stripDecor(raw);
  for (final label in kEnabledJarSources) {
    if (raw.startsWith(label) || plain.startsWith(label)) return label;
  }
  return '';
}

/// 一条线路属于哪个大类：`own` 或白名单源名。
///
/// **只认 jar 线路 id**（`jar::<源名>::…`），不看线路名。
///
/// JAR_ONLY_BY_ID（2026-11-21 用户实测 bug）：上一版按名字前缀分（`咕噜·暴风
/// 资源` → 咕噜大类），结果**我们自己采集入库的线路**（库里 `vod_play_from`
/// 真的就叫 `咕噜` / `咕噜·暴风资源` / `咕噜·量子资源`）被塞进了 jar 大类，
/// 冒充成「咕噜的子线路」——用户在详情页看到的「暴风资源」「默认」就是它们，
/// 而 jar 真返回的 `咕噜·4K` / `咖啡4K超清` / `金牌极速` … 一条都没出现。
///
/// 现在：CMS 采集线路**永远**归「幻想」大类，只有 `JarSpider` 产出的、
/// 带 `jar::` 前缀的线路才进对应 jar 源的大类。
String fxLineGroupKeyOf(LineInfo line) {
  final ref = fxParseJarLineId(line.id);
  if (ref == null) return kOwnLineGroupKey;
  return kEnabledJarSources.contains(ref.label) ? ref.label : kOwnLineGroupKey;
}

/// 前缀后面紧跟的分隔符（`咕噜·4K` / `咕噜 4K` / `咕噜-4K` / `咕噜|4K`）。
final RegExp _fxLinePrefixSep = RegExp(r'^[·・•‧∙⋅|｜/／\-–—_~～\s]+');

/// 一个大类（源）以及它下面的子线路。
class FxLineGroup {
  const FxLineGroup({
    required this.key,
    required this.label,
    required this.lines,
    required this.own,
    this.pending = false,
  });

  final String key;
  final String label;
  final List<LineInfo> lines;
  final bool own;

  /// JAR_PENDING（2026-11-22）：这个大类**正在取线路**（还没拿到）。
  ///
  /// 第一行先按「加载中」占位显示，拿到就原地填充（[lines] 变成真线路、
  /// [pending] 变回 false）；这部片在该源里没有的话，整个大类直接消失。
  /// 只有「jar 已就绪 + 源已启用」时才可能 pending —— 没装 jar 不许有占位，
  /// 否则第一行会永远挂着一个转圈的「咕噜」。
  final bool pending;

  /// 能不能点（有子线路才能点；pending 只能看）。
  bool get available => lines.isNotEmpty;

  @override
  String toString() =>
      'FxLineGroup($label, ${lines.length}${pending ? ', pending' : ''})';
}

/// 把线路按大类切好：**「幻想」+ 真的有线路的 jar 源**。
///
/// JAR_APPEAR_ON_DATA（2026-11-21 用户口径）：
///
/// > 每个片源搜索出来，点进去播放详情，里面有的话就跳出来线路，没有的话就消失。
///
/// 所以不再固定五个大类：某个 jar 源这部片没搜到 / 详情没线路，它那一格
/// **整条不出现** —— 不置灰、不占位、不显示「暂无线路」。只有真拿到子线路
/// 的源才出现在第一行（用户看到的灰 chip 全是这种「假占位」）。
/// [pendingLabels]：**正在取线路**的那些源（JAR_PENDING 2026-11-22）。
///
/// 进详情页时 jar 是就绪的，但这个片名还得异步去 jar 里搜一次（几百毫秒到
/// 十几秒）。以前这段等待是「空白」：第一行只有幻想，用户以为没有咕噜，
/// 等线路补上来，大类突然冒出来、顺序还整体右移 —— 就是「先显示幻想再跳成
/// 咕噜」的错位。现在 pending 标签按原顺序先占位（`咕噜 · 加载中`），
/// 拿到线路原地填充；没有就整条消失、回落到幻想。
///
/// pending 只对**白名单里、且还没有真线路**的标签生效 —— 已经拿到线路的源
/// 不会被 pending 覆盖成占位。
List<FxLineGroup> fxLineGroups(
  List<LineInfo> lines, {
  Iterable<String> pendingLabels = const <String>[],
}) {
  final own = <LineInfo>[];
  final byLabel = <String, List<LineInfo>>{
    for (final label in kEnabledJarSources) label: <LineInfo>[],
  };
  for (final line in lines) {
    final key = fxLineGroupKeyOf(line);
    if (key == kOwnLineGroupKey) {
      own.add(line);
    } else {
      byLabel.putIfAbsent(key, () => <LineInfo>[]).add(line);
    }
  }
  final pending = <String>{
    for (final label in pendingLabels)
      if (kEnabledJarSources.contains(label)) label,
  };
  // GROUP_ORDER（2026-11-22）：用户要求「优先使用咕噜」——
  // 有线路的 jar 源排在前面，幻想（自有）排在最后。
  // 这样默认选中/默认播放的就是咕噜的第一条子线路。
  return <FxLineGroup>[
    for (final label in kEnabledJarSources)
      if ((byLabel[label] ?? const <LineInfo>[]).isNotEmpty)
        FxLineGroup(
          key: label,
          label: label,
          lines: byLabel[label]!,
          own: false,
        )
      else if (pending.contains(label))
        FxLineGroup(
          key: label,
          label: label,
          lines: const <LineInfo>[],
          own: false,
          pending: true,
        ),
    if (own.isNotEmpty)
      FxLineGroup(
        key: kOwnLineGroupKey,
        label: kOwnLineGroupLabel,
        lines: own,
        own: true,
      ),
  ];
}

/// 默认该播哪一条：**咕噜的第一个大类里的第一条子线路**，没有就 null。
///
/// JAR_FIRST（2026-11-22 用户口径）：「优先使用咕噜」。这里只回答「有咕噜
/// 该选哪条」，没有咕噜时返回 null，调用方回落到原来的健康度默认线
/// （`LineHealth.defaultLine`）—— 绝不替它做决定、也不碰死线路判断。
/// 子线路默认优先顺序（JAR_SUB_ORDER 2026-11-22 实测）。
///
/// 《八仙》15 条子线路实测：只有 `咕噜4K` 和 `暴风资源` 真能播 ——
/// 暴风资源首片 577KB/238ms/2371KB/s，咕噜4K 首片 1MB/2293ms/447KB/s，
/// 其余（咖啡4K 404 / 玫瑰4K 404 / 金牌极速 403 / 电影天堂 404 /
/// 量子资源 404 / 非凡资源 404 / 蚂蚁 Parse Failed / 旋风 Parse Failed）
/// 全部不可播。默认线路优先挑这条快线，挑不到才按原顺序。
const List<String> kJarSubLinePreference = <String>['暴风资源', '咕噜4K'];

LineInfo? fxJarDefaultLine(List<LineInfo> lines) {
  final groups = fxLineGroups(lines);
  for (final group in groups) {
    if (group.own || group.lines.isEmpty) continue;
    for (final want in kJarSubLinePreference) {
      for (final line in group.lines) {
        if (line.displayName.contains(want) || line.id.contains(want)) {
          return line;
        }
      }
    }
    return group.lines.first;
  }
  return null;
}

/// 子线路的显示名：去掉 `<大类>` / `<大类>·` 前缀（前缀已经在第一行体现）。
///
/// · `咕噜·量子资源` 在咕噜大类下 → `量子资源`；
/// · 名字就是大类名（裸 `咕噜`）→ [kBareLineSubName]（`默认`），否则第二行
///   会出现一条和大类一字不差的 chip；
/// · 大类是「幻想」时**只剥带分隔符的写法**：`幻想爱奇艺` 原样显示，
///   剥掉就只剩「爱奇艺」，用户会以为那是另一个源。
String fxLineSubName(LineInfo line, String groupLabel) {
  final full = line.displayName.trim();
  if (full.isEmpty) return line.id;
  final label = groupLabel.trim();
  if (label.isEmpty) return full;
  if (full == label) return kBareLineSubName;
  if (!full.startsWith(label)) return full;
  var rest = full.substring(label.length);
  final cut = _fxLinePrefixSep.firstMatch(rest);
  if (cut != null) {
    rest = rest.substring(cut.end);
  } else if (!kEnabledJarSources.contains(label)) {
    // 「幻想」大类：只剥 `幻想·xxx` 这种带分隔符的写法。
    return full;
  }
  rest = rest.trim();
  return rest.isEmpty ? kBareLineSubName : rest;
}

/// 自有线路在前、jar 线路在后（同组内保持原顺序）。
///
/// `LineHealth.rankLines` 会把「未知」档排在「已知坏」前面，jar 线路没有
/// 预检档案、恒为未知档，于是可能插到自有死线路前面。用户口径是
/// 「自有线路永远在前」，所以排序之后再过这一道稳定分区。
List<LineInfo> fxOwnLinesFirst(List<LineInfo> lines) {
  final own = <LineInfo>[];
  final jar = <LineInfo>[];
  for (final line in lines) {
    (fxIsJarLine(line) ? jar : own).add(line);
  }
  if (jar.isEmpty) return lines;
  return <LineInfo>[...own, ...jar];
}

/// 搜索期一条 jar 结果的归宿。
enum FxJarHitAction {
  /// 我们库里已经有这部片（片名 + 年份对得上）：只合并线路，不新增卡片。
  merge,

  /// 我们库里没有：作为新条目上屏（详情 / 播放都走 jar 通道）。
  add,
}

/// 判定一条 jar 搜索结果的归宿（纯函数，`test/jar_fusion_test.dart` 逐条钉住）。
FxJarHitAction fxJarAction({
  required String title,
  required int year,
  required Set<String> ownKeys,
}) {
  final key = JarMergeIndex.keyOf(title, year);
  if (key.isNotEmpty && ownKeys.contains(key)) return FxJarHitAction.merge;
  return FxJarHitAction.add;
}

/* ------------------------------------------------------------ 融合索引 */

/// 一部片在某个 jar 源里的位置。
class FxJarHit {
  const FxJarHit({
    required this.label,
    required this.vodId,
    required this.title,
    required this.year,
  });

  final String label;
  final String vodId;
  final String title;
  final int year;

  @override
  String toString() => 'FxJarHit($label, $vodId)';
}

/// 搜索期的融合索引：**片名 + 年份** → 哪些 jar 源也有这部片。
///
/// 只在内存里、按搜索词滚动覆盖（每次新搜索清空旧的），不落盘：
/// 它表达的是「刚才这一轮搜索里 jar 源命中了什么」，重启后没有意义 ——
/// 详情页拿不到索引时自然就只有自有线路，不会凭空多出线路。
class JarMergeIndex {
  JarMergeIndex._();

  static final JarMergeIndex instance = JarMergeIndex._();

  /// 上限：一部片最多记这么多条（超出说明这个源在灌重复数据）。
  static const int maxHitsPerTitle = 12;

  final Map<String, List<FxJarHit>> _byTitle = <String, List<FxJarHit>>{};

  /// 融合键：归一化片名 + 年份（与「首页 / 搜索去重」同一口径）。
  static String keyOf(String title, int year) {
    final norm = fxNormTitle(title);
    if (norm.isEmpty) return '';
    return '$norm|${year > 0 ? year : 0}';
  }

  void clear() => _byTitle.clear();

  /// 记一条：某个 jar 源里也有这部片（同源同片只记一次）。
  void attach({
    required String title,
    required int year,
    required String label,
    required String vodId,
  }) {
    final key = keyOf(title, year);
    if (key.isEmpty || label.isEmpty || vodId.isEmpty) return;
    final list = _byTitle.putIfAbsent(key, () => <FxJarHit>[]);
    for (final hit in list) {
      if (hit.label == label && hit.vodId == vodId) return;
      if (hit.label == label) {
        // 同一个源换了记录 id：以最新一次搜索为准。
        list.remove(hit);
        break;
      }
    }
    if (list.length >= maxHitsPerTitle) list.removeAt(0);
    list.add(FxJarHit(
      label: label,
      vodId: vodId,
      title: title,
      year: year,
    ));
  }

  /// 这部片在 jar 源里的全部命中（按源名顺序，稳定）。
  List<FxJarHit> hitsFor({required String title, required int year}) {
    final exact = _byTitle[keyOf(title, year)];
    if (exact != null && exact.isNotEmpty) return List<FxJarHit>.of(exact);
    // 年份对不上时退一步按片名找：jar 常把年份写成 0 / 空，
    // 我们库里是 2016，硬比年份会把能合的片漏掉。
    final norm = fxNormTitle(title);
    if (norm.isEmpty) return const <FxJarHit>[];
    for (final entry in _byTitle.entries) {
      if (entry.key.startsWith('$norm|')) return List<FxJarHit>.of(entry.value);
    }
    return const <FxJarHit>[];
  }

  /// 这部片是不是已经在某个 jar 源里出现过（搜索期「合并 vs 新增」判定）。
  bool hasAny({required String title, required int year}) =>
      hitsFor(title: title, year: year).isNotEmpty;

  /// 调试 / 测试：当前记了多少条记录。
  int get length => _byTitle.length;
}

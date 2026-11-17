/// 搜索结果相关性判定（SEARCH_RELEVANCE 2026-11-15）。
///
/// 为什么需要：外部源（肥猫那 41 个 jar 源）的 `searchContent(key, quick)`
/// 并不保证「按 key 搜」。实测（`spider.jar` 反编译，md5 cbe016eb…，
/// `com.github.catvod.spider.Bili`，肥猫配置里 6 个站点都用它）：
///
/// ```java
/// // com.github.catvod.spider.Bili
/// public String searchContent(String str, boolean z) {
///     return categoryContent(str, "1", true, new HashMap<>());
/// }
/// ```
///
/// 它把**搜索词当成分类 id** 传进 `categoryContent`，站点对不存在的分类
/// 返回的是自己的首页 / 合集列表 —— 于是搜「济公传」会冒出「背着善宰跑」
/// 「与恶魔有约」这类完全无关的韩剧。jar 在进程内、我们改不了它，所以必须
/// 在客户端做最后一道判断。
///
/// 判据（GATE_RELAX 2026-11-15 —— **放宽但不能没有底线**）：
///   1. 归一化后片名包含关键词 → 相关（`济公传[电影解说]` / `济公传(2016)` /
///      `新编济公传` 归一化后照样含「济公传」，绝不要求「完全相等」）；
///   2. 关键词包含片名（搜「济公传全集」，片名是「济公传」）→ 相关；
///   3. 关键词的**任一分词**（中文二元组 / 英文单词）出现在片名里 → 相关
///      （「活佛济公」「济公新传」这类同一 IP 的变体都留）；
///   4. 以上都不满足 → 无关，丢掉。
///
/// 「解说 / 预告 / 花絮」这类二次创作**单独判断**（[fxIsExtraClip]），
/// 不参与上面的相关性判定：它们该不该显示由调用方决定，这里只负责把它们
/// 排在正片后面（[fxSearchGate] 的 `extraClips`）。
/// 之前把 `card.desc`（简介）当副标题一起判，简介里提一句关键词就能让一条
/// 完全无关的片混进来 —— 现在只认片名。
library;

import '../models.dart';
import 'fallback_match.dart' show fxIsExtraClip, fxNormTitle;
import 'jar_log.dart';

/// 判定为「相关」的最低分（保留给需要打分排序的调用方，闸门本身不用它
/// 做硬阈值 —— 见 [fxSearchRelevant]）。
const double kSearchRelevanceMin = .5;

/// 关键词 → 检索片段。
///
/// 中文按二元组切（「济公传」→ 济公 / 公传），英文 / 数字按单词切；
/// 单字中文不单独成词（「济」这种单字命中太容易误判）。
List<String> fxSearchTokens(String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const <String>[];
  final out = <String>[];
  for (final match in RegExp(r'[a-z0-9]+').allMatches(q)) {
    final word = match.group(0) ?? '';
    if (word.length >= 2) out.add(word);
  }
  final han = q.replaceAll(RegExp(r'[^\u4e00-\u9fa5]'), '');
  for (var i = 0; i + 2 <= han.length; i++) {
    out.add(han.substring(i, i + 2));
  }
  return out;
}

/// 片名与关键词的相关性，0（完全无关）~ 1（片名含关键词）。
double fxSearchScore(String title, String query) {
  final t = fxNormTitle(title);
  final q = fxNormTitle(query);
  if (t.isEmpty || q.isEmpty) return 0;
  if (t.contains(q)) return 1;
  if (q.contains(t)) return .95;
  var best = 0.0;
  for (final token in fxSearchTokens(q)) {
    if (token.length < 2) continue;
    if (!t.contains(token)) continue;
    final score = token.length >= 2 ? .8 : .6;
    if (score > best) best = score;
  }
  final jaccard = _jaccard(_bigrams(t), _bigrams(q));
  // 有片段命中时在 .8 之上再加一点相似度权重；没有命中就只看 Jaccard。
  if (best > 0) return (best + jaccard * .18).clamp(0.0, 1.0);
  return jaccard;
}

/// 这条片名算不算「和关键词相关」。
///
/// 规则见文件头：包含 / 被包含 / **任一分词命中** 三选一即可，
/// **不看**简介、**不要**完全相等。
bool fxSearchRelevant(
  String title,
  String query, {
  String alternativeTitle = '',
  double minScore = kSearchRelevanceMin,
}) {
  final q = fxNormTitle(query);
  if (q.isEmpty) return true;
  if (_titleHits(title, q)) return true;
  if (alternativeTitle.trim().isEmpty) return false;
  return _titleHits(alternativeTitle, q);
}

bool _titleHits(String title, String normalizedQuery) {
  final t = fxNormTitle(title);
  if (t.isEmpty) return false;
  if (t.contains(normalizedQuery) || normalizedQuery.contains(t)) return true;
  for (final token in fxSearchTokens(normalizedQuery)) {
    if (token.length < 2) continue;
    if (t.contains(token)) return true;
  }
  return false;
}

/// 一次闸门判定的结果：留下的、丢掉的、以及其中有多少是「解说 / 预告」。
///
/// 日志要用它说清「丢了几条、留了几条、为什么」（JAR_LOG 2026-11-15）：
/// `[JarSearch] gate source=哔哩合集 dropped=2 kept=3 reason=unrelated`。
class FxSearchGate {
  const FxSearchGate({
    required this.kept,
    required this.dropped,
    required this.extraClips,
  });

  const FxSearchGate.empty()
      : kept = const <VideoCard>[],
        dropped = 0,
        extraClips = 0;

  /// 相关的结果（正片在前，解说 / 预告这类排在后面，各自保持原顺序）。
  final List<VideoCard> kept;

  /// 被判成「无关」而丢掉的条数。
  final int dropped;

  /// [kept] 里属于解说 / 预告 / 花絮的条数（不再单独丢，只降位）。
  final int extraClips;

  bool get isEmpty => kept.isEmpty;
}

/// 过一遍闸门：[cards] 里留下和 [query] 相关的，解说 / 预告排到后面。
///
/// [cards] 为空或 [query] 为空时整批放行（空关键词不做判断）。
/// 这些词出现在片名/分类里，就说明是音频、曲艺、有声内容 —— 不是影视。
///
/// 搜「济公传」时 `明星 mv` 源灌进来的「长篇单口相声」「评书全集」
/// 「太平歌词」全属于这一类；不拦掉，用户看到的就是一屏无关结果。
const List<String> _kAudioWords = <String>[
  '相声', '评书', '单口', '对口', '群口', '太平歌词', '快板', '鼓书',
  '有声书', '有声小说', '听书', '音频', '电台', '广播剧',
  '戏曲', '京剧', '越剧', '黄梅', '豫剧', '梆子', '昆曲',
  '小品', '二人转', '脱口秀', '播客',
  // 曲艺现场 / 广播剧（三六零源常把德云社专场归成「综艺」灌进搜索结果）
  '书场', '钢丝节', '德云社', '广播剧', '大鼓', '琴书', '数来宝',
  'DJ', 'FM', '音乐', '歌曲', '演唱会', '伴奏', '纯音乐',
];

/// 这条卡片是不是「音频 / 曲艺 / 电台」这类非影视内容。
bool fxLooksLikeAudioContent(VideoCard card) {
  final hay = <String>[
    card.title,
    card.category,
    card.type,
    ...card.tags,
  ].join(' ').toLowerCase();
  for (final w in _kAudioWords) {
    if (hay.contains(w.toLowerCase())) return true;
  }
  return false;
}

FxSearchGate fxSearchGate(List<VideoCard> cards, String query) {
  final q = query.trim();
  if (cards.isEmpty || q.isEmpty) {
    return FxSearchGate(kept: cards, dropped: 0, extraClips: 0);
  }
  final main = <VideoCard>[];
  final clips = <VideoCard>[];
  var dropped = 0;
  for (final card in cards) {
    // NOT_FILM（2026-11-17）：**音频 / 曲艺内容一律丢掉**。
    //
    // 用户实测搜「济公传」，`明星 mv` 那个源回来 20 条全是「郭德纲｜长篇
    // 单口相声｜全本【济公传】」「郭德纲评书全集」——片名里确实有关键词，
    // 相关性闸门全放行，但那些不是影视，用户看到的就是「一堆无关的东西」。
    // 带这些词的一律当非影视处理。
    if (fxLooksLikeAudioContent(card)) {
      dropped++;
      continue;
    }
    if (!fxSearchRelevant(card.title, q)) {
      dropped++;
      continue;
    }
    // 解说 / 预告：判相关的规则**不参与**，这里只决定它排在哪。
    if (fxIsExtraClip(card.title)) {
      clips.add(card);
    } else {
      main.add(card);
    }
  }
  return FxSearchGate(
    kept: <VideoCard>[...main, ...clips],
    dropped: dropped,
    extraClips: clips.length,
  );
}

/// 闸门的日志行（JAR_LOG 2026-11-15）。
///
/// 格式固定，真机 `grep 'gate source='` 就能看出**哪个源**在灌无关数据：
/// `[JarSearch] gate source=哔哩合集 dropped=2 kept=3 clips=0 reason=unrelated`
void fxJarGateLog(String source, FxSearchGate gate) {
  final who = source.trim().isEmpty ? '?' : source.trim();
  final reason = gate.dropped > 0
      ? 'unrelated'
      : (gate.kept.isEmpty ? 'empty' : 'ok');
  fxJarLog(
    'gate source=$who dropped=${gate.dropped} kept=${gate.kept.length} '
    'clips=${gate.extraClips} reason=$reason',
  );
}

/// 过滤一批卡片：只留和 [query] 相关的（保留给老调用方）。
///
/// 新代码用 [fxSearchGate]：它同时给「丢了几条」，日志才能说清链路。
List<VideoCard> fxRelevantCards(List<VideoCard> cards, String query) =>
    fxSearchGate(cards, query).kept;

Set<String> _bigrams(String text) {
  final chars = text.split('');
  if (chars.length < 2) return <String>{if (text.isNotEmpty) text};
  final out = <String>{};
  for (var i = 0; i + 1 < chars.length; i++) {
    out.add('${chars[i]}${chars[i + 1]}');
  }
  return out;
}

double _jaccard(Set<String> a, Set<String> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  var inter = 0;
  for (final e in a) {
    if (b.contains(e)) inter++;
  }
  final union = a.length + b.length - inter;
  return union == 0 ? 0 : inter / union;
}

/// 搜索结果相关性判定（SEARCH_RELEVANCE 2026-11-15）。
///
/// 为什么需要：外部源（肥猫那 41 个 jar 源）的 `searchContent(key, quick)`
/// 并不保证「按 key 搜」。实测（`spider.jar` 反编译，md5 cbe016eb…）：
///
/// ```java
/// // com.github.catvod.spider.Bili（肥猫配置里 6 个站点都用它）
/// public String searchContent(String str, boolean z) {
///     return categoryContent(str, "1", true, new HashMap<>());
/// }
/// ```
///
/// 它把**搜索词当成分类 id** 传进 `categoryContent`，站点对不存在的分类
/// 返回的是自己的首页 / 合集列表 —— 于是搜「济公传」会冒出「背着善宰跑」
/// 「与恶魔有约」这类完全无关的韩剧。jar 在进程内、我们改不了它，所以必须
/// 在客户端做最后一道判断：**片名和关键词无关的结果不展示**。
///
/// 判据（宁可少一条，也不给一条明显不相干的）：
///   1. 归一化后片名包含关键词 → 1.0；
///   2. 关键词包含片名（搜「济公传全集」，片名是「济公传」）→ .95；
///   3. 关键词的中文二元组 / 英文单词命中片名 → ≥ .8；
///   4. 否则用二元组 Jaccard 相似度（0~1）。
///
/// 阈值 [kSearchRelevanceMin]：低于它就算「无关」，整条丢掉。
library;

import '../models.dart';
import 'fallback_match.dart' show fxNormTitle;

/// 判定为「相关」的最低分。
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
bool fxSearchRelevant(
  String title,
  String query, {
  String alternativeTitle = '',
  double minScore = kSearchRelevanceMin,
}) {
  if (fxSearchScore(title, query) >= minScore) return true;
  if (alternativeTitle.trim().isEmpty) return false;
  return fxSearchScore(alternativeTitle, query) >= minScore;
}

/// 过滤一批卡片：只留和 [query] 相关的。
///
/// [cards] 为空或 [query] 为空时原样返回（空关键词不做判断）。
List<VideoCard> fxRelevantCards(List<VideoCard> cards, String query) {
  final q = query.trim();
  if (cards.isEmpty || q.isEmpty) return cards;
  return <VideoCard>[
    for (final card in cards)
      if (fxSearchRelevant(card.title, q, alternativeTitle: card.desc))
        card,
  ];
}

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

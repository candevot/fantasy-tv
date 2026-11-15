/// 搜索结果的排序记分表（SEARCH_RANK，2026-11-15）。
///
/// 分辨率怎么算（三层）见 [stream_resolution.dart]；这里只做三件事：
///   1. 把「片名+年份 → 分数」记账（跨源同一按键，只升不降）；
///   2. 维护第三层缓存「播过一次就记住真实分辨率」（本地 prefs）；
///   3. 提供全局排序（分高 → 热度 → 更新时间）。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import 'stream_resolution.dart';

export 'stream_resolution.dart';

/// 第三层缓存：播放器上真正出过的分辨率与宽高（RES_LEARNED）。
///
/// 用户的诉求是「动态实时」：每部剧的每条线路实际分辨率都不一样，估不准。
/// 所以播放器一拿到 `onVideoSizeChanged` 的真实 `width×height` 就立刻写这里；
/// 下次搜索排序命中就用真实值，没命中才退回线路名推断。
///
/// 存储：SharedPreferences 一段 JSON（`fx_res_learned_v1`）
/// ```
/// { "sourceKey|lineName|vodId": {"w":1920,"h":1080,"t":1763000000000}, … }
/// ```
/// 条数上限 [maxEntries]（默认 5000），超了按 `t` 淘汰最旧的一批（LRU）。
/// 同一条线路不同集分辨率可能不同：键里不带集号，**取最新值**。
class LearnedResolution {
  LearnedResolution._();

  static const String _prefKey = 'fx_res_learned_v1';

  /// 最多记多少条（LRU：按时间戳淘汰）。
  static const int maxEntries = 5000;

  /// `sourceKey|lineName|vodId` → (宽, 高, 时间戳)
  static final Map<String, ResEntry> _map = <String, ResEntry>{};

  static bool _loaded = false;

  static String keyOf({
    required String sourceKey,
    required String lineName,
    required String vodId,
  }) =>
      '${sourceKey.trim()}|${lineName.trim()}|${vodId.trim()}';

  /// 读一次本地缓存（幂等；失败就当空表）。
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_prefKey);
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is Map) {
          final w = int.tryParse('${value['w']}') ?? 0;
          final h = int.tryParse('${value['h']}') ?? 0;
          final t = int.tryParse('${value['t']}') ?? 0;
          if (h > 0) _map['${entry.key}'] = ResEntry(w, h, t);
        } else {
          // 旧格式：只存了高度。
          final h = int.tryParse('$value') ?? 0;
          if (h > 0) _map['${entry.key}'] = ResEntry(0, h, 0);
        }
      }
    } catch (_) {
      // 缓存坏了就当没有：下次播放会重写。
    }
  }

  /// 查一条线路学到的分辨率高度；没有返回 null。
  static int? heightOf({
    required String sourceKey,
    required String lineName,
    required String vodId,
  }) =>
      _map[keyOf(sourceKey: sourceKey, lineName: lineName, vodId: vodId)]
          ?.height;

  /// 记一次真实分辨率（起播就写；分辨率变了才落盘）。
  static Future<void> remember({
    required String sourceKey,
    required String lineName,
    required String vodId,
    required int width,
    required int height,
  }) async {
    if (width <= 0 || height <= 0) return;
    final key = keyOf(sourceKey: sourceKey, lineName: lineName, vodId: vodId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final old = _map[key];
    if (old != null && old.width == width && old.height == height) {
      // 同一个分辨率：只刷新时间戳（保持 LRU 新鲜度），不重写整张表。
      _map[key] = ResEntry(width, height, now);
      return;
    }
    _map[key] = ResEntry(width, height, now);
    _evict();
    await _persist();
  }

  /// 超上限时按时间戳淘汰最旧的一批。
  static void _evict() {
    if (_map.length <= maxEntries) return;
    final keys = _map.keys.toList()
      ..sort((a, b) => _map[a]!.at.compareTo(_map[b]!.at));
    final drop = _map.length - maxEntries;
    for (var i = 0; i < drop && i < keys.length; i++) {
      _map.remove(keys[i]);
    }
  }

  static Future<void> _persist() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
        _prefKey,
        jsonEncode(<String, Map<String, int>>{
          for (final entry in _map.entries)
            entry.key: <String, int>{
              'w': entry.value.width,
              'h': entry.value.height,
              't': entry.value.at,
            },
        }),
      );
    } catch (_) {
      // 写盘失败：内存里的这一份本次会话仍然有效。
    }
  }

  /// 当前记了多少条（调试 / 单测）。
  static int get count => _map.length;

  static void clear() => _map.clear();
}

/// 一条学到的分辨率记录。
class ResEntry {
  const ResEntry(this.width, this.height, this.at);

  final int width;
  final int height;

  /// 写入时间（毫秒时间戳），LRU 淘汰用。
  final int at;
}

/* ------------------------------------------------------------ 记分表 */

/// 卡片 → 分数（记分表：按「片名 + 年份」索引，和跨源去重同一个键）。
///
/// 同一部片先到的来源记过分，后面别的来源再来同一条时**只升不降**：
/// 高画质的那条一旦出现，排序就以它为准。
class SearchRank {
  SearchRank._();

  static final Map<String, SearchScore> _scores = <String, SearchScore>{};

  static const int _limit = 4000;

  /// SOURCE_SPLIT（2026-11-15）：同一部剧现在会按片源拆成多条记录
  /// （hx=幻想 / xo=官采切片），各自带自己的线路 —— 分数必须按记录算，
  /// 否则两条会互相覆盖，排出来的顺序是随机的。
  static String keyOf(VideoCard card) =>
      '${_norm(card.title)}|${card.year}|${card.fromSource}';

  /// 记录一条记录的分数。
  static void record(
    VideoCard card, {
    required String playFrom,
    required String playUrl,
    String extraQuality = '',
    String vodId = '',
    String sourceKey = '',
  }) {
    final key = keyOf(card);
    if (key.isEmpty) return;
    // 第三层：把这部片每条线路「播过的真实分辨率」喂给打分函数。
    final lineNames = <String>[
      for (final part in playFrom.split(r'$$$')) part.trim(),
    ];
    final learned = <String, int>{};
    for (final name in lineNames) {
      final h = LearnedResolution.heightOf(
        sourceKey: sourceKey,
        lineName: name,
        vodId: vodId.isEmpty ? card.id : vodId,
      );
      if (h != null && h > 0) learned[name] = h;
    }
    final scored = scoreOfRecord(
      playFrom: playFrom,
      playUrl: playUrl,
      extraQuality: extraQuality,
      learnedHeightByLine: learned,
    );
    if (scored.lineCount == 0) return;
    final old = _scores[key];
    if (old != null && old.score >= scored.score) return;
    if (_scores.length >= _limit && !_scores.containsKey(key)) {
      _scores.remove(_scores.keys.first);
    }
    _scores[key] = scored;
  }

  /// 某个标题+年份的分数明细；没记过返回 null。
  static SearchScore? scoreOfCard(VideoCard card) => _scores[keyOf(card)];

  /// 排序用的数值（没记过 = 0 分，排最后）。
  static double scoreValue(VideoCard card) => _scores[keyOf(card)]?.score ?? 0;

  /// 全局排序：分高 → 热度 → 更新时间 → 保持原序（稳定）。
  static List<VideoCard> sort(List<VideoCard> src) {
    if (src.length < 2) return src;
    final indexed = <MapEntry<int, VideoCard>>[
      for (var i = 0; i < src.length; i++) MapEntry<int, VideoCard>(i, src[i]),
    ];
    indexed.sort((a, b) {
      final byScore = scoreValue(b.value).compareTo(scoreValue(a.value));
      if (byScore != 0) return byScore;
      final byHeat = _heat(b.value.heat).compareTo(_heat(a.value.heat));
      if (byHeat != 0) return byHeat;
      final byTime = b.value.time.compareTo(a.value.time);
      if (byTime != 0) return byTime;
      return a.key.compareTo(b.key);
    });
    return <VideoCard>[for (final entry in indexed) entry.value];
  }

  static void clear() => _scores.clear();

  static num _heat(String heat) {
    final text = heat.trim();
    if (text.isEmpty) return 0;
    if (text.endsWith('万')) {
      final n = double.tryParse(text.substring(0, text.length - 1));
      return n == null ? 0 : n * 10000;
    }
    return num.tryParse(text) ?? 0;
  }

  static String _norm(String raw) => raw
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\u3000·・•,，。.、:：;；!！?？\-—_/\\|｜()（）\[\]【】]'), '');
}

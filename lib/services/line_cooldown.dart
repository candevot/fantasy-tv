/// 线路「临时不可用」冷却期（AUTO_LINE_FULL 2026-11-15）。
///
/// 用户定稿的规则：
/// ```
/// ① 一条线路失败 → 立刻切下一条（不等用户）
/// ② 这条线路记「临时不可用」10 分钟，期间不再试
/// ③ 本次播放内：失败线路沉到最后
/// ④ 下次打开同一部剧：排序时「最近失败过」的排在同分辨率后面
/// ⑤ 10 分钟后恢复原权重（可能只是当时网络抖动）
/// ```
///
/// 这一层只负责记账与排序，不碰播放器：
///   · 键是 `videoId|线路名`（线路名来自 `LineInfo.displayName`，播放页与详情页
///     用的是同一套名字，所以两边都能查）；
///   · 存 SharedPreferences（`fx_line_cooldown_v1`），杀掉进程再进来仍然生效；
///   · 过期条目在读取时就被丢掉，不额外起定时器。
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import 'fallback_match.dart';
import 'play_log.dart';

class FxLineCooldown {
  FxLineCooldown._();

  static const String prefKey = 'fx_line_cooldown_v1';

  /// 最多记多少条（超出按失败时间淘汰最旧的）。
  static const int maxEntries = 2000;

  /// `videoId|线路名` → 失败时刻（毫秒时间戳）。
  static final Map<String, int> _failedAt = <String, int>{};

  static bool _loaded = false;
  static Future<void>? _loading;
  static bool _dirty = false;
  static Timer? _saveTimer;

  /// 记账键：`videoId|线路名`。
  static String keyOf(String videoId, String lineName) =>
      '${videoId.trim()}|${lineName.trim()}';

  /// 读一次本地缓存（幂等；坏数据当空表）。
  static Future<void> load() {
    if (_loaded) return Future<void>.value();
    final running = _loading;
    if (running != null) return running;
    final task = () async {
      try {
        final sp = await SharedPreferences.getInstance();
        final raw = sp.getString(prefKey);
        if (raw != null && raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            final now = DateTime.now().millisecondsSinceEpoch;
            for (final entry in decoded.entries) {
              final at = int.tryParse('${entry.value}') ?? 0;
              if (!fxCoolingActive(at, now)) continue;
              _failedAt['${entry.key}'] = at;
            }
          }
        }
      } catch (_) {
        // 缓存坏了就当没有：下次失败会重新写。
      }
      _loaded = true;
    }();
    _loading = task.whenComplete(() {
      _loading = null;
    });
    return _loading!;
  }

  /// 这条线路现在是不是还在冷却期（10 分钟内失败过）。
  static bool isCooling(
    String videoId,
    String lineName, {
    DateTime? now,
  }) {
    final key = keyOf(videoId, lineName);
    final at = _failedAt[key];
    if (at == null) return false;
    final ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
    if (fxCoolingActive(at, ms)) return true;
    // 过期了顺手清掉，别让表一直长。
    _failedAt.remove(key);
    return false;
  }

  /// 记一次失败（10 分钟内不再试这条线路）。
  static void markFailed(
    String videoId,
    String lineName, {
    DateTime? now,
  }) {
    final id = videoId.trim();
    final name = lineName.trim();
    if (id.isEmpty || name.isEmpty) return;
    final ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
    _failedAt[keyOf(id, name)] = ms;
    fxPlayLog('cooldown mark video=$id line=$name window=${fxLineCooldownWindow.inMinutes}min');
    _prune();
    _scheduleSave();
  }

  /// 这条线路又播成功了：从冷却表里删掉（别让它无辜背 10 分钟锅）。
  static void markHealthy(String videoId, String lineName) {
    final key = keyOf(videoId, lineName);
    if (_failedAt.remove(key) == null) return;
    _scheduleSave();
  }

  /// 一部剧的全部记录清掉（用户点最终失败页的重试 = 重新开始）。
  static void clearFor(String videoId) {
    final prefix = '${videoId.trim()}|';
    final before = _failedAt.length;
    _failedAt.removeWhere((key, _) => key.startsWith(prefix));
    if (_failedAt.length != before) _scheduleSave();
  }

  /// 清空全部（调试 / 设置里「重置」用）。
  static Future<void> clearAll() async {
    _failedAt.clear();
    _dirty = true;
    await flush();
  }

  /// 冷却中的线路沉到最后；返回新列表（不改入参顺序）。
  static List<T> sortCoolingLast<T>(
    String videoId,
    List<T> items,
    String Function(T item) nameOf, {
    DateTime? now,
  }) {
    if (items.length < 2) return List<T>.of(items);
    final fresh = <T>[];
    final cooling = <T>[];
    for (final item in items) {
      if (isCooling(videoId, nameOf(item), now: now)) {
        cooling.add(item);
      } else {
        fresh.add(item);
      }
    }
    return <T>[...fresh, ...cooling];
  }

  /// `LineInfo` 列表按冷却期重排（详情页默认线路 / 播放页自动轮都用它）。
  static List<LineInfo> sortLines(String videoId, List<LineInfo> lines) =>
      sortCoolingLast<LineInfo>(
        videoId,
        lines,
        (line) => line.displayName,
      );

  /// 给外部排序（`SearchRank`）用的惩罚位：0 = 正常，1 = 最近失败过。
  ///
  /// 只作为**同分辨率之后的**次级排序位：实测分辨率还是第一优先级，
  /// 否则「1080P 但刚才抖了一下」会被排到 480P 后面，用户更不满意。
  static int sortPenalty(VideoCard card, {DateTime? now}) {
    final id = card.id.trim();
    if (id.isEmpty) return 0;
    final name = card.sourceLabel.trim();
    if (name.isEmpty) return 0;
    return isCooling(id, name, now: now) ? 1 : 0;
  }

  /* ------------------------------------------------------------ 持久化 */

  static void _prune() {
    if (_failedAt.length <= maxEntries) return;
    final entries = _failedAt.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final drop = _failedAt.length - maxEntries;
    for (var i = 0; i < drop && i < entries.length; i++) {
      _failedAt.remove(entries[i].key);
    }
  }

  static void _scheduleSave() {
    _dirty = true;
    _saveTimer?.cancel();
    // 200ms 防抖：一次自动换线路轮里可能连续记好几条，别每记一条写一次盘。
    _saveTimer = Timer(const Duration(milliseconds: 200), () {
      unawaited(flush());
    });
  }

  /// 立刻落盘（页面退出 / 测试用）。
  static Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_dirty) return;
    _dirty = false;
    try {
      final sp = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      final out = <String, int>{};
      _failedAt.forEach((key, at) {
        if (fxCoolingActive(at, now)) out[key] = at;
      });
      await sp.setString(prefKey, jsonEncode(out));
    } catch (_) {
      // 写盘失败不影响本次播放：冷却表在内存里照样生效。
    }
  }
}

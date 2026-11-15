/// 线路健康档案（LINE_HEALTH 2026-11-15，用户口径）。
///
/// 用户要求：**App 启动时就开始检查线路**，进详情页时把健康的线路排前面，
/// 已知坏的不再排前面（播放页里坏的照样自动跳）。
///
/// 这一层只做三件事，判定全部复用 `line_probe.dart`（**不写第二份预检**）：
/// ```
/// ① 探：连接 → 清单 200 且是 #EXTM3U → 首片能下（各 3 秒，总 8 秒）
/// ② 存：line_health[vodId|线路名] = {ok, 探到的时间, 实测宽高}
/// ③ 排：健康度高的排前面，已知坏的沉后；30 分钟过期重探，
///      坏线路 10 分钟内不重复探
/// ```
/// 省流量：纯移动网络下只探清单（不探分片），并发 ≤3，只探当前可见的那批
/// （推荐 + 分类首页各一行），不做全库扫描。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import 'line_probe.dart';

/// 一条线路的健康快照。
@immutable
class LineHealthEntry {
  const LineHealthEntry({
    required this.ok,
    required this.probedAtMs,
    this.width = 0,
    this.height = 0,
  });

  /// 预检是否通过（三项全过）。
  final bool ok;

  /// 探到的时刻（毫秒时间戳）。
  final int probedAtMs;

  /// 实测宽高（拿得到才有；启动探针拿不到就留 0）。
  final int width;
  final int height;

  Map<String, Object?> toJson() => <String, Object?>{
    'ok': ok,
    'at': probedAtMs,
    'w': width,
    'h': height,
  };

  static LineHealthEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = (raw['at'] as num?)?.toInt() ?? 0;
    if (at <= 0) return null;
    return LineHealthEntry(
      ok: raw['ok'] == true,
      probedAtMs: at,
      width: (raw['w'] as num?)?.toInt() ?? 0,
      height: (raw['h'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 一次启动探针的目标：哪部片的哪条线路，用哪个地址去探。
class LineHealthTarget {
  const LineHealthTarget({
    required this.vodId,
    required this.lineName,
    required this.url,
  });

  final String vodId;
  final String lineName;
  final String url;

  String get key => LineHealth.keyOf(vodId, lineName);
}

/// 线路健康档案：内存 + SharedPreferences 双写。
///
/// `ok` 的记录 30 分钟过期；`bad` 的记录 10 分钟内不再重探（省流量、也省
/// 用户等待 —— 一条刚证明下不动的线路，五分钟后再探一遍也是一样的结果）。
class LineHealth {
  LineHealth._();

  static final LineHealth instance = LineHealth._();

  /// 健康记录的保质期。
  static const Duration healthyTtl = Duration(minutes: 30);

  /// 坏线路的冷却：10 分钟内不再重探。
  static const Duration badCooldown = Duration(minutes: 10);

  /// 启动探针的并发上限（别把启动时的网络占满）。
  static const int bootConcurrency = 3;

  /// 存储键。
  static const String storeKey = 'line_health_v1';

  /// `vodId|线路名`：和 `FxLineCooldown` 的键同构，方便两处互相参照。
  static String keyOf(String vodId, String lineName) =>
      '${vodId.trim()}|${lineName.trim()}';

  final Map<String, LineHealthEntry> _entries = <String, LineHealthEntry>{};

  SharedPreferences? _prefs;

  bool _loaded = false;

  /// 组记录条数（调试 / 测试用）。
  int get length => _entries.length;

  /// 读本地缓存（幂等）。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      final raw = prefs.getString(storeKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        final parsed = LineHealthEntry.fromJson(entry.value);
        if (parsed == null) continue;
        _entries['${entry.key}'] = parsed;
      }
    } catch (error) {
      // 档案坏了不影响播放：当成空档案。
      debugPrint('[$_logTag] load failed: $error');
    }
  }

  /// 写回本地（只留最近 400 条，别把 prefs 撑大）。
  Future<void> _save() async {
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      if (_entries.length > 400) {
        final keys = _entries.keys.toList()
          ..sort(
            (a, b) => (_entries[b]?.probedAtMs ?? 0).compareTo(
              _entries[a]?.probedAtMs ?? 0,
            ),
          );
        for (final key in keys.skip(400)) {
          _entries.remove(key);
        }
      }
      await prefs.setString(
        storeKey,
        jsonEncode(<String, Object?>{
          for (final e in _entries.entries) e.key: e.value.toJson(),
        }),
      );
    } catch (error) {
      debugPrint('[$_logTag] save failed: $error');
    }
  }

  /// 当前记录（不管过没过期；界面排序用 [effective]）。
  LineHealthEntry? raw(String vodId, String lineName) =>
      _entries[keyOf(vodId, lineName)];

  /// 有效记录：过期的返回 null（等于「不知道」）。
  LineHealthEntry? effective(String vodId, String lineName, {DateTime? now}) {
    final entry = raw(vodId, lineName);
    if (entry == null) return null;
    final age = (now ?? DateTime.now()).millisecondsSinceEpoch -
        entry.probedAtMs;
    if (age < 0) return entry;
    if (!entry.ok && age < badCooldown.inMilliseconds) return entry;
    if (entry.ok && age < healthyTtl.inMilliseconds) return entry;
    return null;
  }

  /// 记一条探针结果（播放页的预检也会写进来，两边共用同一份档案）。
  Future<void> record({
    required String vodId,
    required String lineName,
    required bool ok,
    int width = 0,
    int height = 0,
    DateTime? now,
  }) async {
    final key = keyOf(vodId, lineName);
    if (key.trim().isEmpty || vodId.trim().isEmpty) return;
    _entries[key] = LineHealthEntry(
      ok: ok,
      probedAtMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
      width: width,
      height: height,
    );
    await _save();
  }

  /// 详情页排序：健康度高 → 未知 → 已知坏；同档内保持服务端原顺序。
  ///
  /// 只调顺序，不隐藏任何线路：服务端 / 我们的探测都可能误判，
  /// 用户想点坏的照样能点（播放页里它会自动跳下一条）。
  List<LineInfo> rankLines(String vodId, List<LineInfo> lines, {DateTime? now}) {
    if (lines.length < 2) return lines;
    int rankOf(LineInfo line) {
      final entry = effective(vodId, line.displayName, now: now);
      if (entry == null) return 1; // 未知
      return entry.ok ? 0 : 2; // 健康 / 坏
    }

    final indexed = <MapEntry<int, LineInfo>>[
      for (var i = 0; i < lines.length; i++) MapEntry(i, lines[i]),
    ];
    indexed.sort((a, b) {
      final byRank = rankOf(a.value).compareTo(rankOf(b.value));
      if (byRank != 0) return byRank;
      return a.key.compareTo(b.key);
    });
    return <LineInfo>[for (final e in indexed) e.value];
  }

  /// 启动探针：探当前可见的那批线路，结果写档案。
  ///
  /// [targets] 由调用方给（只给可见的那批，别全库扫）。整个流程都容错：
  /// 任何异常只写日志，绝不冒泡到启动流程。
  Future<void> probeBoot(
    Future<List<LineHealthTarget>> Function() targets, {
    DateTime? now,
    bool? cellular,
  }) async {
    final watch = Stopwatch()..start();
    await load();
    final isCellular = cellular ?? await onCellular();
    List<LineHealthTarget> list;
    try {
      list = await targets();
    } catch (error) {
      debugPrint('[$_logTag] boot targets failed: $error');
      return;
    }
    if (list.isEmpty) return;
    // 只探「该探的」：10 分钟内的坏线路、30 分钟内的健康线路都跳过。
    final pending = <LineHealthTarget>[
      for (final target in list)
        if (effective(target.vodId, target.lineName, now: now) == null) target,
    ];
    if (pending.isEmpty) {
      debugPrint('[$_logTag] boot total=0 skip=all-fresh');
      return;
    }
    // 纯移动网络：只探清单（不探分片），省流量。
    final manifestOnly = isCellular;
    var ok = 0;
    var bad = 0;
    var index = 0;
    Future<void> worker() async {
      while (true) {
        if (index >= pending.length) return;
        final target = pending[index++];
        final result = await probeLine(
          target.url,
          manifestOnly: manifestOnly,
        );
        if (result.ok) {
          ok++;
        } else {
          bad++;
        }
        await record(
          vodId: target.vodId,
          lineName: target.lineName,
          ok: result.ok,
          now: now,
        );
      }
    }

    final workers = <Future<void>>[
      for (var i = 0; i < bootConcurrency; i++) worker(),
    ];
    await Future.wait(workers);
    watch.stop();
    final elapsed = (watch.elapsedMilliseconds / 1000).toStringAsFixed(1);
    // 固定格式（用户指定）：`[FxProbe] boot total=40 ok=31 bad=9 elapsed=6.2s`
    debugPrint(
      '[$_logTag] boot total=${pending.length} ok=$ok bad=$bad '
      'elapsed=${elapsed}s${manifestOnly ? ' manifest_only=1' : ''}',
    );
  }

  /// 清空档案（测试 / 排障）。
  Future<void> clear() async {
    _entries.clear();
    await _save();
  }
}

/// 日志标签：`[FxProbe]`（用户指定的格式前缀）。
const String _logTag = 'FxProbe';

/// 当前是不是纯移动网络（没连 WiFi）。
///
/// 没有 connectivity 插件，也不值得为一个判断加依赖：Android 上
/// `NetworkInterface.list()` 里 `wlan*` 表示 WiFi，`rmnet* / ccmni* / pdp*`
/// 表示蜂窝。判断不了时按「不是移动网络」处理（只在确实看到蜂窝接口、
/// 且没有 WiFi 接口时才认定为移动网络）—— 宁可多探清单，也别把功能关掉。
Future<bool> onCellular() async {
  try {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    var hasWifi = false;
    var hasCell = false;
    for (final iface in interfaces) {
      final name = iface.name.toLowerCase();
      if (name.startsWith('wlan') || name.startsWith('ap')) hasWifi = true;
      if (name.startsWith('rmnet') ||
          name.startsWith('ccmni') ||
          name.startsWith('pdp') ||
          name.startsWith('clat')) {
        hasCell = true;
      }
    }
    return hasCell && !hasWifi;
  } catch (_) {
    return false;
  }
}

/// 源级失败记账（PROTOCOL_FACE 2026-11-15，移植阶段 1 · 第 8 条）。
///
/// 壳的语义（`model/SiteViewModel.java:74-81` + `RE §8#14`）：
///   · 首页内容取一次就记 `Prefers("crash", false)` —— **崩过一次就先不调这个源**，
///     下次进来再给一次机会（「崩溃熔断」）；
///   · `Prefers.getBoolean("crash")` 为真时 `homeContent` 直接返回空串，
///     不碰 spider（避免一个坏 jar 把整个首页拖死）。
///
/// 我们这边原来**完全没有**源级记账：死源每一轮搜索都重新发一次请求、
/// 等满 12 秒再当「没结果」—— 用户看到的是「每次搜索都要等十几秒」。
/// 线路级冷却（`line_cooldown.dart`）只管播放线路，管不到「这个源根本连不上」。
///
/// 这个文件做的是**同一件事的通用版**：
///   · 每源记「连续失败次数 + 最近失败时间」；
///   · 连续失败到 [cooldownThreshold] 次 → 进冷却 [cooldown]，期间批量检索跳过它
///     （用户主动点进这个源的详情 / 播放不受影响 —— 那是显式意图）；
///   · 冷却到期自动恢复：**只放一次**试探（下一次成功就清账，再失败继续冷却）；
///   · 成功的源立刻清账，不留历史包袱；
///   · 落盘（`SharedPreferences`），进程重启后仍然记得 —— 壳只存在内存里，
///     我们比它多一层，因为「每次启动都白等一遍死源」是最容易被用户骂的点。
///
/// 纯逻辑 + 可注入的存储接口：`test/source_failure_test.dart` 不需要
/// Flutter 插件就能跑完整语义（时间也可以注入）。
library;

import 'dart:convert';

/// 一次失败的类型（决定冷却力度）。
enum SourceFailureKind {
  /// 超时：源站慢 / 连不上 —— 最常见。
  timeout,

  /// 出错：HTTP 4xx/5xx、JSON 坏了、jar 抛异常。
  error,

  /// 空结果：源站通了但一条都没有（**不算失败**，只记次数用于排序）。
  empty,

  /// 崩溃：jar 类加载失败 / 原生通道异常 —— 壳的 `crash` 熔断就这一种。
  crash;

  String get label => switch (this) {
        SourceFailureKind.timeout => '超时',
        SourceFailureKind.error => '出错',
        SourceFailureKind.empty => '空',
        SourceFailureKind.crash => '崩溃',
      };
}

/// 一个源的记账条目。
class SourceFailureEntry {
  const SourceFailureEntry({
    this.failures = 0,
    this.lastFailMs = 0,
    this.cooldownUntilMs = 0,
    this.lastKind = SourceFailureKind.error,
    this.totalFailures = 0,
  });

  /// 连续失败次数（成功即清零）。
  final int failures;

  /// 最近一次失败的时间戳（毫秒）。
  final int lastFailMs;

  /// 冷却到期时间戳（毫秒）；0 = 不在冷却。
  final int cooldownUntilMs;

  final SourceFailureKind lastKind;

  /// 累计失败次数（不清零，只用于「这个源一直不稳」的排序 / 诊断）。
  final int totalFailures;

  bool cooling(int nowMs) => cooldownUntilMs > nowMs;

  Map<String, Object?> toMap() => <String, Object?>{
        'f': failures,
        't': lastFailMs,
        'c': cooldownUntilMs,
        'k': lastKind.name,
        'n': totalFailures,
      };

  static SourceFailureEntry? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final kindName = '${raw['k'] ?? ''}';
    return SourceFailureEntry(
      failures: _int(raw['f']),
      lastFailMs: _int(raw['t']),
      cooldownUntilMs: _int(raw['c']),
      lastKind: SourceFailureKind.values.firstWhere(
        (k) => k.name == kindName,
        orElse: () => SourceFailureKind.error,
      ),
      totalFailures: _int(raw['n']),
    );
  }
}

/// 记账表的存储接口（生产实现是 SharedPreferences，测试实现是内存）。
abstract class SourceFailureStore {
  Future<String?> read();

  Future<void> write(String body);
}

/// 内存实现（非 Android / 单测 / 读盘失败时的兜底）。
class MemorySourceFailureStore implements SourceFailureStore {
  MemorySourceFailureStore([this._body]);

  String? _body;

  @override
  Future<String?> read() async => _body;

  @override
  Future<void> write(String body) async => _body = body;
}

/// 源级失败账本。
class SourceFailureLedger {
  SourceFailureLedger({
    SourceFailureStore? store,
    this.cooldown = const Duration(minutes: 10),
    this.cooldownThreshold = 2,
    this.crashCooldown = const Duration(minutes: 30),
    this.maxEntries = 400,
    DateTime Function()? clock,
  })  : _store = store ?? MemorySourceFailureStore(),
        _clock = clock ?? DateTime.now;

  /// 连续失败 [cooldownThreshold] 次后的冷却时长（默认 10 分钟，
  /// 与线路冷却同一口径）。
  final Duration cooldown;

  /// 连续失败几次进冷却。
  final int cooldownThreshold;

  /// 「崩溃」这一类单独关更久（壳的 `crash` 熔断语义：jar 崩过一次就先别调）。
  final Duration crashCooldown;

  /// 账本容量上限（超了丢最久没失败的，别让 prefs 无限涨）。
  final int maxEntries;

  final SourceFailureStore _store;
  final DateTime Function() _clock;

  final Map<String, SourceFailureEntry> _entries = <String, SourceFailureEntry>{};

  bool _loaded = false;
  Future<void>? _loading;

  int get nowMs => _clock().millisecondsSinceEpoch;

  int get length => _entries.length;

  /// 读一次盘（幂等；失败按空表处理）。
  Future<void> ensureLoaded() {
    final running = _loading;
    if (running != null) return running;
    if (_loaded) return Future<void>.value();
    final task = () async {
      try {
        final body = await _store.read();
        if (body != null && body.trim().isNotEmpty) {
          final raw = jsonDecode(body);
          if (raw is Map) {
            raw.forEach((k, v) {
              final entry = SourceFailureEntry.fromMap(v);
              if (entry != null) _entries['$k'] = entry;
            });
          }
        }
      } catch (_) {
        // 坏账本当没有：宁可多试一次源，也不能让读盘失败拖住搜索。
      }
      _loaded = true;
    }();
    _loading = task;
    return task.whenComplete(() {
      _loading = null;
    });
  }

  /// 这个源现在要不要跳过（冷却中 = 跳过）。
  bool shouldSkip(String key, {int? at}) {
    final entry = _entries[key.trim()];
    if (entry == null) return false;
    return entry.cooling(at ?? nowMs);
  }

  /// 还要冷却多久（没在冷却返回 [Duration.zero]）。
  Duration remaining(String key, {int? at}) {
    final entry = _entries[key.trim()];
    if (entry == null) return Duration.zero;
    final left = entry.cooldownUntilMs - (at ?? nowMs);
    return left <= 0 ? Duration.zero : Duration(milliseconds: left);
  }

  SourceFailureEntry? entryOf(String key) => _entries[key.trim()];

  /// 记一次失败，返回记完之后的条目。
  ///
  /// 冷却时长按类型：`crash` 用 [crashCooldown]，其余用 [cooldown]；
  /// 「空结果」不触发冷却（源站是通的，只是没这部片）。
  Future<SourceFailureEntry> recordFailure(
    String key,
    SourceFailureKind kind, {
    String note = '',
  }) async {
    final k = key.trim();
    if (k.isEmpty) return const SourceFailureEntry();
    await ensureLoaded();
    final now = nowMs;
    final old = _entries[k] ?? const SourceFailureEntry();
    final failures = kind == SourceFailureKind.empty ? old.failures : old.failures + 1;
    var cooldownUntil = old.cooldownUntilMs;
    if (kind != SourceFailureKind.empty) {
      final threshold =
          kind == SourceFailureKind.crash ? 1 : cooldownThreshold;
      if (failures >= threshold) {
        final span = kind == SourceFailureKind.crash ? crashCooldown : cooldown;
        cooldownUntil = now + span.inMilliseconds;
      }
    }
    final entry = SourceFailureEntry(
      failures: failures,
      lastFailMs: now,
      cooldownUntilMs: cooldownUntil,
      lastKind: kind,
      totalFailures: old.totalFailures + (kind == SourceFailureKind.empty ? 0 : 1),
    );
    _entries[k] = entry;
    _trim();
    await _flush();
    return entry;
  }

  /// 记一次成功：清账（冷却也一起清，用户下次还会用到它）。
  Future<void> recordSuccess(String key) async {
    final k = key.trim();
    if (k.isEmpty) return;
    await ensureLoaded();
    final old = _entries[k];
    if (old == null) return;
    if (old.failures == 0 && old.cooldownUntilMs == 0) return;
    _entries[k] = SourceFailureEntry(totalFailures: old.totalFailures);
    await _flush();
  }

  /// 清空（设置页「重置片源缓存」时一起清）。
  Future<void> clear() async {
    _entries.clear();
    _loaded = true;
    await _flush();
  }

  /// 当前在冷却的源（诊断 / 日志用）。
  List<String> coolingKeys({int? at}) {
    final now = at ?? nowMs;
    return <String>[
      for (final e in _entries.entries)
        if (e.value.cooling(now)) e.key,
    ];
  }

  /// 一行摘要（日志用）。
  String summary() {
    final cooling = coolingKeys();
    if (_entries.isEmpty) return 'source_fail[空]';
    return 'source_fail[记 ${_entries.length} 源'
        '${cooling.isEmpty ? '' : ' 冷却 ${cooling.length}：${cooling.take(5).join('/')}'}]';
  }

  void _trim() {
    if (_entries.length <= maxEntries) return;
    final keys = _entries.keys.toList()
      ..sort((a, b) =>
          (_entries[a]?.lastFailMs ?? 0).compareTo(_entries[b]?.lastFailMs ?? 0));
    final drop = _entries.length - maxEntries;
    for (var i = 0; i < drop && i < keys.length; i++) {
      _entries.remove(keys[i]);
    }
  }

  Future<void> _flush() async {
    try {
      final body = jsonEncode(<String, Object?>{
        for (final e in _entries.entries) e.key: e.value.toMap(),
      });
      await _store.write(body);
    } catch (_) {
      // 写不进去只是下次启动不记得，不能影响检索。
    }
  }
}

/// SharedPreferences 存储（生产用；非 Android 平台自动退化成内存）。
///
/// 直接 `implements` 而不 import `shared_preferences`：这个文件要被纯 Dart
/// 单测与 `tools/probe_tvbox_config.dart` 引用，不能拖插件依赖。真正的
/// SharedPreferences 绑定放在 `source_hub.dart`（它本来就依赖插件）。
class PrefsSourceFailureStore implements SourceFailureStore {
  PrefsSourceFailureStore({
    required Future<String?> Function() read,
    required Future<void> Function(String body) write,
  })  : _read = read,
        _write = write;

  final Future<String?> Function() _read;
  final Future<void> Function(String body) _write;

  @override
  Future<String?> read() => _read();

  @override
  Future<void> write(String body) => _write(body);
}

int _int(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse('${raw ?? ''}'.trim()) ?? 0;
}

/// 搜索命中后**自动补线路**（ENRICH 2026-11-15，用户口径）。
///
/// 搜索结果里某部片线路很少时，后台按「片名 + 年份」去补：
/// **只在 App 的详情页多出这些线路，服务端库一行都不改**。
///
/// 动态探测（不写死排除任何线路）：
/// ```
/// 三条都去试：幻想爱奇艺 / 福盈4K(SH4K) / 福盈蓝光(PAN1)
/// 每条先探测能不能解析出可播地址（line_probe 三关：连接 → 清单 → 首片）
///   探通了 → 补进线路列表
///   探不通 → 不补，并记住失败时间（1 小时内不再探它）
/// ```
/// 福盈蓝光哪天自己好了，下一次就会自动补出来 —— 不用改代码。
///
/// 缓存：`enrich[片名|年份][线路] = {ok, episodes, at}`；成功 24 小时、
/// 失败 1 小时（冷却）。规则与文案都在 `line_enrich_rules.dart`（纯 Dart，
/// 可 `dart run` 单测）；探测复用 `line_probe.dart` 的预检（**不写第二份**）。
///
/// 日志：`[FxEnrich] vod=济公传 line=幻想爱奇艺 ok=true eps=58` /
/// `[FxEnrich] vod=济公传 line=福盈蓝光 ok=false stage=manifest reason=http_400`。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import 'cms_api.dart';
import 'cms_bridge.dart';
import 'line_enrich_rules.dart';
import 'line_probe.dart';

// 规则 / 模型（EnrichEntry / EnrichLineState / 日志格式）由规则层提供，
// 调用方只 import 这一个文件就够。
export 'line_enrich_rules.dart';

/// 补线路：探测、缓存、地址解析。
class LineEnrich {
  LineEnrich._();

  static final LineEnrich instance = LineEnrich._();

  /// 存储键。
  static const String storeKey = 'line_enrich_v2';

  /// 总开关（排障用：关掉就不补线路）。
  static bool enabled = true;

  /// 每条线路最多往下试几集（探到就停，别把接口打爆）。
  static const int maxEpisodeProbes = 6;

  final Map<String, EnrichEntry> _entries = <String, EnrichEntry>{};

  SharedPreferences? _prefs;

  bool _loaded = false;

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
        final parsed = EnrichEntry.fromJson(entry.value);
        if (parsed != null) _entries['${entry.key}'] = parsed;
      }
    } catch (error) {
      debugPrint('[$kEnrichLogTag] load failed: $error');
    }
  }

  Future<void> _save() async {
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      if (_entries.length > 200) {
        final keys = _entries.keys.toList()
          ..sort(
            (a, b) =>
                (_entries[b]?.atMs ?? 0).compareTo(_entries[a]?.atMs ?? 0),
          );
        for (final key in keys.skip(200)) {
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
      debugPrint('[$kEnrichLogTag] save failed: $error');
    }
  }

  /// 取缓存（整条记录；每条线路自己决定还有没有效）。
  EnrichEntry? cached(String title, int year) => _entries[enrichKeyOf(title, year)];

  /// 把探通的线路转成详情页能用的 [LineInfo]。
  ///
  /// 集数按对方实际集数；单集（电影）叫「正片」，多集叫「第 N 集」——
  /// 和服务端的集名规则一致，否则详情页的选集条会和别的线路不齐。
  List<LineInfo> linesOf(EnrichEntry entry) {
    final usable = entry.usable;
    final out = <LineInfo>[];
    for (var i = 0; i < usable.length; i++) {
      final line = usable[i];
      out.add(
        LineInfo(
          line.lineId,
          line.name,
          // 爱奇艺走解析服务现取的**成品**地址；借来的线路自带地址。
          line.borrowed ? 'hls' : 'parse',
          usable.length - i,
          from: line.name,
          epNames: enrichEpisodeNames(line.episodes),
        ),
      );
    }
    return out;
  }

  /// 补线路主入口：拿缓存，没缓存 / 过期的线路才去探。
  ///
  /// [existing] = 详情里已有的线路：已经有「幻想爱奇艺」的片不再补这条。
  Future<EnrichEntry?> enrich({
    required String title,
    required int year,
    required List<LineInfo> existing,
    int? episodes,
  }) async {
    if (!enabled || title.trim().isEmpty) return null;
    await load();
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final previous = cached(title, year);
    final have = <String>{
      for (final line in existing) line.displayName.trim().toLowerCase(),
    };
    // 只探「服务端没有 + 缓存里没有有效结果」的线路。
    final pending = <EnrichProvider>[
      for (final provider in enrichProviders)
        if (!have.contains(provider.name.toLowerCase()) &&
            !_freshState(previous, provider, nowMs))
          provider,
    ];
    if (pending.isEmpty) {
      // 全都有有效缓存：直接返回（命中的照样补，失败的照样不补）。
      return previous;
    }

    final states = <EnrichLineState>[
      // 先把还有效的旧结果原样带上（失败冷却中的不重探、成功的继续用）。
      for (final provider in enrichProviders)
        if (_freshState(previous, provider, nowMs))
          _stateOf(previous, provider)!,
    ];
    for (final provider in pending) {
      final state = await _probe(
        provider: provider,
        title: title,
        year: year,
        episodes: episodes,
        nowMs: nowMs,
      );
      states.add(state);
      // 每探一条就落盘：中途进程被杀也不白探。
      debugPrint(enrichLineLog(title: title, line: state));
    }

    final entry = EnrichEntry(
      title: title.trim(),
      year: year,
      atMs: nowMs,
      lines: <EnrichLineState>[
        for (final provider in enrichProviders)
          if (_stateOfList(states, provider) != null)
            _stateOfList(states, provider)!,
      ],
    );
    _entries[enrichKeyOf(title, year)] = entry;
    await _save();
    debugPrint(
      enrichSummaryLog(
        title: title,
        added: <String>[for (final line in entry.usable) line.name],
        probed: states.length,
      ),
    );
    return entry;
  }

  EnrichLineState? _stateOf(
    EnrichEntry? entry,
    EnrichProvider provider,
  ) {
    for (final line in entry?.lines ?? const <EnrichLineState>[]) {
      if (line.name == provider.name) return line;
    }
    return null;
  }

  EnrichLineState? _stateOfList(
    List<EnrichLineState> states,
    EnrichProvider provider,
  ) {
    for (final line in states) {
      if (line.name == provider.name) return line;
    }
    return null;
  }

  /// 缓存里这条线路还有效吗（成功 24 小时 / 失败 1 小时）。
  bool _freshState(EnrichEntry? entry, EnrichProvider provider, int nowMs) {
    final state = _stateOf(entry, provider);
    return state != null && state.fresh(nowMs);
  }

  Future<EnrichLineState> _probe({
    required EnrichProvider provider,
    required String title,
    required int year,
    required int? episodes,
    required int nowMs,
  }) async {
    if (provider.kind == 'iqiyi') {
      return _probeIqiyi(
        provider: provider,
        title: title,
        year: year,
        episodes: episodes,
        nowMs: nowMs,
      );
    }
    return _probeBorrow(
      provider: provider,
      title: title,
      year: year,
      nowMs: nowMs,
    );
  }

  /// 探爱奇艺：ep1 必须通，然后从「详情里的集数」往下试。
  ///
  /// 不硬凑：只报**探通过**的集数；失败时把最后的失败阶段 / 原因带回去。
  Future<EnrichLineState> _probeIqiyi({
    required EnrichProvider provider,
    required String title,
    required int year,
    required int? episodes,
    required int nowMs,
  }) async {
    FxLineProbeResult? last;
    Future<bool> exists(int ep) async {
      final result = await probeLine(
        CmsApi.iqiyiPlayUri(title: title, year: year, ep: ep).toString(),
        manifestOnly: true,
      );
      last = result;
      return result.ok;
    }

    if (!await exists(1)) {
      final failed = last;
      return EnrichLineState(
        name: provider.name,
        ok: false,
        atMs: nowMs,
        stage: failed?.stage ?? 'manifest',
        reason: failed?.failureCode ?? 'probe_failed',
      );
    }
    final wanted = episodes ?? 1;
    final top = wanted < 1 ? 1 : wanted;
    var count = 1;
    if (top > 1) {
      // 从「详情里的集数」往下退，最多试 maxEpisodeProbes 次（少打请求）。
      var probe = top;
      var tries = 0;
      while (probe > 1 && tries < maxEpisodeProbes) {
        if (await exists(probe)) {
          count = probe;
          break;
        }
        probe--;
        tries++;
      }
    }
    return EnrichLineState(
      name: provider.name,
      ok: count > 0,
      atMs: nowMs,
      episodes: count,
      stage: last?.stage ?? FxProbeStage.manifest,
    );
  }

  /// 探「借地址」类的线路（SH4K / 福盈蓝光）：在同名同年的另一条记录里
  /// 找同名线路，解析 ep1 并预检；探不通就记下失败阶段与原因。
  Future<EnrichLineState> _probeBorrow({
    required EnrichProvider provider,
    required String title,
    required int year,
    required int nowMs,
  }) async {
    EnrichLineState fail(String stage, String reason) => EnrichLineState(
      name: provider.name,
      ok: false,
      atMs: nowMs,
      stage: stage,
      reason: reason,
    );
    try {
      final card = await CmsBridge.findByTitle(
        title,
        year: year,
      ).timeout(const Duration(seconds: 8));
      if (card == null || card.id.trim().isEmpty) {
        return fail('lookup', 'no_record');
      }
      final detail = await CmsBridge.detail(
        card.id,
      ).timeout(const Duration(seconds: 8));
      LineInfo? target;
      for (final line in detail.lines) {
        if (!provider.matches(line.displayName)) continue;
        if (line.epNames.isEmpty) continue;
        target = line;
        break;
      }
      if (target == null) return fail('lookup', 'no_line');
      String url;
      try {
        url = await CmsBridge.playUrl(
          card.id,
          target.id,
          1,
        ).timeout(const Duration(seconds: 12));
      } catch (_) {
        return fail('parse', 'resolve_failed');
      }
      if (url.trim().isEmpty) return fail('parse', 'resolve_failed');
      final probe = await probeLine(url, manifestOnly: true);
      if (!probe.ok) {
        return fail(
          probe.stage,
          probe.failureCode.isEmpty ? 'probe_failed' : probe.failureCode,
        );
      }
      return EnrichLineState(
        name: provider.name,
        ok: true,
        atMs: nowMs,
        episodes: target.epNames.length,
        stage: probe.stage,
        borrowVodId: card.id,
        borrowLineId: target.id,
      );
    } catch (error) {
      debugPrint('[$kEnrichLogTag] ${provider.name} probe failed: $error');
      return fail('lookup', 'error');
    }
  }

  /// 补进来的线路地址：播放器解析不到时就问它。
  ///
  /// [lineId] 必须带 `enrich:` 前缀，否则返回 null（不是补的线路，交回
  /// 原来的 `CmsBridge.play`）。
  Future<PlayInfo?> resolvePlay({
    required int ep,
    required String lineId,
  }) async {
    final id = lineId.trim();
    if (!id.startsWith(kEnrichIdPrefix)) return null;
    await load();
    EnrichEntry? entry;
    EnrichLineState? hit;
    for (final candidate in _entries.values) {
      for (final line in candidate.lines) {
        if (!line.ok || line.lineId != id) continue;
        entry = candidate;
        hit = line;
        break;
      }
      if (hit != null) break;
    }
    if (entry == null || hit == null) return null;
    if (ep < 1 || ep > hit.episodes) return null;
    if (hit.borrowed) {
      try {
        return await CmsBridge.play(
          hit.borrowVodId,
          ep,
          hit.borrowLineId,
        ).timeout(const Duration(seconds: 12));
      } catch (error) {
        debugPrint('[$kEnrichLogTag] borrow resolve failed: $error');
        return null;
      }
    }
    // 爱奇艺：成品地址可直接播（服务端 302 → 清单）。
    return PlayInfo(
      url: CmsApi.iqiyiPlayUri(
        title: entry.title,
        year: entry.year,
        ep: ep,
      ).toString(),
      type: 'hls',
      quality: const <QualityItem>[],
      backup: const <String>[],
      headers: const <String, String>{},
      parsePage: '',
      lineName: hit.name,
      direct: true,
    );
  }

  /// 清空缓存（测试 / 排障）。
  Future<void> clear() async {
    _entries.clear();
    await _save();
  }
}

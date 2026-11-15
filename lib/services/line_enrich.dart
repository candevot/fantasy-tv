/// 搜索命中后**自动补线路**（ENRICH 2026-11-15，用户口径）。
///
/// 用户要求：搜索结果里某部片只有一两条线路时，后台按「片名 + 年份」去补，
/// 命中就把线路追加到这部片上；**只在 App 的详情页多出这些线路，不改服务端库**。
///
/// 只补两条，第三条是明确的死线路：
/// ```
/// 幻想爱奇艺（iqiyi）   正常，能补 —— 解析服务按「片名 + 年份 + 第几集」现取成品
/// SH4K / 福盈4K         正常，能补 —— 借「同名同年的另一条记录」的 SH4K 线路
/// 福盈蓝光（PAN1）      不补 —— 福盈解析接口坏了，补上去就是一条点了不出画的线
/// ```
///
/// 约束：
///   · 集数按**对方实际集数**，不硬凑（探测不到就不补这条）；
///   · 命中缓存 24 小时，避免同一部片反复查；
///   · 追加的线路参与现有排序（付费线在前、按实测分辨率）与自动切线：
///     它们长得和普通 `LineInfo` 一样，只是 id 带 `enrich:` 前缀，
///     播放地址由 [LineEnrich.resolvePlay] 现算。
///
/// 规则与文案在 `line_enrich_rules.dart`（纯 Dart，可 `dart run` 单测）；
/// 探测复用 `line_probe.dart` 的三级预检（**不写第二份**）。
///
/// 日志固定：`[FxEnrich] vod=济公传 add=幻想爱奇艺,SH4K hit=2/2`。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import 'cms_api.dart';
import 'cms_bridge.dart';
import 'line_enrich_rules.dart';
import 'line_probe.dart';

// 规则 / 模型（EnrichHit / EnrichEntry / 日志格式）由规则层提供，
// 调用方只 import 这一个文件就够。
export 'line_enrich_rules.dart';

/// 补线路：探测、缓存、地址解析。
class LineEnrich {
  LineEnrich._();

  static final LineEnrich instance = LineEnrich._();

  /// 存储键。
  static const String storeKey = 'line_enrich_v1';

  /// 总开关（排障用：关掉就不补线路）。
  static bool enabled = true;

  /// 每部片最多往下试几集（爱奇艺按集探测，探到就停）。
  static const int maxEpisodeProbes = 6;

  final Map<String, EnrichEntry> _entries = <String, EnrichEntry>{};

  SharedPreferences? _prefs;

  bool _loaded = false;

  /// 读缓存（幂等）。
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
      // 只留最近 200 条：一部片一条，追剧也用不到更多。
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

  /// 取缓存（24 小时内有效）。
  EnrichEntry? cached(String title, int year, {DateTime? now}) {
    final entry = _entries[enrichKeyOf(title, year)];
    if (entry == null) return null;
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    if (!enrichFresh(atMs: entry.atMs, nowMs: nowMs)) return null;
    return entry;
  }

  /// 把命中的线路转成详情页能用的 [LineInfo]。
  ///
  /// 集数按对方实际集数；单集（电影）叫「正片」，多集叫「第 N 集」——
  /// 和服务端的集名规则一致，否则详情页的选集条会和别的线路不齐。
  List<LineInfo> linesOf(EnrichEntry entry) {
    final out = <LineInfo>[];
    for (var i = 0; i < entry.hits.length; i++) {
      final hit = entry.hits[i];
      out.add(
        LineInfo(
          hit.lineId,
          hit.name,
          // 爱奇艺走解析服务现取的**成品**地址；借用的线路自带地址。
          hit.borrowed ? 'hls' : 'parse',
          entry.hits.length - i,
          from: hit.name,
          epNames: enrichEpisodeNames(hit.episodes),
        ),
      );
    }
    return out;
  }

  /// 补线路主入口：拿缓存，没缓存就探。
  ///
  /// [existing] = 详情里已有的线路：已经有「幻想爱奇艺」的片不再补，
  /// 补重复线路只会让用户看到两条一样的。
  Future<EnrichEntry?> enrich({
    required String title,
    required int year,
    required List<LineInfo> existing,
    int? episodes,
  }) async {
    if (!enabled || title.trim().isEmpty) return null;
    await load();
    final cachedEntry = cached(title, year);
    if (cachedEntry != null) return cachedEntry;

    final have = <String>{
      for (final line in existing) line.displayName.trim().toLowerCase(),
    };
    final wants = <String>[
      if (!have.contains(kEnrichIqiyiName.toLowerCase())) kEnrichIqiyiName,
      if (!have.contains(kEnrichSh4kName.toLowerCase())) kEnrichSh4kName,
    ];
    if (wants.isEmpty) return null;

    final hits = <EnrichHit>[];
    // ① 幻想爱奇艺：解析服务按「片名 + 年份 + 第几集」现取成品地址。
    if (wants.contains(kEnrichIqiyiName)) {
      final eps = await _probeIqiyi(
        title: title,
        year: year,
        episodes: episodes,
      );
      if (eps > 0) {
        hits.add(EnrichHit(name: kEnrichIqiyiName, episodes: eps));
      }
    }
    // ② SH4K / 福盈4K：借「同名同年的另一条记录」的这条线路。
    //    福盈蓝光（PAN1）在规则层就被挡掉，不会走到这里。
    if (wants.contains(kEnrichSh4kName)) {
      final borrow = await _probeSh4k(title: title, year: year);
      if (borrow != null) hits.add(borrow);
    }

    final entry = EnrichEntry(
      title: title.trim(),
      year: year,
      atMs: DateTime.now().millisecondsSinceEpoch,
      hits: hits,
    );
    _entries[enrichKeyOf(title, year)] = entry;
    await _save();
    debugPrint(
      enrichLog(
        title: title,
        added: <String>[for (final hit in hits) hit.name],
        wanted: wants.length,
      ),
    );
    return entry;
  }

  /// 探爱奇艺这条线到底有几集：ep1 必须通，然后从「详情里的集数」往下试。
  ///
  /// 不硬凑：只报**探通过**的集数，一集都探不到就返回 0（这条线不补）。
  Future<int> _probeIqiyi({
    required String title,
    required int year,
    int? episodes,
  }) async {
    Future<bool> exists(int ep) async {
      final result = await probeLine(
        CmsApi.iqiyiPlayUri(title: title, year: year, ep: ep).toString(),
        manifestOnly: true,
      );
      return result.ok;
    }

    if (!await exists(1)) return 0;
    final wanted = episodes ?? 1;
    final top = wanted < 1 ? 1 : wanted;
    if (top <= 1) return 1;
    // 从「详情里的集数」往下退，最多试 maxEpisodeProbes 次（少打请求）。
    var probe = top;
    var tries = 0;
    while (probe > 1 && tries < maxEpisodeProbes) {
      if (await exists(probe)) return probe;
      probe--;
      tries++;
    }
    return 1;
  }

  /// 探 SH4K：在同名同年的另一条记录里找 SH4K / 福盈4K 线路并借用。
  ///
  /// 「能播才算命中」：解析出 ep1 的地址 + 预检清单通过才补，否则这条线
  /// 补上去只会让用户点了不出画。
  Future<EnrichHit?> _probeSh4k({
    required String title,
    required int year,
  }) async {
    try {
      final card = await CmsBridge.findByTitle(
        title,
        year: year,
      ).timeout(const Duration(seconds: 8));
      if (card == null || card.id.trim().isEmpty) return null;
      final detail = await CmsBridge.detail(
        card.id,
      ).timeout(const Duration(seconds: 8));
      for (final line in detail.lines) {
        final name = line.displayName.trim();
        if (!enrichIsSh4k(name)) continue;
        // 福盈蓝光 / PAN1：解析接口坏了，明确跳过。
        if (enrichBlocked(name)) continue;
        if (line.epNames.isEmpty) continue;
        String url;
        try {
          url = await CmsBridge.playUrl(
            card.id,
            line.id,
            1,
          ).timeout(const Duration(seconds: 12));
        } catch (_) {
          continue;
        }
        if (url.trim().isEmpty) continue;
        final probe = await probeLine(url, manifestOnly: true);
        if (!probe.ok) continue;
        return EnrichHit(
          name: kEnrichSh4kName,
          episodes: line.epNames.length,
          kind: 'borrow',
          borrowVodId: card.id,
          borrowLineId: line.id,
        );
      }
    } catch (error) {
      debugPrint('[$kEnrichLogTag] SH4K probe failed: $error');
    }
    return null;
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
    EnrichHit? hit;
    EnrichEntry? entry;
    for (final candidate in _entries.values) {
      for (final item in candidate.hits) {
        if (item.lineId == id) {
          entry = candidate;
          hit = item;
          break;
        }
      }
      if (hit != null) break;
    }
    if (entry == null || hit == null) return null;
    if (ep < 1 || ep > hit.episodes) return null;
    if (hit.borrowed) {
      if (hit.borrowVodId.isEmpty || hit.borrowLineId.isEmpty) return null;
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

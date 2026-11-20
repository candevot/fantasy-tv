import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../services/cms_bridge.dart';
import '../services/fallback_match.dart';
import '../services/source_hub.dart';
import '../theme.dart';
import 'fx_line_group_selector.dart';
import 'together_client.dart';
import 'together_ui.dart';

/* ========================================================================== */
/*  一起看 · 建房 / 换片选择器（三步，房间外与房间内共用一套）                  */
/*                                                                            */
/*  第 1 步  搜片名 → 列出所有源的匹配（每张卡标来源：幻想 / 咕噜 / 剧圈 …）    */
/*  第 2 步  选片 → 列出这部片在各个源下的版本（线路数、画质、集数）            */
/*  第 3 步  选源 → 列出该源的线路 → 选一条线路                                */
/*                                                                            */
/*  返回一份 [TogetherRoomDraft]：源 + 片 + 该源的线路列表 + 选中线路。        */
/*  建房用它，房间内换片也用它 —— 只有「选完干什么」不同，选择过程完全一样。   */
/* ========================================================================== */

/// 三步选择器的结果：房间要绑定的「源 + 片 + 线路列表 + 当前线路」。
class TogetherRoomDraft {
  const TogetherRoomDraft({
    required this.sourceKey,
    required this.sourceName,
    required this.sourceKind,
    required this.sourceApi,
    required this.vodId,
    required this.vodName,
    required this.vodYear,
    required this.episodes,
    required this.lines,
    required this.line,
    this.cover = '',
    this.rating = 0,
  });

  /// 源：`hx`（幻想自建）/ `咕噜` / `剧圈` …（外部源用 KSource.key）。
  final String sourceKey;
  final String sourceName;

  /// `jar` / `cms` / `direct` / `hx`。
  final String sourceKind;
  final String sourceApi;

  /// 片：`vodId` 就是卡片 id（外部源带 `@src:<key>::` 前缀）。
  final String vodId;
  final String vodName;
  final int vodYear;
  final int episodes;

  /// 该源的线路列表（房间绑定的就是这一份）。
  final List<TogetherLine> lines;

  /// 选中的线路（[TogetherLine.name]）。
  final String line;
  final String cover;
  final num rating;

  /// 给服务端 / UI 看的「源 + 片」摘要。
  String get summarySource => sourceName.isEmpty ? sourceKey : sourceName;

  String get summaryVod =>
      vodYear > 0 ? '$vodName（$vodYear）' : vodName;

  TogetherLine? get pickedLine {
    for (final line in lines) {
      if (line.name == this.line || line.id == this.line) return line;
    }
    return lines.isEmpty ? null : lines.first;
  }
}

/// 打开三步选择器；用户取消返回 null。
///
/// [initialQuery] 预填搜索词（详情页进来时可以带片名）。
/// [currentVodId] / [currentSourceKey] 用于在列表里标出「当前房间正在用的」。
Future<TogetherRoomDraft?> showTogetherRoomPicker(
  BuildContext context, {
  String initialQuery = '',
  String currentVodId = '',
  String currentSourceKey = '',
}) {
  return showModalBottomSheet<TogetherRoomDraft>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    barrierColor: Colors.black.withValues(alpha: .34),
    builder: (ctx) => _TogetherRoomPicker(
      initialQuery: initialQuery,
      currentVodId: currentVodId,
      currentSourceKey: currentSourceKey,
    ),
  );
}

/* ------------------------------------------------------------ 源解析 */

/// 卡片 → 源信息。主站 id（没有 `@src:` 前缀）算我们自己的「幻想」。
({String key, String name, String kind, String api}) togetherSourceOfCard(
  VideoCard card,
) {
  final source = SourceHub.instance.decodeSource(card.id);
  if (source != null) {
    return (
      key: source.key,
      name: source.name.trim().isEmpty ? source.key : source.name.trim(),
      kind: source.kind.name,
      api: source.api,
    );
  }
  final label = card.sourceLabel.trim();
  final own = label.isEmpty ||
      label == KSource.ownResultLabel ||
      card.id.startsWith('v_') ||
      !card.id.contains(SourceHub.idMark);
  return (
    key: own ? 'hx' : label,
    name: own ? KSource.ownResultLabel : label,
    kind: 'hx',
    api: '',
  );
}

/// 视频 id → 源信息（详情页「一起看」入口用：id 带 `@src:` 就是外部源，
/// 裸 id 就是我们自己的「幻想」库）。
({String key, String name, String kind, String api}) togetherSourceOfId(
  String id, {
  String label = '',
}) {
  final source = SourceHub.instance.decodeSource(id);
  if (source != null) {
    return (
      key: source.key,
      name: source.name.trim().isEmpty ? source.key : source.name.trim(),
      kind: source.kind.name,
      api: source.api,
    );
  }
  final text = label.trim();
  final name = text.isEmpty || text == KSource.ownResultLabel
      ? KSource.ownResultLabel
      : text;
  return (key: 'hx', name: name, kind: 'hx', api: '');
}

/// 线路名 → 房间线路（房间绑定列表用）。
TogetherLine togetherLineOfInfo(LineInfo line, {int episodes = 0}) {
  final name = line.displayName.trim();
  return TogetherLine(
    name: name.isEmpty ? line.id : name,
    id: line.id,
    episodes: line.epNames.isNotEmpty ? line.epNames.length : episodes,
  );
}

/* ------------------------------------------------------------ 选择器 */

enum _Step { search, versions, lines }

class _TogetherRoomPicker extends StatefulWidget {
  const _TogetherRoomPicker({
    required this.initialQuery,
    required this.currentVodId,
    required this.currentSourceKey,
  });

  final String initialQuery;
  final String currentVodId;
  final String currentSourceKey;

  @override
  State<_TogetherRoomPicker> createState() => _TogetherRoomPickerState();
}

class _TogetherRoomPickerState extends State<_TogetherRoomPicker> {
  static const Duration _debounceDelay = Duration(milliseconds: 320);

  final TextEditingController _query = TextEditingController();
  Timer? _debounce;
  StreamSubscription<SearchBatch>? _sub;

  _Step _step = _Step.search;

  /// 第 1 步的所有结果（**不跨源合并**：同一部片在咕噜/剧圈各一条，都给出来）。
  final List<VideoCard> _results = <VideoCard>[];
  bool _searching = false;
  int _done = 0;
  int _total = 0;
  String _error = '';
  int _requestId = 0;

  /// 第 2 步选中的片，第 3 步选中的源。
  VideoCard? _picked;
  final List<_Version> _versions = <_Version>[];
  _Version? _pickedVersion;

  @override
  void initState() {
    super.initState();
    _query.text = widget.initialQuery;
    if (widget.initialQuery.trim().isEmpty) {
      // 没有预填词：直接给热门（和旧选择器一致，进来就能点）。
      unawaited(_loadInitial());
    } else {
      unawaited(_search(widget.initialQuery));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _sub?.cancel();
    _query.dispose();
    super.dispose();
  }

  /* ------------------------------------------------ 第 1 步：搜片 */

  Future<void> _loadInitial() async {
    final request = ++_requestId;
    setState(() {
      _searching = true;
      _error = '';
      _results.clear();
    });
    try {
      final home = await CmsBridge.home('recommend');
      var items = <VideoCard>[
        for (final section in home.sections) ...section.items,
      ];
      if (items.isEmpty) {
        try {
          items = await CmsBridge.category(type: 'tv', sort: 'latest', page: 1);
        } catch (_) {
          // 推荐为空、兜底也失败时按空结果处理。
        }
      }
      if (!mounted || request != _requestId) return;
      setState(() {
        _results
          ..clear()
          ..addAll(_sanitize(items));
        _searching = false;
      });
    } catch (e) {
      if (!mounted || request != _requestId) return;
      setState(() {
        _searching = false;
        _error = _messageOf(e);
      });
    }
  }

  Future<void> _search(String value) async {
    final keyword = value.trim();
    if (keyword.isEmpty) {
      await _loadInitial();
      return;
    }
    await _sub?.cancel();
    final request = ++_requestId;
    setState(() {
      _searching = true;
      _error = '';
      _done = 0;
      _total = 0;
      _results.clear();
    });
    final seen = <String>{};
    _sub = CmsBridge.searchStream(keyword, 1, keepDuplicates: true).listen(
      (batch) {
        if (!mounted || request != _requestId) return;
        final fresh = <VideoCard>[];
        for (final card in _sanitize(batch.items)) {
          if (seen.add('${card.id}|${card.title}')) fresh.add(card);
        }
        setState(() {
          _results.addAll(fresh);
          _done = batch.done;
          _total = batch.total;
          if (batch.finished) _searching = false;
        });
      },
      onError: (Object e) {
        if (!mounted || request != _requestId) return;
        setState(() {
          _searching = false;
          if (_results.isEmpty) _error = _messageOf(e);
        });
      },
      onDone: () {
        if (!mounted || request != _requestId) return;
        setState(() => _searching = false);
      },
    );
  }

  List<VideoCard> _sanitize(Iterable<VideoCard> raw) {
    final out = <VideoCard>[];
    for (final card in raw) {
      if (card.id.trim().isEmpty || card.title.trim().isEmpty) continue;
      if (SourceHub.isLiveCard(card)) continue;
      out.add(card);
    }
    return out;
  }

  String _messageOf(Object error) => error is ApiException
      ? error.message
      : '搜索失败，请稍后重试';

  /* ------------------------------------------------ 第 2 步：同片各源版本 */

  void _pickVod(VideoCard card) {
    _picked = card;
    _step = _Step.versions;
    _versions.clear();
    // 同名的其它源版本：不合并，一源一行，让用户按「线路数 / 画质 / 集数」自己挑。
    final same = <String, _Version>{};
    for (final item in _results) {
      if (!fxSameTitle(item.title, card.title)) continue;
      if (item.year > 0 && card.year > 0 && !fxYearCompatible(card.year, item.year)) {
        continue;
      }
      final source = togetherSourceOfCard(item);
      final key = source.key.isEmpty ? source.name : source.key;
      final existing = same[key];
      if (existing == null || item.episodes > existing.card.episodes) {
        same[key] = _Version(card: item, source: source);
      }
    }
    // 选中的那一条永远排第一。
    final own = same.remove(togetherSourceOfCard(card).key);
    if (own != null) _versions.add(own);
    _versions.addAll(same.values);
    setState(() {});
    for (final version in _versions) {
      unawaited(_loadVersion(version));
    }
  }

  Future<void> _loadVersion(_Version version) async {
    if (version.loading || version.loaded) return;
    version.loading = true;
    if (mounted) setState(() {});
    try {
      final detail = await CmsBridge.detail(version.card.id);
      final episodes = detail.allEpisodes.isNotEmpty
          ? detail.allEpisodes.length
          : (detail.episodes > 0 ? detail.episodes : version.card.episodes);
      // FUSION（2026-11-21）：建房也要能看到 jar 源的同名子线路（`咕噜·4K`），
      // 否则「创建时选咕噜大类」这一步根本不存在。只在搜索时命中过才有，
      // 而且拿不到就当没有，不影响建房。
      var lines = detail.lines;
      try {
        final extra = await CmsBridge.jarLinesFor(detail);
        if (extra.isNotEmpty) {
          final have = <String>{for (final l in lines) l.name};
          lines = <LineInfo>[
            ...lines,
            for (final l in extra)
              if (!have.contains(l.name)) l,
          ];
        }
      } catch (_) {
        // jar 源失败不影响建房。
      }
      version.lines = <TogetherLine>[
        for (final line in lines) togetherLineOfInfo(line, episodes: episodes),
      ];
      version.episodes = episodes;
      version.loaded = true;
    } catch (e) {
      version.failed = true;
      version.error = _messageOf(e);
    } finally {
      version.loading = false;
      if (mounted) setState(() {});
    }
  }

  void _pickVersion(_Version version) {
    _pickedVersion = version;
    _step = _Step.lines;
    if (!version.loaded && !version.loading) unawaited(_loadVersion(version));
    setState(() {});
  }

  void _back() {
    switch (_step) {
      case _Step.lines:
        _step = _Step.versions;
        _pickedVersion = null;
      case _Step.versions:
        _step = _Step.search;
        _pickedVersion = null;
        _versions.clear();
      case _Step.search:
        Navigator.of(context).maybePop();
        return;
    }
    setState(() {});
  }

  void _finish(_Version version, TogetherLine line) {
    final source = version.source;
    Navigator.of(context).pop(TogetherRoomDraft(
      sourceKey: source.key.isEmpty ? source.name : source.key,
      sourceName: source.name.isEmpty ? source.key : source.name,
      sourceKind: source.kind,
      sourceApi: source.api,
      vodId: version.card.id,
      vodName: version.card.title,
      vodYear: version.card.year,
      episodes: version.episodes,
      lines: version.lines,
      line: line.name,
      cover: version.card.cover,
      rating: version.card.rating,
    ));
  }

  /* ------------------------------------------------ UI */

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        constraints: BoxConstraints(maxHeight: height * .82),
        decoration: const BoxDecoration(
          color: Color(0xFFF9FBFF),
          borderRadius: BorderRadius.all(Radius.circular(26)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _header(),
            const SizedBox(height: 10),
            Flexible(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final (index, total) = switch (_step) {
      _Step.search => (0, 3),
      _Step.versions => (1, 3),
      _Step.lines => (2, 3),
    };
    final titles = <String>['搜片名', '选源', '选线路'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (_step != _Step.search)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: InkWell(
                  onTap: _back,
                  borderRadius: BorderRadius.circular(14),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(
                      Icons.arrow_back_ios_new_rounded,
                      size: 15,
                      color: Fx.ink,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: Text(
                '一起看 · ${titles[index]}',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: Fx.ink,
                ),
              ),
            ),
            Text(
              '${index + 1}/$total',
              style: TextStyle(
                fontSize: 10.5,
                color: Fx.sub.withValues(alpha: .9),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (var i = 0; i < titles.length; i++) ...[
              if (i > 0)
                Expanded(
                  child: Container(
                    height: 2,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    color: i <= index
                        ? Fx.accent.withValues(alpha: .55)
                        : const Color(0xFFE4E9F2),
                  ),
                ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: i == index
                      ? Fx.accent.withValues(alpha: .12)
                      : const Color(0xFFEFF3FA),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  titles[i],
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: i == index ? Fx.accent : Fx.sub,
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _body() {
    switch (_step) {
      case _Step.search:
        return _buildSearch();
      case _Step.versions:
        return _buildVersions();
      case _Step.lines:
        return _buildLines();
    }
  }

  Widget _buildSearch() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _query,
          textInputAction: TextInputAction.search,
          style: const TextStyle(fontSize: 13, color: Fx.ink),
          decoration: InputDecoration(
            isDense: true,
            hintText: '搜片名，选一个源开房',
            hintStyle: TextStyle(fontSize: 12.5, color: Fx.sub.withValues(alpha: .7)),
            prefixIcon: const Icon(Icons.search_rounded, size: 17, color: Fx.sub),
            suffixIcon: _query.text.isEmpty
                ? null
                : InkWell(
                    onTap: () {
                      _query.clear();
                      unawaited(_loadInitial());
                    },
                    child: const Icon(Icons.close_rounded, size: 16, color: Fx.sub),
                  ),
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFE6EBF4)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Color(0xFFE6EBF4)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: Fx.accent.withValues(alpha: .55)),
            ),
          ),
          onChanged: (value) {
            _debounce?.cancel();
            setState(() {});
            _debounce = Timer(_debounceDelay, () {
              if (!mounted) return;
              unawaited(_search(value));
            });
          },
          onSubmitted: (value) {
            _debounce?.cancel();
            unawaited(_search(value));
          },
        ),
        if (_searching) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  valueColor: AlwaysStoppedAnimation<Color>(Fx.accent),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _total > 0 ? '已查 $_done/$_total 个源…' : '正在搜索…',
                style: TextStyle(fontSize: 10.5, color: Fx.sub.withValues(alpha: .9)),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Flexible(child: _resultList()),
      ],
    );
  }

  Widget _resultList() {
    if (_error.isNotEmpty && _results.isEmpty) {
      return _empty('$_error', retry: true);
    }
    if (_results.isEmpty) {
      return _empty(_searching ? '正在搜索…' : '没有找到，换个片名试试');
    }
    return ListView.separated(
      shrinkWrap: true,
      itemCount: _results.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (ctx, i) => _ResultTile(
        card: _results[i],
        onTap: () => _pickVod(_results[i]),
      ),
    );
  }

  Widget _buildVersions() {
    final card = _picked;
    if (card == null) return _empty('没有选片');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '「${card.title}」在这些源上都有，点一个源继续选线路',
          style: TextStyle(fontSize: 10.5, color: Fx.sub.withValues(alpha: .92)),
        ),
        const SizedBox(height: 8),
        Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: _versions.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (ctx, i) => _VersionTile(
              version: _versions[i],
              current: widget.currentVodId.isNotEmpty &&
                  _versions[i].card.id == widget.currentVodId,
              onTap: () => _pickVersion(_versions[i]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLines() {
    final version = _pickedVersion;
    if (version == null) return _empty('没有选源');
    if (version.loading && version.lines.isEmpty) {
      return _empty('正在读取「${version.source.name}」的线路…');
    }
    if (version.failed && version.lines.isEmpty) {
      return _empty(
        '读不到这个源的线路（${version.error}）',
        retry: true,
        onRetry: () {
          version.failed = false;
          unawaited(_loadVersion(version));
        },
      );
    }
    if (version.lines.isEmpty) {
      return _empty('这个源没有可用的线路');
    }
    final episodes = version.episodes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${version.source.name} · ${version.card.title}'
          '${episodes > 0 ? ' · $episodes 集' : ''}',
          style: TextStyle(fontSize: 10.5, color: Fx.sub.withValues(alpha: .92)),
        ),
        const SizedBox(height: 8),
        // LINE_GROUPS（2026-11-21）：建房「选线路」一步和详情页 / 房间面板
        // 用同一个两行组件：第一行大类（幻想 / 咕噜 / 剧圈 / 橘汁 / 下饭），
        // 第二行该大类的子线路。选定后房间以「大类 + 子线路」作为初始线路。
        Flexible(
          child: SingleChildScrollView(
            child: FxLineGroupSelector(
              lines: <LineInfo>[
                for (final line in version.lines)
                  LineInfo(line.id, line.name, 'hls', 0),
              ],
              currentLineId: '',
              padding: EdgeInsets.zero,
              showHint: false,
              selectFirstOnGroupChange: false,
              onSelected: (picked) {
                // 组件给的是 LineInfo，这里换回建房用的 TogetherLine
                // （房间线路按名字广播，名字里带了大类前缀）。
                final line = version.lines.firstWhere(
                  (l) => l.id == picked.id,
                  orElse: () => version.lines.firstWhere(
                    (l) => l.name == picked.name,
                    orElse: () => version.lines.first,
                  ),
                );
                _finish(version, line);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _empty(String text, {bool retry = false, VoidCallback? onRetry}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 26),
      child: Column(
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, color: Fx.sub.withValues(alpha: .85)),
          ),
          if (retry) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: onRetry ?? () => unawaited(_search(_query.text)),
              child: const Text('重试', style: TextStyle(fontSize: 12)),
            ),
          ],
        ],
      ),
    );
  }
}

/// 第 2 步的一行：某个源上的这部片。
class _Version {
  _Version({required this.card, required this.source});

  final VideoCard card;
  final ({String key, String name, String kind, String api}) source;

  List<TogetherLine> lines = const <TogetherLine>[];
  int episodes = 0;
  bool loading = false;
  bool loaded = false;
  bool failed = false;
  String error = '';

  /// 画质提示：从线路名里认 4K / 1080P（线路自带的 quality 优先）。
  List<String> get qualityTags {
    final out = <String>[];
    for (final line in lines) {
      final q = line.qualityLabel;
      if (q.isNotEmpty && !out.contains(q)) out.add(q);
    }
    if (out.isEmpty) return const <String>[];
    // 只留最高的两档，避免一排标签把行挤爆。
    const order = <String>['4K', '2K', '1080P', '720P'];
    out.sort((a, b) {
      final ia = order.indexOf(a);
      final ib = order.indexOf(b);
      return (ia < 0 ? 99 : ia).compareTo(ib < 0 ? 99 : ib);
    });
    return out.take(2).toList();
  }
}

/* ------------------------------------------------------------ 行样式 */

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.card, required this.onTap});

  final VideoCard card;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final source = togetherSourceOfCard(card);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFEDF1F8)),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 52,
                height: 70,
                child: TogetherCover(
                  cover: togetherCoverUrl(card.cover),
                  title: card.title,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    card.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: Fx.ink,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 5,
                    runSpacing: 4,
                    children: [
                      _tag(source.name, accent: true),
                      if (card.year > 0) _tag('${card.year}'),
                      if (card.episodes > 0) _tag('${card.episodes} 集'),
                      if (card.rating > 0) _tag('评分 ${card.rating}'),
                      if (card.heat.trim().isNotEmpty) _tag(card.heat.trim()),
                    ],
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 18, color: Fx.sub),
          ],
        ),
      ),
    );
  }
}

class _VersionTile extends StatelessWidget {
  const _VersionTile({
    required this.version,
    required this.onTap,
    required this.current,
  });

  final _Version version;
  final VoidCallback onTap;
  final bool current;

  @override
  Widget build(BuildContext context) {
    final tags = version.qualityTags;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: current
                ? Fx.accent.withValues(alpha: .45)
                : const Color(0xFFEDF1F8),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          version.source.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: Fx.ink,
                          ),
                        ),
                      ),
                      if (current) ...[
                        const SizedBox(width: 6),
                        _tag('房间正在用', accent: true),
                      ],
                    ],
                  ),
                  const SizedBox(height: 5),
                  if (version.loading && !version.loaded)
                    Text(
                      '正在读取线路…',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: Fx.sub.withValues(alpha: .85),
                      ),
                    )
                  else if (version.failed)
                    Text(
                      '线路读取失败，点进去可重试',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: Fx.sub.withValues(alpha: .85),
                      ),
                    )
                  else
                    Wrap(
                      spacing: 5,
                      runSpacing: 4,
                      children: [
                        _tag('${version.lines.length} 条线路'),
                        for (final q in tags) _tag(q, accent: q == '4K'),
                        if (version.episodes > 0) _tag('${version.episodes} 集'),
                      ],
                    ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 18, color: Fx.sub),
          ],
        ),
      ),
    );
  }
}

Widget _tag(String text, {bool accent = false}) {
  if (text.trim().isEmpty) return const SizedBox.shrink();
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: accent
          ? Fx.accent.withValues(alpha: .12)
          : const Color(0xFFF1F4FA),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 9.5,
        fontWeight: FontWeight.w600,
        color: accent ? Fx.accent : Fx.sub,
      ),
    ),
  );
}

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../services/cms_bridge.dart';
import '../theme.dart';
import 'fx_cards.dart';
import 'player_theme.dart';
import 'together_ui.dart';

/// 一起看 · 选片弹层：搜索 / 从热门选。
Future<VideoCard?> showTogetherVideoPicker(BuildContext context) {
  return showModalBottomSheet<VideoCard>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: .28),
    builder: (_) => const _TogetherVideoPicker(),
  );
}

/// 一起看 · 选集弹层。
Future<int?> showTogetherEpisodePicker(
  BuildContext context, {
  required List<Episode> episodes,
  required int current,
  String title = '',
}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: .28),
    builder: (_) => _TogetherEpisodePicker(
      episodes: episodes,
      current: current,
      title: title,
    ),
  );
}

class _TogetherVideoPicker extends StatefulWidget {
  const _TogetherVideoPicker();

  @override
  State<_TogetherVideoPicker> createState() => _TogetherVideoPickerState();
}

enum _PickerStatus { loading, ready, empty, error }

class _TogetherVideoPickerState extends State<_TogetherVideoPicker> {
  static const Duration _debounceDelay = Duration(milliseconds: 300);

  final TextEditingController _query = TextEditingController();
  Timer? _debounce;
  List<VideoCard> _items = const [];
  _PickerStatus _status = _PickerStatus.loading;
  String _activeQuery = '';
  String _errorDetail = '';
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _loadInitial();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _requestId++;
    _query.dispose();
    super.dispose();
  }

  /// 初始列表：`GET /api/home?channel=recommend` 的
  /// `data.sections[].items[]`，跨分区按 id 去重。
  /// 推荐区为空时退回「最新剧集」；两者都失败才展示错误态。
  Future<void> _loadInitial() async {
    final request = ++_requestId;
    if (mounted) {
      setState(() {
        _status = _PickerStatus.loading;
        _items = const [];
        _activeQuery = '';
        _errorDetail = '';
      });
    }
    try {
      final home = await CmsBridge.home('recommend');
      var items = _sanitize(<VideoCard>[
        for (final section in home.sections) ...section.items,
      ]);
      if (items.isEmpty) {
        try {
          items = _sanitize(
            await CmsBridge.category(type: 'tv', sort: 'latest', page: 1),
          );
        } catch (_) {
          // 推荐为空、兜底接口也不可用时按空结果处理。
        }
      }
      if (!mounted || request != _requestId) return;
      setState(() {
        _items = items;
        _status = items.isEmpty ? _PickerStatus.empty : _PickerStatus.ready;
      });
    } catch (e) {
      if (!mounted || request != _requestId) return;
      setState(() {
        _items = const [];
        _status = _PickerStatus.error;
        _errorDetail = _messageOf(e);
      });
    }
  }

  /// 搜索：`GET /api/search?q=<kw>&page=1` 的 `data.items[]`，
  /// 与初始列表同样按 id 去重、跳过脏条目。
  Future<void> _search(String q) async {
    final keyword = q.trim();
    if (keyword.isEmpty) {
      await _loadInitial();
      return;
    }
    final request = ++_requestId;
    if (mounted) {
      setState(() {
        _status = _PickerStatus.loading;
        _items = const [];
        _activeQuery = keyword;
        _errorDetail = '';
      });
    }
    try {
      final items = _sanitize(await CmsBridge.search(keyword, 1));
      if (!mounted || request != _requestId || _query.text.trim() != keyword) {
        return;
      }
      setState(() {
        _items = items;
        _status = items.isEmpty ? _PickerStatus.empty : _PickerStatus.ready;
      });
    } catch (e) {
      if (!mounted || request != _requestId || _query.text.trim() != keyword) {
        return;
      }
      setState(() {
        _items = const [];
        _status = _PickerStatus.error;
        _errorDetail = _messageOf(e);
      });
    }
  }

  List<VideoCard> _sanitize(Iterable<VideoCard> raw) {
    final seen = <String>{};
    final items = <VideoCard>[];
    for (final card in raw) {
      final id = card.id.trim();
      if (id.isEmpty || card.title.trim().isEmpty) continue;
      if (!seen.add(id)) continue;
      items.add(card);
    }
    return items;
  }

  String _messageOf(Object error) {
    if (error is ApiException) return error.message;
    return '网络请求失败，请稍后重试';
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    final q = value.trim();
    // 只刷新输入框右侧的清除按钮，不等请求。
    setState(() {});
    _debounce = Timer(_debounceDelay, () {
      if (!mounted) return;
      if (q.isEmpty) {
        _loadInitial();
      } else {
        _search(q);
      }
    });
  }

  void _retry() {
    _debounce?.cancel();
    final q = _query.text.trim();
    if (q.isEmpty) {
      _loadInitial();
    } else {
      _search(q);
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: FractionallySizedBox(
        heightFactor: .9,
        child: Container(
          decoration: const BoxDecoration(
            color: Color(0xFFF9FBFF),
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
            boxShadow: [
              BoxShadow(
                color: Color(0x33263A5A),
                blurRadius: 40,
                offset: Offset(0, -8),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD4DCEA),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 12, 2),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '一起看 · 选片',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: Fx.ink,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              '选一部想和朋友同步看的影片',
                              style: TextStyle(fontSize: 10.5, color: Fx.sub),
                            ),
                          ],
                        ),
                      ),
                      TogetherCircleButton(
                        icon: Icons.close_rounded,
                        size: 34,
                        onTap: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Container(
                    height: 42,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .78),
                      borderRadius: BorderRadius.circular(21),
                      border: Border.all(color: Colors.white),
                    ),
                    child: TextField(
                      controller: _query,
                      onChanged: _onQueryChanged,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (v) {
                        _debounce?.cancel();
                        final q = v.trim();
                        if (q.isEmpty) {
                          _loadInitial();
                        } else {
                          _search(q);
                        }
                      },
                      style: const TextStyle(fontSize: 13, color: Fx.ink),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: '搜索想看的剧',
                        hintStyle: TextStyle(
                          fontSize: 12.5,
                          color: Fx.sub.withValues(alpha: .7),
                        ),
                        prefixIcon: Icon(
                          Icons.search_rounded,
                          size: 19,
                          color: Fx.sub.withValues(alpha: .8),
                        ),
                        suffixIcon: _query.text.isEmpty
                            ? null
                            : GestureDetector(
                                onTap: () {
                                  _debounce?.cancel();
                                  _query.clear();
                                  setState(() {});
                                  _loadInitial();
                                },
                                child: Icon(
                                  Icons.cancel_rounded,
                                  size: 17,
                                  color: Fx.sub.withValues(alpha: .55),
                                ),
                              ),
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(child: _buildBody()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_status) {
      case _PickerStatus.loading:
        return const _TogetherPickerSkeleton();
      case _PickerStatus.error:
        return _buildError();
      case _PickerStatus.empty:
        return _buildEmpty();
      case _PickerStatus.ready:
        return _buildGrid();
    }
  }

  /// 失败态：文案 + 可点重试，不再停留在 loading。
  Widget _buildError() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _retry,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Fx.accent.withValues(alpha: .10),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.cloud_off_rounded,
                  size: 27,
                  color: Fx.accent,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '加载失败，点击重试',
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: Fx.ink,
                ),
              ),
              if (_errorDetail.isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(
                  _errorDetail,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.4,
                    color: Fx.sub.withValues(alpha: .9),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: 132,
                child: GradButton(
                  text: '重试',
                  icon: Icons.refresh_rounded,
                  height: 40,
                  onTap: _retry,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 空态：搜索无结果与初始推荐为空统一文案。
  Widget _buildEmpty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: Fx.accent.withValues(alpha: .08),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.search_off_rounded,
                size: 27,
                color: Fx.accent.withValues(alpha: .75),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              '没有找到相关影片',
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
                color: Fx.ink,
              ),
            ),
            if (_activeQuery.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                '换个关键词试试',
                style: TextStyle(
                  fontSize: 11.5,
                  color: Fx.sub.withValues(alpha: .85),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGrid() {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: _items.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: .56,
        mainAxisSpacing: 14,
        crossAxisSpacing: 11,
      ),
      itemBuilder: (context, i) => _VideoTile(
        card: _items[i],
        onTap: () => Navigator.of(context).pop(_items[i]),
      ),
    );
  }
}

/// 选片列表加载骨架：3 列 × 5 行，和正式海报网格同尺寸。
class _TogetherPickerSkeleton extends StatelessWidget {
  const _TogetherPickerSkeleton();

  @override
  Widget build(BuildContext context) {
    return FxSkeletonPulse(
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        itemCount: 15,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: .56,
          mainAxisSpacing: 14,
          crossAxisSpacing: 11,
        ),
        itemBuilder: (context, i) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Expanded(child: FxSkeletonBox(radius: 13)),
            const SizedBox(height: 6),
            const FxSkeletonBox(height: 11, radius: 4),
            const SizedBox(height: 4),
            FractionallySizedBox(
              widthFactor: .56,
              child: const FxSkeletonBox(height: 9, radius: 4),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoTile extends StatelessWidget {
  const _VideoTile({required this.card, required this.onTap});

  final VideoCard card;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                TogetherCover(cover: card.cover, title: card.title, radius: 13),
                if (card.rating > 0)
                  Positioned(
                    right: 5,
                    top: 5,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .45),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        card.rating.toStringAsFixed(1),
                        style: const TextStyle(
                          color: Fx.gold,
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          Text(
            card.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Fx.ink,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            [
              if (card.year > 0) '${card.year}',
              if (card.episodes > 0)
                '${card.episodes}集'
              else if (card.status.isNotEmpty)
                card.status,
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 9, color: Fx.sub.withValues(alpha: .85)),
          ),
        ],
      ),
    );
  }
}

class _TogetherEpisodePicker extends StatelessWidget {
  const _TogetherEpisodePicker({
    required this.episodes,
    required this.current,
    required this.title,
  });

  final List<Episode> episodes;
  final int current;
  final String title;

  String _labelFor(int n) {
    for (final e in episodes) {
      if (e.n == n) return fxEpisodeLabel(e.n, e.name);
    }
    return fxEpisodeLabel(n);
  }

  @override
  Widget build(BuildContext context) {
    // PANEL_COMPACT（2026-11-15）：与主播放全屏的选集面板同一个高度规则 ——
    // 屏高 35%（最低 240、最高 460），内部滚动，别占大半屏。
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final height = math
        .min(460.0, math.max(240.0, size.height * .35))
        .toDouble();
    final available = math
        .max(240.0, size.height - pad.top - pad.bottom - 24)
        .toDouble();
    return SizedBox(
      height: math.min(height, available),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFFF9FBFF),
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: [
            BoxShadow(
              color: Color(0x33263A5A),
              blurRadius: 40,
              offset: Offset(0, -8),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              const SizedBox(height: 8),
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFD4DCEA),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 12, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title.isEmpty ? '选集' : '选集 · $title',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: Fx.ink,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '共 ${fxMainEpisodeCount(episodes)} 集 · 当前 ${_labelFor(current)}',
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: Fx.sub,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TogetherCircleButton(
                      icon: Icons.close_rounded,
                      size: 34,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: episodes.isEmpty
                    ? Center(
                        child: Text(
                          '暂无剧集信息',
                          style: TextStyle(
                            fontSize: 12,
                            color: Fx.sub.withValues(alpha: .8),
                          ),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        itemCount: episodes.length,
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 5,
                              childAspectRatio: 1.62,
                              mainAxisSpacing: 8,
                              crossAxisSpacing: 8,
                            ),
                        itemBuilder: (context, i) {
                          final ep = episodes[i];
                          final active = ep.n == current;
                          return GestureDetector(
                            onTap: () => Navigator.of(context).pop(ep.n),
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                gradient: active ? Fx.brand : null,
                                color: active
                                    ? null
                                    : Colors.white.withValues(alpha: .72),
                                borderRadius: BorderRadius.circular(11),
                                border: Border.all(
                                  color: active
                                      ? Colors.transparent
                                      : Colors.white.withValues(alpha: .95),
                                ),
                              ),
                              child: Text(
                                fxEpisodeLabel(ep.n, ep.name),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: active
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: active ? Colors.white : Fx.ink,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

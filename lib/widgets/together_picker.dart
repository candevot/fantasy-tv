import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'player_theme.dart';
import 'together_ui.dart';

/// 一起看 · 选片弹层：搜索 / 从热门选。
Future<VideoCard?> showTogetherVideoPicker(BuildContext context) {
  return showModalBottomSheet<VideoCard>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(.28),
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
    barrierColor: Colors.black.withOpacity(.28),
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

class _TogetherVideoPickerState extends State<_TogetherVideoPicker> {
  final TextEditingController _query = TextEditingController();
  Timer? _debounce;
  List<VideoCard> _items = const [];
  bool _loading = true;
  bool _error = false;
  String _activeQuery = '';

  @override
  void initState() {
    super.initState();
    _loadHot();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  Future<void> _loadHot() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = false;
      _activeQuery = '';
    });

    List<VideoCard> items = const [];
    try {
      items = await Api.rank('hot').timeout(const Duration(seconds: 7));
    } catch (_) {
      // 排行榜不可用时再从首页热门里取。
    }
    if (!mounted) return;
    if (items.isEmpty) {
      try {
        final home = await Api.home('recommend').timeout(const Duration(seconds: 7));
        items = [for (final section in home.sections) ...section.items];
      } catch (_) {
        // 服务器不可用时保持空列表，不做本地假数据兜底。
      }
    }
    if (!mounted) return;

    final seen = <String>{};
    items = items.where((e) => e.id.isNotEmpty && seen.add(e.id)).toList();
    setState(() {
      _loading = false;
      _items = items;
      _error = items.isEmpty;
    });
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 420), () {
      if (!mounted) return;
      final q = value.trim();
      if (q.isEmpty) {
        _loadHot();
      } else {
        _search(q);
      }
    });
  }

  Future<void> _search(String q) async {
    setState(() {
      _loading = true;
      _error = false;
      _activeQuery = q;
    });
    try {
      final items = await Api.search(q, 1).timeout(const Duration(seconds: 8));
      if (!mounted || _activeQuery != q) return;
      setState(() {
        _loading = false;
        _items = items;
        _error = false;
      });
    } catch (_) {
      if (!mounted || _activeQuery != q) return;
      setState(() {
        _loading = false;
        _items = const [];
        _error = true;
      });
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
                      color: Colors.white.withOpacity(.78),
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
                        if (q.isNotEmpty) _search(q);
                      },
                      style: const TextStyle(fontSize: 13, color: Fx.ink),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: '搜索想看的剧',
                        hintStyle: TextStyle(
                          fontSize: 12.5,
                          color: Fx.sub.withOpacity(.7),
                        ),
                        prefixIcon: Icon(
                          Icons.search_rounded,
                          size: 19,
                          color: Fx.sub.withOpacity(.8),
                        ),
                        suffixIcon: _query.text.isEmpty
                            ? null
                            : GestureDetector(
                                onTap: () {
                                  _query.clear();
                                  _loadHot();
                                },
                                child: Icon(
                                  Icons.cancel_rounded,
                                  size: 17,
                                  color: Fx.sub.withOpacity(.55),
                                ),
                              ),
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 12),
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
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
            const SizedBox(height: 10),
            Text(
              '正在加载影片…',
              style: TextStyle(fontSize: 11, color: Fx.sub.withOpacity(.8)),
            ),
          ],
        ),
      );
    }
    if (_error) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.wifi_off_rounded,
              size: 34,
              color: Fx.sub.withOpacity(.4),
            ),
            const SizedBox(height: 10),
            Text(
              '暂无内容，请稍后重试',
              style: TextStyle(fontSize: 12, color: Fx.sub.withOpacity(.9)),
            ),
            const SizedBox(height: 14),
            GestureDetector(
              onTap: _activeQuery.isEmpty
                  ? _loadHot
                  : () => _search(_activeQuery),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                decoration: BoxDecoration(
                  gradient: Fx.brand,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Text(
                  '重新加载',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 34,
              color: Fx.sub.withOpacity(.4),
            ),
            const SizedBox(height: 10),
            Text(
              _activeQuery.isEmpty ? '暂无内容，请稍后重试' : '没有找到「$_activeQuery」',
              style: TextStyle(fontSize: 12, color: Fx.sub.withOpacity(.9)),
            ),
          ],
        ),
      );
    }
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
                TogetherCover(
                  cover: card.cover,
                  title: card.title,
                  radius: 13,
                ),
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
                        color: Colors.black.withOpacity(.45),
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
              if (card.episodes > 0) '${card.episodes}集' else if (card.status.isNotEmpty) card.status,
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 9, color: Fx.sub.withOpacity(.85)),
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
    return FractionallySizedBox(
      heightFactor: .55,
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
                            color: Fx.sub.withOpacity(.8),
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
                                    : Colors.white.withOpacity(.72),
                                borderRadius: BorderRadius.circular(11),
                                border: Border.all(
                                  color: active
                                      ? Colors.transparent
                                      : Colors.white.withOpacity(.95),
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

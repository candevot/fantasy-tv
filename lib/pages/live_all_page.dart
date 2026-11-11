import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../utils/fx_route.dart';
import 'live_detail_page.dart';
import 'live_groups_page.dart' show LiveChannelCard, LiveSection, buildLiveSections;

/// 直播总览页：从首页「直播 · 全部」进入。
///
/// 首页只放横向滚动的精选频道，这里给出完整分组（央视 / 卫视 / 地方台…），
/// 每个分组一组网格，点任意台进播放页。样式复用 [LiveChannelCard]，
/// 与首页、直播详情保持一致。
class LiveAllPage extends StatefulWidget {
  const LiveAllPage({super.key});

  @override
  State<LiveAllPage> createState() => _LiveAllPageState();
}

class _LiveAllPageState extends State<LiveAllPage> {
  List<LiveGroup> _groups = const <LiveGroup>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final groups = await Api.liveGroups();
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final sections = buildLiveSections(_groups);
    return Scaffold(
      appBar: AppBar(title: const Text('直播')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('加载失败：$_error',
                          style: const TextStyle(color: Fx.sub)),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: sections.length,
                    itemBuilder: (ctx, i) => _section(sections[i]),
                  ),
                ),
    );
  }

  Widget _section(LiveSection s) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 3,
                height: 14,
                decoration: BoxDecoration(
                  color: Fx.accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                s.name,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Fx.ink,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${s.channels.length} 个台',
                style: const TextStyle(fontSize: 11, color: Fx.sub),
              ),
            ],
          ),
          const SizedBox(height: 10),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 1.15,
            ),
            itemCount: s.channels.length,
            itemBuilder: (ctx, i) {
              final c = s.channels[i];
              return LiveChannelCard(
                channel: c,
                onTap: () => _open(c, s.channels),
              );
            },
          ),
        ],
      ),
    );
  }

  void _open(LiveChannel c, List<LiveChannel> playlist) {
    Navigator.of(context).push(
      FxPageRoute(
        builder: (_) => LiveDetailPage(channel: c, playlist: playlist),
      ),
    );
  }
}

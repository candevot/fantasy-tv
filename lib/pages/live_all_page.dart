import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../services/cms_bridge.dart';
import '../services/live_source.dart';
import '../services/source_hub.dart';
import '../theme.dart';
import '../utils/fx_route.dart';
import 'category_page.dart' show fxErrorText;
import 'live_detail_page.dart';
import 'live_groups_page.dart' show LiveChannelCard, LiveSection, buildLiveSections;
import 'source_settings_page.dart';

/// 直播专区（底部导航「直播」的独立入口）。
///
/// 频道不写死在 App 里：地址由云端下发（后台 `/api/config` 的 `live_url`，
/// 或云端 `type: "live"` 的片源），App 只负责拉、自动识别格式（M3U / TXT /
/// JSON）、按「央视频道 / 卫视频道 / 地方频道 …」分组展示。
///
/// 直播与点播是两条数据线：首页推荐、搜索、排行榜都不查直播（见
/// `CmsBridge` 的多源合并逻辑），这里也不拿 CMS 的任何点播数据。
///
/// 云端没配直播地址时，回落到旧接口 `/api/live` —— 老服务端还有这份数据，
/// 只是新的直播源已经改成云端下发，回落只为「升级不瞎屏」。
class LiveAllPage extends StatefulWidget {
  const LiveAllPage({super.key});

  @override
  State<LiveAllPage> createState() => _LiveAllPageState();
}

class _LiveAllPageState extends State<LiveAllPage> {
  List<LiveSection> _sections = const <LiveSection>[];
  LiveCatalog? _catalog;
  bool _loading = true;
  bool _refreshing = false;
  String? _error;

  /// LIVE_FOLLOW_INTERFACE（2026-11-17）：当前导入的接口里**没有**直播源。
  ///
  /// 用户口径：「接口没带 lives → 直播页显示『当前接口没有直播源』，
  /// 不报错、不白屏」。所以这是空态，不是错误态。
  bool _noLive = false;
  bool _fromLegacy = false;
  int _req = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    final req = ++_req;
    if (mounted) {
      setState(() {
        _loading = _catalog == null;
        _refreshing = _catalog != null;
        _error = null;
        _noLive = false;
      });
    }
    try {
      final catalog = await LiveSourceService.load(force: force);
      if (!mounted || req != _req) return;
      final sections = buildLiveSections(catalog.groups);
      setState(() {
        _catalog = catalog;
        _sections = sections;
        _fromLegacy = false;
        _loading = false;
        _refreshing = false;
        _noLive = false;
        _error = sections.isEmpty ? '直播列表里没有可用频道' : null;
      });
    } catch (e) {
      if (!mounted || req != _req) return;
      // 接口没带 lives：这是空态，不是错误（不弹「加载失败」、不白屏）。
      if (SourceHub.instance.liveUrl.trim().isEmpty) {
        setState(() {
          _loading = false;
          _refreshing = false;
          _error = null;
          _noLive = true;
          _sections = const <LiveSection>[];
        });
        return;
      }
      if (!CmsBridge.legacyEnabled) {
        // 旧接口（8787）已随迁移下线：不再拿它兜底，直接把真实原因说清楚。
        // 「后台还没配直播接口地址」比先转 16 秒（8 秒超时 ×2 次重试）再报
        // 一个看不懂的网络错误有用得多。
        setState(() {
          _loading = false;
          _refreshing = false;
          _error = fxErrorText(e);
        });
        return;
      }
      await _loadLegacy(e, req);
    }
  }

  /// 云端没配 / 拉不到：回落到旧接口的分组数据。
  Future<void> _loadLegacy(Object cause, int req) async {
    if (!CmsBridge.legacyEnabled) {
      if (!mounted || req != _req) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        _error = fxErrorText(cause);
      });
      return;
    }
    try {
      final groups = await Api.liveGroups();
      if (!mounted || req != _req) return;
      final sections = buildLiveSections(groups);
      if (!mounted || req != _req) return;
      setState(() {
        _sections = sections;
        _catalog = null;
        _fromLegacy = true;
        _loading = false;
        _refreshing = false;
        _error = sections.isEmpty ? fxErrorText(cause) : null;
      });
    } catch (_) {
      if (!mounted || req != _req) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        _error = fxErrorText(cause);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('直播'),
        actions: [
          IconButton(
            tooltip: '片源设置',
            onPressed: _openSettings,
            icon: const Icon(Icons.tune_rounded),
          ),
          IconButton(
            tooltip: '刷新频道',
            onPressed: _refreshing ? null : () => _load(force: true),
            icon: _refreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_noLive && _sections.isEmpty) return _noLiveView();
    if (_error != null && _sections.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.live_tv_rounded, size: 40, color: Fx.sub),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                '加载失败：$_error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Fx.sub),
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '直播跟着接口走：导入的接口里带 lives 才有频道',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: Color(0xFFA6B1C2)),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => _load(force: true),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(force: true),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: _sections.length + 1,
        itemBuilder: (ctx, i) {
          if (i == 0) return _statusBar();
          return _section(_sections[i - 1]);
        },
      ),
    );
  }

  /// 接口里没有直播源时的空态（不报错、不白屏）。
  Widget _noLiveView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.live_tv_rounded, size: 40, color: Fx.sub),
            const SizedBox(height: 10),
            const Text(
              '当前接口没有直播源',
              style: TextStyle(fontSize: 14, color: Fx.ink),
            ),
            const SizedBox(height: 6),
            const Text(
              '直播跟着接口走：导入的接口里带 lives（TVBox 配置的直播列表）时，'
              '频道会自动出现在这里。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, height: 1.5, color: Fx.sub),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton(
                  onPressed: () => _load(force: true),
                  child: const Text('刷新'),
                ),
                const SizedBox(width: 10),
                TextButton(
                  onPressed: _openSettings,
                  child: const Text('片源管理'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部状态条：来源格式 + 频道数 + 更新时间（缓存时会说明）。
  Widget _statusBar() {
    final catalog = _catalog;
    final chips = <String>[
      if (_fromLegacy) '旧接口兜底',
      if (catalog != null) catalog.formatLabel,
      if (catalog != null) '${catalog.channelCount} 个台',
      if (catalog?.fromCache == true) '离线缓存',
    ];
    final at = catalog?.fetchedAt;
    if (at != null) chips.add('更新 ${_timeText(at)}');
    if (chips.isEmpty && _error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          const Icon(Icons.bolt_rounded, size: 13, color: Fx.accent),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              chips.isEmpty ? '$_error' : chips.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Fx.sub),
            ),
          ),
        ],
      ),
    );
  }

  static String _timeText(DateTime at) {
    final now = DateTime.now();
    final sameDay = now.year == at.year &&
        now.month == at.month &&
        now.day == at.day;
    final hm = '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
    return sameDay ? '今天 $hm' : '${at.month}-${at.day} $hm';
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

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      FxPageRoute(builder: (_) => const SourceSettingsPage()),
    );
    if (!mounted) return;
    // 从设置回来可能换过直播地址：强制重拉一次。
    await _load(force: true);
  }
}

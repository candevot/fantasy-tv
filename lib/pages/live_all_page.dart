import 'package:flutter/material.dart';

import '../models.dart';
import '../services/live_source.dart';
import '../services/live_validity.dart';
import '../theme.dart';
import '../utils/fx_route.dart';
import 'live_detail_page.dart';
import 'live_groups_page.dart' show LiveChannelCard, LiveSection, buildLiveSections;

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
    // LIVE_INVALID（2026-11-21）：播放页确认拿不到流时会登记失效台，
    // 这里跟着重建分组 —— 用户从播放页退回来，列表已经少掉那一台。
    LiveValidity.revision.addListener(_rebuildSections);
    _load();
  }

  @override
  void dispose() {
    LiveValidity.revision.removeListener(_rebuildSections);
    super.dispose();
  }

  /// 只重建分组（不重新拉数据）：失效标记 / 分组变化用。
  void _rebuildSections() {
    final catalog = _catalog;
    if (!mounted || catalog == null) return;
    setState(() => _sections = buildLiveSections(catalog.groups));
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
      // LIVE_SCAN（2026-11-20）：拉不到数据（扫描还没跑完 / 弱网 / 服务刚重启）
      // 不白屏、也不甩错误码 —— 显示「正在同步直播源，请稍候」，等后台出数据。
      setState(() {
        _loading = false;
        _refreshing = false;
        _error = null;
        _noLive = true;
        _sections = const <LiveSection>[];
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
                '正在同步直播源，请稍候',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Fx.sub),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '后台正在重扫频道（$_error）',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: Color(0xFFA6B1C2)),
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
              '正在同步直播源，请稍候',
              style: TextStyle(fontSize: 14, color: Fx.ink),
            ),
            const SizedBox(height: 6),
            const Text(
              '服务端会定时重扫所有频道，只保留实测能连通的台；稍等片刻或点刷新。',
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
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部状态条：一行搞定 —— `512 个台 · 更新 19:58`。
  ///
  /// LIVE_UI（2026-11-21）：原来这里还拼了来源格式（`JSON · 512 个台 …`），
  /// 用户看不懂也没用，还和「离线缓存」挤在一起显得乱。格式只在**兜底 / 缓存**
  /// 这类需要解释的状态下才出现，正常情况就是「台数 · 更新时间」两段。
  Widget _statusBar() {
    final catalog = _catalog;
    if (catalog == null && _error == null) return const SizedBox.shrink();
    // 台数按**当前显示**的台算：会话内被标记失效的台已经不在列表里，
    // 数字不跟着变会显得对不上。
    var visible = 0;
    for (final s in _sections) {
      visible += s.count;
    }
    final at = catalog?.fetchedAt;
    final parts = <String>[];
    if (visible > 0) parts.add('$visible 个台');
    if (at != null) parts.add('更新 ${_timeText(at)}');
    if (catalog?.fromCache == true) parts.add('离线缓存');
    if (_fromLegacy) parts.add('旧接口');
    if (parts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          const Icon(Icons.bolt_rounded, size: 13, color: Fx.accent),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              parts.join(' · '),
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

  /// 3 列网格的卡片高度（LIVE_UI 2026-11-21）。
  ///
  /// 原来是 `childAspectRatio: 1.15`：卡片高度跟着宽度走，台名一行 / 两行、
  /// 台标加载出来 / 没加载出来，视觉上就参差。现在改成固定高度 ——
  /// 台标区吃掉剩余空间（16:10 左右），文字按当前系统字号预留，
  /// 每张卡完全同高，缺台标的卡也不会比有台标的矮一截。
  double _cardExtent(BuildContext context, double crossAxisExtent) {
    const columns = 3;
    const spacing = 10.0;
    final cardWidth =
        ((crossAxisExtent - spacing * (columns - 1)) / columns).clamp(60.0, 400.0);
    final scaler = MediaQuery.textScalerOf(context);
    final logo = cardWidth * .62;
    // 6 上内边距 + 台标 + 7 间距 + 台名 + 2 间距 + 副标题 + 6 下内边距
    final text = scaler.scale(12.5 * 1.2) + 2 + scaler.scale(10 * 1.2);
    return (logo + text + 21).clamp(96.0, 260.0);
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
              Expanded(
                child: Text(
                  s.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Fx.ink,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 数量靠右：用户扫右边缘就知道每个分组有多少台，
              // 不用在标题后面找那一小串灰字。
              Text(
                '${s.count}',
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                  color: Fx.sub,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (ctx, constraints) {
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  mainAxisExtent: _cardExtent(ctx, constraints.maxWidth),
                ),
                itemCount: s.channels.length,
                itemBuilder: (ctx, i) {
                  final c = s.channels[i];
                  return LiveChannelCard(
                    channel: c,
                    onTap: () => _open(c, s.channels),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }

  void _open(LiveChannel c, List<LiveChannel> playlist) {
    // 点卡片直接进播放页（播放页进来就会起播）；返回时按失效登记重建一次，
    // 播不起来的台退回来就不在列表里了。
    Navigator.of(context)
        .push(
          FxPageRoute(
            builder: (_) => LiveDetailPage(channel: c, playlist: playlist),
          ),
        )
        .whenComplete(() {
      if (mounted) _rebuildSections();
    });
  }
}

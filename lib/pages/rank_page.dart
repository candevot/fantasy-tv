import 'package:flutter/material.dart';

import '../services/cms_bridge.dart';
import '../services/platform_rank.dart';
import '../theme.dart';
import '../utils/fx_route.dart';
import '../widgets/player_theme.dart' show fxToast;
import 'category_page.dart';
import 'detail_page.dart';

/// 排行榜页（RANK_BOARD 2026-11-21）。
///
/// 改版原因：以前这一页读的是 `CmsBridge.rank` —— 服务端按 `vod_hits` 排出来的
/// **我们库内的热度榜**，和腾讯 / 爱奇艺的榜单一毛钱关系都没有（谁先进库谁靠前）。
/// 现在直接读平台榜：
///
///   腾讯 pbaccess / 爱奇艺 mesh → `mac_hot_rank`（每 3 小时同步）
///     → `GET /api/rank?source=&type=` → [PlatformRankApi]
///
/// 页面结构：顶部切平台（腾讯热播 / 爱奇艺热播），下面切分类（电影 / 电视剧 /
/// 动漫 / 综艺），列表显示**平台真实名次**。拿不到数据时只说「榜单同步中」，
/// 绝不回落库内热度排序冒充平台榜 —— 那正是这次要改掉的事。
///
/// 旧的 [CmsBridge.rank] 保留着（别处可能还在用），本页不再调它。
class RankPage extends StatefulWidget {
  const RankPage({super.key});

  @override
  State<RankPage> createState() => _RankPageState();
}

class _RankPageState extends State<RankPage> {
  String _source = PlatformRankApi.platforms.first.key;
  int _type = PlatformRankApi.channels.first.type;

  PlatformRankBoard _board = PlatformRankBoard.empty;
  bool _loading = true;
  String? _error;
  int _req = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  RankPlatform get _platform => PlatformRankApi.platformOf(_source);
  RankChannel get _channel => PlatformRankApi.channelOf(_type);

  /// [force] = 跳过 60 秒本地缓存（下拉刷新 / 点刷新按钮）。
  Future<void> _load({bool force = false}) async {
    final req = ++_req;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final board = await PlatformRankApi.fetch(_source, _type, force: force);
      if (!mounted || req != _req) return;
      // 榜单里的 id 就是 mac_vod.vod_id：记进来源账本，详情 / 播放按 CMS 路由，
      // 不会先按「来源未知」猜一遍。
      CmsBridge.noteCmsIds(board.items.map((e) => e.vodId));
      setState(() {
        _board = board;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted || req != _req) return;
      final msg = fxErrorText(e);
      setState(() {
        _loading = false;
        _error = msg;
      });
      // 已有榜单时不要整页报错：保留旧数据 + 顶部重试条，再轻提示一次。
      if (_board.items.isNotEmpty) fxToast(context, '刷新失败：$msg');
    }
  }

  void _selectSource(String key) {
    if (_source == key) return;
    setState(() {
      _source = key;
      _board = PlatformRankBoard.empty;
      _error = null;
      _loading = true;
    });
    _load();
  }

  void _selectType(int type) {
    if (_type == type) return;
    // 换分类必须像换平台一样先清空：否则头部已经显示「动漫」，下面还挂着
    // 电影那批片子，加载中也没有骨架，看起来就是换了 tab 榜单没变。
    setState(() {
      _type = type;
      _board = PlatformRankBoard.empty;
      _error = null;
      _loading = true;
    });
    _load();
  }

  void _openDetail(String id) {
    if (id.isEmpty) return;
    Navigator.of(context).push(
      FxPageRoute(builder: (_) => DetailPage(id: id)),
    );
  }

  /// 前三名金银铜，其余中性灰。入参是**平台真实名次**，不是列表下标。
  Color _rankColor(int rank) {
    if (rank == 1) return Fx.gold;
    if (rank == 2) return const Color(0xFF8FA7C8);
    if (rank == 3) return const Color(0xFFC79A78);
    return const Color(0xFFB3BECD);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          _header(),
          if (_error != null && _board.items.isNotEmpty) _retryBar(),
          const SizedBox(height: 12),
          Expanded(child: _content()),
        ],
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('排行榜',
                        style: TextStyle(
                            fontSize: 20,
                            height: 1.2,
                            fontWeight: FontWeight.w600,
                            color: Fx.ink)),
                    SizedBox(height: 2),
                    Text('腾讯视频 / 爱奇艺 实时热播榜',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            color: Fx.sub)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _loading ? null : () => _load(force: true),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .72),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white),
                  ),
                  child: _loading
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Fx.accent),
                          ),
                        )
                      : const Icon(Icons.refresh_rounded,
                          size: 18, color: Fx.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // 一级切换：两个平台的榜。
          Container(
            height: 40,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .58),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: .92)),
            ),
            child: Row(
              children: [
                for (final p in PlatformRankApi.platforms)
                  Expanded(
                    child: _switchCell(
                      label: p.label,
                      selected: p.key == _source,
                      onTap: () => _selectSource(p.key),
                      radius: 17,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 二级切换：分类。
          Container(
            height: 36,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .42),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: .86)),
            ),
            child: Row(
              children: [
                for (final c in PlatformRankApi.channels)
                  Expanded(
                    child: _switchCell(
                      label: c.label,
                      selected: c.type == _type,
                      onTap: () => _selectType(c.type),
                      radius: 15,
                      small: true,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _switchCell({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    required double radius,
    bool small = false,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          gradient: selected ? Fx.brand : null,
          borderRadius: BorderRadius.circular(radius),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: Fx.accent.withValues(alpha: .22),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: small ? 12.5 : 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? Colors.white : Fx.sub,
            ),
          ),
        ),
      ),
    );
  }

  /// 刷新失败但还有旧榜单：顶部细条提示 + 重试，不整页报错。
  Widget _retryBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, size: 14, color: Fx.sub),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              '刷新失败，当前为上次榜单',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w400, color: Fx.sub),
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _loading ? null : () => _load(force: true),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Text(
                '重试',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Fx.accent,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _content() {
    if (_loading && _board.items.isEmpty) {
      return const FxSkeletonPulse(child: FxRankListSkeleton(count: 6));
    }
    // 拿不到平台榜（同步还没跑完 / 接口挂了）时只说「榜单同步中」。
    // 这里**不能**回落 CmsBridge.rank：那是我们自己库的热度排序，
    // 挂上「腾讯热播」的标题就成了假榜。
    if (_board.items.isEmpty) {
      return FxEmptyView(
        icon: Icons.sync_rounded,
        title: '榜单同步中',
        subtitle: _error == null
            ? '${_platform.tag}${_channel.label}榜每 3 小时同步一次，稍后刷新'
            : '${_platform.tag}${_channel.label}榜暂时取不到（$_error），稍后刷新',
        actionText: '刷新',
        onAction: () => _load(force: true),
      );
    }
    return RefreshIndicator(
      color: Fx.accent,
      backgroundColor: Colors.white,
      onRefresh: () => _load(force: true),
      child: ListView.separated(
        physics:
            const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 104),
        itemCount: _board.items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (ctx, i) => _row(_board.items[i]),
      ),
    );
  }

  Widget _rankBadge(int rank) {
    final top = rank <= 3;
    final color = _rankColor(rank);
    return Container(
      width: 30,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: top
            ? LinearGradient(
                colors: [color, color.withValues(alpha: .72)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: top ? null : Colors.white.withValues(alpha: .66),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: top ? Colors.white.withValues(alpha: .38) : Colors.white,
        ),
        boxShadow: top
            ? [
                BoxShadow(
                  color: color.withValues(alpha: .26),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        // 名次可能到两位数（平台榜 60 条）：挤不下时按宽度缩，不换行不溢出。
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '$rank',
            style: TextStyle(
              fontSize: top ? 15 : 13,
              height: 1,
              fontWeight: FontWeight.w700,
              color: top ? Colors.white : Fx.sub,
            ),
          ),
        ),
      ),
    );
  }

  Widget _metaTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Fx.accent.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 10.5,
          height: 1.2,
          fontWeight: FontWeight.w600,
          color: Fx.accent,
        ),
      ),
    );
  }

  Widget _row(PlatformRankItem item) {
    final platform = _platform;
    final channel = _channel;
    final channelName =
        _board.channelName.isEmpty ? channel.label : _board.channelName;
    final meta = <String>[
      if (item.year > 0) '${item.year}',
      channelName,
    ].join(' · ');
    final rankText = '${platform.tag}$channelName榜 · 第 ${item.rank} 名';
    return GlassCard(
      padding: const EdgeInsets.all(10),
      radius: 18,
      opacity: item.rank <= 3 ? .72 : .6,
      onTap: () => _openDetail(item.vodId),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _rankBadge(item.rank),
          const SizedBox(width: 8),
          SizedBox(
            width: 66,
            height: 99,
            child: FxCover(
              url: item.cover,
              title: item.title,
              radius: 10,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            // 内容至少与封面同高；大字体下随文字长高，不裁字也不压住底栏。
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 99),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                        color: Fx.ink),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    meta.isEmpty ? '影视' : meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11.5,
                        height: 1.2,
                        fontWeight: FontWeight.w400,
                        color: Fx.sub),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    rankText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.35,
                      fontWeight: FontWeight.w600,
                      color: Fx.accent,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Flexible(child: _metaTag(platform.tag)),
                      if (_board.stale) ...[
                        const SizedBox(width: 6),
                        const Flexible(child: _StaleTag()),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「榜单同步中 · 上次结果」小标：服务端读库失败时给的是 30 分钟内的旧榜，
/// 必须告诉用户这是上次的结果，不能当成最新名次。
class _StaleTag extends StatelessWidget {
  const _StaleTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFA6B1C2).withValues(alpha: .16),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text(
        '上次榜单',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10.5,
          height: 1.2,
          fontWeight: FontWeight.w600,
          color: Color(0xFF7C8798),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../theme.dart';
import 'downloads_page.dart';
import 'favorite_page.dart';
import 'history_page.dart';
import 'settings_page.dart';

class _Entry {
  const _Entry(this.icon, this.label, this.subtitle, this.color, this.builder);
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final WidgetBuilder builder;
}

class MinePage extends StatefulWidget {
  const MinePage({super.key});

  @override
  State<MinePage> createState() => _MinePageState();
}

class _MinePageState extends State<MinePage> {
  int _history = 0;
  int _favorite = 0;
  int _download = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final res = await Future.wait<int>([
      FxStore.count(FxStore.historyKey),
      FxStore.count(FxStore.favoriteKey),
      FxStore.count(FxStore.downloadKey),
    ]);
    if (!mounted) return;
    setState(() {
      _history = res[0];
      _favorite = res[1];
      _download = res[2];
    });
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (mounted) _load();
  }

  List<_Entry> get _entries => [
        _Entry(Icons.history_rounded, '观看历史', '$_history 条记录', Fx.accent,
            (_) => const HistoryPage()),
        _Entry(Icons.favorite_rounded, '我的收藏', '$_favorite 部作品',
            const Color(0xFFFF7EA8), (_) => const FavoritePage()),
        _Entry(Icons.download_rounded, '离线缓存', '$_download 个任务',
            const Color(0xFF5BC8A8), (_) => const DownloadsPage()),
        _Entry(Icons.settings_rounded, '设置', '清除缓存 · 检查更新',
            const Color(0xFF8E6BFF), (_) => const SettingsPage()),
      ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        color: Fx.accent,
        backgroundColor: Colors.white,
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 110),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Text('我的',
                    style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: Fx.ink,
                        letterSpacing: -.3)),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.66),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white),
                  ),
                  child: const Text('v1.0.0',
                      style: TextStyle(
                          fontSize: 9.5, color: Color(0xFFA6B1C2))),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _profile(),
            const SizedBox(height: 18),
            _statHeader(),
            const SizedBox(height: 8),
            _stats(),
            const SizedBox(height: 20),
            const Text('我的功能',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Fx.ink)),
            const SizedBox(height: 8),
            _entryCard(),
            const SizedBox(height: 26),
            const Center(
              child: Column(
                children: [
                  Text('幻想影视 · 纯净追剧',
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF9AA6B8),
                          letterSpacing: .3)),
                  SizedBox(height: 4),
                  Text('无广告 · 无会员 · 只为看好片',
                      style: TextStyle(
                          fontSize: 9.5, color: Color(0xFFB3BECD))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _profile() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.white.withOpacity(.82),
            Fx.accent.withOpacity(.10),
            Fx.accent2.withOpacity(.07),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(.95)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF50729F).withOpacity(.10),
            blurRadius: 30,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: Fx.brand,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Fx.accent.withOpacity(.30),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: const Text('幻',
                style: TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.w800,
                    color: Colors.white)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Flexible(
                      child: Text('游客用户',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                              color: Fx.ink)),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(.72),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.person_outline_rounded,
                              size: 10, color: Fx.sub),
                          SizedBox(width: 2),
                          Text('游客',
                              style: TextStyle(
                                  fontSize: 9, color: Fx.sub)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text('本地模式 · 无需登录，数据仅存本机',
                    style: TextStyle(fontSize: 11, color: Fx.sub)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statHeader() {
    return const Row(
      children: [
        Text('观看统计',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Fx.ink)),
        Spacer(),
        Text('仅统计本机',
            style: TextStyle(fontSize: 9.5, color: Color(0xFFA6B1C2))),
      ],
    );
  }

  Widget _stats() {
    return GlassCard(
      padding: const EdgeInsets.symmetric(vertical: 15),
      radius: 20,
      child: Row(
        children: [
          _stat('$_history', '观看记录'),
          _divider(),
          _stat('$_favorite', '我的收藏'),
          _divider(),
          _stat('$_download', '离线缓存'),
        ],
      ),
    );
  }

  Widget _stat(String value, String label) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ShaderMask(
            shaderCallback: (r) => Fx.brand.createShader(r),
            child: Text(
              value,
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  height: 1.1),
            ),
          ),
          const SizedBox(height: 4),
          Text(label,
              style: const TextStyle(fontSize: 10, color: Fx.sub)),
        ],
      ),
    );
  }

  Widget _divider() {
    return Container(
      width: 1,
      height: 26,
      color: Fx.ink.withOpacity(.06),
    );
  }

  Widget _entryCard() {
    final entries = _entries;
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      radius: 20,
      child: Column(
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            _entryRow(entries[i]),
            if (i != entries.length - 1)
              Padding(
                padding: const EdgeInsets.only(left: 50),
                child: Container(height: 1, color: Fx.ink.withOpacity(.05)),
              ),
          ],
        ],
      ),
    );
  }

  Widget _entryRow(_Entry e) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _open(e.builder(context)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: e.color.withOpacity(.11),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(e.icon, size: 19, color: e.color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.label,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Fx.ink)),
                  const SizedBox(height: 2),
                  Text(e.subtitle,
                      style: const TextStyle(fontSize: 10.5, color: Fx.sub)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                size: 19, color: Color(0xFFB3BECD)),
          ],
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/source_hub.dart';
import '../theme.dart';
import 'player_theme.dart' show PGlassIcon;

/// 源选择面板的返回值。
///
/// - [FxSourceChoice.pick]：选了一个源（[SourceHub.ownSourceKey] = 幻想）；
/// - [FxSourceChoice.refreshHome]：点的是某一行的「刷新」图标 —— 只重拉
///   首页，不改变当前选择。
@immutable
class FxSourceChoice {
  const FxSourceChoice.pick(this.key) : refresh = false;

  const FxSourceChoice.refreshHome(this.key) : refresh = true;

  /// 目标源的 key（[SourceHub.ownSourceKey] = 幻想）。
  final String key;

  /// true = 刷新这一行对应的数据（首页按该源重拉）。
  final bool refresh;
}

/// 影视壳（FongMi / OK影视）样式的源选择面板。
///
/// 结构和顺序都照壳来（SOURCE_PICK_ORDER，2026-11-17 定稿）：
///   · 一个圆角输入框「关键字…」+ 每个源一行 + 行尾刷新图标；
///   · 行顺序 = **配置里的原始顺序**，一项都不重排：肥猫那批
///     （咕噜 • APP / 豆瓣 • 首页 / 配置 • 中心 / 本地 • 视频 / …）在前，
///     幻想（我们自己的源）排在最后；
///   · 默认选中配置里的第一个源（肥猫配置里就是咕噜），只有用户主动
///     点了幻想才切到我们自己的库；
///   · 不可用的源（没有 jar 插件时的那批）行尾显示禁止图标，点了给原因。
Future<FxSourceChoice?> showFxSourceSheet(BuildContext context) {
  return showModalBottomSheet<FxSourceChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: .28),
    builder: (_) => const _SourceSheet(),
  );
}

class _SourceSheet extends StatefulWidget {
  const _SourceSheet();

  @override
  State<_SourceSheet> createState() => _SourceSheetState();
}

class _SourceSheetState extends State<_SourceSheet> {
  final SourceHub _hub = SourceHub.instance;
  final TextEditingController _keyword = TextEditingController();
  bool _configRefreshing = false;

  @override
  void initState() {
    super.initState();
    _hub.addListener(_onChanged);
    _keyword.addListener(_onChanged);
    // jar 插件状态决定肥猫那批能不能点（没装 jar 它们一条内容都出不来）。
    unawaited(_hub.ensureJarStatus());
  }

  @override
  void dispose() {
    _hub.removeListener(_onChanged);
    _keyword.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  String get _q => _keyword.text.trim().toLowerCase();

  bool _match(KSource s) {
    if (_q.isEmpty) return true;
    return s.name.toLowerCase().contains(_q) ||
        s.shortName.toLowerCase().contains(_q);
  }

  /// 这个源现在能不能真出内容。
  ///
  /// 两道闸：
  ///   · 非影视源（网盘 / 课堂 / 体育 / 音频 / 配置中心、type=0 直接地址、
  ///     `.py` 脚本）一律 ⊘ 不可选（规则见 [SourceHub.blockedReasonOf]）；
  ///   · jar 源要先装 jar 插件，没装同样是 ⊘。
  bool _usable(KSource s) =>
      !SourceHub.isBlockedSource(s) &&
      (s.kind != KSourceKind.jar || _hub.jarReady);

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final picked = _hub.homeSource;
    final sources = <KSource>[
      for (final s in _hub.pickerSources)
        if (_match(s)) s,
    ];
    final ownVisible = _q.isEmpty || SourceHub.ownSourceName.contains(_q);
    return Container(
      height: media.size.height * .76,
      // GLASS_UI：整块面板是毛玻璃（blur 18 + 白 .62 + 白描边 .9），
      // 不是实心白块 —— 背后是首页海报，透出来才对。
      child: FxGlassPanel(
        radius: 24,
        tint: FxGlassPanel.glassTint,
        child: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFDCE4F0),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 8, 0),
              child: Row(
                children: [
                  const Text(
                    '选择接口',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Fx.ink,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '当前：${_hub.homeSourceName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Fx.sub),
                    ),
                  ),
                  _configRefreshing
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : IconButton(
                          tooltip: '重新拉取配置',
                          onPressed: _refreshConfig,
                          icon: const Icon(
                            Icons.sync_rounded,
                            size: 20,
                            color: Fx.sub,
                          ),
                        ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
              child: FxGlassPanel(
                radius: 20,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(
                  height: 40,
                  child: Row(
                  children: [
                    const Icon(Icons.search_rounded, size: 17, color: Fx.sub),
                    const SizedBox(width: 7),
                    Expanded(
                      child: TextField(
                        controller: _keyword,
                        style: const TextStyle(fontSize: 13, color: Fx.ink),
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: '关键字…',
                          hintStyle: TextStyle(fontSize: 13, color: Fx.sub),
                        ),
                      ),
                    ),
                    if (_keyword.text.isNotEmpty)
                      GestureDetector(
                        onTap: () => _keyword.clear(),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: Fx.sub,
                        ),
                      ),
                  ],
                ),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
                physics: const BouncingScrollPhysics(),
                children: [
                  // 配置里的原始顺序，一项不重排。
                  for (final s in sources) _sourceRow(s, picked),
                  // 幻想固定最后一行：它不是配置里的 sites 条目，
                  // 是我们自己的 hx 库（CmsApi 那条默认路径）。
                  if (ownVisible) _ownRow(picked == null),
                  if (!ownVisible && sources.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 28),
                      child: Center(
                        child: Text(
                          '没有匹配的接口',
                          style: TextStyle(fontSize: 12, color: Fx.sub),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  Widget _sourceRow(KSource source, KSource? picked) {
    final usable = _usable(source);
    final name = source.shortName.isEmpty ? source.name : source.shortName;
    final blocked = SourceHub.blockedReasonOf(source);
    final subtitle = <String>[
      source.kindLabel,
      if (_hub.isPinned(source.key)) '推荐',
      if (blocked.isNotEmpty) blocked,
      if (blocked.isEmpty && !usable) '需要 jar 插件',
    ].join(' · ');
    return _row(
      name: name,
      subtitle: subtitle,
      icon: SourceHub.isBundledSource(source)
          ? Icons.pets_rounded
          : (source.isLive ? Icons.live_tv_rounded : Icons.movie_rounded),
      selected: picked?.key == source.key,
      enabled: usable,
      trailing: _trailing(enabled: usable, key: source.key),
      onTap: () {
        if (blocked.isNotEmpty) {
          _toast('「$name」用不了：$blocked');
          return;
        }
        if (!usable) {
          _toast('「$name」要先在「设置 → jar 插件」装好 jar 才出内容');
          return;
        }
        Navigator.pop(context, FxSourceChoice.pick(source.key));
      },
    );
  }

  /// 幻想：我们自己的源，固定最后一行。
  Widget _ownRow(bool selected) {
    return _row(
      name: SourceHub.ownSourceName,
      subtitle: '我们自己的片源（${_hub.ownSources.length} 条线路）',
      icon: Icons.auto_awesome_motion_rounded,
      selected: selected,
      trailing: _trailing(enabled: true, key: SourceHub.ownSourceKey),
      onTap: () => Navigator.pop(
        context,
        const FxSourceChoice.pick(SourceHub.ownSourceKey),
      ),
    );
  }

  /// 行尾：能用的给玻璃圆刷新图标（重拉首页），不能用的给禁止图标。
  Widget _trailing({required bool enabled, required String key}) {
    if (!enabled) {
      return SizedBox(
        width: 40,
        height: 40,
        child: Center(
          child: Icon(
            Icons.block_rounded,
            size: 17,
            color: Fx.sub.withValues(alpha: .45),
          ),
        ),
      );
    }
    return PGlassIcon(
      icon: Icons.refresh_rounded,
      size: 30,
      iconSize: 16,
      tint: .16,
      iconColor: Fx.sub,
      hitSize: 40,
      tooltip: '刷新',
      onTap: () => Navigator.pop(context, FxSourceChoice.refreshHome(key)),
    );
  }

  Widget _row({
    required String name,
    required String subtitle,
    required IconData icon,
    required bool selected,
    required Widget trailing,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    // GLASS_UI：每一行都是玻璃胶囊 —— 选中 = 主题色实心 + 白字，
    // 未选中 = 白色半透明 + 白描边，禁止项 = 玻璃但文字置灰。
    final fg = selected
        ? Colors.white
        : (enabled ? Fx.ink : Fx.sub.withValues(alpha: .55));
    final sub = selected
        ? Colors.white.withValues(alpha: .86)
        : Fx.sub.withValues(alpha: enabled ? 1 : .55);
    final glyph = selected
        ? Colors.white
        : (enabled ? Fx.accent : Fx.sub.withValues(alpha: .5));
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.fromLTRB(12, 9, 6, 9),
          decoration: BoxDecoration(
            color: selected
                ? Fx.accent.withValues(alpha: .92)
                : Colors.white.withValues(alpha: enabled ? .62 : .34),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? Colors.white.withValues(alpha: .45)
                  : Colors.white.withValues(alpha: FxGlassPanel.glassBorder),
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF50729F).withValues(alpha: .06),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(icon, size: 17, color: glyph),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: fg,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: sub),
                    ),
                  ],
                ),
              ),
              if (selected)
                const Padding(
                  padding: EdgeInsets.only(right: 2),
                  child: Icon(
                    Icons.check_circle_rounded,
                    size: 17,
                    color: Colors.white,
                  ),
                ),
              trailing,
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _refreshConfig() async {
    if (_configRefreshing) return;
    setState(() => _configRefreshing = true);
    final ok = await _hub.refresh();
    if (!mounted) return;
    setState(() => _configRefreshing = false);
    _toast(ok ? '接口配置已更新' : '拉取失败：${_hub.lastError}');
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xEE1B2430),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }
}

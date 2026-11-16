import 'package:flutter/material.dart';

import '../services/source_hub.dart';
import '../theme.dart';
import '../utils/fx_route.dart';
import 'category_page.dart' show FxPageScaffold;

/// 片源管理（设置 → 片源管理）。
///
/// SHELL_SOURCE_MGR（2026-11-17）：按用户口径整页重做 ——
///   · **删掉整块 jar 插件**（spider.jar 的安装 / 更新 / 自检 / 卸载都在
///     「设置 → jar 插件」那一页，这里不再重复一遍）；
///   · 「添加源」和「导入 TVBox」**合并成一个「+ 添加接口」**：粘一个
///     CMS 接口地址、或者一份 TVBox / 猫源配置地址，二合一；
///   · 云端源 / 我的源每一条都能**单独删除**、标「推荐」/「设为首选」；
///   · 删掉的源进「已移除」分组，带「恢复」按钮（只恢复这一条，不牵连别人）；
///   · 直播不在这里管理：直播数据来自导入接口里的 `lives` 字段。
class SourceSettingsPage extends StatefulWidget {
  const SourceSettingsPage({super.key});

  @override
  State<SourceSettingsPage> createState() => _SourceSettingsPageState();
}

class _SourceSettingsPageState extends State<SourceSettingsPage> {
  final SourceHub _hub = SourceHub.instance;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _hub.addListener(_onChanged);
    _boot();
  }

  @override
  void dispose() {
    _hub.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _boot() async {
    await _hub.ensureReady();
    await _hub.ensureJarStatus();
    if (!mounted) return;
    setState(() {});
  }

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xEE1B2430),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return FxPageScaffold(
      title: '片源管理',
      actions: [
        IconButton(
          tooltip: '重新拉取',
          onPressed: _refreshing ? null : _refresh,
          icon: _refreshing
              ? const SizedBox(
                  width: 17,
                  height: 17,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_sync_rounded, size: 20, color: Fx.ink),
        ),
      ],
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 30),
        children: [
          _statusCard(),
          _sectionTitle('云端源'),
          _cloudList(),
          _sectionTitle('我的源'),
          _userList(),
          if (_removedCount > 0) ...[
            _sectionTitle('已移除'),
            _removedList(),
          ],
          const SizedBox(height: 18),
          // 一个入口：粘贴接口地址 / TVBox 配置地址，二合一。
          GradButton(
            text: '＋ 添加接口',
            icon: Icons.add_rounded,
            height: 44,
            onTap: _addInterface,
          ),
          const SizedBox(height: 14),
          const Text(
            '说明：接口支持 CMS（type 1）、直接地址（type 0）和 TVBox jar 源'
            '（type 3，需要先在「设置 → jar 插件」装好 jar）；'
            '也可以直接粘 TVBox / 猫源配置地址，会按 sites 批量导入。'
            '直播跟着接口走：接口里带 lives 就有直播，不带就显示空态。',
            style: TextStyle(
              fontSize: 10.5,
              height: 1.55,
              color: Color(0xFFA6B1C2),
            ),
          ),
        ],
      ),
    );
  }

  int get _removedCount =>
      _hub.removedCloudSources.length + (_hub.bundledHidden ? 1 : 0);

  /* ------------------------------------------------------------ 顶部状态 */

  /// 一行配置状态（已同步 · 时间）+「重新拉取配置」+ 检索统计。
  Widget _statusCard() {
    final at = _hub.fetchedAt;
    final error = _hub.lastError;
    return FxGlassPanel(
      radius: 18,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                error.isEmpty
                    ? Icons.cloud_done_rounded
                    : Icons.cloud_off_rounded,
                size: 16,
                color: error.isEmpty ? Fx.accent : Fx.danger,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  error.isEmpty
                      ? (at == null ? '还没同步过配置' : '配置已同步 · ${_timeText(at)}')
                      : '拉取失败：$error（正在用本地缓存）',
                  maxLines: 2,
                  style: TextStyle(
                    fontSize: 12,
                    color: error.isEmpty ? Fx.ink : Fx.danger,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              GradButton(
                text: _refreshing ? '拉取中…' : '重新拉取配置',
                height: 34,
                onTap: _refreshing ? null : _refresh,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${_hub.retrievalLabel} 个源参与检索',
                  textAlign: TextAlign.right,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, color: Fx.sub),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /* ------------------------------------------------------------ 云端源 */

  /// 云端接口带来的源（幻想这条线路集 + 肥猫那批）。
  ///
  /// 每一条右侧都有「推荐（置顶）」和「删除」；删掉只记黑名单，
  /// 云端原始配置不动，「已移除」里能单独恢复。
  Widget _cloudList() {
    final cloud = _hub.visibleCloud;
    final bundled = _hub.bundledSources;
    return FxGlassPanel(
      radius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          for (var i = 0; i < cloud.length; i++) ...[
            if (i > 0) _divider(),
            _sourceRow(
              key: cloud[i].key,
              icon: Icons.auto_awesome_motion_rounded,
              name: cloud[i].shortName.isEmpty
                  ? cloud[i].name
                  : cloud[i].shortName,
              subtitle: _hub.isPinned(cloud[i].key)
                  ? '${cloud[i].kindLabel} · 推荐'
                  : cloud[i].kindLabel,
              preferred: _hub.homeSource?.key == cloud[i].key,
              onPin: () => _togglePin(cloud[i].key, cloud[i].name),
              onDelete: () => _removeCloud(cloud[i]),
            ),
          ],
          if (!_hub.bundledHidden) ...[
            if (cloud.isNotEmpty) _divider(),
            _sourceRow(
              key: _bundledKey,
              icon: Icons.pets_rounded,
              name: '肥猫',
              subtitle: _hub.isPinned(_bundledKey)
                  ? '${bundled.length} 个源 · 推荐'
                  : '${bundled.length} 个源（TVBox 配置导入）',
              preferred: false,
              onPin: () => _togglePin(_bundledKey, '肥猫'),
              onDelete: _removeBundled,
            ),
          ],
          if (cloud.isEmpty && _hub.bundledHidden) ...[
            _divider(),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Text(
                '接口里还没有片源，点下面的「重新拉取配置」或自己加一个接口。',
                style: TextStyle(fontSize: 11, height: 1.5, color: Fx.sub),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static const String _bundledKey = '@bundled';

  /* ------------------------------------------------------------ 我的源 */

  Widget _userList() {
    final user = _hub.userSources;
    return FxGlassPanel(
      radius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          if (user.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '还没有自己添加的接口。点下面的「＋ 添加接口」粘一个 CMS 地址，'
                '或者直接粘 TVBox / 猫源配置地址批量导入。',
                style: TextStyle(fontSize: 11.5, height: 1.5, color: Fx.sub),
              ),
            ),
          for (var i = 0; i < user.length; i++) ...[
            if (i > 0) _divider(),
            _sourceRow(
              key: user[i].key,
              icon: user[i].isLive
                  ? Icons.live_tv_rounded
                  : Icons.movie_rounded,
              name: user[i].shortName.isEmpty
                  ? user[i].name
                  : user[i].shortName,
              subtitle: _hub.isPinned(user[i].key)
                  ? '${user[i].kindLabel} · 推荐'
                  : user[i].kindLabel,
              preferred: _hub.homeSource?.key == user[i].key,
              onPin: () => _togglePin(user[i].key, user[i].name),
              onPrefer: () => _prefer(user[i]),
              onDelete: () => _removeUser(user[i]),
            ),
          ],
        ],
      ),
    );
  }

  /* ------------------------------------------------------------ 已移除 */

  Widget _removedList() {
    final removed = _hub.removedCloudSources;
    return FxGlassPanel(
      radius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          for (var i = 0; i < removed.length; i++) ...[
            if (i > 0) _divider(),
            _removedRow(
              name: removed[i].shortName.isEmpty
                  ? removed[i].name
                  : removed[i].shortName,
              subtitle: '云端接口里还有，删掉的是本地这条',
              onRestore: () => _restoreCloud(removed[i]),
            ),
          ],
          if (_hub.bundledHidden) ...[
            if (removed.isNotEmpty) _divider(),
            _removedRow(
              name: '肥猫',
              subtitle: '恢复后不用重新联网，导入结果还在本地',
              onRestore: _restoreBundled,
            ),
          ],
        ],
      ),
    );
  }

  Widget _removedRow({
    required String name,
    required String subtitle,
    required VoidCallback onRestore,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const Icon(
            Icons.remove_circle_outline_rounded,
            size: 17,
            color: Color(0xFFC3CDDA),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Fx.sub,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: Fx.sub),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onRestore,
            child: const Text(
              '恢复',
              style: TextStyle(fontSize: 12, color: Fx.accent),
            ),
          ),
        ],
      ),
    );
  }

  /* ------------------------------------------------------------ 行 */

  /// 一条源：名字 + 副标题 + 行尾动作（推荐 / 设为首选 / 删除）。
  Widget _sourceRow({
    required String key,
    required IconData icon,
    required String name,
    required String subtitle,
    required bool preferred,
    required VoidCallback onPin,
    required VoidCallback onDelete,
    VoidCallback? onPrefer,
  }) {
    final pinned = _hub.isPinned(key);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 17, color: Fx.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Fx.ink,
                        ),
                      ),
                    ),
                    if (preferred) ...[
                      const SizedBox(width: 5),
                      _chip('首选', tint: Fx.accent),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, color: Fx.sub),
                ),
              ],
            ),
          ),
          // 推荐 / 置顶
          IconButton(
            tooltip: pinned ? '取消推荐' : '标为推荐',
            visualDensity: VisualDensity.compact,
            onPressed: onPin,
            icon: Icon(
              pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
              size: 17,
              color: pinned ? Fx.gold : Fx.sub,
            ),
          ),
          if (onPrefer != null)
            IconButton(
              tooltip: preferred ? '已是首选' : '设为首选',
              visualDensity: VisualDensity.compact,
              onPressed: preferred ? null : onPrefer,
              icon: Icon(
                Icons.home_outlined,
                size: 17,
                color: preferred ? Fx.accent : Fx.sub,
              ),
            ),
          IconButton(
            tooltip: '删除',
            visualDensity: VisualDensity.compact,
            onPressed: onDelete,
            icon: const Icon(
              Icons.delete_outline_rounded,
              size: 18,
              color: Color(0xFFE05252),
            ),
          ),
        ],
      ),
    );
  }

  /* ------------------------------------------------------------ 动作 */

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final ok = await _hub.refresh();
    if (!mounted) return;
    setState(() => _refreshing = false);
    _toast(
      ok ? '云端配置已更新（${_hub.retrievalLabel}）' : '拉取失败：${_hub.lastError}',
    );
  }

  Future<void> _togglePin(String key, String name) async {
    await _hub.togglePinned(key);
    if (!mounted) return;
    _toast(_hub.isPinned(key) ? '已把「$name」标为推荐' : '「$name」已取消推荐');
  }

  Future<void> _prefer(KSource source) async {
    await _hub.selectHomeSource(source.key);
    if (!mounted) return;
    _toast('首页 / 分类已切到「${_hub.homeSourceName}」');
  }

  Future<void> _removeCloud(KSource source) async {
    final ok = await _confirm(
      title: '删除「${source.name}」？',
      body: '删掉后这条源不再参与首页 / 搜索。云端配置里还在，「已移除」里能恢复。',
      confirm: '删除',
    );
    if (ok != true) return;
    await _hub.removeCloud(source.key);
    if (!mounted) return;
    _toast('已删除「${source.name}」，可在「已移除」里恢复');
  }

  Future<void> _removeBundled() async {
    final ok = await _confirm(
      title: '删除「肥猫」这批源？',
      body: '肥猫的 ${_hub.bundledSources.length} 个 jar 源会一起从列表里移除；'
          '导入结果留在本地，「已移除」里能一键恢复。',
      confirm: '删除',
    );
    if (ok != true) return;
    await _hub.setBundledHidden(true);
    if (!mounted) return;
    _toast('已移除肥猫这批源，可在「已移除」里恢复');
  }

  Future<void> _restoreBundled() async {
    await _hub.setBundledHidden(false);
    if (!mounted) return;
    _toast('肥猫这批源已恢复');
  }

  Future<void> _restoreCloud(KSource source) async {
    await _hub.restoreCloud(source.key);
    if (!mounted) return;
    _toast('已恢复「${source.name}」');
  }

  Future<void> _removeUser(KSource source) async {
    final ok = await _confirm(
      title: '删除「${source.name}」？',
      body: '这是你自己加的接口，删掉后不会自动恢复（可以重新添加一次）。',
      confirm: '删除',
    );
    if (ok != true) return;
    await _hub.removeUser(source.key);
    if (!mounted) return;
    _toast('已删除「${source.name}」');
  }

  /// 「+ 添加接口」：一个入口吃两种输入（SHELL_SOURCE_MGR）。
  ///
  ///   · 粘 `{...sites...}` JSON / TVBox / 猫源配置地址 → 按 sites 批量导入；
  ///   · 粘一个 CMS 接口地址 → 当成一条自加源。
  /// 判断顺序是「先试导入、失败再当接口」，所以用户不用自己选类型。
  Future<void> _addInterface() async {
    final ctrl = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white.withValues(alpha: .96),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          '添加接口',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '粘一个接口地址就行：CMS 接口（…/api.php/provide/vod/）会加成一条源；'
                'TVBox / 猫源配置地址（含 sites 的 JSON 也行）会按 sites 批量导入。',
                style: TextStyle(fontSize: 11, height: 1.5, color: Fx.sub),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: ctrl,
                maxLines: 5,
                minLines: 3,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  hintText: 'https://…/api.php/provide/vod/  或  配置地址 / JSON',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Fx.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('添加', style: TextStyle(color: Fx.accent)),
          ),
        ],
      ),
    );
    final text = ctrl.text.trim();
    ctrl.dispose();
    if (saved != true || !mounted) return;
    if (text.isEmpty) {
      _toast('先粘一个接口地址');
      return;
    }
    // JSON 一定是 TVBox 配置；地址先按配置试一次（肥猫那类地址），
    // 解析不出 sites 再落回「一条 CMS 源」。
    if (text.startsWith('{')) {
      try {
        await _importConfig(text);
      } catch (e) {
        if (mounted) _toast('$e');
      }
      return;
    }
    try {
      await _importConfig(text);
    } catch (_) {
      await _addAsSource(text);
    }
  }

  Future<void> _importConfig(String input) async {
    try {
      final result = await _hub.importTvBox(input);
      if (!mounted) return;
      _toast(<String>[
        '已导入 ${result.added} 条接口，跳过 ${result.skipped} 条',
        ...result.notes.take(4),
      ].join('\n'));
    } catch (e) {
      rethrow;
    }
  }

  Future<void> _addAsSource(String url) async {
    try {
      final made = await _hub.addUser(name: '', api: url);
      if (!mounted) return;
      _toast('已添加「${made.name}」');
    } catch (e) {
      if (!mounted) return;
      _toast('$e');
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String body,
    required String confirm,
  }) =>
      showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: Colors.white.withValues(alpha: .96),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(
            title,
            style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
          ),
          content: Text(
            body,
            style: const TextStyle(fontSize: 12.5, height: 1.5, color: Fx.sub),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消', style: TextStyle(color: Fx.sub)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                confirm,
                style: const TextStyle(color: Color(0xFFE05252)),
              ),
            ),
          ],
        ),
      );

  /* ------------------------------------------------------------ 小部件 */

  Widget _chip(String text, {Color? tint}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: (tint ?? Fx.sub).withValues(alpha: .12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: 9.5, color: tint ?? Fx.sub),
        ),
      );

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Fx.sub,
            letterSpacing: .3,
          ),
        ),
      );

  Widget _divider() => Divider(
        height: 1,
        thickness: .5,
        color: Colors.white.withValues(alpha: .6),
      );

  String _timeText(DateTime at) {
    final now = DateTime.now();
    final sameDay =
        now.year == at.year && now.month == at.month && now.day == at.day;
    final hm = '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';
    return sameDay ? '今天 $hm' : '${at.month}-${at.day} $hm';
  }
}

/// 让「片源管理」也能从别处直接打开（分类页 / 搜索页的入口复用）。
void openSourceSettings(BuildContext context) {
  Navigator.of(context).push(
    FxPageRoute(builder: (_) => const SourceSettingsPage()),
  );
}

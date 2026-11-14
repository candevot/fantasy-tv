import 'package:flutter/material.dart';

import '../services/source_hub.dart';
import '../theme.dart';
import '../utils/fx_route.dart';
import 'category_page.dart' show FxPageScaffold;

/// 片源管理（设置 → 片源管理）。
///
/// 三块：
///   1. **云端配置**：后台 `/api/config` 下发的片源与直播接口地址，
///      这里能看同步状态、手动重拉；
///   2. **云端源**：内置源可删，删完点「恢复默认」一键回来（黑名单清空，
///      不用重新拉配置）；
///   3. **我的源**：用户自加的 CMS / 直连源，可增删改；也能直接粘贴
///      TVBox / 猫源配置（JSON 或地址）批量导入，`type: 3/4` 的解析脚本
///      会明确标成「暂不支持」并跳过。
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
          _sectionTitle('云端配置'),
          _cloudCard(),
          _sectionTitle('云端源'),
          _cloudList(),
          _sectionTitle('我的源'),
          _userList(),
          const SizedBox(height: 18),
          const Text(
            '说明：只支持 type 1（CMS 接口）和 type 0（直接地址）；'
            'type 3 / 4 是 jar / python 解析脚本，需要额外的运行时，暂不支持。'
            '搜索会把所有启用源的结果合并去重，并在卡片上标出来源。',
            style: TextStyle(fontSize: 10.5, height: 1.55, color: Color(0xFFA6B1C2)),
          ),
        ],
      ),
    );
  }

  /* ------------------------------------------------------------ 云端 */

  Widget _cloudCard() {
    final at = _hub.fetchedAt;
    final error = _hub.lastError;
    final liveUrl = _hub.liveUrl;
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      radius: 18,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                error.isEmpty ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
                size: 16,
                color: error.isEmpty ? Fx.accent : Fx.danger,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  error.isEmpty
                      ? (at == null ? '还没同步过云端配置' : '配置已同步 · ${_timeText(at)}')
                      : '拉取失败：$error（正在用本地缓存）',
                  style: TextStyle(
                    fontSize: 12,
                    color: error.isEmpty ? Fx.ink : Fx.danger,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            '直播接口地址',
            style: TextStyle(fontSize: 11, color: Fx.sub),
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFF4F7FC),
              borderRadius: BorderRadius.circular(10),
            ),
            child: SelectableText(
              liveUrl.isEmpty ? '未配置（后台填写 live_url 后下发）' : liveUrl,
              maxLines: 3,
              style: TextStyle(
                fontSize: 10.5,
                height: 1.45,
                color: liveUrl.isEmpty ? const Color(0xFFA6B1C2) : Fx.accent,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              GradButton(
                text: _refreshing ? '拉取中…' : '重新拉取配置',
                height: 34,
                onTap: _refreshing ? null : _refresh,
              ),
              const Spacer(),
              Text(
                '${_hub.querySources.length} 个源参与检索',
                style: const TextStyle(fontSize: 10.5, color: Fx.sub),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _cloudList() {
    final cloud = _hub.cloudSources;
    if (cloud.isEmpty) {
      return GlassCard(
        padding: const EdgeInsets.all(14),
        radius: 18,
        child: Text(
          _hub.loaded && _hub.lastError.isEmpty
              ? '后台配置里没有 cloud_sources。在后台「系统 → 配置」里加上 cloud_sources 数组即可，字段见交付说明。'
              : '还没拿到云端片源，点上面的「重新拉取配置」再试一次。',
          style: const TextStyle(fontSize: 11.5, height: 1.55, color: Fx.sub),
        ),
      );
    }
    final removed = cloud.where((s) => _hub.isRemoved(s.key)).length;
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      radius: 18,
      child: Column(
        children: [
          for (var i = 0; i < cloud.length; i++) ...[
            if (i > 0) _divider(),
            _cloudRow(cloud[i]),
          ],
          if (removed > 0) ...[
            _divider(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '已删除 $removed 个内置源',
                      style: const TextStyle(fontSize: 11, color: Fx.sub),
                    ),
                  ),
                  TextButton(
                    onPressed: _restore,
                    child: const Text('恢复默认'),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _cloudRow(KSource source) {
    final removed = _hub.isRemoved(source.key);
    final off = source.kind == KSourceKind.unsupported || !source.enabled;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              source.isLive ? Icons.live_tv_rounded : Icons.cloud_rounded,
              size: 17,
              color: removed || off ? const Color(0xFFC3CDDA) : Fx.accent,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        source.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: removed ? const Color(0xFFA6B1C2) : Fx.ink,
                          decoration:
                              removed ? TextDecoration.lineThrough : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _chip(source.kindLabel),
                    if (removed) ...[
                      const SizedBox(width: 6),
                      _chip('已删除'),
                    ],
                    if (!removed && off) ...[
                      const SizedBox(width: 6),
                      _chip(source.reason.isEmpty ? '已停用' : source.reason),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  source.api,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: Color(0xFFA6B1C2)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          if (removed)
            IconButton(
              tooltip: '恢复',
              visualDensity: VisualDensity.compact,
              onPressed: () => _restore(),
              icon: const Icon(Icons.restore_rounded,
                  size: 18, color: Fx.accent),
            )
          else
            IconButton(
              tooltip: '删除',
              visualDensity: VisualDensity.compact,
              onPressed: () => _removeCloud(source),
              icon: const Icon(Icons.delete_outline_rounded,
                  size: 18, color: Color(0xFFE05252)),
            ),
        ],
      ),
    );
  }

  /* ------------------------------------------------------------ 我的源 */

  Widget _userList() {
    final user = _hub.userSources;
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      radius: 18,
      child: Column(
        children: [
          if (user.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '还没有自加片源。可以添加一个 CMS 接口，或粘贴 TVBox 配置批量导入。',
                style: TextStyle(fontSize: 11.5, height: 1.5, color: Fx.sub),
              ),
            ),
          for (var i = 0; i < user.length; i++) ...[
            if (i > 0) _divider(),
            _userRow(user[i]),
          ],
          _divider(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: () => _editUser(null),
                  icon: const Icon(Icons.add_rounded, size: 17),
                  label: const Text('添加源'),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _importTvBox,
                  icon: const Icon(Icons.playlist_add_rounded, size: 17),
                  label: const Text('导入 TVBox'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _userRow(KSource source) {
    final broken = source.kind == KSourceKind.unsupported;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              source.isLive ? Icons.live_tv_rounded : Icons.movie_rounded,
              size: 17,
              color: broken ? const Color(0xFFC3CDDA) : Fx.accent2,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        source.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Fx.ink,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _chip(source.kindLabel),
                    if (source.tag.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      _chip(source.tag),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  source.api,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: Color(0xFFA6B1C2)),
                ),
                if (broken) ...[
                  const SizedBox(height: 3),
                  Text(
                    source.reason.isEmpty ? '暂不支持' : source.reason,
                    style: const TextStyle(fontSize: 10, color: Fx.danger),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: '编辑',
            visualDensity: VisualDensity.compact,
            onPressed: () => _editUser(source),
            icon: const Icon(Icons.edit_outlined, size: 17, color: Fx.sub),
          ),
          IconButton(
            tooltip: '删除',
            visualDensity: VisualDensity.compact,
            onPressed: () => _removeUser(source),
            icon: const Icon(Icons.delete_outline_rounded,
                size: 18, color: Color(0xFFE05252)),
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
    _toast(ok
        ? '云端配置已更新（${_hub.querySources.length} 个源）'
        : '拉取失败：${_hub.lastError}');
  }

  Future<void> _restore() async {
    await _hub.restoreDefaults();
    if (!mounted) return;
    _toast('已恢复默认：内置源全部回来');
  }

  Future<void> _removeCloud(KSource source) async {
    final ok = await _confirm(
      title: '删除「${source.name}」？',
      body: '删除后搜索和分类不再查这个源。随时可以点「恢复默认」让它回来，'
          '不用重新拉配置。',
      confirm: '删除',
    );
    if (ok != true) return;
    await _hub.removeCloud(source.key);
    if (!mounted) return;
    _toast('已删除「${source.name}」');
  }

  Future<void> _removeUser(KSource source) async {
    final ok = await _confirm(
      title: '删除「${source.name}」？',
      body: '这是我的源，删掉后不会自动恢复。',
      confirm: '删除',
    );
    if (ok != true) return;
    await _hub.removeUser(source.key);
    if (!mounted) return;
    _toast('已删除「${source.name}」');
  }

  /// [source] 为空 = 新增。
  Future<void> _editUser(KSource? source) async {
    final nameCtrl = TextEditingController(text: source?.name ?? '');
    final apiCtrl = TextEditingController(text: source?.api ?? '');
    var type = source?.kind == KSourceKind.direct ? 0 : 1;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(
            source == null ? '添加片源' : '编辑片源',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: '名称',
                    hintText: '比如：幻想云源',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: apiCtrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '接口地址',
                    hintText: 'https://xxx/api.php/provide/vod/',
                  ),
                ),
                const SizedBox(height: 12),
                const Text('类型', style: TextStyle(fontSize: 11, color: Fx.sub)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    _typeChip('CMS 接口 (1)', 1, type, (v) {
                      setLocal(() => type = v);
                    }),
                    const SizedBox(width: 8),
                    _typeChip('直接地址 (0)', 0, type, (v) {
                      setLocal(() => type = v);
                    }),
                  ],
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
              child: Text(
                source == null ? '添加' : '保存',
                style: const TextStyle(color: Fx.accent),
              ),
            ),
          ],
        ),
      ),
    );
    final name = nameCtrl.text.trim();
    final api = apiCtrl.text.trim();
    nameCtrl.dispose();
    apiCtrl.dispose();
    if (saved != true || !mounted) return;
    try {
      if (source == null) {
        final made = await _hub.addUser(name: name, api: api, type: type);
        if (mounted) _toast('已添加「${made.name}」');
      } else {
        await _hub.updateUser(source.key, name: name, api: api, type: type);
        if (mounted) _toast('已保存');
      }
    } catch (e) {
      if (!mounted) return;
      _toast('$e');
    }
  }

  Future<void> _importTvBox() async {
    final ctrl = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          '导入 TVBox / 猫源',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '粘贴含 sites 数组的 JSON，或填配置地址（http 开头）。'
                '只导入 type 1 / type 0，type 3 / 4 会标「暂不支持」后跳过。',
                style: TextStyle(fontSize: 11, height: 1.5, color: Fx.sub),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: ctrl,
                maxLines: 6,
                minLines: 3,
                decoration: const InputDecoration(
                  hintText: '{"sites":[{"key":"csp","name":"…","type":1,"api":"…"}]}',
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
            child: const Text('导入', style: TextStyle(color: Fx.accent)),
          ),
        ],
      ),
    );
    final text = ctrl.text;
    ctrl.dispose();
    if (saved != true || !mounted) return;
    try {
      final result = await _hub.importTvBox(text);
      if (!mounted) return;
      final lines = <String>[
        '已导入 ${result.added} 个源，跳过 ${result.skipped} 个。',
        ...result.notes.take(6),
      ];
      _toast(lines.join('\n'));
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
          backgroundColor: Colors.white,
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
              child: Text(confirm,
                  style: const TextStyle(color: Color(0xFFE05252))),
            ),
          ],
        ),
      );

  /* ------------------------------------------------------------ 小部件 */

  Widget _typeChip(String label, int value, int current, ValueChanged<int> onTap) {
    final active = value == current;
    return GestureDetector(
      onTap: () => onTap(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? Fx.accent.withValues(alpha: .12) : const Color(0xFFF4F7FC),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: active ? Fx.accent : const Color(0xFFE3E9F2),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: active ? Fx.accent : Fx.sub,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _chip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFFF1F4FA),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          style: const TextStyle(fontSize: 9.5, color: Fx.sub),
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
        color: const Color(0xFFEDF1F7),
      );

  String _timeText(DateTime at) {
    final now = DateTime.now();
    final sameDay = now.year == at.year &&
        now.month == at.month &&
        now.day == at.day;
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

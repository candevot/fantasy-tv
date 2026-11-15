import 'package:flutter/material.dart';

import '../widgets/jar_plugin_card.dart';
import '../services/source_hub.dart';
import '../theme.dart';
import '../utils/fx_route.dart';
import 'category_page.dart' show FxPageScaffold;

/// 片源管理（设置 → 片源管理）。
///
/// 三块：
///   1. **云端配置**：后台 `/api/config` 的同步状态与手动重拉；直播接口地址
///      只在后台真的配了下发时显示，没配就整行不出现；
///   2. **云端源**：只有两条内置项 —— `幻想`（我们自己的 7 条线路）和
///      `肥猫`（TVBox 配置带进来的 41 个 jar 源，内部再多也只是一条）。
///      两条都不可删、不显示任何 api 地址；
///   3. **我的源**：只放用户自己加的 CMS / 直连源，可增删改；也能直接粘贴
///      TVBox / 猫源配置（JSON 或地址）批量导入，`type: 3`（jar 插件）现在
///      能直接用，`type: 4`（python 脚本）仍标成「暂不支持」并跳过。
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
          _builtinList(),
          _sectionTitle('我的源'),
          _userList(),
          _sectionTitle('jar 插件'),
          _jarCard(),
          const SizedBox(height: 18),
          const Text(
            '说明：支持 type 1（CMS 接口）、type 0（直接地址）和 type 3'
            '（TVBox jar 插件，需要先在下面装好 spider.jar）；'
            'type 4 是 python 解析脚本，仍需额外的运行时。'
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
          // 直播接口地址：没配就整行不显示 —— 原来那句「未配置（后台填写
          // live_url 后下发）」对用户只是噪音，他现在也填不了这一项。
          if (liveUrl.isNotEmpty) ...[
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
                liveUrl,
                maxLines: 3,
                style: const TextStyle(
                  fontSize: 10.5,
                  height: 1.45,
                  color: Fx.accent,
                ),
              ),
            ),
          ],
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
                  // 统计不再只说「48 个源」，而是把 48 拆开：
                  // 幻想 7 + 肥猫 41，和上面两条内置项对得上。
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

  /// 云端源：只有两条内置项。
  ///
  /// 之前把「云端源」下的 7 条和「我的源」下的 41 条 jar 源全部逐个列出来，
  /// 每条还带完整 api 地址和删除按钮 —— 用户既看不懂那些地址，也分不清哪条
  /// 是内置的、哪条是自己加的。现在：
  ///   · `幻想`：我们自己的 7 条线路，只显示名字，行尾「内置」；
  ///   · `肥猫`：TVBox 配置带进来的 41 个 jar 源，界面只算一条，副标题写
  ///     「41 个源」。
  /// 两条都不可删；以前删过内置源的，这里还给一个「恢复默认」。
  Widget _builtinList() {
    final bundled = _hub.bundledSources.length;
    final removed =
        _hub.cloudSources.where((s) => _hub.isRemoved(s.key)).length;
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      radius: 18,
      child: Column(
        children: [
          _builtinRow(
            icon: Icons.auto_awesome_motion_rounded,
            name: '幻想',
            subtitle: '',
          ),
          _divider(),
          _builtinRow(
            icon: Icons.pets_rounded,
            name: '肥猫',
            subtitle: '$bundled 个源',
          ),
          if (_hub.cloudSources.isEmpty) ...[
            _divider(),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Text(
                '云端配置里还没有幻想线路，点右上角的刷新重新拉一次。',
                style: TextStyle(fontSize: 11, height: 1.5, color: Fx.sub),
              ),
            ),
          ],
          if (removed > 0) ...[
            _divider(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '已停用 $removed 条幻想线路',
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

  /// 一条内置源：名字（+ 可选副标题）+ 行尾「内置」，不显示地址、不给删除。
  Widget _builtinRow({
    required IconData icon,
    required String name,
    required String subtitle,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Icon(icon, size: 17, color: Fx.accent),
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
                    color: Fx.ink,
                  ),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 10.5, color: Fx.sub),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
          _chip('内置'),
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
                '还没有自己添加的片源。肥猫那 41 个源算在「云端源」那一条里，'
                '这里只放你自己加的 CMS 接口，也可以粘贴 TVBox 配置批量导入。',
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
                // 不显示地址：编辑弹窗里能看能改，列表里一串 URL
                // 既撑破行宽也不提供任何信息（用户自己加的源自己清楚）。
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
    _toast(ok ? '云端配置已更新（${_hub.retrievalLabel}）' : '拉取失败：${_hub.lastError}');
  }

  Future<void> _restore() async {
    await _hub.restoreDefaults();
    if (!mounted) return;
    _toast('已恢复默认：内置源全部回来');
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
    final extCtrl = TextEditingController(text: source?.ext ?? '');
    var type = switch (source?.kind) {
      KSourceKind.direct => 0,
      KSourceKind.jar => 3,
      _ => 1,
    };

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
                  decoration: InputDecoration(
                    labelText: type == 3 ? 'api（jar 里的类名）' : '接口地址',
                    hintText: type == 3
                        ? 'csp_Xxx'
                        : 'https://xxx/api.php/provide/vod/',
                  ),
                ),
                if (type == 3) ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: extCtrl,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'ext（站点配置）',
                      hintText: '地址或 JSON，由这个 jar 指定，可留空',
                    ),
                  ),
                ],
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
                    const SizedBox(width: 8),
                    _typeChip('jar 插件 (3)', 3, type, (v) {
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
    final ext = extCtrl.text.trim();
    nameCtrl.dispose();
    apiCtrl.dispose();
    extCtrl.dispose();
    if (saved != true || !mounted) return;
    try {
      if (source == null) {
        final made = await _hub.addUser(
          name: name,
          api: api,
          type: type,
          ext: ext,
        );
        if (mounted) _toast('已添加「${made.name}」');
      } else {
        await _hub.updateUser(
          source.key,
          name: name,
          api: api,
          type: type,
          ext: ext,
        );
        if (mounted) _toast('已保存');
      }
    } catch (e) {
      if (!mounted) return;
      _toast('$e');
    }
  }

  Future<void> _importTvBox() async {
    // 默认就填好肥猫的配置地址：多数人点「导入」就够了，不用自己去找地址。
    final ctrl = TextEditingController(text: SourceHub.defaultTvBoxUrl);
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
                '粘贴含 sites 数组的 JSON，或填配置地址（http 开头，默认是肥猫）。'
                '加密配置（\$#key#\$ + AES）会自动解密。'
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

  /* ------------------------------------------------------------ jar 插件 */

  /// jar 插件卡片：显示有没有装 spider.jar，装了能更新/卸载。
  ///
  /// 为什么要在这里放入口：TVBox 的 type 3 源（肥猫 / 饭太硬 / 二小这类）
  /// 都是「一个 jar + 一堆站点配置」，不装 jar 那些源永远是空的，
  /// 用户不会知道要去哪里补这一块。
  Widget _jarCard() {
    // 状态 / 进度 / 失败原因 / 自检 / 四种安装方式都在共用组件里，
    // 和「设置 → jar 插件」保持完全一致（那边是同一个 Widget）。
    return JarPluginCard(
      dense: true,
      onChanged: () => setState(() {}),
    );
  }

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

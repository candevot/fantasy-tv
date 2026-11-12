import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../auth.dart';
import '../models.dart';
import '../theme.dart';
import 'downloads_page.dart';
import 'favorite_page.dart';
import 'history_page.dart';
import 'login_page.dart';
import 'player_page.dart';
import 'settings_page.dart';
import '../utils/fx_route.dart';
import '../widgets/fx_recent_row.dart';

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

  /// 最近观看（带封面），按 updatedAt 倒序。
  List<Map<String, dynamic>> _recent = const [];
  bool _avatarBusy = false;
  bool _statsReady = false;

  @override
  void initState() {
    super.initState();
    Auth.instance.addListener(_onAuth);
    _load();
  }

  @override
  void dispose() {
    Auth.instance.removeListener(_onAuth);
    super.dispose();
  }

  void _onAuth() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final res = await Future.wait<int>([
      FxStore.count(FxStore.historyKey),
      FxStore.count(FxStore.favoriteKey),
      FxStore.count(FxStore.downloadKey),
    ]);
    final hist = await FxStore.read(FxStore.historyKey);
    hist.sort((a, b) =>
        fxInt(b['updatedAt']).compareTo(fxInt(a['updatedAt'])));
    if (!mounted) return;
    setState(() {
      _history = res[0];
      _favorite = res[1];
      _download = res[2];
      _recent = hist;
      _statsReady = true;
    });
  }

  /// 点最近观看：直接进播放页续播（带集数和线路）。
  Future<void> _openRecent(Map<String, dynamic> item) async {
    final id = fxStr(item['id']);
    if (id.isEmpty) return;
    await Navigator.of(context).push(
      FxPageRoute(
        builder: (_) => PlayerPage(
          videoId: id,
          ep: fxInt(item['ep'], 1),
          line: fxStr(item['lineId']).isEmpty
              ? fxStr(item['line'])
              : fxStr(item['lineId']),
        ),
      ),
    );
    if (mounted) _load();
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(FxPageRoute(builder: (_) => page));
    if (mounted) _load();
  }

  void _toast(String text) {
    final m = ScaffoldMessenger.maybeOf(context);
    if (m == null) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(text),
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xEE1B2430),
      margin: const EdgeInsets.fromLTRB(22, 0, 22, 18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      duration: const Duration(milliseconds: 1800),
    ));
  }

  /* ------------------------------------------------------------ 账号 */

  Future<void> _openLogin() async {
    await Navigator.of(context)
        .push(FxPageRoute(builder: (_) => const LoginPage()));
    if (!mounted) return;
    Auth.instance.refresh();
  }

  Future<void> _pickAvatar() async {
    if (_avatarBusy) return;
    final user = Auth.instance.user;
    if (user == null) {
      await _openLogin();
      return;
    }
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1400,
        maxHeight: 1400,
        imageQuality: 92,
      );
      if (picked == null) return;
      if (!mounted) return;
      setState(() => _avatarBusy = true);
      // 读取原图 → 压缩 → base64 → POST /user/avatar → 更新本地用户。
      final raw = await picked.readAsBytes();
      await Auth.instance.uploadAvatar(raw);
      if (!mounted) return;
      _toast('头像已更新');
    } on PlatformException catch (e) {
      if (mounted) _toast('无法打开相册：${e.message ?? '请检查权限'}');
    } on ApiException catch (e) {
      if (mounted) _toast(e.message);
    } catch (e) {
      if (mounted) {
        _toast(e is Exception ? e.toString() : '头像处理失败，请重试');
      }
    } finally {
      if (mounted) setState(() => _avatarBusy = false);
    }
  }

  Future<void> _editNickname() async {
    final user = Auth.instance.user;
    if (user == null) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NicknameDialog(initial: user.nickname),
    );
    if (!mounted || name == null) return;
    try {
      await Auth.instance.updateNickname(name);
      if (!mounted) return;
      _toast('昵称已更新');
    } catch (e) {
      if (!mounted) return;
      _toast(e is Exception ? e.toString() : '修改失败，请稍后重试');
    }
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white.withValues(alpha: .98),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('退出登录？',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w800, color: Fx.ink)),
        content: const Text('退出后本机观看记录仍会保留，下次登录可继续修改昵称与头像。',
            style: TextStyle(fontSize: 13, color: Fx.sub, height: 1.5)),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child:
                const Text('取消', style: TextStyle(fontSize: 13, color: Fx.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('退出',
                style: TextStyle(
                    fontSize: 13,
                    color: Color(0xFFE05252),
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await Auth.instance.logout();
    if (mounted) _toast('已退出登录');
  }

  /* ------------------------------------------------------------ UI */

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
        onRefresh: () async {
          await Future.wait([_load(), Auth.instance.refresh()]);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Text('我的',
                    style: TextStyle(
                        fontSize: 20,
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                        color: Fx.ink)),
                const Spacer(),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .66),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white),
                  ),
                  child: const Text('v1.0.0',
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w400,
                          color: Color(0xFFA6B1C2))),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // MINE_V2（2026-11-12）：按腾讯/爱奇艺的排法重排。
            //
            // 顶部大头图（头像 + 昵称 + 统计）→ 最近观看横滑 →
            // 功能宫格。原来「观看统计」单独占一块，把首屏切得很碎。
            _hero(),
            // 最近观看：带封面横滑，点卡片直接续播
            if (_recent.isNotEmpty) ...[
              const SizedBox(height: 24),
              FxRecentRow(
                items: _recent,
                onTapItem: _openRecent,
                onMore: () => _open(const HistoryPage()),
              ),
            ],
            const SizedBox(height: 24),
            _sectionHeader('我的'),
            const SizedBox(height: 10),
            _entryGrid(),
            const SizedBox(height: 28),
            const Center(
              child: Text(
                '无广告 · 无会员 · 只为看好剧',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: Color(0xFFA6B1C2),
                    letterSpacing: .3),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String title, {String? trailing}) {
    return Row(
      children: [
        Text(title,
            style: const TextStyle(
                fontSize: 17,
                height: 1.2,
                fontWeight: FontWeight.w600,
                color: Fx.ink)),
        const Spacer(),
        if (trailing != null)
          Text(trailing,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: Color(0xFFA6B1C2))),
      ],
    );
  }

  Widget _profile() {
    final user = Auth.instance.user;
    final logged = user != null;
    final account = user?.account.trim() ?? '';
    return Row(
        children: [
          _avatar(user),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: logged ? _editNickname : _openLogin,
                        child: Text(
                          logged
                              ? (user.nickname.isEmpty ? '幻想用户' : user.nickname)
                              : '点击登录 / 注册',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 18,
                              height: 1.2,
                              fontWeight: FontWeight.w600,
                              color: Fx.ink),
                        ),
                      ),
                    ),
                    if (logged) ...[
                      const SizedBox(width: 7),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _editNickname,
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: .82),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white),
                          ),
                          child: const Icon(Icons.edit_rounded,
                              size: 12, color: Fx.sub),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: logged
                            ? const Color(0xFF4CC38A)
                            : const Color(0xFFF2B45E),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        logged
                            ? (account.isEmpty ? '已登录' : '已登录 · $account')
                            : '未登录 · 登录后同步观看记录',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            color: Fx.sub),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (logged)
            Tooltip(
              message: '退出登录',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _logout,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .62),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white),
                  ),
                  child: const Icon(Icons.logout_rounded,
                      size: 16, color: Color(0xFF8E99A8)),
                ),
              ),
            )
          else
            GradButton(text: '登录', height: 32, onTap: _openLogin),
        ],
    );
  }

  Widget _avatar(AuthUser? user) {
    final logged = user != null;
    Widget content;
    final path = Auth.instance.avatarPath;
    // 头像只显示 64pt，按 dpr 解码，别把 1MB 原图塞进图片缓存。
    final cacheWidth =
        (64 * MediaQuery.devicePixelRatioOf(context)).round().clamp(64, 512);
    if (path.isNotEmpty && File(path).existsSync()) {
      content = Image.file(
        File(path),
        width: 64,
        height: 64,
        cacheWidth: cacheWidth,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _avatarFallback(user),
      );
    } else if (user != null && user.avatar.trim().isNotEmpty) {
      content = FxNetworkImage(
        url: user.avatar,
        width: 64,
        height: 64,
        cacheWidth: cacheWidth,
        fit: BoxFit.cover,
        fallback: _avatarFallback(user),
      );
    } else {
      content = _avatarFallback(user);
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: logged ? _pickAvatar : _openLogin,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Fx.accent.withValues(alpha: .28),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: ClipOval(child: content),
          ),
          if (logged)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  gradient: Fx.brand,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.8),
                ),
                child: const Icon(Icons.photo_camera_rounded,
                    size: 11, color: Colors.white),
              ),
            ),
          if (_avatarBusy)
            Positioned.fill(
              child: ClipOval(
                child: Container(
                  color: Colors.black.withValues(alpha: .32),
                  child: const Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _avatarFallback(AuthUser? user) {
    final nickname = user?.nickname ?? '幻';
    final char =
        nickname.isNotEmpty ? String.fromCharCode(nickname.runes.first) : '幻';
    return Container(
      width: 64,
      height: 64,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: Fx.brand,
      ),
      child: Text(
        char,
        style: const TextStyle(
            fontSize: 27, fontWeight: FontWeight.w800, color: Colors.white),
      ),
    );
  }

  Widget _divider() {
    return Container(
      width: 1,
      height: 28,
      color: Fx.ink.withValues(alpha: .06),
    );
  }

  /// 顶部大头图：头像 + 昵称 + 三格统计，一块玻璃卡包住。
  ///
  /// 腾讯/爱奇艺的「我的」页都是这种结构：上面一块整的，
  /// 统计数字压在头像下面，不再单独开一个「观看统计」分区。
  Widget _hero() {
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      radius: 22,
      opacity: .72,
      child: Column(
        children: [
          _profile(),
          const SizedBox(height: 14),
          Container(
            height: 1,
            color: Colors.white.withValues(alpha: .72),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _heroStat(_statsReady ? '$_history' : '—', '观看'),
              _heroDivider(),
              _heroStat(_statsReady ? '$_favorite' : '—', '收藏'),
              _heroDivider(),
              _heroStat(_statsReady ? '$_download' : '—', '缓存'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _heroStat(String value, String label) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (label == '观看') {
            _open(const HistoryPage());
          } else if (label == '收藏') {
            _open(const FavoritePage());
          } else {
            _open(const DownloadsPage());
          }
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              style: const TextStyle(
                fontSize: 19,
                height: 1.1,
                fontWeight: FontWeight.w700,
                color: Fx.ink,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: const TextStyle(fontSize: 10.5, color: Fx.sub),
            ),
          ],
        ),
      ),
    );
  }

  Widget _heroDivider() {
    return Container(
      width: 1,
      height: 26,
      color: Colors.white.withValues(alpha: .78),
    );
  }

  Widget _entryGrid() {
    final entries = _entries;
    return LayoutBuilder(
      builder: (ctx, cons) {
        const gap = 12.0;
        final itemWidth = (cons.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final e in entries)
              SizedBox(width: itemWidth, child: _entryTile(e)),
          ],
        );
      },
    );
  }

  Widget _entryTile(_Entry e) {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      radius: 18,
      opacity: .62,
      onTap: () => _open(e.builder(context)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: e.color.withValues(alpha: .11),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(e.icon, size: 19, color: e.color),
              ),
              const Spacer(),
              const Icon(Icons.chevron_right_rounded,
                  size: 18, color: Color(0xFFB3BECD)),
            ],
          ),
          const SizedBox(height: 14),
          Text(e.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 14,
                  height: 1.2,
                  fontWeight: FontWeight.w500,
                  color: Fx.ink)),
          const SizedBox(height: 4),
          Text(e.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 12,
                  height: 1.2,
                  fontWeight: FontWeight.w400,
                  color: Fx.sub)),
        ],
      ),
    );
  }
}

class _NicknameDialog extends StatefulWidget {
  const _NicknameDialog({required this.initial});
  final String initial;

  @override
  State<_NicknameDialog> createState() => _NicknameDialogState();
}

class _NicknameDialogState extends State<_NicknameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white.withValues(alpha: .98),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      title: const Text('修改昵称',
          style: TextStyle(
              fontSize: 17, fontWeight: FontWeight.w800, color: Fx.ink)),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 20,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
        style: const TextStyle(
            fontSize: 15, color: Fx.ink, fontWeight: FontWeight.w600),
        decoration: InputDecoration(
          hintText: '输入新昵称（最多 20 字）',
          hintStyle: const TextStyle(fontSize: 13, color: Color(0xFFA6B1C2)),
          filled: true,
          fillColor: const Color(0xFFF3F6FB),
          counterStyle:
              const TextStyle(fontSize: 9.5, color: Color(0xFFA6B1C2)),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(13),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(13),
            borderSide: const BorderSide(color: Fx.accent, width: 1.2),
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child:
              const Text('取消', style: TextStyle(fontSize: 13, color: Fx.sub)),
        ),
        TextButton(
          onPressed: _save,
          child: const Text('保存',
              style: TextStyle(
                  fontSize: 13, color: Fx.accent, fontWeight: FontWeight.w700)),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../auth.dart';
import '../theme.dart';
import 'category_page.dart';
import 'change_password_page.dart';
import 'login_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _checking = false;
  int _cacheBytes = 0;

  @override
  void initState() {
    super.initState();
    _cacheBytes = PaintingBinding.instance.imageCache.currentSizeBytes;
    Auth.instance.addListener(_onAuth);
  }

  @override
  void dispose() {
    Auth.instance.removeListener(_onAuth);
    super.dispose();
  }

  void _onAuth() {
    if (mounted) setState(() {});
  }

  Future<void> _openChangePassword() async {
    if (Auth.instance.user == null) {
      await Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const LoginPage()));
      if (!mounted || Auth.instance.user == null) return;
    }
    if (!mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ChangePasswordPage()));
  }

  void _toast(String msg) {
    final m = ScaffoldMessenger.maybeOf(context);
    if (m == null) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xEE1B2430),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ));
  }

  Future<void> _clearCache() async {
    final before = PaintingBinding.instance.imageCache.currentSizeBytes;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text('清除缓存？',
            style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700)),
        content: const Text('将清理临时图片缓存，不会影响收藏、观看历史与离线记录。',
            style: TextStyle(fontSize: 12.5, height: 1.5, color: Fx.sub)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Fx.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清除', style: TextStyle(color: Fx.accent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    setState(() => _cacheBytes = 0);
    _toast(before > 0 ? '已清理 ${fxBytes(before)} 缓存' : '缓存已清理');
  }

  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    await Future<void>.delayed(const Duration(milliseconds: 850));
    if (!mounted) return;
    setState(() => _checking = false);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                color: const Color(0xFF5BC8A8).withOpacity(.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_rounded,
                  size: 28, color: Color(0xFF2FA985)),
            ),
            const SizedBox(height: 14),
            const Text('已是最新版本',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Fx.ink)),
            const SizedBox(height: 6),
            const Text('幻想影视 v1.0.0',
                style: TextStyle(fontSize: 11.5, color: Fx.sub)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了', style: TextStyle(color: Fx.accent)),
          ),
        ],
      ),
    );
  }

  void _showAbout() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 22),
        decoration: const BoxDecoration(
          color: Color(0xFFFBFDFF),
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: const Color(0xFFDCE4F0),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: Fx.brand,
                  boxShadow: [
                    BoxShadow(
                      color: Fx.accent.withOpacity(.30),
                      blurRadius: 22,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.asset(
                  'assets/logo.png',
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stack) => const Icon(
                      Icons.play_arrow_rounded,
                      size: 36,
                      color: Colors.white),
                ),
              ),
              const SizedBox(height: 12),
              const Text('幻想影视',
                  style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: Fx.ink,
                      letterSpacing: .5)),
              const SizedBox(height: 4),
              const Text('版本 1.0.0',
                  style: TextStyle(fontSize: 11, color: Fx.sub)),
              const SizedBox(height: 14),
              const Text(
                '纯净无广告的高清追剧应用，支持多线路播放、4K 画质与离线缓存。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, height: 1.65, color: Fx.sub),
              ),
              const SizedBox(height: 15),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                alignment: WrapAlignment.center,
                children: [
                  for (final t in ['无广告', '4K 高清', '多线路', 'AI 找片'])
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Fx.accent.withOpacity(.07),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(t,
                          style: const TextStyle(
                              fontSize: 10, color: Fx.accent)),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              Text('© ${DateTime.now().year} 幻想影视',
                  style: const TextStyle(
                      fontSize: 9.5, color: Color(0xFFB3BECD))),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FxPageScaffold(
      title: '设置',
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 30),
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 8),
            child: Text('通用',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Fx.sub)),
          ),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            radius: 20,
            child: Column(
              children: [
                _row(
                  icon: Icons.cleaning_services_rounded,
                  color: Fx.accent,
                  title: '清除缓存',
                  subtitle: '临时图片与运行缓存',
                  trailing: Text(fxBytes(_cacheBytes),
                      style: const TextStyle(fontSize: 11, color: Fx.sub)),
                  onTap: _clearCache,
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 48),
                  child: Container(height: 1, color: Fx.ink.withOpacity(.05)),
                ),
                _row(
                  icon: Icons.system_update_rounded,
                  color: const Color(0xFF5BC8A8),
                  title: '检查更新',
                  subtitle: '当前版本 v1.0.0',
                  trailing: _checking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Fx.accent),
                          ),
                        )
                      : const Text('已是最新',
                          style: TextStyle(
                              fontSize: 10.5, color: Color(0xFFA6B1C2))),
                  onTap: _checkUpdate,
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 22, 4, 8),
            child: Text('账号与安全',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Fx.sub)),
          ),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            radius: 20,
            child: _row(
              icon: Icons.password_rounded,
              color: const Color(0xFFE08A3C),
              title: '修改密码',
              subtitle: Auth.instance.user == null
                  ? '登录后可修改登录密码'
                  : '旧密码验证，定期更换更安全',
              trailing: Text(
                  Auth.instance.user == null ? '去登录' : '修改',
                  style: const TextStyle(fontSize: 10.5, color: Color(0xFFA6B1C2))),
              onTap: _openChangePassword,
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 22, 4, 8),
            child: Text('关于',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Fx.sub)),
          ),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            radius: 20,
            child: _row(
              icon: Icons.info_outline_rounded,
              color: Fx.accent2,
              title: '关于幻想影视',
              subtitle: '版本 1.0.0',
              trailing: const Text('1.0.0',
                  style: TextStyle(fontSize: 11, color: Fx.sub)),
              onTap: _showAbout,
            ),
          ),
          const SizedBox(height: 26),
          const Center(
            child: Text('幻想影视 v1.0.0',
                style: TextStyle(
                    fontSize: 10,
                    color: Color(0xFFB3BECD),
                    letterSpacing: .4)),
          ),
        ],
      ),
    );
  }

  Widget _row({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required Widget trailing,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color.withOpacity(.11),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Fx.ink)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(fontSize: 10.5, color: Fx.sub)),
                ],
              ),
            ),
            trailing,
            const SizedBox(width: 2),
            const Icon(Icons.chevron_right_rounded,
                size: 18, color: Color(0xFFC3CDDA)),
          ],
        ),
      ),
    );
  }
}

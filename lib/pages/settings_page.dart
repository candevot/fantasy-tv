import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth.dart';
import '../services/app_info.dart';
import '../services/app_settings.dart';
import '../services/app_update_service.dart';
import '../services/download_service.dart';
import '../theme.dart';
import 'about_page.dart';
import 'category_page.dart';
import 'change_password_page.dart';
import 'download_settings_page.dart';
import 'feedback_page.dart';
import 'login_page.dart';

/// 设置页：账号安全 / 播放设置 / 下载与缓存 / 关于 / 退出登录。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final AppSettings _settings = AppSettings.instance;
  final DownloadService _downloads = DownloadService.instance;

  bool _checking = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onChanged);
    _downloads.addListener(_onChanged);
    Auth.instance.addListener(_onChanged);
    _load();
  }

  @override
  void dispose() {
    _settings.removeListener(_onChanged);
    _downloads.removeListener(_onChanged);
    Auth.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      await _settings.init();
      await AppInfo.load();
      await _downloads.init();
      await _downloads.refreshUsage();
    } catch (e) {
      debugPrint('SettingsPage: load failed: $e');
    }
    if (!mounted) return;
    setState(() => _ready = true);
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

  Future<void> _openDownloadSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const DownloadSettingsPage()),
    );
    if (!mounted) return;
    await _downloads.refreshUsage();
    if (mounted) setState(() {});
  }

  Future<void> _openAbout() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AboutPage()),
    );
  }

  Future<void> _openFeedback() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const FeedbackPage()),
    );
  }

  Future<void> _pickQuality() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _QualitySheet(current: _settings.defaultQuality),
    );
    if (selected == null || !mounted) return;
    await _settings.setDefaultQuality(selected);
    if (!mounted) return;
    _toast('默认清晰度已设为「${_settings.defaultQualityLabel}」');
  }

  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final info = await AppUpdateService.check();
      if (!mounted) return;
      if (info.hasUpdate) {
        setState(() => _checking = false);
        await _showUpdate(info);
        return;
      }
      _toast('已是最新版本 ${AppInfo.displayVersion}');
    } on AppUpdateException catch (e) {
      if (mounted) _toast(e.message);
    } catch (_) {
      if (mounted) _toast('检查更新失败，请检查网络后重试');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _showUpdate(AppUpdateInfo info) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Fx.accent.withOpacity(.10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.system_update_rounded,
                size: 20,
                color: Fx.accent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '发现新版本',
                    style: TextStyle(
                      fontSize: 16.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '当前 ${AppInfo.displayVersion} → 最新 ${info.displayVersion}',
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w400,
                      color: Fx.sub,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (info.notes.trim().isNotEmpty) ...[
              Text(
                info.notes.trim(),
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: Fx.sub,
                ),
              ),
              const SizedBox(height: 12),
            ],
            const Text(
              '下载链接',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Fx.ink,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              decoration: BoxDecoration(
                color: const Color(0xFFF4F7FC),
                borderRadius: BorderRadius.circular(11),
              ),
              child: SelectableText(
                info.downloadUrl,
                style: const TextStyle(
                  fontSize: 10.5,
                  height: 1.45,
                  color: Fx.accent,
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '复制链接后可在浏览器中下载安装包。',
              style: TextStyle(fontSize: 10, color: Color(0xFFA6B1C2)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('稍后', style: TextStyle(color: Fx.sub)),
          ),
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: info.downloadUrl));
              if (!mounted) return;
              Navigator.pop(ctx);
              _toast('下载链接已复制，请在浏览器中打开');
            },
            child: const Text('复制链接', style: TextStyle(color: Fx.accent)),
          ),
        ],
      ),
    );
  }

  Future<void> _logout() async {
    if (Auth.instance.user == null) {
      _toast('当前未登录');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text(
          '退出登录？',
          style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700),
        ),
        content: const Text(
          '退出后本机观看记录、收藏与离线缓存仍会保留，下次登录可继续使用。',
          style: TextStyle(fontSize: 12.5, height: 1.5, color: Fx.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Fx.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '退出',
              style: TextStyle(color: Color(0xFFE05252)),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await Auth.instance.logout();
    if (mounted) _toast('已退出登录');
  }

  @override
  Widget build(BuildContext context) {
    final user = Auth.instance.user;
    return FxPageScaffold(
      title: '设置',
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 30),
        children: [
          const _SectionTitle('账号安全'),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            radius: 20,
            child: _row(
              icon: Icons.password_rounded,
              color: const Color(0xFFE08A3C),
              title: '修改密码',
              subtitle: user == null
                  ? '登录后可修改登录密码'
                  : '已登录：${user.nickname.trim().isEmpty ? user.account : user.nickname}',
              trailing: Text(
                user == null ? '去登录' : '修改',
                style: const TextStyle(
                  fontSize: 10.5,
                  color: Color(0xFFA6B1C2),
                ),
              ),
              onTap: _openChangePassword,
            ),
          ),
          const _SectionTitle('播放设置'),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            radius: 20,
            child: Column(
              children: [
                _row(
                  icon: Icons.high_quality_rounded,
                  color: Fx.accent,
                  title: '默认清晰度',
                  subtitle: _qualityHint(_settings.defaultQuality),
                  trailing: Text(
                    _settings.defaultQualityLabel,
                    style: const TextStyle(fontSize: 11, color: Fx.sub),
                  ),
                  onTap: _pickQuality,
                ),
                _divider(),
                _switchRow(
                  icon: Icons.skip_next_rounded,
                  color: const Color(0xFF8E6BFF),
                  title: '自动下一集',
                  subtitle: '当前集播完后自动播放下一集',
                  value: _settings.autoNext,
                  onChanged: (value) async {
                    await _settings.setAutoNext(value);
                    if (!mounted) return;
                    _toast(value ? '已开启自动下一集' : '已关闭自动下一集');
                  },
                ),
                _divider(),
                _switchRow(
                  icon: Icons.fast_forward_rounded,
                  color: const Color(0xFF2FA985),
                  title: '跳过片头片尾',
                  subtitle: '默认关闭，开启后全屏与自动连播生效',
                  value: _settings.skipIntroOutro,
                  onChanged: (value) async {
                    await _settings.setSkipIntroOutro(value);
                    if (!mounted) return;
                    _toast(value ? '已开启跳过片头片尾' : '已关闭跳过片头片尾');
                  },
                ),
              ],
            ),
          ),
          const _SectionTitle('下载与缓存'),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            radius: 20,
            child: _row(
              icon: Icons.download_rounded,
              color: const Color(0xFF5BC8A8),
              title: '下载与缓存',
              subtitle: _downloadHint(),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _ready ? fxBytes(_downloads.usedBytes) : '统计中…',
                    style: const TextStyle(fontSize: 11, color: Fx.sub),
                  ),
                  const SizedBox(width: 2),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: Color(0xFFC3CDDA),
                  ),
                ],
              ),
              onTap: _openDownloadSettings,
              showChevron: false,
            ),
          ),
          const _SectionTitle('关于'),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            radius: 20,
            child: Column(
              children: [
                _row(
                  icon: Icons.info_outline_rounded,
                  color: Fx.accent2,
                  title: '关于幻想影视',
                  subtitle: _ready ? AppInfo.fullVersion : '正在读取版本…',
                  trailing: Text(
                    _ready ? AppInfo.displayVersion : '',
                    style: const TextStyle(fontSize: 11, color: Fx.sub),
                  ),
                  onTap: _openAbout,
                ),
                _divider(),
                _row(
                  icon: Icons.feedback_outlined,
                  color: const Color(0xFFFF7EA8),
                  title: '意见反馈',
                  subtitle: '提交问题或建议，我们会尽快查看',
                  trailing: const SizedBox.shrink(),
                  onTap: _openFeedback,
                ),
                _divider(),
                _row(
                  icon: Icons.system_update_rounded,
                  color: const Color(0xFF2FA985),
                  title: '检查更新',
                  subtitle: '当前 ${_ready ? AppInfo.displayVersion : '…'}',
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
                      : const Text(
                          '检查',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: Color(0xFFA6B1C2),
                          ),
                        ),
                  onTap: _checkUpdate,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _logoutButton(user != null),
          const SizedBox(height: 18),
          Center(
            child: Text(
              '${AppInfo.appName} ${_ready ? AppInfo.displayVersion : ''}',
              style: const TextStyle(
                fontSize: 10,
                color: Color(0xFFB3BECD),
                letterSpacing: .4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _qualityHint(String key) {
    for (final option in AppSettings.qualityOptions) {
      if (option.key == key) return option.hint;
    }
    return AppSettings.qualityOptions.first.hint;
  }

  String _downloadHint() {
    if (!_ready) return '正在读取下载设置…';
    final parts = <String>[
      _downloads.locationLabel,
      if (_downloads.storageFallback) '应用专属',
      if (_settings.wifiOnlyDownload) '仅 Wi-Fi',
    ];
    return parts.join(' · ');
  }

  Widget _logoutButton(bool loggedIn) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _logout,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(.72),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFFFD7D7)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.logout_rounded,
              size: 18,
              color: loggedIn ? const Color(0xFFE05252) : Fx.sub,
            ),
            const SizedBox(width: 6),
            Text(
              '退出登录',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: loggedIn ? const Color(0xFFE05252) : Fx.sub,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _divider() => Padding(
        padding: const EdgeInsets.only(left: 48),
        child: Container(height: 1, color: Fx.ink.withOpacity(.05)),
      );

  Widget _row({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required Widget trailing,
    required VoidCallback onTap,
    bool showChevron = true,
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
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Fx.ink,
                    ),
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
            trailing,
            if (showChevron) ...[
              const SizedBox(width: 2),
              const Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: Color(0xFFC3CDDA),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _switchRow({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
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
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Fx.ink,
                  ),
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
          Switch.adaptive(
            value: value,
            activeColor: Fx.accent,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Fx.sub,
        ),
      ),
    );
  }
}

class _QualitySheet extends StatelessWidget {
  const _QualitySheet({required this.current});

  final String current;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 22),
      decoration: const BoxDecoration(
        color: Color(0xFFFBFDFF),
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: const Color(0xFFDCE4F0),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Text(
              '默认清晰度',
              style: TextStyle(
                fontSize: 16.5,
                fontWeight: FontWeight.w700,
                color: Fx.ink,
              ),
            ),
            const SizedBox(height: 12),
            for (final option in AppSettings.qualityOptions) ...[
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.pop(context, option.key),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: current == option.key
                        ? Fx.accent.withOpacity(.07)
                        : Colors.white.withOpacity(.72),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: current == option.key
                          ? Fx.accent.withOpacity(.45)
                          : Colors.white,
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              option.label,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color:
                                    current == option.key ? Fx.accent : Fx.ink,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              option.hint,
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: Fx.sub,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        current == option.key
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 19,
                        color: current == option.key
                            ? Fx.accent
                            : const Color(0xFFC3CDDA),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

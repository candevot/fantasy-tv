import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth.dart';
import '../services/app_info.dart';
import '../services/app_settings.dart';
import '../services/app_update_service.dart';
import '../services/download_service.dart';
import '../services/exo_player.dart';
import '../services/jar_plugin.dart';
import '../services/playback_params.dart';
import '../services/source_hub.dart';
import '../theme.dart';
import 'about_page.dart';
import 'category_page.dart';
import 'change_password_page.dart';
import 'download_settings_page.dart';
import 'feedback_page.dart';
import 'login_page.dart';
import 'source_settings_page.dart';
import '../utils/fx_route.dart';

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

  /// 是否已在电池优化白名单里（BG_SERVICE：后台播放保活）。
  bool _batteryOk = false;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onChanged);
    _downloads.addListener(_onChanged);
    Auth.instance.addListener(_onChanged);
    SourceHub.instance.addListener(_onChanged);
    JarPluginManager.instance.addListener(_onChanged);
    // 片源配置在后台补一次（有缓存就直接用，不挡设置页渲染）。
    unawaited(SourceHub.instance.ensureReady());
    _load();
  }

  @override
  void dispose() {
    _settings.removeListener(_onChanged);
    _downloads.removeListener(_onChanged);
    Auth.instance.removeListener(_onChanged);
    SourceHub.instance.removeListener(_onChanged);
    JarPluginManager.instance.removeListener(_onChanged);
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
    final batteryOk = await ExoPlayerEngine.isIgnoringBatteryOptimizations();
    if (!mounted) return;
    setState(() {
      _ready = true;
      _batteryOk = batteryOk;
    });
  }

  /// 后台播放保活的白名单入口（BG_SERVICE，2026-11-15）。
  ///
  /// 只在用户**主动点**这里时才拉系统页面 —— 不在启动 / 播放时弹对话框，
  /// 那对用户是纯骚扰。返回 false 表示这台机器没有对应的系统页面。
  Future<void> _openBatteryWhitelist() async {
    final ok = await ExoPlayerEngine.requestIgnoreBatteryOptimizations();
    if (!mounted) return;
    if (!ok) {
      _toast('这台机器没有电池优化设置页，请到系统设置里允许「幻想影视」后台运行');
      return;
    }
    final ignoring = await ExoPlayerEngine.isIgnoringBatteryOptimizations();
    if (!mounted) return;
    setState(() => _batteryOk = ignoring);
    if (ignoring) _toast('已加入电池优化白名单');
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
          .push(FxPageRoute(builder: (_) => const LoginPage()));
      if (!mounted || Auth.instance.user == null) return;
    }
    if (!mounted) return;
    await Navigator.of(context)
        .push(FxPageRoute(builder: (_) => const ChangePasswordPage()));
  }

  /// 缓冲档位选择（PARAMS_ALIGN 阶段 2 第 5 条）。
  ///
  /// 十档一次列全：壳的 `buffer` 就是 1..10 的整数，用户要的就是「拖多久
  /// 之后能接着看」。改完立刻推给原生（下次建播放器生效），并提示用户
  /// 需要重进播放页 —— 正在播的实例不重建，避免为了一个档位打断视频。
  Future<void> _openBufferLevel() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: EdgeInsets.fromLTRB(
            20, 16, 20, 22 + MediaQuery.of(ctx).padding.bottom),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '播放缓冲档位',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: Fx.ink,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '档位越高，能承受的网络抖动越大，但起播前要等的数据也越多。'
              '改完下次进播放页生效。',
              style: TextStyle(fontSize: 11.5, height: 1.5, color: Fx.sub),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var n = AppSettings.minBufferLevel;
                    n <= AppSettings.maxBufferLevel;
                    n++)
                  ChoiceChip(
                    label: Text('$n 档'),
                    selected: n == _settings.bufferLevel,
                    selectedColor: Fx.accent,
                    labelStyle: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: n == _settings.bufferLevel
                          ? Colors.white
                          : Fx.ink,
                    ),
                    onSelected: (_) => Navigator.of(ctx).pop(n),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '当前：${AppSettings.bufferLevelHint(_settings.bufferLevel)}'
              '（一档 = ${AppSettings.bufferStepMs ~/ 1000} 秒）',
              style: const TextStyle(fontSize: 10.5, color: Fx.sub),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (selected == _settings.bufferLevel) return;
    await _settings.setBufferLevel(selected);
    // 设置只落盘不够：内核要拿到它（下次建播放器生效）。
    unawaited(PlaybackParamsInstaller.sync(_settings));
    if (mounted) _toast('缓冲已设为 $selected 档（${selected * 50} 秒），重进播放页生效');
  }

  Future<void> _openDownloadSettings() async {
    await Navigator.of(context).push(
      FxPageRoute(builder: (_) => const DownloadSettingsPage()),
    );
    if (!mounted) return;
    await _downloads.refreshUsage();
    if (mounted) setState(() {});
  }

  Future<void> _openAbout() async {
    await Navigator.of(context).push(
      FxPageRoute(builder: (_) => const AboutPage()),
    );
  }

  Future<void> _openFeedback() async {
    await Navigator.of(context).push(
      FxPageRoute(builder: (_) => const FeedbackPage()),
    );
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
                color: Fx.accent.withValues(alpha: .10),
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
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
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
                maxLines: 3,
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
          // jar 插件那块整块不显示（用户要求：插件不需要露面，
          // 内置 jar 随包走、后台自动更新，用户不用管）。
          const _SectionTitle('片源与直播'),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            radius: 20,
            child: _row(
              icon: Icons.cloud_queue_rounded,
              color: const Color(0xFF5B8CFF),
              title: '片源管理',
              subtitle: _sourceHint(),
              trailing: const Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: Color(0xFFC3CDDA),
              ),
              onTap: _openSources,
              showChevron: false,
            ),
          ),
          const _SectionTitle('播放'),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            radius: 20,
            child: _row(
              icon: Icons.battery_saver_rounded,
              color: const Color(0xFF9B7BFF),
              title: '后台播放保活',
              subtitle: _batteryOk
                  ? '已在电池优化白名单：锁屏 / 切后台继续播，不会被系统回收'
                  : '未加白名单：长时间后台播放可能被系统回收（放着放着断了）',
              trailing: Text(
                _batteryOk ? '已加入' : '去设置',
                style: const TextStyle(
                  fontSize: 10.5,
                  color: Color(0xFFA6B1C2),
                ),
              ),
              onTap: _openBatteryWhitelist,
            ),
          ),
          // PARAMS_ALIGN（2026-11-15 · 阶段 2）：缓冲档位。
          //
          // 对齐壳的 `Setting.getBuffer()`（pref 键 `buffer`，1..10 档）。
          // 一档 = 50 秒（壳 media3 fork 的 DEFAULT_MIN/MAX_BUFFER_MS 都是
          // 50000，buildLoadControl 只把这两个值乘档位）。
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            radius: 20,
            child: Column(
              children: [
                _row(
                  icon: Icons.layers_rounded,
                  color: const Color(0xFF4A9BFF),
                  title: '播放缓冲档位',
                  subtitle: _ready
                      ? AppSettings.bufferLevelHint(_settings.bufferLevel)
                      : '正在读取…',
                  trailing: Text(
                    '${_settings.bufferLevel} 档',
                    style: const TextStyle(fontSize: 11, color: Fx.sub),
                  ),
                  onTap: _openBufferLevel,
                ),
              ],
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

  String _sourceHint() {
    final hub = SourceHub.instance;
    final parts = <String>[
      // 统计拆成「幻想 7 + 肥猫 41」，和片源页那两条内置项对得上。
      '${hub.retrievalLabel} 个源参与检索',
      if (hub.liveUrl.isNotEmpty) '直播已配置',
    ];
    return parts.join(' · ');
  }

  Future<void> _openSources() async {
    await Navigator.of(context).push(
      FxPageRoute(builder: (_) => const SourceSettingsPage()),
    );
    if (mounted) setState(() {});
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
          color: Colors.white.withValues(alpha: .72),
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
        child: Container(height: 1, color: Fx.ink.withValues(alpha: .05)),
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
                color: color.withValues(alpha: .11),
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

import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/download_service.dart';
import '../services/download_storage.dart';
import '../services/network_status.dart';
import '../theme.dart';
import 'category_page.dart';

/// 设置 → 下载与缓存。
class DownloadSettingsPage extends StatefulWidget {
  const DownloadSettingsPage({super.key});

  @override
  State<DownloadSettingsPage> createState() => _DownloadSettingsPageState();
}

class _DownloadSettingsPageState extends State<DownloadSettingsPage> {
  final AppSettings _settings = AppSettings.instance;
  final DownloadService _downloads = DownloadService.instance;

  bool _loading = true;
  bool _switching = false;
  FxNetworkKind _network = FxNetworkKind.unknown;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onChanged);
    _downloads.addListener(_onChanged);
    _load();
  }

  @override
  void dispose() {
    _settings.removeListener(_onChanged);
    _downloads.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      await _settings.init();
      await _downloads.init();
      await _downloads.refreshUsage();
      final network = await NetworkStatus.detect();
      _network = network;
    } catch (_) {}
    if (!mounted) return;
    setState(() => _loading = false);
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

  Future<void> _pickLocation() async {
    if (_switching) return;
    final selected = await showModalBottomSheet<DownloadLocation>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _LocationSheet(current: _downloads.location),
    );
    if (selected == null || !mounted || selected == _downloads.location) return;
    setState(() => _switching = true);
    try {
      await _downloads.setLocation(selected);
      if (!mounted) return;
      final fallback = _downloads.storageFallback;
      _toast(fallback
          ? '已切换，但系统限制写入公共目录，已使用应用专属目录'
          : '下载目录已切换为「${selected.label}」');
    } catch (_) {
      if (mounted) _toast('切换下载目录失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _refreshUsage() async {
    await _downloads.refreshUsage();
    if (!mounted) return;
    _toast('已重新统计：${fxBytes(_downloads.usedBytes)}');
  }

  Future<void> _pickConcurrency() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
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
              '同时下载连接数',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: Fx.ink,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '只影响单集内部的并发；多集之间仍按队列顺序下载，'
              '总连接数不会超过 8。',
              style: TextStyle(fontSize: 11.5, height: 1.5, color: Fx.sub),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var n = AppSettings.minDownloadConcurrency;
                    n <= AppSettings.maxDownloadConcurrency;
                    n++)
                  ChoiceChip(
                    label: Text('$n 路'),
                    selected: n == _settings.downloadConcurrency,
                    selectedColor: Fx.accent,
                    labelStyle: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: n == _settings.downloadConcurrency
                          ? Colors.white
                          : Fx.ink,
                    ),
                    onSelected: (_) => Navigator.of(ctx).pop(n),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (selected == _settings.downloadConcurrency) return;
    await _settings.setDownloadConcurrency(selected);
    if (mounted) _toast('已设置为 $selected 路并发下载');
  }

  Future<void> _clearAll() async {
    final before = _downloads.usedBytes;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: const Text(
          '清除全部缓存？',
          style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700),
        ),
        content: Text(
          '将删除全部离线视频、未完成的分片和图片缓存，约 ${fxBytes(before)}。'
          '不会影响收藏、观看历史与账号。',
          style: const TextStyle(fontSize: 12.5, height: 1.5, color: Fx.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Fx.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              '全部清除',
              style: TextStyle(color: Color(0xFFE45C5C)),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _downloads.clearAll();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    await _downloads.refreshUsage();
    if (!mounted) return;
    _toast(before > 0 ? '已清除全部缓存，释放 ${fxBytes(before)}' : '缓存已清空');
  }

  @override
  Widget build(BuildContext context) {
    return FxPageScaffold(
      title: '下载与缓存',
      child: _loading
          ? const FxLoadingView(label: '正在统计缓存空间…')
          : ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(18, 6, 18, 32),
              children: [
                const _SectionTitle('下载目录'),
                GlassCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                  radius: 20,
                  child: Column(
                    children: [
                      _row(
                        icon: Icons.folder_outlined,
                        color: Fx.accent,
                        title: '下载位置',
                        subtitle: _downloads.storageFallback
                            ? '公共目录不可写，已使用应用专属目录'
                            : _downloads.displayRootPath,
                        trailing: _switching
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Fx.accent,
                                ),
                              )
                            : Text(
                                _downloads.locationLabel,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Fx.sub,
                                ),
                              ),
                        onTap: _pickLocation,
                      ),
                      _divider(),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(
                              Icons.info_outline_rounded,
                              size: 13,
                              color: Color(0xFFA6B1C2),
                            ),
                            const SizedBox(width: 5),
                            Expanded(
                              child: SelectableText(
                                _downloads.rootPath,
                                style: const TextStyle(
                                  fontSize: 9.5,
                                  height: 1.5,
                                  color: Color(0xFFA6B1C2),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const _SectionTitle('空间与网络'),
                GlassCard(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                  radius: 20,
                  child: Column(
                    children: [
                      _row(
                        icon: Icons.pie_chart_outline_rounded,
                        color: const Color(0xFF2FA985),
                        title: '已用空间',
                        subtitle: '真实统计全部下载目录（含未完成分片）',
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              fxBytes(_downloads.usedBytes),
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: Fx.ink,
                              ),
                            ),
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.refresh_rounded,
                              size: 14,
                              color: Color(0xFFA6B1C2),
                            ),
                          ],
                        ),
                        onTap: _refreshUsage,
                      ),
                      _divider(),
                      _row(
                        icon: Icons.delete_sweep_outlined,
                        color: const Color(0xFFE45C5C),
                        title: '清除全部缓存',
                        subtitle: '删除离线视频、未完成分片和图片缓存',
                        trailing: const Icon(
                          Icons.chevron_right_rounded,
                          size: 18,
                          color: Color(0xFFC3CDDA),
                        ),
                        onTap: _clearAll,
                      ),
                      _divider(),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: const Color(0xFFE08A3C).withValues(alpha: .11),
                                borderRadius: BorderRadius.circular(11),
                              ),
                              child: const Icon(
                                Icons.wifi_rounded,
                                size: 18,
                                color: Color(0xFFE08A3C),
                              ),
                            ),
                            const SizedBox(width: 12),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '仅 Wi-Fi 下载',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: Fx.ink,
                                    ),
                                  ),
                                  SizedBox(height: 2),
                                  Text(
                                    '开启后，移动网络下开始下载会被阻止',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: Fx.sub,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Switch.adaptive(
                              value: _settings.wifiOnlyDownload,
                              activeThumbColor: Fx.accent,
                              onChanged: (value) async {
                                await _settings.setWifiOnlyDownload(value);
                                if (!mounted) return;
                                _toast(
                                    value ? '已开启仅 Wi-Fi 下载' : '已关闭仅 Wi-Fi 下载');
                              },
                            ),
                          ],
                        ),
                      ),
                      _divider(),
                      _row(
                        icon: Icons.speed_rounded,
                        color: Fx.accent,
                        title: '同时下载连接数',
                        subtitle: '默认 6 路，可调 2–8；多集按顺序下载',
                        trailing: Text(
                          '${_settings.downloadConcurrency} 路',
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: Fx.ink,
                          ),
                        ),
                        onTap: _pickConcurrency,
                      ),
                      _divider(),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 10, 4, 12),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.network_check_rounded,
                              size: 14,
                              color: Fx.sub,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '当前网络：${_network.label}',
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: Fx.sub,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              _settings.wifiOnlyDownload
                                  ? '移动网络下不下载'
                                  : '不限制网络类型',
                              style: const TextStyle(
                                fontSize: 10,
                                color: Color(0xFFA6B1C2),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    '切换下载目录不会移动已下载的文件；旧文件仍可在「离线缓存」中播放，'
                    '也可以在「清除全部缓存」里统一清理。',
                    style: TextStyle(
                      fontSize: 10,
                      height: 1.6,
                      color: Color(0xFFA6B1C2),
                    ),
                  ),
                ),
              ],
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

class _LocationSheet extends StatelessWidget {
  const _LocationSheet({required this.current});

  final DownloadLocation current;

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
              '选择下载目录',
              style: TextStyle(
                fontSize: 16.5,
                fontWeight: FontWeight.w700,
                color: Fx.ink,
              ),
            ),
            const SizedBox(height: 12),
            for (final location in DownloadLocation.values) ...[
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.pop(context, location),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 13,
                  ),
                  decoration: BoxDecoration(
                    color: current == location
                        ? Fx.accent.withValues(alpha: .07)
                        : Colors.white.withValues(alpha: .72),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: current == location
                          ? Fx.accent.withValues(alpha: .45)
                          : Colors.white,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        location == DownloadLocation.phone
                            ? Icons.smartphone_rounded
                            : Icons.lock_outline_rounded,
                        size: 20,
                        color: current == location ? Fx.accent : Fx.sub,
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              location.label,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: current == location ? Fx.accent : Fx.ink,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              location.description,
                              style: const TextStyle(
                                fontSize: 10.5,
                                height: 1.45,
                                color: Fx.sub,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        current == location
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 19,
                        color: current == location
                            ? Fx.accent
                            : const Color(0xFFC3CDDA),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 4),
            const Text(
              '「手机存储」会优先写入 手机存储/Download/幻想影视；Android 10 及以上若系统不允许写入公共目录，会自动改为应用专属外部目录。',
              style: TextStyle(
                fontSize: 10,
                height: 1.6,
                color: Color(0xFFA6B1C2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

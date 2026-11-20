/// 设置 → 片源管理（JAR_RESTORE 2026-11-21）。
///
/// 只做一件事：**逐个启停用户挑中的那几个 jar 源**，外加看 / 装 `spider.jar`。
///
/// 故意不恢复的东西（用户明确说过不要）：
///   · 「+ 添加接口」用户自加源；
///   · 「导入 TVBox 配置」（含加密配置 / depot 地址）；
///   · 启动自动安装 spider.jar。
///
/// 页面上只有白名单里的源（[kEnabledJarSources]），别的肥猫源一条都不显示 ——
/// 显示一堆点不动的源只会让用户以为功能坏了。
library;

import 'package:flutter/material.dart';

import '../services/jar_sources.dart';
import '../services/source_hub.dart';
import '../theme.dart';
import '../widgets/jar_plugin_card.dart';

class SourceSettingsPage extends StatefulWidget {
  const SourceSettingsPage({super.key});

  @override
  State<SourceSettingsPage> createState() => _SourceSettingsPageState();
}

class _SourceSettingsPageState extends State<SourceSettingsPage> {
  final SourceHub _hub = SourceHub.instance;

  @override
  void initState() {
    super.initState();
    _hub.addListener(_onChanged);
    // 只查状态，不装 —— 装 jar 必须是用户在这一页点「安装 / 更新」。
    _hub.ensureReady().then((_) => _hub.refreshJarStatus());
  }

  @override
  void dispose() {
    _hub.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _toggle(String label, bool value) async {
    await _hub.setJarSourceEnabled(label, value);
  }

  /// 这个 jar 源在片源表里的类名（`csp_Gulu`），给用户看一眼。
  String _apiOf(String label) {
    for (final s in _hub.cloudSources) {
      if (SourceHub.jarLabelOf(s) == label) return s.api;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final labels = kJarLabels;
    final enabledCount =
        labels.where((l) => _hub.jarSourceEnabled(l)).length;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FB),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF5F7FB),
        elevation: 0,
        title: const Text(
          '片源管理',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          // jar 插件状态 + 安装 / 更新（唯一的手动安装入口）。
          const JarPluginCard(),
          const SizedBox(height: 18),
          const _SectionTitle('jar 片源'),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            radius: 18,
            child: Column(
              children: [
                for (final label in labels)
                  _JarSourceRow(
                    label: label,
                    api: _apiOf(label),
                    enabled: _hub.jarSourceEnabled(label),
                    installed: _hub.jarReady,
                    onChanged: (v) => _toggle(label, v),
                  ),
                if (labels.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(14),
                    child: Text(
                      '没有配置任何 jar 源（kEnabledJarSources 为空）',
                      style: TextStyle(fontSize: 12, color: Fx.sub),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '· 只影响搜索和播放解析：首页 / 分类 / 排行榜永远只用幻想自己的片源。\n'
            '· 默认只开用户挑中的 $enabledCount/${labels.length} 个；关掉之后搜索不再向它发请求。\n'
            '· 播放时现场解析（jar 的 playerContent），库里不存播放地址。',
            style: TextStyle(
              fontSize: 11,
              height: 1.6,
              color: Fx.sub.withValues(alpha: .95),
            ),
          ),
          if (_hub.jarMissing) ...[
            const SizedBox(height: 10),
            const _SectionTitle('提示'),
            GlassCard(
              padding: const EdgeInsets.all(14),
              radius: 18,
              child: Text(
                _hub.jarNotice,
                style: const TextStyle(fontSize: 12, color: Fx.sub),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 一行：某个 jar 源 + 开关。
class _JarSourceRow extends StatelessWidget {
  const _JarSourceRow({
    required this.label,
    required this.api,
    required this.enabled,
    required this.installed,
    required this.onChanged,
  });

  final String label;
  final String api;
  final bool enabled;
  final bool installed;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: Fx.ink,
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (!installed)
                      Text(
                        '未装 jar',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                          color: Fx.accent.withValues(alpha: .9),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  api.isEmpty ? '不在片源表里' : api,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: Fx.sub.withValues(alpha: .9),
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: enabled,
            activeTrackColor: Fx.accent,
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
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: Fx.sub.withValues(alpha: .95),
        ),
      ),
    );
  }
}

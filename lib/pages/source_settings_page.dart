/// 设置 → 片源管理（JAR_RESTORE 2026-11-21 / JAR_BOOT 2026-11-21）。
///
/// 两件事：**逐个启停用户挑中的那几个 jar 源**、**看每个源的状态并装 / 重装
/// `spider.jar`**。状态三档与用户口径一一对应：`可用` / `jar 未安装` / `已停用`
/// （见 [fxJarSourceStateLabel]）。
///
/// 自动安装由启动流程（`Boot.run` → `JarPluginManager.bootSilently`）负责；
/// 这一页的「安装 / 更新」是**手动重装**入口，`force: true`，不受自动开关限制。
///
/// 故意不恢复的东西（用户明确说过不要）：
///   · 「+ 添加接口」用户自加源；
///   · 「导入 TVBox 配置」（含加密配置 / depot 地址）。
///
/// 页面上只有白名单里的源（[kEnabledJarSources]），别的肥猫源一条都不显示 ——
/// 显示一堆点不动的源只会让用户以为功能坏了。
library;

import 'package:flutter/material.dart';

import '../services/jar_plugin.dart';
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

  /// 手动「安装 / 更新」spider.jar（用户主动动作，走 force 分支不受自动开关限制）。
  Future<void> _installJar() async {
    try {
      await JarPluginManager.instance.ensureReady(force: true);
    } catch (_) {
      // 失败原因已经写在 JarPluginManager.error 里，卡片上会标红显示。
    }
    if (!mounted) return;
    await _hub.refreshJarStatus();
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
                    state: _hub.jarSourceState(label),
                    onChanged: (v) => _toggle(label, v),
                    onInstall: () => _installJar(),
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

/// 一行：某个 jar 源 + 状态 + 开关。
///
/// 状态三档（用户口径）：`可用` / `jar 未安装` / `已停用`；`jar 未安装` 时
/// 这一行右侧直接给「安装 / 更新」，不用再往上找卡片。
class _JarSourceRow extends StatelessWidget {
  const _JarSourceRow({
    required this.label,
    required this.api,
    required this.enabled,
    required this.state,
    required this.onChanged,
    required this.onInstall,
  });

  final String label;
  final String api;
  final bool enabled;
  final FxJarSourceState state;
  final ValueChanged<bool> onChanged;
  final VoidCallback onInstall;

  /// 状态色：可用绿、缺 jar 用强调色（要用户处理）、停用灰。
  Color get _stateColor => switch (state) {
        FxJarSourceState.available => const Color(0xFF2FA985),
        FxJarSourceState.jarMissing => Fx.accent,
        FxJarSourceState.disabled => const Color(0xFFA6B1C2),
      };

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
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: _stateColor.withValues(alpha: .12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        fxJarSourceStateLabel(state),
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          color: _stateColor,
                        ),
                      ),
                    ),
                    if (state == FxJarSourceState.jarMissing)
                      TextButton(
                        onPressed: onInstall,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          minimumSize: const Size(0, 26),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text(
                          '安装 / 更新',
                          style: TextStyle(fontSize: 10.5, color: Fx.accent),
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

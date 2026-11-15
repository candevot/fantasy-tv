/// 「jar 插件」设置卡片（设置页 / 片源管理页共用）。
///
/// 为什么做成一个组件：这套东西在两个页面都要出现 ——
///   · 设置 → jar 插件（用户按「设置」两个字找的地方）
///   · 片源管理 → jar 插件（用户按「源不加载」找的地方）
/// 两边要求完全一致：显示状态、下载进度、失败原因、自检结果，以及
/// 四种安装方式（服务器地址 / 内置 / 本地文件 / 重试）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/jar_plugin.dart';
import '../theme.dart';

class JarPluginCard extends StatefulWidget {
  const JarPluginCard({super.key, this.onChanged, this.dense = false});

  /// 安装 / 卸载 / 自检状态变化时通知宿主（片源页用来刷新自己的状态）。
  final VoidCallback? onChanged;

  /// 片源管理页里空间更紧，少两行说明。
  final bool dense;

  @override
  State<JarPluginCard> createState() => _JarPluginCardState();
}

class _JarPluginCardState extends State<JarPluginCard> {
  final JarPluginManager _jar = JarPluginManager.instance;
  final AppSettings _settings = AppSettings.instance;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _jar.addListener(_onChanged);
    _settings.addListener(_onChanged);
    // 只查状态，不在这里自动下载：自动安装由启动流程 / 搜索页触发，
    // 打开设置页就偷偷下 1.5MB 不符合预期。
    unawaited(() async {
      await _settings.init();
      if (_jar.phase == JarPluginPhase.unknown) {
        await _jar.refresh();
      }
    }());
  }

  @override
  void dispose() {
    _jar.removeListener(_onChanged);
    _settings.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _notify() => widget.onChanged?.call();

  void _toast(String text) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(text),
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xEE1B2430),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ));
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
      _notify();
    }
  }

  Future<void> _install() async {
    var url = _settings.jarUrl.trim();
    if (url.isEmpty) {
      await _editSource();
      url = _settings.jarUrl.trim();
      if (url.isEmpty) return;
    }
    await _run(() async {
      final status = await _jar.installFromUrl(url, md5: _settings.jarMd5);
      _toast('jar 已安装（${status.shortMd5} · ${status.sizeLabel}）');
    });
  }

  Future<void> _installBundled() async {
    await _run(() async {
      final status = await _jar.installBundled();
      _toast('已启用内置 jar（${status.sizeLabel}）');
    });
  }


  /// 让用户输入本地 jar 的绝对路径（替代 file_picker）。
  Future<String?> _askPath() async {
    final ctrl = TextEditingController(
      text: '/sdcard/Download/spider.jar',
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从本地文件安装'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: 'jar 的完整路径',
            hintText: '/sdcard/Download/spider.jar',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('安装'),
          ),
        ],
      ),
    );
    final v = ok == true ? ctrl.text.trim() : null;
    ctrl.dispose();
    return v;
  }

  Future<void> _installFromFile() async {
    // 不依赖 file_picker（它在 CI 上解析不到，analyze 会报 undefined_getter）。
    // 改成让用户填 jar 的绝对路径，功能等价：本地文件安装依然可用。
    final path = await _askPath();
    if (path == null || path.trim().isEmpty || !mounted) return;
    await _run(() async {
      final status = await _jar.installFromPath(path!);
      _toast('jar 已安装（${status.shortMd5}）');
    });
  }

  Future<void> _selfTest() async {
    await _run(() async {
      final report = await _jar.selfTest();
      _toast(report.summary);
    });
  }

  Future<void> _uninstall() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('卸载 spider.jar？',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: const Text(
          '卸载后肥猫那批 jar 源会暂时没有内容（不会自动再用内置 jar），'
          '重新安装一次即可恢复。',
          style: TextStyle(fontSize: 13, height: 1.6, color: Fx.sub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Fx.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('卸载', style: TextStyle(color: Color(0xFFE05252))),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await _jar.uninstall();
      _toast('已卸载 spider.jar');
    });
  }

  Future<void> _editSource() async {
    final urlCtrl = TextEditingController(text: _settings.jarUrl);
    final md5Ctrl = TextEditingController(text: _settings.jarMd5);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('jar 下载地址',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: urlCtrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'spider.jar 地址',
                hintText: AppSettings.defaultJarUrl,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: md5Ctrl,
              decoration: const InputDecoration(
                labelText: 'md5（可选，填了就强校验）',
                hintText: '32 位小写 md5',
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '要的是 TVBox 的解析器 jar（里面有一堆 csp_ 开头的源），'
              '不是随便一个 zip。留空则不自动下载，只用内置/本地安装的。',
              style: TextStyle(fontSize: 10.5, height: 1.5, color: Fx.sub),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Fx.sub)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存', style: TextStyle(color: Fx.accent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final url = urlCtrl.text.trim();
    final md5 = md5Ctrl.text.trim();
    urlCtrl.dispose();
    md5Ctrl.dispose();
    await _settings.setJarUrl(url);
    await _settings.setJarMd5(md5);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final status = _jar.status;
    final installed = status.installed;
    final test = _jar.lastTest;
    final busy = _busy || _jar.busy;
    final fraction = _jar.fraction;
    final failed = _jar.phase == JarPluginPhase.failed;

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      radius: 18,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                installed
                    ? Icons.extension_rounded
                    : (failed
                        ? Icons.error_outline_rounded
                        : Icons.extension_off_rounded),
                size: 16,
                color: installed
                    ? Fx.accent
                    : (failed ? const Color(0xFFE05252) : const Color(0xFFA6B1C2)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _jar.statusLabel,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.35,
                    color: installed ? Fx.ink : Fx.sub,
                  ),
                ),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
          if (busy)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 4,
                  backgroundColor: const Color(0xFFE8EEF7),
                  valueColor: const AlwaysStoppedAnimation<Color>(Fx.accent),
                ),
              ),
            ),
          if (!installed && !_settings.jarAutoInstall)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '「首次使用自动安装」已关闭：只能手动装。',
                style: TextStyle(fontSize: 10.5, color: Color(0xFFA6B1C2)),
              ),
            ),
          if (failed && _jar.error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                _jar.error,
                style: const TextStyle(
                  fontSize: 10.5,
                  height: 1.5,
                  color: Color(0xFFE05252),
                ),
              ),
            ),
          if (test != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    test.ok
                        ? Icons.check_circle_outline_rounded
                        : Icons.report_problem_outlined,
                    size: 13,
                    color: test.ok ? const Color(0xFF2FA985) : const Color(0xFFE08A3C),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      test.summary,
                      style: TextStyle(
                        fontSize: 10.5,
                        height: 1.45,
                        color: test.ok
                            ? const Color(0xFF2FA985)
                            : const Color(0xFFE08A3C),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (!widget.dense)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                installed
                    ? 'TVBox 的 type 3 源（肥猫 / 饭太硬 / 二小这类 csp_ 源）都由它解析。'
                    : 'TVBox 的 type 3 源需要这个 jar 才能出内容。'
                        '默认地址 ${AppSettings.defaultJarUrl}，首次使用会自动后台安装。',
                style: const TextStyle(
                  fontSize: 10.5,
                  height: 1.5,
                  color: Color(0xFFA6B1C2),
                ),
              ),
            ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 2,
            children: [
              TextButton(
                onPressed: busy ? null : _install,
                child: Text(
                  installed ? '更新 jar' : '安装 jar',
                  style: const TextStyle(color: Fx.accent),
                ),
              ),
              TextButton(
                onPressed: busy ? null : _installBundled,
                child: const Text('用内置', style: TextStyle(color: Fx.sub)),
              ),
              TextButton(
                onPressed: busy ? null : _installFromFile,
                child: const Text('本地文件', style: TextStyle(color: Fx.sub)),
              ),
              TextButton(
                onPressed: busy || !installed ? null : _selfTest,
                child: const Text('自检', style: TextStyle(color: Fx.sub)),
              ),
              TextButton(
                onPressed: busy ? null : _editSource,
                child: const Text('下载地址', style: TextStyle(color: Fx.sub)),
              ),
              if (installed)
                TextButton(
                  onPressed: busy ? null : _uninstall,
                  child: const Text('卸载', style: TextStyle(color: Fx.sub)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

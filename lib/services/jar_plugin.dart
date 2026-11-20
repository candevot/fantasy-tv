/// jar 插件（TVBox type 3 / 肥猫那批 `csp_*` 源）的**自动安装与自检**。
///
/// 为什么需要这一层：`JarSpider` 只是通道的薄封装，而「首次使用时自动装」
/// 要处理的状态很多 —— 内置 jar 能不能用、下载到哪一步了、重试几次、
/// 装完要不要重查片源、自检过没过。这些都放在这里，页面只监听
/// [JarPluginManager] 的 `phase` / `progress` / `message`。
///
/// 状态机：
/// ```
/// unknown → checking ─┬─ 已安装 → ready ──(自检)── ready/failed
///                     ├─ 内置可用 → installing → ready
///                     └─ 需要下载 → downloading → installing → ready
///                                    └─ 失败 → failed（可重试）
/// ```
/// 「装完自动重查」：成功后调 [SourceHub.invalidateJarStatus]，把片源中心
/// 的 jar 状态清掉重查，搜索页监听本对象后会自动重跑上一次搜索。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_settings.dart';
import 'jar_spider.dart';
import 'source_hub.dart';

/// 当前处于哪一步。
enum JarPluginPhase {
  /// 还没查过。
  unknown,

  /// 正在查状态。
  checking,

  /// 正在用内置 jar（不联网）。
  installingBundled,

  /// 正在下载。
  downloading,

  /// 下载完了，正在校验 / 落盘。
  installing,

  /// 可用。
  ready,

  /// 失败（[JarPluginManager.error] 有原因，可重试）。
  failed,
}

class JarPluginManager extends ChangeNotifier {
  JarPluginManager._() {
    _progressSub = JarSpider.installProgress.listen(_onProgress);
  }

  static final JarPluginManager instance = JarPluginManager._();

  /// 自动下载最多尝试几次（首次 + 1 次重试）。
  static const int maxAutoAttempts = 2;

  /// 两次尝试之间的等待。
  static const Duration retryDelay = Duration(seconds: 2);

  StreamSubscription<JarInstallProgress>? _progressSub;

  JarPluginPhase _phase = JarPluginPhase.unknown;

  /// 下载进度 0..1；null = 不确定（服务器没给 Content-Length）。
  double? _fraction;

  String _message = '';
  String _error = '';
  JarStatus _status = const JarStatus.missing();
  JarSelfTest? _lastTest;
  bool _testing = false;
  int _attempt = 0;

  /// 单飞：同一时间只允许一个安装流程。
  Future<void>? _running;

  /// 自检过的 md5（内存级）：同一个 jar 不重复打网络。
  String _testedMd5 = '';

  JarPluginPhase get phase => _phase;
  double? get fraction => _fraction;
  String get message => _message;
  String get error => _error;
  JarStatus get status => _status;
  JarSelfTest? get lastTest => _lastTest;
  bool get testing => _testing;

  /// 自动安装当前是第几次尝试（1 = 首次，2 = 重试）。
  int get attempt => _attempt;
  bool get installed => _status.installed;
  bool get busy =>
      _phase == JarPluginPhase.checking ||
      _phase == JarPluginPhase.downloading ||
      _phase == JarPluginPhase.installing ||
      _phase == JarPluginPhase.installingBundled;

  /// 能直接显示的一句话状态（设置页 / 提示条）。
  String get statusLabel {
    if (!JarSpider.supported) return '当前平台不支持 jar 插件';
    switch (_phase) {
      case JarPluginPhase.ready:
        final bundled = _status.bundled ? '（内置）' : '';
        return 'spider.jar 已就绪$bundled · ${_status.sizeLabel} · '
            'md5 ${_status.shortMd5}';
      case JarPluginPhase.downloading:
        return _message.isEmpty ? '正在下载 jar…' : _message;
      case JarPluginPhase.installing:
      case JarPluginPhase.installingBundled:
        return _message.isEmpty ? '正在安装 jar…' : _message;
      case JarPluginPhase.checking:
        return '正在检查 jar 插件…';
      case JarPluginPhase.failed:
        return _error.isEmpty ? 'jar 插件不可用' : _error;
      case JarPluginPhase.unknown:
        return '还没检查 jar 插件';
    }
  }

  /// 启动时 / 首次搜索前调用：已装就直接用，没装就自动装。
  ///
  /// [auto] 为 false 时只查状态、不下载（用户手动点「安装」）。
  Future<void> ensureReady({bool auto = true, bool force = false}) {
    final running = _running;
    if (running != null) return running;
    final task = _ensureReady(auto: auto, force: force);
    _running = task;
    return task.whenComplete(() {
      _running = null;
    });
  }

  Future<void> _ensureReady({required bool auto, required bool force}) async {
    if (!JarSpider.supported) {
      _fail('当前平台不支持 jar 插件（只有 Android 客户端能用）');
      return;
    }
    _setPhase(JarPluginPhase.checking, message: '正在检查 jar 插件…');

    final fresh = await JarSpider.status(fresh: true);
    _status = fresh;
    if (fresh.installed) {
      _setPhase(JarPluginPhase.ready);
      _syncHub();
      // 第一次看到某个 md5 时后台自检一次（不挡 UI）。
      if (force || _testedMd5 != fresh.md5) {
        unawaited(selfTest());
      }
      return;
    }

    if (!auto) {
      _fail('还没安装 spider.jar');
      return;
    }

    final settings = AppSettings.instance;
    await settings.init();
    // JAR_RESTORE（2026-11-21）：用户不要「启动自动安装」，所以后台触发
    // （auto=true 但没人点）一律不装；设置页里点「安装 / 更新」时走
    // `force: true`，那是用户主动动作，不受这个开关限制。
    if (!settings.jarAutoInstall && !force) {
      _fail('还没安装 spider.jar（点「安装 / 更新」再装一次）');
      return;
    }

    // 1) 内置 jar 优先：不联网、秒装，离线也能用。
    try {
      _setPhase(JarPluginPhase.installingBundled, message: '正在释放内置 spider.jar…');
      final status = await JarSpider.installBundled();
      _status = status;
      _attempt = 0;
      _setPhase(JarPluginPhase.ready, message: '已启用内置 spider.jar');
      _syncHub();
      unawaited(selfTest());
      return;
    } catch (e) {
      final text = '$e';
      debugPrint('JarPlugin: bundled unavailable: $text');
      // 没有内置 jar 是正常情况（CI 没放 assets），继续走下载。
    }

    // 2) 从服务器下载（失败重试一次）。
    final url = settings.jarUrl.trim();
    if (url.isEmpty) {
      _fail('还没安装 spider.jar，且没有配置下载地址');
      return;
    }
    final md5 = settings.jarMd5.trim();
    Object? lastError;
    for (var i = 0; i < maxAutoAttempts; i++) {
      _attempt = i + 1;
      try {
        _setPhase(
          JarPluginPhase.downloading,
          message: i == 0 ? '正在下载 jar 插件…' : '重试下载（${i + 1}/$maxAutoAttempts）…',
        );
        final status = await JarSpider.install(url, md5: md5);
        _status = status;
        _setPhase(JarPluginPhase.ready);
        _syncHub();
        unawaited(selfTest());
        return;
      } catch (e) {
        lastError = e;
        debugPrint('JarPlugin: download failed: $e');
        if (i + 1 < maxAutoAttempts) {
          await Future<void>.delayed(retryDelay);
        }
      }
    }
    _fail(_humanize(lastError, url));
  }

  /// 手动：从地址安装。
  Future<JarStatus> installFromUrl(String url, {String md5 = ''}) async {
    _setPhase(JarPluginPhase.downloading, message: '正在下载 jar 插件…');
    try {
      final status = await JarSpider.install(url, md5: md5);
      _status = status;
      _attempt = 0;
      _setPhase(JarPluginPhase.ready);
      _syncHub();
      unawaited(selfTest());
      return status;
    } catch (e) {
      _fail(_humanize(e, url));
      rethrow;
    }
  }

  /// 手动：从本地文件安装（file_picker 拿到的路径）。
  Future<JarStatus> installFromPath(String path) async {
    _setPhase(JarPluginPhase.installing, message: '正在安装本地 jar…');
    try {
      final status = await JarSpider.installFromPath(path);
      _status = status;
      _attempt = 0;
      _setPhase(JarPluginPhase.ready);
      _syncHub();
      unawaited(selfTest());
      return status;
    } catch (e) {
      _fail('安装本地 jar 失败：$e');
      rethrow;
    }
  }

  /// 手动：用内置 jar。
  Future<JarStatus> installBundled() async {
    _setPhase(JarPluginPhase.installingBundled, message: '正在释放内置 spider.jar…');
    try {
      final status = await JarSpider.installBundled();
      _status = status;
      _attempt = 0;
      _setPhase(JarPluginPhase.ready, message: '已启用内置 spider.jar');
      _syncHub();
      unawaited(selfTest());
      return status;
    } catch (e) {
      _fail('没有可用的内置 jar，或释放失败：$e');
      rethrow;
    }
  }

  /// 自检（默认 `csp_Douban`）。失败不抛异常，结果在 [lastTest]。
  Future<JarSelfTest> selfTest({String api = JarSpider.defaultSelfTestApi}) async {
    if (!JarSpider.supported || !_status.installed) {
      final report = JarSelfTest(
        ok: false,
        api: api,
        stage: 'jar',
        code: 'no_jar',
        error: '还没有安装 jar 插件',
      );
      _lastTest = report;
      notifyListeners();
      return report;
    }
    _testing = true;
    notifyListeners();
    try {
      final report = await JarSpider.selfTest(api: api);
      _lastTest = report;
      if (report.ok) {
        _testedMd5 = _status.md5;
      } else {
        _testedMd5 = '';
      }
      if (_phase == JarPluginPhase.ready && !report.ok) {
        // jar 装上了但跑不起来：状态仍然保持 ready（能重试 / 换 jar），
        // 但把原因写进 error，设置页和搜索页都能看到。
        _error = report.summary;
      }
      return report;
    } finally {
      _testing = false;
      notifyListeners();
    }
  }

  /// 卸载（下次启动不会再自动解内置 jar）。
  Future<void> uninstall() async {
    await JarSpider.uninstall();
    _status = const JarStatus.missing();
    _lastTest = null;
    _testedMd5 = '';
    _setPhase(JarPluginPhase.unknown, message: '已卸载 spider.jar');
    _syncHub();
  }

  /// 只刷新状态，不安装。
  Future<void> refresh() async {
    final status = await JarSpider.status(fresh: true);
    _status = status;
    _setPhase(
      status.installed ? JarPluginPhase.ready : JarPluginPhase.failed,
      message: status.installed ? '' : '还没安装 spider.jar',
    );
    _syncHub();
  }

  void _onProgress(JarInstallProgress p) {
    switch (p.phase) {
      case JarInstallPhase.start:
        _fraction = null;
        _setPhase(JarPluginPhase.downloading, message: p.label);
      case JarInstallPhase.download:
        _fraction = p.fraction;
        _message = p.label;
        notifyListeners();
      case JarInstallPhase.verify:
        _fraction = null;
        _setPhase(JarPluginPhase.installing, message: p.label);
      case JarInstallPhase.install:
        _fraction = null;
        _setPhase(JarPluginPhase.installing, message: p.label);
      case JarInstallPhase.done:
        _fraction = 1;
        notifyListeners();
      case JarInstallPhase.error:
        _fraction = null;
        notifyListeners();
    }
  }

  void _setPhase(JarPluginPhase phase, {String? message}) {
    _phase = phase;
    if (message != null) _message = message;
    if (phase != JarPluginPhase.failed && phase != JarPluginPhase.ready) {
      _error = '';
    }
    notifyListeners();
  }

  void _fail(String message) {
    _phase = JarPluginPhase.failed;
    _error = message;
    _message = message;
    _fraction = null;
    notifyListeners();
  }

  /// 装好 / 卸载后让片源中心重查：搜索页据此把肥猫的 jar 源重新放回队列。
  void _syncHub() {
    final hub = SourceHub.instance;
    hub.invalidateJarStatus();
    unawaited(hub.ensureJarStatus());
  }

  /// 把底层异常翻译成用户能看懂的一句。
  String _humanize(Object? error, String url) {
    final text = '${error ?? ''}';
    if (text.contains('HTTP 404') || text.contains('http_404')) {
      return '下载地址 404（$url）—— 服务器上还没放 spider.jar';
    }
    if (text.contains('md5') || text.contains('md5_mismatch')) {
      return 'md5 校验不通过（$url，应为 ${AppSettings.defaultJarMd5}）：'
          '文件被换过或下到了错误页面，已自动重下仍失败';
    }
    if (text.contains('bad_jar') || text.contains('不是有效的 jar')) {
      return '下载到的不是有效的 jar（$url）';
    }
    if (text.contains('timeout') || text.contains('超时')) {
      return '下载超时（$url），检查网络后重试';
    }
    if (text.isEmpty) return 'jar 安装失败，请稍后重试';
    return 'jar 安装失败：$text';
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }
}

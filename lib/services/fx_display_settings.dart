import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 播放画面 · 画面比例 6 档：
/// 适应（contain，默认）/ 填充（cover）/ 拉伸（fill）/ 16:9 / 4:3 / 1:1。
///
/// 前三档直接换 BoxFit；后三档是固定比例档，由播放画面把内容框成目标比例、
/// 居中裁切（框内裁满），框外留黑边。
enum FxAspectMode {
  contain('contain', '适应'),
  cover('cover', '填充'),
  fill('fill', '拉伸'),
  ratio16x9('16:9', '16:9'),
  ratio4x3('4:3', '4:3'),
  ratio1x1('1:1', '1:1');

  const FxAspectMode(this.key, this.label);

  /// 持久化用的稳定 key（不随显示文案变化）。
  final String key;

  /// 面板上的短标签：适应 / 填充 / 拉伸 / 16:9 / 4:3 / 1:1。
  final String label;

  /// 未知 / 旧数据返回 null，由调用方回退到默认档。
  static FxAspectMode? fromKey(String? key) {
    for (final mode in values) {
      if (mode.key == key) return mode;
    }
    return null;
  }

  /// 固定比例档的目标宽高比；适应 / 填充 / 拉伸为 null。
  double? get frameRatio => switch (this) {
    FxAspectMode.ratio16x9 => 16 / 9,
    FxAspectMode.ratio4x3 => 4 / 3,
    FxAspectMode.ratio1x1 => 1,
    _ => null,
  };

  /// 是否固定比例档（16:9 / 4:3 / 1:1）。
  bool get isFixed => frameRatio != null;
}

/// 播放画面 · 镜像 3 档：默认 / 水平镜像 / 垂直镜像。
enum FxMirrorMode {
  none('none', '默认'),
  horizontal('horizontal', '水平镜像'),
  vertical('vertical', '垂直镜像');

  const FxMirrorMode(this.key, this.label);

  final String key;
  final String label;

  static FxMirrorMode? fromKey(String? key) {
    for (final mode in values) {
      if (mode.key == key) return mode;
    }
    return null;
  }

  /// 水平镜像：画面左右翻转。
  bool get flipX => this == FxMirrorMode.horizontal;

  /// 垂直镜像：画面上下翻转。
  bool get flipY => this == FxMirrorMode.vertical;
}

/// 画面比例 / 镜像模式的全局设置：
///
/// - 单例 + [ChangeNotifier]：竖屏、全屏、一起看全屏共用一份，改完立刻通知
///   所有播放画面重建，**不重载当前视频**；
/// - 持久化到 SharedPreferences，下次启动直接生效；
/// - 由第一个播放画面 [ensureLoaded] 幂等加载，读完自动通知一次。
class FxDisplaySettings extends ChangeNotifier {
  FxDisplaySettings._();

  static final FxDisplaySettings instance = FxDisplaySettings._();

  static const String _kAspect = 'player_aspect_mode';
  static const String _kMirror = 'player_mirror_mode';

  /// 旧「撑满全屏」开关（true = cover）：新档位首次写入前按它迁移一次。
  static const String _legacyFillKey = 'player_fill_screen';
  static const String _legacyFillMigratedKey =
      'player_fill_screen_contain_migrated_v1';

  /// 默认档：适应（contain）—— 等比完整显示，不裁字幕。
  FxAspectMode aspect = FxAspectMode.contain;

  /// 默认不镜像。
  FxMirrorMode mirror = FxMirrorMode.none;

  Future<void>? _loading;

  /// 幂等加载：多个播放画面同时挂上来也只读一次存储。
  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      aspect =
          FxAspectMode.fromKey(sp.getString(_kAspect)) ?? _legacyAspect(sp);
      mirror =
          FxMirrorMode.fromKey(sp.getString(_kMirror)) ?? FxMirrorMode.none;
    } catch (_) {
      // 读取失败：保持默认档，播放不受影响。
    }
    notifyListeners();
  }

  /// 旧「撑满全屏」迁移：开关打开 = 填充（cover），否则适应；
  /// 还没做过 contain 迁移的旧数据一律回适应（老版本默认 cover）。
  FxAspectMode _legacyAspect(SharedPreferences sp) {
    if (sp.getString(_kAspect) != null) return aspect;
    final migrated = sp.getBool(_legacyFillMigratedKey) ?? false;
    final fill = migrated ? (sp.getBool(_legacyFillKey) ?? false) : false;
    return fill ? FxAspectMode.cover : FxAspectMode.contain;
  }

  /// 切画面比例：立即通知所有播放画面，并落盘。
  Future<void> setAspect(FxAspectMode value) async {
    if (aspect != value) {
      aspect = value;
      notifyListeners();
    }
    await _save(_kAspect, value.key);
  }

  /// 切镜像模式：立即通知所有播放画面，并落盘。
  Future<void> setMirror(FxMirrorMode value) async {
    if (mirror != value) {
      mirror = value;
      notifyListeners();
    }
    await _save(_kMirror, value.key);
  }

  Future<void> _save(String key, String value) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(key, value);
    } catch (_) {
      // 本地存储失败不影响当前播放。
    }
  }
}

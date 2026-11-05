import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 画面适配档位：充满 / 适应 / 拉伸。
///
/// 默认 [cover]：等比铺满并裁掉多余画面，人物不会变形。
enum ScreenFit {
  cover('充满', '等比铺满，裁掉多余画面', BoxFit.cover),
  contain('适应', '完整画面，可能有黑边', BoxFit.contain),
  stretch('拉伸', '铺满屏幕，画面会变形', BoxFit.fill);

  const ScreenFit(this.label, this.description, this.boxFit);

  /// 设置面板展示用的中文名。
  final String label;

  /// 一句话说明，展示在设置面板里。
  final String description;

  /// 交给 media_kit `Video.fit` 的对应值。
  final BoxFit boxFit;

  /// 读取持久化值：未知 / 历史脏数据一律回落到默认的充满。
  static ScreenFit parse(String? raw) {
    for (final fit in values) {
      if (fit.name == raw) return fit;
    }
    return ScreenFit.cover;
  }
}

/// 全局画面模式状态。
///
/// 竖屏与全屏播放器都监听同一个 [notifier]，切换时只重建 `Video.fit`，
/// 不会重新创建 controller 或重新 open 视频；进入全屏前调用 [ensureLoaded]，
/// 保证进出全屏使用同一个持久化档位。
class ScreenFitStore {
  ScreenFitStore._();

  /// SharedPreferences 存储键。
  static const String storageKey = 'fx_screen_fit';

  /// 当前画面模式，默认充满。
  static final ValueNotifier<ScreenFit> notifier =
      ValueNotifier<ScreenFit>(ScreenFit.cover);

  static ScreenFit get value => notifier.value;

  static bool _loaded = false;
  static int _revision = 0;

  /// 从 SharedPreferences 读取一次；并发调用共享同一个加载结果。
  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    final revision = _revision;
    try {
      final sp = await SharedPreferences.getInstance();
      final saved = ScreenFit.parse(sp.getString(storageKey));
      // 加载期间用户已经手动切换：以用户选择为准，不要被旧值覆盖。
      if (revision == _revision) {
        notifier.value = saved;
        _loaded = true;
      }
    } catch (_) {
      // 读取失败不影响播放，保持默认的充满。
      if (revision == _revision) _loaded = true;
    }
  }

  /// 切换画面模式：先更新内存让画面立即生效，再异步持久化。
  static Future<void> set(ScreenFit fit) async {
    _revision++;
    _loaded = true;
    notifier.value = fit;
    // 串行写盘：连续快速切换时按队列写入最新档位，避免旧值覆盖新值。
    _writes = _writes.then((_) async {
      try {
        final sp = await SharedPreferences.getInstance();
        await sp.setString(storageKey, notifier.value.name);
      } catch (_) {
        // 写盘失败时本次会话仍然生效，不打断播放。
      }
    });
    await _writes;
  }

  /// 持久化写队列。
  static Future<void> _writes = Future<void>.value();
}

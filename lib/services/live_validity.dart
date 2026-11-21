import 'package:flutter/foundation.dart';

/// 本次会话内「播不了」的频道登记处（LIVE_INVALID 2026-11-21）。
///
/// 用户口径：「有频道点进去看不了」——直播页看起来 512 个台都在，
/// 点进去才发现全是死链。服务端已经把连不上的台清掉了（live_check.php），
/// 但公开直播源的失效是**随时**发生的：刚测活五分钟后就挂掉很正常。
///
/// 所以 App 侧再兜一层：播放页确认拿不到流时把该台记下来，
/// 直播页 / 首页直播区立刻不再显示它。只记在内存，**不落盘**——
/// 换一次会话（重启 App）重新拉一次清单，服务端那时候也已经复测过了。
class LiveValidity {
  LiveValidity._();

  static final Set<String> _broken = <String>{};

  /// 失效计数：页面监听它，标记后自动重排列表。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static bool isBroken(String id) => id.trim().isNotEmpty && _broken.contains(id.trim());

  static int get brokenCount => _broken.length;

  /// 标记一个台失效。幂等：同一个台重复标记不会触发多余重建。
  static void markBroken(String id) {
    final key = id.trim();
    if (key.isEmpty) return;
    if (!_broken.add(key)) return;
    revision.value++;
  }

  /// 会话内恢复（调试 / 用户下拉强制刷新时用）。
  static void clear() {
    if (_broken.isEmpty) return;
    _broken.clear();
    revision.value++;
  }
}

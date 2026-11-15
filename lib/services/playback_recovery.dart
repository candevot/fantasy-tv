/// 重连期间的进度保护与落点判定。纯 Dart，便于独立回归验证。
///
/// FLOW_WATCH（2026-11-15，用户口径）：「该不该切下一条」只看**还有没有
/// 数据在动**，不看等了多久 ——
/// ```
/// 真失败（立即切）  401/403/404/410/500/502/503、解析错误、清单不是
///                   #EXTM3U、DNS / 连接被拒 / TLS、清单 0 分片、分片全 4xx
/// 真卡死（判失败）  连续 8 秒 bytes 和 buffered 都不动（起播阶段）
///                   首帧出来之后：连续 6 秒 buffered 不涨
/// 慢网（继续等）    只要还在动就等，但有数据也没首帧时最多 30 秒硬上限
/// ```
/// 三条门槛的**唯一出处**是 `playback_progress.dart`，这里只做引用，
/// 不许再出现第二份数字。
library;

import 'playback_progress.dart';

bool recoverySeekLanded({
  required bool live,
  required Duration target,
  required Duration actual,
}) =>
    live ||
    target <= Duration.zero ||
    (actual - target).abs() <= const Duration(seconds: 5);

Duration recoveryVisiblePosition({
  required bool holding,
  required Duration previous,
  required Duration incoming,
}) => holding ? previous : incoming;

/// 起播阶段「连续无进展」门槛 —— 引用 `playback_progress.dart` 的
/// [fxStartupNoProgressWindow]（8 秒），不在这里写数字。
///
/// 以前这一层是「起播 15 秒 / 首帧后 12 秒」的**固定总时长**门槛，慢网
/// （限速 200KB/s 起播 20 秒才出首帧）必然被误杀。现在 8 秒量的是
/// 「**一动不动**」：bytes / buffered 连续 8 秒都没变化才算卡死。
const Duration startupStallTimeout = fxStartupNoProgressWindow;

/// 首帧出来之后的卡顿门槛：连续 **6 秒** buffered 不涨就切下一条。
///
/// 同样只引用一处：[fxStallNoProgressWindow]。已经出过画面说明线路本身
/// 是好的，这时候卡住多半是某一片重试；6 秒足够吃掉 media3 默认一次退避
/// （0/1s/2s），又不至于让用户干等。
const Duration playbackStallTimeout = fxStallNoProgressWindow;

/// 按「首帧是否已渲染」选停摆门槛。
Duration stallTimeoutFor({required bool hasRenderedFirstFrame}) =>
    hasRenderedFirstFrame ? playbackStallTimeout : startupStallTimeout;
/// 坏地址账本：同一个播放地址累计失败到 [failThreshold] 次就判死，
/// 后续救援链直接跳过重试；解析类失败（列表拿不到 / 不是 m3u8）一次即判死。
///
/// 为什么需要它：救援链第①步（换签名）和第②步（同地址重开）都会把同一个
/// 死地址再打一遍，每轮 6~8 秒，三轮就是二十多秒 —— 账本让「已经证明不行
/// 的地址」只死一次，后面立刻往下走（换线路 / 交回页面）。
class BadAddressLedger {
  BadAddressLedger({this.failThreshold = 2});

  /// 判死门槛：同一地址失败这么多次后不再重试。
  final int failThreshold;

  /// 账本上限：一集一个新地址，正常追剧也用不到这么多条。
  static const int _maxEntries = 32;

  final Map<String, int> _counts = <String, int>{};

  /// 该地址已累计失败次数。
  int countOf(String url) => _counts[url.trim()] ?? 0;

  /// 是否已判死（救援链遇到它直接跳过）。
  bool isDead(String url) => countOf(url) >= failThreshold;

  /// 记一次失败，返回累计次数。
  ///
  /// [resolveFailure] = 解析类失败（列表拿不到 / 不是 m3u8）：这种地址
  /// 重试没有意义，直接记到门槛。
  int noteFailure(String url, {bool resolveFailure = false}) {
    final key = url.trim();
    if (key.isEmpty) return 0;
    final next = resolveFailure ? failThreshold : countOf(key) + 1;
    _counts[key] = next;
    while (_counts.length > _maxEntries) {
      _counts.remove(_counts.keys.first);
    }
    return next;
  }

  /// 成功播起来就销账：地址没坏，刚才只是运气不好。
  void clear(String url) => _counts.remove(url.trim());
}

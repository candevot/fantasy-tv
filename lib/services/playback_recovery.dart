/// 重连期间的进度保护与落点判定。纯 Dart，便于独立回归验证。
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

/// 起播阶段的卡住门槛（首帧还没渲染出来）。
///
/// ALIGN_FONGMI（2026-11-15）：门槛从 6 秒抬到 15 秒。
///
/// 原生层已经改成「和壳一致」的传输参数（连接 / 读超时都是 30s、错误交给
/// media3 默认的 3 次重试、不再按状态码一次判死）。6 秒的门槛比传输层
/// 短得多，正常但有波动的线路（解析 302 冷启动 3s + 清单 + 首片）会被它
/// 误判成死线路，然后走救援链换线路重开 —— 用户看到的就是「壳秒开、
/// 我们一直在转圈/换线」。
/// 15 秒仍然比「一个完整读超时」短一半：真死了的地址照样会被放弃，
/// 不会拖到 30 秒以上。
const Duration startupStallTimeout = Duration(seconds: 15);

/// 首帧已经渲染之后的停摆门槛（12 秒）。
///
/// 首帧之后播放器已经在出画面，卡顿多半是某一片在重试：media3 默认
/// 0 / 1s / 2s 三次退避最多约 3 秒，12 秒足够吃掉两轮，不会误杀。
const Duration playbackStallTimeout = Duration(seconds: 12);

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

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
/// STARTUP_FAST_FAIL（2026-11-14）：原生层已经把「死地址」的最长等待压到
/// 十几秒（401/403/404/410/416/500/503 立刻判死 + 连接 6s / 读 8s + 最多
/// 2 次重试），Dart 侧再等 30 秒只是白等 —— 这 30 秒里旧实例还在对废地址
/// 发请求抢带宽，用户看到的就是「一直转圈加载不出来」。
/// 起播只给 6 秒：正常起播 < 2 秒，超过 6 秒还没出帧就换一套动作。
const Duration startupStallTimeout = Duration(seconds: 6);

/// 首帧已经渲染之后的停摆门槛：回到原来的宽松值，避免把「大分片加载慢」
/// 误判成「线路不可用」。
const Duration playbackStallTimeout = Duration(seconds: 8);

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

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

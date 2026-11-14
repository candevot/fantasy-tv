import '../lib/services/play_orientation.dart';

/// 全屏播放方向自适应的回归测试（纯 Dart，无 Flutter 依赖）。
///
/// 覆盖三件事：
///   1. 分辨率 → 方向：1080×1920 竖屏片判竖屏、1920×1080 判横屏、
///      0×0 / 方形不判；
///   2. 防抖：0×0 先到、真实值后到、中间来回抖，最终只切一次；
///   3. 手动接管：force 之后自动判断冻结，不会把用户切的方向扳回去。
Future<void> main() async {
  var checks = 0;
  void check(bool ok, String name) {
    if (!ok) throw StateError('FAIL $name');
    checks++;
    print('PASS $name');
  }

  /* ---------------------------------------------------------- 1. 方向判断 */

  check(
    fxOrientationForSize(1080, 1920) == FxPlayOrientation.portrait,
    '1080x1920 短剧判竖屏',
  );
  check(
    fxOrientationForSize(720, 1280) == FxPlayOrientation.portrait,
    '720x1280 竖屏判竖屏',
  );
  check(
    fxOrientationForSize(1920, 1080) == FxPlayOrientation.landscape,
    '1920x1080 正片判横屏',
  );
  check(fxOrientationForSize(0, 0) == null, '0x0 不判方向');
  check(fxOrientationForSize(1080, 0) == null, '缺高度不判方向');
  check(fxOrientationForSize(null, 1920) == null, '缺宽度不判方向');
  check(fxOrientationForSize(1080, 1080) == null, '方形不判方向');

  check(
    fxResolvePlayOrientation(width: 1080, height: 1920).isPortrait,
    '竖屏片锁竖屏',
  );
  check(
    fxResolvePlayOrientation(width: 1920, height: 1080).isPortrait == false,
    '横屏片锁横屏',
  );
  check(
    fxResolvePlayOrientation(width: 0, height: 0) ==
        FxPlayOrientation.landscape,
    '拿不到尺寸时保持横屏（旧行为）',
  );

  /* ------------------------------------------------------------ 2. 防抖 */

  const short = Duration(milliseconds: 20);

  // 0×0 先到 → 真实竖屏值 → 只切一次到竖屏。
  final once = <FxPlayOrientation>[];
  final d1 = FxPlayOrientationDebouncer(onResolve: once.add, stable: short);
  d1.update(0, 0);
  d1.update(1080, 1920);
  await Future<void>.delayed(const Duration(milliseconds: 5));
  // 稳定期内同一个值再来：不能重置窗口（否则一直刷新就永远定不下来）。
  d1.update(1080, 1920);
  await Future<void>.delayed(const Duration(milliseconds: 40));
  check(
    once.length == 1 && once.single == FxPlayOrientation.portrait,
    '0x0 → 1080x1920：稳定后只切一次竖屏',
  );

  // 播放中每秒通知同样的值：不能反复回调。
  for (var i = 0; i < 5; i++) {
    d1.update(1080, 1920);
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  check(once.length == 1, '同分辨率反复通知不重复切换');
  d1.dispose();

  // 值来回抖（0×0 → 720x1280 → 0×0 → 1080x1920）：只有最后一次稳定下来。
  final flap = <FxPlayOrientation>[];
  final d2 = FxPlayOrientationDebouncer(onResolve: flap.add, stable: short);
  for (final (w, h) in [(0, 0), (720, 1280), (0, 0), (1080, 1920)]) {
    d2.update(w, h);
    await Future<void>.delayed(const Duration(milliseconds: 4));
  }
  await Future<void>.delayed(const Duration(milliseconds: 40));
  check(
    flap.length == 1 && flap.single == FxPlayOrientation.portrait,
    '分辨率抖动期间不切，稳定后只切一次',
  );

  // 切到横屏片（换集 / 换线路）：稳定后按新分辨率切一次。
  d2.update(1920, 1080);
  await Future<void>.delayed(const Duration(milliseconds: 40));
  check(
    flap.length == 2 && flap.last == FxPlayOrientation.landscape,
    '换成横屏片后切一次横屏',
  );
  d2.dispose();

  // settleNow：进全屏时立即定，不等窗口。
  final instant = <FxPlayOrientation>[];
  final d3 = FxPlayOrientationDebouncer(onResolve: instant.add, stable: short);
  d3.settleNow(1920, 1080);
  check(
    instant.length == 1 && instant.single == FxPlayOrientation.landscape,
    'settleNow 立即出结论',
  );
  d3.dispose();

  /* ------------------------------------------------------ 3. 手动接管 */

  final manual = <FxPlayOrientation>[];
  final d4 = FxPlayOrientationDebouncer(onResolve: manual.add, stable: short);
  d4.settleNow(1080, 1920); // 自动判成竖屏
  d4.force(FxPlayOrientation.landscape); // 用户手动转成横屏
  check(d4.frozen && d4.applied == FxPlayOrientation.landscape, '手动切换后冻结自动判断');
  d4.update(1080, 1920);
  await Future<void>.delayed(const Duration(milliseconds: 40));
  check(
    manual.length == 1 && d4.applied == FxPlayOrientation.landscape,
    '冻结后不再被自动逻辑扳回竖屏',
  );
  // 解除冻结：重新交给自动判断。
  d4.unfreeze();
  check(d4.frozen == false, '解除冻结');
  d4.update(1080, 1920);
  await Future<void>.delayed(const Duration(milliseconds: 40));
  check(
    d4.applied == FxPlayOrientation.portrait,
    '解除冻结后重新自动判成竖屏',
  );
  d4.dispose();

  print('play orientation: $checks checks passed');
}

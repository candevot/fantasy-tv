/// 把「播放参数类设置」推到原生内核（PARAMS_ALIGN 2026-11-15 · 阶段 2）。
///
/// 背景：壳把缓冲档位 / 音轨偏好 / 隧道开关都读自全局 Setting，在内核
/// **建播放器那一刻**取用（`ExoUtil.buildLoadControl` /
/// `ExoUtil.buildTrackSelector`）。我们这边设置项在 Dart（[AppSettings]），
/// 内核在原生，中间需要一条明确的推送链路 —— 就是这个类。
///
/// 三条纪律：
///   1. **去重**：设置没变就不发（AppSettings 一次启动会 notify 好几次，
///      不去重等于每次启动都往通道打一遍）；
///   2. **失败静默**：老原生包不认这些方法时返回 false，只是回到改造前的
///      写死行为，绝不该冒到播放链路上；
///   3. **不阻塞**：推送是 fire-and-forget（[install] 不 await），设置页
///      点一下不该等一次通道往返。
///
/// 与 DNS 那条（`DnsProfileInstaller`）同构：都是「配置 → 原生」的一次性
/// 投递，都带签名去重。区别是这个有多个独立字段，签名要一起算。
library;

import 'app_settings.dart';
import 'exo_player.dart';

/// 一份「播放参数画像」：从 [AppSettings] 拍下来的快照。
class PlaybackParams {
  const PlaybackParams({
    this.bufferLevel = AppSettings.defaultBufferLevel,
    this.preferAac = false,
    this.tunneling = false,
  });

  /// 缓冲档位 1..10（一档 = 50 秒），见 [AppSettings.bufferLevel]。
  final int bufferLevel;

  /// 首选 AAC 音轨（壳 `prefer_aac`，默认关）。
  final bool preferAac;

  /// 隧道播放（壳 `tunnel`，默认关）。
  final bool tunneling;

  /// 从当前设置拍一份。
  factory PlaybackParams.fromSettings(AppSettings s) => PlaybackParams(
        bufferLevel: s.bufferLevel,
        preferAac: s.preferAac,
        tunneling: s.tunneling,
      );

  /// 去重签名：三个字段串起来，任一变化才会真的发。
  String get signature => 'buf=$bufferLevel|aac=$preferAac|tun=$tunneling';

  /// 日志 / 诊断用的一行摘要。
  String summary() =>
      'params[buffer=$bufferLevel(${bufferLevel * AppSettings.bufferStepMs ~/ 1000}s) '
      'aac=$preferAac tun=$tunneling]';
}

/// 把 [PlaybackParams] 推到原生（去重 + 失败静默）。
class PlaybackParamsInstaller {
  PlaybackParamsInstaller._();

  /// 已经推成功的签名（诊断 / 单测用）。
  static String _pushed = '';

  /// 当前生效的画像（诊断 / 单测用）。
  static PlaybackParams _current = const PlaybackParams();

  static PlaybackParams get current => _current;
  static String get pushedSignature => _pushed;

  /// 拍一份当前设置并推送；内容没变就直接返回（幂等）。
  static Future<void> sync(AppSettings settings) async {
    _current = PlaybackParams.fromSettings(settings);
    await install(_current);
  }

  /// 推一份画像（幂等）。
  ///
  /// 返回 true = 已推成功或本来就一致；false = 通道不可用 / 老原生包。
  static Future<bool> install(PlaybackParams params) {
    _current = params;
    if (!ExoPlayerEngine.isSupported) return Future<bool>.value(false);
    final signature = params.signature;
    if (signature == _pushed) return Future<bool>.value(true);
    return _push(params, signature);
  }

  static Future<bool> _push(PlaybackParams params, String signature) async {
    // 两个方法分开推：缓冲档位是老内核就可能认的独立开关，音轨偏好是
    // 之后才加的 —— 分开推，一边不支持不会把另一边一起丢掉。
    final bufferOk = await ExoPlayerEngine.setBufferLevel(params.bufferLevel);
    final trackOk = await ExoPlayerEngine.setTrackPrefs(
      preferAac: params.preferAac,
      tunneling: params.tunneling,
    );
    // 通道没实现（老插件）也记成已推：避免每次改设置都试一遍打日志。
    _pushed = signature;
    return bufferOk || trackOk;
  }

  /// 单测 / 诊断用：清掉「已推」记录。
  static void resetForTest() {
    _current = const PlaybackParams();
    _pushed = '';
  }
}

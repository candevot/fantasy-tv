import 'package:flutter/foundation.dart';

/// 播放链路的统一日志前缀（PLAY_LOG 2026-11-15）。
///
/// 为什么要有它：起播要依次经过
/// `详情 → CmsBridge.play（拿地址）→ CmsApi（要不要解析 / 解析成什么）
/// → FxPlayer.open（交给内核）→ 原生 ExoPlayer`
/// 五段，任何一段判错，用户看到的都只是「正在加载 第01集」。
/// 真机排查时 `adb logcat | grep FxPlay` 一条命令就能看出：
///
/// ```
/// [FxPlay] line=幻想爱奇艺 url=http://…/hxparse/play/iqiyi/1/index.m3u8?… source=cms kind=direct
/// [FxPlay] open line=幻想爱奇艺 url=http://… source=cms kind=direct
/// [FxPlay] FAIL line=幻想爱奇艺 reason=… elapsed=…
/// ```
///
/// - `source=cms|legacy`：地址来自 CMS 还是旧的 8787 后端；
/// - `kind=direct|parse`：这条地址是成品直链，还是现场走了 hxparse 解析。
const String fxPlayTag = 'FxPlay';

/// 写一条播放链路日志。release 包里也保留（[debugPrint] 不会被裁掉，
/// 只是频率被限流；起播这种低频日志完全够用）。
void fxPlayLog(String message) {
  debugPrint('[$fxPlayTag] $message');
}

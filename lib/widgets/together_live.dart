/* ========================================================================== */
/*  一起看 · 直播房同步口径（纯 Dart，无 Flutter 依赖，方便单测）               */
/*                                                                            */
/*  LIVE_TOGETHER（2026-11-20 用户第三次澄清，口径以此为准）：                   */
/*                                                                            */
/*  「一方点了刷新之后，两边才会同时刷新，跟随电视直播的进度，我是说双方不会      */
/*    同步。正常看的话」                                                       */
/*                                                                            */
/*  拆成三条硬规则：                                                           */
/*   ① 频道同步：进房就是同一个频道；谁切台，双方一起切（`switchChannel`）；     */
/*   ② 正常观看不同步：播放过程中**绝不**广播 seek / 位置 / 暂停 / 播放 / 切集， */
/*      各自落后多少算多少 —— 电视直播本来就有延迟，谁都不许把别人拉位置；      */
/*   ③ 刷新同步：任何一方点「刷新」，双方同时刷新、都落到直播边缘前 3 秒         */
/*      （`liveRefresh`）—— 这是直播房唯一会广播的位置类动作。                  */
/*                                                                            */
/*  这个文件只放口径常量与纯计算：不碰播放器、不碰 UI、不碰通道。                */
/* ========================================================================== */
library;

import '../services/live_edge.dart';

/// 直播房允许广播的动作：**只有**「切台」和「刷新追边」这两个。
///
/// 换线路也走 [liveChannelAction]：线路是频道的一部分（同一个台的不同地址），
/// 换线路等价于「切到同一个台的新地址」，仍然只广播频道级信息，不带进度。
const Set<String> togetherLiveBroadcastActions = <String>{
  togetherLiveChannelAction,
  togetherLiveRefreshAction,
};

/// 广播动作名：切台 / 换线路（频道级）。
const String togetherLiveChannelAction = 'switchChannel';

/// 广播动作名：刷新追边（唯一会广播的位置类动作）。
const String togetherLiveRefreshAction = 'liveRefresh';

/// 直播房一律本地化的动作：进度 / 播放态 / 切集 / 倍速 / 换片。
///
/// 这些动作在直播房里**不会**产生任何房间广播；状态机里留一份显式清单，
/// 是为了让「不许广播」变成可断言的常量，而不是散落在 if 里的隐含约定。
const Set<String> togetherLiveLocalOnlyActions = <String>{
  'seek',
  'position',
  'play',
  'pause',
  'state',
  'rate',
  'episode',
  'next',
  'prev',
  'switchTitle',
  'switchSource',
  'switchLine', // 换线路已被折叠进 switchChannel（频道级），单发线名不广播。
};

/// 直播房是否允许广播这个动作。
bool togetherLiveMayBroadcast(String action) =>
    togetherLiveBroadcastActions.contains(action.trim());

/// 直播房是否必须把这个动作留在本地（绝不广播）。
bool togetherLiveIsLocalOnly(String action) =>
    togetherLiveLocalOnlyActions.contains(action.trim());

/// 直播房**没有**「一起暂停 / 一起继续」。
///
/// 全屏底栏（`FsBottomBar(live: true)`）、竖屏房间操作条都用它来决定
/// 要不要渲染播放 / 暂停按钮；单测直接断言这个常量，防止有人把按钮加回去。
const bool togetherLiveShowsTogetherPause = false;

/// 收到一条房间操作广播后，直播房要不要执行「刷新追边」。
///
/// 只有**别人**的 `liveRefresh` 才触发：自己点刷新时本地已经刷过了，
/// 服务端把同一条 op 回播给所有人（含发起者），不能让它再刷一次。
bool togetherLiveShouldRefreshOnOp({
  required String action,
  required bool mine,
  required bool isLive,
}) => isLive && !mine && action.trim() == togetherLiveRefreshAction;

/// 收到 room_state 后要不要跟着切台（频道同步）。
///
/// 频道是同步的（LIVE_TOGETHER ①），但「进房第一次对齐」由页面按
/// `firstJoin` 单独处理（不给提示），这里只管「频道 id 真的变了」。
bool togetherLiveShouldFollowChannel({
  required String incomingId,
  required String currentId,
}) {
  final next = incomingId.trim();
  if (next.isEmpty) return false;
  return next != currentId.trim();
}

/// 收到刷新广播后本地要落的位置：直播窗口末端前 3 秒。
///
/// 返回 null 表示窗口时长未知（交给播放器用 seekToEnd 兜底）或窗口太短，
/// 与 `FxPlayer.seekToLiveEdge` 的判定完全一致。
Duration? togetherLiveRefreshTarget(Duration duration) =>
    fxLiveEdgeTarget(duration, rewind: fxLiveRefreshRewind);

/// 收到别人的刷新广播后的轻提示：「小明 已同步刷新直播」。
String togetherLiveRefreshToast(String name) {
  final who = name.trim();
  return '${who.isEmpty ? '有人' : who} 已同步刷新直播';
}

/// 自己点刷新后的轻提示。
const String togetherLiveRefreshSelfToast = '已回到直播';

/// 切台后给跟随方的轻提示：「已跟着切到「CCTV-5」」。
String togetherLiveChannelToast(String channelName) {
  final name = channelName.trim();
  return name.isEmpty ? '已跟着切台' : '已跟着切到「$name」';
}

/// 操作流水里「谁切台」的文案尾段：「切到 CCTV-5」。
String togetherLiveChannelLabel(String channelName) {
  final name = channelName.trim();
  return name.isEmpty ? '换了直播台' : '切到 $name';
}

/// 刷新探针的理由串：本地刷新 / 跟着别人刷新。
const String togetherLiveRefreshReasonSelf = 'refresh';
const String togetherLiveRefreshReasonPeer = 'peer-refresh';

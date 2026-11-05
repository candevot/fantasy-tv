# 幻想影视 · 跨功能衔接终审（只读审查）

- 审查对象：`/root/workspace/fantasy_flutter`，commit `c98ccdd`（feat: live detail page & together(kind=live)）工作树
- 审查范围：**只审跨模块衔接**（播放↔详情、播放↔一起看、直播↔一起看/详情、本地代理、下载↔播放、账号、图片代理、生命周期），单模块内部的样式/布局问题不重复
- 方式：静态通读 + 交叉调用链核对。本机无 Flutter SDK（`which flutter` 为空），未做编译与真机复现，结论以代码路径为准
- 只读：未修改任何源码，仅新增本文件
- 行号以当前工作树（`git status` 干净）为准

## 结论摘要

| 级别 | 数量 | 是否阻塞发布 |
|---|---|---|
| P0 | 1 | 是 |
| P1 | 5 | 否，但 P1-1 建议与 P0 同批修 |
| P2 | 14（另 3 条同类低优先级补充） | 否，排期跟进 |

**总体结论：需修复（不可直接发布）。** 唯一 P0 是「离开直播详情页后播放器仍在出声」的资源/音频泄漏，属于用户可感知的功能缺陷（后台串音、耗电、二次进入双声），必须修完 P0 + P1-1（同模式漏释放）再发版。

---

## P0

### P0-1 直播详情页：切线路/刷新途中退出页面，会遗留一个「一直在播放」的播放器
- **文件**：`lib/pages/live_detail_page.dart:165-205`（关键点在 `177` 的 `await _release(old)`、`181` 的 `_player = player`、`184/186/188/196` 的四处 `return null`）
- **现象**：
  - `_open()` 先把 `_player` 置空（166-167），再 `await _release(old)`（177），然后才创建新播放器并**立即**赋值 `_player = player`（179-181），接着 `player.open(..., play: true)`（183）。
  - 如果在 `177` 的 await 期间用户按返回（或页面被 pop），`dispose()`（72-84）会 `_openSeq++` 并尝试释放 `_player`——但此刻 `_player` 还是 `null`，什么也没释放。随后 `_open()` 恢复执行：新建播放器 → 赋给已销毁 State 的 `_player` → `open(play: true)` **开始出声** → 到 `184` 因 `!mounted` 直接 `return null`，**没有 dispose**。
  - 这个实例再没有任何引用方，`dispose()` 也不会再跑，声音会一直播到进程结束。
  - 同样的漏释放也适用于 `seq != _openSeq`：快速连点两条线路（本页 `_switchLine`/`_reopenCurrent` 都没有并发保护，见 `272-276`、`215-219`）时，先发起的 `_open` 会在 181 覆盖后来者的 `_player`，后来者成功、先发起者泄漏，最坏情况两路直播同时出声。
- **触发**：点「刷新」或任意线路卡后立刻返回；或网络慢时连续点两条线路。弱网下窗口可达数百毫秒，很容易命中。
- **修法**：
  1. `await _release(old)` 之后**再校验一次** `if (!mounted || seq != _openSeq) return null;`，避免给已销毁/已过期的请求创建播放器；
  2. 把「创建 → open」整段包进统一的 `_dropPlayer(FxPlayer p)`：任何 `return null` 分支前都 `p.removeListener(_onPlayer); _player = (identical(_player, p) ? null : _player); await _release(p);`
  3. `_player = player` 只在 `open` 成功且 `seq == _openSeq` 之后再赋值（或赋值时带上 seq 判断），保证并发时后发者不会被先发者覆盖；
  4. `_switchLine` 增加 `_switching` 布尔（与详情页 `_playerSwitchingLine` 对齐），加载中禁用线路卡。

---

## P1

### P1-1 一起看直播房：换线时同一处漏释放，泄漏一个正在播放的 FxPlayer
- **文件**：`lib/pages/together_page.dart:1937-1958`（关键 `1945`）
- **现象**：`1940` 的过期分支有 `await _releasePlayer(controller)`，但 `1943-1944` 两个 await 之后的 `1945 if (seq != _videoSeq) return;` **直接 return，不释放** `controller`。此时播放器尚未挂到 `_controller`（1949 才挂），也不在 `previous` 里（`previous` 在 1919-1920 就被摘走），所以 `_disposeController()` / `dispose()` 都拿不到它 → 房间内换线 + 卡顿重连（`_liveJumpToEdge`）叠加时会遗留一个出声音的孤儿播放器。
- **修法**：`1945` 改成 `if (seq != _videoSeq) { await _releasePlayer(controller); return; }`；并把 `_loadLiveVideo` 的「过期即释放」抽成一个局部函数，所有 seq 分支统一调用。

### P1-2 收藏页删除后，详情页仍显示「已收藏」（`fav_*` 标记与收藏列表两套状态不同步）
- **文件**：`lib/pages/favorite_page.dart:124-128`（`_delete`）＋ `lib/pages/detail_page.dart:302-314`（`_loadFavState`）、`338-366`（`_toggleFav`）；直播同款写在 `lib/pages/live_detail_page.dart:298-327`
- **现象**：详情页收藏会同时写 `SharedPreferences['fav_<id>']` 和 `FxStore.favoriteKey` 列表；`_loadFavState` **先读 `fav_` 标记**，只有为 false 才去查列表。收藏页删除只改列表（124-126），`fav_<id>` 永远是 true → 再次进详情页显示「已收藏」，但收藏页/我的页计数里已经没有，点一次「已收藏」才变回未收藏（且此时只是把标记置 false 再删一次空列表）。直播收藏的 `fav_live_<id>` 同样不被清理。
- **修法**：`FavoritePage._delete` / `_confirmClear` 里同步 `sp.remove('fav_${r.id}')`（直播 `fav_live_${r.id}`）；或彻底去掉 `fav_` 这层缓存，只以 `favoriteKey` 列表为唯一事实源。

### P1-3 从一起看房间返回详情页：不跟随房间内切集/换剧/换线，自动重播旧集
- **文件**：`lib/pages/detail_page.dart:655-683`（`_together`）＋ `lib/pages/player_page.dart:671-674`（`resumeAfterTogether`）
- **现象**：`_together()` 只 await 路由返回，然后 `resumeAfterTogether()` → `_bootstrap(seekToSaved: true)`，用的还是进房前的 `_ep`/`_line`。房间内房主切到第 5 集、或换到另一条线路后回到详情页：
  - 详情页 `_ep` 仍是旧集，高亮也是旧线路 → 播放器**重播旧集**，用户以为"继续看"；
  - 房间退出时 `_saveRoomProgress()`（`together_page.dart:952-964`）写的是 `pos_<videoId>_<房间当前集>`，详情页读的是旧集的 key，进度对不上；
  - 换剧的情况更彻底：房间已经是另一部片，详情页仍完全是旧片。
- **修法**：`TogetherPage` 退出（`_confirmLeaveRoom` / `_onClosed`）时 `Navigator.pop(<结果对象>)` 带回 `(videoId, ep, line, position, playing)`；`DetailPage._together` 拿到结果后，同一部片就 `setState(_ep/_lineId)` 并 `_saveHistory()`，然后再 `resumeAfterTogether`（内部用 `epOverride`/`lineOverride`）；不同片则不恢复播放并提示"房间已切换到其他影片"。

### P1-4 直播详情 → 一起看：只 `pause()` 不释放，房间里同时存在两台解码器/两条直播流
- **文件**：`lib/pages/live_detail_page.dart:356-382`
- **现象**：`_together()` 只做 `await player.pause().catchError((_) {})` 就压栈开房间，`FxPlayer`/libmpv 实例、已建立的直播 HLS 连接全部保留；房间又新建一个播放器拉同一路流。违反「房间里只能有一个播放器」的约定（点播侧 `pauseAndReleaseForTogether` 做对了，`player_page.dart:645-668`）。而且 `pause()` 的失败被 `catchError` 吞掉（366 行），一旦 pause 真的失败就是**双声**。
- **修法**：进房前 `await _release(player)` 并把 `_player = null`（保留 `_lineId`），返回后 `_reopenCurrent()` 重新拉流回到直播边缘；同时把直播页与房间页的播放器所有权用 `_openingTogether` 之外的一个 `_releasedForTogether` 标记显式化。

### P1-5 token 过期后，一起看只会无限重连，不提示重新登录
- **文件**：`lib/widgets/together_client.dart:339-344`（WS 带 token）、`lib/pages/together_page.dart:604-611` 与 `316-331`（断线重连提示）、`lib/api.dart:110-122`（401 只转文案）、`lib/auth.dart:117`（只有 `/user/me` 的 401 才清 session）
- **现象**：WS 把 `Api.token` 拼进 query；token 过期时服务端多半直接关闭连接或回一个非约定 code，`_onDown`/`_onError` 只表现为「连接断开，正在自动重连…」「连不上一起看服务器，稍后再试」，然后按 3/6/12/24/30s 无限重试，**没有任何"登录已过期"的提示或跳登录**。HTTP 侧同理：`Api._httpException` 把 401 变成「登录已过期，请重新登录」，但除 `Auth.refresh()` 外没有任何地方清 session，用户留在页面里会一直看到同一句错误。
- **修法**：`TogetherClient` 收到握手失败/异常关闭且已重试 ≥2 次时回调一个新的 `onAuthFailed`；`TogetherPage` 据此 `Auth.instance.logout()` 并导航到登录页。`Api._send/_decode` 遇到 401 统一触发一个 `Api.onUnauthorized` 回调（`Auth` 注册），清 session + 全局提示，避免每个页面自己处理。

---

## P2

| # | 位置 | 现象 | 修法 |
|---|---|---|---|
| P2-1 | `lib/services/fx_player.dart:502-532` | 本地代理只在 `FxPlayer.dispose()` 里关，且顺序是 `await _player.dispose()` **之后** 才 `hlsProxy.dispose()`（522-531）。mpv 释放偶发卡住时，`HttpServer`、临时目录、90s 刷新定时器会一直留着；每集一个新播放器 → 每集一个新 server，卡一次就积一个。 | 把 `hlsProxy.dispose()` 放到 `_player.dispose()` 之前（或并行 `Future.wait`），并对 `_player.dispose()` 加 `timeout` 兜底。 |
| P2-2 | `lib/services/local_hls_proxy.dart:245-253`、`1465-1477` | `cancelPrefetch()` 只清预取队列，不动在途分片下载；`proxy()` 换集时 `_clearCaches()` 后，旧集的在途分片仍会 `_cachePut()` 写回同一张缓存表，最多占满 256MB，并继续吃带宽。 | `_cachePut`/`_loadSegment` 增加 generation 校验（当前已有 `_generation`），过期结果直接丢弃；`cancelPrefetch` 里同时 `_clearCaches()`。 |
| P2-3 | `lib/services/local_hls_proxy.dart:360-397` | `/playlist` 不校验 `u` 是否等于 `_activePlaylistUrl`，换集后旧集的本地 URL 仍能取到新列表；libmpv 的迟到请求会把旧集播放列表再拉一遍（表现为切集后仍有旧集请求）。 | `_servePlaylist` 里比较 `u` 与 `_activePlaylistUrl`，不一致直接 410/404，让播放器放弃旧请求。 |
| P2-4 | `lib/pages/together_page.dart:2164`、`1938`；`lib/pages/live_detail_page.dart:183` | 一起看房间、直播页调 `FxPlayer.open()` 都没传 `direct`，只有详情页/全屏走本地分片代理（`player_page.dart:839`、`fullscreen_page.dart:685`）。同一片源在不同入口体验不一致（房间更容易卡）。 | 两处补 `direct: play.direct && play.isHls`（直播没有 PlayInfo，可新增 `isHlsUrl` 判断或固定 `direct: true`）。 |
| P2-5 | `lib/pages/together_page.dart:952-964` | 房间退出只写 `fxSaveProgress`，不更新 `FxStore` 历史；从房间看完回「观看历史」，进度条和集数还是旧的。 | 与 `PlayerView._saveProgress` 对齐，追加 `FxStore.updateProgress(...)`。 |
| P2-6 | `lib/pages/player_page.dart:226-231`、`lib/pages/fullscreen_page.dart:417-421` | 10s 定时器在后台仍执行 `_maybePrewarmNext()` → 后台打 `/api/play` + 拉 m3u8，耗电/流量；`_saveProgress` 后台跑是预期行为。 | `_maybePrewarmNext` 首行加 `if (_backgrounded) return;`。 |
| P2-7 | `lib/widgets/together_client.dart:416-426` | `pauseHeartbeat()` / `resumeHeartbeat()` 从未被调用（死代码），切后台 WS 的 10s ping + 30s 时钟校准照常跑，`TogetherPage.didChangeAppLifecycleState`（261-290）也没接。 | 在 `together_page` 的 `paused/hidden` 调 `pauseHeartbeat()`、`resumed` 调 `resumeHeartbeat()`；或删掉死代码避免误读。 |
| P2-8 | `lib/services/download_service.dart:272-313` | 下载服务没有任何生命周期处理：切后台继续下（无前台服务，进程被系统杀掉后只能靠 `_reconcile` 恢复成「已暂停」）；播放中的 `_persistSoon` 定时器同样常驻。 | 加 `WidgetsBindingObserver`：后台且非「仅 Wi-Fi」时可选暂停，回前台 `_kick()`；至少在设置项里说明后台下载不保证。 |
| P2-9 | `lib/pages/downloads_page.dart:610-710`；`lib/services/download_service.dart:376` | 离线播放走 `video_player`（与主链路的 media_kit 分离）：不写播放进度、没有倍速/字幕/手势/后台策略；`isCached()` 没有任何调用方，**已缓存的集在线播放时仍走网络**。 | 离线页至少回写 `fxSaveProgress`；`PlayerView._bootstrapSource` 在 `DownloadService.isCached(videoId, ep)` 时优先 `open(file)`。 |
| P2-10 | `lib/pages/detail_page.dart:338-366` | 未登录点收藏直接成功（本地写入），没有登录引导；`catch (_) {}` 吞掉所有异常后仍 `fxToast('已加入收藏')`，写盘失败会给用户错误反馈。 | 未登录时提示「登录后可同步收藏」并提供跳转；失败分支 toast「收藏失败，请重试」并回滚 `_fav`。 |
| P2-11 | `lib/widgets/together_ui.dart:258-259` | 头像只认 `http(s)://` 绝对地址，服务端返回相对地址（`/api/avatar/...`）时永远显示首字母占位；`detail_widgets.dart:776-779` 的评论头像却能靠 `FxNetworkImage` 兜住相对地址。 | 改成 `togetherCoverUrl(avatar)`（`together_ui.dart:27-36`）后再交给 `FxNetworkImage`，或直接去掉前置判断，交给 `Api.imgProxy` 归一。 |
| P2-12 | `lib/pages/together_page.dart:1574-1601` | 房间内「换一部剧」把 `_videoLine` 硬编码成 `'l1'` 并原样广播；新片没有 `l1` 时房主和所有成员都要在 `_loadVideo` 的 `ordered` 里再回落一次（2131-2136），多一次 `/api/play` 失败往返，且广播的 lineId 与实际不符。 | 换剧时先取详情再决定 lineId（`_ensureDetail(card.id)` 后取 `lines.first.id`），拿不到再退回 `'l1'`。 |
| P2-13 | `lib/pages/together_page.dart:604-611`、`858-910` | 房间被服务端解散（`onClosed`）后 `_clearRoom()` 把页面切回「一起看入口页」，用户还停在 together 路由里，需要再按一次返回才回详情；期间详情页播放器已释放，是黑屏。 | `_onClosed` 在 `_stage == room` 时直接 `pop`（带"房间已解散"提示），入口页只在用户主动进入时出现。 |
| P2-14 | `lib/pages/player_page.dart:671-674` | `resumeAfterTogether()` 无条件 `_bootstrap(seekToSaved: true)`，`playOverride` 为 null 时取 `autoPlay && !_covered` = true → 房间是**暂停退出**的，回详情页也会自己播起来（与 `resumeAfterCover` 的语义不一致）。 | `pauseAndReleaseForTogether` 记录 `_playingBeforeTogether`，`resumeAfterTogether` 用它作 `playOverride`。 |

补充（同类但优先级更低，建议顺手改）：
- `lib/pages/fullscreen_page.dart:1160-1184` + `1983-1984`：`_firstFrame` 以 `videoParams` 的宽高为准，进全屏时若参数未上报但画面已在播，会先黑屏、10s 后才报「加载失败」。建议进全屏时把 `_firstFrame` 初值改为 `c.value.isInitialized`，宽高只用于画质胶囊。
- `lib/pages/detail_page.dart:358-361`：取消收藏的 `removeWhere` 只比 `id`、不比 `kind`，可能把同 id 的直播收藏一起删掉（`addFavorite` 是带 kind 的）。
- `lib/pages/live_detail_page.dart:87-96`：直播页没有 `_fullscreenActive` 标记，全屏页正复用同一个 `player` 时，若 `resumed` 且 `_error == null` 命中 `_reopenCurrent()`（215-219），会释放全屏页正在用的播放器。加一个 `_fullscreenActive` 早退即可。

---

## 八个审查重点的核对记录

1. **播放 ↔ 详情**：进房/进全屏/进相关推荐都有暂停或释放；返回时 `PlayerView.dispose()` 先同步取 `value` 再 `unawaited(_saveProgress())`，不会丢进度；线路自动回落通过 `onLineFallback` 回写 `_lineId`，高亮与实际一致（`player_page.dart:369/385` ↔ `detail_page.dart:434-440`）。本链路**未发现 P0/P1**；一起看返回后的恢复语义见 P2-14。切线路并发保护（`_switchingLine`/`_pendingEp`）齐备。
2. **播放 ↔ 一起看**：详情进房前 `pauseAndReleaseForTogether()` 真正 dispose（`player_page.dart:645-668`），房间退出 `pause→stop→dispose`（`together_page.dart:2301-2311`），不会双声；问题在**房间内切集/换线后回详情不同步**（P1-3）和**恢复必播**（P2-14）。实例泄漏集中在直播房（P1-1）。
3. **直播 ↔ 一起看/详情**：返回/退出释放正常（`live_detail_page.dart:72-84`）；**切线路途中退出会泄漏**（P0-1）、**进房不释放**（P1-4）、**全屏缺互斥**（补充）。
4. **本地代理**：`HttpServer` 随 `FxPlayer.dispose()` 关闭、失败回退直连路径正确（`fx_player.dart:379-388`，`playbackUrl/headers` 只在代理成功时替换）；残留问题为关闭时机（P2-1）、在途分片（P2-2）、旧集 URL 可继续取列表（P2-3）。
5. **下载 ↔ 播放**：下载服务是单例、独立 `http.Client`，与播放器/线路切换完全解耦，切集/切线路/退出后任务继续，未见崩溃路径；不足是离线与在线没打通（P2-9）、后台无生命周期（P2-8）。
6. **账号**：收藏/历史**完全本地**（`api.dart` 无对应接口），token 过期不会让它们失败，也就没有提示可加——代价是换设备/换账号数据不迁移，且 `fav_*` 与列表两套状态（P1-2）。未登录点收藏无引导（P2-10）。一起看 token 失效只表现为无限重连（P1-5）。
7. **图片代理**：所有封面/头像最终都走 `FxCover`/`FxNetworkImage` → `Api.imgProxy`（相对地址 `abs()` 归一、本站直连），失败占位 `FxImageFallback` 覆盖首页/搜索/分类/排行榜/详情/收藏/历史/下载/一起看全部列表；`errorBuilder` + `frameBuilder` 统一。唯一缺口是一起看头像的前置判断（P2-11）。
8. **生命周期**：`PlayerView` / `FullPlayerPage` 的后台播放、音频焦点宽限（`fxAudioFocusLossGrace`）、看门狗停摆都做了；一起看后台不断 WS（设计如此）但心跳没暂停（P2-7）；直播页只有 `resumed` 分支、来电不暂停；下载服务完全没有观察者（P2-8）。

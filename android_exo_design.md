# ExoPlayer 内核桥接设计

## 目标
把 `FxPlayer`（现在基于 media_kit/libmpv）换成 ExoPlayer(Media3)，
解决 libmpv 的 HLS 兼容问题（ENDLIST 丢失、302 跳转、4K 缓冲）。

## 约束
- 必须保留 `FxPlayer` 现有对外 API（页面层不用改）
- 必须保留：救援链、看门狗、进度同步、一起看、离线播放
- 先只做 Android（iOS 保持 media_kit）

## 方案：MethodChannel 桥接（不引入第三方包）

不用 better_player / video_player（会带来自己的 widget 层和生命周期问题），
直接写一个轻量 MethodChannel 桥：

```
Flutter 侧                          Android 侧
FxPlayerExo (Dart)          ←→      ExoPlayerPlugin (Kotlin)
  ├─ open(url, headers)              ├─ ExoPlayer.Builder
  ├─ play/pause/seek/rate            ├─ MediaItem + DefaultHttpDataSource
  ├─ 位置/时长/缓冲 轮询              ├─ Player.Listener → EventChannel
  └─ 画面渲染                         └─ PlayerView / Surface
```

## 关键点

1. **画面渲染**：用 `PlatformView`（AndroidView）承载 `PlayerView`，
   Flutter 侧用 `Stack` 叠控制层。
2. **事件通道**：`EventChannel` 推送 playing/buffering/position/duration/error。
3. **HLS 配置**：`DefaultHlsPlaylistParser` 原生支持 ENDLIST，无需改写。
4. **302 跳转**：`DefaultHttpDataSource` 的 `allowCrossProtocolRedirects=true`。
5. **缓冲调优**：`LoadControl` 设 `bufferForPlaybackMs=1500`（对齐腾讯策略）。
6. **硬解**：`MediaCodecSelector.DEFAULT` 自动选硬解，4K HEVC 走硬件。

## 工作量
- Kotlin 插件：~300 行
- Dart 封装：~400 行
- FxPlayer 适配：改 open/play/pause/seek/dispose 内部实现，保留签名

## 分片缓存契约（2026-11-14）

「首页续播预取」和播放器必须写 / 读**同一份** SimpleCache 的**同一个 key**，
否则预取等于白下。契约只有一条：

```
cacheKey = stripQuery(url) + "||" + url
```

- 唯一实现：`android_src/kotlin/.../FxCacheKey.kt`（`FxCacheKeyFactory`）。
- 三处都 `.setCacheKeyFactory(FxCacheKeyFactory)`，谁都不许自己拼 key：
  1. `ExoPlayerPlugin.cacheDataSourceFactory`（播放器读 / 写）
  2. `SegmentPreloader.cacheDataSourceFactory`（播放页分片预取）
  3. `ExoPlayerPlugin.prefetchSegment`（首页续播预取，复用 1 的工厂）
- 为什么不能只按路径：服务端分片都是 `/api/seg?u=…&i=…&s=…&ln=…`，
  同一路径下靠 query 区分，去掉 query 会全部撞成一条。
- 为什么还留 `||url`：`u` 才是真正的片地址，整条 url 保证唯一。
- 代价：换 key 规则等于让旧缓存失效一次（首播多回源一遍），属一次性成本。

首页预取链路：`home_page` 的 `FxResumeBarHost`（Stack 最后一层）→
渲染完成后 `ResumePrefetch.warm(ResumeTarget)` → `/api/play` +
`HlsSegmentIndex` 定位续播那一片 → `ExoPlayerEngine.prefetchSegment`
→ 原生 `prefetchSegment` 走上面的工厂写盘。

## 媒体会话 / 系统媒体卡片契约（2026-11-15）

后台播放从「裸 Service + 手绘常驻通知（只有播放/暂停/关闭）」升级成
media3 的 **MediaSessionService + MediaSession**，和 B 站 / 影视壳一样进系统
媒体卡片：封面 + 片名 · 第N集 + 进度条 + 上一集/播放暂停/下一集，锁屏、
负一屏媒体中心、耳机线控、蓝牙、车机都能控制。

```
Dart                                  Android
player_page.setBackgroundMedia(...)   ExoPlayerPlugin（同一台 ExoPlayer）
  → FxPlayer._openMedia               ├─ MediaItem.Builder().setMediaMetadata(...)
    → engine.open(bgTitle/bgEp/…)     ├─ PlaybackService : MediaSessionService
    → engine.backgroundStart(...)     │    ├─ MediaSession.Builder(player)
                                      │    │    ├─ setSessionActivity(回 App)
                                      │    │    └─ DefaultMediaNotificationProvider
                                      │    └─ SessionPlayer(ForwardingPlayer)
                                      └─ 事件快照 bgStepSeq/bgStepDelta → Dart
```

必须遵守的几条（改了就会静默退化，APK 能装能播、只是通知变回普通样式）：

1. **不自己画通知**：用 `DefaultMediaNotificationProvider`。系统媒体卡片是
   SystemUI 按版本渲染的，自绘布局进不了锁屏 / 媒体中心。
2. **不新建播放器**：session 绑 `ExoPlayerPlugin.currentPlayer()` 那台实例，
   `MediaSession.Builder(context, player)`；播放器实例被重建（解码失败重试）
   时先 `PlaybackService.releaseSessionNow()`，重建后 `syncPlayer()` 换绑。
3. **元数据挂在 MediaItem 上**：`title` = 片名、`artist` + `albumTitle` =
   「第N集 · 线路名」、`artworkUri` = 封面。**必须在 prepare 之前**挂上
   （prepare 之后再改只能换 source = 重新起播），所以片名/集号/线路名/封面
   跟着 `open` 一起传，而不是等播起来再告诉原生。
4. **封面**：`PlaybackService.artworkUriFor()` 优先 `cacheDir/fx_art/<sha1>`
   的本地文件（Dart 在 `_bootstrap` 里提前 `warmArtwork`），没缓存到才退化成
   http 地址；下载并发 1，绝不和起播抢带宽。
5. **上一集/下一集**：ExoPlayer 里只有一集（一个 MediaItem），
   `SEEK_TO_NEXT_MEDIA_ITEM` 天然不可用 → 用 `SessionPlayer`（ForwardingPlayer）
   按 Dart 给的 `hasPrev/hasNext` 声明命令，并把调用**拦下来转给 Dart**
   （`bgStepSeq` +1，页面走原来的 `_switchEpisode`）。拦截后不转给播放器：
   单集列表上 `seekToNext` 会 seek 到片头或什么都不做。
6. **释放顺序**：`player.release()` 之前必须 `PlaybackService.releaseSessionNow()`
   （session 强引用 player，反了就抛 `IllegalStateException` 崩主线程）；
   播放结束 / 关闭 / 退出播放页 / 服务销毁都走这条，不留僵尸通知。
7. **前台服务类型**：manifest `<service android:name=".PlaybackService"
   android:foregroundServiceType="mediaPlayback" android:exported="false">` +
   `<intent-filter><action android:name="androidx.media3.session.MediaSessionService"/>`。
   由 `tools/patch_manifest.py` 写并校验；通知渠道名
   `R.string.fx_bg_channel` 也在那里生成。
8. **验证口径**：`adb shell dumpsys media_session | grep fantasy_tv` 能看到
   session 与其 `PlaybackState`（position/duration/actions）；通知是 `MediaStyle`。

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

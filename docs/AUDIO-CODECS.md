# 音轨解码与选轨（FFMPEG_AUDIO / AUDIO_BITRATE，2026-11-19）

这一页解决两件用户能**直接感知**的事：

1. **带 AC3 / EAC3 / DTS / TrueHD 的源要能出声** —— 系统解码器普遍不支持
   DTS / TrueHD，部分机器连 EAC3 都不支持，以前这些源是「能起播、没有声音」。
2. **多音轨时选码率最高的那条** —— 以前按编码类型偏好（`preferAac`），而
   AAC 在同一条片子里通常就是码率最低的那条（128~192k，E-AC3/AC3/DTS
   则 384~1536k），等于主动降级。

## 1. 依赖：为什么 media3 从 1.4.1 升到 1.7.1

FFmpeg 音轨解码器用**预编译**扩展，不在 CI 里编 FFmpeg（不装 NDK 工具链、
不加 30 分钟构建时间）：

```
io.github.anilbeesetti:nextlib-media3ext:1.7.1-0.9.0
```

* 版本号格式 `<media3 版本>-<nextlib 版本>`，**第一段必须等于 `MEDIA3_VERSION`**，
  `tools/patch_exoplayer.py` 里有断言，CI 也会再核一次。
* 它按 media3 版本一对一发版，**最早的构建就是 `1.7.1-0.9.0`，没有 1.4.1
  对应版本**。把 1.7.1 编出来的 AAR 塞进 1.4.1 的运行时是二进制不兼容的
  （`FfmpegAudioRenderer` 继承 `DecoderAudioRenderer`，父类签名在 1.4 → 1.7
  之间变过），表现是起播那一刻 `NoSuchMethodError`。
* 升级前用 `javap` 逐个核对了我们用到的 API，签名未变：
  `DefaultRenderersFactory`（含 `setEnableDecoderFallback` / `setMediaCodecSelector` /
  `EXTENSION_RENDERER_MODE_*`）、`DefaultTrackSelector` 及其
  `Parameters.Builder.setTunnelingEnabled` / `setForceHighestSupportedBitrate`、
  `DefaultHlsExtractorFactory(int, boolean)`、`TsExtractor.DEFAULT_TIMESTAMP_SEARCH_BYTES`、
  `MediaSession` / `MediaSessionService` / `DefaultMediaNotificationProvider`。

带进 APK 的原生库（只出 arm64 包，约 5.5MB）：

| 库 | 作用 |
| --- | --- |
| `libmedia3ext.so` | nextlib 的 JNI 层（`ffmpegHasDecoder` / 解码循环） |
| `libavcodec.so` | FFmpeg 本体，含 `ac3` `eac3` `dca` `truehd` `mlp` 解码器 |
| `libavutil.so` / `libswresample.so` / `libswscale.so` | FFmpeg 依赖 + 重采样 |

`.so` 全部 `LOAD` 段 `0x4000` 对齐（16KB 页要求，`readelf -l` 验过），
`verify_apk.py` 会在产物里再查一遍，并且**必须**能查到这个四个库 +
dex 里的 `FfmpegAudioRenderer`，否则构建红。

## 2. 解码器优先级与降级阶梯

```
硬件 / 系统 MediaCodec  →  FFmpeg（只兜底系统解不了的）  →  失败就降级（绝不拖垮起播）
```

* 渲染器：`FxRenderersFactory`（继承 `DefaultRenderersFactory`）**只在音频
  渲染器列表末尾**追加 `FfmpegAudioRenderer`。视频链路一点没动 —— 1080P /
  HEVC 仍然走硬解，`setEnableDecoderFallback(true)` 与「软解优先」那套
  `MediaCodecSelector` 行为不变。
* 降级三层（任何一层失败都只是「这条轨解不了」，不是「播不了」）：
  1. **探测**：`FxAudioExt.available()` 全包 `catch (Throwable)`
     （`UnsatisfiedLinkError` 是 `Error` 不是 `Exception`）；
  2. **挂载**：构造 `FfmpegAudioRenderer` 抛错 → `FxAudioExt.disable(...)`，
     继续用系统解码器；`ExoPlayer.Builder.build()` 不会因此失败；
  3. **播放期**：出现解码错误时，第一次重试**先摘掉 FFmpeg**
     （退回这次改动之前的行为），之后才走原来的「软解 ↔ 硬解」切换。

## 3. 选轨规则（`FxAudioTrack`）

```
① 所有音频轨按 bitrate 降序，取最高（未声明码率 -1 按 0 算，不能赢）
② 同码率：EAC3 > AC3 > DTS > AAC > 其它
③ 首选音轨语言：源里**有**该语言 → 只在该语言里选最高码率；
                一条都没有 → 不限制语言（否则会静默丢掉唯一那条）
④ 解不了的轨不参与（全都不支持时才退回全部，交给 media3 报错）
```

为什么必须在 `TrackSelectionOverride` 里做、而不是调 TrackSelector 参数：
media3 的选轨是**组内比较**，HLS 的多音轨常常是多个独立 `TrackGroup`
（每条 `#EXT-X-MEDIA` 一组），跨组之间不比较码率 —— 谁先被抽出来就是谁。
所以 `ExoPlayerPlugin.onTracksChanged` 里收集 `player.currentTracks` 的全部
音频轨，算出赢家后写成 `TrackSelectionOverride` 钉死；换集 / 换线路 / 重建
播放器时清掉旧 override。

首选音轨语言的来源：`setTrackPrefs` 的**新增可选键** `audioLanguage`
（Dart 现在不传）→ 否则系统语言 ISO3。通道契约里已有的键一个没动：
`preferAac` / `tunneling` / `textLanguage` 语义照旧，其中 `preferAac`
仍接收但**只记日志**（它的方向是错的：AAC 基本就是码率最低那条）。

## 4. 怎么验（真机）

```bash
# 0) 造一份确定的多音轨样本（5 轨 AAC/AC3/EAC3/DTS/TrueHD + 1080P HLS 三音轨）
bash tools/make_multiaudio_sample.sh /tmp/fx-multiaudio
python3 -m http.server 8899 -d /tmp/fx-multiaudio     # 同一台机器上起个静态服务

# 1) 装上 CI 出的 arm64 包，打开上面那个 m3u8 / mkv，抓日志
adb logcat -c && adb logcat -s FxExo FxAudioExt | tee /tmp/fx.log
```

日志里应该能逐条对上：

```
AUDIO_EXT 状态 ffmpeg=on(6.0)                      ← FFmpeg 挂上了（off = 降级）
AUDIO_EXT 已挂 FFmpeg 音轨渲染器（优先级=系统硬解之后）
TRACK 音频候选 mime=audio/mp4a-latm bitrate=- sup=1 sel=0
TRACK 音频候选 mime=audio/ac3 bitrate=384k lang=zho sup=1 sel=0
TRACK 音频候选 mime=audio/eac3 bitrate=640k lang=eng sup=1 sel=0
TRACK 音频候选 mime=audio/vnd.dts bitrate=1536k lang=jpn sup=1 sel=0
TRACK 音频候选 mime=audio/true-hd bitrate=- sup=1 sel=0
TRACK 选中音轨 mime=audio/vnd.dts bitrate=1536k lang=jpn supported=1（候选 5 条，按码率取最高；语言偏好=any）
```

三个验收点分别看：

| 验收 | 看什么日志 |
| --- | --- |
| ① 起播不退化 | `FIRST_FRAME 已渲染` / `t=...ms seek_first_frame` 与改动前同量级 |
| ② AC3/EAC3 源能出声 | `AUDIO_EXT 状态 ffmpeg=on` + 选中音轨是 `ac3`/`eac3`/`vnd.dts`/`true-hd` |
| ③ 多音轨选最高码率 | `TRACK 选中音轨 ...` 的 bitrate 是候选列表里最大的 |

## 5. 门禁（CI）

* `tools/check_fx_audio_track.sh`：选轨规则 25 条 JVM 单测（没有 kotlinc 自动 SKIP）；
* 结构断言：依赖坐标 / 版本配对 / 渲染器位置 / 三条降级路径 / 选轨实现；
* 反向断言：**不许**把 `setPreferredAudioMimeType(AUDIO_AAC)` 写回来；
* `tools/verify_apk.py`：APK 里必须有 FFmpeg 的四个 `.so` + dex 里的
  `FfmpegAudioRenderer`，并且 16KB 页对齐。

# 播放失败 + 三段降级换源（FX_FALLBACK，2026-11-15）

「和影视壳一样：本片所有线路都播不了，就拿片名+年份去别的源找同名，
找到就跳过去继续播。」这份文档说明它到底怎么判定、怎么接着播、怎么排错。

## 1. 三段降级

```
第 1 段  本片其他线路    详情页 _switchNextLine（原有逻辑，未改）
第 2 段  同源其他版本    同片名 + 年份差 ≤1 的**另一条记录**（幻想库里的 hx / xo 两条）
第 3 段  跨源找同名      拿片名去外部源（肥猫的 jar 源 + 自加源）搜
全失败   「所有线路都尝试过了，暂时无法播放」
```

- 第 1 段仍然是原来的流程：原线重试一次 → 逐条换线路（每条最多换入一次）。
- 第 1 段彻底失败（`_showPlaybackError`）才进入第 2 / 3 段。
- **只切一次**：`FxSourceFallback.switched` 一旦为真就不再换源；同一次播放会话
  里 `_fallbackDone` 也保证「搜过一次就不再搜」，不会在源之间来回跳成死循环。
- **每个源只试一次**：`triedSources` 记已查过的源 key（jar 源是 `api|ext`，
  CMS 源是 `api`），第 3 段只查不在集合里的源。

## 2. 匹配规则（必须严）

规则本体在 `lib/services/fallback_match.dart`（纯函数、无 import），
单测 `tools/test_fallback_match.dart` + `test/fallback_match_test.dart` 逐条钉住。

| 规则 | 口径 |
| --- | --- |
| 片名 | 归一化后**全等**（复用 `SourceHub.normTitle` → 现在就是 `fxNormTitle`），不做模糊 |
| 年份 | 差 ≤1 年；一边未知时接受（服务端 `vod_year` 常空），但排在后面 |
| 非正片 | 片名含 解说 / 预告 / 花絮 / 片段 / 抢先 / 彩蛋 / 幕后 / 特辑 / 混剪 / 精讲 / 速看 / trailer … 一律不要 |
| 直播 | `SourceHub.isLiveCard` 的结果不要 |
| 线路 | `degraded` 排最后，要现场解析的 `parse` 次之，集数未知的再往后 |
| 集数 | 对方集数 < 当前集号 → **不换这条**，提示「该源只有 N 集」，停在原处 |

## 3. 集号与进度对齐

- 换源前抓现场：`PlayerViewState.playbackSnapshot()` → `{ep, position, playing}`。
  位置的可信顺序是「播放器当前进度 → 本集最后一次正常位置 → 切换期间锁定的
  UI 进度」；播放器报错后 `value.position` 常常是 0，直接用会退回片头。
- 换源后 `pushReplacement` 到目标记录的 `DetailPage(ep: N, startSeconds: 位置)`，
  播放器 `open` 时把起始位置带进 `startPosition`，首个分片请求就是目标片。
- 对方这一集比当前进度还短（看到 40 分钟、对方只有 30 分钟）→ 夹到末尾继续。
- 对方集数不够（当前第 12 集、对方 8 集）→ 不换，提示「该源只有 8 集」。

## 4. 用户能看到的

| 时机 | 表现 |
| --- | --- |
| 进入第 2 / 3 段 | 画面提示 + toast「当前源播放失败，正在尝试其他源…」 |
| 命中 | toast「已切换到 咕噜」（附带「（该源只有 N 集）」之类的补充） |
| 全失败 | 错误层「所有线路都尝试过了，暂时无法播放」，可重试 / 换线路 |
| jar 没装 | 第 3 段如实跳过，最终提示后缀「装好 jar 插件（spider.jar）后可跨源再找一次」 |

## 5. 日志（永远不静默）

真机排查：`adb logcat | grep FxPlay`

```
[FxPlay] fallback level=2 from=幻想 to=咕噜 reason=all_lines_failed     命中（第 2 段）
[FxPlay] fallback level=3 from=幻想 to=剧圈 reason=all_lines_failed     命中（第 3 段）
[FxPlay] fallback level=2 skip from=幻想 reason=own_empty               没命中（留痕）
[FxPlay] fallback level=3 skip from=幻想 reason=jar_missing             jar 没装，第 3 段跳过
[FxPlay] resume ep=5 pos=754000ms from=幻想 to=咕噜                     换源起播（集号 + 位置）
```

## 6. 全屏里的失败

全屏的救援链（`_rescueLineSource`）把本片线路全部试过后，一旦这一集彻底打不开，
就带着「集号 + 进度」返回竖屏（`_exit(requestLineChange: true, sourceFailed: true)`），
由竖屏继续走降级链。换源发生在竖屏链路里，进度与集号一路带过去，
换完可以再进全屏接着看同一集同一位置。

## 7. 真机验证

1. 用 `ac=detail&ids=` 找一条地址 404 的片（`vod_play_url` 里的域名不可达）；
2. 点播放 → 第 1 段逐条换线路 → 应看到「当前源播放失败，正在尝试其他源…」；
3. 命中后 toast「已切换到 <源名>」，且仍停在第 N 集、进度接着走；
4. 全源都失败：错误层给「所有线路都尝试过了，暂时无法播放」，不会一直转圈。

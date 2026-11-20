# 线路大类按前缀归类 + 冷启动自动装 jar — LINE_PREFIX / JAR_BOOT 2026-11-21

两件用户实测出来的问题，一次改完：

1. **两行线路的第一行大类分错了**：截图里第一行选中「幻想」，第二行却是
   「咕噜 / 幻想爱奇艺 / 红牛」，「咕噜」还高亮着。
2. **四个 jar 源（咕噜 / 橘汁 / 剧圈 / 下饭）全是灰的**：根因是 `spider.jar`
   没装 —— jar 通道不可用，源没有线路，chips 就置灰。

---

## 1. 大类分组：按「线路名前缀」，不再按数据来源

### 根因

服务端采集入库的线路名**本身就带源名前缀**（`glu_collect.php` 写的是
`vod_play_from = 咕噜` / `咕噜·量子资源` / `咕噜·暴风资源`）。旧实现在
`fxLineGroupKeyOf` 里只认 `$label·`（**必须带分隔符**）：

```dart
if (name.startsWith('$label·') || name.startsWith('$label・')) return label;
```

裸名字那条 `咕噜` 不满足 → 落到 `own` → 显示在「幻想」大类第二行，
而且因为它正是当前播放的线路，第二行里它被高亮。这就是截图。

### 现在

`lib/services/jar_sources.dart`：

* 新增 `fxLineGroupLabelOfName(String)` —— **纯函数**，按前缀判大类，
  分隔符可有可无（`咕噜` / `咕噜·x` / `咕噜4K` / `咕噜 4K` / `咕噜|量子资源`
  都算咕噜）；装饰字符（emoji / 竖线）先剥掉再比。
* `fxLineGroupKeyOf` 先看 jar 编码过的线路 id（`jar::源::片::flag`），
  再看名字前缀，其余归 `own`（幻想）。
* `fxLineSubName` 去掉前缀（`咕噜·量子资源` → `量子资源`）；名字就是大类名
  （裸 `咕噜`）时显示 `默认`；**幻想大类只剥带分隔符的写法**，所以
  `幻想爱奇艺` 原样显示（不会被剥成「爱奇艺」）。

### 真值表（`test/line_group_prefix_test.dart` 逐条钉住）

| 线路名 | 归属大类 |
| --- | --- |
| `咕噜` | 咕噜 |
| `咕噜·量子资源` | 咕噜 |
| `咕噜·暴风资源` | 咕噜 |
| `咕噜·非凡资源` | 咕噜 |
| `咕噜·电影天堂` | 咕噜 |
| `咕噜·4K` | 咕噜 |
| `咕噜4K` | 咕噜 |
| `剧圈·线路1` / `剧圈` | 剧圈 |
| `橘汁·高清` | 橘汁 |
| `下饭·线路2` | 下饭 |
| `量子` | 幻想 |
| `SH4K` | 幻想 |
| `幻想爱奇艺` / `幻想自建` | 幻想 |
| `shvip` / `bilibili` / `qq` / `mgtv` / `youku` | 幻想 |
| `红牛` / `TW线路` | 幻想 |

**`咕噜·量子资源` 和自有的 `量子` 是两条线路**：前者进咕噜大类、后者留在
幻想大类，id 不同，不合并、不互相覆盖（有专门断言）。

---

## 2. 冷启动自动装 `spider.jar`

### 开关与流程

| 位置 | 改动 |
| --- | --- |
| `AppSettings` | `defaultJarAutoInstall = true`（读不到存档也按开）；新增 `setJarAutoInstall` |
| `main.dart` `Boot.run()` | source hub 就绪后 `unawaited(JarPluginManager.instance.bootSilently())` |
| `JarPluginManager.bootSilently()` | 记开始日志 → `ensureReady()`（内置优先 → 下载 + md5 强校验，最多 2 次）→ 记结果日志；**永不抛** |
| `JarPluginManager._syncHub()` | 装完清 jar 状态缓存并重查 → 搜索页 / 详情页据此立刻生效 |

口径：

* **不挡首屏**：`unawaited`，CI 有反向门禁（`await ... bootSilently` 出现即红）。
* **带 md5**：地址 / md5 取 `AppSettings`（默认
  `http://125.94.244.87/spider.jar` / `cbe016eb3cb002ae62058604843f5106`），
  原生侧校验不过直接失败，不会留半个 jar。
* **失败不阻断**：只把 phase 写成 `failed`，设置 → 片源管理里标红并给原因；
  App 其它功能照旧。
* **日志**：`[JarBoot] 启动检查 auto=… url=…` / `[JarBoot] 结果 phase=… md5=…`，
  真机 `adb logcat | grep JarBoot` 一条命令看全。

### 装好之后立刻可用（chips 不再置灰）

| 场景 | 处理 |
| --- | --- |
| 冷启动边装边用，详情页已经开着 | 详情页监听 `SourceHub`，`jarReady` false→true 时 `_mergeJarLines(fillHits: true)` |
| 从首页 / 收藏直接进详情（没有搜索期索引） | 首屏合并带 `fillHits`：`CmsBridge.fillJarHitsFor(detail)` 按片名在启用源里补一次命中 |
| 搜索时 jar 还没装好 | 搜索页监听 `SourceHub`，`jarReady` 翻真时**重跑上一轮搜索**，jar 波次正常参与 |

### 没装 jar 时（用户要求第 4 条）

* 搜索：`searchStream` 里 `jarSources = hub.jarReady ? plan.external : []` —— 不发车。
* 详情：`jarLinesFor` / `fillJarHitsFor` 第一件事就是 `if (!hub.jarReady) return …` ——
  一条请求都不发，也不白等十几秒。
* 两处都给同一句话：`SourceHub.jarNotice` →
  `jar 未就绪：咕噜 / 橘汁 / 剧圈 / 下饭 四个源需要先装 spider.jar，去 设置 → 片源管理 → 安装 / 更新`
  （搜索页 `_jarNoticeBar`、详情页 `_jarNotReadyHint`）。

### 设置 → 片源管理的每源状态

`fxJarSourceStateOf(installed:, enabled:)` + `fxJarSourceStateLabel`：

| 状态 | 含义 |
| --- | --- |
| `可用` | jar 已装 + 源开着 |
| `jar 未安装` | 源开着但没 jar（这一行右侧直接给「安装 / 更新」） |
| `已停用` | 用户自己关掉的（优先显示，比缺 jar 更直接） |

---

## 3. 验收

| 项 | 落点 |
| --- | --- |
| ① 分组真值表 | `test/line_group_prefix_test.dart`（20 条线路名 + 三条「量子」混淆 + 装饰字符） |
| ② 冷启动自动装 jar 的日志 / 断言 | `test/jar_autoboot_test.dart`「冷启动自动装 jar：走 jarInstall + md5，落地 ready，并留 JarBoot 日志」 |
| ③ 装好后四个源 chips 不再置灰 | `test/jar_autoboot_test.dart`「装好 jar：四个源都能合并子线路 → 四个大类 available（不置灰）」+ 组件级 `line_group_prefix_test.dart`「第一行点咕噜 → 第二行换成咕噜的子线路」 |
| ④ CI | `.github/workflows/build.yml` → job `build-apk` step `jar 源（融合 / 两行线路）regressions`（新增 ⑦ 段 JAR_BOOT / 前缀分组门禁） |

本地跑法（CI 同一套命令）：

```bash
flutter analyze --fatal-infos
flutter test test/line_group_prefix_test.dart test/jar_autoboot_test.dart
flutter test          # 全量 538 条
```

## 4. 没动的东西

* 通道契约：`fantasy_tv/spider` 的方法名 / 参数名 / 返回结构一个字没改
  （CI 仍钉着 `MethodChannel('fantasy_tv/spider')`）。
* 首页 / 分类 / 排行榜：仍然只用自有源（`searchPlan.own`，jar 源不在其中）。
* 融合口径：搜索命中的合并线路 / 未命中的新增卡片，与 JAR_RESTORE 一致。

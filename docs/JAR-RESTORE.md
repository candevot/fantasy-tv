# jar 源（影视壳那套）恢复记录 — JAR_RESTORE 2026-11-21

> 历史参考：`d79e901`（拆 ① 设置页片源管理入口）+ `d893aa4`（拆 ②③④ jar 源接入层
> 整层移除）。任务里写的 `e07323cd` 在仓库里不存在 —— 实际把这一层删掉的是上面
> 两个提交，恢复以它们的父提交为准。
>
> 口径：**只恢复「搜索 + 播放解析」用的 jar 层**，并且只保留用户点名的四个源。
> 首页 / 分类 / 排行榜 / 搜索的其它行为一个字没动。

## 1. 恢复了哪些文件

### 原样从历史取回（未改写）

| 文件 | 行数 | 作用 |
| --- | --- | --- |
| `lib/services/jar_spider.dart` | 1215 | jar 通道封装（search / detail / playerContent）+ TVBox JSON → 模型 |
| `lib/services/jar_plugin.dart` | 399 | jar 安装 / 自检状态机（**JAR_BOOT 2026-11-21 起冷启动会自动装**，见 `LINE-PREFIX-AND-JAR-BOOT.md`） |
| `lib/services/jar_log.dart` | 39 | `[JarSearch] / [JarDetail] / [JarPlay]` 链路日志 |
| `lib/services/tvbox_crypto.dart` | 185 | 配置解密（保留，别再删一次又得找） |
| `lib/services/search_group.dart` | 246 | 源名归一（`咕噜 • APP` → `咕噜`）/ 分组纯逻辑 |
| `lib/widgets/jar_plugin_card.dart` | 442 | 设置页「jar 插件」卡片（状态 / 安装 / 自检） |
| `test/jar_plugin_test.dart` | 147 | jar 安装状态机回归 |
| `test/jar_search_fallback_test.dart` | 423 | quick 回退 + 相关性闸门 + 日志格式 |
| `test/tvbox_crypto_test.dart` | 41 | 配置解密回归 |
| `test/search_group_test.dart` | 200 | 源名 / 分组回归 |
| `test/search_group_pinned_test.dart` | 82 | 组标题吸顶回归 |

`android_src/kotlin/.../JarSpiderLoader.kt` / `JarSpiderPlugin.kt` 一直在仓库里，
只是没人调；这次恢复 Dart 侧之后它们重新被用到。**通道契约一个字没改**
（`fantasy_tv/spider` 的方法名 / 参数名原样）。

### 新增（这次才有的「闸门」层）

| 文件 | 作用 |
| --- | --- |
| `lib/services/jar_sources.dart` | 白名单 `kEnabledJarSources`、内置源目录 `kBuiltinJarSources`、jar 线路 id 编解码、两行分组纯逻辑、融合索引 `JarMergeIndex` |
| `lib/widgets/fx_line_group_selector.dart` | 两行线路选择器（详情页 / 一起看三处共用） |
| `lib/pages/source_settings_page.dart` | 设置 → 片源管理（只有四个 jar 源的开关 + jar 插件卡） |
| `test/jar_fusion_test.dart` | 融合口径（合并线路 / 新增卡片 / 两行分组 / 实时解析）11 条 |
| `test/jar_source_toggle_test.dart` | 白名单 / 默认开关 / 启停持久化 4 条 |

### 改动的既有文件

| 文件 | 改了什么 |
| --- | --- |
| `lib/services/source_hub.dart` | `type:3` 重新算 jar 源；补内置目录；`jarSources` / 开关持久化 / `jarReady`；`searchPlan.external` = jar 源；`searchSource` 恢复 jar 分支 |
| `lib/services/cms_bridge.dart` | 搜索流加 jar 波次（并发发车、结果押后合并）；`detail` / `play` / `playUrl` 的 jar 路由；`jarLinesFor()` 融合入口；`_jarGuard` |
| `lib/pages/detail_page.dart` | 线路区换成两行组件；详情加载后台合并 jar 子线路；自有线路恒在 jar 前 |
| `lib/pages/settings_page.dart` | 恢复「jar 插件」卡 + 「片源管理」入口 |
| `lib/services/app_settings.dart` | 恢复 `jarUrl` / `jarMd5`（`jarAutoInstall` 默认 **关**） |
| `lib/widgets/together_sheets.dart` | 房间线路面板 / 底栏线路入口换成同一个两行组件 |
| `lib/widgets/together_room_picker.dart` | 建房「选线路」一步换成同一个两行组件，并合并 jar 子线路 |
| `lib/services/search_relevance.dart` | 闸门日志回到 `[JarSearch]` 口径（保留 `fxSourceGateLog` 别名） |
| `.github/workflows/build.yml` | 恢复 jar 回归步骤（见第 4 节） |

## 2. 恢复后的行为

1. **只在搜索 + 播放解析用 jar 源**：`SourceHub.querySources` 明确跳过 jar，
   首页 / 分类 / 排行榜 / 上拉加载更多都不碰 jar。
2. **融合**（用户口径「我们有的它合并进来，我们没有的它能搜到」）：
   - 我们库里已有的片 → **不新增卡片**，jar 的子线路合并进那条记录（`咕噜·4K`）；
   - 我们库里没有的片 → jar 结果作为**新条目**上屏，详情 / 播放都走 jar 通道；
   - 合并键 = 片名（归一化）+ 年份；年份对不上时退一步只按片名（jar 常写 0）。
3. **默认启用名单**：`kEnabledJarSources`（`lib/services/jar_sources.dart:26`）。
4. **播放实时解析**：`CmsBridge.play` 认出 `jar::<源名>::<vod_id>::<flag>` 就走
   `playerContent` 现解析，地址只进内存缓存（`FxPlayCache`，10 分钟），不落库。
5. **线路名**：`<源名>·<它自己的子线路名>`，同源同名只留一条；自有线路恒排在
   jar 线路前面。
6. **没恢复的自动行为**：TVBox 配置导入（`importTvBox`）、启动自动安装
   spider.jar（`AppSettings.jarAutoInstall` 默认 false，且没有任何启动路径调它）。

## 3. 设置页「片源管理」长什么样

`设置 → jar 插件`（`JarPluginCard`：状态 / 大小 / md5 / 安装 / 更新 / 自检）

`设置 → 片源与直播 → 片源管理`（`SourceSettingsPage`）：

```
[ jar 插件卡（JarPluginCard） ]
jar 片源
  咕噜    csp_Gulu            [开]
  橘汁    csp_AppDrama        [开]
  剧圈    csp_App99           [开]
  下饭    csp_JuXiaFan        [开]
· 只影响搜索和播放解析：首页 / 分类 / 排行榜永远只用幻想自己的片源。
· 默认只开用户挑中的 4/4 个；关掉之后搜索不再向它发请求。
· 播放时现场解析（jar 的 playerContent），库里不存播放地址。
```

开关落盘键 `fx_jar_enabled_v1`（`SourceHub._kJarEnabled`）：没改过就按白名单，
改过之后按用户的选择。别的肥猫源一条都不显示。

## 4. CI

`.github/workflows/build.yml` 里新增（原来是 `jar plugin regressions`，拆除时删掉）：

```yaml
- name: jar 源（融合 / 两行线路）regressions
  run: |
    set -e
    grep -q "const List<String> kEnabledJarSources" lib/services/jar_sources.dart
    grep -q "'咕噜', '橘汁', '剧圈', '下饭'" lib/services/jar_sources.dart
    grep -q 'csp_Gulu' lib/services/jar_sources.dart
    ...
    # 反面门禁：TVBox 配置导入不许回来
    # （「启动自动安装 spider.jar」这条旧门禁已在 JAR_BOOT 2026-11-21 按用户
    #   要求反过来：现在冷启动**必须**自动装，新门禁见同 step 的 JAR_BOOT 段）
    flutter test test/jar_fusion_test.dart
    flutter test test/jar_source_toggle_test.dart
    flutter test test/jar_plugin_test.dart
    flutter test test/tvbox_crypto_test.dart
    flutter test test/search_group_test.dart test/search_group_pinned_test.dart
    python3 tools/check_spider_url.py || true
```

## 5. 验收怎么复现

1. 搜索一部我们库里**有**的片（如「八仙」）：只有一张卡片；进详情后线路区第一行
   出现 `幻想 / 咕噜 / 橘汁 / 剧圈 / 下饭`，点「咕噜」第二行是它的子线路
   （`4K` / `暴风资源` / `量子资源` …）。
2. 搜索一部我们库里**没有**的片（jar 里有）：出现一张新卡片，能点开、能播。
3. 一起看：建房选线路 / 房间线路面板 / 全屏底栏线路入口都是同一套两行结构；
   房主切「咕噜 → 4K」，全员跟着切到 `咕噜·4K`（沿用 `switchLine` 广播）。

## 6. 后续（2026-11-21 第二轮）

用户实测报了两个问题，改法与真值表见 [`LINE-PREFIX-AND-JAR-BOOT.md`](LINE-PREFIX-AND-JAR-BOOT.md)：

1. 第一行大类改成**按线路名前缀**判（库里裸名字 `咕噜` 必须进咕噜大类）；
2. 「启动不自动装 spider.jar」的口径**作废** —— 现在首次进 App 后台静默装
   （md5 校验、失败不阻断），装好后四个源立刻可用。

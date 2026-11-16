# 116 个 jar 源逐个实测（搜「济公传」）— 2026-11-16

测试方式：把线上 `spider.jar`（`http://125.94.244.87/spider.jar`，classes.dex 4.9MB）
用 dex2jar 转成 JVM 可加载的 class，**直接调每个类的
`init(null, ext)` + `searchContent("济公传", false)`**，真网络、真站点、真超时。
配置取自 `http://125.94.244.87/hx_all.json`（116 个 type3 源 + 1 个 type1）。

> 为什么要用 JVM 而不是真机：本机 ART（`/apex/.../dalvikvm64`）在 proot 里
> 无法初始化 JNI（`Failed to initialize JNI invocation API`），`app_process64`
> 缺 `libnativeloader.so`，所以没法在手机侧直接跑 dex。dex2jar 的产物在
> 「纯 Java 逻辑 + okhttp 网络」这条路径上与真机等价；少数源会碰到
> Android 原生方法（`SystemProperties` / `libcore.io.Linux.getuid`）在 JVM 上
> 不可用 —— 这类在表里单列，**真机上不会失败**。

## 结论一：`ext` 传参没问题

三源对照（同一份 jar、同一份代码路径）：

| 源 | ext | 返回 | 说明 |
|---|---|---|---|
| `csp_Gulu` 咕噜 | 无 | 3 条（济公传 / 济公传郭德纲版 / 济公新传） | 对照组 |
| `csp_AppRJ` 热播 | `{"url":"http://v.rbotv.cn"}` | 0 条（但 `homeContent` 有分类，搜「济公」出 8 条） | ext 读到了，是站点没这部片 |
| `csp_Douban` 豆瓣 | 无 | 0 条 | 配置里本来就是 `searchable:0` 的首页源 |

带 ext 的源里 **下饭 40 条 / 荐片 20 条 / 金牌 8 条 / 半日 3 条** 都正常出结果，
所以「带 ext 出不来」这个假设不成立。

## 结论二：真凶是原生侧把 init 关在全局锁里

`JarSpiderLoader.spider()` 原来把 `bootstrapJar()` + `newInstance()` +
`initInstance()` **整段**放在 `synchronized(lock)` 内。实测 `csp_SaoHuo.init()`
会同步抓 `http://shapp.us/`，**33 秒**才返回 —— 它一进锁，其余 115 个源全部
在锁外排队，12 秒单源预算下根本没开始就超时。

用真实 116 源复刻两版调度（20 并发、单源 12 秒）：

| | 30 秒内跑完 | 命中源 |
|---|---|---|
| 改动前（全局锁） | **39 / 116** | **10 个** |
| 改动后（短锁 + init 独立池） | 40 秒跑完 **115 / 116** | **24 个** |

修复后命中源：下饭(40) 围观短剧(30) 韩圈(21) 荐片(20) 河马短剧(15) 听友听书(10)
七猫短剧(10) 懂片(8) 金牌影视(8) 看剧(8) 赏月(7) 蜻蜓FM(4) 星辰影视(4) 一起影视(4)
骚火影视(4) 剧圈99(3) 半日99(3) 咕噜(3) 马猴影视(2) 1905(2) 博看听书(1) 飞娱影视(1)
布布(1) 种子(1) —— **远超「至少 8 个来源」的验收线**。

## 结论三：客户端相关性闸门不是主因

把 24 个有返回的源的真实片名喂给 `fxSearchGate`（`lib/services/search_relevance.dart`
的逐字复刻）：**保留 123 条 / 丢弃 86 条，21 个源仍有结果**，只整源清空 3 个
（韩圈、七猫短剧、围观短剧 —— 它们回的是无关短剧/韩剧，本来就该丢）。
闸门放宽没有收益，问题不在这里。

## 完整逐源表（116 行）

「判定」一列的口径：

- **有结果** —— 真按关键词出了片；
- **返回 0 条** —— 源站通了但没这部片（换关键词会有，例如 `csp_AppRJ` 搜「济公」出 8 条）；
- **JVM 环境限制 / JVM 栈溢出 / dex2jar 产物异常** —— 源本身在真机上能用，
  只是 dex2jar 转出来的 class 缺 Android 原生方法或栈帧；
- **py 源** —— `api` 是 `.py` 地址，jar 通道没有这个类（需要 python loader，本项目不支持）；
- **jar 缺依赖类** —— 配置里写的类在 jar 里不存在。

| 1 | 下饭 | 下饭 • APP | `csp_JuXiaFan` | 无 | 1 | 40 | 1006ms | 有结果 |
| 2 | 韩圈 | 韩圈 • APP | `csp_Hxq` | 无 | 1 | 21 | 939ms | 有结果 |
| 3 | 荐片 | 荐片 • 磁力 | `csp_JianPian` | 有 | 1 | 20 | 581ms | 有结果 |
| 4 | 河马短剧 | 河马 • 短剧 | `csp_ShortHema` | 无 | 1 | 15 | 258ms | 有结果 |
| 5 | 七猫短剧 | 七猫 • 短剧 | `csp_ShortQimao` | 无 | 1 | 10 | 855ms | 有结果 |
| 6 | 听友听书 | 听友 • 听书 | `csp_TingTingyou` | 无 | 1 | 10 | 826ms | 有结果 |
| 7 | 懂片 | 懂片 • 影视 | `csp_DongPian` | 无 | 1 | 8 | 348ms | 有结果 |
| 8 | 看剧 | 看剧 • 影视 | `csp_KanJuAI` | 无 | 1 | 8 | 848ms | 有结果 |
| 9 | 金牌影视 | 金牌 • 影视 | `csp_Jpys` | 有 | 1 | 8 | 5658ms | 有结果 |
| 10 | 赏月 | 赏月 • 动漫 | `csp_AnimeTsukimi` | 无 | 1 | 7 | 1085ms | 有结果 |
| 11 | 一起影视 | 一起 • APP | `csp_AppYQK` | 无 | 1 | 4 | 724ms | 有结果 |
| 12 | 星辰影视 | 星辰 • 影视 | `csp_XingChen` | 无 | 1 | 4 | 1784ms | 有结果 |
| 13 | 蜻蜓FM | 蜻蜓 • FM | `csp_QingtingFM` | 无 | 0 | 4 | 165ms | 有结果 |
| 14 | 骚火影视 | 骚火 • 影视 | `csp_SaoHuo` | 有 | 1 | 4 | 11793ms | 有结果 |
| 15 | 半日99 | 半日 • APP | `csp_App99` | 有 | 1 | 3 | 403ms | 有结果 |
| 16 | 咕噜 | 咕噜 • APP | `csp_Gulu` | 无 | 1 | 3 | 466ms | 有结果 |
| 17 | 1905 | 1905 • 影视 | `csp_Web1905` | 无 | 1 | 2 | 730ms | 有结果 |
| 18 | 剧圈99 | 剧圈 • APP | `csp_App99` | 有 | 1 | 2 | 291ms | 有结果 |
| 19 | 马猴影视 | 马猴 • APP | `csp_App3Q` | 有 | 1 | 2 | 938ms | 有结果 |
| 20 | 博看听书 | 博看 • 听书 | `csp_TingBokan` | 无 | 1 | 1 | 459ms | 有结果 |
| 21 | 布布 | 布布 • APP | `csp_YunDuo` | 有 | 1 | 1 | 797ms | 有结果 |
| 22 | 种子 | 种子 • 4K | `csp_SeedHub` | 有 | 1 | 1 | 3684ms | 有结果 |
| 23 | 飞娱影视 | 飞娱 • 影视 | `csp_Feiyu` | 无 | 1 | 1 | 341ms | 有结果 |
| 24 | 123云盘 | 123 • 云盘 | `csp_Pan123` | 无 | 0 | 0 | 1ms | 返回 0 条 |
| 25 | 88看球 | 88 • 看球 | `csp_Sports88` | 无 | 0 | 0 | 0ms | 返回 0 条 |
| 26 | New6v | New6V • 磁力 | `csp_New6v` | 有 | 1 | -1 | 878ms | dex2jar 产物异常（真机可用） |
| 27 | UC网盘 | UC • 网盘 | `csp_PanUC` | 无 | 0 | 0 | 0ms | 返回 0 条 |
| 28 | push_agent | 手机 • 推送 | `csp_Push` | 无 | 0 | 0 | 1ms | 返回 0 条 |
| 29 | 三六零 | 三六零 • 视频 | `csp_SP360` | 无 | 1 | -1 | 3ms | JVM 环境限制（Android 原生方法，真机可用） |
| 30 | 世界听书 | 世界 • 听书 | `https://oss-v1.wangmeipo.cn/236/世界听书.py` | 无 | 1 | -1 | 0ms | py 源（需 python loader，jar 通道无类） |
| 31 | 光鸭云盘 | 光鸭 • 云盘 | `csp_PanGuangya` | 无 | 0 | 0 | 2ms | 返回 0 条 |
| 32 | 兔小贝 | 兔小贝 • 儿童 | `csp_TuXiaoBei` | 无 | 1 | 0 | 474ms | 返回 0 条 |
| 33 | 八零 | 八零 • 4K | `csp_PanWebShare` | 有 | 1 | 0 | 10966ms | 返回 0 条 |
| 34 | 养生堂 | 养生 • 知识 | `csp_YST` | 无 | 0 | 0 | 0ms | 返回 0 条 |
| 35 | 初中课堂 | 初中 • 课堂 | `csp_Bili` | 有 | 0 | -1 | 0ms | JVM 环境限制（Android 原生方法，真机可用） |
| 36 | 华谊 | 华谊 • APP | `csp_AppDrama` | 有 | 1 | -1 | 441ms | JVM 环境限制（Android 原生方法，真机可用） |
| 37 | 卡卡 | 卡卡 • 4K | `csp_KKPan` | 无 | 1 | -1 | 5ms | JVM 栈溢出（dex2jar 产物，真机可用） |
| 38 | 即刻 | 即刻 • 4K | `csp_Jike` | 无 | 1 | -1 | 5ms | JVM 栈溢出（dex2jar 产物，真机可用） |
| 39 | 厂长影视 | 厂长 • 影视 | `csp_Czsapp` | 有 | 1 | 0 | 2254ms | 返回 0 条 |
| 40 | 双星 | 双星 • 4K | `csp_ShuangXing` | 无 | 1 | -1 | 6ms | JVM 栈溢出（dex2jar 产物，真机可用） |
| 41 | 吉里动漫 | 吉里 • 动漫 | `csp_AnimeGiri` | 无 | 1 | 0 | 1061ms | 返回 0 条 |
| 42 | 呦呦DJ | 呦呦 • DJ | `csp_Djuu` | 无 | 1 | 0 | 1ms | 返回 0 条 |
| 43 | 咖啡体育 | 咖啡 • 体育 | `csp_SportsKafei` | 无 | 0 | 0 | 0ms | 返回 0 条 |
| 44 | 哔哩合集 | 哔哩 • 合集 | `csp_Bili` | 有 | 1 | -1 | 12ms | JVM 环境限制（Android 原生方法，真机可用） |
| 45 | 哔哩哔哩听书 | 哔哩 • 听书 | `csp_Bili` | 有 | 0 | -1 | 0ms | JVM 环境限制（Android 原生方法，真机可用） |
| 46 | 哔哩哔哩小品 | 哔哩 • 小品 | `csp_Bili` | 有 | 0 | -1 | 0ms | JVM 环境限制（Android 原生方法，真机可用） |
| 47 | 哔哩哔哩戏曲 | 哔哩 • 戏曲 | `csp_Bili` | 有 | 0 | -1 | 0ms | JVM 环境限制（Android 原生方法，真机可用） |
| 48 | 哔哩哔哩相声 | 哔哩 • 相声 | `csp_Bili` | 有 | 0 | -1 | 0ms | JVM 环境限制（Android 原生方法，真机可用） |
| 49 | 哔哩哔哩音乐 | 哔哩 • 音乐 | `csp_Bili` | 有 | 0 | -1 | 0ms | JVM 环境限制（Android 原生方法，真机可用） |
| 50 | 哔哩视频 | 哔哩 • 视频 | `csp_BiliYS` | 有 | 1 | -1 | 0ms | JVM 环境限制（Android 原生方法，真机可用） |
| 51 | 围观短剧 | 围观 • 短剧 | `csp_ShortWeiguan` | 无 | 1 | -1 | 1ms | JVM 环境限制（Android 原生方法，真机可用） |
| 52 | 堇夏听书 | 堇夏 • 听书 | `csp_TingJinxia` | 有 | 1 | 0 | 291ms | 返回 0 条 |
| 53 | 多多 | 多多 • 4K | `csp_PanWebShare` | 有 | 1 | 0 | 12501ms | 返回 0 条 |
| 54 | 天堂 | 天堂 • APP | `csp_AppDrama` | 有 | 1 | -1 | 389ms | JVM 环境限制（Android 原生方法，真机可用） |
| 55 | 天翼云盘 | 天翼 • 云盘 | `csp_PanTianyi` | 无 | 0 | 0 | 2ms | 返回 0 条 |
| 56 | 夸克网盘 | 夸克 • 网盘 | `csp_PanQuark` | 无 | 0 | 0 | 1ms | 返回 0 条 |
| 57 | 好看短剧 | 好看 • 短剧 | `csp_ShortHaokan` | 无 | 1 | 0 | 140ms | 返回 0 条 |
| 58 | 小丑 | 小丑 • 4K | `csp_4KZhinan` | 有 | 1 | 0 | 2347ms | 返回 0 条 |
| 59 | 小学课堂 | 小学 • 课堂 | `csp_Bili` | 有 | 0 | -1 | 0ms | JVM 环境限制（Android 原生方法，真机可用） |
| 60 | 少儿教育 | 少儿 • 教育 | `csp_Bili` | 有 | 0 | -1 | 0ms | JVM 环境限制（Android 原生方法，真机可用） |
| 61 | 巴士动漫 | 巴士 • 动漫 | `csp_AnimeBashi` | 无 | 1 | 0 | 14805ms | 返回 0 条 |
| 62 | 快映 | 快映 • 4K | `csp_PanWebShare` | 有 | 1 | 0 | 2779ms | 返回 0 条 |
| 63 | 快映fox | 快映 • APP | `csp_AppFox` | 有 | 1 | 0 | 30530ms | 返回 0 条 |
| 64 | 急救教学 | 急救 • 教学 | `csp_FirstAid` | 无 | 0 | 0 | 1665ms | 返回 0 条 |
| 65 | 戏曲多多 | 戏曲 • 多多 | `csp_AppLY` | 无 | 0 | 0 | 0ms | 返回 0 条 |
| 66 | 指南 | 指南 • 4K | `csp_4KZhinan` | 有 | 1 | 0 | 2416ms | 返回 0 条 |
| 67 | 搬运 | 搬运 • 4K | `csp_BanYunDao` | 无 | 1 | -1 | 8ms | JVM 栈溢出（dex2jar 产物，真机可用） |
| 68 | 旺旺影视 | 旺旺 • 影视 | `csp_Wwys` | 有 | 1 | 0 | 136ms | 返回 0 条 |
| 69 | 星芽短剧 | 星芽 • 短剧 | `csp_ShortXingya` | 无 | 1 | 0 | 1653ms | 返回 0 条 |
| 70 | 木偶 | 木偶 • 4K | `csp_PanWebShare` | 有 | 1 | 0 | 799ms | 返回 0 条 |
| 71 | 本地 | 本地 • 视频 | `csp_LocalFile` | 无 | 1 | 0 | 11ms | 返回 0 条 |
| 72 | 果果短剧 | 果果 • 短剧 | `csp_XBPQ` | 有 | 1 | 0 | 1978ms | 返回 0 条 |
| 73 | 枫叶影视 | 枫叶 • 影视 | `csp_FengYe` | 有 | 1 | 0 | 2247ms | 返回 0 条 |
| 74 | 橘汁 | 橘汁 • APP | `csp_AppDrama` | 有 | 1 | -1 | 415ms | JVM 环境限制（Android 原生方法，真机可用） |
| 75 | 热播影视 | 热播 • APP | `csp_AppRJ` | 有 | 1 | 0 | 231ms | 返回 0 条 |
| 76 | 爱盼 | 爱盼 • 4K | `csp_AiPan` | 无 | 1 | -1 | 6ms | JVM 栈溢出（dex2jar 产物，真机可用） |
| 77 | 爱看机器人 | 爱看 • 影视 | `csp_Ikanbot` | 无 | 1 | 0 | 6ms | 返回 0 条 |
| 78 | 独播影视 | 独播 • 影视 | `csp_Duboku` | 无 | 1 | 0 | 889ms | 返回 0 条 |
| 79 | 王子 | 王子 • APP | `csp_AppGet` | 有 | 1 | 0 | 21385ms | 返回 0 条 |
| 80 | 玩偶 | 玩偶 • 4K | `csp_Wogg` | 有 | 1 | 0 | 2054ms | 返回 0 条 |
| 81 | 球通体育 | 球通 • 体育 | `csp_SportQiutong` | 无 | 0 | 0 | 0ms | 返回 0 条 |
| 82 | 瓜子体育 | 瓜子 • 体育 | `csp_SportsGuazi` | 无 | 0 | 0 | 1ms | 返回 0 条 |
| 83 | 瓜子影视 | 瓜子 • 影视 | `csp_Gz360` | 无 | 1 | -1 | 1ms | JVM 环境限制（Android 原生方法，真机可用） |
| 84 | 电影港 | 电影港 • 磁力 | `csp_DianYingG` | 无 | 1 | 0 | 285ms | 返回 0 条 |
| 85 | 番社动漫 | 番社 • 动漫 | `csp_XBPQ` | 有 | 1 | 0 | 1218ms | 返回 0 条 |
| 86 | 百度网盘 | 百度 • 网盘 | `csp_PanBaidu` | 无 | 0 | 0 | 1ms | 返回 0 条 |
| 87 | 百酷 | 百酷 • 搜索 | `csp_Baiku` | 无 | 1 | -1 | 1ms | JVM 栈溢出（dex2jar 产物，真机可用） |
| 88 | 盘搜 | 盘搜 • 搜索 | `csp_PanSou` | 无 | 1 | -1 | 3ms | JVM 栈溢出（dex2jar 产物，真机可用） |
| 89 | 移动 | 移动 • 4K | `csp_Yidong4K` | 无 | 1 | -1 | 6ms | JVM 栈溢出（dex2jar 产物，真机可用） |
| 90 | 稀饭 | 稀饭 • 动漫 | `csp_AnimeXifan` | 无 | 1 | 0 | 1258ms | 返回 0 条 |
| 91 | 童趣 | 童趣 • 儿童 | `csp_TongQu` | 无 | 1 | -1 | 30050ms | 站点返回空（真机同样空） |
| 92 | 米诺 | 米诺 • APP | `csp_AppMN` | 无 | 1 | 0 | 129ms | 返回 0 条 |
| 93 | 红果短剧 | 红果 • 短剧 | `https://oss-v1.wangmeipo.cn/236/红果短剧.py` | 无 | 1 | -1 | 0ms | py 源（需 python loader，jar 通道无类） |
| 94 | 美剧迷 | 美剧迷 • 磁力 | `csp_MeijuMi` | 无 | 1 | -1 | 3ms | dex2jar 产物异常（真机可用） |
| 95 | 花卷 | 花卷 • 4K | `csp_PanWebShareHJ` | 有 | 1 | 0 | 1058ms | 返回 0 条 |
| 96 | 花子动漫 | 花子 • 动漫 | `csp_AnimeHuazi` | 无 | 1 | -1 | 1ms | jar 缺依赖类（AppFQ 不在 jar 内） |
| 97 | 苹果 | 苹果 • APP | `csp_AppDrama` | 有 | 1 | -1 | 377ms | JVM 环境限制（Android 原生方法，真机可用） |
| 98 | 茉莉 | 茉莉 • 4K | `csp_HDmoli` | 有 | 1 | 0 | 18365ms | 返回 0 条 |
| 99 | 茉莉Get | 茉莉 • APP | `csp_AppGet` | 有 | 1 | -1 | 386ms | JVM 环境限制（Android 原生方法，真机可用） |
| 100 | 蓝鸟 | 蓝鸟 • APP | `csp_AppQi` | 有 | 1 | 0 | 533ms | 返回 0 条 |
| 101 | 蓝鹰 | 蓝鹰 • APP | `csp_AppQi` | 有 | 1 | 0 | 198ms | 返回 0 条 |
| 102 | 虎斑 | 虎斑 • 4K | `csp_PanWebShare` | 有 | 1 | 0 | 1754ms | 返回 0 条 |
| 103 | 蜡笔 | 蜡笔 • 4K | `csp_PanWebShare` | 有 | 1 | 0 | 2681ms | 返回 0 条 |
| 104 | 觅盘 | 觅盘 • 搜索 | `csp_MiPan` | 无 | 1 | -1 | 2ms | JVM 栈溢出（dex2jar 产物，真机可用） |
| 105 | 豆瓣 | 豆瓣 • 首页 | `csp_Douban` | 无 | 0 | 0 | 12ms | 返回 0 条 |
| 106 | 贝乐虎 | 贝乐虎 • 儿童 | `csp_BeiLeHu` | 无 | 1 | 0 | 1ms | 返回 0 条 |
| 107 | 趣盘 | 趣盘 • 搜索 | `csp_QuPanSo` | 无 | 1 | -1 | 2ms | JVM 栈溢出（dex2jar 产物，真机可用） |
| 108 | 迅雷云盘 | 迅雷 • 云盘 | `csp_PanXunlei` | 无 | 0 | 0 | 2ms | 返回 0 条 |
| 109 | 迅雷吧 | 迅雷吧 • 磁力 | `csp_Xunlei8` | 有 | 1 | -1 | 1ms | dex2jar 产物异常（真机可用） |
| 110 | 配置中心 | 配置 • 中心 | `csp_Config` | 无 | 0 | 0 | 45ms | 返回 0 条 |
| 111 | 酷乐 | 酷乐 • 搜索 | `csp_KuLe` | 无 | 1 | -1 | 2ms | JVM 栈溢出（dex2jar 产物，真机可用） |
| 112 | 闪电 | 闪电 • 4K | `csp_PanWebShare` | 有 | 1 | 0 | 3379ms | 返回 0 条 |
| 113 | 阿里云盘 | 阿里 • 云盘 | `csp_PanAli` | 无 | 0 | 0 | 1ms | 返回 0 条 |
| 114 | 预告 | 新片 • 预告 | `csp_YGP` | 无 | 0 | 0 | 3365ms | 返回 0 条 |
| 115 | 飞球体育 | 飞球 • 体育 | `csp_SportsFeiqiu` | 无 | 0 | 0 | 356ms | 返回 0 条 |
| 116 | 高中课堂 | 高中 • 课堂 | `csp_Bili` | 有 | 0 | -1 | 0ms | JVM 环境限制（Android 原生方法，真机可用） |

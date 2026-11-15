# jar 源支持（TVBox `type: 3`）— JAR_SPIDER

TVBox 配置里的 `{"type":3,"api":"csp_Xxx","ext":"…"}` 这种源（肥猫 / 饭太硬 /
二小那类）现在能用了：原生侧用 `DexClassLoader` 加载 `spider.jar`，反射调
`com.github.catvod.crawler.Spider` 的接口，把返回的 TVBox JSON 转成我们自己的
`VideoCard` / `VideoDetail` / `PlayInfo`，页面完全不感知差异。

`type: 4`（python 脚本）仍然跳过。

## 1. 目录与文件

| 位置 | 作用 |
| --- | --- |
| `android_src/api_stub/java/com/github/catvod/**` | 自建的 `Spider` 基类源码（官方 api.jar 拿不到时的等价实现） |
| `android_src/libs/api.jar` | 上面那份源码的编译产物（`Spider` / `SpiderNull` / `SpiderDebug` / `net.OkHttp` / `utils.Json` / `utils.Util`） |
| `android_src/libs/okhttp3 okio gson jsoup commons-*` | jar 源运行时常用的第三方库 |
| `android_src/kotlin/.../JarSpiderLoader.kt` | 类加载 + 反射调用 + 超时 / 兜底 + 实例缓存 |
| `android_src/kotlin/.../JarSpiderPlugin.kt` | `MethodChannel('fantasy_tv/spider')`、jar 下载 / md5 / 卸载 |
| `lib/services/jar_spider.dart` | Dart 侧通道封装 + TVBox JSON → 模型的转换 |
| `tools/patch_jar_spider.py` | 构建注入：拷 jar、加 Gradle 依赖、注册通道、写 R8 规则 |
| `tools/build_api_jar.py` | 重新生成 `api.jar` |
| `tools/build_sample_jar.py` + `tools/spider_sample/` | 示例 spider（自检 + 真机验证用） |

## 2. 为什么自建 api.jar

`com.github.catvod.crawler.Spider` 是 jar 源的基类，jar 里的子类靠继承它运行。
官方 api.jar 在这个构建环境里取不到（GitHub 直连不通，jsDelivr 上的
TVBoxOSC / FongMi 仓库也没有这个 jar），所以自建一份**接口完全一致**的实现：

- 包名 / 类名 / 方法名 / 参数类型 / 返回类型与官方相同；
- 所有方法都有**默认实现**（返回空串 / `false` / `null`），因为 jar 通常只
  override 其中几个，还会 `super.init(...)`；
- `categoryContent(tid, pg, filter, extend)` 的 `pg` 是 **String**（页码），
  这是线上 jar 的编译签名；
- 附带 `OkHttp` / `Json` / `Util` / `SpiderDebug`，这些是 jar 里最常见的工具类。

拿到官方 api.jar 后，直接覆盖 `android_src/libs/api.jar` 即可，Kotlin 侧不用改。

## 3. 加载与调用链路

```
Dart MethodChannel('fantasy_tv/spider')
  └─ JarSpiderPlugin（后台线程池 → 主线程回话）
       └─ JarSpiderLoader（单线程 worker，25s 超时，全异常兜底）
            ├─ DexClassLoader(jar, dex/<md5>, parent = context.classLoader)
            │    └─ 父加载器里有 api.jar，所以 jar 的子类能继承 Spider
            ├─ 类名解析：全限定名 → com.github.catvod.spider.<api> →
            │   去掉 csp_ 前缀 → 扫 jar 条目按简单类名匹配
            ├─ newInstance + init(context, ext)（ext 变了重新 init）
            └─ 反射调用（按名字 + 参数个数匹配，按形参类型做强制转换）
```

要点：

- **绝不把异常抛给 Flutter**：所有调用返回 JSON 字符串，失败是
  `{"error":"…","code":"…"}`（`no_jar` / `no_class` / `no_method` /
  `init_failed` / `call_failed` / `empty` / `timeout` / `oom`）。
- **线程**：jar 里基本都是同步网络请求，必须离开 UI 线程；加载器内部是单线程
  串行，避免 jar 的静态状态互相污染。
- **签名宽容**：`searchContent` 两参 / 三参两个版本都认；`categoryContent`
  第二参按目标形参自动在 String / boolean 之间转换。
- **dex 缓存**：`filesDir/dex/<jar md5>`，md5 变了换目录并重建加载器 ——
  否则会命中上一次的 odex，改了 jar 也还是旧类。
- **jar 必须只读**：Android 14 起 `DexClassLoader` 只吃 `0444` 的文件，
  加载前先 chmod（见第 8 节）。

## 4. jar 从哪来

1. **下载安装**：片源管理 → jar 插件 → 安装 jar，填 `spider.jar` 的 http(s)
   地址（可选 md5 强校验）；落盘到 `filesDir/spiders/<md5>.jar`。
2. **本地文件**：同一入口填 `file:///sdcard/Download/spider-demo.jar`。
3. **内置**：把 jar 放到仓库 `assets/spiders/spider.jar`，构建脚本会拷进
   `android/app/src/main/assets/spiders/`，没下载过时自动解出来用。

卸载会删掉 `filesDir/spiders/` 下的 jar 与记录。

## 5. 数据怎么变成我们的模型

TVBox 的 `vod_*` 字段与苹果CMS 同构，所以转换极薄：

| TVBox 接口 | 返回 | 我们的转换 |
| --- | --- | --- |
| `homeContent` | `{"class":[…],"list":[…]}` | `JarSpider.classesOf` → 分类；`cardsOf` → `VideoCard` |
| `categoryContent` | `{"page":1,"pagecount":N,"list":[…]}` | `cardsOf` |
| `searchContent` | `{"list":[…]}` | `cardsOf` |
| `detailContent` | `{"list":[{…,"vod_play_from","vod_play_url"}]}` | `parseLines`（cms_source）→ `CmsApi.detailOf` |
| `playerContent` | `{"parse":0,"url":"…","header":{…}}` | `playOf` → `PlayInfo`（`parse!=0` 且不是直链时抛「需要网页解析」） |

分类映射：我们的 7 个频道键 ↔ jar 自己的 `type_id`，由 `homeContent` 的
`class` 列表按名字用 `channelKeyOfClassName` 归一化后匹配。

## 6. 真机验证（不需要真的肥猫配置）

```bash
# 1) 生成示例 jar（仓库里已经带了一份：tools/spider_sample/spider-demo.jar）
python3 tools/build_sample_jar.py --selftest

# 2) 推到手机
adb push tools/spider_sample/spider-demo.jar /sdcard/Download/

# 3) App：设置 → 片源管理 → jar 插件 → 安装 jar
#    地址填 file:///sdcard/Download/spider-demo.jar
#    （或把 jar 传到任意 http 服务器，这里填 https 地址）

# 4) 我的源 → 添加：类型「jar 插件 (3)」，api 填 csp_Demo，ext 留空

# 5) 搜索「自检」→ 应出现「幻想起点 · 自检片」，
#    详情页有两条线路（演示A / 演示B），点播放拿到 example.com 的地址
#    （示例数据故意返回 example.com，能拿到说明链路通了，播不出来是正常的）

# 6) 排障
adb logcat -s FXSpider
```

真实源（肥猫 / 饭太硬 / 二小）：把它们的 `spider.jar` 地址填进第 3 步，然后把
TVBox 配置里的 `sites` 里 `type: 3` 的项粘进「TVBox 导入」即可（`api` 与 `ext`
会一起带进来）。

## 7. 已知限制

- `playerContent` 返回 `parse: 1` 且不是直链时需要 WebView 嗅探，本实现没有
  嗅探器 —— 直接抛「这条线路需要网页解析，换一条线路试试」。
- 第三方库是 okhttp **3.12.13**（纯 Java 分支）。若某个 jar 明确用了 okhttp 4.x
  的 Kotlin 扩展（`toRequestBody` / `toMediaType`），把它换成 Gradle 依赖
  `com.squareup.okhttp3:okhttp:4.12.0`，并注意别和其他插件重复。
- 自建 api.jar 少了官方那些冷门 `bean` / `utils` 类；命中时会得到
  `{"error": … "code":"no_method" / "call_failed"}`，换官方 api.jar 即可。
- 线路名互为前缀时（`demo` / `demo2`），`models.dart` 的 `mergeLines` 会合成
  一条 —— 这是 App 对 CMS 线路的既有规则，jar 源同样适用。
- R8：release 默认没开 minify；万一将来开启，`proguard-rules.pro` 里已经
  keep 了 `com.github.catvod.**` / okhttp / gson / jsoup（反射用的类）。

## 8. Android 14 的「Writable dex file」（DEX_READONLY）

v1.0.352 在 Android 14+ 真机上的报错：

```
java.lang.SecurityException: Writable dex file
'/data/user/0/com.huanxiang.fantasy_tv/files/spiders/cbe016eb…jar'
is not allowed.
```

**根因**：API 34 起 ART 打开 dex 前会看 `st_mode & 0222`，只要 owner /
group / other 任一可写就拒加载。我们下载 / 解 assets 出来的 jar 天生是
`0644`，所以「下载成功、md5 通过、自检必失败」。

**修法**：落盘之后、交给 `DexClassLoader` 之前把文件钉成 `0444`。
实现集中在 `JarPermissions.kt`（新文件），两侧的调用点：

| 场景 | 处理 |
| --- | --- |
| 下载 / 本地文件 / 内置 jar 安装（`adopt`） | 落盘后 `sealJar(target, strict = true)`，34+ 上 chmod 失败直接报 `jar_not_readonly` |
| 从 assets 释放（`extractAssetJar` / `installBundled`） | 写之前 `unseal`，写完 `sealJar` |
| 每次取到当前 jar（`currentJar`） | 顺手 chmod：老版本装下的 `0644` 自动修好，用户不用重装 |
| 加载前（`JarSpiderLoader.classLoader`） | `ensureJarReadOnly()` 打日志 + 仍失败时 chmod 后重试；ART 还拒就报 `jar_not_readonly` |
| 重新下载（`download.tmp`） | 删旧 tmp 前 `unseal` |
| 覆盖写固定文件名的 `bundled.jar` | 写之前 `unseal`（否则第二次「用内置」EACCES） |
| 卸载 / 清 dex 缓存 | 先 `unseal` / `makeDirWritable`，再删 |
| dex 输出目录 `dex/<md5>` | **相反**：必须 0700 可写（ART 要往里写 odex），只确保可写，绝不 chmod 只读 |

真机确认方式（一眼看权限）：

```
adb logcat -s FXSpider | grep JarSpider
I FXSpider: [JarSpider] jar path=/data/user/0/com.huanxiang.fantasy_tv/files/spiders/cbe016eb….jar writable=false perms=444
```

自检结果里也带 `jarPerms` / `jarWritable`（`444` / `false` 才是合格），
失败时页面文案是「jar 权限不对 … 重装一次 jar 源插件即可自动改正」。

**本机验证**（不需要真机、不需要 Android SDK）：

```bash
# 1) 真实 chmod 行为：非 root 跑，验证 444 之后 canWrite=false、覆盖写被拒、
#    makeWritable 之后又能写；会跑两遍（纯 JVM / 带假 android.system.Os 的反射路径）
bash tools/check_jar_perms.sh

# 2) 静态门禁（CI 里必跑）：chmod 必须在 DexClassLoader 之前、
#    更新/卸载前必须改回可写，删一行就红
python3 tools/check_jar_readonly.py
```

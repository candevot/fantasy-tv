# android_src/libs —— jar 源（TVBox type 3）运行期依赖

这里放的是 `JarSpiderLoader` 用 `DexClassLoader` 加载 csp_XXX.jar 时需要
**已经存在于 App 的 classpath 里**的那些类。构建时由
`tools/patch_jar_spider.py` 整个目录拷到 `android/app/libs/`，再由
`app/build.gradle(.kts)` 的 `implementation(fileTree("libs"))` 打进 APK。

| 文件 | 用途 | 来源 |
| --- | --- | --- |
| `api.jar` | `com.github.catvod.crawler.Spider` 基类 + `SpiderDebug` / `SpiderNull` / `com.github.catvod.net.OkHttp` / `com.github.catvod.utils.Json` / `Util` | **自建**，源码在 `android_src/api_stub/java/`，用 `python3 tools/build_api_jar.py` 重新生成（class version 55 / Java 11） |
| `okhttp-3.12.13.jar` | jar 源里的 `okhttp3.*` 同步请求 | Maven Central |
| `okio-1.17.5.jar` | okhttp3 3.x 的 IO 依赖 | Maven Central |
| `gson-2.10.1.jar` | jar 源里的 `com.google.gson.*` | Maven Central |
| `jsoup-1.16.2.jar` | 网页类源的 HTML 解析 | Maven Central |
| `commons-lang3-3.12.0.jar` | `StringUtils` / `DateUtils` 等 | Maven Central |
| `commons-io-2.11.0.jar` | `IOUtils` / `FileUtils` | Maven Central |

## 换成官方 api.jar

官方 api.jar（FongMi/TV 或 TVBoxOSC 的 `catvod` 产物）拿到后直接覆盖
`api.jar` 即可 —— 包名、类名、方法签名与自建版本一致，Kotlin 侧不用改。
自建版本少的是官方那些 `bean` / `utils` 里更冷门的类，行为差异只在
「某个源用到这些冷门类」时出现，加载器会把这类失败兜成 `{"error": ...}`。

## 注意

- 这些 jar 会被 D8 打进 APK，**不要**再放进 `android/app/libs/`（那里由脚本拷）。
- 如果之后项目引入的 Flutter 插件也带 okhttp / gson，Gradle 会报
  `Duplicate class okhttp3.…`，那时把这里对应的 jar 删掉、改成
  `implementation("com.squareup.okhttp3:okhttp:…")` 即可（脚本注释里有说明）。
- okhttp 3.12.x 是纯 Java 分支（无 Kotlin 运行时依赖）。如果某个源明确用了
  okhttp 4.x 的 Kotlin 扩展（`toRequestBody` / `toMediaType`），把它需要的
  4.x 换成 Gradle 依赖并在 `android_src/api_stub` 里同步改 `OkHttp` 的用法。

# 后台播放（MediaSession）崩因分析与验收

> 事故：`MediaSession` 升级后「**任意剧点播放就闪退**」，紧急用
> `BG_SERVICE_ENABLED = false` 把服务启动整段旁路（能播，但没后台保活、
> 没有系统媒体卡片）。本文是根因、修法、验证证据和真机验收清单。
>
> 结论先行：崩点不在我们写的那几行 `PlaybackService.start()`，而在
> **media3 库内部自己调 `startForeground()` 的那一句**。它抛出的异常不在
> 我们的调用栈上，所以之前那圈 `try/catch` 再多也接不住 —— 那才是「必崩」
> 的原因。修法是：**通知继续交给 media3 画，前台由我们自己带类型进，
> 每一次系统调用都在 `BgSafe.run`（runCatching）里**。

---

## 1. 崩因：异常从哪一行、在哪个线程、抛了什么

### 1.1 触发链（媒体3 1.4.1，源码 + 字节码双重确认）

```
open() 里 prepare 下发                       ExoPlayerPlugin.kt:2044  startBackground()
  → PlaybackService.start()                  PlaybackService.kt（context.startService）
  → onStartCommand(ACTION_START)
  → ensureSession() → createSession()
  → addSession(session)                      ← 从这一刻起，media3 接管「要不要进前台」
─────────────────────────── 之后全在 media3 内部 ───────────────────────────
  → 播放器第一次 BUFFERING（playWhenReady=true）
  → MediaSessionService.MediaSessionListener.onEvents(...)      MediaSessionService.java:356
  → MediaSessionService.onUpdateNotificationInternal(...)       MediaSessionService.java:614
  → MediaNotificationManager.startForeground(...)               MediaNotificationManager.java:365
  → Util.setForegroundServiceNotification(..., FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK, "mediaPlayback")
  → Util$Api29.startForeground(...)  ← 这里抛
```

`Util$Api29.startForeground` 的字节码（`media3-common:1.4.1`，`javap -c`）：

```
  0: aload_0 ... invokevirtual  android/app/Service.startForeground:(ILandroid/app/Notification;I)V
  7: goto 40
 10: astore 5                      // catch java.lang.RuntimeException
 12: ldc  "Util"
 21: ldc  "The service must be declared with a foregroundServiceType that includes"
 37: aload 5
 39: athrow                        // ← 记完日志**原样 rethrow**
```

而上一层的吞异常范围（`MediaSessionService.java:614-631`）只有：

```java
    } catch (/* ForegroundServiceStartNotAllowedException */ IllegalStateException e) {
      if ((SDK_INT >= 31) && Api31.instanceOfForegroundServiceStartNotAllowedException(e)) {
        onForegroundServiceStartNotAllowedException();   // ← 只有这一种会被吞
        return false;
      }
      throw e;                                            // ← 其余原样抛回主线程
    }
```

也就是说 **只有一种异常是安全的**：

| 异常 | 继承关系 | media3 行为 | 结果 |
|---|---|---|---|
| `ForegroundServiceStartNotAllowedException`（Android 12+ 后台起前台服务） | `IllegalStateException` | 吞掉，回调 `Listener` | 安全（我们只记日志） |
| `MissingForegroundServiceTypeException`（Android 14+ 声明里没有 `mediaPlayback`） | `ServiceStartNotAllowedException` → `IllegalStateException` | **不进那个 if，rethrow** | **FATAL EXCEPTION: main** |
| `SecurityException`（Android 14+ 缺 `FOREGROUND_SERVICE_MEDIA_PLAYBACK`；部分 ROM 缺 `POST_NOTIFICATIONS` 也抛） | `RuntimeException`（不是 `IllegalStateException`） | **catch 不到，直接上抛** | **FATAL EXCEPTION: main** |

调用栈全在库内部（`Service` 主线程的播放器回调里），**我们的 try/catch 不在栈上**，
所以 `createSession()` 外面那圈 `try` 对这条路径毫无作用 —— 这就是「点任意剧
必闪退」而不是「偶发」的原因：每次起播都必然走一次「第一次进前台」。

### 1.2 逐个调用点审计（改前 / 改后）

线程列里「主」= 主线程（`Looper.getMainLooper()`），任何未捕获异常都是
`FATAL EXCEPTION: main` = 闪退。

| # | 调用点（改后行号） | 线程 | 前置条件 | 可能抛 | 改前是否捕获 | 改后 |
|---|---|---|---|---|---|---|
| 1 | `context.startService(...)`（`PlaybackService.start`，companion） | 主（MethodChannel） | 组件已在 manifest 声明；App 在前台 | `IllegalStateException`（后台启动限制）、`SecurityException`（ROM 拦截） | 是（try/catch，日志 `FxBg`） | `BgSafe.run("PlaybackService.start")`，日志 `FxPlay` |
| 2 | **media3 内部 `startForeground`**（上面的触发链） | 主 | Android 14+：manifest `foregroundServiceType=mediaPlayback` + `FOREGROUND_SERVICE_MEDIA_PLAYBACK`；Android 13+ 通知权限；App 允许起前台服务 | `MissingForegroundServiceTypeException`、`SecurityException` | **否（库内部，接不住）** | **不再发生**：`super.onUpdateNotification(session, false)` 永远不带 `true`（`PlaybackService.kt:635`） |
| 3 | `MediaSession.Builder(this, SessionPlayer(...)).build()`（`createSession`） | 主（`ensureSession` 里校验，见 #6） | 播放器存在；线程有 Looper；同 ID session 不重复 | `IllegalStateException`（无 Looper / 重名 ID / `setSessionActivity` 不是 Activity 型 PendingIntent） | 是 | 仍是 try/catch，另加主线程门禁 |
| 4 | `addSession(session)`（`createSession`） | 主 | session 已 build | `IllegalStateException` | 是（同一 try） | 不变 |
| 5 | `DefaultMediaNotificationProvider.Builder(...).build()` + `setSmallIcon`（`installNotificationProvider`，:601） | 主（`onCreate`） | 渠道名字符串资源、单色图标资源存在 | `Resources.NotFoundException`、`IllegalArgumentException` | 是 | `BgSafe.run("installNotificationProvider")` |
| 6 | `MediaSession.Builder` 所在函数入口（`ensureSession`，:841） | **任意** | `Looper.myLooper() == main` | `IllegalStateException: Can't create handler inside thread that has not called Looper.prepare()` | **否**（`ensureSession` 可被背景线程调） | **转主线程 + 返回现有 session** |
| 7 | 我们自己 `startForeground(id, notif, FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)`（`enterForegroundGuarded`，:664） | 主 | `BgGate.checkForeground() == NONE` | 上面那三类 | —— | `BgSafe.run("startForeground(type=mediaPlayback)")`，显式带类型 |
| 8 | `stopForeground(...)`（`exitForegroundGuarded` :700 / `onDestroy` :781） | 主 | 已进前台 | `IllegalArgumentException`（DETACH 时通知已被移除） | 部分 | `BgSafe.run(...)` |
| 9 | `PackageManager.getServiceInfo(...)` / `checkSelfPermission`（`readEnv`，:211） | 主 | —— | `NameNotFoundException`、`SecurityException` | —— | `BgSafe.value(...)`，失败按 `BgEnv.UNKNOWN`（fail-closed） |
| 10 | `PowerManager.newWakeLock().acquire()`（`onCreate`） | 主 | 电量优化白名单 | `SecurityException` | 是 | 不变（已 try/catch） |
| 11 | `session.release()` / `removeSession()`（`releaseSessionQuietly`） | 主 | 先于 `player.release()` | `IllegalStateException`（在已释放 player 上读状态） | 是 | 不变；`dispose()` 里顺序已固定 |

### 1.3 其它四条「看起来像根因」的排查结论

| 用户列的嫌疑 | 结论 | 证据 |
|---|---|---|
| ① Android 12+ 后台起前台服务 | **不是本次主因**，而且已被 media3 吞掉 | `MediaSessionService.java:624` 只吞 `ForegroundServiceStartNotAllowedException`；我们另加 `requireForeground` 门禁 |
| ② 通知权限未授予 | **是真风险**（部分 ROM 抛 `SecurityException`，那条没人吞） | `BgGate.NO_NOTIFICATION_PERMISSION` 直接不调 `startForeground`（需求③） |
| ③ Android 14 前台服务类型 | **最可能的直接触发者**（`MissingForegroundServiceTypeException` 被 rethrow） | `Util` 的 rethrow 字节码 + 只对 `ForegroundServiceStartNotAllowedException` 开豁免 |
| ④ MediaSession 线程 | **改造前确实没校验**（`ensureSession` 可被背景线程调） | 现在 `ensureSession` 第一段就是主线程校验（:841） |
| ⑤ 绑定顺序 / ⑥ 通知 Provider / ⑦ 未捕获 | 表 1.2 逐条覆盖 | —— |

### 1.4 manifest 这一侧是干净的（已核对）

按 CI 同款步骤在本地重新生成了一遍清单（`flutter create` + `tools/patch_manifest.py`）：

```
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<service android:name=".PlaybackService"
         android:foregroundServiceType="mediaPlayback"
         android:exported="false">
    <intent-filter>
        <action android:name="androidx.media3.session.MediaSessionService" />
```

也就是说 Android 14+ 的两条硬前置（类型 + `FOREGROUND_SERVICE_MEDIA_PLAYBACK`）
在包里是齐的。那么这台 Redmi（Android 17 / targetSdk 36）上真正被踩到的，
只剩运行时那两条：

* **通知权限**：Android 13+ 未授权时部分 ROM（MIUI / HyperOS 尤甚）会在
  `startForeground` 里抛 `SecurityException` —— media3 只 catch
  `IllegalStateException` 的一个子类，这条直接上抛；
* **ROM 自带的前台服务策略**：Xiaomi 对 `mediaPlayback` 有额外校验
  （后台起 / 通知被关 / 电池策略），抛出来的同样是没人接的 `SecurityException`。

不管具体是哪一条，结论都一样：**这条链上的异常没有任何人在接**。新结构把
`createNotification` / 异步封面回调 / `startForeground` 全部挪进
`BgSafe.run` 的栈帧里，所以哪一条触发都只是打一行 `FxPlay` 日志，
播放继续 —— 而且那行日志会把 `sdk/fg/notif/types/mediaPlaybackPerm`
五个值都打出来，下次一眼就能看出是哪一项。

> 取证命令（下次任何设备再出问题，先拉这一条就能定位到具体缺哪项）：
> `adb logcat -s FxPlay FxBg FxCrash`
> 正常：`后台播放自检：sdk=37 fg=true notif=true types=0x2 mediaPlaybackPerm=true -> NONE`
> 异常：同一行里 `-> FOREGROUND_TYPE_NOT_DECLARED / NO_MEDIA_PLAYBACK_PERMISSION / NO_NOTIFICATION_PERMISSION`

---

## 2. 修法（对应需求 ①–⑥）

| 需求 | 落地 | 位置 |
|---|---|---|
| ① 所有系统调用 `runCatching`，失败只记 `Log.w("FxPlay", ...)` | 新增 `BgSafe.run/value`（唯一异常出口，内部 `Log.w(BgSafe.TAG = "FxPlay", ...)`）；后台链路的失败日志全部改走它 | `PlaybackService.kt:1076`、`ExoPlayerPlugin.kt:698/721` |
| ② Android 14 显式带类型 | 前台由我们自己进：`startForeground(id, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)`；**不再让 media3 进前台** | `PlaybackService.kt:664`、`:635` |
| ③ 通知权限未授予：先不 startForeground，播放不受影响，授予后补起 | `BgGate.checkForeground()` 返回 `NO_NOTIFICATION_PERMISSION` → 一次都不调；媒体卡片由 media3 照常 `notify`（权限给了系统才显示）；下一次播放事件自动重试 | `BgGate.kt:100` |
| ④ session 主线程创建 + release 先于 player | `ensureSession()` 开头校验 `Looper.myLooper() != Looper.getMainLooper()` → post 主线程；`dispose()` 里 `releaseSessionNow()` 在 `player?.release()` 之前 | `PlaybackService.kt:841`、`ExoPlayerPlugin.kt:511/525` |
| ⑤ 只在前台起服务 | `startBackground(requireForeground)`：`open()` 路径不要求（一定在前台）；`onIsPlayingChanged` 路径要求 `RunningAppProcessInfo.importance == IMPORTANCE_FOREGROUND` | `ExoPlayerPlugin.kt:698`、`:1470`、`PlaybackService.kt:196` |
| ⑥ 失败不影响播放 | 上面所有失败路径只写日志/降级（不闪退、不暂停、不报错）；`BG_SERVICE_ENABLED` 仍作为最后一档逃生开关（现在 = `true`） | `ExoPlayerPlugin.kt:681` |

### 2.1 关键设计：通知归 media3，前台归我们

```
media3 的 provider 画通知（封面/片名·第N集/进度/上下一集不变）
        ↑
RecordingNotificationProvider 包一层：记下 Notification + 接管异步回调
        ↑
onUpdateNotification(session, /* startInForegroundRequired = */ false)   ← 永远 false
        ↑
enterForegroundGuarded(notification)
   ├─ BgGate.checkForeground()  三道闸（类型 / 权限 / 通知）
   ├─ startForeground(id, notification, FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
   └─ BgSafe.run(...)           失败只记 FxPlay 日志
```

为什么必须这样：只要把 `startInForegroundRequired = true` 交给 media3，
它就会在库内部自己 `startForeground()`，那段代码**不可能**被我们的
try/catch 覆盖（见 §1.1）。现在这条路径不存在了，剩下的每一句系统调用都在
`BgSafe.run` 里 —— 这就是「绝不闪退」的结构保证，而不是「多包了层 try」。

### 2.2 改动文件

| 文件 | 改动 |
|---|---|
| `android_src/kotlin/.../BgGate.kt` | **新增**。纯逻辑门禁（不 import android），`BgEnv` / `BgBlock` / `checkServiceStart` / `checkForeground` / `describe`；采样失败按「Android 14 + 什么都没声明」fail-closed |
| `android_src/kotlin/.../PlaybackService.kt` | 覆写 `onUpdateNotification`（:635）只发通知不进前台；新增 `enterForegroundGuarded`（:664）/ `exitForegroundGuarded`（:700）/ `RecordingNotificationProvider`（:1110）/ `BgSafe`（:1076）；`onCreate` 增加前台服务自检日志（:559）；`ensureSession` 主线程门禁（:841）；companion 增加 `isAppInForeground` / `readEnv` / `gateServiceStart`（:196/211/225）；所有失败日志改 `FxPlay` |
| `android_src/kotlin/.../ExoPlayerPlugin.kt` | `BG_SERVICE_ENABLED = true`（:681）；`startBackground(requireForeground)` 走门禁（:698）；`onIsPlayingChanged` 用 `requireForeground = true`（:1470）；`stopBackground` 走 `BgSafe`（:721） |
| `tools/check_bg_foreground.py` | **新增**。结构门禁：startForeground 必须在 `BgSafe.run` 内且带类型、不许把 `true` 交给 media3、MediaSession 只在主线程建、dispose 顺序、BG 开关、文档存在 |
| `tools/bg_gate_jvm_test.kt` + `tools/check_bg_gate.sh` | **新增**。21 项 JVM 单测：Android 13/14/15/17 各档 + fail-closed |
| `tools/check_kotlin_compile.sh` | **新增**。kotlinc 全量编译 `android_src/`（本机 / CI 有 jar 时） |
| `.github/workflows/build.yml` | MediaSession 步骤的反向门禁从「禁止 startForeground」改成「必须经 BgSafe + 带类型」；新增 `BG_GATE` 步骤 |
| `docs/BACKGROUND-PLAYBACK.md` | 本文 |

---

## 3. 验证证据（可重跑）

| 项 | 命令 | 结果 |
|---|---|---|
| 结构门禁 | `python3 tools/check_bg_foreground.py` | `BG_GATE 静态门禁全绿` |
| 门禁单测 | `bash tools/check_bg_gate.sh` | `BG_GATE 单测全绿（21 项）` |
| Kotlin 编译 | `FX_KT_LIBS=<media3 等 jar 目录> bash tools/check_kotlin_compile.sh` | `Kotlin 编译通过：15 个源文件 -> 58 个 class` |
| Dart 静态检查 | `flutter analyze --fatal-infos` | 见 CI 日志 |
| Dart 单测 | `flutter test` | 见 CI 日志 |
| APK 门禁 | `python3 tools/verify_apk.py <apk>` | 见 CI 日志 |

> 说明：CI runner 上没有 kotlinc / media3 jar，这一步会打印 `SKIP`（不判红）；
> Kotlin 真正的编译门禁仍然是 Gradle（APK 构建成功 = 编译通过）。

---

## 4. 真机验收（照着点，10 分钟）

前提：装上本轮 CI 的 APK（版本号见 Release 页）。

1. **不闪退（核心回归）**：首页点任意一部剧 → 点任意一集播放 → 画面正常出来，
   App 不退出。重复 3 部不同的剧 / 3 条不同线路。
2. **媒体卡片**：出画面 3 秒后下拉通知栏 → 出现媒体卡片，含封面、片名、
   「第N集 · 线路名」、进度条、上一集 / 播放暂停 / 下一集。
3. **切后台继续播**：按 Home → 声音继续；从最近任务里划掉界面 → 声音仍继续
   （`adb shell dumpsys activity services com.huanxiang.fantasy_tv | grep -i playback`
   能看到 `PlaybackService` 且 `isForeground=true`）。
4. **锁屏 / 耳机 / 车机**：锁屏出现媒体控件，可播放暂停、上一集、下一集；
   蓝牙耳机按播放暂停有反应；点下一集后回到 App，播放页集号确实变了。
5. **集数边界**：第一集不显示「上一集」，最后一集不显示「下一集」，电影两个都不显示。
6. **通知权限关掉也不崩**：系统设置 → 应用 → 幻想影视 → 通知 → 关闭 →
   回到 App 重新播放：**不闪退**，只是没有媒体卡片；再把通知打开 → 下一次播放
   卡片自己回来。
7. **暂停语义**：暂停后通知还在，但进程不再占前台（`dumpsys` 里
   `isForeground=false`）；继续播放又变回 `true`。
8. **收尾干净**：播放到结尾 / 退出播放页 / 通知里点关闭 →
   通知消失，`dumpsys activity services ... | grep -i playback` 为空（不留僵尸服务）。
9. **日志核对**（连电脑 `adb logcat -s FxPlay FxBg FxCrash`）：
   - `前台服务自检：sdk=37 fg=true notif=true types=0x2 mediaPlaybackPerm=true -> NONE`
   - `已进前台（mediaPlayback）：2817`
   - 不应出现 `不进前台（播放继续）：...`（出现说明该机型某一项不满足，
     把那行发出来即可定位）
10. **万一还闪退**：`adb shell run-as com.huanxiang.fantasy_tv cat files/crash.log`
    （`FxCrash` 写的完整栈），把最后一段 `FATAL EXCEPTION` 发回来。

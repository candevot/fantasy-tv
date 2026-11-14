#!/usr/bin/env python3
"""把 CI 生成的 MainActivity / 主题补成 edge-to-edge，保留 Android 8/9
写公共 Download 目录所需的旧版存储权限请求，并注册 DLNA 投屏用的
WifiManager.MulticastLock 通道（fantasy_tv/cast）。

Flutter 3.32 模板 MainActivity 的写法是 `class MainActivity : FlutterActivity()`，
冒号两侧都有空格；旧的内联 patch 只匹配 `MainActivity: FlutterActivity()`，
升级后会导致 patch 静默失效，check_android_compat 才会报错。

用法（仓库根目录）：python3 tools/patch_edge_to_edge.py
"""

import glob
import io
import os
import re
import sys

STYLE = 'android/app/src/main/res/values/styles.xml'

STYLE_BLOCK = '''<style name="NormalTheme" parent="@android:style/Theme.Light.NoTitleBar">
        <item name="android:windowBackground">?android:colorBackground</item>
        <item name="android:statusBarColor">@android:color/transparent</item>
        <item name="android:navigationBarColor">@android:color/transparent</item>
        <item name="android:windowDrawsSystemBarBackgrounds">true</item>
        <item name="android:windowLightStatusBar">true</item>
        <item name="android:windowLightNavigationBar">true</item>
        <item name="android:windowLayoutInDisplayCutoutMode">shortEdges</item>
        <item name="android:windowTranslucentStatus">false</item>
    </style>'''

IMPORTS = (
    'import androidx.core.view.WindowCompat',
    'import androidx.core.app.ActivityCompat',
    'import androidx.core.content.ContextCompat',
)

ORIENTATION_FUNC = '''
    // 播放器方向：Flutter 的 SystemChrome.setPreferredOrientations 会被引擎
    // 映射成 USER_LANDSCAPE，遵守系统「自动旋转」开关；竖屏锁定下播放器就
    // 转不到横屏。这里直接用 SENSOR_LANDSCAPE / PORTRAIT，与腾讯视频等
    // 播放器一致，不看系统旋转锁。
    private fun registerOrientationChannel(
        flutterEngine: io.flutter.embedding.engine.FlutterEngine
    ) {
        io.flutter.plugin.common.MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "fantasy_tv/orientation"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "sensorLandscape" -> {
                    try {
                        requestedOrientation =
                            android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("orientation", e.message, null)
                    }
                }
                "portrait" -> {
                    try {
                        requestedOrientation =
                            android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("orientation", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

'''

ORIENTATION_CALL = '''
        registerOrientationChannel(flutterEngine)'''

DISPLAY_FUNC = """
    // 亮度 / 音量：直接操作 Activity 窗口与 AudioManager。
    //
    // 原来亮度走 screen_brightness 的平台接口、音量走 volume_controller，
    // 两者都可能静默失败（异常被 Dart 侧 catch 吃掉），用户看到的就是
    // 「拖亮度没反应、拖音量有延迟」。
    // 这里自己实现，不依赖任何第三方插件的注册时机：
    //   · 亮度改的是本窗口的 screenBrightness，退出播放页恢复系统值
    //   · 音量直接 setStreamVolume(flags=0)，不弹系统音量条，没有延迟
    private fun registerDisplayChannel(
        flutterEngine: io.flutter.embedding.engine.FlutterEngine
    ) {
        io.flutter.plugin.common.MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "fantasy_tv/display"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getBrightness" -> {
                    val v = window.attributes.screenBrightness
                    result.success(if (v < 0f) -1.0 else v.toDouble())
                }
                "setBrightness" -> {
                    val v = call.argument<Double>("value")
                    if (v == null) {
                        result.success(false)
                    } else {
                        try {
                            window.attributes = window.attributes.apply {
                                screenBrightness = v.toFloat().coerceIn(0.01f, 1f)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("brightness", e.message, null)
                        }
                    }
                }
                "resetBrightness" -> {
                    try {
                        window.attributes = window.attributes.apply {
                            screenBrightness = android.view.WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("brightness", e.message, null)
                    }
                }
                "getVolume" -> {
                    try {
                        val am = getSystemService(android.content.Context.AUDIO_SERVICE)
                            as android.media.AudioManager
                        val max = am.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)
                        val cur = am.getStreamVolume(android.media.AudioManager.STREAM_MUSIC)
                        result.success(if (max > 0) cur.toDouble() / max else 0.0)
                    } catch (e: Exception) {
                        result.error("volume", e.message, null)
                    }
                }
                "setVolume" -> {
                    val v = call.argument<Double>("value")
                    if (v == null) {
                        result.success(false)
                    } else {
                        try {
                            val am = getSystemService(android.content.Context.AUDIO_SERVICE)
                                as android.media.AudioManager
                            val max = am.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC)
                            val idx = (v.coerceIn(0.0, 1.0) * max).toInt()
                            am.setStreamVolume(android.media.AudioManager.STREAM_MUSIC, idx, 0)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("volume", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

"""

DISPLAY_CALL = """
        registerDisplayChannel(flutterEngine)"""

STORAGE_FUNC = """
    // 「所有文件访问」：Android 11+ 直接写公共 Download 目录必须这个权限，
    // 否则只能落到 Android/data/<包名>/… 里，文件管理器看不到。
    // 设置里没开时，下载会自动回退到应用专属目录（设置页会提示）。
    private fun registerStorageChannel(
        flutterEngine: io.flutter.embedding.engine.FlutterEngine
    ) {
        io.flutter.plugin.common.MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "fantasy_tv/storage"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isManager" -> {
                    val ok = if (android.os.Build.VERSION.SDK_INT >= 30) {
                        android.os.Environment.isExternalStorageManager()
                    } else true
                    result.success(ok)
                }
                "requestManager" -> {
                    try {
                        if (android.os.Build.VERSION.SDK_INT >= 30 &&
                            !android.os.Environment.isExternalStorageManager()
                        ) {
                            startActivity(
                                android.content.Intent(
                                    android.provider.Settings
                                        .ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                    android.net.Uri.parse("package:" + packageName)
                                )
                            )
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("storage", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

"""

STORAGE_CALL = """
        registerStorageChannel(flutterEngine)"""

CAST_BLOCK = '''
    private var castMulticastLock: android.net.wifi.WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: io.flutter.embedding.engine.FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        io.flutter.plugin.common.MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "fantasy_tv/cast"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireMulticastLock" -> {
                    try {
                        val wifi = applicationContext.getSystemService(
                            android.content.Context.WIFI_SERVICE
                        ) as android.net.wifi.WifiManager
                        val lock = castMulticastLock ?: wifi.createMulticastLock(
                            "fantasy_tv_cast"
                        ).also {
                            it.setReferenceCounted(false)
                            castMulticastLock = it
                        }
                        if (!lock.isHeld) lock.acquire()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("cast_lock", e.message, null)
                    }
                }
                "releaseMulticastLock" -> {
                    try {
                        castMulticastLock?.let { if (it.isHeld) it.release() }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("cast_lock", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // 应用内更新：下载完成后把 <cacheDir>/updates/*.apk 用 FileProvider
        // 换成 content:// URI，交给系统安装器（需 REQUEST_INSTALL_PACKAGES）。
        io.flutter.plugin.common.MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "fantasy_tv/update"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    try {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("install_path", "path is empty", null)
                        } else {
                            val file = java.io.File(path)
                            if (!file.exists()) {
                                result.error(
                                    "install_missing",
                                    "APK not found: " + path,
                                    null
                                )
                            } else {
                                val uri = androidx.core.content.FileProvider.getUriForFile(
                                    this,
                                    "$packageName.fileprovider",
                                    file
                                )
                                val intent = android.content.Intent(
                                    android.content.Intent.ACTION_VIEW
                                )
                                intent.setDataAndType(
                                    uri,
                                    "application/vnd.android.package-archive"
                                )
                                intent.addFlags(
                                    android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION
                                )
                                intent.addFlags(
                                    android.content.Intent.FLAG_ACTIVITY_NEW_TASK
                                )
                                startActivity(intent)
                                result.success(true)
                            }
                        }
                    } catch (e: Exception) {
                        result.error("install_failed", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
'''

ON_CREATE = '''
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        // Android 8/9（API 23-28）写公共 Download 目录需要旧版存储权限；
        // Android 10+ 走分区存储，写入失败会自动回退应用专属目录。
        if (android.os.Build.VERSION.SDK_INT <= 28 &&
            ContextCompat.checkSelfPermission(
                this,
                android.Manifest.permission.WRITE_EXTERNAL_STORAGE
            ) != android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(android.Manifest.permission.WRITE_EXTERNAL_STORAGE),
                1001
            )
        }
    }'''


def patch_cast(kt: str):
    """在 MainActivity 里注册 MulticastLock 通道；已存在则不动。"""
    if 'fantasy_tv/cast' in kt:
        return kt, False
    pattern = re.compile(
        r'class\s+MainActivity\s*:\s*FlutterActivity\(\)\s*\{')
    match = pattern.search(kt)
    if not match:
        return kt, False
    kt = kt[:match.end()] + CAST_BLOCK + kt[match.end():]
    return kt, True


def patch_orientation(kt: str):
    """在 MainActivity 里加屏幕方向通道（独立函数 + 在 configureFlutterEngine
    里调用一次）；已存在则不动。"""
    if 'fantasy_tv/orientation' in kt:
        return kt, False
    pattern = re.compile(
        r'class\s+MainActivity\s*:\s*FlutterActivity\(\)\s*\{')
    match = pattern.search(kt)
    if not match:
        return kt, False
    # 1) 函数体插在类开头（无论后面 patch 谁插在哪，函数定义都在类内）。
    kt = kt[:match.end()] + ORIENTATION_FUNC + kt[match.end():]
    # 2) 在 configureFlutterEngine 的 super 调用后注册一次。
    hook = 'super.configureFlutterEngine(flutterEngine)'
    index = kt.find(hook)
    if index < 0:
        return kt, False
    insert_at = index + len(hook)
    kt = kt[:insert_at] + '\n' + ORIENTATION_CALL + kt[insert_at:]
    return kt, True




def patch_storage_access(kt: str):
    """在 MainActivity 里加「所有文件访问」通道；已存在则不动。"""
    if 'fantasy_tv/storage' in kt:
        return kt, False
    pattern = re.compile(
        r'class\s+MainActivity\s*:\s*FlutterActivity\(\)\s*\{')
    match = pattern.search(kt)
    if not match:
        return kt, False
    kt = kt[:match.end()] + STORAGE_FUNC + kt[match.end():]
    hook = 'super.configureFlutterEngine(flutterEngine)'
    index = kt.find(hook)
    if index < 0:
        return kt, False
    insert_at = index + len(hook)
    kt = kt[:insert_at] + '\n' + STORAGE_CALL + kt[insert_at:]
    return kt, True




def patch_display(kt: str):
    """在 MainActivity 里加亮度 / 音量通道；已存在则不动。"""
    if 'fantasy_tv/display' in kt:
        return kt, False
    pattern = re.compile(
        r'class\s+MainActivity\s*:\s*FlutterActivity\(\)\s*\{')
    match = pattern.search(kt)
    if not match:
        return kt, False
    kt = kt[:match.end()] + DISPLAY_FUNC + kt[match.end():]
    hook = 'super.configureFlutterEngine(flutterEngine)'
    index = kt.find(hook)
    if index < 0:
        return kt, False
    kt = kt[:index + len(hook)] + '\n' + DISPLAY_CALL + kt[index + len(hook):]
    return kt, True


def main() -> int:
    styles = io.open(STYLE, encoding='utf-8').read()
    if 'windowLightNavigationBar' not in styles:
        styles, count = re.subn(
            r'<style name="NormalTheme"[^>]*>.*?</style>',
            STYLE_BLOCK, styles, count=1, flags=re.S)
        if not count:
            print('NormalTheme not found in %s' % STYLE, file=sys.stderr)
            return 1
        io.open(STYLE, 'w', encoding='utf-8').write(styles)
        print('patched %s' % STYLE)
    else:
        print('keep %s' % STYLE)

    candidates = glob.glob('android/app/src/main/**/MainActivity.kt',
                           recursive=True)
    if not candidates:
        print('MainActivity.kt not found', file=sys.stderr)
        return 1
    activity = candidates[0]
    kt = io.open(activity, encoding='utf-8').read()
    edge_patched = 'setDecorFitsSystemWindows' not in kt
    if edge_patched:
        for imp in IMPORTS:
            if imp not in kt:
                kt = kt.replace(
                    'import io.flutter.embedding.android.FlutterActivity',
                    'import io.flutter.embedding.android.FlutterActivity\n' + imp,
                    1)

        # Flutter 3.32 模板: `class MainActivity : FlutterActivity()`（无花括号）。
        pattern = re.compile(
            r'class\s+MainActivity\s*:\s*FlutterActivity\(\)\s*(\{)?')
        if not pattern.search(kt):
            print('cannot find MainActivity class declaration in %s' % activity,
                  file=sys.stderr)
            return 1

        def repl(m):
            head = 'class MainActivity : FlutterActivity() {'
            if m.group(1):
                return head + ON_CREATE
            return head + ON_CREATE + '\n}'

        kt = pattern.sub(repl, kt, count=1)

    kt, cast_patched = patch_cast(kt)
    if 'fantasy_tv/cast' not in kt:
        print('cannot patch DLNA multicast lock channel in %s' % activity,
              file=sys.stderr)
        return 1
    kt, display_patched = patch_display(kt)
    if 'fantasy_tv/display' not in kt:
        print('cannot patch display channel in %s' % activity, file=sys.stderr)
        return 1
    kt, storage_patched = patch_storage_access(kt)
    if 'fantasy_tv/storage' not in kt:
        print('cannot patch storage access channel in %s' % activity,
              file=sys.stderr)
        return 1
    kt, orient_patched = patch_orientation(kt)
    if 'fantasy_tv/orientation' not in kt:
        print('cannot patch orientation channel in %s' % activity,
              file=sys.stderr)
        return 1
    if kt.count('{') != kt.count('}'):
        print('unbalanced braces after patching %s' % activity,
              file=sys.stderr)
        return 1
    io.open(activity, 'w', encoding='utf-8').write(kt)
    if edge_patched or cast_patched or orient_patched or storage_patched or display_patched:
        print('patched %s' % activity)
    else:
        print('keep %s' % activity)
    return 0


if __name__ == '__main__':
    sys.exit(main())

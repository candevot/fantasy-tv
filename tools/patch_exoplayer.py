#!/usr/bin/env python3
"""把 ExoPlayer(Media3) 内核插件注入 CI 生成的 Android 工程。

android/ 目录不入库（CI 每次 flutter create 重新生成），所以插件源码放在
android_src/ 里，由本脚本在构建时拷进 android/app/src/main/kotlin/ 并
注册到 MainActivity + 加 Media3 依赖。

用法（仓库根目录）：python3 tools/patch_exoplayer.py
"""

import io
import os
import re
import shutil
import sys

SRC_DIR = 'android_src/kotlin'
PKG_PATH = 'com/huanxiang/fantasy_tv'
DEST_DIR = 'android/app/src/main/kotlin/' + PKG_PATH

# Media3 版本：和 compileSdk 36 兼容的稳定版
MEDIA3_VERSION = '1.4.1'

# OkHttp 版本（TRANSPORT_OKHTTP，2026-11-15）。
#
# 必须和 media3-datasource-okhttp:1.4.1 自己的依赖对齐：它的 POM 里写的就是
# okhttp 4.12.0。显式写出来是为了钉住版本（AGP 解析冲突时不会漂到 5.x）。
# android_src/libs/api.jar 里没有 okhttp3，不存在与 jar 内类的冲突。
OKHTTP_VERSION = '4.12.0'

# 播放传输层：OkHttpDataSource（HTTP/2 + 全局连接池 + trust-all + 兜底 UA）。
# DefaultHttpDataSource 走 HttpURLConnection，每次 302 换域都重开 TCP+TLS，
# 移动网一次 100~600ms —— 那是起播慢的主因，见 PlayerHttp.kt。
#
# MEDIA_SESSION（2026-11-15）：**media3-session 是新增的主力**。
# 后台播放从「裸 Service + 手绘通知」换成 MediaSessionService + MediaSession，
# 系统媒体卡片（封面 / 进度条 / 上一集下一集）、锁屏控件、负一屏媒体中心、
# 耳机线控、车机全靠它。它和 media3-exoplayer 同一个版本号，不额外引依赖。
MEDIA3_MODULES = (
    'media3-exoplayer',
    'media3-exoplayer-hls',
    'media3-ui',
    'media3-datasource',
    'media3-datasource-okhttp',
    'media3-session',
)


def dep_lines(is_kts):
    """(坐标, 该行 Gradle 文案) —— 按需补：已有的一条都不重复插。"""
    lines = []
    for module in MEDIA3_MODULES:
        coord = 'androidx.media3:%s' % module
        if is_kts:
            text = '    implementation("%s:%s")\n' % (coord, MEDIA3_VERSION)
        else:
            text = "    implementation '%s:%s'\n" % (coord, MEDIA3_VERSION)
        lines.append((coord, text))
    okhttp = [
        ('com.squareup.okhttp3:okhttp', OKHTTP_VERSION),
    ]
    for coord, version in okhttp:
        if is_kts:
            text = '    implementation("%s:%s")\n' % (coord, version)
        else:
            text = "    implementation '%s:%s'\n" % (coord, version)
        lines.append((coord, text))
    return lines


REGISTER_MARK = '// FX_EXOPLAYER_REGISTER'


def fail(msg):
    print('ERROR: ' + msg)
    sys.exit(1)


def copy_sources():
    if not os.path.isdir(SRC_DIR):
        fail('找不到 ' + SRC_DIR)
    os.makedirs(DEST_DIR, exist_ok=True)
    n = 0
    for root, _dirs, files in os.walk(SRC_DIR):
        for f in files:
            if not f.endswith(('.kt', '.java')):
                continue
            src = os.path.join(root, f)
            dst = os.path.join(DEST_DIR, f)
            shutil.copy2(src, dst)
            print('  copied %s -> %s' % (src, dst))
            n += 1
    if n == 0:
        fail('android_src 里没有 .kt/.java 文件')
    return n


def patch_gradle():
    """给 app/build.gradle(.kts) 加 Media3（含 session）+ OkHttp 依赖

    三种情况都要能收敛：
      · 全新模板（CI 每次 flutter create）→ 全部依赖一起插；
      · 已经打过 media3、但没有 media3-session / okhttp（旧缓存模板）→
        只补缺的那几条（**MEDIA_SESSION 就是靠这条补齐的**）；
      · 全都在 → 跳过。
    """
    cands = ['android/app/build.gradle.kts', 'android/app/build.gradle']
    path = next((p for p in cands if os.path.exists(p)), None)
    if not path:
        fail('找不到 app/build.gradle')
    src = io.open(path, encoding='utf-8').read()

    is_kts = path.endswith('.kts')
    missing = [(coord, text) for coord, text in dep_lines(is_kts)
               if coord not in src]
    if not missing:
        print('  Media3(含 session) / OkHttp 依赖已存在，跳过')
        return path

    block = ''.join(text for _coord, text in missing)
    print('  补 %d 条依赖：%s' % (
        len(missing), ', '.join(coord for coord, _ in missing)))

    m = re.search(r'dependencies\s*\{', src)
    if not m:
        # Flutter 模板偶尔把 dependencies 放在别处，兜底：顶层 dependencies 块
        print('  未找到 dependencies 块，追加到文件末尾')
        src = src + '\n\ndependencies {\n' + block + '}\n'
    else:
        src = src[:m.end()] + '\n' + block + src[m.end():]

    io.open(path, 'w', encoding='utf-8').write(src)
    print('  依赖已写入 -> %s' % path)
    return path


def find_main_activity():
    """在 android/app/src 下递归找 MainActivity（包名/语言都可能变）"""
    root = 'android/app/src/main'
    hits = []
    for base, _dirs, files in os.walk(root):
        for f in files:
            if f in ('MainActivity.kt', 'MainActivity.java'):
                hits.append(os.path.join(base, f))
    if not hits:
        # 打印实际目录帮助定位
        print('  android/app/src/main 下的文件树：')
        for base, _dirs, files in os.walk(root):
            for f in files:
                print('    ' + os.path.join(base, f))
        fail('找不到 MainActivity')
    # 优先 kotlin 路径
    hits.sort(key=lambda p: (0 if p.endswith('.kt') else 1, len(p)))
    return hits[0]


def patch_main_activity():
    """在 MainActivity.configureFlutterEngine 里注册 ExoPlayer 插件"""
    path = find_main_activity()
    print('  找到 MainActivity: ' + path)
    src = io.open(path, encoding='utf-8').read()
    if REGISTER_MARK in src:
        print('  ExoPlayer 注册已存在，跳过')
        return path

    is_kt = path.endswith('.kt')

    # 找 configureFlutterEngine 方法
    if is_kt:
        m = re.search(r'override\s+fun\s+configureFlutterEngine\s*\([^)]*\)\s*\{', src)
    else:
        m = re.search(r'(?:public\s+)?void\s+configureFlutterEngine\s*\([^)]*\)\s*\{', src)
    if not m:
        fail('MainActivity 里没有 configureFlutterEngine')

    if is_kt:
        code = (
            '\n        %s\n'
            '        // CRASH_LOG：未捕获异常写 logcat(FxCrash) 与 filesDir/crash.log，\n'
            '        // 记录完照原样交还系统默认处理器（只记录、不吞异常）。\n'
            '        FxCrash.install(this)\n'
            '        // ExoPlayer(Media3) 内核：画面走 PlatformView，控制权留在 Dart 侧\n'
            '        val exoPlugin = ExoPlayerPlugin(this)\n'
            '        exoPlugin.attach(flutterEngine.dartExecutor.binaryMessenger)\n'
            '        ExoPluginHolder.put(flutterEngine.dartExecutor.binaryMessenger, exoPlugin)\n'
            '        flutterEngine.platformViewsController.registry\n'
            '            .registerViewFactory(ExoPlayerPlugin.VIEW_TYPE,\n'
            '                object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {\n'
            '                    override fun create(context: Context, id: Int, args: Any?): PlatformView =\n'
            '                        ExoView(context, flutterEngine.dartExecutor.binaryMessenger, id, args)\n'
            '                })\n'
        ) % REGISTER_MARK
    else:
        code = (
            '\n        %s\n'
            '        FxCrash.INSTANCE.install(this);\n'
            '        ExoPlayerPlugin exoPlugin = new ExoPlayerPlugin(this);\n'
            '        exoPlugin.attach(flutterEngine.getDartExecutor().getBinaryMessenger());\n'
            '        ExoPluginHolder.INSTANCE.put(flutterEngine.getDartExecutor().getBinaryMessenger(), exoPlugin);\n'
            '        flutterEngine.getPlatformViewsController().getRegistry()\n'
            '            .registerViewFactory(ExoPlayerPlugin.VIEW_TYPE,\n'
            '                new PlatformViewFactory(StandardMessageCodec.INSTANCE) {\n'
            '                    @Override\n'
            '                    public PlatformView create(Context context, int id, Object args) {\n'
            '                        return new ExoView(context,\n'
            '                            flutterEngine.getDartExecutor().getBinaryMessenger(), id, args);\n'
            '                    }\n'
            '                });\n'
        ) % REGISTER_MARK

    pos = m.end()
    src = src[:pos] + code + src[pos:]

    # 补 import
    imports = [
        'import io.flutter.plugin.common.StandardMessageCodec',
        'import io.flutter.plugin.platform.PlatformView',
        'import io.flutter.plugin.platform.PlatformViewFactory',
        'import android.content.Context',
    ]
    lines = src.split('\n')
    last_import = max((i for i, l in enumerate(lines) if l.startswith('import ')), default=-1)
    if last_import >= 0:
        for imp in imports:
            if imp not in src:
                lines.insert(last_import + 1, imp)
                last_import += 1
    src = '\n'.join(lines)

    io.open(path, 'w', encoding='utf-8').write(src)
    print('  ExoPlayer 已注册到 %s' % path)
    return path


def main():
    print('== 注入 ExoPlayer 内核 ==')
    n = copy_sources()
    print('  拷入 %d 个源文件' % n)
    patch_gradle()
    patch_main_activity()
    print('== 完成 ==')


if __name__ == '__main__':
    main()

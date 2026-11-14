#!/usr/bin/env python3
"""把 jar 源（TVBox type 3）的运行期依赖与原生插件注入 CI 生成的 Android 工程。

android/ 目录不入库（CI 每次 flutter create 重新生成），所以：

  1. `android_src/libs/*.jar` → `android/app/libs/`（api.jar + okhttp / gson /
     jsoup / commons-*，DexClassLoader 加载的 csp_XXX.jar 靠它们跑起来）
  2. `app/build.gradle(.kts)` 加 `implementation(fileTree("libs"))`
     （Flutter 模板不会自动收 libs 目录里的 jar）
  3. `MainActivity` 注册 `fantasy_tv/spider` 通道（JarSpiderPlugin）
  4. 写 `android/app/proguard-rules.pro` 并挂到 release（只有开了 minify 才生效；
     Spider 系列类是被反射用的，开了 R8 不 keep 就会被剥掉）
  5. 可选：`assets/spiders/spider.jar` → `android/app/src/main/assets/spiders/`
     （想内置一个 jar 时把它放到 assets/spiders/spider.jar，脚本自动带进 APK）

kotlin 源码本身不用管：`tools/patch_exoplayer.py` 已经把 android_src/kotlin
下所有 .kt 拷进 `android/app/src/main/kotlin/`（JarSpiderLoader.kt /
JarSpiderPlugin.kt 在里面），所以**必须在它之后**执行本脚本。

用法（仓库根目录）：python3 tools/patch_jar_spider.py
"""

import io
import os
import re
import shutil
import sys

SRC_LIBS = 'android_src/libs'
DEST_LIBS = 'android/app/libs'
ASSET_JAR = 'assets/spiders/spider.jar'
DEST_ASSETS = 'android/app/src/main/assets/spiders'

DEPS_MARK = '// FX_JAR_SPIDER_DEPS'
REGISTER_MARK = '// FX_SPIDER_REGISTER'
PROGUARD_MARK = '# FX_JAR_SPIDER'

# jar 源要用、但 app 自己不会直接引用的类必须在 R8 下保住。
PROGUARD_RULES = '''# FX_JAR_SPIDER —— jar 源（TVBox type 3）的 R8 保留规则。
# DexClassLoader 加载的 csp_XXX.jar 会继承 / 调用下面这些类，
# 全是反射 + 外部 dex 引用，R8 看不见，不 keep 会被剥掉。
-keep class com.github.catvod.** { *; }
-keep interface com.github.catvod.** { *; }
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-keep class okio.** { *; }
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn com.github.catvod.**
-dontwarn org.jsoup.**
-dontwarn com.google.gson.**
-keep class com.google.gson.** { *; }
-keep class org.jsoup.** { *; }
-keep class org.apache.commons.** { *; }
# 插件与 jar 之间的桥：反射按名字找方法，别混淆。
-keep class com.huanxiang.fantasy_tv.JarSpiderLoader { *; }
-keep class com.huanxiang.fantasy_tv.JarSpiderPlugin { *; }
'''


def fail(msg):
    print('ERROR: ' + msg)
    sys.exit(1)


def copy_libs():
    if not os.path.isdir(SRC_LIBS):
        fail('找不到 ' + SRC_LIBS)
    jars = sorted(f for f in os.listdir(SRC_LIBS) if f.endswith('.jar'))
    if not jars:
        fail(SRC_LIBS + ' 里没有 jar')
    if 'api.jar' not in jars:
        fail('缺少 api.jar（Spider 基类），先跑 python3 tools/build_api_jar.py')
    os.makedirs(DEST_LIBS, exist_ok=True)
    total = 0
    for name in jars:
        src = os.path.join(SRC_LIBS, name)
        dst = os.path.join(DEST_LIBS, name)
        shutil.copy2(src, dst)
        size = os.path.getsize(dst)
        total += size
        print('  copied %s (%d KB)' % (dst, size // 1024))
    print('  共 %d 个 jar，%.1f MB' % (len(jars), total / 1024.0 / 1024.0))
    return jars


def copy_asset_jar():
    if not os.path.isfile(ASSET_JAR):
        print('  没有内置 jar（%s），跳过（用户可通过「安装 jar」下载）' % ASSET_JAR)
        return False
    os.makedirs(DEST_ASSETS, exist_ok=True)
    dst = os.path.join(DEST_ASSETS, 'spider.jar')
    shutil.copy2(ASSET_JAR, dst)
    print('  内置 jar -> %s (%d KB)' % (dst, os.path.getsize(dst) // 1024))
    return True


def find_gradle():
    for p in ('android/app/build.gradle.kts', 'android/app/build.gradle'):
        if os.path.exists(p):
            return p
    fail('找不到 app/build.gradle（先跑 flutter create 生成壳）')


def patch_gradle():
    path = find_gradle()
    is_kt = path.endswith('.kts')
    src = io.open(path, encoding='utf-8').read()
    if DEPS_MARK in src or 'fileTree' in src and 'libs' in src:
        print('  libs 依赖已存在，跳过 -> %s' % path)
        patch_proguard(path)
        return path

    if is_kt:
        line = ('    %s\n'
                '    implementation(fileTree(mapOf("dir" to "libs", '
                '"include" to listOf("*.jar"))))' % DEPS_MARK)
    else:
        line = ("    %s\n"
                "    implementation fileTree(dir: 'libs', include: ['*.jar'])" % DEPS_MARK)

    m = re.search(r'dependencies\s*\{', src)
    if m:
        src = src[:m.end()] + '\n' + line + src[m.end():]
        io.open(path, 'w', encoding='utf-8').write(src)
        print('  已加 libs 依赖 -> %s' % path)
    else:
        # Flutter 模板可能没有 dependencies 块：顶层追加是合法的 Groovy / Kotlin DSL。
        src = src + '\n\ndependencies {\n' + line + '\n}\n'
        io.open(path, 'w', encoding='utf-8').write(src)
        print('  已追加 dependencies 块 -> %s' % path)
    patch_proguard(path)
    return path


def patch_proguard(gradle_path):
    """写 proguard-rules.pro 并挂到 release（minify 没开时是空转，无害）。"""
    rules = os.path.join('android/app/proguard-rules.pro')
    io.open(rules, 'w', encoding='utf-8').write(PROGUARD_RULES)
    print('  已写 %s' % rules)

    is_kt = gradle_path.endswith('.kts')
    src = io.open(gradle_path, encoding='utf-8').read()
    if 'proguard-rules.pro' in src:
        print('  proguard 规则已挂载，跳过')
        return
    m = re.search(r'buildTypes\s*\{[\s\S]*?release\s*\{', src)
    if not m:
        print('  没有 buildTypes/release 块，跳过挂载（minify 未开启，规则暂时用不上）')
        return
    if is_kt:
        ins = ('\n            proguardFiles(getDefaultProguardFile('
               '"proguard-android-optimize.txt"), "proguard-rules.pro")')
    else:
        ins = ("\n            proguardFiles getDefaultProguardFile("
               "'proguard-android-optimize.txt'), 'proguard-rules.pro'")
    src = src[:m.end()] + ins + src[m.end():]
    io.open(gradle_path, 'w', encoding='utf-8').write(src)
    print('  已把 proguard-rules.pro 挂到 release -> %s' % gradle_path)


def find_main_activity():
    root = 'android/app/src/main'
    hits = []
    for base, _dirs, files in os.walk(root):
        for f in files:
            if f in ('MainActivity.kt', 'MainActivity.java'):
                hits.append(os.path.join(base, f))
    if not hits:
        fail('找不到 MainActivity（先跑 flutter create 生成壳）')
    hits.sort(key=lambda p: (0 if p.endswith('.kt') else 1, len(p)))
    return hits[0]


def patch_main_activity():
    path = find_main_activity()
    src = io.open(path, encoding='utf-8').read()
    if REGISTER_MARK in src:
        print('  jar 源通道已注册，跳过 -> %s' % path)
        return path
    is_kt = path.endswith('.kt')

    if is_kt:
        pat = r'override\s+fun\s+configureFlutterEngine\s*\([^)]*\)\s*\{'
    else:
        pat = r'(?:public\s+)?void\s+configureFlutterEngine\s*\([^)]*\)\s*\{'
    m = re.search(pat, src)
    if not m:
        fail('MainActivity 里没有 configureFlutterEngine')

    if is_kt:
        code = (
            '\n        %s\n'
            '        // jar 源（TVBox type 3）：DexClassLoader 加载 csp_XXX.jar，\n'
            '        // 反射调 Spider；通道 fantasy_tv/spider。\n'
            '        JarSpiderPlugin(this).attach(flutterEngine.dartExecutor.binaryMessenger)\n'
        ) % REGISTER_MARK
    else:
        code = (
            '\n        %s\n'
            '        new JarSpiderPlugin(this).attach(\n'
            '            flutterEngine.getDartExecutor().getBinaryMessenger());\n'
        ) % REGISTER_MARK

    src = src[:m.end()] + code + src[m.end():]
    io.open(path, 'w', encoding='utf-8').write(src)
    print('  jar 源通道已注册 -> %s' % path)
    return path


def main():
    print('== 注入 jar 源（TVBox type 3）支持 ==')
    if not os.path.isdir('android_src/kotlin'):
        fail('找不到 android_src/kotlin')
    kotlin_dest = 'android/app/src/main/kotlin/com/huanxiang/fantasy_tv'
    if not os.path.isdir(kotlin_dest):
        fail('没有 %s —— 先执行 tools/patch_exoplayer.py（它负责拷 .kt）' % kotlin_dest)
    for need in ('JarSpiderLoader.kt', 'JarSpiderPlugin.kt'):
        if not os.path.isfile(os.path.join(kotlin_dest, need)):
            fail('%s 没被拷进工程，先跑 tools/patch_exoplayer.py' % need)
    copy_libs()
    copy_asset_jar()
    patch_gradle()
    patch_main_activity()
    print('== 完成 ==')


if __name__ == '__main__':
    main()

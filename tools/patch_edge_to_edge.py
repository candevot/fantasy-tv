#!/usr/bin/env python3
"""把 CI 生成的 MainActivity / 主题补成 edge-to-edge，并保留 Android 8/9
写公共 Download 目录所需的旧版存储权限请求。

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
    if 'setDecorFitsSystemWindows' in kt:
        print('keep %s' % activity)
        return 0

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
    io.open(activity, 'w', encoding='utf-8').write(kt)
    print('patched %s' % activity)
    return 0


if __name__ == '__main__':
    sys.exit(main())

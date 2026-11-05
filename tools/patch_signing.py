#!/usr/bin/env python3
"""把固定 release 签名写进 CI 生成的 android/app/build.gradle(.kts)。

android/ 目录不入库，CI 每次都用 `flutter create` 重新生成，所以签名只能在
构建前 patch。Flutter 3.24 生成的是 Groovy DSL（build.gradle），之后的版本
改用 Kotlin DSL（build.gradle.kts），这里两种都兼容。

用法（仓库根目录）：python3 tools/patch_signing.py
"""

import io
import os
import sys

KTS = 'android/app/build.gradle.kts'
GROOVY = 'android/app/build.gradle'
KEYSTORE = 'android/fx-release.jks'
STORE_FILE = '../fx-release.jks'  # 相对 android/app/，即 android/fx-release.jks
RELEASE_LINE = 'signingConfig = signingConfigs.getByName("release")'

KTS_BLOCK = '''
    signingConfigs {
        create("release") {
            storeFile = file("../fx-release.jks")
            storePassword = "fx123456"
            keyAlias = "fx"
            keyPassword = "fx123456"
        }
    }
'''

GROOVY_BLOCK = '''
    signingConfigs {
        release {
            storeFile file("../fx-release.jks")
            storePassword "fx123456"
            keyAlias "fx"
            keyPassword "fx123456"
        }
    }
'''

# Flutter 模板里 release 默认用 debug 签名，各种写法都替换掉。
DEBUG_REFS = (
    'signingConfig = signingConfigs.debug',
    'signingConfig signingConfigs.debug',
    'signingConfig = signingConfigs.getByName("debug")',
    "signingConfig = signingConfigs.getByName('debug')",
)


def main() -> int:
    if not os.path.exists(KEYSTORE):
        print('missing %s' % KEYSTORE, file=sys.stderr)
        return 1

    if os.path.exists(KTS):
        path, kotlin = KTS, True
    elif os.path.exists(GROOVY):
        path, kotlin = GROOVY, False
    else:
        print('no android/app/build.gradle(.kts), run flutter create first',
              file=sys.stderr)
        return 1

    s = io.open(path, encoding='utf-8').read()

    if STORE_FILE not in s:
        if '    buildTypes {' not in s:
            print('buildTypes block not found in %s' % path, file=sys.stderr)
            return 1
        block = KTS_BLOCK if kotlin else GROOVY_BLOCK
        s = s.replace('    buildTypes {', block + '\n    buildTypes {', 1)

    for old in DEBUG_REFS:
        s = s.replace(old, RELEASE_LINE)

    if STORE_FILE not in s or RELEASE_LINE not in s:
        print('failed to apply fixed release signing to %s' % path,
              file=sys.stderr)
        return 1

    io.open(path, 'w', encoding='utf-8').write(s)
    print('patched %s (%s DSL)' % (path, 'kotlin' if kotlin else 'groovy'))
    print(s)
    return 0


if __name__ == '__main__':
    sys.exit(main())

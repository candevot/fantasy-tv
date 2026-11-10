#!/usr/bin/env python3
"""把 CI 生成的 Android 工程工具链与 SDK 级别钉死。

android/ 目录不入库，CI 每次用 `flutter create` 重新生成。Flutter 3.32
模板默认 compileSdk/targetSdk = 35、minSdk = 21、AGP 8.7.3、Gradle 8.12、
NDK 26.1；而 media_kit_libs_android_video 1.3.8（libmpv 1.1.7 / 16KB
页对齐）自身要求 AGP 8.13 + compileSdk 36。这里显式写死，避免模板漂移。

- compileSdk 36 / targetSdk 36（Android 16）/ minSdk 23
- AGP 8.13.0 / Gradle 8.14 / Kotlin 2.1.0
- ndkVersion 27.0.12077973（16KB 页对齐所需的新版 NDK）

用法（仓库根目录）：python3 tools/patch_android_sdk.py
"""

import io
import os
import re
import sys

LEVELS = (
    ('compileSdk', 36),
    ('targetSdk', 36),
    ('minSdk', 23),
)
NDK_VERSION = '27.0.12077973'
AGP_VERSION = '8.13.0'
GRADLE_VERSION = '8.14'
KOTLIN_VERSION = '2.1.0'

APP_CANDIDATES = (
    'android/app/build.gradle.kts',
    'android/app/build.gradle',
)
SETTINGS_CANDIDATES = (
    'android/settings.gradle.kts',
    'android/settings.gradle',
)


def find(paths):
    return next((p for p in paths if os.path.exists(p)), None)


def pin_levels(s: str) -> str:
    for name, value in LEVELS:
        # compileSdk = flutter.compileSdkVersion / compileSdkVersion flutter...
        pattern = re.compile(
            rf'(\b{name}(?:Version)?\s*=?\s*)'
            rf'(?:flutter\.{name}Version|["\']?\d+["\']?)')
        s, count = pattern.subn(rf'\g<1>{value}', s)
        if count:
            print('pinned %s = %s' % (name, value))
            continue
        m = re.search(rf'\b{name}(?:Version)?\s*=?\s*(\d+)', s)
        if not m:
            print('cannot find %s' % name, file=sys.stderr)
            raise SystemExit(1)
        print('keep %s = %s' % (name, m.group(1)))
    return s


def pin_ndk(s: str) -> str:
    pattern = re.compile(
        r'(\bndkVersion\s*=?\s*)'
        r'(?:flutter\.ndkVersion|["\'][^"\']+["\'])')
    s, count = pattern.subn(rf'\g<1>"{NDK_VERSION}"', s)
    if count:
        print('pinned ndkVersion = %s' % NDK_VERSION)
    elif NDK_VERSION not in s:
        print('cannot find ndkVersion', file=sys.stderr)
        raise SystemExit(1)
    return s


def pin_settings(path: str) -> None:
    s = io.open(path, encoding='utf-8').read()
    for plugin, version in (
            ('com.android.application', AGP_VERSION),
            ('org.jetbrains.kotlin.android', KOTLIN_VERSION)):
        pattern = re.compile(
            rf'({re.escape(plugin)}["\']\)?\s+version\s+["\'])[^"\']+(["\'])')
        s, count = pattern.subn(rf'\g<1>{version}\g<2>', s)
        print('pinned %s = %s (%d)' % (plugin, version, count))
        if not count:
            print('cannot find %s in %s' % (plugin, path), file=sys.stderr)
            raise SystemExit(1)
    io.open(path, 'w', encoding='utf-8').write(s)
    print('patched %s' % path)


def pin_gradle() -> None:
    path = 'android/gradle/wrapper/gradle-wrapper.properties'
    s = io.open(path, encoding='utf-8').read()
    s2, count = re.subn(
        r'gradle-\d+(?:\.\d+)+(?:-(?:all|bin))?\.zip',
        'gradle-%s-all.zip' % GRADLE_VERSION, s)
    if not count:
        print('cannot find gradle distribution in %s' % path, file=sys.stderr)
        raise SystemExit(1)
    io.open(path, 'w', encoding='utf-8').write(s2)
    print('pinned Gradle = %s' % GRADLE_VERSION)


def main() -> int:
    app = find(APP_CANDIDATES)
    if app is None:
        print('no android/app/build.gradle(.kts), run flutter create first',
              file=sys.stderr)
        return 1
    settings = find(SETTINGS_CANDIDATES)
    if settings is None:
        print('no android/settings.gradle(.kts), run flutter create first',
              file=sys.stderr)
        return 1

    s = io.open(app, encoding='utf-8').read()
    s = pin_levels(s)
    s = pin_ndk(s)
    io.open(app, 'w', encoding='utf-8').write(s)
    print('patched %s' % app)

    pin_settings(settings)
    pin_gradle()
    return 0


if __name__ == '__main__':
    sys.exit(main())

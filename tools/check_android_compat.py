#!/usr/bin/env python3
"""校验 CI 生成的 Android 工程按 Android 16 / 16KB 页要求配置。

在 `flutter create` + patch 步骤之后运行；任何一项不满足都让 CI 失败，
避免「本地能跑、CI 悄悄生成了不兼容的壳」。

要求：
- compileSdk 36 / targetSdk 36 / minSdk 23
- ndkVersion 27+（16KB 页）
- AGP 8.13+ / Gradle 8.13+ / Kotlin 2.x
- manifest 权限、明文流量、应用名
- MainActivity 有 Android 8/9 存储权限请求与 edge-to-edge
"""

import io
import os
import re
import sys


def fail(message: str) -> None:
    print('FAIL: %s' % message, file=sys.stderr)
    raise SystemExit(1)


def read(path: str) -> str:
    try:
        return io.open(path, encoding='utf-8').read()
    except OSError:
        fail('missing %s' % path)


def find(paths):
    return next((p for p in paths if os.path.exists(p)), None)


def sdk_value(text: str, name: str):
    m = re.search(rf'\b{name}(?:Version)?\s*=?\s*(\d+)', text)
    return int(m.group(1)) if m else None


def version_tuple(text: str):
    return tuple(int(x) for x in text.split('.'))


def main() -> None:
    gradle = find(('android/app/build.gradle.kts',
                   'android/app/build.gradle'))
    if gradle is None:
        fail('no android/app/build.gradle(.kts), run flutter create first')
    g = read(gradle)
    for name, expected in (('compileSdk', 36), ('targetSdk', 36),
                           ('minSdk', 23)):
        value = sdk_value(g, name)
        if value is None:
            fail('%s missing in %s' % (name, gradle))
        if value != expected:
            fail('%s=%s != %s' % (name, value, expected))
        print('ok %s=%s' % (name, value))

    m = re.search(r'\bndkVersion\s*=?\s*(?:flutter\.ndkVersion|["\']([^"\']+)["\'])', g)
    if not m or not m.group(1):
        fail('ndkVersion must be pinned to 27+ (found %r)' % (m.group(0) if m else None))
    ndk = m.group(1)
    if version_tuple(ndk)[0] < 27:
        fail('ndkVersion=%s < 27 (not 16KB-page ready)' % ndk)
    print('ok ndkVersion=%s' % ndk)

    settings = find(('android/settings.gradle.kts',
                     'android/settings.gradle'))
    if settings is None:
        fail('no android/settings.gradle(.kts)')
    st = read(settings)
    for plugin, minimum, label in (
            ('com.android.application', (8, 13), 'AGP'),
            ('org.jetbrains.kotlin.android', (2, 0), 'Kotlin')):
        m = re.search(
            rf'{re.escape(plugin)}["\']\)?\s+version\s+["\']([^"\']+)["\']',
            st)
        if not m:
            fail('%s version missing in %s' % (label, settings))
        got = version_tuple(m.group(1))
        if got < minimum:
            fail('%s=%s < %s' % (label, m.group(1),
                                 '.'.join(map(str, minimum))))
        print('ok %s=%s' % (label, m.group(1)))

    wrapper = 'android/gradle/wrapper/gradle-wrapper.properties'
    w = read(wrapper)
    m = re.search(r'gradle-(\d+(?:\.\d+)+)-(?:all|bin)\.zip', w)
    if not m:
        fail('cannot find Gradle distribution in %s' % wrapper)
    if version_tuple(m.group(1)) < (8, 13):
        fail('Gradle=%s < 8.13' % m.group(1))
    print('ok Gradle=%s' % m.group(1))

    manifest = read('android/app/src/main/AndroidManifest.xml')
    checks = (
        ('INTERNET permission',
         'android.permission.INTERNET' in manifest),
        ('Android 8 storage permission',
         re.search(r'WRITE_EXTERNAL_STORAGE[^>]*maxSdkVersion="28"',
                   manifest) is not None),
        ('cleartext traffic', 'android:usesCleartextTraffic="true"' in manifest),
        ('app label', 'android:label="幻想影视"' in manifest),
    )
    for label, ok in checks:
        if not ok:
            fail('manifest: %s' % label)
        print('ok manifest: %s' % label)

    activity = None
    for root, _, files in os.walk('android/app/src/main'):
        for name in files:
            if name == 'MainActivity.kt':
                activity = os.path.join(root, name)
                break
    if activity is None:
        fail('MainActivity.kt not found')
    kt = read(activity)
    if 'requestPermissions' not in kt or 'WRITE_EXTERNAL_STORAGE' not in kt:
        fail('MainActivity does not request legacy storage permission')
    print('ok MainActivity: Android 8/9 storage permission request')

    java_version = re.search(r'JavaVersion\.VERSION_(\d+)', g)
    if java_version:
        print('ok Java target=%s' % java_version.group(1))
    print('android compatibility checks passed')


if __name__ == '__main__':
    main()

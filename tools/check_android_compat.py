#!/usr/bin/env python3
"""校验 CI 生成的 Android 工程确实按 Android 8+ / API 34 配置。

在 `flutter create` + patch 步骤之后运行；任何一项不满足都让 CI 失败，
避免「本地能跑、CI 悄悄生成了不兼容的壳」。
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


def sdk_value(text: str, name: str):
    m = re.search(rf'\b{name}(?:Version)?\s*=?\s*(\d+)', text)
    return int(m.group(1)) if m else None


def main() -> None:
    gradle = next((p for p in ('android/app/build.gradle.kts',
                               'android/app/build.gradle')
                   if os.path.exists(p)), None)
    if gradle is None:
        fail('no android/app/build.gradle(.kts), run flutter create first')
    g = read(gradle)
    for name, minimum in (('compileSdk', 34), ('targetSdk', 34),
                          ('minSdk', 21)):
        value = sdk_value(g, name)
        if value is None:
            fail('%s missing in %s' % (name, gradle))
        if value < minimum:
            fail('%s=%s < %s' % (name, value, minimum))
        print('ok %s=%s' % (name, value))

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
    print('android compatibility checks passed')


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""把 CI 生成的 Android 工程 SDK 级别钉死。

android/ 目录不入库，CI 每次用 `flutter create` 重新生成。Flutter 3.24
模板默认 compileSdk/targetSdk = 34、minSdk = 21，但模板会随 Flutter 版本
漂移；这里显式写死，避免某次升级悄悄把 targetSdk 抬到未适配的版本。

用法（仓库根目录）：python3 tools/patch_android_sdk.py
"""

import io
import os
import re
import sys

LEVELS = (
    ('compileSdk', 34),
    ('targetSdk', 34),
    ('minSdk', 21),
)

CANDIDATES = (
    'android/app/build.gradle.kts',
    'android/app/build.gradle',
)


def main() -> int:
    path = next((p for p in CANDIDATES if os.path.exists(p)), None)
    if path is None:
        print('no android/app/build.gradle(.kts), run flutter create first',
              file=sys.stderr)
        return 1

    s = io.open(path, encoding='utf-8').read()
    for name, value in LEVELS:
        # compileSdk = flutter.compileSdkVersion / compileSdkVersion flutter...
        pattern = re.compile(
            rf'(\b{name}(?:Version)?\s*=?\s*)flutter\.{name}Version')
        s, count = pattern.subn(rf'\g<1>{value}', s)
        if count:
            print('pinned %s = %s' % (name, value))
            continue
        # 已经是显式数字时只做校验，不改写。
        m = re.search(rf'\b{name}(?:Version)?\s*=?\s*(\d+)', s)
        if not m:
            print('cannot find %s in %s' % (name, path), file=sys.stderr)
            return 1
        print('keep %s = %s' % (name, m.group(1)))

    io.open(path, 'w', encoding='utf-8').write(s)
    print('patched %s' % path)
    return 0


if __name__ == '__main__':
    sys.exit(main())

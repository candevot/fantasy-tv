#!/usr/bin/env python3
"""用 XML 解析（而不是字符串 replace）补全并校验 AndroidManifest.xml。

`android/` 目录不入库，CI 每次用 `flutter create` 重新生成，模板里的
manifest 只有 android:label="fantasy_tv"、没有 INTERNET / 明文流量。这里
解析 XML 后按需补上，并在写回后重新解析校验：

- <uses-permission android:name="android.permission.INTERNET"/>
- <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"
                   android:maxSdkVersion="28"/>（Android 8/9 写公共 Download）
- <uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>
- <uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE"/>
  （DLNA/SSDP 组播；MulticastLock 在 MainActivity 的 fantasy_tv/cast 通道
   里按需申请，二者都是 normal 权限，没有运行时弹窗）
- <application android:usesCleartextTraffic="true" ...>
- android:label="幻想影视"
- android:icon 必须存在（由 Flutter 模板 / 图标步骤提供，缺失直接失败）

任何一项无法确保（没有 <application>、没有 icon、解析失败、写回后校验
失败）都会打印 diff 并 sys.exit(1)，让 CI 构建失败。

用法（仓库根目录）：python3 tools/patch_manifest.py
"""

import difflib
import io
import sys
import xml.etree.ElementTree as ET

MANIFEST = 'android/app/src/main/AndroidManifest.xml'
ANDROID_NS = 'http://schemas.android.com/apk/res/android'
A = '{%s}' % ANDROID_NS
LABEL = '幻想影视'
ICON_ATTR = A + 'icon'
INTERNET = 'android.permission.INTERNET'
STORAGE = 'android.permission.WRITE_EXTERNAL_STORAGE'
STORAGE_MAX_SDK = '28'
# DLNA/SSDP 投屏：读 WiFi 状态 + 使用组播（MulticastLock 在 MainActivity
# 的 fantasy_tv/cast 通道里按需申请，二者都是 normal 权限，安装即授予）。
WIFI_STATE = 'android.permission.ACCESS_WIFI_STATE'
MULTICAST = 'android.permission.CHANGE_WIFI_MULTICAST_STATE'

ET.register_namespace('android', ANDROID_NS)


def attr(name):
    return A + name


def parse(path):
    # insert_comments 保留模板里的注释（例如 flutterEmbedding 的说明），
    # 避免补丁把模板注释整段吞掉。
    parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
    return ET.parse(path, parser=parser)


def permission_elements(root):
    found = {}
    for el in root.findall('uses-permission'):
        name = (el.get(attr('name')) or '').strip()
        if name:
            found.setdefault(name, el)
    return found


def application(root):
    return root.find('application')


def ensure_permission(root, name, max_sdk=None):
    """确保 uses-permission 存在；返回新增/修改的说明文字。"""
    perms = permission_elements(root)
    el = perms.get(name)
    changed = []
    if el is None:
        el = ET.Element('uses-permission')
        el.set(attr('name'), name)
        # uses-permission 必须直接挂在 <manifest> 下；插在已有权限之后，
        # 保持调用顺序（INTERNET 在前），不打断其它节点。
        index = 0
        while index < len(root) and root[index].tag == 'uses-permission':
            index += 1
        root.insert(index, el)
        changed.append('added')
    if max_sdk is None:
        if el.get(attr('maxSdkVersion')) is not None:
            del el.attrib[attr('maxSdkVersion')]
            changed.append('removed maxSdkVersion')
    else:
        if el.get(attr('maxSdkVersion')) != max_sdk:
            el.set(attr('maxSdkVersion'), max_sdk)
            changed.append('maxSdkVersion=%s' % max_sdk)
    return changed


def patch(root):
    notes = []
    app = application(root)
    if app is None:
        raise SystemExit(
            'FAIL: <application> not found in %s (namespace/prefix broken?)'
            % MANIFEST)

    for what in ensure_permission(root, INTERNET):
        notes.append('INTERNET %s' % what)
    for what in ensure_permission(root, STORAGE, STORAGE_MAX_SDK):
        notes.append('WRITE_EXTERNAL_STORAGE %s' % what)
    for what in ensure_permission(root, WIFI_STATE):
        notes.append('ACCESS_WIFI_STATE %s' % what)
    for what in ensure_permission(root, MULTICAST):
        notes.append('CHANGE_WIFI_MULTICAST_STATE %s' % what)

    if app.get(attr('usesCleartextTraffic')) != 'true':
        app.set(attr('usesCleartextTraffic'), 'true')
        notes.append('usesCleartextTraffic=true')

    if app.get(attr('label')) != LABEL:
        app.set(attr('label'), LABEL)
        notes.append('label=%s' % LABEL)

    # icon 由 Flutter 模板提供、由“Apply app icons”步骤补图标资源；
    # 这里只校验，不凭空发明一个 @mipmap 引用（缺了说明模板已漂移）。
    return notes


def validate(root):
    problems = []
    app = application(root)
    perms = permission_elements(root)

    if INTERNET not in perms:
        problems.append('missing uses-permission %s' % INTERNET)
    elif perms[INTERNET].get(attr('maxSdkVersion')) is not None:
        problems.append('%s must not be limited by maxSdkVersion' % INTERNET)

    storage = perms.get(STORAGE)
    if storage is None:
        problems.append('missing uses-permission %s' % STORAGE)
    elif storage.get(attr('maxSdkVersion')) != STORAGE_MAX_SDK:
        problems.append('%s maxSdkVersion must be %s'
                        % (STORAGE, STORAGE_MAX_SDK))

    for name in (WIFI_STATE, MULTICAST):
        item = perms.get(name)
        if item is None:
            problems.append('missing uses-permission %s' % name)
        elif item.get(attr('maxSdkVersion')) is not None:
            problems.append('%s must not be limited by maxSdkVersion' % name)

    if app is None:
        problems.append('missing <application>')
        return problems

    if app.get(attr('usesCleartextTraffic')) != 'true':
        problems.append('<application> usesCleartextTraffic must be true')
    if app.get(attr('label')) != LABEL:
        problems.append('<application> label must be %s (got %r)'
                        % (LABEL, app.get(attr('label'))))
    icon = app.get(ICON_ATTR)
    if not icon:
        problems.append('<application> android:icon is missing')
    return problems


def render(root):
    ET.indent(root, space='    ')
    body = ET.tostring(root, encoding='unicode')
    return '<?xml version="1.0" encoding="utf-8"?>\n%s\n' % body


def print_diff(before, after):
    if before == after:
        print('manifest diff: (no changes)')
        return
    diff = list(difflib.unified_diff(
        before.splitlines(keepends=True),
        after.splitlines(keepends=True),
        fromfile='%s (before)' % MANIFEST,
        tofile='%s (after)' % MANIFEST,
    ))
    sys.stdout.write(''.join(diff))
    if diff and not diff[-1].endswith('\n'):
        print()


def main():
    try:
        original = io.open(MANIFEST, encoding='utf-8').read()
    except OSError as exc:
        print('FAIL: cannot read %s: %s' % (MANIFEST, exc), file=sys.stderr)
        raise SystemExit(1)

    try:
        tree = parse(MANIFEST)
    except ET.ParseError as exc:
        print('FAIL: %s is not valid XML: %s' % (MANIFEST, exc),
              file=sys.stderr)
        raise SystemExit(1)

    root = tree.getroot()
    if root.tag != 'manifest':
        print('FAIL: root element is <%s>, expected <manifest>' % root.tag,
              file=sys.stderr)
        raise SystemExit(1)

    try:
        notes = patch(root)
        after = render(root)
    except SystemExit as exc:
        print(str(exc), file=sys.stderr)
        print_diff(original, original)
        raise SystemExit(1)

    print_diff(original, after)
    if notes:
        print('patched: %s' % '; '.join(notes))

    # 写回后重新从磁盘解析一遍，确保 ElementTree 序列化没有破坏命名空间
    # 或属性，再做最终门禁；任何一项缺失都让构建失败。
    io.open(MANIFEST, 'w', encoding='utf-8').write(after)
    try:
        check = parse(MANIFEST).getroot()
    except ET.ParseError as exc:
        print('FAIL: patched manifest is not valid XML: %s' % exc,
              file=sys.stderr)
        raise SystemExit(1)

    problems = validate(check)
    if problems:
        print('FAIL: manifest validation failed:', file=sys.stderr)
        for item in problems:
            print('  - %s' % item, file=sys.stderr)
        raise SystemExit(1)

    for line in validate_ok_lines(check):
        print('ok %s' % line)
    print('manifest OK: %s' % MANIFEST)


def validate_ok_lines(root):
    app = application(root)
    yield '%s' % INTERNET
    yield '%s maxSdkVersion=%s' % (STORAGE, STORAGE_MAX_SDK)
    yield '%s' % WIFI_STATE
    yield '%s' % MULTICAST
    yield 'usesCleartextTraffic=%s' % app.get(attr('usesCleartextTraffic'))
    yield 'label=%s' % app.get(attr('label'))
    yield 'icon=%s' % app.get(ICON_ATTR)


if __name__ == '__main__':
    main()

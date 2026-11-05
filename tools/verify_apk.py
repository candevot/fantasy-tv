#!/usr/bin/env python3
"""构建后 APK 全面校验门禁：任何一项不过就让 CI 失败。

覆盖：
- 二进制 AndroidManifest：INTERNET 权限、usesCleartextTraffic=true、
  android:label=幻想影视、android:icon 存在（aapt2 dump，缺 aapt2 时回退 aapt）
- assets/flutter_assets/fonts/MaterialIcons-Regular.otf（图标字体）
  + FontManifest.json 里注册了 MaterialIcons
- assets/flutter_assets/assets/logo.png（且是合法 PNG）
- lib/arm64-v8a/libapp.so、libflutter.so、libmpv.so 存在
- libmpv.so 恰好 4 段 LOAD 且 ALIGN=0x4000；其余 arm64 .so 的 LOAD 也须
  16KB 对齐
- META-INF 签名文件存在；apksigner verify 通过（没有 apksigner 则跳过并说明）
- zipalign 16KB 对齐（有 zipalign 时）；APK 体积、sha256

用法：
  python3 tools/verify_apk.py build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
"""

import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

DEFAULT_APK = 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk'
ANDROID_NS = 'http://schemas.android.com/apk/res/android'
REQUIRED_ENTRIES = (
    'assets/flutter_assets/fonts/MaterialIcons-Regular.otf',
    'assets/flutter_assets/assets/logo.png',
    'lib/arm64-v8a/libapp.so',
    'lib/arm64-v8a/libflutter.so',
    'lib/arm64-v8a/libmpv.so',
)
SIGNATURE_RE = re.compile(r'^META-INF/[^/]+\.(?:SF|RSA|DSA|EC)$', re.I)


class Gate:
    def __init__(self):
        self.failures = []
        self.skips = []

    def ok(self, what, detail=''):
        print('PASS  %s%s' % (what, (': ' + detail) if detail else ''))

    def fail(self, what, detail=''):
        print('FAIL  %s%s' % (what, (': ' + detail) if detail else ''))
        self.failures.append(what)

    def skip(self, what, why):
        print('SKIP  %s (%s)' % (what, why))
        self.skips.append(what)

    def require(self, what, cond, detail=''):
        if cond:
            self.ok(what, detail)
        else:
            self.fail(what, detail)
        return bool(cond)


def human(size):
    value = float(size)
    for unit in ('B', 'KiB', 'MiB', 'GiB'):
        if value < 1024 or unit == 'GiB':
            return '%.2f %s' % (value, unit)
        value /= 1024.0
    return '%d B' % size


def version_key(name):
    return tuple(int(n) for n in re.findall(r'\d+', name))


def find_tool(name):
    """优先在 ANDROID_HOME 的最新 build-tools 里找，其次 PATH。"""
    roots = [
        os.environ.get('ANDROID_HOME'),
        os.environ.get('ANDROID_SDK_ROOT'),
        '/usr/local/lib/android/sdk',
        '/opt/android-sdk',
        '/usr/lib/android-sdk',
        os.path.expanduser('~/Android/Sdk'),
    ]
    best = None
    for root in roots:
        if not root:
            continue
        build_tools = os.path.join(root, 'build-tools')
        try:
            dirs = os.listdir(build_tools)
        except OSError:
            continue
        for entry in dirs:
            path = os.path.join(build_tools, entry, name)
            if os.path.isfile(path) and os.access(path, os.X_OK):
                key = version_key(entry)
                if best is None or key > best[0]:
                    best = (key, path)
    if best:
        return best[1]
    return shutil.which(name)


def run(cmd, echo=True):
    if echo:
        print('$ ' + ' '.join(cmd))
    return subprocess.run(cmd, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True,
                          encoding='utf-8', errors='replace')


def dump_manifest(tool, apk):
    """返回 (permissions, badging, xmltree) 文本；aapt2 与 aapt 参数不同。"""
    is_aapt2 = os.path.basename(tool).startswith('aapt2')
    perms = run([tool, 'dump', 'permissions', apk])
    badging = run([tool, 'dump', 'badging', apk])
    if is_aapt2:
        xmltree = run([tool, 'dump', 'xmltree', '--file',
                       'AndroidManifest.xml', apk])
    else:
        xmltree = run([tool, 'dump', 'xmltree', apk, 'AndroidManifest.xml'])
    return perms, badging, xmltree


def load_alignments(readelf, path):
    result = run([readelf, '-lW', path], echo=False)
    if result.returncode != 0:
        return None
    aligns = []
    for line in result.stdout.splitlines():
        parts = line.split()
        if parts and parts[0] == 'LOAD':
            aligns.append(parts[-1].lower())
    return aligns


def verify_manifest(gate, apk):
    tool = find_tool('aapt2') or find_tool('aapt')
    if tool is None:
        gate.fail('aapt2/aapt available for manifest inspection')
        return
    gate.ok('manifest inspector', tool)
    perms, badging, xmltree = dump_manifest(tool, apk)
    for name, proc in (('permissions', perms), ('badging', badging),
                       ('xmltree', xmltree)):
        if proc.returncode != 0:
            gate.fail('aapt %s' % name, proc.stdout.strip()[:300])
            return

    gate.require(
        'INTERNET permission in APK',
        re.search(r"uses-permission:\s*name='android\.permission\.INTERNET'",
                  perms.stdout) is not None)
    storage = re.search(
        r"uses-permission:\s*name='android\.permission\.WRITE_EXTERNAL_STORAGE'"
        r"([^\n]*)", perms.stdout)
    gate.require('legacy storage permission in APK', storage is not None,
                 storage.group(0).strip() if storage else 'not found')

    cleartext = ''
    for line in xmltree.stdout.splitlines():
        if 'usesCleartextTraffic' in line:
            cleartext = line.strip()
            break
    gate.require(
        'usesCleartextTraffic=true in APK',
        bool(re.search(r'usesCleartextTraffic.*0xffffffff', cleartext, re.I)
             or re.search(r'usesCleartextTraffic.*\btrue\b', cleartext, re.I)),
        cleartext or 'attribute not found')

    label_match = re.search(r"application-label:'([^']*)'", badging.stdout)
    label = label_match.group(1) if label_match else None
    gate.require('application label in APK', label == '幻想影视',
                 repr(label))

    icon_match = re.search(r"^application:.*?icon='([^']*)'",
                           badging.stdout, re.M)
    icon = icon_match.group(1).strip() if icon_match else ''
    gate.require('application icon in APK', bool(icon), icon or 'not found')


def verify_zip(gate, apk):
    try:
        zf = zipfile.ZipFile(apk)
    except zipfile.BadZipFile as exc:
        gate.fail('APK is a valid zip', str(exc))
        return None
    names = zf.namelist()
    gate.ok('APK is a valid zip', '%d entries' % len(names))
    gate.require('AndroidManifest.xml inside APK',
                 'AndroidManifest.xml' in names)

    for entry in REQUIRED_ENTRIES:
        info = zf.getinfo(entry) if entry in names else None
        gate.require(entry, info is not None and info.file_size > 0,
                     '%d bytes' % info.file_size if info else 'missing')

    font_manifest = 'assets/flutter_assets/FontManifest.json'
    if font_manifest in names:
        try:
            families = {item.get('family') for item in
                        json.loads(zf.read(font_manifest).decode('utf-8'))
                        if isinstance(item, dict)}
            gate.require('MaterialIcons registered in FontManifest',
                         'MaterialIcons' in families, str(sorted(families)))
        except (ValueError, UnicodeDecodeError) as exc:
            gate.fail('FontManifest.json parses', str(exc))
    else:
        gate.fail('FontManifest.json present')

    logo = 'assets/flutter_assets/assets/logo.png'
    if logo in names:
        head = zf.read(logo)[:8]
        gate.require('logo.png is a valid PNG',
                     head == b'\x89PNG\r\n\x1a\n', repr(head))

    sig_names = [n for n in names
                 if n.startswith('META-INF/') and SIGNATURE_RE.match(n)]
    has_sf = any(n.upper().endswith('.SF') for n in sig_names)
    has_block = any(n.upper().endswith(('.RSA', '.DSA', '.EC'))
                    for n in sig_names)
    gate.require('META-INF v1 signature entries',
                 has_sf and has_block and 'META-INF/MANIFEST.MF' in names,
                 ', '.join(sig_names) or 'none')
    return zf


def verify_elf(gate, zf, names):
    readelf = find_tool('readelf')
    if readelf is None:
        gate.fail('readelf available')
        return
    libs = sorted(n for n in names
                  if n.startswith('lib/arm64-v8a/') and n.endswith('.so'))
    if not libs:
        gate.fail('arm64 native libraries present')
        return

    with tempfile.TemporaryDirectory(prefix='fx-apk-') as tmp:
        for name in libs:
            zf.extract(name, tmp)
        for name in libs:
            path = os.path.join(tmp, name)
            aligns = load_alignments(readelf, path)
            short = name.split('/')[-1]
            if not aligns:
                gate.fail('%s LOAD segments' % short)
                continue
            if short == 'libmpv.so':
                gate.require('%s has exactly 4 LOAD segments' % short,
                             len(aligns) == 4, 'got %d' % len(aligns))
                gate.require('%s all LOAD ALIGN=0x4000' % short,
                             all(a == '0x4000' for a in aligns),
                             ', '.join(aligns))
            else:
                def aligned(value):
                    try:
                        return int(value, 16) % 0x4000 == 0
                    except ValueError:
                        return False
                gate.require('%s LOAD ALIGN 16KB' % short,
                             all(aligned(a) for a in aligns),
                             ', '.join(aligns))


def verify_zip_alignment(gate, apk, zf):
    """纯 Python 校验：未压缩 .so 在 zip 内的数据偏移必须 16KB 对齐。

    zipalign -P 16 是同一件事，但旧版 zipalign 没有 -P；这里不依赖它，
    保证本地/CI 都能验证 APK 本身，而不是只验证工具输出。
    """
    short_names = []
    with open(apk, 'rb') as handle:
        for info in zf.infolist():
            name = info.filename
            if not (name.startswith('lib/arm64-v8a/') and
                    name.endswith('.so')):
                continue
            short = name.split('/')[-1]
            short_names.append(short)
            if info.compress_type != zipfile.ZIP_STORED:
                gate.fail('%s stored uncompressed' % short,
                          'compress_type=%d' % info.compress_type)
                continue
            handle.seek(info.header_offset)
            header = handle.read(30)
            if len(header) != 30:
                gate.fail('%s local zip header' % short)
                continue
            fields = struct.unpack('<IHHHHHIIIHH', header)
            name_len, extra_len = fields[-2], fields[-1]
            data_offset = info.header_offset + 30 + name_len + extra_len
            gate.require('%s zip offset 16KB aligned' % short,
                         data_offset % 0x4000 == 0,
                         '0x%x (mod 0x4000=%d)'
                         % (data_offset, data_offset % 0x4000))
    if not short_names:
        gate.fail('arm64 .so entries for zip alignment check')


def verify_signature(gate, apk):
    apksigner = find_tool('apksigner')
    if apksigner is None:
        gate.skip('apksigner verify', 'apksigner not found; v1 META-INF '
                  'entries were checked instead')
        return
    proc = run([apksigner, 'verify', '--print-certs', apk])
    certs = [line.strip() for line in proc.stdout.splitlines()
             if 'Signer #' in line or 'certificate' in line]
    gate.require('apksigner verify', proc.returncode == 0,
                 ' | '.join(certs[:4]) if proc.returncode == 0
                 else proc.stdout.strip()[-500:])


def verify_zipalign(gate, apk):
    zipalign = find_tool('zipalign')
    if zipalign is None:
        gate.skip('zipalign -P 16', 'zipalign not found')
        return
    help_out = run([zipalign, '-h'], echo=False)
    if re.search(r'(^|\s)-P(\s|$|<)', help_out.stdout) is None:
        gate.skip('zipalign -P 16',
                  'this zipalign build has no -P option; the pure-Python '
                  '16KB offset check above is authoritative')
        return
    proc = run([zipalign, '-c', '-P', '16', '-v', '4', apk], echo=False)
    tail = [line for line in proc.stdout.splitlines() if line.strip()][-3:]
    gate.require('zipalign 16KB (-P 16)', proc.returncode == 0,
                 ' | '.join(tail))


def main():
    apk = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_APK
    if not os.path.isfile(apk):
        print('FAIL: APK not found: %s' % apk, file=sys.stderr)
        return 1

    gate = Gate()
    size = os.path.getsize(apk)
    print('APK: %s' % apk)
    print('APK size: %s (%d bytes)' % (human(size), size))

    zf = verify_zip(gate, apk)
    if zf is not None:
        verify_zip_alignment(gate, apk, zf)
        verify_elf(gate, zf, zf.namelist())
        zf.close()
    verify_manifest(gate, apk)
    verify_signature(gate, apk)
    verify_zipalign(gate, apk)

    digest = hashlib.sha256()
    with open(apk, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    print('APK sha256: %s' % digest.hexdigest())

    print('')
    if gate.skips:
        print('skipped: %s' % ', '.join(gate.skips))
    if gate.failures:
        print('APK verification FAILED (%d): %s'
              % (len(gate.failures), ', '.join(gate.failures)))
        return 1
    print('APK verification passed.')
    return 0


if __name__ == '__main__':
    sys.exit(main())

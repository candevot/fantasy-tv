#!/usr/bin/env bash
#
# 一键本地构建 release APK —— 与 .github/workflows/build.yml 步骤 / 变量同款。
#
#   用法：bash tools/build.sh
#
# ========================= 首次准备（一次性） =========================
#   1) Flutter 3.32.8（= Dart 3.8.1；脚本只接受 3.32.x，与 CI flutter-version 一致）
#        git clone -b 3.32.8 https://github.com/flutter/flutter.git ~/flutter
#        echo 'export PATH="$HOME/flutter/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
#        flutter doctor          # 按提示补装
#      注意：官方 Flutter release 包只提供 linux-x64；arm64 主机需把
#      flutter/bin/cache/dart-sdk 换成 arm64 版 Dart 3.8.1，否则 flutter 直接 SIGILL。
#   2) Android SDK（默认 $HOME/Android/Sdk，或 export ANDROID_HOME=<sdk 路径>；CI 同款 SDK 层级）
#        sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0" \
#                   "ndk;27.0.12077973"
#        flutter doctor --android-licenses
#   3) JDK 17（CI 用 temurin 17；AGP 8.13 要求 17+，17~21 都可）
#        apt-get install -y openjdk-17-jdk
#   4) 联网：首次构建 gradle 会拉 AGP 8.13 / Gradle 8.13 / NDK 27 与依赖。
#
# 可选环境变量：
#   BUILD_NUMBER=<int>   指定 versionCode，默认 $(date +%s)（见 build 段说明）
#   SKIP_ANALYZE=1       跳过 flutter analyze（CI 不跳，默认与 CI 一致要跑）
#
# android/ 只入库 android/fx-release.jks，其余壳由本脚本按 CI「Generate android
# shell」相同参数生成；CI workflow 不改，本脚本只是把同一套 tools/*.py
# 补丁与校验门禁按 CI 顺序在本地跑一遍。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

die() {
  printf '\n[build] ERROR: %s\n' "$1" >&2
  shift
  local line
  for line in "$@"; do printf '         %s\n' "$line" >&2; done
  exit 1
}

# ---------------------------------------------------------------- 1. 预检
# flutter 必须在 PATH 且版本 = 3.32.x
if ! command -v flutter >/dev/null 2>&1; then
  die "flutter 不在 PATH" \
      "安装 Flutter 3.32.8：git clone -b 3.32.8 https://github.com/flutter/flutter.git ~/flutter" \
      "然后 export PATH=\"\$HOME/flutter/bin:\$PATH\"（写进 ~/.bashrc）"
fi

FLUTTER_VER="$(flutter --version --machine 2>/dev/null \
  | sed -n 's/.*"frameworkVersion" *: *"\([0-9.]*\)".*/\1/p' | head -n1 || true)"
if [ -z "$FLUTTER_VER" ]; then
  FLUTTER_VER="$(flutter --version 2>/dev/null | head -n1 \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
fi
case "${FLUTTER_VER:-}" in
  3.32.*) ;;
  *)
    die "flutter 版本需要 3.32.x（当前: ${FLUTTER_VER:-读取失败 / flutter 无法运行}）" \
        "安装 Flutter 3.32.8：git clone -b 3.32.8 https://github.com/flutter/flutter.git ~/flutter" \
        "export PATH=\"\$HOME/flutter/bin:\$PATH\"" \
        "arm64 主机：官方包是 linux-x64，需换成 arm64 Dart 3.8.1，否则 flutter 无法启动"
    ;;
esac

# Android SDK：ANDROID_HOME（或 ANDROID_SDK_ROOT），否则默认 ~/Android/Sdk
find_sdk() {
  local c
  for c in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Android/Sdk"; do
    [ -n "$c" ] || continue
    if [ -d "$c" ] && { [ -d "$c/platforms" ] || [ -d "$c/cmdline-tools" ] || [ -d "$c/platform-tools" ]; }; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}
SDK_HOME="$(find_sdk || true)"
if [ -z "$SDK_HOME" ]; then
  die "找不到可用的 Android SDK（已检查 ANDROID_HOME / ANDROID_SDK_ROOT / ~/Android/Sdk）" \
      "安装 cmdline-tools 后执行：sdkmanager \"platform-tools\" \"platforms;android-36\" \"build-tools;36.0.0\" \"ndk;27.0.12077973\"" \
      "再 export ANDROID_HOME=\$HOME/Android/Sdk 与 flutter doctor --android-licenses"
fi
export ANDROID_HOME="$SDK_HOME"
export ANDROID_SDK_ROOT="$SDK_HOME"
echo "[build] flutter $FLUTTER_VER"
echo "[build] ANDROID_HOME=$ANDROID_HOME"

# JDK（CI 用 17；AGP 8.13 要求 17+）
if ! command -v java >/dev/null 2>&1; then
  die "找不到 java（JDK 17）" \
      "apt-get install -y openjdk-17-jdk" \
      "然后 export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-arm64（按实际路径）"
fi
JAVA_MAJOR="$(java -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -n1)"
if [ -z "${JAVA_MAJOR:-}" ] || [ "$JAVA_MAJOR" -lt 17 ]; then
  die "JDK 版本需要 >=17（当前: ${JAVA_MAJOR:-未知}；CI 用 temurin 17）" \
      "apt-get install -y openjdk-17-jdk && export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-arm64"
fi
echo "[build] JDK $JAVA_MAJOR"

# ---------------------------------------------------------------- 2. 依赖
echo "[build] flutter pub get"
flutter pub get

# ------------------------------------------------- 3. android/ 壳 + 签名文件
# 与 CI「Generate android shell」同名参数；只在壳缺失时生成，生成后合并进
# 已存在的 android/（仓库里的 android/fx-release.jks 不会被覆盖/删除）。
if [ -f android/settings.gradle ] || [ -f android/settings.gradle.kts ]; then
  echo "[build] android/ 壳已存在，跳过 flutter create"
else
  echo "[build] 生成 android/ 壳（flutter create，同 CI 参数）"
  rm -rf _tmp
  flutter create --platforms=android --project-name fantasy_tv --org com.huanxiang _tmp
  mkdir -p android
  cp -r _tmp/android/. ./android/
  rm -rf _tmp
fi
if [ ! -f android/fx-release.jks ]; then
  die "缺少 android/fx-release.jks（固定 release 签名，已提交在仓库里）" \
      "git checkout -- android/fx-release.jks"
fi
echo "[build] android/fx-release.jks OK"

# ---------------------------------------------- 4. 同款补丁（CI 步骤顺序）
echo "[build] patch: Android 工具链 / SDK 级别（patch_android_sdk.py）"
python3 tools/patch_android_sdk.py

echo "[build] patch: release 签名（patch_signing.py）"
python3 tools/patch_signing.py
if command -v keytool >/dev/null 2>&1; then
  keytool -list -v -keystore android/fx-release.jks -storepass fx123456 2>/dev/null \
    | grep -E 'Alias name|Valid from|SHA256:' || true
fi

echo "[build] 应用图标"
if [ ! -f assets/icons/ic_launcher-192.png ]; then
  python3 tools/gen_icons.py
fi
for pair in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  k=${pair%%:*}; sz=${pair##*:}
  cp "assets/icons/ic_launcher-${sz}.png" "android/app/src/main/res/mipmap-${k}/ic_launcher.png"
done

echo "[build] patch: manifest（INTERNET / cleartext / label / icon，patch_manifest.py）"
python3 tools/patch_manifest.py

echo "[build] patch: edge-to-edge + 存储权限 + DLNA MulticastLock（patch_edge_to_edge.py）"
python3 tools/patch_edge_to_edge.py

# PLAYER_CORE（2026-11-14 二次切换）：内核是定制 ExoPlayer(Media3)。
# android/ 不入库，原生桥（ExoPlayerPlugin.kt + SegmentPreloader.kt）必须在
# 构建前注入，否则 Dart 侧的 fantasy_tv/exo_player 通道找不到实现 ——
# 表现出来就是「一开播就黑屏、没有任何错误」。CI 里同名步骤是
# 「Inject ExoPlayer (Media3) kernel」。
echo "[build] patch: 注入 ExoPlayer(Media3) 内核（patch_exoplayer.py）"
python3 tools/patch_exoplayer.py

echo "[build] check: Android 8+ / 16KB 兼容（check_android_compat.py）"
python3 tools/check_android_compat.py

# ------------------------------------------------ 5. 与 CI 同款的静态门禁
if grep -q '^dependency_overrides:' pubspec.yaml; then
  die "dependency_overrides must be removed（与 CI「Verify dependency overrides removed」一致）"
fi
# PLAYER_CORE（2026-11-14 二次切换）：内核是定制 ExoPlayer(Media3)，
# media_kit(libmpv) 必须已经移除，且 lib/ 里不许再有引用（与 CI 同款校验）。
if grep -qE '^  media_kit(_video|_libs_video|_libs_android_video)?:' pubspec.yaml; then
  die "pubspec.yaml 仍有 media_kit 依赖（ExoPlayer 内核不需要 libmpv）"
fi
if grep -rnE "package:media_kit" lib/ ; then
  die "lib/ 里仍有 package:media_kit 引用"
fi
echo "[build] 内核：ExoPlayer(Media3)，media_kit 已移除"
# 仓库没有单独的 pubspec 补丁脚本：assets/logo.png 必须由 pubspec 声明，
# 否则构建出来的 APK 会缺 assets/flutter_assets/assets/logo.png。
if ! grep -q -- '- assets/logo.png' pubspec.yaml; then
  die "pubspec.yaml 的 flutter.assets 未声明 assets/logo.png（verify_apk 会因此失败）"
fi

if [ "${SKIP_ANALYZE:-0}" = "1" ]; then
  echo "[build] flutter analyze 已跳过（SKIP_ANALYZE=1）"
else
  echo "[build] flutter analyze"
  flutter analyze
fi

# ------------------------------------------------------------ 6. 构建 APK
# CI：--build-number=${{ github.run_number }} --build-name=1.0.${{ github.run_number }}
# 本地没有 run_number，用秒级时间戳做 versionCode（同款单调递增整数）。
# 不能用 date +%Y%m%d%H%M：12 位数值超出 aapt2 的 int32 上限 2107374182，
# 实测报 "invalid android:versionCode '202611061857'"。
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%s)}"
echo "[build] flutter build apk --release --split-per-abi --target-platform android-arm64"
echo "[build]   versionCode=$BUILD_NUMBER versionName=1.0.${BUILD_NUMBER}"
flutter build apk --release --split-per-abi \
  --target-platform android-arm64 \
  --build-number="$BUILD_NUMBER" \
  --build-name="1.0.${BUILD_NUMBER}"

# ------------------------------------------------------------ 7. 校验门禁
# CI「Verify release APK (comprehensive gate)」同一脚本：
# INTERNET + cleartext + label/icon、MaterialIcons 字体、assets/logo.png、
# libapp/libflutter/libmpv、libmpv 4 段 LOAD ALIGN=0x4000、签名 + zipalign、
# 体积与 sha256；任一不过即退出 1。
APK="build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
if [ ! -f "$APK" ]; then
  die "APK 未生成：$APK" "检查上方 flutter build 输出"
fi
echo "[build] verify_apk.py $APK"
if ! python3 tools/verify_apk.py "$APK"; then
  die "APK 校验未通过（manifest / 字体 / assets / libmpv 16KB / 签名任一项失败）"
fi

APK_SIZE="$(stat -c %s "$APK")"
APK_HUMAN="$(ls -lh "$APK" | awk '{print $5}')"
APK_SHA="$(sha256sum "$APK" | cut -d' ' -f1)"
echo ""
echo "[build] SUCCESS"
echo "  APK     : $REPO_ROOT/$APK"
echo "  size    : $APK_HUMAN ($APK_SIZE bytes)"
echo "  sha256  : $APK_SHA"

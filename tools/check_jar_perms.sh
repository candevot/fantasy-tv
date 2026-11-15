#!/usr/bin/env bash
# DEX_READONLY（2026-11-15）的 JVM 侧验证。
#
# 验什么：`android_src/.../JarPermissions.kt` 在**没有 Android 运行时**的情况下
# 也把 jar 改成 0444 —— 即 Android 14 的判定（`st_mode & 0222 == 0`）真正满足，
# 并且 `File.canWrite()` 变成 false、覆盖写被拒、makeWritable 之后又能写。
#
# 跑两遍：
#   1. 纯 JVM：没有 android.system.*，走 `File.setReadOnly()` / `chmod` 兜底；
#   2. 带 tools/jar_perms_stub 的假 android.system.Os：走**真机同款反射路径**
#      （Os.chmod / Os.stat + StructStat.st_mode），验证反射签名没写错。
#
# 注意：必须**非 root** 跑。root 下 `access(W_OK)` 永远成功，
# `chmod 444` 也证实不了「不能写」，单测会假绿。脚本会自动降权到 nobody。
#
# 没有 kotlinc 的环境（典型 CI runner）直接 SKIP，不算失败：
# 真正拦回归的是 `tools/check_jar_readonly.py` + Gradle 的 Kotlin 编译。
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)
SRC="$ROOT/android_src/kotlin/com/huanxiang/fantasy_tv"
TEST_SRC="$ROOT/tools/jar_perms_jvm_test.kt"
STUB_SRC="$ROOT/tools/jar_perms_stub"
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t jarperm)

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# ---------------------------------------------------------------- 找编译器
# 优先 kotlinc（PATH 里）；没有就用 KOTLIN_COMPILER_JAR 直接喂 K2JVMCompiler。
# 后者是 embeddable 版，自己还缺 coroutines / annotations / trove4j 等，
# 同目录下的 jar 和 kotlinc 安装目录里的一起拼进 -cp（缺了会 NoClassDefFoundError）。
COMPILER=()
if command -v kotlinc >/dev/null 2>&1; then
  COMPILER=(kotlinc)
elif [ -n "${KOTLIN_COMPILER_JAR:-}" ] && [ -f "${KOTLIN_COMPILER_JAR:-}" ]; then
  CCOMPILER_CP="$KOTLIN_COMPILER_JAR"
  for extra in "$(dirname "$KOTLIN_COMPILER_JAR")"/*.jar \
               /usr/share/kotlin/kotlinc/lib/trove4j.jar; do
    [ -f "$extra" ] && case ":$CCOMPILER_CP:" in *":$extra:"*) ;; *) CCOMPILER_CP="$CCOMPILER_CP:$extra";; esac
  done
  COMPILER=(java -cp "$CCOMPILER_CP" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler)
else
  echo 'SKIP: 没有 kotlinc（可用 KOTLIN_COMPILER_JAR 指定 kotlin-compiler jar）'
  exit 0
fi
echo "compiler: ${COMPILER[*]}"

# ---------------------------------------------------------------- 跑的时候降权
if [ "$(id -u)" = "0" ]; then
  if command -v setpriv >/dev/null 2>&1; then
    RUNNER=(setpriv --reuid=65534 --regid=65534 --clear-groups)
  else
    echo 'SKIP: 当前是 root，root 会绕过权限位，单测没有意义（用非 root 用户跑）'
    exit 0
  fi
else
  RUNNER=()
fi
chmod 777 "$TMP"

compile_kotlin() { # $1=输出jar  $2...=额外 -cp
  local out="$1"; shift
  local cp=""
  if [ "$#" -gt 0 ]; then cp="-cp $1"; fi
  "${COMPILER[@]}" -nowarn $cp -include-runtime -d "$out" \
    "$SRC/JarPermissions.kt" "$TEST_SRC" 2>&1 | grep -v '^warning:' | head -20
  [ -f "$out" ]
}

fail=0

echo '=== 1) 纯 JVM（无 android.system.*）：走 File.setReadOnly / chmod 兜底 ==='
if compile_kotlin "$TMP/plain.jar"; then
  chmod -R a+rX "$TMP"
  "${RUNNER[@]}" java -Djava.io.tmpdir="$TMP" -jar "$TMP/plain.jar" || fail=1
else
  echo 'FAIL: 纯 JVM 编译失败'; fail=1
fi

echo
echo '=== 2) 假 android.system.Os（真机同款反射路径）：Os.chmod / Os.stat ==='
mkdir -p "$TMP/stub"
if javac -d "$TMP/stub" "$STUB_SRC"/android/system/*.java 2>&1 | head -10; then
  if compile_kotlin "$TMP/android.jar" "$TMP/stub"; then
    chmod -R a+rX "$TMP"
    "${RUNNER[@]}" java -Djava.io.tmpdir="$TMP" \
      -cp "$TMP/android.jar:$TMP/stub" com.huanxiang.fantasy_tv.Jar_perms_jvm_testKt || fail=1
  else
    echo 'FAIL: 带 android 替身编译失败'; fail=1
  fi
else
  echo 'FAIL: javac 编译 android 替身失败'; fail=1
fi

echo
if [ "$fail" = "0" ]; then echo 'DEX_READONLY 单测全绿'; else echo 'DEX_READONLY 单测有失败项'; fi
exit "$fail"

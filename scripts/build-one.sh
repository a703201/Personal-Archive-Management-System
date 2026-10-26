#!/bin/bash
# ============================================================
# AMS · 单包重编辅助脚本
#
# 用途：修改某个包后，**正确地**重编它与其下游。
#
# 【为什么需要这个脚本】
#   仓颉编译器**优先使用 import-path 里的 .cjo 而非源码**。
#   所以手工执行 `cjc -p <dir> --import-path build` 时，若 build/ 里已有
#   同名旧 .cjo，编译器会直接拿旧的来编 —— **源码改动不生效**，
#   而且新生成的 .cjo 时间戳是新的，导致 build.sh 的增量判断也失效
#   （下游看到「.cjo 比源码新」就 SKIP，于是一路错下去）。
#
#   实测踩坑：改了 UserRepo 加了方法，手工编译后下游报
#   "millisSincePasswordUpdate is not a member of class UserRepo"。
#
# 【正确做法】
#   编译前**先删掉该包的 .cjo 与 .a**，强制编译器从源码重编。
#
# 用法：
#   bash scripts/build-one.sh packages/ams-data/src/repo
#   bash scripts/build-one.sh packages/ams-data/src/repo --downstream
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ $# -lt 1 ]; then
    echo "用法：bash scripts/build-one.sh <包目录> [--downstream]"
    exit 1
fi

PKG_DIR="$1"
shift
WITH_DOWNSTREAM=0
for a in "$@"; do
    case "$a" in
        --downstream) WITH_DOWNSTREAM=1 ;;
    esac
done

if [ ! -d "$PKG_DIR" ]; then
    echo "[ERROR] 包目录不存在：${PKG_DIR}"
    exit 1
fi

# ---- 推导包名（取包声明）----
PKG_NAME="$(grep -m1 -oE '^package [a-zA-Z0-9_.]+' "$PKG_DIR"/*.cj 2>/dev/null | head -1 | awk '{print $2}')"
if [ -z "$PKG_NAME" ]; then
    echo "[ERROR] 无法从 ${PKG_DIR} 解析包名"
    exit 1
fi
CJO="build/${PKG_NAME}.cjo"
LIB="build/lib${PKG_NAME}.a"

echo "=== 重编 ${PKG_NAME} ==="
echo "  包目录: ${PKG_DIR}"

# ---- 关键：先删旧产物，逼编译器从源码重编 ----
rm -f "$CJO" "$LIB"
echo "  已清理旧产物: ${CJO} ${LIB}"

# ---- 编译 ----
source scripts/envsetup.sh >/dev/null 2>&1
if ! cjc -p "$PKG_DIR" \
      --import-path "$CANGJIE_STDX/dynamic/stdx" \
      --import-path build \
      --output-type staticlib \
      --output-dir build 2>&1 | grep -vE "^warning|^\s+\||^\s*$|^note:|^[0-9]+ \||\^|unsecure character" | head -20; then
    echo "[ERROR] 编译失败"
    exit 1
fi

if [ ! -f "$CJO" ]; then
    echo "[ERROR] 未生成 ${CJO}"
    exit 1
fi
echo "  [OK] ${CJO}"
echo "  [OK] ${LIB}"

# ---- 下游重编 ----
if [ "$WITH_DOWNSTREAM" = "1" ]; then
    echo ""
    echo "=== 重编下游 ==="
    bash scripts/build.sh
fi

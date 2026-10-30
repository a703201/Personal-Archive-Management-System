#!/bin/bash
# ============================================================
# AMS · opengauss-driver 编译脚本（Linux 版）
#
# scripts/build-driver.sh 的 Linux 移植：.so 路径、无 .exe、
# 原生绝对路径（无 cygpath）。
#
# 用法：
#   bash scripts/build-driver-linux.sh          # 编译全部子包到 build/drv/
#   bash scripts/build-driver-linux.sh --clean  # 先清空再编译
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DRV_SRC="tools/vendor/opengauss-driver/src"
DRV_OUT="build/drv"

# Linux 下无需 MSYS 路径转换，passthrough。
win_path() {
    echo "$1"
}

# ---- SDK 定位（与 build-linux.sh 一致）----
if [ -z "${CANGJIE_HOME:-}" ] || [ ! -f "${CANGJIE_HOME}/bin/cjc" ]; then
    if [ -f "${ROOT}/tools/cangjie/bin/cjc" ]; then
        CANGJIE_HOME="${ROOT}/tools/cangjie"
    elif [ -f "/opt/cangjie/bin/cjc" ]; then
        CANGJIE_HOME="/opt/cangjie"
    elif [ -f "${HOME}/Cangjie/bin/cjc" ]; then
        CANGJIE_HOME="${HOME}/Cangjie"
    fi
fi

CJC="${CANGJIE_HOME:-/opt/cangjie}/bin/cjc"
STDX_DIR="${CANGJIE_STDX:-${CANGJIE_HOME:-/opt/cangjie}/../cangjie-stdx/linux_x86_64_cjnative}/dynamic/stdx"

if [ ! -f "$CJC" ]; then
    echo "[ERROR] 找不到 cjc：$CJC"
    exit 1
fi
if [ ! -d "$DRV_SRC" ]; then
    echo "[ERROR] 驱动源码不存在：$DRV_SRC"
    echo "        请先执行：bash scripts/install-driver.sh"
    exit 1
fi

if [ "${1:-}" = "--clean" ]; then
    if [ -d "$DRV_OUT" ]; then
        mv -f "$DRV_OUT" "${DRV_OUT}.old.$(date +%s)"
    fi
fi
mkdir -p "$DRV_OUT"

# ---- 依赖顺序（与 Windows 版一致）----
DRV_ORDER=(
    slog
    chunkreader
    subtle
    collections
    sema
    utils
    url
    error
    proto3
    interx
    pgconn
    tinypool
    sqlpool
    driver
)

echo "=== AMS · 编译 opengauss-driver（Linux）==="
echo "  cjc    : ${CJC}"
echo "  stdx   : ${STDX_DIR}"
echo "  输出   : ${DRV_OUT}"
echo ""

FAILED=0
# ---- 暂存测试文件（含 @Test 宏的文件编译静态库前移出，编完放回）----
TESTBAK="build/.drv-testbak"
mkdir -p "$TESTBAK"
for d in "${DRV_SRC}"/*/; do
    p="$(basename "$d")"
    mkdir -p "${TESTBAK}/${p}"
    for f in "$d"*.cj; do
        [ -e "$f" ] || continue
        if grep -q "@Test" "$f" 2>/dev/null; then
            mv "$f" "${TESTBAK}/${p}/" 2>/dev/null || true
        fi
    done
done

restore_tests() {
    for p in "${TESTBAK}"/*/; do
        [ -d "$p" ] || continue
        name="$(basename "$p")"
        for f in "$p"*.cj; do
            [ -e "$f" ] || continue
            mv "$f" "${DRV_SRC}/${name}/" 2>/dev/null || true
        done
    done
}
trap restore_tests EXIT

for p in "${DRV_ORDER[@]}"; do
    d="${DRV_SRC}/${p}"
    if [ ! -d "$d" ]; then
        echo "  [SKIP] ${p}（源码目录不存在）"
        continue
    fi
    printf "  [BUILD] %-14s " "$p"
    if "$CJC" -p "$d" \
              --import-path "$STDX_DIR" \
              --import-path "$DRV_OUT" \
              --output-type staticlib \
              --output-dir "$DRV_OUT" > "/tmp/ams_drv_${p}.log" 2>&1; then
        echo "OK"
    else
        echo "FAILED"
        head -20 "/tmp/ams_drv_${p}.log" | sed 's/^/           /'
        FAILED=1
        break
    fi
done

if [ "$FAILED" = "1" ]; then
    echo ""
    echo "=== 驱动编译失败 ==="
    exit 1
fi

echo ""
echo "=== 驱动编译完成 ==="
ls -1 "$DRV_OUT"/*.a 2>/dev/null | sed 's#.*/##'

#!/bin/bash
# ============================================================
# AMS · opengauss-driver 编译脚本
#
# 用途：把 Cangjie-TPC/opengauss-driver 编译成 ams-data 可链接的静态库。
#
# 为什么自带编译而不是用 cjpm：
#   - 本机 cjpm 崩溃（0xC0000374 堆损坏），cjc 正常；
#   - 驱动用 cjpm 的包命名（cangjie_tpc::opengauss.*），
#     与本项目「子包 = 独立目录」的结构不同，
#     故沿用本项目既有做法：子包粒度 cjc 编译 + 手工链接顺序。
#
# 驱动源码位置：tools/vendor/opengauss-driver（由 scripts/install-driver.sh 拉取）
#
# 用法：
#   bash scripts/build-driver.sh          # 编译全部子包到 build/drv/
#   bash scripts/build-driver.sh --clean  # 先清空再编译
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DRV_SRC="tools/vendor/opengauss-driver/src"
DRV_OUT="build/drv"

# ---- 路径风格转换（Windows 可执行文件无法解析 MSYS 风格路径）----
win_path() {
    [ -z "$1" ] && { echo ""; return; }
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1" 2>/dev/null && return
    fi
    echo "$1"
}

# ---- SDK 定位（与 envsetup.sh / build.sh 一致）----
if [ -z "${CANGJIE_HOME:-}" ] || [ ! -f "${CANGJIE_HOME}/bin/cjc.exe" ]; then
    if [ -f "${ROOT}/tools/cangjie/bin/cjc.exe" ]; then
        CANGJIE_HOME="${ROOT}/tools/cangjie"
    elif [ -f "E:/Cangjie/bin/cjc.exe" ]; then
        CANGJIE_HOME="E:/Cangjie"
    fi
fi

CJ_HOME_WIN="$(win_path "${CANGJIE_HOME:-E:/Cangjie}")"
CJC="${CJ_HOME_WIN}/bin/cjc.exe"
STDX_DIR="$(win_path "${CANGJIE_STDX:-E:/CangjieLibs/windows_x86_64_cjnative}")/dynamic/stdx"

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

# ---- 依赖顺序 ----
# 依据驱动源码的实际 import 关系确定（叶 → 根）。
# 顺序错误会在编译期报 "can not find package"，故此处固定顺序。
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

echo "=== AMS · 编译 opengauss-driver ==="
echo "  cjc    : ${CJC}"
echo "  stdx   : ${STDX_DIR}"
echo "  输出   : ${DRV_OUT}"
echo ""

FAILED=0
# ---- 暂存测试文件 ----
# 驱动源码里带 *_test.cj，用 @Test 宏。编译静态库时它们会被一并处理，
# 而编译器加载 unittest 宏动态库在纯 cjc 环境下不稳定
# （实测报 "could not load the dynamic library ... testmacro.dll"）。
# 故编译前把测试文件移到包外，编完再放回。
TESTBAK="build/.drv-testbak"
mkdir -p "$TESTBAK"
for d in "${DRV_SRC}"/*/; do
    p="$(basename "$d")"
    mkdir -p "${TESTBAK}/${p}"
    for f in "$d"*.cj; do
        [ -e "$f" ] || continue
        # 判定依据是**内容含 @Test 宏**，而非文件名：
        # 驱动里有 type_test_utils.cj 这类不以 _test.cj 结尾却带 @Test 的文件，
        # 只按文件名匹配会漏掉（实测报 "Cannot find method from dynamic libs for macro call 'Test'"）。
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
    # 编译日志写文件，避免 stdout 噪声淹没进度
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

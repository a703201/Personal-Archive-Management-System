#!/bin/bash
# ============================================================
# AMS · 单元测试脚本（cjc 版 · Linux）
#
# scripts/test.sh 的 Linux 移植：原生路径、.so、无 .exe、
# 引导构建改调 build-linux.sh。其余逻辑（增量重建、链接参数收集、
# 结果解析）与 Windows 版一致。
#
# 用法：
#   bash scripts/test-linux.sh              # 跑全部包的测试
#   bash scripts/test-linux.sh ams-kernel   # 只跑指定包
#   bash scripts/test-linux.sh --verbose    # 显示完整编译输出
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="build"
TEST_DIR="build/test"

# Linux 下无需 MSYS 路径转换，passthrough。
win_path() {
    echo "$1"
}
msys_path() {
    echo "$1"
}

# ---- SDK 定位（与 build-linux.sh 一致）----
if [ -z "${CANGJIE_HOME:-}" ] || [ ! -f "${CANGJIE_HOME}/bin/cjc" ]; then
    _root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if [ -f "${_root}/tools/cangjie/bin/cjc" ]; then
        CANGJIE_HOME="${_root}/tools/cangjie"
    elif [ -f "/opt/cangjie/bin/cjc" ]; then
        CANGJIE_HOME="/opt/cangjie"
    elif [ -f "${HOME}/Cangjie/bin/cjc" ]; then
        CANGJIE_HOME="${HOME}/Cangjie"
    fi
fi

CJC="${CANGJIE_HOME:-/opt/cangjie}/bin/cjc"
RUNTIME_DIR="${CANGJIE_HOME:-/opt/cangjie}/runtime/lib/linux_x86_64_cjnative"
STDX_DIR="${CANGJIE_STDX:-${CANGJIE_HOME:-/opt/cangjie}/../cangjie-stdx/linux_x86_64_cjnative}/dynamic/stdx"

VERBOSE=0
PKGS=()
for arg in "$@"; do
    case "$arg" in
        --verbose) VERBOSE=1 ;;
        *) PKGS+=("$arg") ;;
    esac
done

if [ ! -f "$CJC" ]; then
    echo "[ERROR] 找不到 cjc：$CJC"
    echo "        请先设置 CANGJIE_HOME 或将仓颉 SDK 放到 /opt/cangjie"
    exit 1
fi

if [ ${#PKGS[@]} -eq 0 ]; then
    PKGS=(ams-kernel ams-crypto ams-storage ams-data ams-security ams-core ams-app ams-api ams-kit)
fi

mkdir -p "$TEST_DIR"

# stdx 动态库链接参数（Linux：.so + 原生 -L）。
stdx_link_args() {
    local out="-L${STDX_DIR}"
    for so in "$STDX_DIR"/libstdx*.so; do
        [ -f "$so" ] && out="$out -l:$(basename "$so")"
    done
    echo "$out"
}

# 把 stdx 动态库拷入 build 目录（lld 默认搜索路径）。
[ -d "$STDX_DIR" ] && cp "$STDX_DIR"/*.so "$BUILD_DIR/" 2>/dev/null

# ---- 确保产品代码已构建（测试依赖其 cjo 与 .a）----
if [ ! -f "$BUILD_DIR/ams.kernel.cjo" ]; then
    echo "[INFO] 未检测到构建产物，先执行构建..."
    bash "$ROOT/scripts/build-linux.sh" > /tmp/ams_test_build.log 2>&1 || {
        echo "[ERROR] 构建失败："
        tail -20 /tmp/ams_test_build.log | sed 's/^/  /'
        exit 1
    }
fi

# ---- 收集链接参数 ----
ALL_LIBS=""
for a in "$BUILD_DIR"/*.a; do
    [ -f "$a" ] && ALL_LIBS="$ALL_LIBS $(win_path "$ROOT/$a")"
done

DRV_LIBS=""
if [ -d "$BUILD_DIR/drv" ]; then
    for a in "$BUILD_DIR/drv"/*.a; do
        [ -f "$a" ] && DRV_LIBS="$DRV_LIBS $(win_path "$ROOT/$a")"
    done
fi
if [ -n "$DRV_LIBS" ]; then
    ALL_LIBS="$ALL_LIBS$DRV_LIBS"
fi

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_PKGS=()

echo "============================================================"
echo " AMS · 单元测试（cjc · Linux）"
echo "============================================================"

for pkg in "${PKGS[@]}"; do
    tests_root="packages/${pkg}/tests"
    [ -d "$tests_root" ] || continue

    TEST_DIRS=()
    while IFS= read -r d; do
        [ -n "$d" ] && TEST_DIRS+=("$d")
    done < <(find "$tests_root" -name "*_test.cj" -printf "%h\n" 2>/dev/null | sort -u)

    if [ ${#TEST_DIRS[@]} -eq 0 ]; then
        printf "[SKIP] %-14s 无测试\n" "$pkg"
        continue
    fi

    echo ""
    echo "--- ${pkg} ---"

    for tdir in "${TEST_DIRS[@]}"; do
        sub="$(basename "$tdir")"
        out="$TEST_DIR/${pkg}.${sub}"

        src_dir="packages/${pkg}/src/${sub}"

        if [ -d "$src_dir" ]; then
            _cjo="$BUILD_DIR/$(echo "${pkg}" | sed 's#-#.#g').${sub}.cjo"
            _need=0
            if [ ! -f "$_cjo" ]; then
                _need=1
            else
                _newest="$(ls -t "$src_dir"/*.cj 2>/dev/null | head -1)"
                if [ -n "$_newest" ] && [ "$_newest" -nt "$_cjo" ]; then
                    _need=1
                fi
            fi
            if [ "$_need" = 1 ]; then
                [ -f "$_cjo" ] && mv -f "$_cjo" "$_cjo.old" 2>/dev/null
                _lib="$BUILD_DIR/lib$(echo "${pkg}" | sed 's#-#.#g').${sub}.a"
                [ -f "$_lib" ] && mv -f "$_lib" "$_lib.old" 2>/dev/null
                "$CJC" -p "$src_dir" \
                      --import-path "$BUILD_DIR" \
                      --import-path "$STDX_DIR" \
                      --import-path "$BUILD_DIR/drv" \
                      --output-type staticlib \
                      --output-dir "$BUILD_DIR" > /tmp/ams_rebuild.log 2>&1
                if [ ! -f "$_cjo" ]; then
                    echo "  [FAIL]   ${sub} 被测包构建失败"
                    grep -E "error" /tmp/ams_rebuild.log | head -6 | sed 's/^/           /'
                    TOTAL_FAIL=$((TOTAL_FAIL + 1))
                    FAILED_PKGS+=("${pkg}/${sub}")
                    continue
                fi
            fi
        fi

        _link_args="$(stdx_link_args "$tdir" "$src_dir")"

        [ -f "$out" ] && mv -f "$out" "$out.old" 2>/dev/null

        if [ "$VERBOSE" = 1 ]; then
            echo "  [COMPILE] ${pkg}/${sub}"
            "$CJC" -p "$tdir" \
                  --import-path "$BUILD_DIR" \
                  --import-path "$STDX_DIR" \
                  --import-path "$BUILD_DIR/drv" \
                  --test -o "$out" \
                  --link-options "$ALL_LIBS $_link_args" 2>&1 | head -25
        else
            timeout 300 "$CJC" -p "$tdir" \
                  --import-path "$BUILD_DIR" \
                  --import-path "$STDX_DIR" \
                  --import-path "$BUILD_DIR/drv" \
                  --test -o "$out" \
                  --link-options "$ALL_LIBS $_link_args" > /tmp/ams_test_compile.log 2>&1
        fi

        if [ ! -f "$out" ]; then
            echo "  [FAIL]   ${sub} 编译失败"
            grep -E "error" /tmp/ams_test_compile.log 2>/dev/null | head -8 | sed 's/^/           /'
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            FAILED_PKGS+=("${pkg}/${sub}")
            continue
        fi

        # 运行时 .so（仓颉标准库）必须与可执行文件同目录
        [ -d "$STDX_DIR" ] && cp "$STDX_DIR"/*.so "$TEST_DIR/" 2>/dev/null
        [ -d "$RUNTIME_DIR" ] && cp "$RUNTIME_DIR"/*.so "$TEST_DIR/" 2>/dev/null

        # 必须在可执行文件所在目录运行（Linux 下 rpath/同目录查找 .so）
        RESULT="$(cd "$TEST_DIR" && timeout 120 "./$(basename "$out")" 2>&1)"

        CLEAN="$(echo "$RESULT" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')"
        PASSED=$(echo "$CLEAN" | grep -oE "PASSED:[[:space:]]*[0-9]+" | head -1 | grep -oE "[0-9]+")
        FAILED=$(echo "$CLEAN" | grep -oE "FAILED:[[:space:]]*[0-9]+" | head -1 | grep -oE "[0-9]+")
        ERRORS=$(echo "$CLEAN" | grep -oE "ERROR:[[:space:]]*[0-9]+" | head -1 | grep -oE "[0-9]+")
        PASSED=${PASSED:-0}; FAILED=${FAILED:-0}; ERRORS=${ERRORS:-0}

        if [ "$FAILED" -gt 0 ] || [ "$ERRORS" -gt 0 ]; then
            echo "  [FAIL]   ${sub}  通过 ${PASSED} / 失败 ${FAILED} / 错误 ${ERRORS}"
            echo "$CLEAN" | grep -E "FAILED|ERROR" | head -8 | sed 's/^/           /'
            TOTAL_FAIL=$((TOTAL_FAIL + FAILED + ERRORS))
            FAILED_PKGS+=("${pkg}/${sub}")
        else
            echo "  [PASS]   ${sub}  ${PASSED} 个用例"
            TOTAL_PASS=$((TOTAL_PASS + PASSED))
        fi
    done
done

echo ""
echo "============================================================"
echo " 通过 ${TOTAL_PASS} 个用例，失败 ${TOTAL_FAIL} 个"
if [ ${#FAILED_PKGS[@]} -gt 0 ]; then
    echo " 失败位置：${FAILED_PKGS[*]}"
fi
echo "============================================================"

[ "$TOTAL_FAIL" -eq 0 ] || exit 1

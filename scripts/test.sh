#!/bin/bash
# ============================================================
# AMS · 单元测试脚本（cjc 版）
#
# 为什么不用 cjpm test：实测 cjpm 1.0.5 在本机 Windows 上 build 阶段
# 触发堆损坏（0xC0000374），与路径/版本/工程结构均无关。CI 用 cjpm。
#
# ⚠️ 测试结构约定（实测 SDK 1.0.5，本脚本据此设计）：
#   1. **测试代码与产品代码物理分离**：测试在 packages/<pkg>/tests/<sub>/，
#      产品代码在 packages/<pkg>/src/<sub>/。
#      原因：编译器优先使用 import-path 里的 .cjo 而非源码；若测试与产品
#      代码同目录，.cjo 会混入未展开的测试宏，后续编译报出莫名的
#      "expected '=>' in lambda expression"。
#   2. 测试包声明为 <被测包>.test，用 import 引用被测包。
#   3. 编译顺序：先 build（产出被测包的 cjo 与 .a），再编译测试包。
#
# 用法：
#   bash scripts/test.sh              # 跑全部包的测试
#   bash scripts/test.sh ams-kernel   # 只跑指定包
#   bash scripts/test.sh --verbose    # 显示完整编译输出
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="build"
TEST_DIR="build/test"

# ---- 路径风格 ----
# cjc 的 --import-path 用 MSYS 风格（/e/...）才有效；
# --link-options 里的 -L 用 Windows 风格（E:/...）才有效。
win_path() {
    [ -z "$1" ] && { echo ""; return; }
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1" 2>/dev/null && return
    fi
    echo "$1"
}
msys_path() {
    [ -z "$1" ] && { echo ""; return; }
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$1" 2>/dev/null && return
    fi
    echo "$1"
}

# ---- SDK 定位（与 envsetup.sh / build.sh 保持一致）----
# 本脚本独立执行时 shell 里没有 CANGJIE_HOME，需自行探测。
if [ -z "${CANGJIE_HOME:-}" ] || [ ! -f "${CANGJIE_HOME}/bin/cjc.exe" ]; then
    _root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if [ -f "${_root}/tools/cangjie/bin/cjc.exe" ]; then
        CANGJIE_HOME="${_root}/tools/cangjie"
    elif [ -f "E:/Cangjie/bin/cjc.exe" ]; then
        CANGJIE_HOME="E:/Cangjie"
    fi
fi

CJ_HOME_WIN="$(win_path "${CANGJIE_HOME:-E:/Cangjie}")"
CJC="${CJ_HOME_WIN}/bin/cjc.exe"
RUNTIME_DIR="${CJ_HOME_WIN}/runtime/lib/windows_x86_64_cjnative"
STDX_DIR="$(win_path "${CANGJIE_STDX:-E:/CangjieLibs/windows_x86_64_cjnative}")/dynamic/stdx"
STDX_DIR_MSYS="$(msys_path "${CANGJIE_STDX:-E:/CangjieLibs/windows_x86_64_cjnative}")/dynamic/stdx"

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
    echo "        请先执行：source scripts/envsetup.sh"
    exit 1
fi

if [ ${#PKGS[@]} -eq 0 ]; then
    PKGS=(ams-kernel ams-crypto ams-storage ams-data ams-security ams-core ams-app ams-api)
fi

mkdir -p "$TEST_DIR"

# stdx 动态库链接参数。
# -L 用 Windows 风格（lld 不认 MSYS 风格，且 cjc 的 -L 选项会被 MSYS 转换丢盘符）
# -l: 用完整文件名（含点号的库名 lld 才能定位）
# 只链接**实际被 import** 的库 —— 未被 import 的库单独传入会报
# "unable to find library"（它们是别的库的依赖，不能作为链接输入）。
stdx_link_args() {
    # 全量链接 stdx 动态库。
    # 实测（SDK 1.0.5 / Git Bash）：
    #   -L 必须用 **Windows 风格**（E:/...）；cjc 的 -L 选项会被 MSYS 转换丢盘符
    #   -l: 用完整文件名（含点号的库名 lld 才能定位）
    #   - 全量传入可行（早期 "unable to find library" 是 -L 风格错误所致）
    local out="-L${STDX_DIR}"
    for dll in "$STDX_DIR"/libstdx*.dll; do
        [ -f "$dll" ] && out="$out -l:$(basename "$dll")"
    done
    echo "$out"
}

# stdx 动态库拷入 build 目录：lld 在默认搜索路径里找它们。
# 说明：--link-options 里的 -L / -l: 在 Git Bash 下会被 MSYS 路径转换搞乱
#（-L 丢盘符、含点号的库名定位不到），故改用「把 dll 放到搜索目录」的方式。
[ -d "$STDX_DIR" ] && cp "$STDX_DIR"/*.dll "$BUILD_DIR/" 2>/dev/null

# ---- 确保产品代码已构建（测试依赖其 cjo 与 .a）----
if [ ! -f "$BUILD_DIR/ams.kernel.cjo" ]; then
    echo "[INFO] 未检测到构建产物，先执行构建..."
    bash "$ROOT/scripts/build.sh" > /tmp/ams_test_build.log 2>&1 || {
        echo "[ERROR] 构建失败："
        tail -20 /tmp/ams_test_build.log | sed 's/^/  /'
        exit 1
    }
fi

# ---- 收集链接参数 ----
# 产品库的 .a：绝对路径（链接器工作目录可能不同）
# 注意：必须用 **Windows 风格**的绝对路径 —— lld 不认 MSYS 风格（/e/...）
ALL_LIBS=""
for a in "$BUILD_DIR"/*.a; do
    [ -f "$a" ] && ALL_LIBS="$ALL_LIBS $(win_path "$ROOT/$a")"
done

# opengauss-driver 的静态库（在 build/drv/ 子目录，不在上面那个 glob 范围内）
# ams-data 的集成测试需要链接它们。
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
echo " AMS · 单元测试（cjc）"
echo "============================================================"

for pkg in "${PKGS[@]}"; do
    tests_root="packages/${pkg}/tests"
    [ -d "$tests_root" ] || continue

    # 找出所有含 *_test.cj 的目录（每个目录是一个测试包）
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
        [ "${AMS_DEBUG_CMD:-0}" = 1 ] && echo "  [T] $(date +%H:%M:%S) 开始 ${sub}" >&2
        out="$TEST_DIR/${pkg}.${sub}.exe"

        # 被测包源码目录
        src_dir="packages/${pkg}/src/${sub}"

        # 编译器优先使用 import-path 里的 .cjo 而非源码，
        # 故被测包的 cjo 缺失时需先构建（否则测试 import 不到该包）。
        if [ -d "$src_dir" ]; then
            _cjo="$BUILD_DIR/$(echo "${pkg}" | sed 's#-#.#g').${sub}.cjo"
            # 增量重建：仅当源码比 .cjo 新时才重建。
            # 原因：编译器优先用 import-path 里的 .cjo 而非源码，
            #       不重建就会编译到旧代码（这是本项目反复踩的坑）；
            #       但每次都重建会让测试慢一个数量级。
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
                # 用 mv 而非 rm 移走旧产物：
                #   - 保留原文件（可回滚），符合项目「优先 mv 而非 rm」纪律
                #   - 避开 safe-bin 对 rm 的拦截
                [ -f "$_cjo" ] && mv -f "$_cjo" "$_cjo.old" 2>/dev/null
                _lib="$BUILD_DIR/lib$(echo "${pkg}" | sed 's#-#.#g').${sub}.a"
                [ -f "$_lib" ] && mv -f "$_lib" "$_lib.old" 2>/dev/null
                "$CJC" -p "$src_dir" \
                      --import-path "$BUILD_DIR" \
                      --import-path "$STDX_DIR_MSYS" \
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

        # ⚠️ 必须先移走旧 exe —— 否则**编译失败时旧 exe 仍在**，
        #    后面 `if [ ! -f "$out" ]` 会误判为「编译成功」，
        #    于是跑的是**旧版本**测试（结果与源码不一致，极难察觉）。
        #    实测踩坑：加了新测试用例后编译报错（@Test 必须在顶层），
        #    但输出仍是修改前的 27 通过 / 2 失败。
        #    build.sh 早已有同样处理，此处补齐。
        [ -f "$out" ] && mv -f "$out" "$out.old" 2>/dev/null

        if [ "$VERBOSE" = 1 ]; then
            echo "  [COMPILE] ${pkg}/${sub}"
            "$CJC" -p "$tdir" \
                  --import-path "$BUILD_DIR" \
                  --import-path "$STDX_DIR_MSYS" \
                  --import-path "$BUILD_DIR/drv" \
                  --test -o "$out" \
                  --link-options "$ALL_LIBS $_link_args" 2>&1 | head -25
        else
            # 链接 20+ 个静态库与 25+ 个 dll，耗时较长 —— 给足超时但防挂死
            timeout 300 "$CJC" -p "$tdir" \
                  --import-path "$BUILD_DIR" \
                  --import-path "$STDX_DIR_MSYS" \
                  --import-path "$BUILD_DIR/drv" \
                  --test -o "$out" \
                  --link-options "$ALL_LIBS $_link_args" > /tmp/ams_test_compile.log 2>&1
        fi

        if [ ! -f "$out" ]; then
            echo "  [FAIL]   ${sub} 编译失败"
            grep -E "error" /tmp/ams_test_compile.log 2>/dev/null | head -8 | sed 's/^/           /'
            if [ "${AMS_DEBUG_CMD:-0}" = 1 ]; then
                echo "  [LOG] 完整编译日志：" >&2
                cat /tmp/ams_test_compile.log >&2
            fi
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            FAILED_PKGS+=("${pkg}/${sub}")
            continue
        fi

        [ "${AMS_DEBUG_CMD:-0}" = 1 ] && echo "  [T] $(date +%H:%M:%S) 编译完成 ${sub}" >&2

        [ -d "$STDX_DIR" ] && cp "$STDX_DIR"/*.dll "$TEST_DIR/" 2>/dev/null
        # 运行时 DLL（仓颉标准库 + MinGW 运行库）必须与 exe 同目录，
        # 否则 exe 静默退出（无输出 → 0 个用例）。
        # 注意 MinGW 运行库（libgcc_s_seh-1.dll / libwinpthread-1.dll）
        # 是 SDK 1.2.0 的已知缺件，由 install-sdk.sh 补齐到 runtime 目录。
        [ -d "$RUNTIME_DIR" ] && cp "$RUNTIME_DIR"/*.dll "$TEST_DIR/" 2>/dev/null

        # 必须在 exe 所在目录运行，否则 exe 静默退出（无输出 → 0 个用例）
        RESULT="$(cd "$TEST_DIR" && timeout 120 "./$(basename "$out")" 2>&1)"

        # 统计行形如 "    PASSED: 4, SKIPPED: 0, ERROR: 0"（有缩进），
        # 且测试框架输出带 ANSI 颜色转义码，须先剥离
        CLEAN="$(echo "$RESULT" | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')"
        PASSED=$(echo "$CLEAN" | grep -oE "PASSED:[[:space:]]*[0-9]+" | head -1 | grep -oE "[0-9]+")
        FAILED=$(echo "$CLEAN" | grep -oE "FAILED:[[:space:]]*[0-9]+" | head -1 | grep -oE "[0-9]+")
        ERRORS=$(echo "$CLEAN" | grep -oE "ERROR:[[:space:]]*[0-9]+" | head -1 | grep -oE "[0-9]+")
        PASSED=${PASSED:-0}; FAILED=${FAILED:-0}; ERRORS=${ERRORS:-0}

        [ "${AMS_DEBUG_CMD:-0}" = 1 ] && echo "  [T] $(date +%H:%M:%S) 运行完成 ${sub}" >&2
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

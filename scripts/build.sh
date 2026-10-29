#!/bin/bash
# ============================================================
# AMS · 本机构建脚本（cjc 版 · 子包粒度）
#
# 为什么不用 cjpm：实测 cjpm 1.0.5 在本机 Windows 上 build 阶段
# 触发堆损坏（0xC0000374），与路径/SDK 版本/工程结构均无关。cjpm 留给 CI。
#
# ⚠️ 仓颉包结构约定（实测 SDK 1.0.5，决定了本脚本的组织方式）：
#   1. 同一 src 目录下只能有一个包声明 → 子包必须独立目录
#        packages/ams-kernel/src/         → package ams.kernel
#        packages/ams-kernel/src/error/  → package ams.kernel.error
#   2. `cjc -p <目录>` 编译该包，但**只产出该包的 .cjo**；
#      子包的 .cjo 必须**单独编译该子包目录**才产出
#   3. 跨包 import 依赖 .cjo → 子包必须逐个编译，顺序按依赖
#   4. 链接时需同时提供被 import 包的 .cjo（--import-path）与 .a（--link-options）
#
# 用法：
#   bash scripts/build.sh                # 构建全部
#   bash scripts/build.sh ams-kernel     # 只构建指定顶层包（含其子包）
#   bash scripts/build.sh --clean        # 清理后重建
#
# 产物：
#   build/<pkg>.cjo                     # 包元信息（供下游 import）
#   build/lib<pkg>.a                    # 静态库（供链接）
#   build/ams-server.exe                # 可执行文件
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="build"
DRV_DIR="build/drv"

# ---- 路径风格转换 ----
# envsetup.sh 后 CANGJIE_HOME 可能是 MSYS 风格（/e/...），
# Windows 可执行文件无法解析该格式，这里统一转成 Windows 风格（E:/...）。
# 用 cygpath -m（MSYS 自带）而非手工字符串替换，避免反斜杠转义陷阱。
win_path() {
    [ -z "$1" ] && { echo ""; return; }
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1" 2>/dev/null && return
    fi
    echo "$1"
}

# ---- SDK 定位（与 envsetup.sh 保持一致）----
# 背景：本脚本常被独立执行（`bash scripts/build.sh`），此时 shell 环境里
#       没有 CANGJIE_HOME。故此处自行探测，优先级：
#         ① 仓库内副本 tools/cangjie（团队一致环境）
#         ② E:/Cangjie
#         ③ 环境变量 CANGJIE_HOME
if [ -z "${CANGJIE_HOME:-}" ] || [ ! -f "${CANGJIE_HOME}/bin/cjc.exe" ]; then
    if [ -f "${ROOT}/tools/cangjie/bin/cjc.exe" ]; then
        CANGJIE_HOME="${ROOT}/tools/cangjie"
    elif [ -f "E:/Cangjie/bin/cjc.exe" ]; then
        CANGJIE_HOME="E:/Cangjie"
    fi
fi

CJ_HOME_WIN="$(win_path "${CANGJIE_HOME:-E:/Cangjie}")"
CJC="${CJ_HOME_WIN}/bin/cjc.exe"
RUNTIME_DIR="${CJ_HOME_WIN}/runtime/lib/windows_x86_64_cjnative"
STDX_DIR="$(win_path "${CANGJIE_STDX:-E:/CangjieLibs/windows_x86_64_cjnative}")/dynamic/stdx"

# ---- opengauss-driver 静态库（ams-data 依赖）----
# 驱动由 scripts/build-driver.sh 编译到 build/drv/。
# 未编译时 ams-data 会编译失败（缺 cangjie_tpc::opengauss.* 包），
# 故此处在编译 ams-data 前检查并给出明确提示。
DRV_LIBS=""
if [ -d "$DRV_DIR" ]; then
    for a in "$DRV_DIR"/*.a; do
        [ -e "$a" ] || continue
        DRV_LIBS="$DRV_LIBS $(win_path "$ROOT/$a")"
    done
fi
HAS_DRV=0
[ -n "$DRV_LIBS" ] && HAS_DRV=1

# 需要 ams-data 时，驱动缺失则自动构建（一次到位，避免手工两步）
# ⚠️ TARGETS 原在第 111 行才声明，但此处已在 `set -u` 下提前引用，
#    环境无 TARGETS 变量时会报 "unbound variable"。故在此先完成参数解析。
CLEAN=0
TARGETS=()
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=1 ;;
        *) TARGETS+=("$arg") ;;
    esac
done

NEEDS_DRV=0
for t in "${TARGETS[@]:-}"; do
    case "$t" in
        ams-data|ams-app|ams-api|ams-server|all) NEEDS_DRV=1 ;;
    esac
done
[ ${#TARGETS[@]} -eq 0 ] && NEEDS_DRV=1

if [ "$NEEDS_DRV" = "1" ] && [ "$HAS_DRV" = "0" ]; then
    if [ -d "tools/vendor/opengauss-driver/src" ]; then
        echo "[INFO] 未检测到 opengauss-driver 产物，自动构建..."
        bash "$ROOT/scripts/build-driver.sh" > /tmp/ams_build_driver.log 2>&1 || {
            echo "[ERROR] 驱动构建失败："
            tail -20 /tmp/ams_build_driver.log | sed 's/^/  /'
            exit 1
        }
        DRV_LIBS=""
        for a in "$DRV_DIR"/*.a; do
            [ -e "$a" ] || continue
            DRV_LIBS="$DRV_LIBS $(win_path "$ROOT/$a")"
        done
        HAS_DRV=0
        [ -n "$DRV_LIBS" ] && HAS_DRV=1
    else
        echo "[WARN] 未找到驱动源码（tools/vendor/opengauss-driver），"
        echo "       ams-data 及其上层将无法构建。请先执行：bash scripts/install-driver.sh"
    fi
fi

if [ ! -f "$CJC" ]; then
    echo "[ERROR] 找不到 cjc：$CJC"
    echo "        请先执行：source scripts/envsetup.sh"
    exit 1
fi

if [ "$CLEAN" = 1 ]; then
    echo "=== 清理 ==="
    rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"

# stdx 动态库拷入 build 目录（lld 默认搜索路径），
# 避免 --link-options 里的 -L / -l: 被 MSYS 路径转换搞乱
[ -d "$STDX_DIR" ] && cp "$STDX_DIR"/*.dll "$BUILD_DIR/" 2>/dev/null

# ---- 顶层包顺序（架构 §4.2 分层依赖规则）----
# ⚠️ 依赖方向：ams.data → ams.core.search（SearchQuery 等），
#    ams.core 不反向依赖 ams.data。故 ams.core 必须排在 ams.data 之前，
#    否则增量构建时 ams.data.repo 会用到尚未重编的陈旧 ams.core.search.cjo。
TOP_ORDER=(
    ams-kernel
    ams-crypto
    ams-storage
    ams-core
    ams-data
    ams-security
    ams-app
    ams-api
    ams-server
)

# ---- 选出要构建的顶层包（连带其前置依赖）----
select_top() {
    local want=("$@")
    [ ${#want[@]} -eq 0 ] && { echo "${TOP_ORDER[@]}"; return; }
    local sel=() seen=" "
    for w in "${want[@]}"; do
        for p in "${TOP_ORDER[@]}"; do
            case " $seen " in *" $p "*) continue ;; esac
            sel+=("$p"); seen="$seen$p "
            [ "$p" = "$w" ] && break
        done
    done
    echo "${sel[@]}"
}

# ---- 目录 → 包名 ----
#   packages/ams-kernel/src        → ams.kernel
#   packages/ams-kernel/src/error  → ams.kernel.error
dir_to_pkg() {
    local d="$1"
    local top
    top="$(echo "$d" | sed 's#^packages/##; s#/.*##')"          # ams-kernel
    local topdot
    topdot="$(echo "$top" | sed 's#-#.#g')"                     # ams.kernel

    # 子包路径（相对 src/），父包为空
    local rel
    rel="$(echo "$d" | sed "s#^packages/${top}/src##")"        # /error
    rel="${rel#/}"
    rel="${rel%/}"

    if [ -z "$rel" ]; then
        echo "$topdot"
    else
        echo "${topdot}.$(echo "$rel" | sed 's#/#.#g')"
    fi
}


# ---- 收集某顶层包下需编译的子包目录（按依赖拓扑序）----
SUBPKG_DIRS=()
collect_subpkgs() {
    local top="$1"
    local src="packages/${top}/src"
    SUBPKG_DIRS=()
    [ -d "$src" ] || return

    # 父包排最前
    if ls "$src"/*.cj >/dev/null 2>&1; then
        SUBPKG_DIRS+=("$src")
    fi

    # 子包：按 import 依赖做拓扑排序
    # 注意：仅靠「cjo 是否已存在」判断是不够的 —— 首次构建时所有 cjo 都不存在，
    # 同级子包之间的依赖（如 impl → provider）会排不出正确顺序。
    # 故这里显式构建依赖图并做 Kahn 排序。
    local dirs=()
    for d in "$src"/*/; do
        [ -d "$d" ] && dirs+=("$d")
    done
    [ ${#dirs[@]} -eq 0 ] && return

    # 依赖矩阵：deps[i] = 第 i 个子包依赖的子包下标集合（用空格分隔的字符串存）
    local deps=()
    local names=()
    for d in "${dirs[@]}"; do
        names+=("$(dir_to_pkg "$d")")
    done

    for d in "${dirs[@]}"; do
        local dep_list=""
        for imp in $(grep -rhoE "^import [a-z][a-z0-9_.]*" "$d"/*.cj 2>/dev/null | \
                     sed 's/^import //; s/\.\+$//' | sort -u); do
            case "$imp" in
                std.*|stdx.*) continue ;;
            esac
            # 找出 import 目标对应的子包下标
            for ((i = 0; i < ${#names[@]}; i++)); do
                if [ "${names[$i]}" = "$imp" ]; then
                    dep_list="$dep_list $i"
                    break
                fi
            done
        done
        deps+=("$dep_list")
    done

    # Kahn 拓扑排序
    local done_flags=""
    local total=${#dirs[@]}
    local count=0
    while [ "$count" -lt "$total" ]; do
        local picked=0
        for ((i = 0; i < total; i++)); do
            case " $done_flags " in *" $i "*) continue ;; esac
            # 该子包的所有依赖是否都已完成？
            local ready=1
            for j in ${deps[$i]}; do
                case " $done_flags " in
                    *" $j "*) ;;
                    *) ready=0 ;;
                esac
            done
            if [ "$ready" = 1 ]; then
                SUBPKG_DIRS+=("${dirs[$i]}")
                done_flags="$done_flags $i"
                count=$((count + 1))
                picked=1
                break
            fi
        done
        if [ "$picked" = 0 ]; then
            # 存在循环依赖 → 剩余的按原序输出，编译时会报错暴露问题
            for ((i = 0; i < total; i++)); do
                case " $done_flags " in
                    *" $i "*) ;;
                    *) SUBPKG_DIRS+=("${dirs[$i]}") ;;
                esac
            done
            break
        fi
    done
}



TOPS=($(select_top "${TARGETS[@]:-}"))
LINK_LIBS=""
STDX_LIBS_ALL=""
BUILT=()
# 级联重建标记：本轮已有包被重建 → 后续包一律重编
CASCADE_REBUILD=0

# ---- stdx 动态库的链接参数 ----
# stdx 的包（crypto / encoding / net / serialization ...）编译成动态库，
# 链接 exe 时必须显式给出，否则报
#   "undefined symbol: _CGP18stdx.crypto.cryptoiiHv"
#
# 做法（与 test.sh 一致）：
#   ① 把 dll 拷到 build/ 目录（lld 的默认搜索路径）
#   ② 链接参数里用 `-l:完整文件名` 指定（库名含点号，lld 才能定位）
#   ③ `-L` 必须用 **Windows 风格**（E:/...）—— cjc 的 -L 选项会被
#      MSYS 路径转换吃掉盘符，导致找不到库。
if [ -d "$STDX_DIR" ]; then
    for dll in "$STDX_DIR"/libstdx*.dll; do
        [ -f "$dll" ] && STDX_LIBS_ALL="$STDX_LIBS_ALL -l:$(basename "$dll")"
    done
    STDX_LIBS_ALL="-L${STDX_DIR} $STDX_LIBS_ALL"
fi

echo "=== AMS 构建（cjc · 子包粒度）==="
echo "  CANGJIE_HOME : ${CJ_HOME_WIN}"
echo "  CANGJIE_STDX : ${STDX_DIR}"
echo ""

for top in "${TOPS[@]}"; do
    src="packages/${top}/src"
    [ -d "$src" ] || { echo "[SKIP] ${top}（无 src 目录）"; continue; }

    echo "--- ${top} ---"
    collect_subpkgs "$top"

    for subdir in "${SUBPKG_DIRS[@]}"; do
        [ -d "$subdir" ] || continue
        ls "$subdir"/*.cj >/dev/null 2>&1 || continue

        pkgname="$(dir_to_pkg "$subdir")"
        printf "  [BUILD] %-26s " "$pkgname"


        if [ "$pkgname" = "ams.server" ]; then
            # 入口包：编译为可执行文件
            # 链接顺序：AMS 包 -> opengauss-driver -> stdx 动态导入库
            #
            # ⚠️ 必须先移走旧 exe：若链接失败而旧 exe 仍在，
            #    后面的 `if [ -f ... ]` 会误判为「编译成功」，
            #    导致跑的是旧版本（本项目踩过：日志显示旧内容但报告 OK）。
            [ -f "$BUILD_DIR/ams-server.exe" ] && mv -f "$BUILD_DIR/ams-server.exe" "$BUILD_DIR/ams-server.exe.old" 2>/dev/null
            _link="$LINK_LIBS $DRV_LIBS $STDX_LIBS_ALL"
            "$CJC" -p "$subdir" \
                  --import-path "$BUILD_DIR" \
                  --import-path "$STDX_DIR" \
                  --import-path "$DRV_DIR" \
                  --output-type exe \
                  -o "$BUILD_DIR/ams-server.exe" \
                  --link-options "$_link" > /tmp/ams_build.log 2>&1
            if [ -f "$BUILD_DIR/ams-server.exe" ]; then
                echo "OK -> build/ams-server.exe"
            else
                echo "FAILED"
                head -15 /tmp/ams_build.log | sed 's/^/           /'
                exit 1
            fi
        else
            # 只在「源码比 .cjo 新」时重编：
            # 编译器优先使用 import-path 里的 .cjo 而非源码，
            # 所以源码改动后必须重编，否则改动不生效（这是本项目踩过的坑）。
            # 用时间戳判断而非每次全量重编 —— 后者会让构建慢一个数量级。
            #
            # ⚠️ 但**上游包变了，下游也必须重编** —— 下游的 .cjo 里固化了
            #    上游的接口快照（如 Authorizer 新增方法后，ams.app.authz 的
            #    .cjo 仍认为该方法不存在 → 报 "is not a member of class"）。
            #    故用 CASCADE_REBUILD 标记：**本轮已有包被重建**时，
            #    后续所有包一律重编（级联失效）。
            #    代价是改动后全量重编一次（约 1~2 分钟），换来正确性。
            _cjo="$BUILD_DIR/${pkgname}.cjo"
            _need_build=1
            if [ "$CASCADE_REBUILD" = "1" ]; then
                _need_build=1
            elif [ -f "$_cjo" ]; then
                _newest_src="$(ls -t "$subdir"/*.cj 2>/dev/null | head -1)"
                if [ -n "$_newest_src" ] && [ "$_newest_src" -ot "$_cjo" ]; then
                    _need_build=0
                fi
            fi
            if [ "$_need_build" = 0 ]; then
                echo "SKIP (未变更)"
                LINK_LIBS="$LINK_LIBS $(win_path "$ROOT/$BUILD_DIR/lib${pkgname}.a")"
                BUILT+=("$pkgname")
                continue
            fi
            rm -f "$_cjo" "$BUILD_DIR/lib${pkgname}.a"
            # ams-data 依赖 opengauss-driver（cangjie_tpc::opengauss.*），
            # 故编译该包时额外引入 build/drv 作为 import-path。
            if [ "$pkgname" = "ams.data" ] || [ "$pkgname" = "ams.data.db" ] || \
               [ "$pkgname" = "ams.data.repo" ]; then
                if [ "$HAS_DRV" = "0" ]; then
                    echo "FAILED（缺 opengauss-driver：请先执行 bash scripts/build-driver.sh）"
                    exit 1
                fi
                "$CJC" -p "$subdir" \
                      --import-path "$BUILD_DIR" \
                      --import-path "$STDX_DIR" \
                      --import-path "$DRV_DIR" \
                      --output-type staticlib \
                      --output-dir "$BUILD_DIR" > /tmp/ams_build.log 2>&1
            else
                "$CJC" -p "$subdir" \
                      --import-path "$BUILD_DIR" \
                      --import-path "$STDX_DIR" \
                      --output-type staticlib \
                      --output-dir "$BUILD_DIR" > /tmp/ams_build.log 2>&1
            fi
            lib="$BUILD_DIR/lib${pkgname}.a"
            if [ -f "$lib" ]; then
                echo "OK -> $(basename "$lib")"
                # 本包重建了 → 其下游也必须重编（级联失效，见上）
                CASCADE_REBUILD=1
                LINK_LIBS="$LINK_LIBS $(win_path "$ROOT/$lib")"
                BUILT+=("$pkgname")
            else
                echo "FAILED (期望产物 $lib)"
                # 只显示 **error 行**及其上下文 —— 之前的 head -15 会被
                # warning 淹没，导致真实编译错误看不见（踩过坑）。
                grep -n -A6 "error:" /tmp/ams_build.log | head -40 | sed 's/^/           /'
                exit 1
            fi
        fi
    done
done

# ---- 拷贝运行时 DLL（Windows 必需）----
[ -d "$RUNTIME_DIR" ] && cp "$RUNTIME_DIR"/*.dll "$BUILD_DIR/" 2>/dev/null
[ -d "$STDX_DIR" ] && cp "$STDX_DIR"/*.dll "$BUILD_DIR/" 2>/dev/null

echo ""
echo "=== 构建完成 ==="
ls -lh "$BUILD_DIR"/ams-server.exe 2>/dev/null || true
echo "已构建: ${BUILT[*]}"

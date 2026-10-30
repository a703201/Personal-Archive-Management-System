#!/bin/bash
# ============================================================
# AMS · Linux 构建脚本（cjc 版 · 子包粒度）
#
# 这是 scripts/build.sh 的 Linux 移植版。Windows 版因 cjpm 1.0.5
# 堆损坏而走自研 cjc 子包编译；Linux 上 cjpm 可用，但本工程刻意采用
# 「子包 = 独立目录」结构（cjpm 的项目模型不直接适配），故 Linux 同样
# 走 cjc 子包粒度编译，仅替换平台相关差异：
#
#   Windows                              → Linux
#   ---------------------------------------------------------------
#   cygpath -m（MSYS 路径转换）          → 原生绝对路径（passthrough）
#   bin/cjc.exe                          → bin/cjc
#   runtime/lib/windows_x86_64_cjnative  → runtime/lib/linux_x86_64_cjnative
#   CANGJIE_STDX/.../windows_x86_64_*    → .../linux_x86_64_*
#   *.dll（运行时 + stdx 动态库）        → *.so
#   产物 ams-server.exe                  → ams-server（无扩展名）
#   SDK 探测 tools/cangjie / E:/Cangjie  → /opt/cangjie / tools/cangjie
#
# ⚠️ 本脚本在本仓库的 Windows 开发机上无法验证（沙箱无 Linux），
#    属 best-effort 移植，需在 Linux runner（含 Cangjie SDK 1.2.x）上实测。
#    已知风险点：stdx 动态库文件名/数量、运行时 .so 清单、lld 的 -L 风格
#    均以 Windows 经验推断，Linux 上若报 "undefined symbol" 多半是 .so
#    漏拷或 -L 路径不对，请先核对 STDX_DIR 与 RUNTIME_DIR。
#
# 用法：
#   bash scripts/build-linux.sh                # 构建全部
#   bash scripts/build-linux.sh ams-kernel     # 只构建指定顶层包（含其子包）
#   bash scripts/build-linux.sh --clean        # 清理后重建
#
# 产物：
#   build/<pkg>.cjo                     # 包元信息（供下游 import）
#   build/lib<pkg>.a                    # 静态库（供链接）
#   build/ams-server                    # 可执行文件（无扩展名）
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="build"
DRV_DIR="build/drv"

# ---- 路径风格转换 ----
# Linux 下 cjc/lld 直接用原生绝对路径即可，无需 MSYS 转换。
# 保留函数签名以兼容调用点，但一律原样返回。
win_path() {
    echo "$1"
}

# ---- SDK 定位（与 envsetup.sh 保持一致）----
# Linux 探测优先级：
#   ① 环境变量 CANGJIE_HOME
#   ② 仓库内副本 tools/cangjie（团队一致环境）
#   ③ /opt/cangjie（常见系统安装位置）
#   ④ $HOME/Cangjie
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
RUNTIME_DIR="${CANGJIE_HOME:-/opt/cangjie}/runtime/lib/linux_x86_64_cjnative"
# stdx 动态库目录：Linux 上通常是 cangjie-stdx 安装根的 linux_x86_64_cjnative/dynamic/stdx
STDX_DIR="${CANGJIE_STDX:-${CANGJIE_HOME:-/opt/cangjie}/../cangjie-stdx/linux_x86_64_cjnative}/dynamic/stdx"

# ---- opengauss-driver 静态库（ams-data 依赖）----
DRV_LIBS=""
if [ -d "$DRV_DIR" ]; then
    for a in "$DRV_DIR"/*.a; do
        [ -e "$a" ] || continue
        DRV_LIBS="$DRV_LIBS $(win_path "$ROOT/$a")"
    done
fi
HAS_DRV=0
[ -n "$DRV_LIBS" ] && HAS_DRV=1

# 参数解析（同 Windows 版）
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
        bash "$ROOT/scripts/build-driver-linux.sh" > /tmp/ams_build_driver.log 2>&1 || {
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
    echo "        请先设置 CANGJIE_HOME 或将仓颉 SDK 放到 /opt/cangjie"
    exit 1
fi

if [ "$CLEAN" = 1 ]; then
    echo "=== 清理 ==="
    rm -rf "$BUILD_DIR"
fi
mkdir -p "$BUILD_DIR"

# stdx 动态库拷入 build 目录（lld 默认搜索路径）
[ -d "$STDX_DIR" ] && cp "$STDX_DIR"/*.so "$BUILD_DIR/" 2>/dev/null

# ---- 顶层包顺序（架构 §4.2 分层依赖规则）----
TOP_ORDER=(
    ams-kernel
    ams-crypto
    ams-storage
    ams-core
    ams-data
    ams-security
    ams-kit
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
dir_to_pkg() {
    local d="$1"
    local top
    top="$(echo "$d" | sed 's#^packages/##; s#/.*##')"
    local topdot
    topdot="$(echo "$top" | sed 's#-#.#g')"

    local rel
    rel="$(echo "$d" | sed "s#^packages/${top}/src##")"
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

    if ls "$src"/*.cj >/dev/null 2>&1; then
        SUBPKG_DIRS+=("$src")
    fi

    local dirs=()
    for d in "$src"/*/; do
        [ -d "$d" ] && dirs+=("$d")
    done
    [ ${#dirs[@]} -eq 0 ] && return

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
            for ((i = 0; i < ${#names[@]}; i++)); do
                if [ "${names[$i]}" = "$imp" ]; then
                    dep_list="$dep_list $i"
                    break
                fi
            done
        done
        deps+=("$dep_list")
    done

    local done_flags=""
    local total=${#dirs[@]}
    local count=0
    while [ "$count" -lt "$total" ]; do
        local picked=0
        for ((i = 0; i < total; i++)); do
            case " $done_flags " in *" $i "*) continue ;; esac
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
CASCADE_REBUILD=0

# ---- stdx 动态库的链接参数（Linux：原生路径 + .so）----
if [ -d "$STDX_DIR" ]; then
    for so in "$STDX_DIR"/libstdx*.so; do
        [ -f "$so" ] && STDX_LIBS_ALL="$STDX_LIBS_ALL -l:$(basename "$so")"
    done
    STDX_LIBS_ALL="-L${STDX_DIR} $STDX_LIBS_ALL"
fi

echo "=== AMS 构建（cjc · Linux · 子包粒度）==="
echo "  CANGJIE_HOME : ${CANGJIE_HOME}"
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
            [ -f "$BUILD_DIR/ams-server" ] && mv -f "$BUILD_DIR/ams-server" "$BUILD_DIR/ams-server.old" 2>/dev/null
            _link="$LINK_LIBS $DRV_LIBS $STDX_LIBS_ALL"
            "$CJC" -p "$subdir" \
                  --import-path "$BUILD_DIR" \
                  --import-path "$STDX_DIR" \
                  --import-path "$DRV_DIR" \
                  --output-type exe \
                  -o "$BUILD_DIR/ams-server" \
                  --link-options "$_link" > /tmp/ams_build.log 2>&1
            if [ -f "$BUILD_DIR/ams-server" ]; then
                echo "OK -> build/ams-server"
            else
                echo "FAILED"
                head -15 /tmp/ams_build.log | sed 's/^/           /'
                exit 1
            fi
        else
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
            if [ "$pkgname" = "ams.data" ] || [ "$pkgname" = "ams.data.db" ] || \
               [ "$pkgname" = "ams.data.repo" ]; then
                if [ "$HAS_DRV" = "0" ]; then
                    echo "FAILED（缺 opengauss-driver：请先执行 bash scripts/build-driver-linux.sh）"
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
                CASCADE_REBUILD=1
                LINK_LIBS="$LINK_LIBS $(win_path "$ROOT/$lib")"
                BUILT+=("$pkgname")
            else
                echo "FAILED (期望产物 $lib)"
                grep -n -A6 "error:" /tmp/ams_build.log | head -40 | sed 's/^/           /'
                exit 1
            fi
        fi
    done
done

# ---- 拷贝运行时 .so（Linux 必需）----
[ -d "$RUNTIME_DIR" ] && cp "$RUNTIME_DIR"/*.so "$BUILD_DIR/" 2>/dev/null
[ -d "$STDX_DIR" ] && cp "$STDX_DIR"/*.so "$BUILD_DIR/" 2>/dev/null

echo ""
echo "=== 构建完成 ==="
ls -lh "$BUILD_DIR"/ams-server 2>/dev/null || true
echo "已构建: ${BUILT[*]}"

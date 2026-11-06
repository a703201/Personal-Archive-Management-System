#!/bin/bash
# ============================================================
# AMS · CI 工具链准备
#
# 用途：在 CI 机器上准备「仓颉 SDK + stdx + opengauss-driver」。
#
# 三种来源（按优先级）：
#   ① **已存在的 SDK**：检测 CANGJIE_HOME 或 tools/cangjie/ 里有 bin/cjc.exe
#      → 直接用，**零下载**（自托管 runner 场景）。
#   ② **GitHub Release 工具链资产**（推荐给 GitHub 托管 runner）：
#      从 `CANGJIE_TOOLCHAIN_REPO` 的 `CANGJIE_TOOLCHAIN_TAG` Release 下载。
#      资产由 `scripts/ci/publish-toolchain.sh` 在本机生成（一次性）。
#   ③ **SDK 直链**：从 CANGJIE_SDK_URL 下载。
#
# 环境变量：
#   CANGJIE_SDK_VERSION     SDK 版本（默认 1.2.0）
#   CANGJIE_TOOLCHAIN_REPO  工具链所在仓库（默认取 GITHUB_REPOSITORY）
#   CANGJIE_TOOLCHAIN_TAG   工具链 Release 的 tag（默认 toolchain-v1.2.0）
#   CANGJIE_SDK_URL         SDK 压缩包直链（备选）
#   CANGJIE_STDX_VERSION    stdx 版本（默认 1.2.0.1）
#   STDX_ROOT               stdx 安装根目录（默认 $HOME/.cache/ams-stdx）
#   CANGJIE_HOME            已有 SDK 的位置（可选）
#
# ⚠️ 为什么不用官方直链？
#   官方下载页（https://cangjie-lang.cn/download/1.2.0）的直链由前端动态生成，
#   且 SDK 二进制**不是**公开的 gitcode release 资产（实测：stdx 在 gitcode 有
#   release，SDK 没有；候选 URL 全部 403/404）。故采用「自举」方案 ——
#   把工具链做成自己仓库的 Release 资产。
#
# ⚠️ MinGW 运行库
#   SDK 1.2.0 的 Windows 包**不含** libgcc_s_seh-1.dll / libwinpthread-1.dll /
#   libssp-0.dll，而 cjc 编译 @Test 用例时需要它们。本脚本会在解压后
#   自动补齐（从 tools/cangjie/bin 或 Git for Windows 的 mingw64/bin）。
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# 引入路径兼容工具（Git Bash / WSL / 原生 Windows 通用）
# shellcheck source=scripts/ci/pathutil.sh
. "$(dirname "${BASH_SOURCE[0]}")/pathutil.sh"

SDK_VERSION="${CANGJIE_SDK_VERSION:-1.2.0}"
STDX_VERSION="${CANGJIE_STDX_VERSION:-1.2.0.1}"
CACHE_DIR="${HOME}/.cache/ams-toolchain"
STDX_ROOT="${STDX_ROOT:-${CACHE_DIR}/stdx}"

# SDK 下载地址：优先环境变量，其次仓库变量（CI 会注入），否则用占位默认值
SDK_URL="${CANGJIE_SDK_URL:-}"

# GitHub Release 工具链资产（**推荐的 CI 来源**）：
#   仓颉 SDK 不在公开 gitcode release 仓库里，故用「自举」方案 ——
#   本机执行 scripts/ci/publish-toolchain.sh 把工具链传成 Release 资产，
#   CI 再从这里下载。
TOOLCHAIN_TAG="${CANGJIE_TOOLCHAIN_TAG:-toolchain-v${SDK_VERSION}}"
TOOLCHAIN_REPO="${CANGJIE_TOOLCHAIN_REPO:-${GITHUB_REPOSITORY:-}}"
TOOLCHAIN_TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

STDX_REPO="https://gitcode.com/Cangjie/cangjie_stdx"
STDX_URL="${STDX_REPO}/releases/download/v${STDX_VERSION}/cangjie-stdx-windows-x64-${STDX_VERSION}.zip"

echo "=== AMS · CI 工具链准备 ==="
echo "  SDK  : ${SDK_VERSION}"
echo "  stdx : ${STDX_VERSION}"
echo ""

_win_path() {
    [ -z "$1" ] && { echo ""; return; }
    local p="$1"
    if [[ "$p" =~ ^[a-zA-Z]:/ ]]; then
        echo "$p"
    elif [[ "$p" =~ ^/([a-zA-Z])/(.*)$ ]]; then
        echo "$(echo "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]'):/${BASH_REMATCH[2]}"
    else
        echo "$p"
    fi
}

# ---- 1. SDK ----
SDK_HOME=""
ams_path_env_info
if [ -n "${CANGJIE_HOME:-}" ] && [ -f "${CANGJIE_HOME}/bin/cjc.exe" ]; then
    SDK_HOME="$CANGJIE_HOME"
    echo "[1/3] 使用已有 SDK: ${SDK_HOME}"
elif [ -f "tools/cangjie/bin/cjc.exe" ]; then
    SDK_HOME="$(pwd)/tools/cangjie"
    echo "[1/3] 使用仓库内 SDK 副本: ${SDK_HOME}"
else
    CACHED_SDK="${CACHE_DIR}/cangjie-${SDK_VERSION}"
    if [ -f "${CACHED_SDK}/bin/cjc.exe" ]; then
        SDK_HOME="$CACHED_SDK"
        echo "[1/3] 使用缓存 SDK: ${SDK_HOME}"
    else
        # ---- 来源 B：GitHub Release 工具链资产（推荐）----
        if [ -z "$SDK_URL" ] && [ -n "$TOOLCHAIN_REPO" ]; then
            echo "[1/3] 从 GitHub Release 下载工具链（${TOOLCHAIN_REPO} @ ${TOOLCHAIN_TAG}）..."
            mkdir -p "$CACHE_DIR"
            SDK_ZIP="${CACHE_DIR}/cangjie-sdk-windows-x64-${SDK_VERSION}.zip"
            if [ -f "$SDK_ZIP" ]; then
                echo "      使用缓存"
            else
                ASSET_URL="https://github.com/${TOOLCHAIN_REPO}/releases/download/${TOOLCHAIN_TAG}/cangjie-sdk-windows-x64-${SDK_VERSION}.zip"
                AUTH=()
                [ -n "$TOOLCHAIN_TOKEN" ] && AUTH=(-H "Authorization: Bearer ${TOOLCHAIN_TOKEN}")
                # 公开仓库不需要 token；私有仓库必须带 token
                if ! curl --ssl-no-revoke -fL --retry 3 --connect-timeout 30 "${AUTH[@]}" -o "$SDK_ZIP" "$ASSET_URL"; then
                    echo "[ERROR] 工具链资产下载失败：${ASSET_URL}"
                    echo "       若仓库是私有的，请确认 GITHUB_TOKEN 已注入。"
                    echo "       若尚未发布工具链资产，请在本机执行："
                    echo "         bash scripts/ci/publish-toolchain.sh"
                    exit 1
                fi
            fi
        else
        # ---- 来源 C：直链 ----
        if [ -z "$SDK_URL" ]; then
            echo "[ERROR] 未找到可用的仓颉 SDK，且未配置 CANGJIE_SDK_URL / CANGJIE_TOOLCHAIN_REPO。"
            echo ""
            echo "  解决方案（任选其一）："
            echo "   ① **推荐**：在本机发布工具链资产，然后设置仓库变量"
            echo "        bash scripts/ci/publish-toolchain.sh"
            echo "        变量 CANGJIE_TOOLCHAIN_TAG = toolchain-v${SDK_VERSION}"
            echo "   ② 设置仓库变量 CANGJIE_SDK_URL 指向 SDK 压缩包直链"
            echo "   ③ 用**自托管 runner**（已装好 SDK 的机器）"
            exit 1
        fi
        echo "[1/3] 下载 SDK ${SDK_VERSION}（直链）..."
        mkdir -p "$CACHE_DIR"
        SDK_ZIP="${CACHE_DIR}/cangjie-sdk-${SDK_VERSION}.zip"
        if [ ! -f "$SDK_ZIP" ]; then
            curl --ssl-no-revoke -fL --retry 3 --connect-timeout 30 -o "$SDK_ZIP" "$SDK_URL"
        fi
        fi
        echo "      解压中（约 250 MB，需要一会儿）..."
        rm -rf "$CACHED_SDK" 2>/dev/null || true
        mkdir -p "$CACHED_SDK"
        unzip -q "$SDK_ZIP" -d "$CACHED_SDK"
        # 压缩包内可能是 cangjie/ 一层，也可能直接是根目录
        if [ ! -f "${CACHED_SDK}/bin/cjc.exe" ] && [ -f "${CACHED_SDK}/cangjie/bin/cjc.exe" ]; then
            CACHED_SDK="${CACHED_SDK}/cangjie"
        fi
        if [ ! -f "${CACHED_SDK}/bin/cjc.exe" ]; then
            echo "[ERROR] SDK 压缩包结构异常，未找到 bin/cjc.exe"
            exit 1
        fi
        SDK_HOME="$CACHED_SDK"
    fi
fi

# 补齐 MinGW 运行库（1.2.0 SDK 的已知缺件，见 scripts/install-sdk.sh）
# cangjie 的 third_party/llvm/bin（opt.exe 等）同样需要 libgcc/libwinpthread，
# 而 CI runner 的 PATH 不含这些目录，故需把 MinGW DLL 补到 SDK 下所有 bin 目录。
#
# ⚠️ 源候选路径必须兼容两种 git 安装形态：
#   · Git Bash（含 GitHub windows-latest runner）：`command -v git` → /mingw64/bin/git
#     → DLL 位于 /mingw64/bin/
#   · Git CMD / 本机安装：git 在 C:/Program Files/Git/bin/git
#     → DLL 位于 C:/Program Files/Git/mingw64/bin/
#   故两个候选都列上，靠 `[ -e ]` 实测是否存在来筛选，不存在的会被跳过。
mapfile -t BIN_DIRS < <(find "${SDK_HOME}" -type d -name bin 2>/dev/null)

# ① 先补 MinGW 运行时（libgcc/libwinpthread/libssp）：优先 SDK 内部，否则从
#    Git for Windows 的 mingw64/bin 取（兼容 windows-latest runner 与本机两种布局）。
MINGW_DLLS=(libgcc_s_seh-1.dll libwinpthread-1.dll libssp-0.dll)
SRC_CANDIDATES=()
if [ -n "${CANGJIE_MINGW_BIN:-}" ]; then SRC_CANDIDATES+=("${CANGJIE_MINGW_BIN}"); fi
_GIT_EXE="$(command -v git 2>/dev/null || true)"
if [ -n "$_GIT_EXE" ]; then
    _GIT_BIN="$(dirname "$_GIT_EXE")"
    SRC_CANDIDATES+=("$_GIT_BIN" "$_GIT_BIN/../mingw64/bin")
fi
SRC_CANDIDATES+=("/mingw64/bin" "/c/Program Files/Git/mingw64/bin")
for req in "${MINGW_DLLS[@]}"; do
    src="$(find "${SDK_HOME}" -name "$req" 2>/dev/null | head -1)"
    if [ -z "$src" ]; then
        for c in "${SRC_CANDIDATES[@]}"; do
            [ -e "$c/$req" ] || continue
            src="$c/$req"; break
        done
    fi
    if [ -n "$src" ]; then
        for b in "${BIN_DIRS[@]:-}"; do
            [ -e "$b/$req" ] || cp -f "$src" "$b/" 2>/dev/null
        done
    else
        echo "[WARN] 找不到 MinGW 运行时 $req，opt.exe 可能报 DLL not found"
    fi
done

# ② 把 SDK 内现存的【全部】*.dll 互通到每一个 bin 目录。
#    opt.exe / lld.exe 等子进程需在「自身所在目录」找到依赖 DLL；而发布包往往
#    只在部分 bin 目录放了完整 DLL（如 libLLVM/libc++/libunwind 只在 bin/ 而
#    不在 third_party/llvm/bin），导致 opt.exe 因缺 DLL 而 0xC0000135。
#    做法：扫描 SDK 内所有 bin 目录的全部 DLL，去重后补齐到每个 bin 目录，
#    使任意子进程都能在同目录命中其全部依赖（无论缺的是 MinGW 还是 LLVM 运行库）。
declare -A _SEEN=()
DLL_NAMES=()
while IFS= read -r f; do
    b="$(basename "$f")"
    [ -n "${_SEEN[$b]:-}" ] && continue
    _SEEN[$b]=1
    DLL_NAMES+=("$b")
done < <(find "${SDK_HOME}" -type f -name '*.dll' 2>/dev/null)
for b in "${BIN_DIRS[@]:-}"; do
    for d in "${DLL_NAMES[@]:-}"; do
        [ -e "$b/$d" ] && continue
        s="$(find "${SDK_HOME}" -name "$d" 2>/dev/null | head -1)"
        [ -z "$s" ] && continue
        cp -f "$s" "$b/" 2>/dev/null && echo "[INFO] 补齐 $d -> $b"
    done
done
echo "[INFO] DLL 互通完成（${#DLL_NAMES[@]} 种 DLL × ${#BIN_DIRS[@]} 个 bin 目录）"

# ---- 2. stdx ----
echo "[2/3] 准备 stdx ${STDX_VERSION}..."
STDX_TARGET="$(ams_path_norm "${STDX_ROOT}/windows_x86_64_cjnative")"
if [ -d "${STDX_TARGET}/dynamic/stdx" ]; then
    echo "      已存在: ${STDX_TARGET}/dynamic/stdx"
else
    mkdir -p "$CACHE_DIR"
    STDX_ZIP="${CACHE_DIR}/cangjie-stdx-${STDX_VERSION}.zip"
    if [ ! -f "$STDX_ZIP" ]; then
        echo "      下载中..."
        curl --ssl-no-revoke -fL --retry 3 --connect-timeout 30 -o "$STDX_ZIP" "$STDX_URL"
    fi
    TMP="$(mktemp -d)"
    unzip -q "$STDX_ZIP" -d "$TMP"
    mkdir -p "$STDX_ROOT"
    if [ -d "${TMP}/windows_x86_64_cjnative" ]; then
        cp -r "${TMP}/windows_x86_64_cjnative" "$STDX_ROOT/"
    else
        cp -r "$TMP"/* "$STDX_ROOT/" 2>/dev/null || true
    fi
    rm -rf "$TMP" 2>/dev/null || true
    if [ ! -d "${STDX_TARGET}/dynamic/stdx" ]; then
        echo "[ERROR] stdx 解压后结构异常，未找到 dynamic/stdx"
        exit 1
    fi
    echo "      就绪: ${STDX_TARGET}/dynamic/stdx"
fi

# ---- 3. 驱动 ----
echo "[3/3] 准备 opengauss-driver..."
if [ ! -d "tools/vendor/opengauss-driver/src" ]; then
    echo "      克隆驱动源码..."
    mkdir -p tools/vendor
    git clone --depth 1 https://gitcode.com/Cangjie-TPC/opengauss-driver.git \
        tools/vendor/opengauss-driver
fi
if [ -f "tools/vendor/opengauss-driver/src/pgconn/conn.cj" ]; then
    echo "      打适配补丁..."
    python3 scripts/patch-driver.py || true
else
    echo "[WARN] 驱动源码结构异常，跳过"
fi

# ---- 输出环境变量供后续步骤使用 ----
SDK_HOME_WIN="$(_ams_native_to_win "$SDK_HOME")"
STDX_DIR_WIN="$(_ams_native_to_win "${STDX_TARGET}")"

cat > "${GITHUB_ENV:-/tmp/ams_ci_env}" <<ENVEOF
CANGJIE_HOME=${SDK_HOME_WIN}
CANGJIE_STDX=${STDX_DIR_WIN}
CANGJIE_SDK_WIN=${SDK_HOME_WIN}
ENVEOF

# 把 SDK 的 bin 目录加入 PATH，使 opt.exe / cjc 等第三方工具能找到其运行时 DLL
# （CI runner 的 PATH 不含 SDK 目录，本机则不报错，故必须显式追加）
echo "${SDK_HOME_WIN}/bin" >> "${GITHUB_PATH:-/tmp/ams_ci_path}"
echo "${SDK_HOME_WIN}/third_party/llvm/bin" >> "${GITHUB_PATH:-/tmp/ams_ci_path}"

echo ""
echo "=== 工具链就绪 ==="
echo "  CANGJIE_HOME = ${SDK_HOME_WIN}"
echo "  CANGJIE_STDX = ${STDX_DIR_WIN}"

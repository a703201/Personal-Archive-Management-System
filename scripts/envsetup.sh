#!/bin/bash
# ============================================================
# AMS 仓颉开发环境脚本（项目级）
#
# 用法：
#   source scripts/envsetup.sh          # Git Bash / Linux / macOS
#   . scripts/envsetup.ps1              # PowerShell
#
# 作用：
#   1. 定位仓颉 SDK（默认 E:/Cangjie，可用 CANGJIE_HOME 覆盖）
#   2. 设置 CANGJIE_STDX 指向 stdx 扩展标准库
#   3. 把 stdx 动态库目录加入 PATH（运行时需要 DLL/SO）
#   4. 提供常用别名
#
# 实测要点（2026-10-24，SDK 1.0.5）：
#   - bin/ 只有 cjc.exe；cjpm/cjfmt/cjlint/cjcov 在 tools/bin/
#   - SDK 标准库无 SM3/SM4 实现，国密能力来自 stdx
#   - **PATH 必须用 Windows 风格（E:/...）**：SDK 自带 envsetup.sh 会推导成
#     MSYS 风格（/e/...），Windows 可执行文件无法解析，会 command not found
#   - ⚠️ **本机 cjpm 崩溃**（0xC0000374 堆损坏），与路径/版本/工程结构均无关；
#     cjc / cjfmt / cjlint 正常。本机用 cjc 验证代码，cjpm 留给 CI。
# ============================================================

# ---- 路径转换工具（需在使用前定义）----
# Windows 风格 → MSYS 风格：  E:/x/y  →  /e/x/y
_win_to_msys() {
    [ -z "$1" ] && { echo ""; return; }
    local p="$1"
    if [[ "$p" =~ ^/([a-zA-Z])/(.*)$ ]]; then
        echo "$p"                       # 已是 MSYS 风格
    elif [[ "$p" =~ ^([a-zA-Z]):/(.*)$ ]]; then
        echo "/$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')/${BASH_REMATCH[2]}"
    else
        echo "$p"
    fi
}

# MSYS 风格 → Windows 风格：  /e/x/y  →  E:/x/y
# 注意：已是 Windows 风格（E:/...）的原样返回，避免把盘符吃掉变成 /Cangjie
_msys_to_win() {
    [ -z "$1" ] && { echo ""; return; }
    local p="$1"
    if [[ "$p" =~ ^[a-zA-Z]:/ ]]; then
        echo "$p"                       # 已是 Windows 风格
    elif [[ "$p" =~ ^/([a-zA-Z])/(.*)$ ]]; then
        echo "$(echo "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]'):/${BASH_REMATCH[2]}"
    else
        echo "$p"
    fi
}

# ---- 1. 定位 SDK ----
# 优先级：仓库内副本 tools/cangjie → E:/Cangjie → 环境变量 → 旧版安装位置
# 说明：
#   ① 仓库内副本优先 —— 团队成员克隆后跑 scripts/install-sdk.sh 即可获得
#      一致的编译环境，且副本路径不含空格；
#   ② 环境变量在长驻终端里可能是旧值（会话启动时固定），
#      故把已知安装位置放在环境变量之前。
_SCRIPT_DIR_="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROJECT_ROOT_="$(cd "${_SCRIPT_DIR_}/.." && pwd)"

if [ -d "${_PROJECT_ROOT_}/tools/cangjie" ]; then
    export CANGJIE_HOME="${_PROJECT_ROOT_}/tools/cangjie"
    export AMS_CANGJIE_SOURCE="repo"
elif [ -d "E:/Cangjie" ]; then
    export CANGJIE_HOME="E:/Cangjie"
    export AMS_CANGJIE_SOURCE="system"
elif [ -n "${CANGJIE_HOME:-}" ] && [ -d "${CANGJIE_HOME}" ]; then
    export AMS_CANGJIE_SOURCE="env"
elif [ -d "E:/Program Files (x86)/Cangjie" ]; then
    export CANGJIE_HOME="E:/Program Files (x86)/Cangjie"
    export AMS_CANGJIE_SOURCE="legacy"
else
    echo "[ERROR] 未找到仓颉 SDK。请执行 scripts/install-sdk.sh 或设置 CANGJIE_HOME。"
    return 1 2>/dev/null || exit 1
fi

export CANGJIE_STDX_ROOT="${CANGJIE_STDX_ROOT:-E:/CangjieLibs}"
export CANGJIE_TARGET_PLATFORM="windows_x86_64_cjnative"

# ---- 2. 预先算好 Windows 风格路径 ----
# 关键：必须在 source SDK 脚本**之前**算好 —— source 会把 CANGJIE_HOME
# 改写成 MSYS 风格（/e/...），之后 Windows 可执行文件无法解析该格式。
_CJ_WIN="$(_msys_to_win "${CANGJIE_HOME}")"
_CJ_FOR_SDK="$(_win_to_msys "${CANGJIE_HOME}")"

# ---- 3. 加载 SDK 自带环境 ----
if [ -f "${_CJ_FOR_SDK}/envsetup.sh" ]; then
    CANGJIE_HOME="$_CJ_FOR_SDK" source "${_CJ_FOR_SDK}/envsetup.sh"
else
    echo "[WARN] 未找到 ${_CJ_FOR_SDK}/envsetup.sh，跳过 SDK 环境加载"
fi

# ---- 4. 还原为 Windows 风格并重建 PATH（关键）----
# Windows 可执行文件无法解析 MSYS 风格路径，必须显式重建。
export CANGJIE_HOME="$_CJ_WIN"
if [ -n "$_CJ_WIN" ]; then
    export PATH="${_CJ_WIN}/bin:${_CJ_WIN}/tools/bin:${_CJ_WIN}/tools/lib:${_CJ_WIN}/runtime/lib/${CANGJIE_TARGET_PLATFORM}:${PATH}"
fi

# ---- 5. stdx ----
if [ -d "${CANGJIE_STDX_ROOT}/${CANGJIE_TARGET_PLATFORM}" ]; then
    export CANGJIE_STDX="${CANGJIE_STDX_ROOT}/${CANGJIE_TARGET_PLATFORM}"
    export STDX_DYNAMIC_DIR="${CANGJIE_STDX}/dynamic/stdx"
    export STDX_STATIC_DIR="${CANGJIE_STDX}/static/stdx"
    # 运行时需要能找到 libstdx.*.dll
    export PATH="${STDX_DYNAMIC_DIR}:${PATH}"
else
    echo "[WARN] stdx 未找到：${CANGJIE_STDX_ROOT}/${CANGJIE_TARGET_PLATFORM}"
    echo "       请执行：bash scripts/install-stdx.sh"
fi

# ---- 6. 常用别名 ----
# 本机 cjpm 崩溃，故默认别名指向 cjc；CI 中可用 cjpm。
alias cjc-build="cjc"
alias cj-build-linux="cjpm build --target x86_64-linux-gnu"
alias cj-build-arm="cjpm build --target aarch64-linux-gnu"
alias cj-build-win="cjpm build --target x86_64-windows-gnu"
alias cj-lint="cjlint -f packages/ams-server/src -r json -o ./lint-report"
alias cj-fmt="cjfmt -d packages/ams-server/src"

# ---- 7. 输出验证信息 ----
echo "[AMS] CANGJIE_HOME = ${CANGJIE_HOME}"
echo "[AMS] CANGJIE_STDX = ${CANGJIE_STDX:-<未设置>}"
for _tool in cjc cjfmt cjlint; do
    _p="$(command -v $_tool 2>/dev/null)"
    if [ -n "$_p" ]; then echo "[AMS] $_tool -> $_p"; else echo "[AMS] $_tool -> NOT FOUND"; fi
done
if command -v cjpm >/dev/null 2>&1; then
    echo "[AMS] cjpm  -> $(command -v cjpm)  ⚠️ 本机已知崩溃，仅用于 CI/其他环境"
fi
unset _tool _p

#!/bin/bash
# ============================================================
# AMS · 路径工具（跨 bash 环境兼容）
#
# 用途：让脚本在 **Git Bash / WSL / 原生 Windows** 下都能找到同一批文件。
#
# 【问题背景】（实测 2026-10-26）
#   在 WSL 里执行 `bash scripts/ci/publish-toolchain.sh` 时，
#   硬编码的 `E:/CangjieLibs/...` 判定为「目录不存在」——
#   因为 **WSL 不认 Windows 盘符写法**（它要 `/mnt/e/...`）。
#   而 Git Bash 认 `E:/...`，也认 `/e/...`。
#
# 【三种环境的路径对照】
#   | 路径            | Git Bash | WSL              | 说明 |
#   |-----------------|----------|------------------|------|
#   | E:/Foo          | ✅       | ❌               | Windows 盘符 |
#   | /e/Foo          | ✅       | ❌               | Git Bash 挂载点 |
#   | /mnt/e/Foo      | ❌       | ✅               | WSL 挂载点 |
#   | C:\Foo\Bar      | ✅       | ❌               | 反斜杠 |
#
# 【做法】
#   提供 `ams_path_norm`：把任意写法归一到**当前环境能用**的形式。
#   判定依据是当前环境本身（能否看到 /mnt/e、能否看到 /e），
#   而不是靠猜。
# ============================================================

# 判断当前 bash 是 WSL 还是 Git Bash
#
# 说明：可用环境变量强制覆盖（便于测试与特例场景）：
#   AMS_FORCE_WSL=1   强制按 WSL 处理（路径用 /mnt/x/）
#   AMS_FORCE_MINGW=1 强制按 Git Bash 处理（路径用 /x/）
_AMS_IS_WSL=0
if [ "${AMS_FORCE_WSL:-}" = "1" ]; then
    _AMS_IS_WSL=1
elif [ -e /mnt/c ] || grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
    _AMS_IS_WSL=1
fi

# 判断是否 Git Bash（PortableGit 的 MSYS 环境）
_AMS_IS_MINGW=0
if [ "${AMS_FORCE_MINGW:-}" = "1" ]; then
    _AMS_IS_MINGW=1
elif [ "${AMS_FORCE_WSL:-0}" != "1" ] && { [ -n "${MSYSTEM:-}" ] || [ -e /e ] || uname -s 2>/dev/null | grep -qiE "mingw|msys"; }; then
    _AMS_IS_MINGW=1
fi

# Windows 盘符路径 → 当前环境的绝对路径
#   用法：_ams_win_to_native "E:/CangjieLibs" → "/mnt/e/CangjieLibs"（WSL）
#                                              → "/e/CangjieLibs"  （Git Bash）
#                                              → "E:/CangjieLibs"（原生）
_ams_win_to_native() {
    local p="$1"
    # 已是 POSIX 路径，原样返回
    case "$p" in
        /*) echo "$p"; return ;;
    esac
    # 盘符形式：E:/Foo 或 E:\Foo
    local drive="${p:0:1}"
    local rest="${p:2}"
    rest="${rest#:}"
    rest="${rest//\\//}"
    local lower="$(echo "$drive" | tr '[:upper:]' '[:lower:]')"
    if [ "$_AMS_IS_WSL" = "1" ]; then
        echo "/mnt/${lower}${rest}"
    elif [ "$_AMS_IS_MINGW" = "1" ]; then
        echo "/${lower}${rest}"
    else
        echo "${drive}:${rest}"
    fi
}

# 当前环境的路径 → Windows 风格（用于传给 cjc / 生成 Windows 路径的场合）
_ams_native_to_win() {
    local p="$1"
    if [ "$_AMS_IS_WSL" = "1" ]; then
        # /mnt/e/Foo → E:/Foo
        if [[ "$p" =~ ^/mnt/([a-zA-Z])(/.*)$ ]]; then
            local d="$(echo "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')"
            echo "${d}:${BASH_REMATCH[2]}"
            return
        fi
    elif [ "$_AMS_IS_MINGW" = "1" ]; then
        # /e/Foo → E:/Foo
        if [[ "$p" =~ ^/([a-zA-Z])(/.*)$ ]]; then
            local d="$(echo "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]')"
            echo "${d}:${BASH_REMATCH[2]}"
            return
        fi
    fi
    # 已经是 Windows 风格或相对路径
    echo "$p"
}

# 路径存在性检查（自动尝试多种写法）
_ams_path_exists() {
    local p="$1"
    [ -e "$p" ] && return 0
    local alt
    alt="$(_ams_win_to_native "$p")"
    [ "$alt" != "$p" ] && [ -e "$alt" ] && return 0
    alt="$(_ams_native_to_win "$p")"
    [ "$alt" != "$p" ] && [ -e "$alt" ] && return 0
    return 1
}

# 把路径归一到**当前环境可用**的形式（用于后续所有文件操作）
ams_path_norm() {
    local p="$1"
    if [ -e "$p" ]; then
        echo "$p"
        return
    fi
    local alt
    alt="$(_ams_win_to_native "$p")"
    if [ -e "$alt" ]; then
        echo "$alt"
        return
    fi
    alt="$(_ams_native_to_win "$p")"
    if [ -e "$alt" ]; then
        echo "$alt"
        return
    fi
    # 都不存在：返回原始值（由调用方报错）
    echo "$p"
}

# 打印当前环境判定（诊断用）
ams_path_env_info() {
    echo "  bash 环境 : $(uname -s 2>/dev/null) / MSYSTEM=${MSYSTEM:-<无>}"
    echo "  WSL       : ${_AMS_IS_WSL}"
    echo "  MinGW     : ${_AMS_IS_MINGW}"
}

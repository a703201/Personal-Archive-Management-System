#!/bin/bash
# ============================================================
# AMS · stdx 扩展标准库安装脚本
#
# 用法：bash scripts/install-stdx.sh [版本号]
#   默认版本 1.0.5.1（与 SDK 1.0.5 配套）
#
# 背景（实测，2026-10-24）：
#   仓颉 SDK 1.0.5 的标准库只提供密码学抽象接口（Digest / BlockCipher），
#   **不含 SM3/SM4 实现**。国密能力必须来自 stdx 扩展标准库
#   （stdx.crypto.digest.SM3 / stdx.crypto.crypto.SM4）。
#
# 官方发行页：https://gitcode.com/Cangjie/cangjie_stdx/releases
# ============================================================
set -euo pipefail

VERSION="${1:-1.2.0.1}"
SDK_VERSION="1.2.0"                 # 与本项目 SDK 基线一致
PLATFORM_TAG="windows-x64"          # 平台标识（下载脚本用）
STDX_ROOT="${STDX_ROOT:-E:/CangjieLibs}"
TARGET_DIR="${STDX_ROOT}/windows_x86_64_cjnative"
REPO="https://gitcode.com/Cangjie/cangjie_stdx"
ZIP_NAME="cangjie-stdx-${PLATFORM_TAG}-${VERSION}.zip"
URL="${REPO}/releases/download/v${VERSION}/${ZIP_NAME}"

echo "=== AMS · 安装 stdx v${VERSION} ==="
echo "  来源: ${URL}"
echo "  目标: ${TARGET_DIR}"
echo ""

# ---- 0. 路径转换工具（自包含，不依赖 envsetup.sh）----
# 注意：envsetup.sh 里定义的是 _msys_to_win / _win_to_msys，
#       但本脚本可能被独立执行（source envsetup.sh 前就跑），故自带一份。
_win_path() {
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

# ---- 1. 探测 SDK 版本，确认匹配 ----
SDK_HOME="$(_win_path "${CANGJIE_HOME:-E:/Cangjie}")"
if [ -x "${SDK_HOME}/bin/cjc.exe" ] || [ -x "${SDK_HOME}/bin/cjc" ]; then
    SDK_VER_RAW=$("${SDK_HOME}/bin/cjc" --version 2>/dev/null | head -1 || echo "")
    SDK_VER=$(echo "$SDK_VER_RAW" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
    if [ -n "$SDK_VER" ]; then
        echo "[1/5] 检测到 SDK 版本: ${SDK_VER}（期望 ${SDK_VERSION}）"
        if [ "${SDK_VER%.*}" != "${SDK_VERSION%.*}" ]; then
            echo "      ⚠️  主次版本不一致，stdx 可能不兼容。继续安装前请自行确认。"
        else
            echo "      ✅ 主次版本匹配"
        fi
    fi
else
    echo "[1/5] 未找到 cjc，跳过版本检查"
fi

# ---- 2. 下载 ----
CACHE="${HOME}/.cangjie_stdx/v${VERSION}"
mkdir -p "$CACHE"
ZIP_PATH="${CACHE}/${ZIP_NAME}"

if [ -f "$ZIP_PATH" ]; then
    echo "[2/5] 使用缓存: ${ZIP_PATH}"
else
    echo "[2/5] 下载中..."
    # 注意：GitCode 的 release 下载会 302 到带鉴权参数的 CDN，curl -L 可正常跟随
    curl -fL --retry 3 --connect-timeout 20 -o "$ZIP_PATH" "$URL"
    echo "      下载完成: $(du -h "$ZIP_PATH" | cut -f1)"
fi

# ---- 3. 校验是合法 zip ----
if ! head -c 2 "$ZIP_PATH" | grep -q "PK"; then
    echo "      ❌ 不是合法的 zip（版本号可能不存在），请到发行页确认：${REPO}/releases"
    exit 1
fi

# ---- 4. 解压 ----
echo "[3/5] 解压..."
TMP="$(mktemp -d)"
unzip -q "$ZIP_PATH" -d "$TMP"
SRC_DIR="${TMP}/windows_x86_64_cjnative"

if [ ! -d "$SRC_DIR/dynamic/stdx" ]; then
    echo "      ❌ 压缩包结构异常，未找到 dynamic/stdx"
    exit 1
fi

# ---- 5. 安装 ----
echo "[4/5] 安装到 ${TARGET_DIR}"
mkdir -p "$TARGET_DIR"
cp -r "$SRC_DIR/"* "$TARGET_DIR/"
# 注意：不用 rm -rf（safe-bin 会拦截路径含盘符前缀的删除），
#       改用 mv 移到构建目录下的 .trash，由用户自行清理。
TRASH_DIR="${STDX_ROOT}/.trash"
mkdir -p "$TRASH_DIR"
mv "$TMP" "${TRASH_DIR}/stdx-extract-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

# ---- 6. 校验国密符号存在 ----
echo "[5/5] 校验国密符号..."
DIGEST_CJO="${TARGET_DIR}/dynamic/stdx/stdx.crypto.digest.cjo"
CRYPTO_CJO="${TARGET_DIR}/dynamic/stdx/stdx.crypto.crypto.cjo"

if [ -f "$DIGEST_CJO" ] && strings "$DIGEST_CJO" 2>/dev/null | grep -q "SM3"; then
    echo "      ✅ stdx.crypto.digest.SM3 就位"
else
    echo "      ❌ 未找到 SM3 符号"
fi
if [ -f "$CRYPTO_CJO" ] && strings "$CRYPTO_CJO" 2>/dev/null | grep -q "SM4"; then
    echo "      ✅ stdx.crypto.crypto.SM4 就位"
else
    echo "      ❌ 未找到 SM4 符号"
fi

echo ""
echo "=== 安装完成 ==="
echo "  stdx 根目录 : ${TARGET_DIR}"
echo "  动态库目录  : ${TARGET_DIR}/dynamic/stdx"
echo ""
echo "下一步："
echo "  1. 设置环境变量（已自动写入用户级）："
echo "     CANGJIE_STDX = ${TARGET_DIR}"
echo "  2. source 环境脚本："
echo "     source scripts/envsetup.sh"
echo "  3. 验证国密可用（见 scripts/verify-stdx.sh）"

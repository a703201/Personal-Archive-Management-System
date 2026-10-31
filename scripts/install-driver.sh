#!/bin/bash
# ============================================================
# AMS · opengauss-driver 拉取脚本
#
# 用途：把 Cangjie-TPC/opengauss-driver 源码拉到 tools/vendor/，
#       供 scripts/build-driver.sh 编译。
#
# 为什么 vendor 到项目内而不是用 cjpm 依赖：
#   - 本机 cjpm 崩溃（0xC0000374 堆损坏），无法执行 `cjpm update`；
#   - 驱动仓库用 cjpm 组织名（cangjie_tpc::opengauss.*），
#     与本项目子包结构不同，需手工编排编译顺序；
#   - vendor 后源码可离线复用，且不污染全局依赖缓存。
#
# 注意：tools/vendor/ 已加入 .gitignore，不进版本库。
#
# 用法：
#   bash scripts/install-driver.sh            # 克隆或更新
#   bash scripts/install-driver.sh --force    # 强制重新克隆
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REPO_URL="https://gitcode.com/Cangjie-TPC/opengauss-driver.git"
VENDOR_DIR="tools/vendor"
DRV_DIR="${VENDOR_DIR}/opengauss-driver"

echo "=== AMS · 安装 opengauss-driver ==="
echo "  来源: ${REPO_URL}"
echo "  目标: ${DRV_DIR}"
echo ""

mkdir -p "$VENDOR_DIR"

if [ -d "${DRV_DIR}/.git" ] && [ "${1:-}" != "--force" ]; then
    echo "[1/2] 已存在，执行 git pull 更新..."
    git -C "$DRV_DIR" pull --ff-only || {
        echo "      ⚠️  pull 失败，保留现有版本继续使用"
    }
else
    if [ -d "$DRV_DIR" ]; then
        # 不用 rm -rf（safe-bin 会拦截），改用 mv 保留旧目录
        mv -f "$DRV_DIR" "${DRV_DIR}.old.$(date +%Y%m%d-%H%M%S)"
    fi
    echo "[1/2] 克隆（depth=1）..."
    git clone --depth 1 "$REPO_URL" "$DRV_DIR" || {
        echo "      ❌ 克隆失败，请检查网络"
        exit 1
    }
fi

# ---- 校验 ----
if [ ! -f "${DRV_DIR}/src/driver/driver.cj" ]; then
    echo "      ❌ 驱动源码结构异常（缺 src/driver/driver.cj）"
    exit 1
fi

VERSION="$(git -C "$DRV_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
PKG_VER="$(grep -oE 'version *= *"[^"]+"' "${DRV_DIR}/cjpm.toml" 2>/dev/null | head -1 | sed 's/.*"\(.*\)"/\1/')"

echo "[2/2] 校验通过"
echo ""
echo "=== 安装完成 ==="
echo "  提交    : ${VERSION}"
echo "  包版本  : ${PKG_VER:-未知}"
echo "  源码目录: ${DRV_DIR}/src"
echo ""
echo "下一步：bash scripts/build-driver.sh"

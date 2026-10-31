#!/bin/bash
# ============================================================
# AMS · 在容器内编译 Linux 产物（容器化部署的第 1 步）
#
# 为什么需要它：仓颉不支持交叉编译（同一份源码必须用 Linux 版
# cjc 编出 Linux 二进制）。Windows 开发机上没有 Linux 工具链，
# 因此把编译放进 ams-cj 工具链镜像，产物写回宿主 build/linux/。
#
# 前置：先构建工具链镜像（只需一次）
#   docker build -t ams-cj:1.2.0-beta.03 \
#     --build-context sdksrc=.tmp/sdk \
#     -f deploy/docker/Dockerfile.cjbase .
#
# 用法：
#   bash deploy/scripts/build-linux-docker.sh             # 全量构建
#   bash deploy/scripts/build-linux-docker.sh --clean     # 清理后重建
#   bash deploy/scripts/build-linux-docker.sh ams-crypto  # 只编某个顶层包
#
# 产物：build/linux/ams-server + build/linux/*.so
#       （由 Dockerfile.prebuilt 打运行镜像）
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${AMS_CJ_IMAGE:-ams-cj:1.2.0-beta.03}"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[ERROR] 找不到工具链镜像 $IMAGE"
    echo "        先构建：docker build -t $IMAGE --build-context sdksrc=.tmp/sdk \\"
    echo "                -f deploy/docker/Dockerfile.cjbase ."
    exit 1
fi

mkdir -p "$ROOT/build/linux"

echo "=== 容器内编译 Linux 产物 ==="
echo "  镜像 : $IMAGE"
echo "  源码 : $ROOT"
echo "  产物 : build/linux/"
echo ""

# 源码只读挂载，产物目录读写挂载 —— 避免编译中间物污染宿主的 Windows build/
MSYS_NO_PATHCONV=1 docker run --rm \
    -v "$ROOT":/src:ro \
    -v "$ROOT/build/linux":/src/build/linux:rw \
    -w /src \
    -e AMS_BUILD_DIR=build/linux \
    -e CANGJIE_HOME=/opt/cangjie \
    -e CANGJIE_STDX=/opt/cangjie-stdx/linux_x86_64_cjnative \
    "$IMAGE" \
    bash -lc "bash scripts/build-linux.sh $*"

rc=$?
echo ""
if [ $rc -ne 0 ]; then
    echo "[FAILED] 编译失败（退出码 $rc）"
    exit $rc
fi
ls -lh "$ROOT/build/linux/ams-server" 2>/dev/null || {
    echo "[FAILED] 未产出 build/linux/ams-server"
    exit 1
}
echo "[OK] 产物就绪：build/linux/"

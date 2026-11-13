#!/usr/bin/env bash
# =================================================================
#  AMS · 启动器 zenity GUI 实测 —— 宿主机一键入口
# =================================================================
#  前置：本机需安装 Docker 且 Docker 守护进程在运行（Docker Desktop /
#        Docker Engine）。本脚本不依赖宿主机是否装有 X 服务器——
#        容器内的 Xvfb 会提供虚拟显示器。
#
#  做了什么：
#    1) 以 scripts/launcher/test 为构建上下文，构建含 zenity + Xvfb +
#       xdotool + scrot 的 Ubuntu 镜像；
#    2) 把 AMS 仓库以只读挂载到 /opt/ams（测的是当前源码）；
#    3) 运行 test-zenity.sh：真实渲染 zenity 并截屏、驱动交互、
#       验证 headless 降级与 shellcheck；
#    4) 把 /out（result.log + zenity_*.png）落到仓库 .tmp/ams-gui-test。
#
#  用法：bash scripts/launcher/test/run.sh
# =================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"          # 仓库根
CTX="$HERE"                                # 构建上下文（含 Dockerfile 与 test-zenity.sh）
IMAGE="ams-launcher-gui-test"
HOSTOUT="$REPO/.tmp/ams-gui-test"
mkdir -p "$HOSTOUT"

echo "==> 仓库根: $REPO"
echo "==> 产物目录(宿主机): $HOSTOUT"

# ---- Docker 守护进程可用性预检 ----
if ! docker info >/dev/null 2>&1; then
    echo "[ERROR] 未检测到运行中的 Docker 守护进程。" >&2
    echo "        请先启动 Docker Desktop（Windows/macOS）或 dockerd（Linux），" >&2
    echo "        再重新运行本脚本。本沙箱/CI 无显示环境时也可用此脚本在任意" >&2
    echo "        装有 Docker 的机器上一键复现真实的 zenity GUI 实测。" >&2
    exit 2
fi

# ---- 构建镜像 ----
echo "==> 构建镜像 $IMAGE ..."
docker build -t "$IMAGE" -f "$CTX/Dockerfile" "$CTX" || { echo "[ERROR] 镜像构建失败"; exit 1; }

# ---- 运行实测 ----
echo "==> 运行 zenity GUI 实测（Xvfb 虚拟显示）..."
docker run --rm \
    -v "$REPO:/opt/ams:ro" \
    -v "$HOSTOUT:/out" \
    -e "OUT_DIR=/out" \
    "$IMAGE"
RC=$?

echo
echo "==> 退出码: $RC"
echo "==> 结果摘要:"
if [ -f "$HOSTOUT/result.log" ]; then
    grep -E '^(PASS|FAIL|INFO|结果):' "$HOSTOUT/result.log"
    echo "==> 截屏物证:"
    ls -1 "$HOSTOUT"/*.png 2>/dev/null || echo "    (无 PNG)"
fi
exit $RC

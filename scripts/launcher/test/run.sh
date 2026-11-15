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
# 层级：test -> launcher -> scripts -> 仓库根，故为 ../../..。
# 原 ../.. 只到 scripts/，会挂载错源目录，容器内找不到
# scripts/launcher/AMS-Launcher.sh（2026-11-15 实测发现并修复）。
REPO="$(cd "$HERE/../../.." && pwd)"       # 仓库根
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

# ---- Windows Git Bash / MSYS 路径转换防护（必须在 docker build 之前）----
# MSYS 会自动把「以 / 开头的参数」转成宿主机 Windows 路径，曾导致：
#   -e "OUT_DIR=/out" 变成 "D:/Program Files/.../PortableGit/out"、
#   -v 的容器目标 /opt/ams 被改写（容器内只剩 WORKDIR 空目录 → 启动器找不到）、
#   docker build 的上下文 /e/... 不被 Docker Desktop 识别。
# 修法：① 所有**宿主机侧**路径用 cygpath -m 显式转成 E:/... 形式；
#       ② MSYS2_ARG_CONV_EXCL='*' 禁止 MSYS 对容器侧路径(/opt/ams、/out)做转换。
if command -v cygpath >/dev/null 2>&1; then
    REPO_MNT="$(cygpath -m "$REPO")"
    HOSTOUT_MNT="$(cygpath -m "$HOSTOUT")"
    CTX_MNT="$(cygpath -m "$CTX")"
else
    REPO_MNT="$REPO"
    HOSTOUT_MNT="$HOSTOUT"
    CTX_MNT="$CTX"
fi
export MSYS2_ARG_CONV_EXCL='*'

# ---- 构建镜像 ----
echo "==> 构建镜像 $IMAGE ..."
docker build -t "$IMAGE" -f "$CTX_MNT/Dockerfile" "$CTX_MNT" || { echo "[ERROR] 镜像构建失败"; exit 1; }

# ---- 宿主机中文字体（只读挂载**单个字体文件**，避免重包装入把镜像撑爆）----
# Ubuntu 基础镜像无 CJK 字体，实测 16/16 全过但截屏中文全呈方框（tofu）。
# 曾试 apt 装 fonts-noto-cjk，它拉入 webkit2gtk / gstreamer 等重依赖，
# Docker Desktop 导出镜像时报 input/output error。故改为只读挂载宿主机字体文件：
#   · 单个 simhei.ttf (9.4M) 即可，fc-cache 约 3s；挂整个 Fonts 目录(808 文件)会拖慢扫描。
#   · 镜像体积不变、无需改 Dockerfile、zenity/GTK 经 fontconfig 即可正常渲染中文。
#   · 不依赖「镜像碰巧自带字体」——Dockerfile 回退后重建的镜像是无字体的。
FONT_MOUNTS=()
HOST_FONT_FILE=""
# Windows：优先黑体（覆盖简体中文、体积小），退回雅黑 / 宋体
for f in simhei.ttf msyh.ttc simsun.ttc; do
    if [ -f "/c/Windows/Fonts/$f" ]; then HOST_FONT_FILE="C:/Windows/Fonts/$f"; break; fi
done
# Linux / macOS 宿主：常见中文字体路径
if [ -z "$HOST_FONT_FILE" ]; then
    for f in /usr/share/fonts/truetype/wqy/wqy-microhei.ttc \
             /usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc \
             /usr/share/fonts/truetype/arphic/uming.ttc \
             /System/Library/Fonts/PingFang.ttc; do
        if [ -f "$f" ]; then HOST_FONT_FILE="$f"; break; fi
    done
fi
if [ -n "$HOST_FONT_FILE" ]; then
    FONT_EXT="${HOST_FONT_FILE##*.}"
    FONT_MOUNTS=(-v "$HOST_FONT_FILE:/usr/share/fonts/truetype/host-cjk.${FONT_EXT}:ro")
    echo "==> 中文字体: 只读挂载 $HOST_FONT_FILE -> /usr/share/fonts/truetype/host-cjk.${FONT_EXT}"
else
    echo "==> [WARN] 未找到宿主机中文字体，截屏中文可能仍呈方框（测试会显式判 FAIL）"
fi

# ---- 运行实测 ----
# 清空上一轮截屏：scrot 在目标已存在时会自动加 _000 后缀，
# 导致 .tmp/ams-gui-test/ 里新旧图混杂，复核时极易误看旧图（旧图中文是方框）。
# 只删本目录的 zenity_*.png，不动 result.log 之外的任何仓库文件。
rm -f "$HOSTOUT"/zenity_*.png
echo "==> 挂载: $REPO_MNT -> /opt/ams ; $HOSTOUT_MNT -> /out"
echo "==> 运行 zenity GUI 实测（Xvfb 虚拟显示）..."
docker run --rm \
    -v "$REPO_MNT:/opt/ams:ro" \
    -v "$HOSTOUT_MNT:/out" \
    "${FONT_MOUNTS[@]}" \
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
else
    echo "    (未生成 result.log —— 挂载或容器启动异常，请检查上方日志)"
fi
exit $RC

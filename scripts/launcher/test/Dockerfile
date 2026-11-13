# =================================================================
#  AMS · 启动器 Linux zenity 桌面 GUI 实测沙箱
# =================================================================
#  目的：在「真实 Linux 内核 + 真实 zenity 二进制」上实跑启动器的
#        图形路径，弥补「本机无 Linux 桌面」的实测缺口。
#
#  为什么用 Xvfb：zenity 需要 X 显示才能渲染。Xvfb 在容器内提供一块
#  「虚拟显示器」，因此**无需宿主机装有 X 服务器 / VcXsrv / XQuartz**，
#  在 Windows / macOS / Linux 宿主机上只要 Docker 守护进程在跑即可一键复现。
#  这是 CI 里做 GUI 实测的标准做法，比接物理显示器更可复现。
#
#  关于「容器形态 GUI」：本镜像同时演示两种形态——
#    1) headless（默认，不设置 DISPLAY）→ 启动器自动降级为文本菜单；
#    2) 带显示（Xvfb）→ 启动器弹 zenity 图形菜单与对话框。
#  真实部署容器若想用 GUI，必须显式转发显示（见 test/README.md）。
# =================================================================
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:99

# zenity    真实的图形对话框二进制（被测对象）
# xvfb      虚拟显示器（提供 DISPLAY，无需宿主机 X）
# xdotool   自动化点击/输入，用于驱动 zenity 窗口、验证真实交互
# scrot     对 zenity 窗口截屏，产出「真实渲染」的物证 PNG
# x11-utils 含 xwininfo，辅助窗口探测
# curl/openssl 启动器探针依赖
# shellcheck 顺带做一遍静态门禁
RUN apt-get update && apt-get install -y --no-install-recommends \
        zenity xvfb xdotool scrot x11-utils \
        curl openssl bash coreutils \
        shellcheck \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/ams
# 实测对象（scripts/launcher/AMS-Launcher.sh）由宿主机在运行时挂载进 /opt/ams，
# 故构建期不复制仓库，保证测的是「当前源码」而非快照。
COPY test-zenity.sh /opt/test-zenity.sh
RUN chmod +x /opt/test-zenity.sh

ENTRYPOINT ["/opt/test-zenity.sh"]

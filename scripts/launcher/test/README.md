# AMS 启动器 · Linux zenity 桌面 GUI 实测

> 用于关闭 `docs/17` §3.2.3 的两个历史缺口：
> **① Linux 桌面（zenity）图形菜单的真实 GUI 实测** 与 **② 容器形态 GUI**。

## 为什么需要这个

`AMS-Launcher.sh` 在有桌面且安装 `zenity` 时会弹图形菜单，否则自动降级为文本向导。
「真实 zenity 渲染」在开发机（Windows，无 X/zenity）上无法直接验证，故用本方案在
真实 Linux 内核 + 真实 zenity 二进制上实测。**2026-11-15 已实跑通过：PASS=17 FAIL=0**，
产出 6 张 1280×1024 真实渲染截图（详见 `docs/17` §3.2.3 与 §5.3.1）。

## 中文字体（避免截屏中文变方框）

Ubuntu 基础镜像没有 CJK 字体，中文会渲染成 `□`。`run.sh` 会**只读挂载宿主机单个
中文字体文件**（Windows 优先 `C:/Windows/Fonts/simhei.ttf`，Linux/macOS 有对应探测分支），
容器侧执行 `fc-cache`，并由 `test-zenity.sh` 的**中文字体可用性断言**保证物证有效：
`fc-list :lang=zh` 为空直接判 FAIL，不会出现「交互全过但截图乱码」被放过的情况。
挂载单文件而非整个字体目录（808 个文件会把 `fc-cache` 拖慢），也无需在镜像里装
`fonts-noto-cjk`（该包依赖过重，曾导致 Docker 导出镜像 I/O 错误）。

本方案用 **Docker + Xvfb（虚拟显示器）** 在 Ubuntu 容器里跑**真实 zenity 二进制**，
弥补「无物理 Linux 桌面」的缺口。Xvfb 自带显示，所以**宿主机不需要安装 X 服务器 /
VcXsrv / XQuartz**，在 Windows / macOS / Linux 上只要 Docker 守护进程在跑即可一键复现。

## 一键运行

```bash
# 前置：安装 Docker 并启动 Docker 守护进程（Docker Desktop 或 dockerd）
bash scripts/launcher/test/run.sh
```

脚本会：构建镜像 → 把仓库只读挂载进 `/opt/ams`（测的就是当前源码）→
运行 `test-zenity.sh` → 把 `result.log` 与 `zenity_*.png` 截屏落到仓库 `.tmp/ams-gui-test/`。

## 实测覆盖（test-zenity.sh）

| # | 项目 | 性质 | 说明 |
| --- | --- | --- | --- |
| 0 | GUI 自适应检测 | 确定性 | `DISPLAY+zenity → "zenity"`；`无 DISPLAY → ""`（文本） |
| 1 | preflight / cfg_set 失败关闭 | 确定性（文本层） | 缺三密钥被识别、补齐后 0 问题、短令牌(5B)被拦截、键值独占一行 |
| 2 | 真实 zenity 渲染 + 交互 | **真 GUI** | 信息框 / 是-否(返回码 0/1) / 输入框 / 隐藏口令，均用 xdotool 真实驱动并截屏 |
| 3 | 完整 zenity 列表菜单 | **真 GUI** | 真实渲染启动器主菜单并正常退出（截屏 `zenity_menu.png`） |
| 4 | headless 容器形态 | 真实降级 | 无 `DISPLAY` 时自动进入文本菜单、不崩溃、正常退出 |
| 5 | shellcheck | 静态门禁 | 启动器无 warning/error |

`zenity_*.png` 是**真实渲染的物证**（虚拟帧缓冲截图），不是示意图。

## 容器形态 GUI（结论）

- **默认 headless 容器（不设置 `DISPLAY`）**：启动器检测到无显示，自动使用**文本菜单**。
  这是生产容器（`deploy/compose/docker-compose.yml`）的正确形态——命令行 + 健康检查，
  不需要 GUI。此项**已在本实测的 headless 阶段验证**。
- **若要在容器里用 GUI**：必须显式提供显示。两种方式：
  1. **容器内 Xvfb**（本测试的做法，自包含、可复现）：在容器里起 `Xvfb :99` 并设置 `DISPLAY=:99`；
  2. **转发宿主机 X**：`docker run -e DISPLAY=$DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix ...`
     （需宿主机有 X 服务器并 `xhost +local:` 授权）。
- 不要把 `DISPLAY` 设成一个**不存在的 X socket**——zenity 会因连不上显示而报错，
  此时对话框函数会失败（如 `ask_yesno` 返回非零，被当作「否」）。标准做法是：
  要么不设置 `DISPLAY`（文本模式），要么确保 `DISPLAY` 指向可达的显示（Xvfb 或转发的 X）。

## 与失败关闭契约的关系

本实测只验证「启动器的 GUI 外壳」行为；真正拒绝以默认密钥启动、缺密钥不拉起进程等
**权威判定仍在服务端 `main.cj` 的 SEC-001**（见 `docs/17` §3.2.3）。启动器在任何形态下
都只调用 `scripts/start.sh` / `scripts/start.cmd`，不替代命令行入口。

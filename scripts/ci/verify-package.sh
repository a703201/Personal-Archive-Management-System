#!/bin/bash
# ============================================================
# AMS · 发布包可运行性校验
#
# 用途：验证打包产物**能独立启动**（即运行时 DLL 齐全）。
#
# 为什么不能只做健康检查？
#   主程序在**数据库不可用**时会主动退出（返回码 1，日志里有
#   "server.db.unavailable"）。这属于**正常的业务行为**，不是打包缺陷。
#   而「缺 DLL」的表现是进程**瞬间死亡**并打印
#   "error while loading shared libraries" —— 这才是真正要拦住的。
#
# 判定逻辑（区分「二进制加载」与「功能就绪」两个维度）：
#   ① 进程瞬间死亡且日志含加载器错误 → ❌ 失败（运行时缺失）
#   ② 日志出现 "server.db.unavailable" / 连接被拒 → ⚠️ 二进制可加载，但
#      **功能就绪未验证**（CI 无数据库）；发布包校验仍算通过（exit 0），
#      但输出明确 WARN，不笼统宣称「完整可运行」。
#   ③ 健康检查通过 → ✅ 二进制可加载 + 功能就绪（端到端可用）
#
# 语义边界：本脚本验证的是**发布包能否独立加载并启动**，不是功能验收。
#   CI 无 DB 时只能证明前者；后者需要连真实数据库的部署/冒烟测试覆盖。
#
# 用法：
#   bash scripts/ci/verify-package.sh <包目录> [端口]
# ============================================================
set -uo pipefail

PKG_DIR="${1:?用法：verify-package.sh <包目录> [端口]}"
PORT="${2:-18099}"

if [ ! -d "$PKG_DIR" ]; then
    echo "[ERROR] 包目录不存在：${PKG_DIR}"
    exit 1
fi

# 转成绝对路径：后面要 cd 进 bin/，相对路径会失效
PKG_DIR_ABS="$(cd "$PKG_DIR" && pwd)"
BIN_DIR="${PKG_DIR_ABS}/bin"

if [ ! -d "$BIN_DIR" ]; then
    echo "[ERROR] 缺少 bin/ 目录：${BIN_DIR}"
    exit 1
fi

# ---- 桌面启动器静态断言（不参与启动判定，只防「失败关闭」被后续改动破坏）----
# 按包内实际存在的 launcher 文件判定平台：不能用主程序后缀判断
# （交叉打包 / 占位产物下 bin/ams-server.exe 与平台未必对应）。
echo "=== 校验桌面启动器完整性 ==="
if [ -f "${PKG_DIR_ABS}/launcher/AMS-Launcher.ps1" ] \
   || [ -f "${PKG_DIR_ABS}/launcher/AMS-Launcher.cmd" ]; then
    LAUNCHER_FILES="launcher/AMS-Launcher.ps1 launcher/AMS-Launcher.cmd"
    LAUNCHER_PLATFORM="windows"
elif [ -f "${PKG_DIR_ABS}/launcher/AMS-Launcher.sh" ]; then
    LAUNCHER_FILES="launcher/AMS-Launcher.sh"
    LAUNCHER_PLATFORM="linux"
else
    echo "  ✗ 包内没有任何桌面启动器文件（launcher/ 缺失）"
    exit 1
fi
echo "  平台: ${LAUNCHER_PLATFORM}"
for rel in $LAUNCHER_FILES; do
    if [ ! -f "${PKG_DIR_ABS}/${rel}" ]; then
        echo "  ✗ 缺少启动器文件：${rel}"
        exit 1
    fi
    echo "  ✓ ${rel}"
done

# 红线：启动器里不得硬编码任何凭据默认值或开发兜底密钥，也不得自动重启服务。
# 注意只匹配「赋值/默认值」形态，不误伤正常的键名读取与脱敏正则。
for rel in $LAUNCHER_FILES; do
    f="${PKG_DIR_ABS}/${rel}"
    if grep -nEi \
        '(TOKEN_SECRET|KEK|DB_PASSWORD)[[:space:]]*=[[:space:]]*["'"'"'][A-Za-z0-9+/=_-]{8,}["'"'"']' \
        "$f" 2>/dev/null; then
        echo "  ✗ 启动器含硬编码凭据默认值：${rel}"
        exit 1
    fi
    if grep -nEi 'ams-dev-token-secret|auto[-_ ]?restart|自动重启' "$f" 2>/dev/null | \
       grep -vqiE '不会|绝不|不自动|no auto|never|#|REM|不生成'; then
        echo "  ✗ 启动器含开发兜底密钥或自动重启模式：${rel}"
        exit 1
    fi
done
echo "  ✓ 未发现硬编码凭据 / 自动重启模式"
echo ""

# ---- 迁移资源静态断言（随包分发，供 init 容器在部署时执行）----
echo "=== 校验数据库迁移资源完整性 ==="
MIG_DIR="${PKG_DIR_ABS}/db/migrations"
MIG_COUNT="$(find "$MIG_DIR" -maxdepth 1 -name '*.sql' -type f 2>/dev/null | wc -l | tr -d ' ')"
MIG_COUNT="${MIG_COUNT:-0}"
if [ "$MIG_COUNT" -lt 1 ]; then
    echo "  ✗ 包内缺少 db/migrations/*.sql（当前 ${MIG_COUNT} 个）"
    exit 1
fi
if [ ! -f "${PKG_DIR_ABS}/deploy/scripts/migrate.sh" ]; then
    echo "  ✗ 包内缺少 deploy/scripts/migrate.sh（迁移执行器）"
    exit 1
fi
echo "  ✓ ${MIG_COUNT} 个迁移 SQL + deploy/scripts/migrate.sh"
echo ""

# 找主程序
if   [ -f "${BIN_DIR}/ams-server.exe" ]; then SERVER="${BIN_DIR}/ams-server.exe"
elif [ -f "${BIN_DIR}/ams-server" ];     then SERVER="${BIN_DIR}/ams-server"
else
    echo "[ERROR] 找不到主程序（ams-server.exe / ams-server）"
    exit 1
fi

LOG="ams-verify-$$.log"
echo "=== 校验发布包可运行性 ==="
echo "  包   : ${PKG_DIR}"
echo "  主程序: ${SERVER}"
echo "  端口 : ${PORT}"
echo ""

cd "$BIN_DIR"

# 用独立端口与独立配置启动
export AMS_HTTP_PORT="${PORT}"
export AMS_TOKEN_SECRET="${AMS_TOKEN_SECRET:-package-verify-secret-0123456789abcdef}"

# 注意：不设置 AMS_DB_PASSWORD 时会用代码里的本地默认值；
#       无论如何都要能启动到「DB 检查」这一步，才说明运行时齐全。
"$SERVER" > "$LOG" 2>&1 &
SRV_PID=$!

# 最多等 20 秒
# OK：二进制已成功加载并启动（本脚本的核心校验目标）
# FUNC_READY：功能就绪（健康检查 200 通过）——CI 无 DB 时为 0，必须诚实输出 WARN
OK=0
FUNC_READY=0
for i in $(seq 1 20); do
    sleep 1
    # ③ 健康检查通过：二进制加载 + 功能就绪
    if curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
        echo "  ✓ 功能就绪：健康检查通过（HTTP 200）"
        OK=1
        FUNC_READY=1
        break
    fi
    # ② 数据库不可用（正常业务退出，不是打包问题）
    #   服务器启动后会尝试连 DB；CI / 发布校验环境通常没有数据库实例，
    #   连接会被拒绝。只要到达「DB 检查」这一步，就证明运行时 DLL 齐全、
    #   主程序能独立加载 —— 这正是本步骤要拦的打包缺陷的反面。
    #   两种日志签名都算「已正常启动、非打包问题」：
    #     - 代码显式打 "server.db.unavailable"
    #     - 驱动抛 SqliteException / SocketException：连接被拒
    #       （Failed to connect / actively refused / No connection could be made）
    if grep -q "server.db.unavailable" "$LOG" 2>/dev/null \
       || grep -qiE "SqliteException|SocketException|Failed to connect|actively refused|No connection could be made|connection.*refused|database.*unavailable" "$LOG" 2>/dev/null; then
        # 只证明「二进制加载齐全、能启动到 DB 检查」，不能宣称功能就绪。
        echo "  [WARN] 二进制可加载（已启动到 DB 检查），但当前环境无可用数据库："
        echo "  [WARN] 功能就绪**未验证**。本步骤只覆盖发布包可运行性，"
        echo "  [WARN] 端到端功能请在连真实 DB 的部署/冒烟测试中确认。"
        OK=1
        break
    fi
    # ① 进程已死 → 加载错误
    if ! kill -0 "$SRV_PID" 2>/dev/null; then
        if grep -qi "error while loading shared libraries\|could not load the dynamic library\|RunCJTask" "$LOG" 2>/dev/null; then
            echo "  ✗ 运行时加载失败（缺少 DLL）："
            sed 's/^/      /' "$LOG" | head -5
            echo ""
            echo "      缺失的通常是 MinGW 运行库："
            echo "        libgcc_s_seh-1.dll / libwinpthread-1.dll / libpcre2-8.dll"
            rm -f "$LOG"
            exit 1
        fi
        # 其它原因退出 → 也算失败
        echo "  ✗ 服务进程提前退出："
        sed 's/^/      /' "$LOG" | head -8
        rm -f "$LOG"
        exit 1
    fi
done

kill "$SRV_PID" 2>/dev/null || true
sleep 1
kill -9 "$SRV_PID" 2>/dev/null || true

if [ "$OK" != "1" ]; then
    echo "  ✗ 20 秒内服务未就绪："
    sed 's/^/      /' "$LOG" | head -8
    rm -f "$LOG"
    exit 1
fi

rm -f "$LOG"
echo ""
if [ "$FUNC_READY" = "1" ]; then
    echo "=== 发布包校验通过：二进制可加载 + 功能就绪（健康检查 200）==="
else
    echo "=== 发布包校验通过（有限）：二进制可加载，功能就绪未验证（CI 无数据库）==="
    echo "[WARN] 语义说明：此结果只证明发布包能独立加载并启动到 DB 检查，"
    echo "[WARN] 不代表业务功能可用；请勿据此宣称端到端功能已通过。"
fi
exit 0

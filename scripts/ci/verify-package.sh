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
# 判定逻辑：
#   ① 进程瞬间死亡且日志含加载器错误 → ❌ 失败（运行时缺失）
#   ② 日志出现 "server.db.unavailable" → ✅ 通过（缺数据库，非打包问题）
#   ③ 健康检查通过 → ✅ 通过（完整体验）
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
OK=0
for i in $(seq 1 20); do
    sleep 1
    # ③ 健康检查通过
    if curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
        echo "  ✓ 健康检查通过（完整可运行）"
        OK=1
        break
    fi
    # ② 数据库不可用（正常业务退出，不是打包问题）
    if grep -q "server.db.unavailable" "$LOG" 2>/dev/null; then
        echo "  ✓ 服务正常启动并进入就绪检查（数据库不可用，非打包问题）"
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
echo "=== 发布包校验通过 ==="
exit 0

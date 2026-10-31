#!/bin/bash
# ============================================================
# AMS · 数据库初始化（容器化部署用）
#
# 用途：对已启动的 openGauss 容器依次执行 db/migrations/*.sql。
#       等价于物理机侧的 `python scripts/db.py exec <file>`，
#       区别是不依赖宿主机 Python，直接用容器内的 gsql。
#
# 前提：db 容器已把仓库的 db/migrations 挂载到 /migrations（见
#       deploy/compose/docker-compose.yml 的 db.volumes）。
#
# 用法：
#   bash deploy/scripts/init-db.sh                  # 幂等初始化（已有 schema 则跳过）
#   bash deploy/scripts/init-db.sh --force          # 强制重跑全部迁移
#   AMS_DB_CONTAINER=ams_opengauss bash deploy/scripts/init-db.sh
#
# 环境变量：
#   AMS_DB_CONTAINER  db 容器名（默认 ams_opengauss）
#   AMS_DB_NAME       数据库名（默认 ams）
#   AMS_DB_USER       用户名（默认 gaussdb）
#   AMS_DB_PASSWORD   口令（默认取本地开发值，生产务必显式传入）
# ============================================================
set -uo pipefail

CONTAINER="${AMS_DB_CONTAINER:-ams_opengauss}"
DB="${AMS_DB_NAME:-ams}"
USER="${AMS_DB_USER:-gaussdb}"
PASS="${AMS_DB_PASSWORD:-Ams@Gauss2026}"
FORCE=0
for a in "$@"; do
    case "$a" in
        --force) FORCE=1 ;;
    esac
done

GSQL="/usr/local/opengauss/bin/gsql"
export MSYS_NO_PATHCONV=1

gsql_run() {
    # gsql 的 -c/-f 均由容器内执行；口令内嵌在连接串里
    #（openGauss 不读 PGPASSWORD，实测无效，故写进 conninfo）
    docker exec -i "$CONTAINER" bash -lc \
        "LD_LIBRARY_PATH=/usr/local/opengauss/lib $GSQL \
         'host=127.0.0.1 port=5432 user=${USER} password=${PASS} dbname=${DB}' $*"
}

echo "=== AMS 数据库初始化 ==="
echo "  容器 : $CONTAINER"
echo "  库   : $DB"
echo ""

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "[ERROR] 容器 $CONTAINER 未运行。先执行："
    echo "        docker compose -f deploy/compose/docker-compose.yml up -d db"
    exit 1
fi

# 幂等检查：sys_users 存在即视为已初始化
if [ "$FORCE" = "0" ]; then
    has_tbl="$(gsql_run "-t -A -c \"SELECT count(*) FROM information_schema.tables WHERE table_name='sys_users';\"" 2>/dev/null | tr -d '[:space:]')"
    if [ "$has_tbl" = "1" ]; then
        echo "[SKIP] 检测到 sys_users 已存在，跳过初始化（--force 可强制重跑）"
        exit 0
    fi
fi

# migrations 在容器内的挂载点
if ! docker exec "$CONTAINER" test -d /migrations; then
    echo "[ERROR] 容器内没有 /migrations 目录。请确认 compose 已挂载："
    echo "        ./db/migrations:/migrations:ro"
    exit 1
fi

fail=0
total=0
for f in $(docker exec "$CONTAINER" bash -lc "ls /migrations/*.sql | sort"); do
    total=$((total + 1))
    name="$(basename "$f")"
    printf "  [%-3s] %-34s " "$total" "$name"
    out="$(gsql_run "-v ON_ERROR_STOP=1 -q -f $f" 2>&1)"
    if [ $? -eq 0 ]; then
        echo "OK"
    else
        echo "FAILED"
        echo "$out" | head -6 | sed 's/^/         /'
        fail=$((fail + 1))
    fi
done

echo ""
if [ "$fail" -eq 0 ]; then
    echo "=== 初始化完成：$total 个迁移全部成功 ==="
    gsql_run "-c \"SELECT count(*) AS tables FROM information_schema.tables WHERE table_schema='public';\"" 2>/dev/null | head -4
else
    echo "=== 初始化失败：$fail / $total 个迁移出错 ==="
    exit 1
fi

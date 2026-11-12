#!/bin/bash
# ============================================================
# AMS · 数据库逻辑备份（在 db 容器内用 openGauss 自带 gs_dump）
#
# 在宿主机执行；gs_dump 与 gsql 同目录，调用方式（LD_LIBRARY_PATH、
# conninfo 连接串、口令写进连接串）依据 deploy/scripts/migrate.sh
# 与 deploy/scripts/init-db.sh、scripts/db.py。
#
# 用法：
#   set -a; source deploy/compose/.env; set +a     # 载入 AMS_DB_PASSWORD
#   bash deploy/scripts/backup.sh
#   AMS_BACKUP_KEEP=14 bash deploy/scripts/backup.sh
#
# 环境变量：
#   AMS_DB_PASSWORD   必填；脚本不硬编码任何口令（生产显式提供）
#   AMS_DB_CONTAINER  db 容器名（默认 ams_opengauss）
#   AMS_DB_NAME / AMS_DB_USER   库名 / 用户（默认 ams / gaussdb）
#   AMS_BACKUP_DIR    容器内产物目录（默认 /app/data-backups）
#   AMS_BACKUP_KEEP   保留最近几份备份（默认 7，含本次产物）
#   注：口令按仓库既有写法嵌入 conninfo，请勿使用含单引号的口令，
#       否则会破坏连接串的引用。
#
# 产物（db 容器内）：
#   /app/data-backups/ams-YYYYmmdd-HHMMSS.sql          纯 SQL 转储
#   /app/data-backups/ams-YYYYmmdd-HHMMSS.sql.sha256   sha256 校验文件
#   dump 带 --clean --if-exists，配合 restore.sh 可覆盖导入现有库。
#
# [!] 持久化：compose 把 ams-backups 命名卷同时挂到 db 与 ams 服务的
#     /app/data-backups，产物落在卷里，容器重建不会丢失；本脚本仍用
#     -u root 建目录并交给 omm（卷首次挂载时属主为 root）。
#     但卷与数据库同机，整机故障仍会一起丢失，务必按结尾提示用
#     docker cp 取到宿主机 / 异地留存。详见 deploy/RUNBOOK.md。
# ============================================================
set -euo pipefail

CONTAINER="${AMS_DB_CONTAINER:-ams_opengauss}"
DB="${AMS_DB_NAME:-ams}"
USER="${AMS_DB_USER:-gaussdb}"
PASS="${AMS_DB_PASSWORD:?请设置 AMS_DB_PASSWORD（如：set -a; source deploy/compose/.env; set +a）}"
BACKUP_DIR="${AMS_BACKUP_DIR:-/app/data-backups}"
KEEP="${AMS_BACKUP_KEEP:-7}"
GSDUMP=/usr/local/opengauss/bin/gs_dump
# db 容器内部连本机 openGauss：容器内监听 5432（宿主映射才是 15432）
CONN="host=127.0.0.1 port=5432 user=${USER} password=${PASS} dbname=${DB}"

if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || [ "$KEEP" -lt 1 ]; then
  echo "[ERROR] AMS_BACKUP_KEEP 必须是 >=1 的整数，当前为：$KEEP" >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "[ERROR] 容器 $CONTAINER 未运行。先执行：bash deploy/scripts/run-app.sh" >&2
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
NAME="ams-${TS}.sql"
OUT="${BACKUP_DIR}/${NAME}"

echo "=== AMS 数据库备份 ==="
echo "  容器 : $CONTAINER"
echo "  库   : $DB / 用户 $USER"
echo "  产物 : $OUT"

# db 默认以 omm 运行，容器内可能没有 /app/data-backups；用 root 建好后
# 把属主交给 omm，保证下面以 omm 身份执行的 gs_dump 能写入该目录。
docker exec -u root "$CONTAINER" bash -lc \
  "mkdir -p '$BACKUP_DIR' && chown omm: '$BACKUP_DIR'"

# -F p 输出纯 SQL（可用 gsql -f 导入）；-c（--clean）配合 --if-exists
# 让 dump 带上 DROP IF EXISTS，恢复时能覆盖现有同名对象。
# 以上是 openGauss gs_dump（pg_dump 兼容）选项；恢复到同一实例 / 同一
# gaussdb 用户，不需要 --no-owner 或去权限选项。openGauss 不读 PGPASSWORD，
# 口令按 migrate.sh 的做法写进 conninfo 连接串作为位置参数传入。
docker exec -i "$CONTAINER" bash -lc \
  "export LD_LIBRARY_PATH=/usr/local/opengauss/lib; exec $GSDUMP '$CONN' -F p -c --if-exists -f '$OUT'"

# 生成 sha256 校验文件（记录相对文件名，便于在目录内 sha256sum -c）
docker exec -i "$CONTAINER" bash -lc \
  "cd '$BACKUP_DIR' && sha256sum '$NAME' > '${NAME}.sha256'"

echo ""
echo "=== 备份完成 ==="
echo "  SQL  : $OUT"
echo "  校验 : ${OUT}.sha256"
echo "  取回宿主机（建议立即执行并异地留存）："
echo "    docker cp ${CONTAINER}:${OUT} ./${NAME}"
echo "    docker cp ${CONTAINER}:${OUT}.sha256 ./${NAME}.sha256"
echo "    cd <存放目录> && sha256sum -c ${NAME}.sha256"

# ---- 自动清理：只保留最近 KEEP 份 ams-*.sql 及其 .sha256 ----
# 文件名含时间戳，且按 mtime 倒序（ls -1t）；数组切片从第 KEEP 个起为待删。
mapfile -t BACKUPS < <(docker exec "$CONTAINER" bash -lc \
  "cd '$BACKUP_DIR' 2>/dev/null && ls -1t ams-*.sql 2>/dev/null" || true)
if [ "${#BACKUPS[@]}" -gt "$KEEP" ]; then
  for old in "${BACKUPS[@]:KEEP}"; do
    docker exec "$CONTAINER" bash -lc "cd '$BACKUP_DIR' && rm -f -- '$old' '${old}.sha256'"
    echo "  清理旧备份：$old"
  done
fi
echo "  保留策略：AMS_BACKUP_KEEP=$KEEP（当前 ${#BACKUPS[@]} 份）"

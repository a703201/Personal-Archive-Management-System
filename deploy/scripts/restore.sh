#!/bin/bash
# ============================================================
# AMS · 从逻辑备份恢复（在 db 容器内用 gsql 导入）
#
# [!!] 危险操作：会覆盖 ams 库现有数据。备份由 backup.sh 以
#      --clean --if-exists 导出，导入时先 DROP 再重建同名对象，
#      备份时间点之后写入的数据将丢失。执行前必须输入 RESTORE 二次确认。
#
# 用法（宿主机执行）：
#   set -a; source deploy/compose/.env; set +a
#   bash deploy/scripts/restore.sh /app/data-backups/ams-20261107-120000.sql
#   # 参数是 db 容器内的路径；若备份文件在宿主机，先拷进容器：
#   docker cp ./ams-20261107-120000.sql ams_opengauss:/app/data-backups/
#
# 环境变量：同 backup.sh（AMS_DB_PASSWORD 必填，不硬编码口令）。
#
# 调用方式依据 deploy/scripts/migrate.sh / init-db.sh：
#   gsql 路径、LD_LIBRARY_PATH、conninfo 连接串、-v ON_ERROR_STOP=1 -f。
# 恢复后校验项见 deploy/RUNBOOK.md §4。
# ============================================================
set -euo pipefail

CONTAINER="${AMS_DB_CONTAINER:-ams_opengauss}"
DB="${AMS_DB_NAME:-ams}"
USER="${AMS_DB_USER:-gaussdb}"
PASS="${AMS_DB_PASSWORD:?请设置 AMS_DB_PASSWORD（如：set -a; source deploy/compose/.env; set +a）}"
GSQL=/usr/local/opengauss/bin/gsql
CONN="host=127.0.0.1 port=5432 user=${USER} password=${PASS} dbname=${DB}"

if [ "$#" -ne 1 ]; then
  echo "用法: bash deploy/scripts/restore.sh <备份文件路径（db 容器内）>" >&2
  echo "     备份文件在宿主机时先执行：" >&2
  echo "       docker cp <本地文件> ${CONTAINER}:/app/data-backups/" >&2
  exit 1
fi
BACKUP_FILE="$1"
BACKUP_DIR="$(dirname "$BACKUP_FILE")"
BACKUP_NAME="$(basename "$BACKUP_FILE")"
SUM_NAME="${BACKUP_NAME}.sha256"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "[ERROR] 容器 $CONTAINER 未运行。先执行：bash deploy/scripts/run-app.sh" >&2
  exit 1
fi

# gsql -f 读的是容器内路径，先确认文件在 db 容器内可见
if ! docker exec "$CONTAINER" test -f "$BACKUP_FILE"; then
  echo "[ERROR] 容器内找不到备份文件：$BACKUP_FILE" >&2
  echo "        若文件在宿主机，先拷入容器：" >&2
  echo "          docker cp <本地文件> ${CONTAINER}:${BACKUP_DIR}/" >&2
  exit 1
fi

echo "=== AMS 数据库恢复（危险操作）==="
echo "  容器 : $CONTAINER"
echo "  库   : $DB / 用户 $USER"
echo "  备份 : $BACKUP_FILE"
echo ""
echo "  [!!] 此操作会覆盖现有数据：备份内含 DROP/CREATE，导入时会"
echo "       重建同名表与对象，备份时间点之后的数据将丢失。"
echo "       建议先停应用写入：docker compose -p ams -f deploy/compose/docker-compose.yml stop ams"
echo "       并对当前库另做一份备份：bash deploy/scripts/backup.sh"
echo ""

# 有同名 sha256 文件则先校验，校验失败一律中止
if docker exec "$CONTAINER" test -f "${BACKUP_DIR}/${SUM_NAME}"; then
  echo "  sha256 校验中 ..."
  if ! docker exec -i "$CONTAINER" bash -lc \
      "cd '$BACKUP_DIR' && sha256sum -c '$SUM_NAME'"; then
    echo "[ERROR] sha256 校验失败，已中止恢复（未做任何改动）" >&2
    exit 1
  fi
else
  echo "  [WARN] 未找到 ${BACKUP_DIR}/${SUM_NAME}，跳过校验（建议补齐后再恢复）"
fi

# 二次确认：必须精确输入 RESTORE，其它输入（含空）一律取消
read -r -p "确认请输入 RESTORE（其它输入一律取消）：" ans
if [ "$ans" != "RESTORE" ]; then
  echo "已取消，未做任何改动。"
  exit 1
fi

echo "=== 开始导入（gsql -f）==="
docker exec -i "$CONTAINER" bash -lc \
  "export LD_LIBRARY_PATH=/usr/local/opengauss/lib; exec $GSQL '$CONN' -v ON_ERROR_STOP=1 -q -f '$BACKUP_FILE'"

echo ""
echo "=== 导入命令已执行，请按 deploy/RUNBOOK.md §4 做恢复后校验 ==="
echo "  1) 迁移台账：_ams_migrations 行数与发布版本一致"
echo "  2) 健康检查：curl -fsS http://127.0.0.1:8080/api/health"
echo "  3) 业务抽样：登录、档案列表、附件下载、审计链"
echo "  4) 如需重启应用：docker compose -p ams -f deploy/compose/docker-compose.yml up -d ams"

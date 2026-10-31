#!/bin/bash
# ============================================================
# AMS · 迁移执行脚本（在 init 容器内运行，对应 rg_realdb_init）
#
# 由 deploy/compose/docker-compose.yml 的 init 服务以
#   entrypoint: ["/bin/bash", "/migrate.sh"]
# 调用。该容器与 db 同源（enmotech/opengauss 镜像，自带 gsql 客户端），
# 通过 TCP 连 db 的静态 IP，对 /migrations/*.sql 逐一执行。
#
# 幂等模型：**逐迁移台账表** `_ams_migrations`（每成功一个文件登记一条）。
#
# [为什么废弃「sys_users 存在就整体跳过」]
#   旧逻辑是一次性 shortcut：库一旦初始化，后续**新增**的迁移文件就永远
#   不会被执行 —— 实测正是这样丢掉了 020_attachment_summary（summary /
#   keywords 两列）与 021_import_templates（arc_import_templates 表），
#   运行时表现为「时不时冒出来的数据库操作失败」。
#   现在是「每个文件跑且只跑一次（成功即登记）」，下次起栈会自动补齐
#   新增迁移，这才是可演进部署该有的样子。
#
# [openGauss 5.0 限制]
#   不支持 PostgreSQL 的 `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`
#   （实测报 syntax error at or near "NOT EXISTS"）。迁移文件里的幂等请
#   用 DO 块 + information_schema 守卫（参见 022_tenant_isolation.sql、
#   020_attachment_summary.sql、008_attachment_dek.sql）。
#
# 退出码：全部成功 0；有失败 1。（compose 用 service_completed_successfully 判断）
# ============================================================
set -uo pipefail

export LD_LIBRARY_PATH=/usr/local/opengauss/lib
GSQL=/usr/local/opengauss/bin/gsql

HOST="${AMS_DB_HOST:-172.28.0.10}"
PORT="${AMS_DB_PORT:-5432}"
DB="${AMS_DB_NAME:-ams}"
USER="${AMS_DB_USER:-gaussdb}"
PASS="${AMS_DB_PASSWORD:-Ams@Gauss2026}"
# openGauss 不读 PGPASSWORD，口令须写进 conninfo 连接串
CONN="host=${HOST} port=${PORT} user=${USER} password=${PASS} dbname=${DB}"

# ---- 先解析参数（旧版把这里写在「跳过」判断之后，导致 --force 是死代码）----
FORCE=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
  esac
done

echo "=== AMS 数据库迁移（容器内 init 任务）==="
echo "  target : ${HOST}:${PORT}/${DB}"
if [ "$FORCE" = "1" ]; then
  echo "  mode   : --force（忽略台账，全部重跑）"
fi

# 等待 db 可连（最多 60s）
for i in $(seq 1 60); do
  if $GSQL "$CONN" -t -A -c "SELECT 1;" >/dev/null 2>&1; then
    echo "  db reachable after ${i}s"
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "[ERROR] 60s 内仍无法连接 db，退出"
    exit 1
  fi
  sleep 1
done

# ---- 迁移台账：记录「已成功执行过」的迁移文件名 ----
if ! $GSQL "$CONN" -q -c "
CREATE TABLE IF NOT EXISTS _ams_migrations (
    name       TEXT PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);" >/dev/null 2>&1; then
  echo "[ERROR] 无法创建迁移台账表 _ams_migrations"
  exit 1
fi

applied=0
skipped=0
failed=0
total=0

for f in $(ls /migrations/*.sql 2>/dev/null | sort); do
  total=$((total + 1))
  name="$(basename "$f")"

  # 台账里已有且非强制 → 跳过
  if [ "$FORCE" != "1" ]; then
    already="$($GSQL "$CONN" -t -A -c "SELECT count(*) FROM _ams_migrations WHERE name = '${name}';" 2>/dev/null | tr -d '[:space:]')"
    if [ "$already" = "1" ]; then
      skipped=$((skipped + 1))
      printf "  [%-3s] %-38s SKIP(已登记)\n" "$total" "$name"
      continue
    fi
  fi

  printf "  [%-3s] %-38s " "$total" "$name"
  if out="$($GSQL "$CONN" -v ON_ERROR_STOP=1 -q -f "$f" 2>&1)"; then
    # 只有执行成功才登记，避免「失败的迁移被误记为已完成」
    $GSQL "$CONN" -q -c "INSERT INTO _ams_migrations (name) VALUES ('${name}');" >/dev/null 2>&1
    applied=$((applied + 1))
    echo "OK"
  else
    failed=$((failed + 1))
    echo "FAILED"
    echo "$out" | head -6 | sed 's/^/         /'
  fi
done

echo ""
if [ "$total" -eq 0 ]; then
  echo "[WARN] /migrations 下没有 .sql 文件"
  exit 0
fi
echo "=== 迁移完成：apply=${applied} skip=${skipped} fail=${failed} / total=${total} ==="
if [ "$failed" -eq 0 ]; then
  exit 0
else
  echo "=== 迁移失败：${failed} 个迁移出错 ==="
  exit 1
fi

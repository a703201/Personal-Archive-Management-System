#!/bin/bash
# ============================================================
# AMS · 恢复演练（脚本已提供，默认未启用；绝不碰生产数据）
#
# 在独立的临时 docker 容器里拉起一个全新的 openGauss 实例，把指定备份
# 导入这个临时库，跑只读校验 SQL，输出结果与验收结论；结束时无论成功
# 失败都清理临时容器 / 网络。
#
# [!!] 不连接、不挂载、不写入任何生产容器 / 卷 / 网络；演练实例口令是
#      独立的临时随机值，绝不复用生产 AMS_DB_PASSWORD。
# [!!] 镜像 enmotech/opengauss:5.0.0 的初始化变量（GS_PASSWORD /
#      GS_USERNAME / GS_DBNAME）依据 deploy/compose/docker-compose.yml
#      的 db 服务；gsql 路径与 LD_LIBRARY_PATH、conninfo 位置参数写法依据
#      deploy/scripts/backup.sh / restore.sh。本脚本未在实机验证过，
#      运维首次启用前请用 --dry-run 核对命令并按所用镜像版本调整。
#
# 用法（宿主机执行）：
#   bash deploy/scripts/restore-drill.sh --dry-run ./ams-20261107-120000.sql
#   bash deploy/scripts/restore-drill.sh ./ams-20261107-120000.sql
#   DRILL_TIMEOUT=300 bash deploy/scripts/restore-drill.sh <备份.sql>
#
# 参数：<备份文件路径>（宿主机路径；同名 .sha256 存在则先校验）
#
# 环境变量（全部可选）：
#   DRILL_IMAGE        演练镜像（默认 enmotech/opengauss:5.0.0）
#   DRILL_DB_USER      临时实例用户（默认 gaussdb）
#   DRILL_DB_NAME      导入目标库（默认 ams，镜像初始化即创建）
#   DRILL_DB_PASSWORD  临时实例口令；不设则每次随机生成，绝不复用生产口令。
#                      请勿使用含单引号的口令（会破坏 conninfo 连接串）。
#   DRILL_TIMEOUT      就绪等待 / 导入的超时秒数（默认 180）
#   DRILL_KEY_TABLES   关键表清单（空格分隔，默认 "sys_users _ams_migrations"）
#
# --dry-run：只打印将执行的命令（打印到 stderr，口令显示为占位符），
#            不创建容器 / 网络、不导入、不做校验、不碰生产数据。
#
# 校验 SQL（只读，全部在临时实例上执行）：
#   - SELECT count(*) FROM information_schema.tables WHERE table_schema='public'
#   - SELECT count(*) FROM sys_users
#   - 关键表是否都在 information_schema.tables 中
# 验收标准见 deploy/RUNBOOK.md §4.4。
# ============================================================
set -euo pipefail

usage() {
  echo "用法: bash deploy/scripts/restore-drill.sh [--dry-run] <宿主机备份.sql>"
  echo "  --dry-run   只打印将执行的命令，不创建容器 / 网络、不碰生产数据"
  echo "  -h|--help   显示本帮助"
  echo "环境变量（可选）：DRILL_IMAGE / DRILL_DB_USER / DRILL_DB_NAME /"
  echo "                 DRILL_DB_PASSWORD / DRILL_TIMEOUT / DRILL_KEY_TABLES"
}

DRY_RUN=0
BACKUP_FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "[ERROR] 未知选项：$1" >&2; usage >&2; exit 1 ;;
    *)
      if [ -n "$BACKUP_FILE" ]; then
        echo "[ERROR] 只能指定一个备份文件（多余参数：$1）" >&2
        exit 1
      fi
      BACKUP_FILE="$1"
      ;;
  esac
  shift
done
if [ -z "$BACKUP_FILE" ]; then
  echo "[ERROR] 缺少备份文件路径" >&2
  usage >&2
  exit 1
fi

DRILL_IMAGE="${DRILL_IMAGE:-enmotech/opengauss:5.0.0}"
DRILL_DB_USER="${DRILL_DB_USER:-gaussdb}"
DRILL_DB_NAME="${DRILL_DB_NAME:-ams}"
DRILL_TIMEOUT="${DRILL_TIMEOUT:-180}"
DRILL_KEY_TABLES="${DRILL_KEY_TABLES:-sys_users _ams_migrations}"
GSQL=/usr/local/opengauss/bin/gsql

if ! [[ "$DRILL_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$DRILL_TIMEOUT" -lt 1 ]; then
  echo "[ERROR] DRILL_TIMEOUT 必须是 >=1 的整数，当前为：$DRILL_TIMEOUT" >&2
  exit 1
fi

# dry-run 不生成、也不输出真实口令；非 dry-run 用独立临时随机值（不复用生产口令）。
if [ "$DRY_RUN" -eq 1 ]; then
  DRILL_DB_PASSWORD='<DRILL_DB_PASSWORD>'
elif [ -z "${DRILL_DB_PASSWORD:-}" ]; then
  if command -v openssl >/dev/null 2>&1; then
    DRILL_DB_PASSWORD="Dr1ll_$(openssl rand -hex 12)"
  else
    DRILL_DB_PASSWORD="Dr1ll_$(date +%s)_$$_9a"
  fi
fi

# 容器内 gsql 直连本机；口令按 backup.sh / restore.sh 的写法嵌入 conninfo 位置参数。
CONN="host=127.0.0.1 port=5432 user=${DRILL_DB_USER} password=${DRILL_DB_PASSWORD} dbname=${DRILL_DB_NAME}"

# 独立资源名：带时间戳，避免与生产容器 / 网络重名。
TS="$(date +%Y%m%d-%H%M%S)"
CNAME="ams_restore_drill_${TS}"
NETNAME="ams_drill_net_${TS}"

cleanup() {
  # 无论成功失败都清理临时容器 / 网络；--rm 已保证容器移除，这里显式兜底。
  if [ "$DRY_RUN" -eq 0 ]; then
    docker rm -f "$CNAME" >/dev/null 2>&1 || true
    docker network rm "$NETNAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# dry-run 下把「将执行的命令」打印到 stderr，避免被命令替换误当成校验结果。
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '+' >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    return 0
  fi
  "$@"
}

# 执行一条只读校验 SQL；dry-run 下只打印命令，返回空结果（不做判定）。
drill_sql() {
  local sql="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    run docker exec -e "LD_LIBRARY_PATH=/usr/local/opengauss/lib" "$CNAME" \
      "$GSQL" "$CONN" -At -c "$sql"
    printf ''
  else
    docker exec -e "LD_LIBRARY_PATH=/usr/local/opengauss/lib" "$CNAME" \
      "$GSQL" "$CONN" -At -c "$sql"
  fi
}

# ---- 备份文件（宿主机只读；不触碰生产容器）----
if [ ! -f "$BACKUP_FILE" ]; then
  echo "[ERROR] 找不到备份文件：$BACKUP_FILE" >&2
  exit 1
fi
BACKUP_ABS="$(cd "$(dirname "$BACKUP_FILE")" && pwd)/$(basename "$BACKUP_FILE")"
SUM_ABS="${BACKUP_ABS}.sha256"
if [ -f "$SUM_ABS" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "+ (cd '$(dirname "$BACKUP_ABS")' && sha256sum -c '$(basename "$SUM_ABS")')" >&2
  else
    echo "  sha256 校验中 ..."
    if ! ( cd "$(dirname "$BACKUP_ABS")" && sha256sum -c "$(basename "$SUM_ABS")" ); then
      echo "[ERROR] sha256 校验失败，已中止演练（未创建任何临时资源）。" >&2
      exit 1
    fi
    echo "  sha256 校验通过。"
  fi
else
  echo "  [WARN] 未找到 ${SUM_ABS}，跳过校验（建议补齐后再演练）"
fi

echo "=== AMS 恢复演练（独立临时实例，绝不碰生产数据）==="
echo "  备份     : $BACKUP_ABS"
echo "  镜像     : $DRILL_IMAGE"
echo "  临时容器 : $CNAME （--rm，独立网络 $NETNAME）"
echo "  目标库   : $DRILL_DB_NAME / 用户 $DRILL_DB_USER"
echo "  超时     : ${DRILL_TIMEOUT}s"
echo "  模式     : $( [ "$DRY_RUN" -eq 1 ] && echo 'DRY-RUN（仅打印命令）' || echo '实际执行' )"
echo ""

# ---- 创建独立网络与临时容器 ----
# --privileged 与 deploy/compose/docker-compose.yml 的 db 服务一致
# （openGauss MOT 的 NUMA 绑核需要）；若所用镜像无需 MOT，可去掉本行。
run docker network create "$NETNAME"
run docker run -d --rm --name "$CNAME" --network "$NETNAME" --privileged \
  -e "GS_PASSWORD=$DRILL_DB_PASSWORD" \
  -e "GS_USERNAME=$DRILL_DB_USER" \
  -e "GS_DBNAME=$DRILL_DB_NAME" \
  -e "LD_LIBRARY_PATH=/usr/local/opengauss/lib" \
  -v "${BACKUP_ABS}:/drill/backup.sql:ro" \
  "$DRILL_IMAGE"

# ---- 等待临时实例就绪（带超时）----
if [ "$DRY_RUN" -eq 1 ]; then
  run docker exec -e "LD_LIBRARY_PATH=/usr/local/opengauss/lib" "$CNAME" \
    "$GSQL" "$CONN" -At -c "SELECT 1;"
  echo "+ (循环等待临时实例就绪，最多 ${DRILL_TIMEOUT}s，每 3s 重试)" >&2
else
  echo "  等待临时实例就绪（最多 ${DRILL_TIMEOUT}s）..."
  deadline=$((SECONDS + DRILL_TIMEOUT))
  ready=0
  while [ "$SECONDS" -lt "$deadline" ]; do
    if docker exec -e "LD_LIBRARY_PATH=/usr/local/opengauss/lib" "$CNAME" \
        "$GSQL" "$CONN" -At -c "SELECT 1;" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 3
  done
  if [ "$ready" -ne 1 ]; then
    echo "[ERROR] 临时实例在 ${DRILL_TIMEOUT}s 内未就绪，演练失败（临时资源将被清理）。" >&2
    exit 1
  fi
  echo "  临时实例已就绪。"
fi

# ---- 导入备份到临时库（只读挂载，带超时；失败即由 set -e 触发清理）----
# 与 restore.sh 一致：-v ON_ERROR_STOP=1 -q -f；dump 带 --clean --if-exists。
run timeout "$DRILL_TIMEOUT" docker exec \
  -e "LD_LIBRARY_PATH=/usr/local/opengauss/lib" "$CNAME" \
  "$GSQL" "$CONN" -v ON_ERROR_STOP=1 -q -f /drill/backup.sql

# ---- 校验 SQL（只读）----
TABLES_CNT="$(drill_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';")"
USERS_CNT="$(drill_sql "SELECT count(*) FROM sys_users;")"
declare -a KEY_HITS=()
for t in $DRILL_KEY_TABLES; do
  KEY_HITS+=("$(drill_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='$t';")")
done

# ---- dry-run 收尾：只打印，不做判定、不创建 / 删除任何资源 ----
if [ "$DRY_RUN" -eq 1 ]; then
  echo "+ (验收判定：public 表数 > 0、sys_users 可查询、关键表全部存在)" >&2
  run docker rm -f "$CNAME"
  run docker network rm "$NETNAME"
  echo "=== --dry-run 完成：以上为将执行的命令；未创建 / 删除任何资源，未接触生产数据 ==="
  exit 0
fi

# ---- 输出结果与验收结论（仅非 dry-run）----
echo ""
echo "=== 恢复演练校验结果（临时实例，非生产）==="
echo "  public 表数量 : ${TABLES_CNT:-<无输出>}"
echo "  sys_users 行数 : ${USERS_CNT:-<无输出>}"
i=0
for t in $DRILL_KEY_TABLES; do
  echo "  关键表 ${t} : ${KEY_HITS[$i]:-<无输出>} (期望 1=存在)"
  i=$((i + 1))
done
echo ""

FAIL=0
if ! [[ "${TABLES_CNT:-}" =~ ^[0-9]+$ ]] || [ "${TABLES_CNT:-0}" -le 0 ]; then
  echo "  [FAIL] public 表数量为 0 或非数字"
  FAIL=1
fi
if ! [[ "${USERS_CNT:-}" =~ ^[0-9]+$ ]]; then
  echo "  [FAIL] sys_users 查询失败（表可能不存在或导入不完整）"
  FAIL=1
fi
i=0
for t in $DRILL_KEY_TABLES; do
  if [ "${KEY_HITS[$i]:-0}" != "1" ]; then
    echo "  [FAIL] 关键表缺失：$t"
    FAIL=1
  fi
  i=$((i + 1))
done

echo "=== 演练结论：$([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL) ==="
echo "  临时容器 / 网络将在脚本退出时清理（trap EXIT）。"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi

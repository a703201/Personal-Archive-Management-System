#!/bin/bash
# ============================================================
# AMS · 备份异地副本（脚本已提供，但默认未启用，需运维配置后端）
#
# 从挂载 ams-backups 卷的 db 容器取出最新（或指定）逻辑备份，
# 先在宿主机用 sha256sum -c 校验通过，再复制到可配置的异地后端：
#   ① rclone：设置 RCLONE_REMOTE（remote:path）
#   ② ssh  ：设置 OFFSITE_HOST 与 OFFSITE_PATH（scp / rsync）
# 两者都没设置 → 打印清晰指引并退出 1，绝不静默成功。
#
# [!!] 本脚本不硬编码任何主机 / 账号 / 口令 / 密钥；
#      rclone 走 rclone.conf，ssh/scp/rsync 走运维自己的 ssh config / agent。
# [!!] 仓库只提供脚本，未配置定时调度（见 crontab.example /
#      deploy/systemd/ams-backup.timer），也不会默认启用。
# [!!] rclone / rsync / scp / ssh 命令均为通用可配置写法，
#      未针对特定远端或版本调参；运维首次启用请按实际后端核对。
#
# 用法：
#   set -a; source deploy/compose/.env; set +a
#   RCLONE_REMOTE="gdrive:ams-backups" bash deploy/scripts/backup-offsite.sh
#   OFFSITE_HOST="backup.example.com" OFFSITE_PATH="/srv/ams/backups" \
#     bash deploy/scripts/backup-offsite.sh
#   AMS_BACKUP_FILE=ams-20261107-120000.sql \
#     OFFSITE_HOST=backup.example.com OFFSITE_PATH=/srv/ams/backups \
#     bash deploy/scripts/backup-offsite.sh
#
# 环境变量（全部可选 / 按需）：
#   AMS_DB_CONTAINER   db 容器名（默认 ams_opengauss，该容器挂载 ams-backups 卷）
#   AMS_BACKUP_DIR     容器内备份目录（默认 /app/data-backups）
#   AMS_BACKUP_FILE    指定备份文件名；不设则取目录内最新 ams-*.sql
#   RCLONE_REMOTE      rclone 目标（如 remote:path）；设置即启用 rclone 后端
#   OFFSITE_HOST       远端主机（ssh 可达，凭据由 ssh config / agent 提供）
#   OFFSITE_PATH       远端目录（绝对路径）
#   OFFSITE_METHOD     ssh 后端用 rsync 还是 scp（默认 rsync；无 rsync 时回退 scp）
#   OFFSITE_RSYNC_SSH  rsync -e 的 ssh 命令（可选，默认 ssh）
#   OFFSITE_KEEP       异地保留最近几份（默认 7）；超出按文件名倒序删除
#                      .sql 及配套 .sha256
#
# 产物：校验通过的 .sql 与 .sha256 复制到后端，并打印产物清单。
# ============================================================
set -euo pipefail

CONTAINER="${AMS_DB_CONTAINER:-ams_opengauss}"
BACKUP_DIR="${AMS_BACKUP_DIR:-/app/data-backups}"
KEEP="${OFFSITE_KEEP:-7}"
RSYNC_SSH="${OFFSITE_RSYNC_SSH:-ssh}"
METHOD="${OFFSITE_METHOD:-rsync}"

# ---- 后端选择：都没设置则给出指引并退出 ----
RCLONE_REMOTE="${RCLONE_REMOTE:-}"
OFFSITE_HOST="${OFFSITE_HOST:-}"
OFFSITE_PATH="${OFFSITE_PATH:-}"
BACKEND=""
if [ -n "$RCLONE_REMOTE" ]; then
  BACKEND="rclone"
elif [ -n "$OFFSITE_HOST" ] && [ -n "$OFFSITE_PATH" ]; then
  BACKEND="ssh"
elif [ -n "$OFFSITE_HOST" ] || [ -n "$OFFSITE_PATH" ]; then
  echo "[ERROR] OFFSITE_HOST 与 OFFSITE_PATH 必须同时设置（当前只设了其中一个）。" >&2
  exit 1
else
  echo "[ERROR] 未配置任何异地后端，已中止（绝不静默成功）。" >&2
  echo "" >&2
  echo "请二选一后重跑：" >&2
  echo "  ① rclone：export RCLONE_REMOTE=\"<remote>:<path>\"   # 凭据写在 rclone.conf" >&2
  echo "  ② ssh  ：export OFFSITE_HOST=\"<host>\" OFFSITE_PATH=\"<abs-dir>\"  # 走 ssh config/agent" >&2
  echo "示例：" >&2
  echo "  RCLONE_REMOTE=\"gdrive:ams-backups\" bash deploy/scripts/backup-offsite.sh" >&2
  echo "  OFFSITE_HOST=backup.example.com OFFSITE_PATH=/srv/ams/backups \\" >&2
  echo "    bash deploy/scripts/backup-offsite.sh" >&2
  echo "" >&2
  echo "定时启用见 deploy/scripts/crontab.example 与 deploy/systemd/ams-backup.timer（默认未启用）。" >&2
  exit 1
fi

if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || [ "$KEEP" -lt 1 ]; then
  echo "[ERROR] OFFSITE_KEEP 必须是 >=1 的整数，当前为：$KEEP" >&2
  exit 1
fi
if [[ "$BACKUP_DIR" != /* ]]; then
  echo "[ERROR] AMS_BACKUP_DIR 必须是容器内绝对路径，当前为：$BACKUP_DIR" >&2
  exit 1
fi
if [ "$BACKEND" = ssh ] && [[ "$OFFSITE_PATH" != /* ]]; then
  echo "[ERROR] OFFSITE_PATH 必须是远端绝对路径，当前为：$OFFSITE_PATH" >&2
  exit 1
fi

# 工具存在性检查（只检查命令是否可用，不代表凭据已配置）
if [ "$BACKEND" = rclone ]; then
  command -v rclone >/dev/null 2>&1 || { echo "[ERROR] 未找到 rclone，请先安装并配置 rclone.conf" >&2; exit 1; }
else
  command -v ssh >/dev/null 2>&1 || { echo "[ERROR] 未找到 ssh" >&2; exit 1; }
  if [ "$METHOD" = rsync ]; then
    command -v rsync >/dev/null 2>&1 || { echo "[WARN] 未找到 rsync，改用 scp" >&2; METHOD=scp; }
  fi
  command -v scp >/dev/null 2>&1 || { echo "[ERROR] 未找到 scp" >&2; exit 1; }
fi

# 只读检查 db 容器（该容器挂载 ams-backups 卷）；不向容器写入任何东西
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "[ERROR] 容器 $CONTAINER 未运行，无法从 ams-backups 卷取备份。" >&2
  echo "        先执行：bash deploy/scripts/run-app.sh" >&2
  exit 1
fi

# ---- 选定备份文件：指定则用之，否则取目录内最新 ams-*.sql ----
if [ -n "${AMS_BACKUP_FILE:-}" ]; then
  NAME="$AMS_BACKUP_FILE"
  if ! docker exec "$CONTAINER" test -f "${BACKUP_DIR}/${NAME}"; then
    echo "[ERROR] 容器内找不到备份：${BACKUP_DIR}/${NAME}" >&2
    exit 1
  fi
else
  NAME="$(docker exec "$CONTAINER" bash -lc \
    "cd '$BACKUP_DIR' 2>/dev/null && ls -1t ams-*.sql 2>/dev/null | head -n 1" || true)"
  if [ -z "$NAME" ]; then
    echo "[ERROR] ${BACKUP_DIR} 内没有 ams-*.sql 备份，请先执行 bash deploy/scripts/backup.sh" >&2
    exit 1
  fi
fi
# 文件名形态校验：既贴合 backup.sh 命名，也避免路径穿越 / 注入
if ! [[ "$NAME" =~ ^ams-[0-9]{8}-[0-9]{6}\.sql$ ]]; then
  echo "[ERROR] 备份文件名不符合 ams-YYYYmmdd-HHMMSS.sql 规范：$NAME" >&2
  exit 1
fi
SUM_NAME="${NAME}.sha256"

echo "=== AMS 备份异地副本 ==="
echo "  来源容器 : $CONTAINER （挂载 ams-backups 卷）"
echo "  备份文件 : ${BACKUP_DIR}/${NAME}"
echo "  后端     : $BACKEND"
if [ "$BACKEND" = rclone ]; then
  echo "  目标     : ${RCLONE_REMOTE}/${NAME}"
else
  echo "  传输方式 : $METHOD"
  echo "  目标     : ${OFFSITE_HOST}:${OFFSITE_PATH}/${NAME}"
fi
echo "  异地保留 : OFFSITE_KEEP=$KEEP"
echo ""

# ---- 宿主机暂存目录：只用于 sha256 校验与作为上传源，结束即清理 ----
STAGE="$(mktemp -d)"
cleanup_stage() { rm -rf -- "$STAGE"; }
trap cleanup_stage EXIT

docker cp "${CONTAINER}:${BACKUP_DIR}/${NAME}" "${STAGE}/${NAME}"
if docker exec "$CONTAINER" test -f "${BACKUP_DIR}/${SUM_NAME}"; then
  docker cp "${CONTAINER}:${BACKUP_DIR}/${SUM_NAME}" "${STAGE}/${SUM_NAME}"
else
  echo "[ERROR] 缺少校验文件 ${BACKUP_DIR}/${SUM_NAME}，拒绝复制（先校验是硬性要求）。" >&2
  exit 1
fi

# ---- 先校验，通过才允许复制 ----
echo "  sha256 校验中 ..."
if ! ( cd "$STAGE" && sha256sum -c "$SUM_NAME" ); then
  echo "[ERROR] sha256 校验失败，未复制任何文件到异地。" >&2
  exit 1
fi
echo "  sha256 校验通过。"

# ---- 复制到异地后端 ----
if [ "$BACKEND" = rclone ]; then
  # 通用写法：copyto 保留文件名；具体 flag 按所用 rclone 版本 / 远端核对。
  rclone copyto "${STAGE}/${NAME}" "${RCLONE_REMOTE}/${NAME}"
  rclone copyto "${STAGE}/${SUM_NAME}" "${RCLONE_REMOTE}/${SUM_NAME}"
else
  if [ "$METHOD" = rsync ]; then
    # 通用写法：-a 归档；远端目录需事先存在；账号/凭据由 ssh config / agent 提供。
    rsync -a -e "$RSYNC_SSH" "${STAGE}/${NAME}" "${STAGE}/${SUM_NAME}" \
      "${OFFSITE_HOST}:${OFFSITE_PATH}/"
  else
    scp "${STAGE}/${NAME}" "${STAGE}/${SUM_NAME}" \
      "${OFFSITE_HOST}:${OFFSITE_PATH}/"
  fi
fi

# ---- OFFSITE_KEEP：远端按文件名倒序（时间戳命名即时间序）保留最近 KEEP 份 ----
# 只删本脚本产出的 ams-*.sql 及配套 .sha256，不触碰远端其它文件。
if [ "$BACKEND" = rclone ]; then
  mapfile -t REMOTE_SQLS < <(rclone lsf "$RCLONE_REMOTE" --files-only 2>/dev/null \
    | grep -E '^ams-[0-9]{8}-[0-9]{6}\.sql$' | sort -r || true)
  if [ "${#REMOTE_SQLS[@]}" -gt "$KEEP" ]; then
    for old in "${REMOTE_SQLS[@]:KEEP}"; do
      rclone deletefile "${RCLONE_REMOTE}/${old}" || true
      rclone deletefile "${RCLONE_REMOTE}/${old}.sha256" || true
      echo "  异地清理旧备份：$old"
    done
  fi
else
  mapfile -t REMOTE_SQLS < <(ssh "$OFFSITE_HOST" \
    "ls -1 '${OFFSITE_PATH}' 2>/dev/null | grep -E '^ams-[0-9]{8}-[0-9]{6}\.sql$' | sort -r" || true)
  if [ "${#REMOTE_SQLS[@]}" -gt "$KEEP" ]; then
    for old in "${REMOTE_SQLS[@]:KEEP}"; do
      ssh "$OFFSITE_HOST" "rm -f -- '${OFFSITE_PATH}/${old}' '${OFFSITE_PATH}/${old}.sha256'" || true
      echo "  异地清理旧备份：$old"
    done
  fi
fi

# ---- 产物清单 ----
echo ""
echo "=== 异地副本产物清单 ==="
echo "  SQL    : ${NAME}"
echo "  校验   : ${SUM_NAME}"
echo "  sha256 : $(cd "$STAGE" && sha256sum "$NAME" | cut -d' ' -f1)"
if [ "$BACKEND" = rclone ]; then
  echo "  远端   : ${RCLONE_REMOTE}/${NAME}"
  echo "           ${RCLONE_REMOTE}/${SUM_NAME}"
else
  echo "  远端   : ${OFFSITE_HOST}:${OFFSITE_PATH}/${NAME}"
  echo "           ${OFFSITE_HOST}:${OFFSITE_PATH}/${SUM_NAME}"
fi
echo "  保留   : 最近 $KEEP 份（OFFSITE_KEEP）"
echo ""
echo "  提示：首次使用请人工核对远端确实收到文件；"
echo "        备份可用性用 deploy/scripts/restore-drill.sh 定期演练验证。"

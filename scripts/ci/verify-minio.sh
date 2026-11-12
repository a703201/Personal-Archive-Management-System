#!/usr/bin/env bash
# ============================================================
# AMS · MinIO 端到端验证（Q2 对象存储连通性）
#
# 流程：检查 Docker → 起 compose 的 --profile s3 MinIO → 等待就绪
#       → AMS_IT_MINIO=1 bash scripts/test.sh ams-storage
#       → 输出结果 → 清理容器（保留 ams-minio-data 数据卷）。
#
# 约定来源（已核对真实文件，勿凭记忆改）：
#   · deploy/compose/docker-compose.yml：minio 服务 profiles:["s3"]，
#     container_name ams_minio，端口 9000(API) / 9001(console)，
#     数据卷 ams-minio-data；默认凭据 ams-dev-minio /
#     dev-only-minio-change-me。
#   · packages/ams-storage/tests/storage/s3_integration_test.cj：
#     AMS_IT_MINIO=1 + 127.0.0.1:9000，默认凭据 minioadmin / minioadmin，
#     可用 AMS_IT_MINIO_ENDPOINT / REGION / ROOT_USER / ROOT_PASSWORD 覆盖。
#
# ⚠️ 两处默认凭据不一致：compose 是 ams-dev-minio / dev-only-minio-change-me，
#    集成测试是 minioadmin / minioadmin。若不对齐，测试连上 MinIO 但 SigV4
#    签名会被 403 拒绝（失败关闭）。故本脚本显式把两边统一到 minioadmin/minioadmin。
#
# ⚠️ compose 里有三个 :? 必填变量（AMS_DB_PASSWORD / AMS_TOKEN_SECRET / AMS_KEK），
#    只起 minio 服务时整份文件仍会被插值。故给占位值；它们只服务于 db/ams，
#    本脚本不启动这些服务，占位值不会被实际使用。
#
# 只起 minio 服务而非整栈（等价的 --profile s3 up -d minio）：整栈会拉起
# db/init/ams 并需要真实 DB 凭据与镜像，与「只验证对象存储连通性」无关。
#
# 本脚本不搬运任何业务附件，也不删除数据卷。
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

COMPOSE="$ROOT/deploy/compose/docker-compose.yml"
PROJECT="ams"
SERVICE="minio"
API_PORT=9000
HEALTH_URL="http://127.0.0.1:${API_PORT}/minio/health/live"
MAX_WAIT=60          # 每次 sleep 2s，最长约 120s
SLEEP_SEC=2

echo "============================================================"
echo " AMS · MinIO 端到端验证（Q2 对象存储连通性）"
echo "============================================================"

# ---- 1) Docker 可用性（不可用必须明确失败，不假装通过）----
if ! command -v docker >/dev/null 2>&1; then
  echo "[ERROR] 未找到 docker 命令，无法启动 MinIO 做端到端验证。"
  echo "        请先安装 Docker Desktop / Docker Engine 并重新执行本脚本。"
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "[ERROR] Docker daemon 当前不可用（无法连接 Docker 引擎）。"
  echo "        Windows 上常见为 npipe:////./pipe/dockerDesktopLinuxEngine 连不上："
  echo "        请启动 Docker Desktop 并等其状态变为 running 后重试。"
  echo "        本脚本不会在未验证数据的情况下报成功。"
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "[ERROR] 未检测到 'docker compose' 子命令（需要 Compose V2）。"
  exit 1
fi
echo "[OK]   Docker 可用；compose 项目=$PROJECT 服务=$SERVICE"

# ---- 2) 环境变量对齐（凭据 + compose 的 :? 占位）----
# 统一 compose 与集成测试的凭据到 minioadmin/minioadmin；允许外部同名变量覆盖。
export MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
export MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin}"
export AMS_IT_MINIO_ROOT_USER="${AMS_IT_MINIO_ROOT_USER:-$MINIO_ROOT_USER}"
export AMS_IT_MINIO_ROOT_PASSWORD="${AMS_IT_MINIO_ROOT_PASSWORD:-$MINIO_ROOT_PASSWORD}"
export AMS_IT_MINIO_ENDPOINT="${AMS_IT_MINIO_ENDPOINT:-http://127.0.0.1:${API_PORT}}"
export AMS_IT_MINIO_REGION="${AMS_IT_MINIO_REGION:-us-east-1}"
# 三个 :? 必填变量：只起 minio，占位值不会被任何服务使用；若外部已设则不覆盖。
export AMS_DB_PASSWORD="${AMS_DB_PASSWORD:-verify-minio-placeholder}"
export AMS_TOKEN_SECRET="${AMS_TOKEN_SECRET:-verify-minio-placeholder-token-secret}"
export AMS_KEK="${AMS_KEK:-verify-minio-placeholder-kek}"

COMPOSE_CMD=(docker compose -p "$PROJECT" -f "$COMPOSE" --profile s3)

# ---- 3) 清理函数：只清理 minio 容器，保留数据卷 ----
# 放在 Docker 检查通过之后，避免 daemon 不可用时多余地调用 docker。
cleanup() {
  "${COMPOSE_CMD[@]}" stop "$SERVICE" >/dev/null 2>&1 || true
  "${COMPOSE_CMD[@]}" rm -f "$SERVICE" >/dev/null 2>&1 || true
  echo "[INFO] 已停止并移除 ams_minio 容器；数据卷 ams-minio-data 保留（未删除）。"
}
trap cleanup EXIT

# ---- 4) 起 MinIO（只起 minio 服务，不拉整栈）----
echo "[INFO] 启动 MinIO：docker compose -p $PROJECT --profile s3 up -d $SERVICE"
"${COMPOSE_CMD[@]}" up -d "$SERVICE"

# ---- 5) 等待就绪 ----
ready() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 2 "$HEALTH_URL" >/dev/null 2>&1
  else
    (echo > "/dev/tcp/127.0.0.1/${API_PORT}") >/dev/null 2>&1
  fi
}
echo "[INFO] 等待 MinIO 就绪（$HEALTH_URL，最多 $((MAX_WAIT * SLEEP_SEC))s）..."
i=0
while [ "$i" -lt "$MAX_WAIT" ]; do
  if ready; then
    echo "[OK]   MinIO 已就绪。"
    break
  fi
  i=$((i + 1))
  sleep "$SLEEP_SEC"
done
if ! ready; then
  echo "[ERROR] MinIO 在 $((MAX_WAIT * SLEEP_SEC))s 内未就绪，放弃验证（不报成功）。"
  echo "        可检查：docker logs ams_minio"
  exit 1
fi

# ---- 6) 跑集成测试 ----
echo "============================================================"
echo " 执行：AMS_IT_MINIO=1 bash scripts/test.sh ams-storage"
echo "============================================================"
set +e
AMS_IT_MINIO=1 bash "$ROOT/scripts/test.sh" ams-storage
TEST_EXIT=$?
set -e

# ---- 7) 输出结果（cleanup 由 trap 在退出时执行）----
echo "============================================================"
echo " 结果：test.sh 退出码 TEST_EXIT=$TEST_EXIT"
if [ "$TEST_EXIT" -eq 0 ]; then
  echo " [PASS] ams-storage 全部用例无失败（含 S3IntegrationTest 真实 MinIO 往返）。"
else
  echo " [FAIL] ams-storage 存在失败用例，详见上方 test.sh 输出。"
fi
echo " 说明：该退出码来自 scripts/test.sh；容器由 trap 清理，数据卷保留。"
echo "============================================================"
exit "$TEST_EXIT"

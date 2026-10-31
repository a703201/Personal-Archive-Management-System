#!/bin/bash
# ============================================================
# AMS · 一键启动（统一栈，对应 ReturnGuard 的 `returnguard` 组）
#
# 不再像以前那样「单独起 ams_opengauss + 单独起 ams-server」——那样在
# 容器管理界面里是两个平级独立容器。本脚本用一条 compose 命令把
# 数据库 / 迁移 / 应用三类容器归到同一个项目（默认 ams）下，界面上
# 显示为单个「ams」分组（内含 ams_opengauss / ams_db_init / ams-server），
# 与 returnguard 分组（rg_opengaus / rg_realdb_init / rg_app）对齐。
#
# ⚠️ 前提（只需在源码变更后重跑）：
#   bash deploy/scripts/build-linux-docker.sh   # 产出 build/linux/ 与 web/dist/
#   该脚本会经由 Dockerfile.prebuilt 自动构建 ams:0.1.0（若镜像已存在则不重建）。
#
# 用法：
#   bash deploy/scripts/run-app.sh
#   AMS_DB_PASSWORD='...' AMS_TOKEN_SECRET='...' bash deploy/scripts/run-app.sh
#   bash deploy/scripts/run-app.sh --build     # 强制重建应用镜像
#
# 数据保护：数据库数据在命名卷 ams_ogdata（external），重建容器不丢数据。
#           迁移脚本幂等（检测到 sys_users 即跳过）。
#
# 已知陷阱（已在本脚本规避）：
#   - 仓颉运行时只认 IP 字面量，compose 已给 db 分配静态 IP 172.28.0.10。
#   - 若在 Git Bash 里跑，compose 文件内的 /migrations 挂载不受 MSYS 影响
#     （仅命令行 `-e /app/web` 才需 MSYS_NO_PATHCONV，本脚本不触发）。
# ============================================================
set -uo pipefail

COMPOSE_FILE="$(cd "$(dirname "$0")/.." && pwd)/compose/docker-compose.yml"
PROJECT="${AMS_COMPOSE_PROJECT:-ams}"
BUILD_FLAG=""
for a in "$@"; do
  case "$a" in
    --build) BUILD_FLAG="--build" ;;
  esac
done

echo "=== AMS 统一栈启动（project=$PROJECT）==="
# 停止并移除「旧的独立容器」（若你之前用 run-app.sh 旧版本或手动起过），
# 数据卷 ams_ogdata 不受影响。compose 接管后会用同名容器复用该卷。
for c in ams-server ams_opengauss; do
  if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
    echo "  移除旧独立容器 $c（数据卷保留）"
    docker rm -f "$c" >/dev/null 2>&1 || true
  fi
done
# 清理旧版 ams-net（172.19.0.0/16），避免与新 ams-net（172.28.0.0/16）冲突
if docker network ls --format '{{.Name}}' | grep -qx ams-net; then
  # 仅在无容器依赖时才删除（compose 会重建自己的 ams-net）
  if [ -z "$(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' ams-net 2>/dev/null | tr -d ' ')" ]; then
    docker network rm ams-net >/dev/null 2>&1 || true
  fi
fi

# 起整个栈（db + init + ams）
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d $BUILD_FLAG

# 等待健康检查
echo "=== 等待健康检查（/api/health）==="
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8080/api/health" 2>/dev/null)
  if [ "$code" = "200" ]; then
    echo "health OK (HTTP 200) after ${i}s"
    break
  fi
  sleep 1
done

echo ""
echo "访问："
echo "  SPA      http://localhost:8080/"
echo "  健康检查 http://localhost:8080/api/health"
echo "分组（容器管理界面）：project=$PROJECT"
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E "ams_opengauss|ams_db_init|ams-server" || true

#!/usr/bin/env bash
# ============================================================
# AMS · S3 兼容端点端到端验证（免 Docker，用 moto 替代 MinIO）
#
# 适用场景：无法拉取 minio/minio 镜像（镜像节点繁忙）或无法重启
#           Docker / 没有 WSL 的环境。moto 是 S3 兼容 mock 服务器
#           （真实 HTTP + 真实 SigV4 签名校验），等价于 MinIO 验证
#           的实质：证明 HttpS3Transport 的 SigV4 签名 + HTTP/1.1
#           客户端 + 响应解析对真实 S3 端点真实可用。
#
# 流程：检查 python3 → 建 venv 装 moto[server]（已装则跳过）→
#       起 moto_server:9000 → 等待就绪 →
#       AMS_IT_MINIO=1 bash scripts/test.sh ams-storage → 清理 moto。
#
# 与 verify-minio.sh 的区别：verify-minio.sh 起真实 MinIO 容器；
#       本脚本用 moto（无需 Docker 镜像 / 无需重启 Docker）。
#       两者验证的实质一致：SigV4 + HTTP 客户端 + 响应解析真实可用。
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

API_PORT=9000
VENV="$ROOT/.tmp/venv-moto"
MOTO_LOG="$ROOT/.tmp/moto.log"

if ! command -v python3 >/dev/null 2>&1; then
  echo "[ERROR] 未找到 python3，无法用 moto 起 S3 端点。" >&2
  exit 1
fi

# ---- 端口占用检查（不强行 kill 既有服务）----
if command -v curl >/dev/null 2>&1; then
  if curl -fsS --max-time 2 "http://127.0.0.1:${API_PORT}/" >/dev/null 2>&1; then
    echo "[ERROR] 127.0.0.1:${API_PORT} 已被占用（可能已有 MinIO / moto）。请先释放后再跑。" >&2
    exit 1
  fi
fi

# ---- 准备 venv + moto ----
# 跨平台：Windows 原生 venv 是 Scripts/python.exe（activate 无 +x 位，不能用 -x 判断）；
# Linux/macOS 是 bin/python。统一用「venv 内 python 的绝对路径 + -m」调用，
# 不 source activate（避免 activate 脚本差异与 PATH 污染）。
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8
if [ -f "$VENV/Scripts/python.exe" ]; then
  VPY="$VENV/Scripts/python.exe"
elif [ -f "$VENV/bin/python" ]; then
  VPY="$VENV/bin/python"
else
  echo "[INFO] 创建 venv：$VENV"
  python3 -m venv "$VENV"
  if [ -f "$VENV/Scripts/python.exe" ]; then
    VPY="$VENV/Scripts/python.exe"
  else
    VPY="$VENV/bin/python"
  fi
fi
if ! "$VPY" -c "import moto" >/dev/null 2>&1; then
  echo "[INFO] 安装 moto[server]（首次需联网拉取 PyPI）..."
  "$VPY" -m pip install --quiet --disable-pip-version-check "moto[server]"
fi
echo "[OK]   moto 就绪：$("$VPY" -c 'import moto; print(moto.__version__)')"

# ---- 起 moto server（trap 清理）----
MOTO_PID=""
cleanup() {
  if [ -n "${MOTO_PID:-}" ] && kill -0 "$MOTO_PID" 2>/dev/null; then
    kill "$MOTO_PID" 2>/dev/null || true
    wait "$MOTO_PID" 2>/dev/null || true
    echo "[INFO] 已停止 moto_server (PID=$MOTO_PID)。"
  fi
}
trap cleanup EXIT

export AWS_ACCESS_KEY_ID=minioadmin AWS_SECRET_ACCESS_KEY=minioadmin AWS_DEFAULT_REGION=us-east-1
# 与上面一致：不依赖 activate 后的 PATH，直接用 venv 内的绝对入口。
# Windows venv 为 Scripts/moto_server.exe；Linux/macOS 为 bin/moto_server。
if [ -f "$VENV/Scripts/moto_server.exe" ]; then
  MOTO_BIN="$VENV/Scripts/moto_server.exe"
elif [ -f "$VENV/bin/moto_server" ]; then
  MOTO_BIN="$VENV/bin/moto_server"
else
  echo "[ERROR] 未在 venv 中找到 moto_server 入口（Scripts/ 或 bin/）。" >&2
  exit 1
fi
"$MOTO_BIN" -p "$API_PORT" -H 0.0.0.0 > "$MOTO_LOG" 2>&1 &
MOTO_PID=$!
echo "[INFO] moto_server 已启动 (PID=$MOTO_PID, bin=$MOTO_BIN)，等待就绪..."

ready() {
  curl -fsS --max-time 2 "http://127.0.0.1:${API_PORT}/" >/dev/null 2>&1
}
i=0
while [ "$i" -lt 30 ]; do
  if ready; then echo "[OK]   moto S3 端点就绪。"; break; fi
  i=$((i + 1)); sleep 1
done
if ! ready; then
  echo "[ERROR] moto 在 30s 内未就绪，日志：" >&2; tail -20 "$MOTO_LOG" >&2
  exit 1
fi

# ---- 跑集成测试 ----
echo "============================================================"
echo " 执行：AMS_IT_MINIO=1 bash scripts/test.sh ams-storage"
echo "============================================================"
set +e
AMS_IT_MINIO=1 \
AMS_IT_MINIO_ENDPOINT="http://127.0.0.1:${API_PORT}" \
AMS_IT_MINIO_REGION=us-east-1 \
AMS_IT_MINIO_ROOT_USER=minioadmin \
AMS_IT_MINIO_ROOT_PASSWORD=minioadmin \
bash "$ROOT/scripts/test.sh" ams-storage
TEST_EXIT=$?
set -e

echo "============================================================"
echo " 结果：test.sh 退出码 TEST_EXIT=$TEST_EXIT"
if [ "$TEST_EXIT" -eq 0 ]; then
  echo " [PASS] ams-storage 全部用例无失败（含 S3IntegrationTest 经 moto 真实 S3 往返）。"
else
  echo " [FAIL] 存在失败用例，详见上方 test.sh 输出（moto 日志：$MOTO_LOG）。"
fi
echo "============================================================"
exit "$TEST_EXIT"

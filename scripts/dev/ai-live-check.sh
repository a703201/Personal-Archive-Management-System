#!/bin/bash
# ============================================================
# AMS · AI 接口真连冒烟（docs/20 §11 / 9 条 AI API）
#
# 用途：Ollama（或在线 provider）就绪 + AMS 配置完成后，验证 9 条 AI 接口
#       的「可达 / 鉴权 / 契约」三层，不写数据库、不改配置、不上传档案内容。
#
# 分层判定（关键）：
#   [可达] 路由存在且鉴权正确 —— 与模型是否可用无关，必须全绿
#   [降级] 模型未配置/未起时，AI 接口应返回明确的降级/不可用，而不是 500 崩溃
#   [真推理] 仅当 provider 就绪时才有意义；本脚本不强制要求
#
# 用法：
#   AMS_BASE=http://127.0.0.1:8080 AMS_USER=admin AMS_PASS=xxx \
#     bash scripts/dev/ai-live-check.sh
#   也可直接传现成令牌：AMS_TOKEN=xxx bash scripts/dev/ai-live-check.sh
#
# 退出码：0=可达层全绿 / 1=有接口不可达或鉴权失败 / 2=参数或登录错误
# ============================================================
set -u

BASE="${AMS_BASE:-http://127.0.0.1:8080}"
BASE="${BASE%/}"
USER="${AMS_USER:-}"
PASS="${AMS_PASS:-}"
TOKEN="${AMS_TOKEN:-}"
# 模型推理（尤其视觉/3B）可达 1-2 分钟，10s 会误报 HTTP 000
TIMEOUT="${AMS_CHECK_TIMEOUT:-180}"

PASS_N=0
FAIL_N=0
WARN_N=0

command -v curl >/dev/null 2>&1 || { echo "[FAIL] 缺少 curl"; exit 2; }
command -v python >/dev/null 2>&1 || { echo "[FAIL] 缺少 python（解析令牌需要）"; exit 2; }
case "$BASE" in
  http://*|https://*) ;;
  *) echo "[FAIL] AMS_BASE 必须以 http:// 或 https:// 开头（当前：$BASE）"; exit 2 ;;
esac

echo "=== AMS · AI 接口真连冒烟 ==="
echo "  目标：$BASE"
echo "  说明：验证路由可达 / 鉴权 / 契约；不写数据、不改配置"

# --- 健康检查 ---
HC="$(curl -s -o /dev/null -w '%{http_code}' -m "$TIMEOUT" "$BASE/api/health" 2>/dev/null)"
if [ "$HC" != "200" ]; then
  echo "[FAIL] AMS 健康检查 HTTP $HC —— 服务未启动或地址不对"
  echo "       容器形态：docker compose -f deploy/compose/docker-compose.yml -p ams ps"
  exit 1
fi
echo "[OK]   AMS 健康检查 HTTP 200"

# --- 获取令牌 ---
if [ -z "$TOKEN" ]; then
  if [ -z "$USER" ] || [ -z "$PASS" ]; then
    echo "[FAIL] 需要令牌：设置 AMS_TOKEN，或提供 AMS_USER + AMS_PASS"
    exit 2
  fi
  LOGIN="$(curl -s -m "$TIMEOUT" -X POST "$BASE/api/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"$USER\",\"password\":\"$PASS\"}" 2>/dev/null)"
  TOKEN="$(printf '%s' "$LOGIN" | python -c "import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('data',{}).get('accessToken',''))
except Exception:
    pass" 2>/dev/null)"
  if [ -z "$TOKEN" ]; then
    echo "[FAIL] 登录失败或响应无 data.accessToken（检查账号口令 / 是否需要验证码）"
    exit 2
  fi
  echo "[OK]   登录成功，已取得令牌"
else
  echo "[OK]   使用外部传入令牌"
fi

AUTH="Authorization: Bearer $TOKEN"

# 通用检查函数：check <名称> <方法> <路径> [body]
check() {
  local name="$1" method="$2" path="$3" body="${4:-}"
  local code out
  if [ -n "$body" ]; then
    out="$(curl -s -m "$TIMEOUT" -w '\n%{http_code}' -X "$method" "$BASE$path" \
      -H "$AUTH" -H 'Content-Type: application/json' -d "$body" 2>/dev/null)"
  else
    out="$(curl -s -m "$TIMEOUT" -w '\n%{http_code}' -X "$method" "$BASE$path" \
      -H "$AUTH" 2>/dev/null)"
  fi
  code="$(printf '%s' "$out" | tail -n1)"
  case "$code" in
    200|201|202|204)
      # 检查是否 code=OK（契约层）
      if printf '%s' "$out" | grep -q '"code":"OK"'; then
        echo "[OK]   $name — HTTP $code / code=OK"
        PASS_N=$((PASS_N + 1))
      else
        echo "[WARN]  $name — HTTP $code 但响应无 code=OK（可能是流式/降级响应）"
        WARN_N=$((WARN_N + 1))
      fi
      ;;
    400|422)
      # 参数不合法但路由可达、鉴权通过 —— 视为可达层通过（说明路由确实存在）
      echo "[OK]   $name — HTTP $code（路由可达，参数被正确校验）"
      PASS_N=$((PASS_N + 1))
      ;;
    401|403)
      echo "[FAIL] $name — HTTP $code（鉴权失败；检查令牌权限）"
      FAIL_N=$((FAIL_N + 1))
      ;;
    404|405)
      echo "[FAIL] $name — HTTP $code（路由缺失或方法错误；检查 server 注册）"
      FAIL_N=$((FAIL_N + 1))
      ;;
    500|502|503)
      # 5xx 一律 FAIL：模型未配置/未起时应降级返回 200 + reason 码，绝不应 5xx
      # （曾因把 search/ask 的中文 500 当 WARN 放过，实际是 AiJsonEscape 逐字节 UTF-8 bug）
      echo "[FAIL] $name — HTTP $code（服务端错误；AI 失败必须关闭式降级，不得 5xx）"
      FAIL_N=$((FAIL_N + 1))
      ;;
    *)
      echo "[WARN]  $name — HTTP $code（非预期状态）"
      WARN_N=$((WARN_N + 1))
      ;;
  esac
}

echo ""
echo "--- 能力发现与偏好（无需模型，必绿）---"
check "GET  /api/ai/capabilities"      GET  "/api/ai/capabilities"
check "PUT  /api/me/ai-preference"     PUT  "/api/me/ai-preference" '{"optOut":false}'

echo ""
echo "--- 管理面（需 system:admin；非管理员 403 属预期）---"
check "GET  /api/admin/ai/config"      GET  "/api/admin/ai/config"

echo ""
echo "--- AI 能力域（模型未就绪时允许降级 WARN，但不应 404/500）---"
# 中英双语各测一次：中文曾因 AiJsonEscape 逐字节 UTF-8 解码导致 500（已修，防回归）
check "POST /api/search/ask (中文)"    POST "/api/search/ask" '{"question":"找所有证书"}'
check "POST /api/search/ask (英文)"    POST "/api/search/ask" '{"question":"certificate"}'
check "POST /api/summary/items/1"      POST "/api/summary/items/1"
check "POST /api/advice/items/1"       POST "/api/advice/items/1"
check "POST /api/attachments/1/ai-parse" POST "/api/attachments/1/ai-parse"

echo ""
echo "--- admin 测试连接（会真发请求到 provider，模型未起可能失败）---"
echo "  （跳过 POST /api/admin/ai/test：它会触发真实出站请求，请到配置页手动点『测试连接』）"
echo ""
echo "--- 真连提示（模型就绪后按此顺序验证）---"
echo "  1. 配置页点『测试连接』→ ok 表示 AMS→provider 通"
echo "  2. S 域摘要：对某条目点生成摘要，观察是否返回真实内容（非降级）"
echo "  3. Q 域查询：自然语言问一个问题，看命中列表是否合理"
echo "  4. 若 S/Q 全部降级：检查模型是否支持 response_format=json_object"
echo "     （AMS 结构化输出默认带此参数；qwen2.5:0.5b-instruct 支持，其它模型需实测）"

echo ""
echo "=== 汇总：PASS=$PASS_N FAIL=$FAIL_N WARN=$WARN_N ==="
if [ "$FAIL_N" -gt 0 ]; then
  echo "[结论] 有接口不可达或鉴权失败 —— 这是 AMS 侧问题，需修复"
  exit 1
fi
if [ "$WARN_N" -gt 0 ]; then
  echo "[结论] 路由全部可达；$WARN_N 项 WARN 多为 provider 未就绪/降级，属环境态非 AMS 故障"
  echo "       Ollama 装好并在配置页设置后，重跑本脚本观察 WARN 是否转 OK"
else
  echo "[结论] 全部可达且契约正确"
fi
exit 0

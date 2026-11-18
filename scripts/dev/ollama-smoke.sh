#!/bin/bash
# ============================================================
# AMS · Ollama 本地接入冒烟（docs/20 §7.2 / §7.5）
#
# 用途：Ollama 安装后，确认它是否就绪、是否已加载可用于 AMS 的模型，
#       并给出配置页应填的 provider / base_url / model，避免瞎猜端点。
#
# 只读探测：不拉模型、不写 AMS 配置、不上传任何档案内容。
# 真正拉模型由用户自行决定（脚本只打印命令）。
#
# 用法：
#   bash scripts/dev/ollama-smoke.sh
#   AMS_OLLAMA_URL=http://127.0.0.1:11434 bash scripts/dev/ollama-smoke.sh
#
# 退出码：0=可接入 / 1=Ollama 未就绪（不是 AMS 故障）/ 2=参数错误
# ============================================================
set -u

BASE="${AMS_OLLAMA_URL:-http://127.0.0.1:11434}"
BASE="${BASE%/}"
TIMEOUT="${AMS_SMOKE_TIMEOUT:-3}"

info() { printf '  %s\n' "$*"; }
ok()   { printf '[OK]   %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*"; }

command -v curl >/dev/null 2>&1 || { fail "缺少 curl，请先安装"; exit 2; }
case "$BASE" in
  http://*|https://*) ;;
  *) fail "AMS_OLLAMA_URL 必须以 http:// 或 https:// 开头（当前：$BASE）"; exit 2 ;;
esac

printf '=== AMS · Ollama 本地接入冒烟 ===\n'
info "端点：$BASE"
info "（只读探测，不拉模型、不改 AMS 配置）"
printf '\n'

# 1) Ollama 是否在监听 /api/tags
CODE="$(curl -s -o /dev/null -w '%{http_code}' -m "$TIMEOUT" "$BASE/api/tags" 2>/dev/null)"
if [ "$CODE" != "200" ]; then
  warn "Ollama 未就绪：GET /api/tags HTTP $CODE（连接失败或未启动）"
  info "安装/启动方式（按你的平台）："
  info "  Windows : 安装 Ollama 后托盘常驻，或 'ollama serve'"
  info "  Linux   : sudo systemctl start ollama"
  info "  Docker  : docker run -d -p 11434:11434 -v ollama:/root/.ollama ollama/ollama"
  info "启动后重跑本脚本。当前属环境未就绪，不是 AMS 故障。"
  exit 1
fi
ok "Ollama 已在监听（HTTP 200）"

# 2) 列出已加载模型（同时验证响应可解析）
TAGS="$(curl -s -m "$TIMEOUT" "$BASE/api/tags" 2>/dev/null)"
if command -v python >/dev/null 2>&1; then
  MODELS="$(printf '%s' "$TAGS" | python -c "import json,sys
try:
    d=json.load(sys.stdin)
    for m in d.get('models',[]):
        print(m.get('name',''))
except Exception:
    pass" 2>/dev/null)"
else
  MODELS=""
fi
if [ -n "$MODELS" ]; then
  ok "已加载模型："
  printf '%s\n' "$MODELS" | sed 's/^/    - /'
else
  warn "未检测到已加载模型（python 不可用时也可能解析不到，请人工看 /api/tags）"
fi

# 3) 验证 OpenAI 兼容端点（AMS 默认走 /v1）
CODE_V1="$(curl -s -o /dev/null -w '%{http_code}' -m "$TIMEOUT" "$BASE/v1/models" 2>/dev/null)"
if [ "$CODE_V1" = "200" ]; then
  ok "OpenAI 兼容端点 /v1/models 可用（AMS 默认走此协议）"
else
  warn "OpenAI 兼容端点 /v1/models HTTP $CODE_V1 —— 较老版本 Ollama 可能未启用 /v1"
  info "请升级 Ollama，或确认 AMS 配置走原生 /api/chat（当前 AMS 客户端仅实现 /v1 兼容）"
fi

# 4) 判定 AMS 运行形态，给出正确的端点（关键：容器内 127.0.0.1 不是宿主机）
AMS_ENDPOINT="$BASE/v1"
if command -v docker >/dev/null 2>&1; then
  CID="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -m1 '^ams-server$' || true)"
  if [ -n "$CID" ]; then
    # 容器内实测 host.docker.internal 是否可达（curl 存在于 ams 镜像）
    DHA_CODE="$(docker exec "$CID" curl -s --noproxy '*' -m 3 -o /dev/null -w '%{http_code}' \
      "http://host.docker.internal:11434/api/tags" 2>/dev/null || true)"
    if [ "$DHA_CODE" = "200" ]; then
      AMS_ENDPOINT="http://host.docker.internal:11434/v1"
      ok "检测到 AMS 运行于 Docker（$CID），容器可经 host.docker.internal 访问 Ollama"
    else
      warn "AMS 运行于 Docker（$CID），但容器访问 $BASE 失败（HTTP $DHA_CODE）"
      info "若 host.docker.internal 不通，需给 ams-server 加 extra_hosts: ['host.docker.internal:host-gateway']"
    fi
  fi
fi

printf '\n=== AMS 配置页（系统运维 → AI 能力）应填 ===\n'
info "provider : ollama"
info "端点     : $AMS_ENDPOINT"
info "模型     : 从上面已加载模型里选；V 域（视觉识别）须选视觉模型"
info "API 密钥 : 留空（本地无需密钥）"
info "分域开关 : 视觉模型只开 V；纯文本模型只开 S/Q/A（DeepSeek 同理）"
printf '\n=== 建议拉取的模型（供你决定，脚本不代拉）===\n'
info "文本域（总结/查询/建议）：ollama pull qwen2.5:0.5b-instruct"
info "视觉域（证书/表格识别）  ：ollama pull qwen2.5vl:3b   # 体积较大，确认磁盘空间"
printf '\n提示：模型名以本地 ollama list 为准；AMS 不硬编码模型名。\n'
ok "Ollama 接入条件检查完成"
exit 0

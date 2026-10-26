# ============================================================
# AMS · 审计哈希链端到端验证脚本
#
# 覆盖（FR-AUD-003 哈希链防篡改）：
#   A. 完整性：本测试运行新产生的审计记录，链路 verify-chain 返回 ok
#   B. 篡改检测：改最后一条记录的内容字段（occurred_ms）后，
#      链路应报 tampered / broken / missing（非 ok）
#   C. 恢复：把字段改回原值后，链路重新 ok —— 证明 B 不是误报
#
# 设计要点：
#   ① 只校验「本次运行新产生的记录」（from = 测试前 MAX(chain_seq)+1），
#      避开迁移前遗留记录（其 occurred_ms 由 occurred_at 回填，与原始
#      应用层毫秒值可能差 1，属预期的「历史链不可重算」，不应算本实现的缺陷）。
#   ② 篡改用 occurred_ms ±1 —— 它参与哈希规范化，改后重算哈希必失配，
#      但不动哈希列本身，故 -1 即可精确还原，不留脏数据。
#
# 用法：bash scripts/ci/verify-audit.sh
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PORT="${AMS_VERIFY_PORT:-18103}"
BASE="http://127.0.0.1:${PORT}"
DB_PY="python3 scripts/db.py sql -s"

PASS=0
FAIL=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1  (实际: $2)"; FAIL=$((FAIL+1)); }

json_get() { python3 scripts/ci/_json_get.py "$1"; }

login() {
    curl -s --max-time 20 -X POST "${BASE}/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$1\",\"password\":\"$2\"}" \
        | json_get "data.accessToken"
}

code_of() { json_get "code"; }

# 取 aud_logs 当前最大 chain_seq（容忍 gsql 的表头/分隔行）
max_seq() {
    $DB_PY "SELECT MAX(chain_seq) AS n FROM aud_logs;" 2>/dev/null \
        | grep -oE '^[[:space:]]*[0-9]+[[:space:]]*$' | tr -d ' ' | head -1
}

# ---------------------------------------------------------------
# 启动服务
# ---------------------------------------------------------------
echo "=== 启动服务（端口 ${PORT}）==="
_AMS_DB_PW="${AMS_DB_PASSWORD:-Ams@Gauss2026}"
( cd build && exec env AMS_HTTP_PORT=${PORT} \
    AMS_DB_PASSWORD="${_AMS_DB_PW}" \
    AMS_TOKEN_SECRET="verify-audit-secret-key-2026-abcdefghijklmn" \
    ./ams-server.exe ) > /tmp/ams_verify_audit.log 2>&1 &
SRV_PID=$!
sleep 9

cleanup() {
    if [ -n "${SRV_PID:-}" ]; then
        kill -9 "$SRV_PID" 2>/dev/null
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------
# 准备：记录基线，生成本测试的新审计记录
# ---------------------------------------------------------------
BASE_SEQ="$(max_seq)"
[ -z "$BASE_SEQ" ] && BASE_SEQ=0
FROM_SEQ=$((BASE_SEQ + 1))
echo "  基线 chain_seq = ${BASE_SEQ}（本次仅校验 seq >= ${FROM_SEQ}）"

# auditor 登录 → 产生审计记录（testadmin 已绑定 auditor 角色 800005）
AUDITOR_TOKEN=$(login testadmin "Ams#Test12345")
if [ -z "$AUDITOR_TOKEN" ]; then
    echo "  [FAIL] 无法以 testadmin 登录（口令可能已被改过）"
    exit 1
fi
echo "  auditor 登录 OK（已写入审计链）"

# 再登一个用户，制造更多审计记录
login familyuser1 "Ams#Other12345" >/dev/null 2>&1 || true
NEW_SEQ="$(max_seq)"
[ -z "$NEW_SEQ" ] && NEW_SEQ=0
if [ "$NEW_SEQ" -le "$BASE_SEQ" ]; then
    bad "本测试应至少产生 1 条新审计记录" "new_seq=${NEW_SEQ}, base=${BASE_SEQ}"
    exit 1
fi
echo "  新产生审计记录 seq ${FROM_SEQ}..${NEW_SEQ}"

# ---------------------------------------------------------------
# A. 完整性
# ---------------------------------------------------------------
echo ""
echo "=== A. 哈希链完整性（FR-AUD-003）==="
R=$(curl -s --max-time 20 "${BASE}/api/audit/verify-chain?from=${FROM_SEQ}&limit=1000" \
        -H "Authorization: Bearer ${AUDITOR_TOKEN}")
STATUS=$(echo "$R" | json_get "data.status")
if [ "$STATUS" = "ok" ]; then
    ok "新记录链路完整，verify-chain 返回 ok"
else
    bad "新记录链路应返回 ok" "$STATUS :: $R"
fi

# ---------------------------------------------------------------
# B. 篡改检测
# ---------------------------------------------------------------
echo ""
echo "=== B. 篡改检测（FR-AUD-003）==="
# 篡改最后一条记录的内容字段 occurred_ms（+1），
# 链路重算哈希时该字段变化 → 与存储哈希失配 → 应报非 ok。
$DB_PY "UPDATE aud_logs SET occurred_ms = occurred_ms + 1 \
        WHERE chain_seq = (SELECT MAX(chain_seq) FROM aud_logs);" >/dev/null 2>&1

R=$(curl -s --max-time 20 "${BASE}/api/audit/verify-chain?from=${FROM_SEQ}&limit=1000" \
        -H "Authorization: Bearer ${AUDITOR_TOKEN}")
STATUS=$(echo "$R" | json_get "data.status")
if [ "$STATUS" != "ok" ]; then
    ok "篡改后链路检出异常（${STATUS}）"
else
    bad "篡改后链路应检出异常（tampered/broken/missing）" "$STATUS"
fi

# ---------------------------------------------------------------
# C. 恢复（证明 B 不是误报）
# ---------------------------------------------------------------
echo ""
echo "=== C. 篡改恢复后链路复原 ==="
$DB_PY "UPDATE aud_logs SET occurred_ms = occurred_ms - 1 \
        WHERE chain_seq = (SELECT MAX(chain_seq) FROM aud_logs);" >/dev/null 2>&1

R=$(curl -s --max-time 20 "${BASE}/api/audit/verify-chain?from=${FROM_SEQ}&limit=1000" \
        -H "Authorization: Bearer ${AUDITOR_TOKEN}")
STATUS=$(echo "$R" | json_get "data.status")
if [ "$STATUS" = "ok" ]; then
    ok "恢复后链路重新 ok"
else
    bad "恢复后链路应重新 ok" "$STATUS :: $R"
fi

# ---------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------
echo ""
echo "============================================================"
echo " 通过 ${PASS} 项，失败 ${FAIL} 项"
echo "============================================================"
[ "$FAIL" = "0" ] || exit 1

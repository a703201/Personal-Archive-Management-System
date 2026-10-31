#!/usr/bin/env bash
# ============================================================
# AMS · 口令策略端到端验证脚本（FR-AUTH-004）
#
# 覆盖：
#   A. 弱口令被拒（字典命中）
#   B. 过短口令被拒
#   C. 字符类别不足被拒
#   D. 口令含用户名被拒
#   E. 连续重复字符被拒
#   F. 合规口令被接受
#   G. 两次修改间隔 < 24 小时被拒
#
# 用法：bash scripts/ci/verify-password.sh
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PORT="${AMS_VERIFY_PORT:-18102}"
BASE="http://127.0.0.1:${PORT}"
DB_PY="python3 scripts/db.py sql -s"

PASS=0
FAIL=0

ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1  (实际: $2)"; FAIL=$((FAIL+1)); }

json_get() { python3 scripts/ci/_json_get.py "$1"; }
code_of()  { json_get "code"; }
msg_of()   { json_get "message"; }

expect_fail() {
    local desc="$1" body="$2"
    local r c
    r=$(curl -s --max-time 20 -X POST "${BASE}/api/users" \
        -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
        -d "$body")
    c=$(echo "$r" | code_of)
    if [ "$c" = "VALIDATION_FAILED" ]; then
        ok "$desc（$(echo "$r" | msg_of)）"
    else
        bad "$desc" "$c / $(echo "$r" | head -c 90)"
    fi
}

# ---------------------------------------------------------------
# 准备
# ---------------------------------------------------------------
echo "=== 准备测试数据 ==="
$DB_PY "UPDATE sys_users SET password_updated_at = NULL, failed_attempts = 0, locked_until = NULL
        WHERE id = 900001" >/dev/null 2>&1
echo "  数据就绪"

# ---------------------------------------------------------------
# 启动服务
# ---------------------------------------------------------------
echo "=== 启动服务（端口 ${PORT}）==="
_AMS_DB_PW="${AMS_DB_PASSWORD:-Ams@Gauss2026}"
( cd build && exec env AMS_HTTP_PORT=${PORT} \
    AMS_DB_PASSWORD="${_AMS_DB_PW}" \
    AMS_TOKEN_SECRET="verify-passwd-secret-key-2026-abcdefghijklmn" \
    ./ams-server.exe ) > /tmp/ams_verify_passwd.log 2>&1 &
SRV_PID=$!
sleep 9

cleanup() {
    if [ -n "${SRV_PID:-}" ]; then
        kill -9 "$SRV_PID" 2>/dev/null
    fi
}
trap cleanup EXIT

TOKEN=$(curl -s --max-time 30 -X POST "${BASE}/api/auth/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"testadmin","password":"Ams#Test12345"}' | json_get "data.accessToken")
if [ -z "$TOKEN" ]; then
    echo "  [FAIL] 无法以 testadmin 登录"
    exit 1
fi
echo "  管理员登录 OK"

# 每次用不同用户名，避免唯一约束冲突
STAMP=$(date +%s)

echo ""
echo "=== A. 弱口令字典命中 ==="
# 长度 ≥ 12、含 3 类字符，但属常见弱口令 → 应被字典拦下
expect_fail "常见弱口令被拒" \
    "{\"username\":\"pw_weak_${STAMP}\",\"password\":\"Password123!\"}"

echo ""
echo "=== B. 长度不足 ==="
expect_fail "过短口令被拒" \
    "{\"username\":\"pw_short_${STAMP}\",\"password\":\"Ab1!xy\"}"

echo ""
echo "=== C. 字符类别不足 ==="
expect_fail "仅小写的 12 位口令被拒" \
    "{\"username\":\"pw_class_${STAMP}\",\"password\":\"abcdefghijkl\"}"

echo ""
echo "=== D. 口令含用户名 ==="
expect_fail "口令含用户名被拒" \
    "{\"username\":\"pw_user_${STAMP}\",\"password\":\"Pw_user_${STAMP}A\"}"

echo ""
echo "=== E. 连续重复字符 ==="
expect_fail "连续重复字符被拒" \
    "{\"username\":\"pw_rep_${STAMP}\",\"password\":\"Aaaaaaaaaaaa1\"}"

echo ""
echo "=== F. 合规口令被接受 ==="
R=$(curl -s --max-time 20 -X POST "${BASE}/api/users" \
    -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    -d "{\"username\":\"pw_ok_${STAMP}\",\"password\":\"Ams#Good12345\"}")
C=$(echo "$R" | code_of)
if [ "$C" = "OK" ]; then
    ok "合规口令被接受"
else
    bad "合规口令被接受" "$C / $(echo "$R" | head -c 120)"
fi

echo ""
echo "=== G. 两次修改间隔 < 24 小时被拒 ==="
# 刚创建的用户 password_updated_at 是刚才 → 立即重置应被拦
NEWID=$(echo "$R" | json_get "data.id")
R2=$(curl -s --max-time 20 -X POST "${BASE}/api/users/${NEWID}/password" \
    -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
    -d '{"password":"Ams#Other12345"}')
C2=$(echo "$R2" | code_of)
if [ "$C2" = "VALIDATION_FAILED" ]; then
    ok "24 小时内重复改口令被拒（$(echo "$R2" | msg_of)）"
else
    bad "24 小时内重复改口令被拒" "$C2 / $(echo "$R2" | head -c 120)"
fi

# 清理测试账号
$DB_PY "DELETE FROM sys_users WHERE username LIKE 'pw_${STAMP}%' OR username LIKE 'pw_ok_${STAMP}%'
        OR username LIKE 'pw_weak_${STAMP}%' OR username LIKE 'pw_short_${STAMP}%'
        OR username LIKE 'pw_class_${STAMP}%' OR username LIKE 'pw_user_${STAMP}%'
        OR username LIKE 'pw_rep_${STAMP}%'" >/dev/null 2>&1

echo ""
echo "============================================================"
echo " 通过 ${PASS} 项，失败 ${FAIL} 项"
echo "============================================================"
[ "$FAIL" = "0" ] || exit 1

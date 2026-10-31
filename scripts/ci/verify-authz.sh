# ============================================================
# AMS · 端到端授权链路验证脚本
#
# 覆盖：
#   A. 所有者可见自己名下 sensitive / high 条目（FR-ACL-007）
#   B. 归属强制：无归属的他人被拒（FR-ACL-006）
#   C. 显式授权：被授权用户可读该条目（FR-ACL-008）
#   D. 授权到期：过期后立即不可读（FR-ACL-009）
#   E. 授权撤销：撤销后立即不可读（FR-ACL-009）
#
# 用法：bash scripts/ci/verify-authz.sh
# ============================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PORT="${AMS_VERIFY_PORT:-18101}"
BASE="http://127.0.0.1:${PORT}"
DB_PY="python3 scripts/db.py sql -s"

PASS=0
FAIL=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1  (实际: $2)"; FAIL=$((FAIL+1)); }

expect_code() {
    local desc="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then ok "$desc"; else bad "$desc" "$got"; fi
}

json_get() { python3 scripts/ci/_json_get.py "$1"; }

login() {
    curl -s --max-time 20 -X POST "${BASE}/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$1\",\"password\":\"$2\"}" \
        | json_get "data.accessToken"
}

code_of() { json_get "code"; }

# ---------------------------------------------------------------
# 准备测试数据
# ---------------------------------------------------------------
echo "=== 准备测试数据 ==="

# 主体 S1 归 owner 用户 900001 所有；S2 归 owner 用户 900002 所有
$DB_PY "DELETE FROM arc_items WHERE id IN (900201, 900202)" >/dev/null 2>&1
$DB_PY "DELETE FROM acl_grants WHERE id IN (900301, 900302)" >/dev/null 2>&1
$DB_PY "DELETE FROM arc_subjects WHERE id IN (900101, 900102)" >/dev/null 2>&1

# ⚠️ 900102 必须属于**第三方**（900001），不能属于 familyuser1(900002) ——
#    否则 familyuser1 本人就是它的所有者，
#    「无归属用户读他人条目」这条用例就失去意义。
$DB_PY "INSERT INTO arc_subjects (id, name_enc, owner_id, status, created_at, updated_at)
        VALUES (900101, decode('74657374','hex'), 900001, 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
               (900102, decode('74657374','hex'), 900001, 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)" >/dev/null 2>&1

# 900001 的条目：S1 名下，sensitivity=2 (sensitive)
# 900202 的条目：S2 名下，sensitivity=1 (normal)
$DB_PY "INSERT INTO arc_items (id, subject_id, category, title, status, sensitivity, extra,
        created_at, created_by, updated_at, updated_by, version)
        VALUES (900201, 900101, 1, 'owner-sensitive', 1, 2, '{}',
                CURRENT_TIMESTAMP, 900001, CURRENT_TIMESTAMP, 900001, 1),
               (900202, 900102, 1, 'other-normal', 1, 1, '{}',
                CURRENT_TIMESTAMP, 900002, CURRENT_TIMESTAMP, 900002, 1)" >/dev/null 2>&1

# 用户 900002（other）持有 family 角色（含 archive:read:own / write:own）
$DB_PY "DELETE FROM sys_user_roles WHERE user_id = 900002" >/dev/null 2>&1
$DB_PY "INSERT INTO sys_user_roles (id, user_id, role_id, granted_at)
        VALUES (900010, 900002, 800003, CURRENT_TIMESTAMP)" >/dev/null 2>&1

# 900001 持有 owner + auditor
# ⚠️ 只**追加** auditor，不删除 testadmin 的原有角色：
#    owner 角色不含 user:manage（那是 org_admin 的职责），
#    删掉 testadmin 的 org_admin 会导致重置口令接口 403。
$DB_PY "DELETE FROM sys_user_roles WHERE user_id = 900001 AND role_id = 800005" >/dev/null 2>&1
$DB_PY "INSERT INTO sys_user_roles (id, user_id, role_id, granted_at)
        VALUES (900012, 900001, 800005, CURRENT_TIMESTAMP)" >/dev/null 2>&1

# 给 900002 设定口令（用管理员接口，见主流程）
echo "  数据就绪"

# ---------------------------------------------------------------
# 启动服务
# ---------------------------------------------------------------
echo "=== 启动服务（端口 ${PORT}）==="
# TOKEN_SECRET 至少 32 字节（ServerConfig 会校验）
_AMS_DB_PW="${AMS_DB_PASSWORD:-Ams@Gauss2026}"
# 用 exec 让子 shell **替换成** ams-server.exe 进程，
# 这样 $! 拿到的就是服务本身的 PID（否则 $! 是子 shell 的，
# 在 set -u 下还会报 "$!: unbound variable"）。
( cd build && exec env AMS_HTTP_PORT=${PORT} \
    AMS_DB_PASSWORD="${_AMS_DB_PW}" \
    AMS_TOKEN_SECRET="verify-authz-secret-key-2026-abcdefghijklmn" \
    ./ams-server.exe ) > /tmp/ams_verify_authz.log 2>&1 &
SRV_PID=$!
sleep 9

# 用 PID 精确清理 —— ⚠️ 不能用 `pkill -f ams-server.exe`：
# 该模式的匹配范围会命中本脚本自身（脚本命令行里含该字符串），
# 导致脚本被 SIGTERM 杀掉（实测踩坑）。
cleanup() {
    if [ -n "${SRV_PID:-}" ]; then
        kill -9 "$SRV_PID" 2>/dev/null
    fi
}
trap cleanup EXIT

OWNER_TOKEN=$(login testadmin "Ams#Test12345")
if [ -z "$OWNER_TOKEN" ] || [ "$OWNER_TOKEN" = "" ]; then
    echo "  [FAIL] 无法以 testadmin 登录（口令可能已被改过）"
    exit 1
fi
echo "  管理员登录 OK"

# 给 other 用户设口令（走管理员接口，顺带验证 resetPassword 的策略校验）
# ⚠️ 先清掉 password_updated_at —— FR-AUTH-004 的「两次修改间隔 ≥ 24 小时」
#    会拦下重复重置（这正是该需求生效的表现），测试需要绕过它。
$DB_PY "UPDATE sys_users SET password_updated_at = NULL WHERE id = 900002" >/dev/null 2>&1
curl -s --max-time 20 -X POST "${BASE}/api/users/900002/password" \
    -H "Authorization: Bearer ${OWNER_TOKEN}" -H "Content-Type: application/json" \
    -d '{"password":"Ams#Other12345"}' >/dev/null
OTHER_TOKEN=$(login familyuser1 "Ams#Other12345")
if [ -z "$OTHER_TOKEN" ]; then
    echo "  [FAIL] 无法以 familyuser1 登录"
    exit 1
fi
echo "  other 用户登录 OK"

# ---------------------------------------------------------------
# A. 所有者可见自己名下 sensitive 条目
# ---------------------------------------------------------------
echo ""
echo "=== A. 所有者可见性（FR-ACL-007）==="
R=$(curl -s --max-time 20 "${BASE}/api/items/900201" -H "Authorization: Bearer ${OWNER_TOKEN}")
expect_code "所有者读自己 sensitive 条目" "OK" "$(echo "$R" | code_of)"

# ---------------------------------------------------------------
# B. 归属强制
# ---------------------------------------------------------------
echo ""
echo "=== B. 数据归属强制（FR-ACL-006）==="
R=$(curl -s --max-time 20 "${BASE}/api/items/900202" -H "Authorization: Bearer ${OTHER_TOKEN}")
C=$(echo "$R" | code_of)
if [ "$C" = "FORBIDDEN" ] || [ "$C" = "NOT_FOUND" ]; then
    ok "无归属用户读他人条目被拒（${C}）"
else
    bad "无归属用户读他人条目被拒" "$C"
fi

R=$(curl -s --max-time 20 "${BASE}/api/items/900201" -H "Authorization: Bearer ${OTHER_TOKEN}")
C=$(echo "$R" | code_of)
if [ "$C" = "FORBIDDEN" ] || [ "$C" = "NOT_FOUND" ]; then
    ok "无归属用户读他人 sensitive 条目被拒（${C}）"
else
    bad "无归属用户读他人 sensitive 条目被拒" "$C"
fi

# ---------------------------------------------------------------
# C. 显式授权（FR-ACL-008）
# ---------------------------------------------------------------
echo ""
echo "=== C. 显式临时授权（FR-ACL-008）==="
$DB_PY "INSERT INTO acl_grants (id, subject_id, item_id, category, grantee_id, perm_codes,
        granted_by, granted_at, expires_at)
        VALUES (900301, 900101, 900201, NULL, 900002, 'archive:read:own',
                900001, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP + INTERVAL '1 hour')" >/dev/null 2>&1

R=$(curl -s --max-time 20 "${BASE}/api/items/900201" -H "Authorization: Bearer ${OTHER_TOKEN}")
C=$(echo "$R" | code_of)
expect_code "被授权用户可读该条目" "OK" "$C"

# ---------------------------------------------------------------
# D. 授权到期（FR-ACL-009）
# ---------------------------------------------------------------
echo ""
echo "=== D. 授权到期即失效（FR-ACL-009）==="
$DB_PY "UPDATE acl_grants SET expires_at = CURRENT_TIMESTAMP - INTERVAL '1 minute'
        WHERE id = 900301" >/dev/null 2>&1

R=$(curl -s --max-time 20 "${BASE}/api/items/900201" -H "Authorization: Bearer ${OTHER_TOKEN}")
C=$(echo "$R" | code_of)
if [ "$C" = "FORBIDDEN" ] || [ "$C" = "NOT_FOUND" ]; then
    ok "授权过期后立即不可读（${C}）"
else
    bad "授权过期后立即不可读" "$C"
fi

# ---------------------------------------------------------------
# E. 授权撤销（FR-ACL-009）
# ---------------------------------------------------------------
echo ""
echo "=== E. 授权撤销即时生效（FR-ACL-009）==="
$DB_PY "UPDATE acl_grants SET expires_at = CURRENT_TIMESTAMP + INTERVAL '1 hour',
        revoked_at = CURRENT_TIMESTAMP WHERE id = 900301" >/dev/null 2>&1

R=$(curl -s --max-time 20 "${BASE}/api/items/900201" -H "Authorization: Bearer ${OTHER_TOKEN}")
C=$(echo "$R" | code_of)
if [ "$C" = "FORBIDDEN" ] || [ "$C" = "NOT_FOUND" ]; then
    ok "授权撤销后立即不可读（${C}）"
else
    bad "授权撤销后立即不可读" "$C"
fi

# ---------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------
echo ""
echo "============================================================"
echo " 通过 ${PASS} 项，失败 ${FAIL} 项"
echo "============================================================"
[ "$FAIL" = "0" ] || exit 1

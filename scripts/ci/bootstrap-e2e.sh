#!/bin/bash
# ============================================================
# AMS · E2E 环境夹具自举（幂等，仅测试库使用）
# ------------------------------------------------------------
# 背景：cleanup-test-accounts.sql / cleanup-demo-data.sql 会物理删除
#       testadmin / familyuser1，而 verify-authz.sh / verify-password.sh /
#       verify-audit.sh 强依赖如下固定夹具：
#         id=900001  testadmin    口令 Ams#Test12345
#         id=900002  familyuser1  口令 Ams#Other12345
#       以及 900001 的 org_admin(800004)、owner(800001)、auditor(800005)
#       和 900002 的 family(800003) 角色绑定。
#       两个口令沿用既有 verify 脚本里的固定测试值，非新凭据，仅测试库。
#
# 做法：优先走公开 POST /api/auth/register 让服务端计算口令哈希
#       （PBKDF2-HMAC-SM3，Python 标准库无 SM3，绝不自行计算），
#       再用 db.py 把雪花 id 修正为脚本硬编码的 900001 / 900002，
#       最后幂等补齐角色绑定。实测 register 只写 sys_users 一行、
#       且 sys_users 无外键引用，故改 id 不产生任何孤儿数据。
#
# 保证：
#   · 可重复运行；已就绪时不重复注册、不改动任何账号口令；
#   · 不删除任何现有数据、不覆盖已有账号真实口令；
#   · 失败给清晰错误，并以 exit 2 区分「环境夹具问题」与产品回归。
#
# 用法：AMS_DB_PASSWORD=... bash scripts/ci/bootstrap-e2e.sh
# ============================================================
set -uo pipefail

: "${AMS_DB_PASSWORD:?需要设置 AMS_DB_PASSWORD（E2E 需要真实数据库）}"
export AMS_DB_PASSWORD

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PY="$(command -v python3 || command -v python)"
if [ -z "$PY" ]; then
    echo "[SETUP-FAIL] 未找到 python3 / python" >&2
    exit 2
fi

PORT="${AMS_BOOTSTRAP_PORT:-18100}"
BASE="http://127.0.0.1:${PORT}"
SECRET="bootstrap-e2e-secret-key-2026-abcdefghij"

# 注册接口强制图形验证码；bootstrap 通过 e2e_captcha.py 读取显式开启的
# 非生产 devHint 测试通道并随注册请求携带，因此统一使用当前构建产物
# （生产环境该通道恒关闭，见 start_server 的 env 设置与 captcha.cj 门禁）。
BOOT_SERVER="ams-server.exe"

PW_ADMIN="Ams#Test12345"
PW_FAMILY="Ams#Other12345"

die() { echo "[SETUP-FAIL] $*" >&2; exit 2; }

sql() { "$PY" scripts/db.py sql -s "$1" 2>&1; }

# 从 gsql 表格输出里取唯一纯数字标量（db.py 末尾会残留一行 "0"，取首个）
scalar() {
    sql "$1" | grep -oE '^[[:space:]]*[0-9]+[[:space:]]*$' | tr -d ' ' | head -1
}

json_get() { "$PY" scripts/ci/_json_get.py "$1"; }

# gsql -f 默认不因错误置非零 rc，故显式检查报错文本
sql_checked() {
    local out=""
    out="$(sql "$1")"
    if echo "$out" | grep -qiE 'ERROR:|FATAL:|dead lock|duplicate key|violates'; then
        echo "$out" >&2
        die "SQL 执行失败：$1"
    fi
    echo "$out"
}

# 目标 id 是否被非目标账号占用（避免改 id 时主键冲突）
id_occupied_by_other() {
    local n=""
    n="$(scalar "SELECT count(*) FROM sys_users WHERE id = $1 AND username <> '$2';")"
    [ -n "$n" ] && [ "$n" != "0" ]
}

exists_user() {
    local n=""
    n="$(scalar "SELECT count(*) FROM sys_users WHERE username = '$1';")"
    [ -n "$n" ] && [ "$n" != "0" ]
}

ready() {
    local n=""
    n="$(scalar "SELECT count(*) FROM sys_users WHERE id = $1 AND username = '$2';")"
    [ "$n" = "1" ]
}

start_server() {
    ( cd build && exec env AMS_HTTP_PORT="${PORT}" \
        AMS_DB_PASSWORD="${AMS_DB_PASSWORD}" \
        AMS_TOKEN_SECRET="${SECRET}" \
        AMS_ENV=ci \
        AMS_E2E_CAPTCHA_HINT=true \
        "./${BOOT_SERVER}" ) > /tmp/ams_bootstrap_e2e.log 2>&1 &
    SRV_PID=$!
    local i ok=0 h=""
    for i in $(seq 1 25); do
        h="$(curl -s --max-time 2 "${BASE}/api/health" 2>/dev/null)"
        if echo "$h" | grep -q '"OK"'; then
            ok=1
            break
        fi
        sleep 1
    done
    if [ "$ok" != "1" ]; then
        echo "--- 临时服务日志（尾部）---" >&2
        tail -20 /tmp/ams_bootstrap_e2e.log >&2
        die "临时服务未能在端口 ${PORT} 就绪（无法注册/登录验证）"
    fi
}

stop_server() {
    if [ -n "${SRV_PID:-}" ]; then
        kill -9 "$SRV_PID" 2>/dev/null || true
    fi
}
trap stop_server EXIT

# 安全回归：不带任何验证码字段的注册请求必须被拒绝，
# 证明 path 化 + devHint 通道没有削弱生产侧的验证码强校验。
assert_captcha_required() {
    "$PY" scripts/ci/e2e_captcha.py --base "${BASE}" --assert-denied \
        || die "安全回归失败：不带验证码的注册请求未被拒绝（生产校验被削弱）"
}

register_user() {
    local user="$1" pw="$2" email="$3" resp="" code="" newid="" \
          cap_out="" cap_id="" cap_code=""
    cap_out="$("$PY" scripts/ci/e2e_captcha.py --base "${BASE}")" \
        || die "获取图形验证码失败（GET /api/auth/captcha）"
    cap_id="$(echo "$cap_out" | sed -n 's/^ID=//p')"
    cap_code="$(echo "$cap_out" | sed -n 's/^CODE=//p')"
    if [ -z "$cap_id" ] || [ -z "$cap_code" ]; then
        die "图形验证码响应缺少 ID/CODE（结构异常）"
    fi
    resp="$(curl -s --max-time 60 -X POST "${BASE}/api/auth/register" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${user}\",\"password\":\"${pw}\",\"email\":\"${email}\",\"nickname\":\"${user}\",\"captchaId\":\"${cap_id}\",\"captchaCode\":\"${cap_code}\"}")"
    code="$(echo "$resp" | json_get "code")"
    if [ "$code" != "OK" ]; then
        die "注册 ${user} 失败：${resp}（若提示唯一键冲突，说明夹具残留，请先查 sys_users）"
    fi
    newid="$(echo "$resp" | json_get "data.id")"
    if [ -z "$newid" ]; then
        newid="$(echo "$resp" | json_get "id")"
    fi
    [ -n "$newid" ] || die "注册 ${user} 未返回用户 id：${resp}"
    echo "  [OK] ${user} 已注册（临时 id=${newid}）"
}

verify_login() {
    local user="$1" pw="$2" token=""
    token="$(curl -s --max-time 30 -X POST "${BASE}/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${user}\",\"password\":\"${pw}\"}" | json_get "data.accessToken")"
    [ -n "$token" ] || die "夹具账号 ${user} 无法用预期口令登录（口令被改过 / 账号被禁用 / 登录接口异常）；请清理该账号后让 bootstrap 重建，不会自动覆盖其口令"
    echo "  [OK] ${user} 可用预期口令登录"
}

grant_role() {
    local rid="$1" uid="$2" role="$3"
    sql_checked "INSERT INTO sys_user_roles (id, user_id, role_id, granted_at)
        SELECT ${rid}, ${uid}, ${role}, CURRENT_TIMESTAMP
        WHERE NOT EXISTS (SELECT 1 FROM sys_user_roles WHERE user_id = ${uid} AND role_id = ${role})
          AND EXISTS (SELECT 1 FROM sys_users WHERE id = ${uid});" >/dev/null
}

# ---------------------------------------------------------------
echo "=== 夹具前置检查 ==="
id_occupied_by_other 900001 testadmin   && die "id 900001 已被非 testadmin 账号占用，请人工确认"
id_occupied_by_other 900002 familyuser1 && die "id 900002 已被非 familyuser1 账号占用，请人工确认"

# ---------------------------------------------------------------
echo "=== 启动临时服务（端口 ${PORT}，${BOOT_SERVER}）==="
start_server

echo "=== 安全回归：无验证码注册必须被拒绝 ==="
assert_captcha_required

if ! exists_user testadmin; then
    register_user testadmin "${PW_ADMIN}" "testadmin@e2e.local"
else
    echo "  [OK] testadmin 已存在，跳过注册（不改动其口令）"
fi
if ! exists_user familyuser1; then
    register_user familyuser1 "${PW_FAMILY}" "familyuser1@e2e.local"
else
    echo "  [OK] familyuser1 已存在，跳过注册（不改动其口令）"
fi

verify_login testadmin   "${PW_ADMIN}"
verify_login familyuser1 "${PW_FAMILY}"

stop_server

# ---------------------------------------------------------------
echo "=== 修正账号 id 到脚本硬编码值（幂等）==="
sql_checked "UPDATE sys_users SET id = 900001 WHERE username = 'testadmin' AND id <> 900001;" >/dev/null
sql_checked "UPDATE sys_users SET id = 900002 WHERE username = 'familyuser1' AND id <> 900002;" >/dev/null

echo "=== 补齐角色绑定（幂等）==="
grant_role 990011 900001 800004   # org_admin：user:manage（建用户 / 重置口令）
grant_role 990013 900001 800001   # owner：archive:read:own / write:own
grant_role 990014 900001 800005   # auditor：audit verify-chain
grant_role 990015 900002 800003   # family：被授权用例

# ---------------------------------------------------------------
echo "=== 最终校验 ==="
ready 900001 testadmin   || die "最终校验失败：id=900001 不是 testadmin"
ready 900002 familyuser1 || die "最终校验失败：id=900002 不是 familyuser1"
echo "[OK] 夹具就绪：testadmin(900001) / familyuser1(900002)"
exit 0

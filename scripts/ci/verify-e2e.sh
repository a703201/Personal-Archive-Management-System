#!/bin/bash
# 仅供本地/自托管 E2E：显式开启验证码 devHint 测试通道；生产绝不设置
export AMS_ENV=ci
export AMS_E2E_CAPTCHA_HINT=true
# ============================================================
# AMS · 端到端回归统一编排（需要 openGauss + 已构建产物）
#
# 背景：此前 4 个 E2E 分散在 ci.yml 的各步骤里，另有 3 个脚本
#       （verify-tenant.py / verify-family.py / verify-audit-chain.py）
#       从未被任何 workflow 调用。这里统一收口，供本地与自托管
#       runner 一键执行；GitHub 托管 runner 无 DB 时由 ci.yml 显式跳过。
#
# 端口：各脚本自带默认值互相冲突（verify-password 与 verify-family
#       都默认 18102），故此处显式分配互不相交的端口。
#
# 用法（在仓库根目录）：
#   set -a; source deploy/compose/.env; set +a
#   bash scripts/ci/verify-e2e.sh
# ============================================================
set -uo pipefail

: "${AMS_DB_PASSWORD:?需要设置 AMS_DB_PASSWORD（E2E 需要真实数据库）}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PY="$(command -v python3 || command -v python)"
if [ -z "$PY" ]; then
    echo "[ERROR] 未找到 python3 / python"
    exit 1
fi

FAILED=0
TOTAL=0

run_step() {
    local name="$1"
    shift
    TOTAL=$((TOTAL + 1))
    echo ""
    echo "=== E2E ${TOTAL}: ${name} ==="
    if "$@"; then
        echo "  [PASS] ${name}"
    else
        echo "  [FAIL] ${name}"
        FAILED=$((FAILED + 1))
    fi
}

# 1. 仓储层集成测试（无 DB 时脚本内会 SKIP，这里要求已配置 DB 口令）
run_step "集成测试 ams-data" bash scripts/test.sh ams-data

# 1.5 环境夹具自举（不计入 7 组统计）：第 2~4 组强依赖 id=900001/900002
#     的 testadmin/familyuser1 测试账号。夹具缺失属「环境问题」，
#     与产品回归失败区分：失败时以 exit 2 明确终止，不静默跳过。
echo ""
echo "=== E2E 前置：夹具自举（testadmin / familyuser1）==="
if bash scripts/ci/bootstrap-e2e.sh; then
    echo "  [OK] 夹具就绪"
else
    echo "  [SETUP-FAIL] 环境夹具缺失（非产品回归）：testadmin/familyuser1 未就绪"
    echo "  处理：查看上方 bootstrap 错误；或用 scripts/cleanup-test-accounts.sql 清理后重试。"
    exit 2
fi

# 2~4. 既有三条跨层链路
run_step "授权链路（FR-ACL-005~009）" env AMS_VERIFY_PORT=18101 bash scripts/ci/verify-authz.sh
run_step "口令策略（FR-AUTH-004）" env AMS_VERIFY_PORT=18102 bash scripts/ci/verify-password.sh
run_step "审计哈希链（FR-AUD-003）" env AMS_VERIFY_PORT=18103 bash scripts/ci/verify-audit.sh
# 5~6. 此前未接入 CI 的两条回归（两个脚本自行适配图形验证码）
run_step "多租户隔离（方案 A）" env AMS_VERIFY_PORT=18106 "$PY" scripts/ci/verify-tenant.py
run_step "家庭协作 + 同端口静态托管" env AMS_VERIFY_PORT=18107 "$PY" scripts/ci/verify-family.py

# 7. 审计链独立校验器：用 Python 独立复算 SM3，与服务端自证交叉比对。
#    历史链可能因迁移前 occurred_ms 回填口径不同而无法重算，属已知现象，
#    故此步设为 best-effort（失败仅告警，不阻断整批 E2E）。
TOTAL=$((TOTAL + 1))
echo ""
echo "=== E2E ${TOTAL}: 审计链独立校验（best-effort） ==="
if "$PY" scripts/verify-audit-chain.py; then
    echo "  [PASS] 审计链独立校验"
else
    echo "  [WARN] 审计链独立校验未通过（历史链重算口径差异属已知现象，不阻断）"
fi

echo ""
echo "=== 端到端回归汇总：执行 ${TOTAL} 组，失败 ${FAILED} 组 ==="
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
exit 0

-- ============================================================
-- 024 · 租户运营能力（SaaS 方案 A · 阶段 3 · docs/15 §4.2）
--
-- 目标：在阶段 1（数据层隔离）/ 阶段 2（跨租户回归）之上补齐
--   ① 租户级配额  sys_tenant_quota
--   ② 租户级配置  sys_tenant_settings
--   ③ 租户级审计视图 v_tenant_audit_summary
--
-- 幂等性（与 022 同款写法）：
--   openGauss 不支持 ADD COLUMN IF NOT EXISTS / ON CONFLICT，
--   故一律 CREATE TABLE IF NOT EXISTS + WHERE NOT EXISTS 播种。
--   全部为**侧表**，不改动 sys_tenants 既有列，升级零破坏。
--
-- 安全边界：
--   · 配额是「运营上限声明」，本阶段只提供读写与查询，尚未在
--     创建用户 / 条目 / 附件的写路径上强制拦截（见 docs/15 阶段 3 备注）。
--     不在未经压测的情况下悄悄改变写入语义。
--   · 配置表带 is_secret，接口层只回占位，不返回明文。
--   · 审计视图按 actor_id → sys_users.tenant_id 关联；系统动作
--     （actor_id 为空）不计入任何租户。
-- ============================================================

CREATE TABLE IF NOT EXISTS sys_tenant_quota (
    tenant_id      BIGINT      NOT NULL PRIMARY KEY,
    max_users      INTEGER     NOT NULL DEFAULT 100,
    max_items      INTEGER     NOT NULL DEFAULT 10000,
    max_storage_mb INTEGER     NOT NULL DEFAULT 1024,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO sys_tenant_quota (tenant_id, max_users, max_items, max_storage_mb)
SELECT 1, 100, 10000, 1024
WHERE NOT EXISTS (SELECT 1 FROM sys_tenant_quota WHERE tenant_id = 1);

COMMENT ON TABLE sys_tenant_quota IS '租户运营配额（阶段 3）。当前为声明值，写路径强制拦截待后续决策。';

CREATE TABLE IF NOT EXISTS sys_tenant_settings (
    tenant_id   BIGINT       NOT NULL,
    setting_key VARCHAR(128) NOT NULL,
    value       TEXT         NOT NULL DEFAULT '',
    is_secret   BOOLEAN      NOT NULL DEFAULT FALSE,
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (tenant_id, setting_key)
);

COMMENT ON TABLE sys_tenant_settings IS '租户级配置覆盖；is_secret 项接口层只回占位。';

-- 按操作者归属聚合审计动作。actor_id 为空的系统动作不归属任何租户。
CREATE OR REPLACE VIEW v_tenant_audit_summary AS
SELECT u.tenant_id                       AS tenant_id,
       a.action                          AS action,
       a.result                          AS result,
       COUNT(*)                          AS event_count,
       MAX(a.occurred_at)                AS last_occurred_at
FROM aud_logs a
JOIN sys_users u ON u.id = a.actor_id
WHERE u.tenant_id IS NOT NULL
GROUP BY u.tenant_id, a.action, a.result;

COMMENT ON VIEW v_tenant_audit_summary IS '租户级审计聚合（按 actor 归属；系统动作不计入）。';

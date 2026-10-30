-- ============================================================
-- 022 · 多租户隔离（SaaS 方案 A · 阶段 1 · 数据层隔离）
--
-- 依据：docs/18-架构演进路线-方案候选.md §4.2（方案 A 多租户单体）
--
-- 目标：
--   ① 引入租户概念（sys_tenants），存量数据与现有账号统一归属
--      默认租户 id=1（code='default'），迁移不破坏既有数据；
--   ② 在核心表 sys_users / arc_subjects / arc_items 增加 tenant_id，
--      仓储层与鉴权中间件注入租户上下文，所有查询强制带
--      tenant_id 过滤，防越权跨租户访问；
--   ③ 存量行由 DEFAULT 1 回填，新行由应用侧显式写入（失败关闭：
--      不写 tenant_id 会落到系统租户，受默认租户隔离边界约束）。
--
-- 幂等性：
--   - sys_tenants 用 IF NOT EXISTS + WHERE NOT EXISTS 防重复；
--   - 加列用 DO 块 + information_schema 判定（openGauss 不支持
--     ADD COLUMN IF NOT EXISTS）；
--   - 索引用 CREATE INDEX IF NOT EXISTS（openGauss 5.0 支持）。
-- ============================================================

-- ------------------------------------------------------------
-- 1) 租户表
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sys_tenants (
    id          BIGINT       NOT NULL PRIMARY KEY,
    code        VARCHAR(64)  NOT NULL UNIQUE,
    name        VARCHAR(128) NOT NULL,
    status      VARCHAR(16)  NOT NULL DEFAULT 'active',
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 默认租户：所有存量账号 / 主体 / 条目归属此处，迁移零破坏。
INSERT INTO sys_tenants (id, code, name, status)
SELECT 1, 'default', 'Default Tenant', 'active'
WHERE NOT EXISTS (SELECT 1 FROM sys_tenants WHERE id = 1);

COMMENT ON TABLE sys_tenants IS '租户（多租户隔离根）。Phase 1 仅默认租户，租户注册/引导流程见后续阶段。';

-- ------------------------------------------------------------
-- 2) 核心表加 tenant_id（幂等 DO 块）
-- ------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'sys_users' AND column_name = 'tenant_id'
    ) THEN
        ALTER TABLE sys_users ADD COLUMN tenant_id BIGINT NOT NULL DEFAULT 1;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'arc_subjects' AND column_name = 'tenant_id'
    ) THEN
        ALTER TABLE arc_subjects ADD COLUMN tenant_id BIGINT NOT NULL DEFAULT 1;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'arc_items' AND column_name = 'tenant_id'
    ) THEN
        ALTER TABLE arc_items ADD COLUMN tenant_id BIGINT NOT NULL DEFAULT 1;
    END IF;
END $$;

COMMENT ON COLUMN sys_users.tenant_id IS '所属租户；关联 sys_tenants.id，默认 1（Default Tenant）。';
COMMENT ON COLUMN arc_subjects.tenant_id IS '所属租户；行级隔离过滤列。';
COMMENT ON COLUMN arc_items.tenant_id IS '所属租户；行级隔离过滤列。';

-- ------------------------------------------------------------
-- 3) 索引
-- ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_sys_users_tenant     ON sys_users(tenant_id);
CREATE INDEX IF NOT EXISTS idx_arc_subjects_tenant  ON arc_subjects(tenant_id);
CREATE INDEX IF NOT EXISTS idx_arc_items_tenant     ON arc_items(tenant_id);

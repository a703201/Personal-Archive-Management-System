-- ============================================================
-- 007 · P1 基础设施（密钥版本登记表 + 管理员授权补齐）
--
-- 覆盖：
--   FR-CFG-007 密钥管理界面 → sys_key_versions（只存**元信息**，绝不存密钥材料）
--   FR-CFG-005 系统健康看板 / FR-CFG-006 备份与恢复 → 需要 system:admin 授权
--
-- 设计约束（安全章 §4.4）：
--   **密钥材料绝不落库**。本表只登记「当前有哪些密钥版本、各自状态如何」，
--   用于界面展示与轮换留痕；真正的 KEK 来自环境变量 / KMS，
--   DEK 以密文形式存在 arc_attachments.wrapped_dek。
--   轮换 = 生成新版本行并把旧版本标记为 retired（旧数据仍可解），
--   吊销 = 标记 revoked（禁止再用于新数据包裹）。
--
-- 全部语句幂等，可重复执行。
-- ============================================================

-- ---------- 1. 密钥版本登记表 ----------
CREATE TABLE IF NOT EXISTS sys_key_versions (
    id            BIGINT       PRIMARY KEY,
    key_id        VARCHAR(64)  NOT NULL,
    version       INTEGER      NOT NULL,
    alg           SMALLINT     NOT NULL DEFAULT 1,
    purpose       VARCHAR(32)  NOT NULL DEFAULT 'data',
    status        SMALLINT     NOT NULL DEFAULT 1,
    note          VARCHAR(256),
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by    BIGINT,
    retired_at    TIMESTAMPTZ,
    revoked_at    TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS uk_sys_key_versions
    ON sys_key_versions(key_id, version);
CREATE INDEX IF NOT EXISTS idx_sys_key_versions_status
    ON sys_key_versions(status, created_at DESC);

COMMENT ON TABLE sys_key_versions IS '密钥版本元信息（不含任何密钥材料）';
COMMENT ON COLUMN sys_key_versions.status IS '1=active 2=retired 3=revoked';

-- ---------- 2. 补齐 org_admin 的 system:admin 授权 ----------
-- org_admin 是内置机构管理员，默认应能访问系统运维界面。
-- 003 里只播种了权限点，未把 system:admin 挂到该角色上。
--
-- ⚠️ 角色 ID **按 code 查**，不要写死：sys_roles 的 id 由各迁移里的
--    字面量决定（org_admin 实际是 800004，而 800001 是 owner），
--    写死很容易授错角色（且不会报错，只是静默不生效）。
-- 先清掉本迁移保留的这一行（可能来自早期版本按错误角色 ID 写入的记录），
-- 再按 code 重新插入 —— DELETE + INSERT 使整段可重复执行。
DELETE FROM sys_role_perms WHERE id = 700081;

INSERT INTO sys_role_perms (id, role_id, perm_id)
SELECT 700081, r.id, p.id
FROM sys_roles r
CROSS JOIN sys_perms p
WHERE r.code = 'org_admin'
  AND p.code = 'system:admin'
  AND NOT EXISTS (
      SELECT 1 FROM sys_role_perms rp
      WHERE rp.role_id = r.id AND rp.perm_id = p.id
  );

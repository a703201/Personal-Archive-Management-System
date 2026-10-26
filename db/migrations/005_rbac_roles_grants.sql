-- ============================================================
-- AMS · 005_rbac_roles_grants.sql
--
-- 目的：补齐 RBAC 管理闭环所需的表结构（FR-ACL-002 / FR-ACL-004）：
--   sys_roles.parent_role_id   支持自定义角色的层级派生（可选）
--   sys_user_roles.category    支持「按分类授权」的落点（缺此列则分类授权无载体）
--
-- 说明（openGauss 5.0.0）：不支持 `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`，
--   故用 DO 块做幂等判断后再 ADD，确保重复执行安全。
--   两表均为业务表（含数据），**不能** DROP 重建，须在线 ALTER。
-- ============================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'sys_roles' AND column_name = 'parent_role_id'
    ) THEN
        ALTER TABLE sys_roles ADD COLUMN parent_role_id BIGINT;
        -- 自引用外键：父角色级联不影响子角色；软删除只置 deleted_at，PK 不删，故 FK 安全
        ALTER TABLE sys_roles ADD CONSTRAINT fk_sys_roles_parent
            FOREIGN KEY (parent_role_id) REFERENCES sys_roles(id);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'sys_user_roles' AND column_name = 'category'
    ) THEN
        ALTER TABLE sys_user_roles ADD COLUMN category SMALLINT NOT NULL DEFAULT 0;
        CREATE INDEX IF NOT EXISTS idx_sys_user_roles_cat
            ON sys_user_roles(user_id, role_id, COALESCE(subject_id, 0), category);
    END IF;
END $$;

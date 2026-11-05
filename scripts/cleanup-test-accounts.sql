-- ============================================================
-- AMS · 清理全部历史测试账号（幂等；系统配置表一律不动）
-- ------------------------------------------------------------
-- 沿用 cleanup-demo-data.sql 的安全边界：
--   · 只删「以用户 id 为所有者」的私有数据表；
--   · 绝不按 created_by/updated_by 删除 sys_roles / cfg_settings /
--     cfg_dict_* / job_leases / sys_key_versions 等系统表；
--   · 审计表 aud_* 按合规保留；
--   · 账号物理删除，避免唯一索引占位导致同名无法注册。
--
-- 匹配范围：运维期 E2E / 压测 / 接口测试批量生成的账号前缀。
-- 执行前请先用 `scripts/db.py sql -s "SELECT id,username FROM sys_users"`
-- 导出清单备份（本次备份见 .tmp/users-backup-20261105.txt）。
-- ============================================================

CREATE TABLE IF NOT EXISTS cleanup_targets (id BIGINT PRIMARY KEY);
DELETE FROM cleanup_targets;

INSERT INTO cleanup_targets (id)
SELECT id FROM sys_users
 WHERE username ~ '^(e2e|it|t1owner|tenant|bench|tester|apitest|familyuser|gooduser|testadmin)';

-- 1) 测试主体下的共享链接与条目（无 FK 级联，先于主体删除）
DELETE FROM arc_share_links
 WHERE item_id IN (
       SELECT i.id FROM arc_items i
       JOIN arc_subjects s ON s.id = i.subject_id
      WHERE s.owner_id IN (SELECT id FROM cleanup_targets));

DELETE FROM arc_items
 WHERE subject_id IN (
       SELECT id FROM arc_subjects
        WHERE owner_id IN (SELECT id FROM cleanup_targets));

-- 2) 账号私有数据
DELETE FROM sys_user_roles     WHERE user_id  IN (SELECT id FROM cleanup_targets);
DELETE FROM sys_sessions       WHERE user_id  IN (SELECT id FROM cleanup_targets);
DELETE FROM sys_user_totp      WHERE user_id  IN (SELECT id FROM cleanup_targets);
DELETE FROM sys_password_reset WHERE user_id  IN (SELECT id FROM cleanup_targets);
DELETE FROM nft_messages       WHERE user_id  IN (SELECT id FROM cleanup_targets);
DELETE FROM imp_export_tasks   WHERE user_id  IN (SELECT id FROM cleanup_targets);
DELETE FROM fam_members        WHERE user_id  IN (SELECT id FROM cleanup_targets);

-- 3) 以 owner_id 归属的业务对象
DELETE FROM fam_groups           WHERE owner_id IN (SELECT id FROM cleanup_targets);
DELETE FROM arc_saved_views      WHERE owner_id IN (SELECT id FROM cleanup_targets);
DELETE FROM arc_search_history   WHERE owner_id IN (SELECT id FROM cleanup_targets);
DELETE FROM arc_item_templates   WHERE owner_id IN (SELECT id FROM cleanup_targets);
DELETE FROM arc_import_templates WHERE owner_id IN (SELECT id FROM cleanup_targets);
DELETE FROM arc_tags             WHERE owner_id IN (SELECT id FROM cleanup_targets);
DELETE FROM arc_share_links      WHERE owner_id IN (SELECT id FROM cleanup_targets);
DELETE FROM arc_subjects         WHERE owner_id IN (SELECT id FROM cleanup_targets);

-- 4) 账号本身
DELETE FROM sys_users WHERE id IN (SELECT id FROM cleanup_targets);

DROP TABLE cleanup_targets;

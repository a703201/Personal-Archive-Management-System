-- ============================================================
-- AMS · 清理演示/测试账户及其演示数据（幂等，可重复执行）
-- ------------------------------------------------------------
-- tpl_probe_01 是运维期写进数据库卷的测试账号，不在任何迁移里。
-- 首次部署改为由向导创建管理员，故清理该账号及其演示数据。
--
-- 安全边界（重要）：
--   · 只删「以用户 id 为所有者」的私有数据表；
--   · 绝不按 created_by/updated_by 删除系统表（sys_roles / cfg_settings /
--     cfg_dict_* / job_leases / sys_key_versions 等），否则会破坏系统配置；
--   · 审计表（aud_*）按合规要求保留留痕；
--   · 账号物理删除，避免 uk_sys_users_username 占位导致同名无法注册。
--
-- 写法：全部用子查询定位账号 id，不用 PL/pgSQL / $1 占位符，
--      避免与 db.py 的 $$ 分句逻辑冲突。
-- ============================================================

-- 1) 演示主体下的共享链接与条目（无 FK 级联，必须先于主体删除）
DELETE FROM arc_share_links
 WHERE item_id IN (
       SELECT i.id FROM arc_items i
       JOIN arc_subjects s ON s.id = i.subject_id
      WHERE s.owner_id = (SELECT id FROM sys_users WHERE username = 'tpl_probe_01'));

DELETE FROM arc_items
 WHERE subject_id IN (
       SELECT id FROM arc_subjects
        WHERE owner_id = (SELECT id FROM sys_users WHERE username = 'tpl_probe_01'));

-- 2) 账号私有数据（角色、会话、双因子、找回令牌、通知、导出任务、家庭组）
DELETE FROM sys_user_roles    WHERE user_id  = (SELECT id FROM sys_users WHERE username = 'tpl_probe_01');
DELETE FROM sys_sessions      WHERE user_id  = (SELECT id FROM sys_users WHERE username = 'tpl_probe_01');
DELETE FROM sys_user_totp     WHERE user_id  = (SELECT id FROM sys_users WHERE username = 'tpl_probe_01');
DELETE FROM sys_password_reset WHERE user_id = (SELECT id FROM sys_users WHERE username = 'tpl_probe_01');
DELETE FROM nft_messages      WHERE user_id  = (SELECT id FROM sys_users WHERE username = 'tpl_probe_01');
DELETE FROM imp_export_tasks  WHERE user_id  = (SELECT id FROM sys_users WHERE username = 'tpl_probe_01');
DELETE FROM fam_members       WHERE user_id  = (SELECT id FROM sys_users WHERE username = 'tpl_probe_01');

-- 3) 以 owner_id 归属的业务对象
DELETE FROM fam_groups         WHERE owner_id = (SELECT id FROM sys_users WHERE username = 'tpl_probe_01');
DELETE FROM arc_saved_views    WHERE owner_id = (SELECT id FROM sys_users WHERE username = 'tpl_probe_01');
DELETE FROM arc_search_history WHERE owner_id = (SELECT id FROM sys_users WHERE username = 'tpl_probe_01');
DELETE FROM arc_item_templates WHERE owner_id = (SELECT id FROM sys_users WHERE username = 'tpl_probe_01');
DELETE FROM arc_import_templates WHERE owner_id = (SELECT id FROM sys_users WHERE username = 'tpl_probe_01');
DELETE FROM arc_tags           WHERE owner_id = (SELECT id FROM sys_users WHERE username = 'tpl_probe_01');
DELETE FROM arc_share_links    WHERE owner_id = (SELECT id FROM sys_users WHERE username = 'tpl_probe_01');
DELETE FROM arc_subjects       WHERE owner_id = (SELECT id FROM sys_users WHERE username = 'tpl_probe_01');

-- 4) 账号本身（放最后，上面的子查询都依赖它）
DELETE FROM sys_users WHERE username = 'tpl_probe_01';

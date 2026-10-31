-- ============================================================
-- AMS · 007_scheduler_ops.sql
--
-- 目的：让周期任务触发端点（POST /api/admin/tasks/run）**可达**。
--
-- 背景：
--   D6 调度器选型结论为「系统 cron / 运维触发 + 进程内间隔闸门」，
--   因此需要把一个管理端点暴露给具备运维职责的角色。
--   system:admin 权限点已在 003 中定义（id=900038），
--   但**没有任何内置角色持有它** —— 若不授权，端点虽有却无人可调。
--
-- 做法：把 system:admin 授予 owner（所有者，800001）与 org_admin（机构管理员，800004）。
--   二者 max_data_level 均为 3，语义上属于管理者，符合「职责分离」要求。
--
-- 幂等：NOT EXISTS 判重 + 固定 ID（沿用 003 的 700xxx 段），可反复执行。
-- ============================================================

-- owner → system:admin
INSERT INTO sys_role_perms (id, role_id, perm_id)
SELECT 700901, 800001, 900038
WHERE NOT EXISTS (
    SELECT 1 FROM sys_role_perms WHERE role_id = 800001 AND perm_id = 900038
);

-- org_admin → system:admin
INSERT INTO sys_role_perms (id, role_id, perm_id)
SELECT 700902, 800004, 900038
WHERE NOT EXISTS (
    SELECT 1 FROM sys_role_perms WHERE role_id = 800004 AND perm_id = 900038
);

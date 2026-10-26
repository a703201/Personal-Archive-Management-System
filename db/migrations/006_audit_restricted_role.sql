-- ============================================================
-- AMS · 006_audit_restricted_role.sql
--
-- 目的：创建**受限应用账号** ams_app 并收紧审计表权限（FR-AUD-006）。
--
-- 问题：此前应用运行时以 gaussdb 超级用户连接数据库，
--       任何应用层漏洞都可能直接 DROP / TRUNCATE / UPDATE 审计表，
--       使「哈希链 + 外部锚点」的防篡改设计形同虚设。
--
-- 方案：新增受限角色 ams_app（NOSUPERUSER / NOCREATEDB / NOCREATEROLE / NOREPLICATION）：
--   - 业务表（arc_* / sys_* / cfg_* / acl_* / notify_* ...）：SELECT / INSERT / UPDATE / DELETE
--   - 审计表 aud_logs / aud_chain_anchors：仅 SELECT / INSERT（禁止 UPDATE / DELETE / TRUNCATE）
--   从**数据库层**保证审计不可篡改，即使应用层被攻破也难以改写历史记录。
--
-- 部署说明（重要）：
--   1. 本迁移以管理账号（gaussdb）执行，因为它需要 DDL 与授权权限；
--      应用运行时连接**不**应使用此账号，而应改用 ams_app。
--   2. 下方 ams_app 的占位口令仅供本地/测试；生产环境必须用密钥管理注入：
--        ALTER ROLE ams_app PASSWORD '<from-secret-manager>';
--   3. 应用以 AMS_DB_APP_USER=ams_app / AMS_DB_APP_PASSWORD=<secret> 启动；
--      未配置时 main.cj 回退到管理账号（本地开发兼容）。
--   4. 本迁移仅收紧「已存在的审计表」。未来若新增审计类表，
--      须参照下方 REVOKE/GRANT 单独加固（默认权限已对 ams_app 开放全 DML）。
--
-- 幂等：DO 块内做存在性判断，可重复执行。
-- ============================================================

-- 1) 创建受限角色（若不存在）
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ams_app') THEN
        CREATE ROLE ams_app LOGIN
            PASSWORD 'AmsApp@ChangeMe2026'
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            NOREPLICATION;
    END IF;
END
$$;

-- 2) 连接与 schema 使用权限
GRANT CONNECT ON DATABASE ams TO ams_app;
GRANT USAGE ON SCHEMA public TO ams_app;

-- 3) 业务表：全 DML（含未来新建表）
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ams_app;

-- 4) 审计表：仅 SELECT / INSERT —— 核心约束
REVOKE UPDATE, DELETE, TRUNCATE ON aud_logs        FROM ams_app, PUBLIC;
REVOKE UPDATE, DELETE, TRUNCATE ON aud_chain_anchors FROM ams_app, PUBLIC;
GRANT SELECT, INSERT ON aud_logs         TO ams_app;
GRANT SELECT, INSERT ON aud_chain_anchors TO ams_app;

-- 5) 未来新建表的默认权限：默认对 ams_app 开放全 DML
--    （审计表不会再有新建，已存在的审计表已在第 4 步单独收紧）
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ams_app;

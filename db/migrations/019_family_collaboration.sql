-- ============================================================
-- 019 · 家庭成员邀请与轻量协作（FR-ACL-010 · 方案 B）
--
-- 需求：SC-12 / FR-ACL-010 —— 用邀请码/二维码把家人拉入「家庭组」，
--       成员**默认零可见**，只能读取被显式授权的内容。
--
-- 三处待定项的决策依据见 docs/15-家庭成员邀请方案评估.md：
--   · 授权粒度 = 方案 B（主体 + 条目；分类仅作「同主体内收窄」）；
--   · 不做「成员申请 → owner 审批」流程（邀请方向本身即双方确认）；
--   · 实施压缩为 3 批，每批收在可演示闭环上。
--
-- ------------------------------------------------------------
-- 为什么不 ALTER acl_grants 加 group_id（与 docs/14 §4.2 的偏离说明）
-- ------------------------------------------------------------
-- 设计稿原本打算给 acl_grants 加一列 group_id。实测 openGauss **不支持**
--   ALTER TABLE ... ADD COLUMN IF NOT EXISTS
--   → ERROR: syntax error at or near "NOT EXISTS"
-- 于是该 ALTER 无法写成可重复执行的幂等语句（项目约定：每个迁移必须能
-- 反复执行而不报错，scripts/db.py exec 与 CI 都依赖这一点）。
--
-- 替代方案：用**侧表** fam_grants(grant_id, group_id) 建立「授权 → 家庭组」
-- 归属关系。好处：
--   ① CREATE TABLE IF NOT EXISTS 天然幂等，不需要碰核心 ACL 表结构；
--   ② 家庭协作是可选能力，不该让 ACL 核心表承担它的列；
--   ③ 撤销整组授权 = 按 group_id 捞出 grant_id 再逐条置 revoked_at，
--      与单条撤销走同一语义，不引入第二套失效逻辑。
-- 代价：查「某组的授权」多一次 JOIN —— 组内授权量级（几十条）可忽略。
--
-- ------------------------------------------------------------
-- 安全约束（落到表结构上的部分）
-- ------------------------------------------------------------
--   · fam_invites **只存 code 的加盐摘要与 token 摘要**，绝不存明文；
--     明文只在创建响应里出现一次（服务端事后无法二次展示）。
--   · used_count / fail_count 落库 → 计数跨进程、跨重启有效；
--     达到上限即 revoked = TRUE（单向失效，不可恢复）。
--   · 家庭角色写在 fam_members.role，**不写 sys_user_roles** ——
--     入组不改变用户的全局权限，避免「入组即提权」。
--   · 唯一索引 (group_id, user_id) 保证并发接受同一邀请只成功一次。
--
-- ⚠️ 执行方式：普通 DDL（无 DO 块），可直接用 scripts/db.py 执行；
--    重复执行安全（CREATE ... IF NOT EXISTS，种子用 DELETE + INSERT SELECT）。
-- ============================================================

-- ---------- 1. 家庭组 ----------
CREATE TABLE IF NOT EXISTS fam_groups (
    id          BIGINT       PRIMARY KEY,
    name        VARCHAR(64)  NOT NULL,
    owner_id    BIGINT       NOT NULL,
    status      SMALLINT     NOT NULL DEFAULT 0,   -- 0 正常 / 1 已解散
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    version     INT          NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_fam_groups_owner ON fam_groups(owner_id, status);

COMMENT ON TABLE fam_groups IS '家庭组（FR-ACL-010）：协作的最小单元，一个用户可创建多个';
COMMENT ON COLUMN fam_groups.status IS '0=正常 1=已解散（解散只删成员与授权，不删任何条目）';

-- ---------- 2. 组成员 ----------
-- role 是**组内角色**，与全局 RBAC 解耦：不写 sys_user_roles。
CREATE TABLE IF NOT EXISTS fam_members (
    id          BIGINT       PRIMARY KEY,
    group_id    BIGINT       NOT NULL,
    user_id     BIGINT       NOT NULL,
    role        VARCHAR(16)  NOT NULL DEFAULT 'member',  -- owner / manager / member
    status      SMALLINT     NOT NULL DEFAULT 0,         -- 0 正常 / 1 已移除
    invited_by  BIGINT       NOT NULL DEFAULT 0,
    joined_at   TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    removed_at  TIMESTAMPTZ,
    removed_by  BIGINT
);

-- 唯一索引：并发接受同一邀请时，第二次插入必然冲突 → 只成功一次
CREATE UNIQUE INDEX IF NOT EXISTS uk_fam_members_group_user
    ON fam_members(group_id, user_id);
CREATE INDEX IF NOT EXISTS idx_fam_members_user ON fam_members(user_id, status);

COMMENT ON TABLE fam_members IS '家庭组成员（组内角色与全局 RBAC 解耦，入组不改变系统权限）';

-- ---------- 3. 邀请 ----------
-- code_hash = HMAC-SM3(salt, code)，code_salt 每邀请独立。
-- token_hash = HMAC-SM3(服务端密钥, 随机 token)，用于二维码链接。
CREATE TABLE IF NOT EXISTS fam_invites (
    id           BIGINT       PRIMARY KEY,
    group_id     BIGINT       NOT NULL,
    inviter_id   BIGINT       NOT NULL,
    code_hash    VARCHAR(128) NOT NULL,
    code_salt    VARCHAR(64)  NOT NULL,
    token_hash   VARCHAR(128) NOT NULL DEFAULT '',
    target_role  VARCHAR(16)  NOT NULL DEFAULT 'member',
    max_uses     INT          NOT NULL DEFAULT 1,
    used_count   INT          NOT NULL DEFAULT 0,
    fail_count   INT          NOT NULL DEFAULT 0,
    max_fails    INT          NOT NULL DEFAULT 5,
    expires_at   TIMESTAMPTZ  NOT NULL,
    revoked      BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_fam_invites_group
    ON fam_invites(group_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_fam_invites_expires
    ON fam_invites(expires_at) WHERE revoked = FALSE;
CREATE INDEX IF NOT EXISTS idx_fam_invites_token
    ON fam_invites(token_hash) WHERE token_hash <> '';

COMMENT ON TABLE fam_invites IS '家庭组邀请（只存 code/token 摘要，明文仅在创建响应出现一次）';
COMMENT ON COLUMN fam_invites.revoked IS '撤销或错误次数超限后的单向失效标记';

-- ---------- 4. 授权 → 家庭组 归属（替代 ALTER acl_grants） ----------
CREATE TABLE IF NOT EXISTS fam_grants (
    grant_id    BIGINT       PRIMARY KEY,
    group_id    BIGINT       NOT NULL,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_fam_grants_group ON fam_grants(group_id);

COMMENT ON TABLE fam_grants IS 'ACL 授权与家庭组的归属关系（用于按组撤销与审计聚合，不改动 acl_grants 结构）';

-- ---------- 5. 权限点：family:manage / family:invite ----------
-- 只授予 user 角色（所有登录用户都应能创建自己的家庭组）。
-- **不授予**任何管理角色 —— 否则管理员会被动获得他人家庭数据的入口。
-- ⚠️ 固定 ID 段占用情况（核对于 2026-10-29）：
--    sys_perms     ：已有 900001–900038，本迁移用 900101–900102；
--    sys_role_perms：已有 700001–7000xx 与若干雪花值，本迁移用 900111–900114。
--    固定 ID 是为了让「重复执行」可以靠 DELETE + INSERT 收敛，不需要 DO 块。
DELETE FROM sys_role_perms WHERE id IN (900111, 900112, 900113, 900114, 900115, 900116);

INSERT INTO sys_perms (id, code, name, domain, action, scope, description)
SELECT 900101, 'family:manage', '家庭组管理', 'family', 'manage', '',
       '创建/解散自己的家庭组，移除成员'
WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'family:manage');

INSERT INTO sys_perms (id, code, name, domain, action, scope, description)
SELECT 900102, 'family:invite', '家庭邀请与授权', 'family', 'invite', '',
       '生成/撤销邀请，对组内成员创建与撤销数据授权'
WHERE NOT EXISTS (SELECT 1 FROM sys_perms WHERE code = 'family:invite');

-- ------------------------------------------------------------
-- 授予哪些角色（**这里踩过一次坑，记下来**）
-- ------------------------------------------------------------
-- 初版写的是 `r.code = 'user'` —— 但系统里**没有** `user` 这个角色：
--   实际角色是 owner / curator / family / org_admin / auditor。
-- 于是那两条 INSERT ... SELECT 匹配到 0 行，静默不报错，
-- 表现就是「迁移成功、跑完没异常，但除了 owner 谁都建不了家庭组」。
-- 教训：权限种子的 SELECT 必须有一个「结果行数 > 0」的校验兜底，
--       见文件末尾的核对语句。
--
-- 现在的规则：**能建/改自己主体的人，才能建组**（subject:write:own）。
--   · owner   个人全权 —— 必须有；
--   · curator 代管人 —— 有自己名下的主体，需要把档案分享给家人；
--   · family  家庭成员 —— 是**被共享方**，不需要建组；
--             它不需要任何 family:* 权限，因为只读出口
--             /api/family/shared-items 刻意不挂功能权限
--             （见 FamilyRoutes 文件头：入组不改变全局权限）；
--   · org_admin / auditor —— 管理/审计视角，不该持有个人数据授权能力。
INSERT INTO sys_role_perms (id, role_id, perm_id)
SELECT 900111, r.id, p.id
FROM sys_roles r CROSS JOIN sys_perms p
WHERE r.code = 'owner' AND p.code = 'family:manage'
  AND NOT EXISTS (
      SELECT 1 FROM sys_role_perms rp WHERE rp.role_id = r.id AND rp.perm_id = p.id
  );

INSERT INTO sys_role_perms (id, role_id, perm_id)
SELECT 900112, r.id, p.id
FROM sys_roles r CROSS JOIN sys_perms p
WHERE r.code = 'owner' AND p.code = 'family:invite'
  AND NOT EXISTS (
      SELECT 1 FROM sys_role_perms rp WHERE rp.role_id = r.id AND rp.perm_id = p.id
  );

INSERT INTO sys_role_perms (id, role_id, perm_id)
SELECT 900113, r.id, p.id
FROM sys_roles r CROSS JOIN sys_perms p
WHERE r.code = 'curator' AND p.code = 'family:manage'
  AND NOT EXISTS (
      SELECT 1 FROM sys_role_perms rp WHERE rp.role_id = r.id AND rp.perm_id = p.id
  );

INSERT INTO sys_role_perms (id, role_id, perm_id)
SELECT 900114, r.id, p.id
FROM sys_roles r CROSS JOIN sys_perms p
WHERE r.code = 'curator' AND p.code = 'family:invite'
  AND NOT EXISTS (
      SELECT 1 FROM sys_role_perms rp WHERE rp.role_id = r.id AND rp.perm_id = p.id
  );

-- ---- 幂等核对：两个权限码必须真的授出去了 ----
-- 为什么不用 DO $$ ... $$ 块：`scripts/db.py exec` 按分号切语句
-- （scripts/db.py:71），PL/pgSQL 块体内的分号会被切断，整段语法破碎。
-- 改用「除零即报错」的单语句断言：任一绑定缺失 → division by zero，
-- 迁移显式失败，而不是静默地只授了一半。
SELECT 1 / CASE WHEN (
    SELECT COUNT(*) FROM sys_role_perms WHERE id IN (900111, 900112, 900113, 900114)
) > 0 THEN 1 ELSE 0 END AS family_perm_seed_check;

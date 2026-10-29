-- ============================================================
-- 018 · 条目共享链接（FR-ACL-011 / FR-ACL-012 · 方案 A）
--
-- 需求：
--   · FR-ACL-011 共享链接（公开只读）：链接主体为**条目**而非账户；
--   · FR-ACL-012 分享密码与次数限制：密码错误次数超限自动失效。
--
-- 安全设计：
--   · token 由服务端用**密钥 HMAC** 派生（不落明文凭据、不可预测），
--     唯一索引保证不重复；
--   · 密码只存 **加盐 HMAC-SM3** 摘要，绝不存明文；盐每链独立；
--   · fail_count / max_fails 落库：失败计数跨进程、跨重启有效；
--     达到上限后 revoked = TRUE，链接**立即失效**（不是仅提示）；
--   · expires_at 可为 NULL（不过期），但创建接口默认要求给出有效期；
--   · revoked 是**单向**标记：撤销后不可恢复，避免「先撤销再偷偷恢复」。
--
-- 公开访问只返回展示字段（标题/分类/签发机关/日期/状态），
-- 永不返回附件、扩展字段、条目标识或归属主体。
--
-- ⚠️ 执行方式：普通 DDL（无 DO 块），可直接用 scripts/db.py 执行；
--    重复执行安全（CREATE ... IF NOT EXISTS）。
-- ============================================================

CREATE TABLE IF NOT EXISTS arc_share_links (
    id             BIGINT       PRIMARY KEY,
    token          VARCHAR(64)  NOT NULL,
    item_id        BIGINT       NOT NULL,
    owner_id       BIGINT       NOT NULL,
    password_hash  VARCHAR(128) NOT NULL DEFAULT '',
    password_salt  VARCHAR(64)  NOT NULL DEFAULT '',
    fail_count     INT          NOT NULL DEFAULT 0,
    max_fails      INT          NOT NULL DEFAULT 5,
    expires_at     TIMESTAMPTZ,
    revoked        BOOLEAN      NOT NULL DEFAULT FALSE,
    view_count     BIGINT       NOT NULL DEFAULT 0,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_access_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS uk_arc_share_links_token
    ON arc_share_links(token);

CREATE INDEX IF NOT EXISTS idx_arc_share_links_item
    ON arc_share_links(item_id);

CREATE INDEX IF NOT EXISTS idx_arc_share_links_owner
    ON arc_share_links(owner_id);

COMMENT ON TABLE arc_share_links IS '条目共享链接（FR-ACL-011/012）：公开只读 + 可选密码 + 错误次数上限';
COMMENT ON COLUMN arc_share_links.fail_count IS '密码连续错误次数（成功后归零）';
COMMENT ON COLUMN arc_share_links.revoked IS '撤销/超限后的单向失效标记';

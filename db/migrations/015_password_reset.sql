-- ============================================================
-- 015 · 自助找回（FR-AUTH-008）：验证码 → 一次性重置令牌 → 强制下线
--
-- 设计要点：
--   · 一次「找回」只写一行：先用 code_* 字段承载验证码，
--     验证通过后同一行补上 token_* 字段承载重置令牌；
--     行内状态机 code_used / consumed 保证两步都是**一次性**；
--   · 只存 SM3 摘要，不存明文验证码/令牌（库被拖走也无法直接冒用）；
--     摘要加域前缀与 user_id 作盐（`pr:<uid>:<code>` / `tk:<token>`）；
--   · 时间一律用毫秒整数（与本仓其余表一致，避免 TIMESTAMPTZ 时区歧义）；
--   · attempts 只累计**验证码**错误次数，超 max_attempts 即作废该行，
--     防止 6 位数字被在线穷举；
--   · consumed_at 记录令牌被用掉的时刻，用于审计复盘。
--
-- ⚠️ 执行方式：普通 DDL（无 DO 块），可直接用 scripts/db.py 执行；
--    重复执行安全（CREATE ... IF NOT EXISTS）。
-- ============================================================

CREATE TABLE IF NOT EXISTS sys_password_reset (
    id               BIGINT       PRIMARY KEY,
    user_id          BIGINT       NOT NULL,
    code_hash        VARCHAR(128) NOT NULL,
    code_expires_at  BIGINT       NOT NULL,
    code_used        BOOLEAN      NOT NULL DEFAULT FALSE,
    attempts         SMALLINT     NOT NULL DEFAULT 0,
    max_attempts     SMALLINT     NOT NULL DEFAULT 5,
    token_hash       VARCHAR(128),
    token_expires_at BIGINT,
    consumed         BOOLEAN      NOT NULL DEFAULT FALSE,
    request_ip       VARCHAR(64)  NOT NULL DEFAULT '',
    request_agent    VARCHAR(256) NOT NULL DEFAULT '',
    -- 冷却期（60 秒内不允许重复索取）要在 SQL 里做数值比较，
    -- 故除 TIMESTAMPTZ 留档外再存一份毫秒整数，避免时区/类型转换风险。
    created_ms       BIGINT       NOT NULL,
    created_at       TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    consumed_ms      BIGINT       NOT NULL DEFAULT 0,
    consumed_at      TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_sys_password_reset_user
    ON sys_password_reset(user_id, code_used, consumed);

CREATE INDEX IF NOT EXISTS idx_sys_password_reset_token
    ON sys_password_reset(token_hash);

COMMENT ON TABLE sys_password_reset IS '自助找回验证码与一次性重置令牌（FR-AUTH-008）';
COMMENT ON COLUMN sys_password_reset.code_hash IS '验证码 SM3 摘要（盐=用户 ID，不存明文）';
COMMENT ON COLUMN sys_password_reset.token_hash IS '重置令牌 SM3 摘要（盐=固定域名前缀，不存明文）';
COMMENT ON COLUMN sys_password_reset.attempts IS '验证码错误次数（超 max_attempts 该行作废）';
COMMENT ON COLUMN sys_password_reset.consumed IS '重置令牌是否已被使用（一次性）';

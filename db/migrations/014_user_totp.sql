-- ============================================================
-- 014 · 双因子认证（TOTP，FR-AUTH-009）
--
-- 设计：
--   · 一个用户一条记录（唯一索引 user_id）：多设备绑定共用同一密钥，
--     与主流「一个账户一个 TOTP 密钥、多端各自录入」的模型一致；
--   · verified=FALSE 表示「已生成密钥但用户还没用动态码确认」，
--     此时登录**不**要求动态码（否则用户会被自己的半成品绑定锁死）；
--   · last_step 记录最近一次成功校验的时间步，用于**重放保护**：
--     同一个 30 秒窗口内的码只能用一次；
--   · secret_b32 明文存储：TOTP 需要原始密钥参与 HMAC，无法哈希。
--     因此该表属高敏数据，生产环境应配合磁盘加密 / 数据库 TDE。
--
-- ⚠️ 执行方式：本文件为普通 DDL（无 DO 块），可用 scripts/db.py 执行；
--    重复执行安全（CREATE ... IF NOT EXISTS）。
-- ============================================================

CREATE TABLE IF NOT EXISTS sys_user_totp (
    id          BIGINT       PRIMARY KEY,
    user_id     BIGINT       NOT NULL,
    secret_b32  VARCHAR(128) NOT NULL,
    digits      SMALLINT     NOT NULL DEFAULT 6,
    period      SMALLINT     NOT NULL DEFAULT 30,
    verified    BOOLEAN      NOT NULL DEFAULT FALSE,
    last_step   BIGINT       NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    verified_at TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS uk_sys_user_totp_user
    ON sys_user_totp(user_id);

COMMENT ON TABLE sys_user_totp IS '用户 TOTP 双因子密钥（FR-AUTH-009）';
COMMENT ON COLUMN sys_user_totp.last_step IS '最近一次校验通过的时间步（防重放）';

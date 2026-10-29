-- ============================================================
-- 011 · P1 邮件通知通道（FR-NTF-004）
--
-- 覆盖：
--   FR-NTF-004 邮件通知：到期提醒、共享通知、异常登录告警
--
-- 设计约束（关键）：
--   本仓不引第三方 SMTP 库，且本地无可用 SMTP 服务；
--   故邮件采用「**出站队列（outbox）**」模式：
--     Mailer.send() 只负责把邮件写入 ntf_email_outbox（status='queued'），
--     真正的外发由独立 worker（或配置 mail.enabled=true 时的发送器）从队列出队。
--   这样邮件「可追溯、可重试、幂等」，且主流程不阻塞。
--
--   配套配置种子（cfg_settings，scope=mail / audit）：
--     audit.retention_days —— 审计热表留存天数（FR-AUD-008，默认 180）
--     mail.enabled        —— 是否真正外发（默认 false，仅入队）
--     mail.smtp_host/port/from_addr —— 真实外发时填写
-- ============================================================

-- ---------- 邮件出站队列 ----------
CREATE TABLE IF NOT EXISTS ntf_email_outbox (
    id          BIGINT      PRIMARY KEY,
    to_addr     VARCHAR(254) NOT NULL,
    subject     VARCHAR(512) NOT NULL,
    body        TEXT         NOT NULL,
    status      VARCHAR(16)  NOT NULL DEFAULT 'queued',  -- queued | sent | failed
    attempts    INT          NOT NULL DEFAULT 0,
    last_error  TEXT,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sent_at     TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_ntf_email_outbox_status
    ON ntf_email_outbox(status, created_at DESC);
COMMENT ON TABLE ntf_email_outbox IS '邮件出站队列（FR-NTF-004，Mailer 入队，worker 出队外发）';

-- ---------- 配置种子：审计留存期（FR-AUD-008）----------
INSERT INTO cfg_settings (id, scope, key, value, value_type, is_secret, description, created_at, created_by, updated_at, updated_by)
SELECT 900100, 'audit', 'retention_days', '180', 'int', FALSE,
       '审计热表留存天数，到期后归档到冷存 aud_logs_archive（FR-AUD-008，可配置）',
       CURRENT_TIMESTAMP, 0, CURRENT_TIMESTAMP, 0
WHERE NOT EXISTS (SELECT 1 FROM cfg_settings WHERE scope = 'audit' AND key = 'retention_days');

-- ---------- 配置种子：邮件通道（FR-NTF-004，默认关闭仅入队）----------
INSERT INTO cfg_settings (id, scope, key, value, value_type, is_secret, description, created_at, created_by, updated_at, updated_by)
SELECT 900101, 'mail', 'enabled', 'false', 'bool', FALSE,
       '是否真正外发邮件；false 时 Mailer 仅入队 ntf_email_outbox（FR-NTF-004）',
       CURRENT_TIMESTAMP, 0, CURRENT_TIMESTAMP, 0
WHERE NOT EXISTS (SELECT 1 FROM cfg_settings WHERE scope = 'mail' AND key = 'enabled');

INSERT INTO cfg_settings (id, scope, key, value, value_type, is_secret, description, created_at, created_by, updated_at, updated_by)
SELECT 900102, 'mail', 'smtp_host', '', 'string', FALSE,
       'SMTP 主机（真实外发时填写）',
       CURRENT_TIMESTAMP, 0, CURRENT_TIMESTAMP, 0
WHERE NOT EXISTS (SELECT 1 FROM cfg_settings WHERE scope = 'mail' AND key = 'smtp_host');

INSERT INTO cfg_settings (id, scope, key, value, value_type, is_secret, description, created_at, created_by, updated_at, updated_by)
SELECT 900103, 'mail', 'smtp_port', '465', 'int', FALSE,
       'SMTP 端口',
       CURRENT_TIMESTAMP, 0, CURRENT_TIMESTAMP, 0
WHERE NOT EXISTS (SELECT 1 FROM cfg_settings WHERE scope = 'mail' AND key = 'smtp_port');

INSERT INTO cfg_settings (id, scope, key, value, value_type, is_secret, description, created_at, created_by, updated_at, updated_by)
SELECT 900104, 'mail', 'from_addr', 'ams@localhost', 'string', FALSE,
       '发件人地址',
       CURRENT_TIMESTAMP, 0, CURRENT_TIMESTAMP, 0
WHERE NOT EXISTS (SELECT 1 FROM cfg_settings WHERE scope = 'mail' AND key = 'from_addr');

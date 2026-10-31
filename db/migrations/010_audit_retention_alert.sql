-- ============================================================
-- 010 · P1 审计留存与告警
--
-- 覆盖：
--   FR-AUD-008 审计留存 ≥ 180 天，到期归档到冷存储（而非直接删除）
--   FR-AUD-007 高危操作实时告警（后台扫描后推送管理员）
--
-- 设计约束（关键）：
--   aud_logs 为**只追加、不可篡改**表（应用账号已被 REVOKE UPDATE/DELETE，
--   见 002_audit_schema_fix.sql），因此留存策略只能「冷存归档」——
--   把超期的热表记录**复制**到 aud_logs_archive（冷表），而非从热表删除。
--   热表保留全量以满足哈希链完整性；冷表是离线/冷存副本。
--
-- 归档幂等：以 id 为键，NOT EXISTS 跳过已归档记录，可重复执行。
-- ============================================================

-- ---------- 冷存归档表（与 aud_logs 同构 + archived_at）----------
CREATE TABLE IF NOT EXISTS aud_logs_archive (
    id           BIGINT      PRIMARY KEY,
    chain_seq    BIGINT      NOT NULL,
    actor_id     BIGINT,
    actor_type   SMALLINT    NOT NULL DEFAULT 0,
    action       VARCHAR(64) NOT NULL,
    action_desc  VARCHAR(256),
    target_type  VARCHAR(32),
    target_id    VARCHAR(64),
    subject_id   BIGINT,
    category     SMALLINT,
    result       SMALLINT    NOT NULL DEFAULT 0,
    error_code   VARCHAR(32),
    client_ip    VARCHAR(45),
    user_agent   VARCHAR(256),
    trace_id     VARCHAR(64),
    detail       JSONB,
    prev_hash    BYTEA       NOT NULL,
    record_hash  BYTEA       NOT NULL,
    occurred_ms  BIGINT,
    occurred_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    archived_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_aud_logs_archive_action
    ON aud_logs_archive(action, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_aud_logs_archive_time
    ON aud_logs_archive(occurred_at DESC);
COMMENT ON TABLE aud_logs_archive IS '审计冷存归档（FR-AUD-008，从 aud_logs 复制，热表保持不可篡改）';

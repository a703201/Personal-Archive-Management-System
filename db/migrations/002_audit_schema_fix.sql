-- ============================================================
-- AMS · 002_audit_schema_fix.sql
--
-- 目的：审计表结构按数据模型文档 §10.1 修正。
--   aud_logs：
--     - seq        → chain_seq
--     - result     由 VARCHAR 改为 SMALLINT（0=成功 1=失败 2=拒绝）
--     - prev_hash / record_hash 由 VARCHAR(64) 改为 BYTEA（存原始 SM3 摘要）
--     - 新增 actor_type / action_desc / error_code / occurred_at
--   aud_chain_anchors：
--     - 由「按 seq 锚定」改为「按日期锚定」（anchor_date + chain_head_hash）
--     - 用途：防「整链重写」攻击 —— 每日链头写到主库之外的位置
--
-- 说明：审计表**仅 INSERT**，故直接 DROP 重建是安全的
--       （生产环境应改用 ALTER TABLE ADD COLUMN 做在线迁移）。
-- ============================================================

DROP TABLE IF EXISTS aud_chain_anchors;
DROP TABLE IF EXISTS aud_logs;

CREATE TABLE aud_logs (
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
    prev_hash    BYTEA   NOT NULL,
    record_hash  BYTEA   NOT NULL,
    occurred_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX uk_aud_logs_chain_seq ON aud_logs(chain_seq);
CREATE UNIQUE INDEX uk_aud_logs_hash      ON aud_logs(record_hash);
CREATE INDEX idx_aud_logs_actor         ON aud_logs(actor_id, occurred_at DESC);
CREATE INDEX idx_aud_logs_subject       ON aud_logs(subject_id, occurred_at DESC);
CREATE INDEX idx_aud_logs_action        ON aud_logs(action, occurred_at DESC);
CREATE INDEX idx_aud_logs_result        ON aud_logs(result, occurred_at DESC);
CREATE INDEX idx_aud_logs_time          ON aud_logs(occurred_at DESC);
CREATE INDEX idx_aud_logs_trace         ON aud_logs(trace_id);

CREATE TABLE aud_chain_anchors (
    id             BIGINT      PRIMARY KEY,
    anchor_date    DATE        NOT NULL,
    chain_head_hash BYTEA  NOT NULL,
    record_count   BIGINT      NOT NULL,
    anchored_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    anchored_by    BIGINT,
    external_ref   VARCHAR(256)
);
CREATE UNIQUE INDEX uk_aud_chain_anchors_date ON aud_chain_anchors(anchor_date);

-- ============================================================
-- 审计表权限收紧（安全章 §10.1）：
--   应用账号只允许 SELECT / INSERT，不得 UPDATE / DELETE / TRUNCATE。
--   这从**数据库层**保证审计不可篡改（FR-AUD-006）。
--   说明：当前开发环境用超级用户 gaussdb 连接，应用账号待部署时创建。
-- ============================================================
-- REVOKE UPDATE, DELETE, TRUNCATE ON aud_logs FROM ams_app;
-- REVOKE ALL ON aud_logs FROM PUBLIC;
-- GRANT SELECT, INSERT ON aud_logs TO ams_app;

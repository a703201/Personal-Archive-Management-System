-- ============================================================
-- AMS · 迁移 004：审计记录补充「原始毫秒时间戳」列
--
-- 背景（实测 2026-10-26）：
--   审计哈希链的规范化包含 occurredAt 字段：
--     record_hash = SM3(prev_hash || 规范化记录)
--   落库时 occurredAt 由**应用层**取（Times.nowMillis()，整数毫秒），
--   而校验链时是从数据库的 occurred_at 列换算
--   （EXTRACT(EPOCH FROM occurred_at) * 1000 → numeric → CAST BIGINT）。
--   数据库存的是微秒精度，换算时会**四舍五入**，与原始毫秒值可能差 1，
--   导致重算哈希不匹配 → 链校验误报「broken」。
--
-- 解决：新增 occurred_ms BIGINT 列，**落库时写入应用层算出的毫秒值**，
--       链校验直接读该列 → 逐毫秒一致。
--       原 occurred_at 列保留（用于按时间范围查询与索引）。
--
-- ⚠️ openGauss 5.0.0 基于 PostgreSQL 9.2 内核，**不支持**
--    `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`（实测报错），
--    故这里用 DO 块做条件判断。
-- ============================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'aud_logs' AND column_name = 'occurred_ms'
    ) THEN
        ALTER TABLE aud_logs ADD COLUMN occurred_ms BIGINT;
    END IF;
END
$$;

-- 回填历史记录（用换算值近似；历史链的哈希是用当时的规则算的，
-- 旧记录的链校验可能仍报不一致 —— 这是预期行为，历史链本就不可重算）
UPDATE aud_logs
SET occurred_ms = CAST(EXTRACT(EPOCH FROM occurred_at) * 1000 AS BIGINT)
WHERE occurred_ms IS NULL;

-- 便于按时间范围查询（与 occurred_at 等价但类型更精确）
CREATE INDEX IF NOT EXISTS idx_aud_logs_occurred_ms ON aud_logs(occurred_ms DESC);

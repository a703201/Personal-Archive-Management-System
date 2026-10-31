-- ============================================================
-- 009 · P1 搜索与存储基础表
--
-- 覆盖：
--   FR-SRC-008 保存的筛选视图（命名视图，可置顶）
--   FR-SRC-009 搜索历史（个人，可清除，GDPR 友好）
--   FR-ATT-011 存储配额（按主体设配额，NULL = 跟随全局默认）
--
-- 全部语句幂等，可重复执行。
-- ============================================================

-- ---------- 1. 保存的筛选视图 ----------
CREATE TABLE IF NOT EXISTS arc_saved_views (
    id          BIGINT       PRIMARY KEY,
    owner_id    BIGINT       NOT NULL,
    name        VARCHAR(128) NOT NULL,
    query_json  TEXT         NOT NULL,
    is_pinned   BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at  TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_arc_saved_views_owner
    ON arc_saved_views(owner_id, is_pinned DESC, updated_at DESC);
COMMENT ON TABLE arc_saved_views IS '用户保存的命名筛选视图（FR-SRC-008）';

-- ---------- 2. 搜索历史 ----------
CREATE TABLE IF NOT EXISTS arc_search_history (
    id            BIGINT       PRIMARY KEY,
    owner_id      BIGINT       NOT NULL,
    query         VARCHAR(512) NOT NULL,
    hit_count     INTEGER      NOT NULL DEFAULT 0,
    last_used_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at    TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_arc_search_history_owner
    ON arc_search_history(owner_id, last_used_at DESC);
COMMENT ON TABLE arc_search_history IS '个人搜索历史（FR-SRC-009，可清除）';

-- ---------- 3. 存储配额（按主体）----------
-- NULL = 跟随全局默认（cfg_settings scope=storage, key=default_quota_bytes，
-- 若未配则服务端兜底 5 GiB）。
-- 注意：openGauss 不支持 `ADD COLUMN IF NOT EXISTS`，改用 DO 块做存在性判断。
DO $do$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'arc_subjects' AND column_name = 'quota_bytes'
    ) THEN
        ALTER TABLE arc_subjects ADD COLUMN quota_bytes BIGINT;
    END IF;
END $do$;
COMMENT ON COLUMN arc_subjects.quota_bytes IS '本主体存储配额（字节）；NULL=全局默认';

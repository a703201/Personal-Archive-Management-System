-- ============================================================
-- 012 · 条目历史版本（FR-ARCH-011）
--
-- 目的：
--   关键字段变更留存历史版本（快照），支持对比与回滚。
--
-- 设计：
--   · 每次「更新条目」前，把**更新前**的状态写入本表（version = 旧 version）。
--   · 唯一键 (item_id, version) 保证同一版本只留一份快照，重复写入幂等。
--   · snapshot 为 JSON 文本：title/category/status/sensitivity/issuedDate/
--     expiresAt/issuer/remark/extra/version。
--   · 回滚 = 先把当前状态快照一次，再用目标快照的内容执行一次普通更新
--     （version 继续递增，不破坏乐观锁与审计链）。
--
-- 全部语句幂等，可重复执行。
-- ============================================================

CREATE TABLE IF NOT EXISTS arc_item_versions (
    id           BIGINT       PRIMARY KEY,
    item_id      BIGINT       NOT NULL,
    version      INTEGER      NOT NULL,
    snapshot     TEXT         NOT NULL,
    change_note  VARCHAR(256),
    changed_by   BIGINT,
    changed_at   TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS uk_arc_item_versions
    ON arc_item_versions(item_id, version);

CREATE INDEX IF NOT EXISTS idx_arc_item_versions_item
    ON arc_item_versions(item_id, changed_at DESC);

COMMENT ON TABLE arc_item_versions IS '条目历史版本快照（FR-ARCH-011）';
COMMENT ON COLUMN arc_item_versions.snapshot IS '更新前状态的 JSON 快照';

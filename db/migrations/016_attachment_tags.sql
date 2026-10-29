-- ============================================================
-- 016 · 附件标签（FR-ATT-010 批量打标签）
--
-- 背景：既有标签只挂在「条目」上（arc_item_tags），附件维度没有任何
-- 标签载体，导致「批量给这批附件打标签」无处落地。
-- 这里新增独立的关联表，标签本身仍复用 arc_tags（重命名/合并/颜色
-- 等既有能力全部生效），只是把可用实体从 item 扩展到 attachment。
--
-- 设计：
--   · 唯一索引 (attachment_id, tag_id) → 重复打标签幂等，不用 ON CONFLICT；
--   · tag_id 侧建索引 → 「按标签反查附件」不走全表；
--   · created_by 记操作员，便于审计复盘是谁打的标签。
--
-- ⚠️ 执行方式：普通 DDL（无 DO 块），可直接用 scripts/db.py 执行；
--    重复执行安全（CREATE ... IF NOT EXISTS）。
-- ============================================================

CREATE TABLE IF NOT EXISTS arc_attachment_tags (
    id            BIGINT      PRIMARY KEY,
    attachment_id BIGINT      NOT NULL,
    tag_id        BIGINT      NOT NULL,
    created_by    BIGINT      NOT NULL DEFAULT 0,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS uk_arc_attachment_tags
    ON arc_attachment_tags(attachment_id, tag_id);

CREATE INDEX IF NOT EXISTS idx_arc_attachment_tags_tag
    ON arc_attachment_tags(tag_id);

COMMENT ON TABLE arc_attachment_tags IS '附件-标签关联（FR-ATT-010 批量打标签）';

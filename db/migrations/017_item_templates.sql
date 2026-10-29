-- ============================================================
-- 017 · 条目模板（FR-ARCH-012 · 方案 C：骨架 + 字段默认值）
--
-- 需求：常用条目一键套用模板批量创建。
--
-- 设计取舍（方案 C）：
--   · **条目骨架**：name/category/title/status/sensitivity/issuer/remark
--     决定「新建出来长什么样」；
--   · **字段默认值**：extra 存扩展字段的 JSON 默认值，套用时一并写入；
--   · **有效期偏移**：expires_offset_days > 0 时，以「套用当天 + N 天」
--     作为有效期 —— 模板里存绝对日期毫无意义（模板会长期复用）。
--   · 标题支持 `{n}` 序号占位，套用 N 条时替换为 1..N；
--     不含占位且 N > 1 时由应用层追加 ` (n)`，避免同名条目无法区分。
--
-- 归属：owner_id 为模板所有者，个人模板仅本人可见可用。
--       （机构共享模板属于 FR-IMP-005 的范畴，此处不混入。）
--
-- ⚠️ 执行方式：普通 DDL（无 DO 块），可直接用 scripts/db.py 执行；
--    重复执行安全（CREATE ... IF NOT EXISTS）。
-- ============================================================

CREATE TABLE IF NOT EXISTS arc_item_templates (
    id                  BIGINT       PRIMARY KEY,
    owner_id            BIGINT       NOT NULL,
    name                VARCHAR(100) NOT NULL,
    category            SMALLINT     NOT NULL,
    title               VARCHAR(200) NOT NULL,
    status              SMALLINT     NOT NULL DEFAULT 0,
    sensitivity         SMALLINT     NOT NULL DEFAULT 1,
    issuer              VARCHAR(128) NOT NULL DEFAULT '',
    remark              VARCHAR(1000) NOT NULL DEFAULT '',
    expires_offset_days INT          NOT NULL DEFAULT 0,
    extra               JSONB        NOT NULL DEFAULT '{}'::jsonb,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by          BIGINT       NOT NULL DEFAULT 0,
    updated_by          BIGINT       NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_arc_item_templates_owner
    ON arc_item_templates(owner_id);

COMMENT ON TABLE arc_item_templates IS '条目模板（FR-ARCH-012）：骨架 + 字段默认值，可批量套用';
COMMENT ON COLUMN arc_item_templates.expires_offset_days IS '有效期偏移天数（0 = 不设有效期）';
COMMENT ON COLUMN arc_item_templates.extra IS '扩展字段默认值 JSON';

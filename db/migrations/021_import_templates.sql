-- ============================================================
-- 021 · 导入模板（FR-IMP-005 · 方案 C：导入列 → 字段映射）
--
-- 背景：CSV 导入此前只能用固定列序
--   （subject_id,category,title,status,sensitivity,issued_date,
--    expires_at,issuer,remark）。用户手头的表格列名千差万别
--   （如「姓名」「发证机构」），每次都要手动重排，体验差。
--
-- 方案 C 复用 FR-ARCH-003/004 的字段定义域注册表：模板只描述
--   「CSV 表头 → 字段键」的映射，字段的值域 / 类型 / 枚举校验
--   由既有的 field_defs 提供。自定义字段（field_defs 中注册的）
--   同样经此通道落入 arc_item_fields（见 importservice.cj）。
--
-- 结构：
--   mapping  JSONB —— { "<csv表头>": "<字段键>" }
--                     字段键 ∈ 系统字段键（subject_id / category /
--                     title / status / sensitivity / issued_date /
--                     expires_at / issuer / remark）或该分类下已注册的
--                     自定义字段键。
--   defaults JSONB —— 系统字段未从 CSV 取到时的默认值，如
--                     {"subject_id":"0","category":"3",
--                      "status":"0","sensitivity":"1"}
--
-- 归属：owner_id 隔离，个人模板仅本人可见可用。
-- 执行方式：普通 DDL，可重复执行（IF NOT EXISTS）。
-- ============================================================

CREATE TABLE IF NOT EXISTS arc_import_templates (
    id          BIGINT       PRIMARY KEY,
    owner_id    BIGINT       NOT NULL,
    name        VARCHAR(100) NOT NULL,
    mapping     JSONB        NOT NULL DEFAULT '{}'::jsonb,
    defaults    JSONB        NOT NULL DEFAULT '{}'::jsonb,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    created_by  BIGINT       NOT NULL DEFAULT 0,
    updated_by  BIGINT       NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_arc_import_templates_owner
    ON arc_import_templates(owner_id);

COMMENT ON TABLE arc_import_templates IS '导入模板（FR-IMP-005）：CSV 表头 → 字段键映射 + 系统字段默认值';
COMMENT ON COLUMN arc_import_templates.mapping IS 'CSV 表头到字段键的映射 {csvHeader: fieldKey}';
COMMENT ON COLUMN arc_import_templates.defaults IS '系统字段未从 CSV 取到的默认值 {fieldKey: value}';

-- ============================================================
-- 020 · 附件手动摘要 / 关键词（FR-ATT-013 降级）
--
-- 背景：FR-ATT-013 全文 OCR 在本仓无 OCR 引擎、且涉及隐私显式同意，
--       降级为「手动录入摘要 / 关键词并随条目一起被检索索引」。
--       OCR 不在本仓实现，留作部署侧可选项。
-- 变更：arc_attachments 增加 summary / keywords 两列（空串默认，不破坏既有行）。
--
-- 【openGauss 兼容 · 重要】
--   openGauss 5.0.0 不支持 PostgreSQL 的
--     ALTER TABLE ... ADD COLUMN IF NOT EXISTS
--   实测报 `syntax error at or near "NOT EXISTS"`，会直接让迁移失败
--   （本迁移原先写法即在 openGauss 上报此错，导致 summary/keywords
--     长期未被建出 → 运行时报「数据库操作失败」）。
--   故改用 DO 块 + information_schema 存在性判断实现幂等，
--   与 022_tenant_isolation.sql 保持一致。
-- ============================================================
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'arc_attachments' AND column_name = 'summary'
    ) THEN
        ALTER TABLE arc_attachments ADD COLUMN summary TEXT NOT NULL DEFAULT '';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'arc_attachments' AND column_name = 'keywords'
    ) THEN
        ALTER TABLE arc_attachments ADD COLUMN keywords TEXT NOT NULL DEFAULT '';
    END IF;
END $$;

-- ============================================================
-- 020 · 附件手动摘要 / 关键词（FR-ATT-013 降级）
--
-- 背景：FR-ATT-013 全文 OCR 在本仓无 OCR 引擎、且涉及隐私显式同意，
--       降级为「手动录入摘要 / 关键词并随条目一起被检索索引」。
--       OCR 不在本仓实现，留作部署侧可选项。
-- 变更：arc_attachments 增加 summary / keywords 两列（空串默认，不破坏既有行）。
-- ============================================================
ALTER TABLE arc_attachments ADD COLUMN IF NOT EXISTS summary   TEXT NOT NULL DEFAULT '';
ALTER TABLE arc_attachments ADD COLUMN IF NOT EXISTS keywords  TEXT NOT NULL DEFAULT '';

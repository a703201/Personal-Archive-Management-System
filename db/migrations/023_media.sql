-- ============================================================
-- 023 · 附件媒体处理结果（OCR / 缩略图 / 像素水印）
--
-- 背景：纯仓颉媒体引擎（ams.core.media）已在进程内实现 PNG 的
--       OCR / 缩略图 / 像素水印，以及文本型 PDF 的文本抽取。
--       处理结果落库供列表 / 详情展示与 GET /ocr 读取。
--       OCR 需隐私显式同意（PRD FR-ATT-013）：自动处理仅在
--       AMS_MEDIA_ENABLED 与 AMS_OCR_CONSENT 同时为 true 时触发。
-- 变更：arc_attachments 增加 ocr_text / ocr_status / ocr_engine /
--       media_error 四列，均带非空默认值，不破坏既有行。
--
-- 【openGauss 兼容 · 重要】
--   openGauss 5.0.0 不支持 ADD COLUMN IF NOT EXISTS，故沿用
--   020_attachment_summary.sql 的 DO 块 + information_schema 幂等守卫。
-- ============================================================
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'arc_attachments' AND column_name = 'ocr_text'
    ) THEN
        ALTER TABLE arc_attachments ADD COLUMN ocr_text TEXT NOT NULL DEFAULT '';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'arc_attachments' AND column_name = 'ocr_status'
    ) THEN
        ALTER TABLE arc_attachments ADD COLUMN ocr_status SMALLINT NOT NULL DEFAULT 0;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'arc_attachments' AND column_name = 'ocr_engine'
    ) THEN
        ALTER TABLE arc_attachments ADD COLUMN ocr_engine VARCHAR(32) NOT NULL DEFAULT '';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'arc_attachments' AND column_name = 'media_error'
    ) THEN
        ALTER TABLE arc_attachments ADD COLUMN media_error TEXT NOT NULL DEFAULT '';
    END IF;
END $$;

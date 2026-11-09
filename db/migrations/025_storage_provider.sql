-- ============================================================
-- 025 · 多厂商存储平台标识（Q2 方案 A 扩展）
--
-- 背景：
--   `arc_attachments.storage_backend` 只有 0=fs / 1=s3 两个取值，
--   无法区分「同一类对象存储下的不同厂商」（华为云 OBS / 阿里云 OSS /
--   七牛 Kodo / 腾讯 COS / AWS S3 / MinIO）。切换平台时，
--   旧行的 storage_key 该去哪个 endpoint/bucket 找，必须有据可查。
--
-- 设计：
--   · 不改动 storage_backend 的既有语义（0/1 保持，零回归）；
--   · 新增 storage_provider 记录平台 code（见 StorageProviders）；
--   · 存量行由 DEFAULT 'local' 回填 —— 它们确实都在本地 FS；
--   · 侧表/视图均不涉及，本迁移只加一列。
--
-- 幂等性：openGauss 不支持 ADD COLUMN IF NOT EXISTS，
--   沿用 022 的 DO $$ + information_schema.columns 判定写法。
-- ============================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'arc_attachments' AND column_name = 'storage_provider'
    ) THEN
        ALTER TABLE arc_attachments
            ADD COLUMN storage_provider VARCHAR(32) NOT NULL DEFAULT 'local';
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_arc_attachments_provider
    ON arc_attachments (storage_provider);

COMMENT ON COLUMN arc_attachments.storage_backend IS
    '存储后端大类：0=本地 FS，1=对象存储（Q2 方案 A）';
COMMENT ON COLUMN arc_attachments.storage_provider IS
    '平台 code（StorageProviders）：local/minio/huawei/aliyun/qiniu/tencent/aws/s3';

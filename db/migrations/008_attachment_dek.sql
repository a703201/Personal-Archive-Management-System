-- ============================================================
-- AMS · 008_attachment_dek.sql
--
-- 目的：为附件加密存储补上「被包裹的数据密钥」落库位置（FR-ATT-003）。
--
-- 问题：
--   arc_attachments 只有 key_version（密钥版本号），**没有存放 DEK 的列**。
--   而 KeyManager.generateDataKey() 每次生成的是**随机** DEK，
--   仅凭 key_version 无法还原，附件上传后将永久无法解密。
--
-- 方案：新增 wrapped_dek 列，存放 WrappedKey 的文本化表示：
--     "<keyId>|<version>|<alg>|<base64(mac)>|<base64(ciphertext)>"
--   解密时按此格式还原 WrappedKey，再经 KeyManager.unwrap() 取回明文 DEK。
--
-- 为什么用 TEXT 而不是 BYTEA：
--   WrappedKey 自身没有定义二进制布局与序列化方法，
--   这里用「竖线分隔 + base64」是自描述且可调试的表示，
--   与项目既有做法一致（口令哈希用 "$sm3-pbkdf2$v1$..."、令牌用 base64url）。
--
-- 幂等：openGauss 5.0.0 **不支持** PostgreSQL 的
--   ALTER TABLE ... ADD COLUMN IF NOT EXISTS
--   （实测报 `syntax error at or near "NOT EXISTS"`，会让迁移整段失败）。
--   故改用 DO 块 + information_schema 存在性判断，保证可重复执行。
-- ============================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'arc_attachments' AND column_name = 'wrapped_dek'
    ) THEN
        ALTER TABLE arc_attachments ADD COLUMN wrapped_dek TEXT;
    END IF;
END $$;

-- ============================================================
-- 013 · 异步导出 / 批量导入任务扩展（FR-EXP-001/002/003/006、FR-IMP-001/002/003）
--
-- 背景：
--   imp_export_tasks 在 001_core_schema.sql 已建表，字段覆盖
--   task_no / task_type / status / total_count / done_count /
--   failed_count / params / result_path / error_msg。
--
-- 本次扩展三个字段：
--   · format     产物格式（csv / json / zip）—— 同步导出只有 csv，
--                异步任务需要区分，以便下载时给正确的 Content-Type。
--   · expires_at 产物过期时间（毫秒时间戳）。按 FR-EXP-003 为 7 天；
--                过期后 status 置 5（expired），下载返回 410。
--   · row_count  实际写出行数（total_count 在导入场景是「待处理行数」，
--                两者语义不同，不能复用）。
--
-- 为什么不加「进度百分比」列：
--   进度 = done_count / total_count，冗余列会带来写放大与不一致风险。
--
-- openGauss 5.0.0 不支持 `ADD COLUMN IF NOT EXISTS`（实测报错），
-- 故沿用 004 的 DO 块条件判断。
--
-- ⚠️ 执行方式：本文件含 DO 块，必须整文件执行，例如
--      docker exec -i ams_opengauss bash -lc \
--        'LD_LIBRARY_PATH=/usr/local/opengauss/lib:$LD_LIBRARY_PATH \
--         /usr/local/opengauss/bin/gsql -d <db> -p 5432 -f /tmp/013.sql'
--    或 CI 里的 cjpm/迁移工具。
--    `python scripts/db.py exec` 会按 `;` 切分语句，DO 块会被拆碎而整体失败
--    （004/005/009 同理），不要用它跑本文件。
--
-- 本文件在语义上幂等（重复执行不改结果），可安全多次整文件执行。
-- ============================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'imp_export_tasks' AND column_name = 'format'
    ) THEN
        ALTER TABLE imp_export_tasks ADD COLUMN format VARCHAR(16);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'imp_export_tasks' AND column_name = 'expires_at'
    ) THEN
        ALTER TABLE imp_export_tasks ADD COLUMN expires_at BIGINT;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'imp_export_tasks' AND column_name = 'row_count'
    ) THEN
        ALTER TABLE imp_export_tasks ADD COLUMN row_count INTEGER;
    END IF;
END
$$;

-- 过期清理与任务列表都按 (user_id, created_at) 扫，补一个状态索引
CREATE INDEX IF NOT EXISTS idx_imp_export_tasks_status
    ON imp_export_tasks(status, created_at);

CREATE INDEX IF NOT EXISTS idx_imp_export_tasks_expires
    ON imp_export_tasks(expires_at);

COMMENT ON COLUMN imp_export_tasks.format IS '产物格式：csv/json/zip（FR-EXP-001）';
COMMENT ON COLUMN imp_export_tasks.expires_at IS '产物过期毫秒时间戳（FR-EXP-003：7 天）';
-- 注：row_count 的 COMMENT 在本机 openGauss 5.0.0 上稳定报
-- 「column "row_count" of relation ... does not exist」（列实际已存在，
-- SELECT 可正常读到），属该版本对「同一批次内新增列再加注释」的限制。
-- 注释是纯文档性质，不承担任何约束，故此处不写，避免迁移脚本恒报失败。

-- ============================================================
-- 026 · 附件去重键唯一约束（P2 数据层工程债）
--
-- 背景：
--   业务层 findByDedupKey() 把 (subject_id, dedup_key) 当作「同主体内唯一」使用
--   （FR-ATT-002 秒传复用），但库里 001 迁移只建了普通索引
--   idx_arc_attachments_dedup(dedup_key)，并无唯一约束。并发上传同一文件时，
--   两个请求可能同时通过「先查后插」的竞态窗口，写出重复附件。
--
-- 设计：
--   · 唯一范围与业务一致：**同主体内**去重（MD-10），不是全局去重；
--   · 部分索引：dedup_key IS NOT NULL AND deleted_at IS NULL，
--     与查询条件完全对齐 —— 软删行不参与唯一性，回收站恢复不会撞约束；
--   · 不改动既有 idx_arc_attachments_dedup（它服务其它按 dedup_key 的查询）。
--
-- 幂等性：openGauss 不支持 CREATE UNIQUE INDEX IF NOT EXISTS，
--   沿用 025 的 DO $$ + 系统目录判定写法（此处查 pg_indexes）。
--
-- ⚠️ 【迁移前必读：历史重复数据】
--   若存量库已有重复的 (subject_id, dedup_key) 未删行，本迁移会**失败**
--   （这是期望行为：唯一约束不能在有重复数据时建立）。请先执行下面的检测，
--   人工确认保留行后再清理；**本脚本不会自动删除任何数据**。
--
--   检测（返回行即存在重复，需先处理）：
--     SELECT subject_id, dedup_key, COUNT(*) AS n,
--            array_agg(id ORDER BY id) AS ids
--     FROM arc_attachments
--     WHERE dedup_key IS NOT NULL AND deleted_at IS NULL
--     GROUP BY subject_id, dedup_key
--     HAVING COUNT(*) > 1
--     ORDER BY n DESC;
--
--   清理指引（人工核对后按需执行其一，均**不物理删除**）：
--     a) 保留最早一条，其余软删（保持可恢复性）：
--          UPDATE arc_attachments
--          SET deleted_at = CURRENT_TIMESTAMP, status = 9, updated_by = 0
--          WHERE id IN (
--              SELECT id FROM (
--                  SELECT id, ROW_NUMBER() OVER (
--                      PARTITION BY subject_id, dedup_key ORDER BY id ASC
--                  ) AS rn
--                  FROM arc_attachments
--                  WHERE dedup_key IS NOT NULL AND deleted_at IS NULL
--              ) t WHERE t.rn > 1
--          );
--     b) 若重复行各自挂了不同条目/版本，应先由业务合并版本再软删，
--        避免「秒传复用」指向被删对象。
--   确认检测 SELECT 返回 0 行后，再执行本迁移。
-- ============================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'arc_attachments'
          AND indexname = 'uk_arc_attachments_subject_dedup'
    ) AND NOT EXISTS (
        -- 有历史重复数据时跳过建索引：迁移不中断部署，但约束暂不生效；
        -- 按文件头检测/清理指引处理后重跑本脚本即可补建。
        SELECT 1 FROM (
            SELECT subject_id, dedup_key
            FROM arc_attachments
            WHERE dedup_key IS NOT NULL AND deleted_at IS NULL
            GROUP BY subject_id, dedup_key
            HAVING COUNT(*) > 1
        ) d
    ) THEN
        CREATE UNIQUE INDEX uk_arc_attachments_subject_dedup
            ON arc_attachments (subject_id, dedup_key)
            WHERE dedup_key IS NOT NULL AND deleted_at IS NULL;
    END IF;
END $$;

-- 索引语义：同主体内附件去重键唯一（仅未删除、dedup_key 非空行），
-- 与 findByDedupKey() 的查询条件完全对齐；软删行不参与唯一性。

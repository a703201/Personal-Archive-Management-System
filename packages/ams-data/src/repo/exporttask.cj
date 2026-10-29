// ============================================================
// ams.data.repo.exporttask · 导入/导出任务仓储（FR-EXP-001/002/003、FR-IMP-001/002）
//
// 表：imp_export_tasks（001_core_schema.sql 建表，013 增补 format/expires_at/row_count）
//
// 状态机（status）：
//   0 pending   已创建，等待 worker 领取
//   1 running   执行中（done_count 递增）
//   2 success   完成，result_path 指向产物
//   3 failed    失败，error_msg 说明原因
//   4 cancelled 用户取消
//   5 expired   产物已过期（下载返回 410）
//
// 设计要点：
//   · 状态流转全部走**带前置状态条件的 UPDATE**（WHERE status IN (...)），
//     并发下只有一个写入者能成功，天然避免「取消后又变成功」的竞态。
//   · task_no 是给用户看的短标识，id 是内部主键；对外一律用 task_no，
//     避免暴露自增规模。
// ============================================================
package ams.data.repo

import std.database.sql.*

import ams.data.db.*
import ams.kernel.error.*
import ams.kernel.id.*

/** 任务状态常量（与 DB 中 status 列一一对应） */
public class TaskStatus {
    public static let Pending: Int64 = 0
    public static let Running: Int64 = 1
    public static let Success: Int64 = 2
    public static let Failed: Int64 = 3
    public static let Cancelled: Int64 = 4
    public static let Expired: Int64 = 5
}

/**
 * 导入/导出任务仓储。
 */
public class ExportTaskRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /**
     * 创建任务（status = pending）。
     *
     * @param taskNo    对外任务号
     * @param taskType  export / import
     * @param userId    发起人
     * @param subjectId 主体范围（可空，导出为「当前用户可访问范围」的快照标识，不落具体 ID 列表）
     * @param format    产物格式
     * @param params    任务参数 JSON（筛选条件等）
     * @param total     预计总行数（未知填 0，运行时回填）
     * @param expiresAt 产物过期毫秒时间戳
     */
    public func create(
        taskNo: String,
        taskType: String,
        userId: Int64,
        subjectId: Option<Int64>,
        format: String,
        params: String,
        total: Int64,
        expiresAt: Int64
    ): Int64 {
        let id = Ids.next()
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "INSERT INTO imp_export_tasks " +
                "(id, task_no, task_type, user_id, subject_id, status, total_count, done_count, " +
                "failed_count, params, format, expires_at, row_count, created_at, updated_at) " +
                "VALUES (?, ?, ?, ?, ?, 0, ?, 0, 0, ?, ?, ?, 0, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
            )
            st.set(0, id)
            st.set(1, taskNo)
            st.set(2, taskType)
            st.set(3, userId)
            match (subjectId) {
                case Some(v) => st.set(4, v)
                case None => st.setNull(4)
            }
            st.set(5, total)
            st.set(6, params)
            st.set(7, format)
            st.set(8, expiresAt)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 按任务号查（对外接口的唯一入口） */
    public func findByNo(taskNo: String): ?RowData {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(SELECT_COLS + " WHERE task_no = ?")
            st.set(0, taskNo)
            let rows = readRows(st.query()).all()
            if (rows.size > 0) {
                return Some(rows[0])
            }
            return None
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 按主键查（worker 用） */
    public func findById(id: Int64): ?RowData {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(SELECT_COLS + " WHERE id = ?")
            st.set(0, id)
            let rows = readRows(st.query()).all()
            if (rows.size > 0) {
                return Some(rows[0])
            }
            return None
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 列出任务（本人）。
     *
     * @param userId   发起人
     * @param taskType 任务类型（空 = 全部）
     * @param limit    分页大小
     * @param offset   偏移
     */
    public func listOf(userId: Int64, taskType: String, limit: Int64, offset: Int64): RowSet {
        let c = this.db.connect()
        try {
            let cond = if (taskType.isEmpty()) { "" } else { " AND task_type = ? " }
            let st = c.prepareStatement(
                SELECT_COLS + " WHERE user_id = ?" + cond +
                " ORDER BY created_at DESC LIMIT ? OFFSET ?"
            )
            var i = 0
            st.set(i, userId); i = i + 1
            if (!taskType.isEmpty()) {
                st.set(i, taskType); i = i + 1
            }
            st.set(i, limit); i = i + 1
            st.set(i, offset)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 统计本人的任务数 */
    public func countOf(userId: Int64, taskType: String): Int64 {
        let c = this.db.connect()
        try {
            let cond = if (taskType.isEmpty()) { "" } else { " AND task_type = ? " }
            let st = c.prepareStatement(
                "SELECT CAST(COUNT(1) AS BIGINT) AS n FROM imp_export_tasks WHERE user_id = ?" + cond
            )
            var i = 0
            st.set(i, userId); i = i + 1
            if (!taskType.isEmpty()) {
                st.set(i, taskType)
            }
            let rows = readRows(st.query()).all()
            if (rows.size > 0) {
                return rows[0].i64("n")
            }
            return 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 领取任务：pending → running。
     *
     * @return true = 领取成功（本调用是唯一执行者）
     */
    public func claim(id: Int64, total: Int64): Bool {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "UPDATE imp_export_tasks SET status = 1, total_count = ?, updated_at = CURRENT_TIMESTAMP " +
                "WHERE id = ? AND status = 0"
            )
            st.set(0, total)
            st.set(1, id)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 进度回写（仅 running 生效，取消后不再覆盖） */
    public func updateProgress(id: Int64, done: Int64, failed: Int64): Unit {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "UPDATE imp_export_tasks SET done_count = ?, failed_count = ?, " +
                "updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status = 1"
            )
            st.set(0, done)
            st.set(1, failed)
            st.set(2, id)
            st.update()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 标记成功。
     *
     * @return true = 仍然处于 running（未被取消）
     */
    public func markSuccess(id: Int64, resultPath: String, rows: Int64, expiresAt: Int64): Bool {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "UPDATE imp_export_tasks SET status = 2, result_path = ?, row_count = ?, " +
                "total_count = ?, done_count = ?, failed_count = 0, expires_at = ?, " +
                "updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status = 1"
            )
            st.set(0, resultPath)
            st.set(1, rows)
            st.set(2, rows)
            st.set(3, rows)
            st.set(4, expiresAt)
            st.set(5, id)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 收尾（成功）：**一次性**写入总数 / 成功 / 失败，并置 status=2。
     *
     * 【为什么需要这个方法】
     *   旧流程是「markSuccess(...) 之后再 updateProgress(...) 回写失败数」，
     *   但 `updateProgress` 的 WHERE 条件是 `status = 1`，而 markSuccess
     *   已经把 status 置成 2 —— 回写**永远是空操作**。
     *   表现：CSV 导入里 fail 了 3 行，任务详情仍显示 failed=0、
     *   total=done，用户看不到失败；附件导入同理。
     *   把三组计数放进同一条 UPDATE，既正确又少一次往返。
     *
     * @return true = 仍然处于 running（未被取消）
     */
    public func finish(
        id: Int64,
        resultPath: String,
        total: Int64,
        done: Int64,
        failed: Int64,
        expiresAt: Int64
    ): Bool {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "UPDATE imp_export_tasks SET status = 2, result_path = ?, total_count = ?, " +
                "done_count = ?, failed_count = ?, row_count = ?, expires_at = ?, " +
                "updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status = 1"
            )
            st.set(0, resultPath)
            st.set(1, total)
            st.set(2, done)
            st.set(3, failed)
            st.set(4, done)
            st.set(5, expiresAt)
            st.set(6, id)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 标记失败（pending / running 都可转失败） */
    public func markFailed(id: Int64, errorMsg: String): Unit {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "UPDATE imp_export_tasks SET status = 3, error_msg = ?, " +
                "updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status IN (0, 1)"
            )
            st.set(0, errorMsg)
            st.set(1, id)
            st.update()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 取消任务：pending → cancelled；running → cancelled（worker 下次查状态即退出）。
     *
     * @return true = 本次取消生效
     */
    public func cancel(id: Int64): Bool {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "UPDATE imp_export_tasks SET status = 4, updated_at = CURRENT_TIMESTAMP " +
                "WHERE id = ? AND status IN (0, 1)"
            )
            st.set(0, id)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 是否已被取消（worker 分块循环内检查） */
    public func isCancelled(id: Int64): Bool {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement("SELECT status FROM imp_export_tasks WHERE id = ?")
            st.set(0, id)
            let rows = readRows(st.query()).all()
            if (rows.size > 0) {
                return rows[0].i64("status") == TaskStatus.Cancelled
            }
            return true
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 过期清理：success 且 expires_at < now → expired。
     *
     * @return 本次标记的条数（由调用方写日志；下载时也会逐条判过期）
     */
    public func purgeExpired(now: Int64): Int64 {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "UPDATE imp_export_tasks SET status = 5, updated_at = CURRENT_TIMESTAMP " +
                "WHERE status = 2 AND expires_at IS NOT NULL AND expires_at > 0 AND expires_at < ?"
            )
            st.set(0, now)
            return st.update().rowCount
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 崩溃恢复：把卡在 running 且超过阈值的任务置为失败。
     *
     * 进程重启后 running 的任务不会有人推进（worker 是进程内线程），
     * 如实标失败并让用户重试，好过永远转圈。
     */
    public func failStaleRunning(now: Int64, staleMillis: Int64): Int64 {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "UPDATE imp_export_tasks SET status = 3, " +
                "error_msg = COALESCE(error_msg, '任务执行超时（服务重启）'), " +
                "updated_at = CURRENT_TIMESTAMP " +
                "WHERE status = 1 AND " +
                "CAST(EXTRACT(EPOCH FROM updated_at) * 1000 AS BIGINT) < ?"
            )
            st.set(0, now - staleMillis)
            return st.update().rowCount
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    private static let SELECT_COLS: String =
        "SELECT id, task_no, task_type, " +
        "CAST(user_id AS BIGINT) AS user_id, " +
        "CAST(COALESCE(subject_id, 0) AS BIGINT) AS subject_id, " +
        "CAST(status AS BIGINT) AS status, " +
        "CAST(total_count AS BIGINT) AS total_count, " +
        "CAST(done_count AS BIGINT) AS done_count, " +
        "CAST(failed_count AS BIGINT) AS failed_count, " +
        "COALESCE(params::text, '{}') AS params, " +
        "COALESCE(format, 'csv') AS format, " +
        "COALESCE(result_path, '') AS result_path, " +
        "COALESCE(error_msg, '') AS error_msg, " +
        "CAST(COALESCE(expires_at, 0) AS BIGINT) AS expires_at, " +
        "CAST(COALESCE(row_count, 0) AS BIGINT) AS row_count, " +
        "CAST(EXTRACT(EPOCH FROM created_at) * 1000 AS BIGINT) AS created_ms, " +
        "CAST(EXTRACT(EPOCH FROM updated_at) * 1000 AS BIGINT) AS updated_ms " +
        "FROM imp_export_tasks"
}

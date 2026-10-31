// ============================================================
// ams.data.repo.system · 系统运维仓储（FR-CFG-005/006/007 支撑）
//
// 职责：
//   - 密钥版本登记表的读写（**只存元信息，绝不存密钥材料**）
//   - 健康看板所需的库内指标：存储用量、各表行数、DB 往返延迟
//
// 边界：
//   配置读写沿用 ConfigRepo；备份快照的**文件**落 StorageBackend，
//   其**索引**记在 cfg_settings（scope='backup'），避免为「列目录」
//   再引一层文件系统 API。
// ============================================================
package ams.data.repo

import std.collection.*
import std.database.sql.*

import ams.data.db.*

import ams.kernel.error.*
import ams.kernel.id.*
import ams.kernel.time.*

/**
 * 系统运维仓储。
 */
public class SystemRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    // ------------------------------------------------------------
    // 密钥版本（FR-CFG-007）
    // ------------------------------------------------------------

    /**
     * 登记一个新的密钥版本。
     *
     * @param purpose 用途标识（如 'attachment' / 'subject-name' / 'blind-index'）
     * @return 新记录 ID
     */
    public func addKeyVersion(
        keyId: String,
        version: Int64,
        alg: Int64,
        purpose: String,
        note: String,
        operatorId: Int64
    ): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO sys_key_versions " +
                  "(id, key_id, version, alg, purpose, status, note, created_at, created_by) " +
                  "VALUES (?, ?, ?, ?, ?, 1, ?, CURRENT_TIMESTAMP, ?)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, keyId)
            st.set(2, version)
            st.set(3, alg)
            st.set(4, purpose)
            st.set(5, note)
            st.set(6, operatorId)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 列出全部密钥版本（按创建时间倒序）。
     */
    public func listKeyVersions(): RowSet {
        let sql = "SELECT id, key_id, version, alg, purpose, status, note, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM created_at) * 1000, 0) AS BIGINT) AS created_ms, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM retired_at) * 1000, 0) AS BIGINT) AS retired_ms, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM revoked_at) * 1000, 0) AS BIGINT) AS revoked_ms " +
                  "FROM sys_key_versions ORDER BY created_at DESC, id DESC"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 取某用途当前处于 active 的最大版本号（没有则 0）。
     *
     * 用于轮换时确定「下一个版本号是多少」。
     */
    public func maxActiveVersion(keyId: String): Int64 {
        let sql = "SELECT COALESCE(MAX(version), 0) AS v FROM sys_key_versions " +
                  "WHERE key_id = ? AND status <> 3"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, keyId)
            let rows = readRows(st.query())
            if (rows.isEmpty()) {
                return 0
            }
            return rows.at(0).i64("v")
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 变更密钥状态。
     *
     * @param status 1=active 2=retired 3=revoked
     * @return false = 记录不存在
     *
     * 变更人由调用方写入**审计链**（FR-AUD-001），本表不冗余操作人字段：
     *   审计表是不可篡改的唯一事实来源，冗余一份反而可能与之不一致。
     */
    public func setKeyStatus(id: Int64, status: Int64): Bool {
        let sql = "UPDATE sys_key_versions SET status = ?, " +
                  "retired_at = CASE WHEN ? = 2 THEN CURRENT_TIMESTAMP ELSE retired_at END, " +
                  "revoked_at = CASE WHEN ? = 3 THEN CURRENT_TIMESTAMP ELSE revoked_at END " +
                  "WHERE id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, status)
            st.set(1, status)
            st.set(2, status)
            st.set(3, id)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    // ------------------------------------------------------------
    // 健康看板指标（FR-CFG-005）
    // ------------------------------------------------------------

    /**
     * 存储用量：附件总字节数与文件数。
     */
    public func storageUsage(): (Int64, Int64) {
        let sql = "SELECT COALESCE(SUM(file_size), 0) AS bytes, COUNT(*) AS files " +
                  "FROM arc_attachments WHERE deleted_at IS NULL"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            let rows = readRows(st.query())
            if (rows.isEmpty()) {
                return (0, 0)
            }
            return (rows.at(0).i64("bytes"), rows.at(0).i64("files"))
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 核心业务表的行数。
     *
     * 一次 UNION ALL 取回，避免逐表往返。
     */
    public func tableStats(): RowSet {
        let sql = "SELECT 'users' AS t, COUNT(*) AS n FROM sys_users WHERE deleted_at IS NULL " +
                  "UNION ALL SELECT 'subjects', COUNT(*) FROM arc_subjects WHERE deleted_at IS NULL " +
                  "UNION ALL SELECT 'items', COUNT(*) FROM arc_items WHERE deleted_at IS NULL " +
                  "UNION ALL SELECT 'attachments', COUNT(*) FROM arc_attachments WHERE deleted_at IS NULL " +
                  "UNION ALL SELECT 'audit', COUNT(*) FROM aud_logs " +
                  // 站内通知表是 nft_messages（见 NotifyRepo），不是 sys_notifications
                  "UNION ALL SELECT 'notifications', COUNT(*) FROM nft_messages"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 数据库往返延迟（毫秒）。
     *
     * 用最轻的 `SELECT 1` 计时 —— 它同时是「连接池是否还健康」的探针：
     *   连接耗尽 / 网络中断时这里会抛异常，看板据此显示 DB 不可用。
     */
    public func pingMillis(): Int64 {
        let t0 = Times.nowMillis()
        let c = this.db.connect()
        try {
            let st = c.prepareStatement("SELECT 1 AS ok")
            readRows(st.query())
            return Times.nowMillis() - t0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }
}

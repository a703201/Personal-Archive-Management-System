// ============================================================
// ams.data.repo.email · 邮件出站队列仓储
//
// 需求：
//   FR-NTF-004 邮件通知（到期提醒 / 共享通知 / 异常登录告警）
//
// [设计]
//   真实外发由独立 worker 负责；本仓储只负责「入队」与「统计」，
//   保证邮件可追溯、可重试、幂等，且不阻塞主流程。
// ============================================================
package ams.data.repo

import std.collection.*
import std.database.sql.*

import ams.data.db.*
import ams.kernel.error.*
import ams.kernel.id.*

/**
 * 邮件出站队列仓储。
 */
public class EmailRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /**
     * 入队一封邮件（status 默认 queued）。
     *
     * @return 新入队邮件的 id
     */
    public func enqueue(toAddr: String, subject: String, body: String): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO ntf_email_outbox (id, to_addr, subject, body, status, created_at) " +
                  "VALUES (?, ?, ?, ?, 'queued', CURRENT_TIMESTAMP)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, toAddr)
            st.set(2, subject)
            st.set(3, body)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 待发邮件数（status = 'queued'）。
     */
    public func countQueued(): Int64 {
        let sql = "SELECT COUNT(*) AS n FROM ntf_email_outbox WHERE status = 'queued'"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            let rows = readRows(st.query())
            if (rows.isEmpty()) {
                return 0
            }
            return rows.at(0).i64("n")
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }
}

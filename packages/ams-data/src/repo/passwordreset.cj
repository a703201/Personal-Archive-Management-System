// ============================================================
// ams.data.repo.passwordreset · 自助找回仓储（FR-AUTH-008）
//
// 表：sys_password_reset（见 db/migrations/015_password_reset.sql）
//
// 一行 = 一次找回流程，行内两步状态机：
//   ① code_used = FALSE 且 code_expires_at > now  → 可校验验证码
//   ② markCodeUsed + issueToken  → 可凭令牌重置
//   ③ consume → 令牌作废（一次性）
//
// 关键方法都是**带条件的 UPDATE**（`WHERE ... AND consumed = FALSE`），
// 靠返回的受影响行数判断是否抢到这次机会 —— 并发下只有一个调用者成功，
// 不需要额外加锁。
// ============================================================
package ams.data.repo

import std.database.sql.*

import ams.data.db.*
import ams.kernel.error.*
import ams.kernel.id.*

/**
 * 自助找回（验证码 / 重置令牌）仓储。
 */
public class PasswordResetRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /**
     * 新建一次找回流程。
     *
     * @param userId       目标用户
     * @param codeHash     验证码摘要
     * @param codeExpiresAt 验证码过期毫秒时间戳
     * @param maxAttempts  允许的最大错误次数
     * @param ip           请求来源 IP
     * @param agent        请求 UA
     * @return 新行 ID
     */
    public func create(
        userId: Int64,
        codeHash: String,
        codeExpiresAt: Int64,
        maxAttempts: Int64,
        ip: String,
        agent: String,
        now: Int64
    ): Int64 {
        let id = Ids.next()
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "INSERT INTO sys_password_reset " +
                "(id, user_id, code_hash, code_expires_at, code_used, attempts, max_attempts, " +
                "consumed, request_ip, request_agent, created_ms, created_at, consumed_ms) " +
                "VALUES (?, ?, ?, ?, FALSE, 0, ?, FALSE, ?, ?, ?, CURRENT_TIMESTAMP, 0)"
            )
            st.set(0, id)
            st.set(1, userId)
            st.set(2, codeHash)
            st.set(3, codeExpiresAt)
            st.set(4, maxAttempts)
            st.set(5, ip)
            st.set(6, agent)
            st.set(7, now)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 最近一次「还能验验证码」的流程（未用过、未过期、未超次数）。
     */
    public func latestCode(userId: Int64, now: Int64): ?RowData {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "SELECT id, CAST(user_id AS BIGINT) AS user_id, code_hash, " +
                "CAST(code_expires_at AS BIGINT) AS code_expires_at, " +
                "CAST(attempts AS BIGINT) AS attempts, " +
                "CAST(max_attempts AS BIGINT) AS max_attempts " +
                "FROM sys_password_reset " +
                "WHERE user_id = ? AND code_used = FALSE AND consumed = FALSE " +
                "AND code_expires_at > ? AND attempts < max_attempts " +
                "ORDER BY id DESC LIMIT 1"
            )
            st.set(0, userId)
            st.set(1, now)
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
     * 冷却期判断：统计 sinceMillis 之后新建的流程数。
     */
    public func countSince(userId: Int64, sinceMillis: Int64): Int64 {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "SELECT CAST(COUNT(1) AS BIGINT) AS n FROM sys_password_reset " +
                "WHERE user_id = ? AND created_ms >= ?"
            )
            st.set(0, userId)
            st.set(1, sinceMillis)
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
     * 验证码错误次数 +1。
     *
     * @return 累计后的次数
     */
    public func bumpAttempts(id: Int64): Int64 {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "UPDATE sys_password_reset SET attempts = attempts + 1 " +
                "WHERE id = ? AND consumed = FALSE"
            )
            st.set(0, id)
            st.update()
            let q = c.prepareStatement(
                "SELECT CAST(attempts AS BIGINT) AS attempts FROM sys_password_reset WHERE id = ?"
            )
            q.set(0, id)
            let rows = readRows(q.query()).all()
            if (rows.size > 0) {
                return rows[0].i64("attempts")
            }
            return 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 标记验证码已用掉（防止同一码换出多个令牌）。
     */
    public func markCodeUsed(id: Int64): Bool {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "UPDATE sys_password_reset SET code_used = TRUE " +
                "WHERE id = ? AND code_used = FALSE AND consumed = FALSE"
            )
            st.set(0, id)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 签发重置令牌（写摘要与有效期）。
     */
    public func issueToken(id: Int64, tokenHash: String, tokenExpiresAt: Int64): Bool {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "UPDATE sys_password_reset SET token_hash = ?, token_expires_at = ?, " +
                "attempts = 0 WHERE id = ? AND code_used = TRUE AND consumed = FALSE"
            )
            st.set(0, tokenHash)
            st.set(1, tokenExpiresAt)
            st.set(2, id)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 按令牌摘要查有效流程（未消费、未过期）。
     */
    public func findByTokenHash(tokenHash: String, now: Int64): ?RowData {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "SELECT id, CAST(user_id AS BIGINT) AS user_id " +
                "FROM sys_password_reset " +
                "WHERE token_hash = ? AND consumed = FALSE AND token_expires_at > ? " +
                "ORDER BY id DESC LIMIT 1"
            )
            st.set(0, tokenHash)
            st.set(1, now)
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
     * 消费令牌（一次性）：只有第一次调用能成功。
     */
    public func consume(id: Int64, now: Int64): Bool {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "UPDATE sys_password_reset SET consumed = TRUE, consumed_ms = ?, " +
                "consumed_at = CURRENT_TIMESTAMP WHERE id = ? AND consumed = FALSE"
            )
            st.set(0, now)
            st.set(1, id)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 作废某用户全部未消费流程（改完口令后清理残留）。
     */
    public func revokeAllOf(userId: Int64, now: Int64): Int64 {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "UPDATE sys_password_reset SET consumed = TRUE, consumed_ms = ? " +
                "WHERE user_id = ? AND consumed = FALSE"
            )
            st.set(0, now)
            st.set(1, userId)
            return st.update().rowCount
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 清理过期且未消费的历史行（避免表无限增长）。
     *
     * 保留 1 天内的行，便于审计复盘。
     */
    public func purgeExpired(now: Int64, keepMillis: Int64): Int64 {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "DELETE FROM sys_password_reset " +
                "WHERE consumed = FALSE AND code_expires_at < ? " +
                "AND (token_expires_at IS NULL OR token_expires_at < ?)"
            )
            st.set(0, now - keepMillis)
            st.set(1, now - keepMillis)
            return st.update().rowCount
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }
}

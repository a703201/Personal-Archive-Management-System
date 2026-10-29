// ============================================================
// ams.data.repo.sharelink · 共享链接仓储（FR-ACL-011 / FR-ACL-012）
//
// 关键语义：
//   · 密码只存加盐 HMAC-SM3 摘要，不存明文；
//   · fail_count / max_fails 落库 → 失败计数跨进程、跨重启有效；
//   · 达到上限即置 revoked = TRUE（单向失效，不可恢复）；
//   · expired 由 SQL 现算（不在应用层比较时间），避免时钟/时区口径分裂。
// ============================================================
package ams.data.repo

import std.collection.*
import std.database.sql.*

import ams.data.db.*

import ams.kernel.error.*
import ams.kernel.id.*

/**
 * 共享链接仓储。
 */
public class ShareLinkRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /**
     * 新建共享链接。
     *
     * @param expiresAt ISO8601 字符串；空串表示不过期（写入 NULL）
     */
    public func create(
        token: String,
        itemId: Int64,
        ownerId: Int64,
        passwordHash: String,
        passwordSalt: String,
        maxFails: Int64,
        expiresAt: String
    ): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO arc_share_links (" +
                  "id, token, item_id, owner_id, password_hash, password_salt, " +
                  "fail_count, max_fails, expires_at, revoked, view_count, created_at" +
                  ") VALUES (?, ?, ?, ?, ?, ?, 0, ?, CAST(? AS TIMESTAMPTZ), FALSE, 0, " +
                  "CURRENT_TIMESTAMP)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, token)
            st.set(2, itemId)
            st.set(3, ownerId)
            st.set(4, passwordHash)
            st.set(5, passwordSalt)
            st.set(6, maxFails)
            if (expiresAt.isEmpty()) {
                st.setNull(7)
            } else {
                st.set(7, expiresAt)
            }
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 按 token 查链接（公开访问用，不含归属过滤 —— 鉴权由 token 本身承担）。 */
    public func findByToken(token: String): Option<RowData> {
        let sql = "SELECT id, token, item_id, owner_id, password_hash, password_salt, " +
                  "fail_count, max_fails, revoked, view_count, " +
                  "CASE WHEN expires_at IS NOT NULL AND expires_at <= CURRENT_TIMESTAMP " +
                  "THEN TRUE ELSE FALSE END AS expired, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM expires_at) * 1000, 0) AS BIGINT) AS expires_ms " +
                  "FROM arc_share_links WHERE token = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, token)
            return readRows(st.query()).first()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 列出某用户的共享链接（最近创建在前）。 */
    public func listByOwner(ownerId: Int64, limit: Int64, offset: Int64): RowSet {
        let sql = "SELECT id, token, item_id, owner_id, " +
                  "fail_count, max_fails, revoked, view_count, " +
                  "CASE WHEN expires_at IS NOT NULL AND expires_at <= CURRENT_TIMESTAMP " +
                  "THEN TRUE ELSE FALSE END AS expired, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM expires_at) * 1000, 0) AS BIGINT) AS expires_ms, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM created_at) * 1000, 0) AS BIGINT) AS created_ms, " +
                  "CAST(COALESCE(EXTRACT(EPOCH FROM last_access_at) * 1000, 0) AS BIGINT) AS last_access_ms " +
                  "FROM arc_share_links WHERE owner_id = ? " +
                  "ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, ownerId)
            st.set(1, limit)
            st.set(2, offset)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 统计某用户的共享链接数。 */
    public func countByOwner(ownerId: Int64): Int64 {
        let sql = "SELECT COUNT(*) AS n FROM arc_share_links WHERE owner_id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, ownerId)
            let rows = readRows(st.query())
            match (rows.first()) {
                case Some(r) => return r.i64("n")
                case None => return 0
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 撤销（owner 归属校验在 WHERE 里；单向，不可恢复）。 */
    public func revoke(id: Int64, ownerId: Int64): Bool {
        let sql = "UPDATE arc_share_links SET revoked = TRUE WHERE id = ? AND owner_id = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, ownerId)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 记录一次成功访问。 */
    public func recordView(token: String): Unit {
        let sql = "UPDATE arc_share_links SET view_count = view_count + 1, " +
                  "last_access_at = CURRENT_TIMESTAMP WHERE token = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, token)
            st.update()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 记录一次密码错误，并在达到上限时撤销链接。
     *
     * 为什么用**一条** UPDATE 完成「自增 + 判定 + 撤销」：
     *   拆成「先自增、再读、再撤销」时，中间任一步之后进程被杀，就会留下
     *   `fail_count = max_fails` 但 `revoked = FALSE` 的链接 —— 攻击者白得一次
     *   尝试机会。SQL 里 `fail_count + 1 >= max_fails` 用的是**更新前的值**，
     *   因此判定与自增在同一条语句内自洽，不会出现这个中间态。
     *
     * @return 自增后的累计失败次数（读回用；即使读回值有并发偏差，
     *         撤销判定已在 UPDATE 内原子完成，不影响安全性）
     */
    public func bumpFail(token: String): Int64 {
        let bumpSql = "UPDATE arc_share_links SET " +
                      "fail_count = fail_count + 1, " +
                      "last_access_at = CURRENT_TIMESTAMP, " +
                      "revoked = CASE WHEN fail_count + 1 >= max_fails " +
                      "THEN TRUE ELSE revoked END " +
                      "WHERE token = ?"
        let readSql = "SELECT fail_count FROM arc_share_links WHERE token = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(bumpSql)
            st.set(0, token)
            st.update()

            let st2 = c.prepareStatement(readSql)
            st2.set(0, token)
            let rows = readRows(st2.query())
            match (rows.first()) {
                case Some(r) => return r.i64("fail_count")
                case None => return 0
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /** 密码校验成功后归零失败计数。 */
    public func resetFail(token: String): Unit {
        let sql = "UPDATE arc_share_links SET fail_count = 0 WHERE token = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, token)
            st.update()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }
}

// ============================================================
// ams.security.authn · 数据库会话存储 + 运行时共享状态 DB 句柄
//
// 用途（审查报告 P1-5「多副本承诺不成立」）：
//   DbSessionStore 把 SessionStore 的全部状态落到 sys_runtime_sessions /
//   sys_used_refresh_hashes，替代 MemorySessionStore 的进程内 HashMap，
//   使多副本之间会话可见、登出/重放检测全局生效。
//
//   RuntimeStateDb 是给其它「原本静态 + 进程内」的运行时状态组件
//   （LoginFailureCounter / CaptchaStore / ChunkUploadStore / Scheduler）
//   提供统一的可选 DB 句柄：
//     · 生产启动时调用 configure(db) → 走 DB，多副本共享；
//     · 未配置时这些组件退回各自原有的内存实现 → 单测零改动可用。
//
// 分层：ams.security.authn → ams.data.db / ams.data.repo（ams-data 先于
//   ams-security 构建，无反向依赖，无环）。
// ============================================================
package ams.security.authn

import std.collection.*
import std.database.sql.*

import stdx.encoding.hex.*

import ams.crypto.impl.*
import ams.crypto.provider.*

import ams.data.db.*
import ams.data.repo.*

import ams.kernel.error.*
import ams.kernel.time.*

/**
 * 运行时共享状态的可选 DB 句柄。
 *
 * 【为什么是静态 holder】CaptchaStore / ChunkUploadStore /
 * LoginFailureCounter 的公开方法全是 static，签名不能改（路由层直接调用）。
 * 注入 Database 的唯一低侵入方式就是一次性 configure。
 */
public class RuntimeStateDb {
    private static var dbOpt: Option<Database> = None

    /** 生产启动时调用一次：RuntimeStateDb.configure(db)。 */
    public static func configure(db: Database): Unit {
        RuntimeStateDb.dbOpt = Some(db)
    }

    /** 是否已配置 DB（未配置时各 store 走内存回退）。 */
    public static func isConfigured(): Bool {
        match (RuntimeStateDb.dbOpt) {
            case Some(_) => return true
            case None => return false
        }
    }

    /** 取已配置的 DB；未配置抛内部错误（调用方应先判 isConfigured）。 */
    public static func get(): Database {
        match (RuntimeStateDb.dbOpt) {
            case Some(d) => return d
            case None =>
                throw AppError(AppErrorKind.Internal,
                    "运行时状态存储未初始化：请先调用 RuntimeStateDb.configure(db)")
        }
    }

    /** 生成跨实例唯一的随机 token（ownerId / 上传 ID 后缀等）。 */
    public static func newToken(): String {
        let provider: CryptoProvider = StdxCryptoProvider()
        match (provider.randomBytes(12)) {
            case CryptoResult.Ok(b) => return toHexString(b)
            case CryptoResult.Err(_) =>
                throw AppError(AppErrorKind.Internal, "随机 token 生成失败")
        }
    }
}

/**
 * 数据库会话存储（SessionStore 的生产实现）。
 *
 * 所有方法都通过参数化 SQL 访问 DB；多副本共享同一张表，
 * 单点/全局登出与刷新令牌重放检测因此对所有实例生效。
 */
public class DbSessionStore <: SessionStore {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    // ------------------------------------------------------------
    // SessionStore 实现
    // ------------------------------------------------------------

    public func get(sid: String): ?Session {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "SELECT sid, uid, refresh_hash, revoked, created_at, last_active_at, ip, user_agent " +
                "FROM sys_runtime_sessions WHERE sid = ?"
            )
            st.set(0, sid)
            return DbSessionStore.toSession(readRows(st.query()).first())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    public func save(session: Session): Unit {
        let c = this.db.connect()
        try {
            let q = c.prepareStatement("SELECT 1 FROM sys_runtime_sessions WHERE sid = ?")
            q.set(0, session.sid)
            let exists = !readRows(q.query()).isEmpty()
            let st = if (exists) {
                let u = c.prepareStatement(
                    "UPDATE sys_runtime_sessions SET uid = ?, refresh_hash = ?, revoked = ?, " +
                    "last_active_at = ?, ip = ?, user_agent = ? WHERE sid = ?"
                )
                u.set(0, session.uid)
                u.set(1, session.refreshTokenHash)
                u.set(2, session.revoked)
                u.set(3, session.lastActiveAt)
                u.set(4, session.ip)
                u.set(5, session.userAgent)
                u.set(6, session.sid)
                u
            } else {
                let ins = c.prepareStatement(
                    "INSERT INTO sys_runtime_sessions " +
                    "(sid, uid, refresh_hash, revoked, created_at, last_active_at, ip, user_agent, tenant_id) " +
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, '')"
                )
                ins.set(0, session.sid)
                ins.set(1, session.uid)
                ins.set(2, session.refreshTokenHash)
                ins.set(3, session.revoked)
                ins.set(4, session.createdAt)
                ins.set(5, session.lastActiveAt)
                ins.set(6, session.ip)
                ins.set(7, session.userAgent)
                ins
            }
            st.update()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    public func listByUser(uid: String): Array<Session> {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "SELECT sid, uid, refresh_hash, revoked, created_at, last_active_at, ip, user_agent " +
                "FROM sys_runtime_sessions WHERE uid = ? ORDER BY created_at DESC"
            )
            st.set(0, uid)
            let rows = readRows(st.query())
            let out = ArrayList<Session>()
            for (r in rows.all().iterator()) {
                match (DbSessionStore.toSession(Some(r))) {
                    case Some(s) => out.add(s)
                    case None => ()
                }
            }
            return out.toArray()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    public func findByRefreshTokenHash(hash: String): ?Session {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "SELECT sid, uid, refresh_hash, revoked, created_at, last_active_at, ip, user_agent " +
                "FROM sys_runtime_sessions WHERE refresh_hash = ?"
            )
            st.set(0, hash)
            return DbSessionStore.toSession(readRows(st.query()).first())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    public func findUsedRefreshHash(hash: String): ?String {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "SELECT uid FROM sys_used_refresh_hashes WHERE hash = ?"
            )
            st.set(0, hash)
            match (readRows(st.query()).first()) {
                case Some(r) => return Some(r.str("uid"))
                case None => return None
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    public func markRefreshHashUsed(hash: String, uid: String): Unit {
        let c = this.db.connect()
        try {
            // openGauss 无 ON CONFLICT：先查后插（唯一主键兜底并发）。
            let q = c.prepareStatement("SELECT 1 FROM sys_used_refresh_hashes WHERE hash = ?")
            q.set(0, hash)
            if (!readRows(q.query()).isEmpty()) {
                return
            }
            let st = c.prepareStatement(
                "INSERT INTO sys_used_refresh_hashes (hash, uid, used_at) " +
                "SELECT ?, ?, ? WHERE NOT EXISTS " +
                "(SELECT 1 FROM sys_used_refresh_hashes WHERE hash = ?)"
            )
            st.set(0, hash)
            st.set(1, uid)
            st.set(2, Times.nowMillis())
            st.set(3, hash)
            st.update()
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    public func revokeAllByUser(uid: String): Int64 {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "UPDATE sys_runtime_sessions SET revoked = TRUE WHERE uid = ? AND revoked = FALSE"
            )
            st.set(0, uid)
            return st.update().rowCount
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    public func revoke(sid: String, uid: String): Bool {
        let c = this.db.connect()
        try {
            // uid 归属校验放在 WHERE 里：猜到 sid 也踢不掉别人的会话。
            let st = c.prepareStatement(
                "UPDATE sys_runtime_sessions SET revoked = TRUE " +
                "WHERE sid = ? AND uid = ? AND revoked = FALSE"
            )
            st.set(0, sid)
            st.set(1, uid)
            return st.update().rowCount > 0
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    public func revokeOthersByUser(uid: String, keepSid: String): Int64 {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "UPDATE sys_runtime_sessions SET revoked = TRUE " +
                "WHERE uid = ? AND sid <> ? AND revoked = FALSE"
            )
            st.set(0, uid)
            st.set(1, keepSid)
            return st.update().rowCount
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    public func activeCount(): Int64 {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "SELECT COUNT(*) AS n FROM sys_runtime_sessions WHERE revoked = FALSE"
            )
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

    // ------------------------------------------------------------
    // 额外运维方法（非接口要求）
    // ------------------------------------------------------------

    /** 已吊销会话数（测试/观测口径，含 revoked 行）。 */
    public func count(): Int64 {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement("SELECT COUNT(*) AS n FROM sys_runtime_sessions")
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

    /** 过期会话清理：简单 DELETE，由运维/启动钩子调用。 */
    public func cleanupExpired(beforeMillis: Int64): Int64 {
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(
                "DELETE FROM sys_runtime_sessions WHERE last_active_at < ?"
            )
            st.set(0, beforeMillis)
            let n = st.update().rowCount
            let st2 = c.prepareStatement(
                "DELETE FROM sys_used_refresh_hashes WHERE used_at < ?"
            )
            st2.set(0, beforeMillis)
            st2.update()
            return n
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    // ------------------------------------------------------------
    // 行 → Session
    // ------------------------------------------------------------
    private static func toSession(rowOpt: ?RowData): ?Session {
        match (rowOpt) {
            case Some(r) =>
                let s = Session(
                    r.str("sid"),
                    r.str("uid"),
                    r.str("refresh_hash"),
                    r.i64("created_at"),
                    r.str("ip"),
                    r.str("user_agent")
                )
                s.revoked = r.bool("revoked")
                s.lastActiveAt = r.i64("last_active_at")
                return Some(s)
            case None => return None
        }
    }
}

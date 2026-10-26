// ============================================================
// ams.security.authn · 内存会话存储
//
// 用途：
//   - 单元测试的会话存储实现
//   - 单机部署 / 开发环境的会话存储
//
// [注意] 生产环境必须换成数据库实现（ams-data），
//    内存版不持久化，进程重启即丢失所有会话。
// ============================================================
package ams.security.authn

import std.collection.*
import std.sync.*

/**
 * 内存会话存储。
 *
 * 线程安全：所有写操作加锁。
 */
public class MemorySessionStore <: SessionStore {
    private let sessions: HashMap<String, Session>
    private let lock: Mutex

    public init() {
        this.sessions = HashMap<String, Session>()
        this.lock = Mutex()
    }

    /**
     * 按会话 ID 取会话。
     */
    public func get(sid: String): ?Session {
        this.lock.lock()
        try {
            return this.sessions[sid]
        } finally {
            this.lock.unlock()
        }
    }

    /**
     * 保存/更新会话。
     */
    public func save(session: Session): Unit {
        this.lock.lock()
        try {
            this.sessions[session.sid] = session
        } finally {
            this.lock.unlock()
        }
    }

    /**
     * 按用户 ID 取全部会话。
     */
    public func listByUser(uid: String): Array<Session> {
        this.lock.lock()
        try {
            // Array 在仓颉里不可变且无 + 运算符，故用 ArrayList 收集
            let out = ArrayList<Session>()
            for ((_, s) in this.sessions) {
                if (s.uid == uid) {
                    out.add(s)
                }
            }
            return out.toArray()
        } finally {
            this.lock.unlock()
        }
    }

    /**
     * 按刷新令牌哈希查找会话。
     */
    public func findByRefreshTokenHash(hash: String): ?Session {
        this.lock.lock()
        try {
            for ((_, s) in this.sessions) {
                if (s.refreshTokenHash == hash) {
                    return Some(s)
                }
            }
            return None
        } finally {
            this.lock.unlock()
        }
    }

    /**
     * 吊销某用户的全部会话。
     */
    public func revokeAllByUser(uid: String): Int64 {
        this.lock.lock()
        try {
            var count: Int64 = 0
            for ((_, s) in this.sessions) {
                if (s.uid == uid && !s.revoked) {
                    s.revoked = true
                    count += 1
                }
            }
            return count
        } finally {
            this.lock.unlock()
        }
    }

    /**
     * 当前会话总数（测试用）。
     */
    public func count(): Int64 {
        this.lock.lock()
        try {
            return this.sessions.size
        } finally {
            this.lock.unlock()
        }
    }
}

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
     * 按会话 ID 取会话；不存在返回 None。
     *
     * 注意：仓颉 HashMap 的 `hm[key]` 在键不存在时**抛 NoneValueException**，
     * 不是返回 Option。此前这里直接 `return this.sessions[sid]`，
     * 于是「服务重启后内存会话表为空 + 客户端仍持旧令牌」这一常见场景
     * 会抛异常穿透中间件，返回裸 500 Internal Server Error
     * （而不是应有的 401「会话不存在」）。必须先 contains 再取。
     */
    public func get(sid: String): ?Session {
        this.lock.lock()
        try {
            if (!this.sessions.contains(sid)) {
                return None
            }
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

    /**
     * 吊销单个会话（FR-AUTH-007）。
     *
     * 【归属校验的必要性】
     *   sid 是 16 字节随机数，理论上不可猜；但「不可猜」不能替代鉴权 ——
     *   一旦某个 sid 通过日志/代理/截屏泄漏，缺少 uid 校验就等于
     *   任何人都能把它作废（DoS）。故这里强制比对 uid。
     */
    public func revoke(sid: String, uid: String): Bool {
        this.lock.lock()
        try {
            match (this.sessions.get(sid)) {
                case Some(s) =>
                    if (s.uid != uid || s.revoked) {
                        return false
                    }
                    s.revoked = true
                    return true
                case None => return false
            }
        } finally {
            this.lock.unlock()
        }
    }

    /**
     * 吊销某用户除 keepSid 之外的全部会话。
     */
    public func revokeOthersByUser(uid: String, keepSid: String): Int64 {
        this.lock.lock()
        try {
            var count: Int64 = 0
            for ((sid, s) in this.sessions) {
                if (s.uid == uid && sid != keepSid && !s.revoked) {
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
     * 未吊销会话数（在线用户口径，供健康看板）。
     */
    public func activeCount(): Int64 {
        this.lock.lock()
        try {
            var n: Int64 = 0
            for ((_, s) in this.sessions) {
                if (!s.revoked) {
                    n += 1
                }
            }
            return n
        } finally {
            this.lock.unlock()
        }
    }
}

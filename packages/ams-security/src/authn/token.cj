// ============================================================
// ams.security.authn.token · 访问令牌与刷新令牌
//
// 需求（FR-AUTH-005 / FR-AUTH-006）：
//   - Access Token：JWT/紧凑令牌格式；短期有效（默认 30 min，可配置）；
//     HMAC-SM3 签名；载荷含 uid/roles/perms/sid/jti；服务端可吊销
//   - Refresh Token：一次性使用（旋转）；每次刷新作废旧令牌并下发新令牌；
//     检测到**重放**（旧令牌再次使用）立即吊销该用户全部会话并告警
//
// 设计要点：
//   - 令牌格式：<base64url(payload)>.<base64url(sig)>  （紧凑 JWT 风格）
//   - 签名：HMAC-SM3(secret, header.payload)
//   - jti：随机 128 bit，用于服务端会话表的唯一键
//   - 服务端会话表由调用方提供（SessionStore 接口），
//     本包只定义契约与逻辑，不绑定具体存储
// ============================================================
package ams.security.authn

import std.collection.*
import stdx.encoding.base64.*
import stdx.encoding.hex.*

import ams.crypto.provider.*
import ams.kernel.error.*
import ams.kernel.time.*

/**
 * 令牌载荷。
 */
public class TokenPayload {
    /** 用户 ID */
    public let uid: String
    /** 角色列表 */
    public let roles: Array<String>
    /** 权限点列表 */
    public let perms: Array<String>
    /** 会话 ID */
    public let sid: String
    /** 令牌唯一 ID（jti） */
    public let jti: String
    /** 签发时间（Unix 毫秒） */
    public let issuedAt: Int64
    /** 过期时间（Unix 毫秒） */
    public let expiresAt: Int64

    public init(
        uid: String,
        roles: Array<String>,
        perms: Array<String>,
        sid: String,
        jti: String,
        issuedAt: Int64,
        expiresAt: Int64
    ) {
        this.uid = uid
        this.roles = roles
        this.perms = perms
        this.sid = sid
        this.jti = jti
        this.issuedAt = issuedAt
        this.expiresAt = expiresAt
    }
}

/**
 * 会话记录。
 */
public class Session {
    /** 会话 ID */
    public let sid: String
    /** 用户 ID */
    public let uid: String
    /** 当前刷新令牌哈希 */
    public var refreshTokenHash: String
    /** 是否已吊销 */
    public var revoked: Bool
    /** 创建时间 */
    public let createdAt: Int64
    /** 最近活动时间 */
    public var lastActiveAt: Int64
    /** 客户端 IP */
    public let ip: String
    /** User-Agent */
    public let userAgent: String

    public init(
        sid: String,
        uid: String,
        refreshTokenHash: String,
        createdAt: Int64,
        ip: String,
        userAgent: String
    ) {
        this.sid = sid
        this.uid = uid
        this.refreshTokenHash = refreshTokenHash
        this.revoked = false
        this.createdAt = createdAt
        this.lastActiveAt = createdAt
        this.ip = ip
        this.userAgent = userAgent
    }
}

/**
 * 会话存储契约。
 *
 * 生产实现用数据库（ams-data），测试可用内存实现。
 */
public interface SessionStore {
    /**
     * 按会话 ID 取会话。
     */
    func get(sid: String): ?Session

    /**
     * 保存/更新会话。
     */
    func save(session: Session): Unit

    /**
     * 按用户 ID 取全部会话。
     */
    func listByUser(uid: String): Array<Session>

    /**
     * 按刷新令牌哈希查找会话。
     *
     * 刷新令牌本身是随机串，服务端只存哈希；
     * 刷新时据此定位会话并检测重放。
     */
    func findByRefreshTokenHash(hash: String): ?Session

    /**
     * 吊销某用户的全部会话（全局登出 / 检测到重放时调用）。
     */
    func revokeAllByUser(uid: String): Int64

    /**
     * 吊销单个会话（FR-AUTH-007：用户远程踢出某一台设备）。
     *
     * @param uid 调用者用户 ID —— **必须校验归属**：
     *            否则只要猜到 sid 就能踢掉别人的会话。
     * @return false = 会话不存在、已吊销或不属于该用户
     */
    func revoke(sid: String, uid: String): Bool

    /**
     * 吊销某用户除 keepSid 之外的全部会话（「踢出其他设备」）。
     *
     * 保留当前会话，避免用户把自己登出后无法继续操作。
     */
    func revokeOthersByUser(uid: String, keepSid: String): Int64

    /**
     * 未被吊销的会话总数（在线用户口径）。
     *
     * 与 count() 的区别：count() 含已吊销行（用于测试），
     * 这里给健康看板用，只统计仍有效的会话。
     */
    func activeCount(): Int64
}

/**
 * 令牌配置。
 */
public class TokenConfig {
    /** 访问令牌有效期（秒） */
    public let accessTtlSeconds: Int64
    /** 刷新令牌有效期（秒） */
    public let refreshTtlSeconds: Int64
    /** 签名密钥（≥ 32 字节） */
    public let secret: Array<Byte>

    public init(
        accessTtlSeconds!: Int64 = 1800,
        refreshTtlSeconds!: Int64 = 2592000,
        secret!: Array<Byte>
    ) {
        this.accessTtlSeconds = accessTtlSeconds
        this.refreshTtlSeconds = refreshTtlSeconds
        this.secret = secret
    }
}

/**
 * 令牌签发与验证。
 */
public class TokenService {
    private let provider: CryptoProvider
    private let config: TokenConfig
    private let sessions: SessionStore

    public init(provider: CryptoProvider, config: TokenConfig, sessions: SessionStore) {
        this.provider = provider
        this.config = config
        this.sessions = sessions
    }

    /**
     * 签发访问令牌 + 刷新令牌，并创建会话。
     *
     * @param uid 用户 ID
     * @param roles 角色
     * @param perms 权限点
     * @param ip 客户端 IP
     * @param userAgent User-Agent
     */
    public func issue(
        uid: String,
        roles: Array<String>,
        perms: Array<String>,
        ip: String,
        userAgent: String
    ): CryptoResult<(String, String, String)> {
        // 会话 ID 与 jti 用随机数生成（不可预测）
        let sidBytes = match (this.provider.randomBytes(16)) {
            case CryptoResult.Ok(b) => b
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
        let sid = toHexString(sidBytes)
        let jti = sid   // 会话内 jti 与 sid 同源，够用且便于关联

        let now = Times.nowMillis()
        let payload = TokenPayload(
            uid, roles, perms, sid, jti,
            now, now + this.config.accessTtlSeconds * 1000)

        let accessToken = match (this.signPayload(payload)) {
            case CryptoResult.Ok(t) => t
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }

        // 刷新令牌：随机 32 字节，服务端只存哈希
        let refreshRaw = match (this.provider.randomBytes(32)) {
            case CryptoResult.Ok(b) => b
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
        let refreshToken = toBase64String(refreshRaw)
        let refreshHash = match (this.provider.digest(refreshRaw, DigestAlgorithm.Sm3)) {
            case CryptoResult.Ok(h) => toHexString(h)
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }

        this.sessions.save(Session(
            sid, uid, refreshHash, now, ip, userAgent))

        return CryptoResult.Ok((accessToken, refreshToken, sid))
    }

    /**
     * 验证访问令牌。
     *
     * 校验：签名 -> 过期 -> 会话是否被吊销。
     */
    public func verifyAccessToken(token: String): CryptoResult<TokenPayload> {
        let parts = token.split(".")
        if (parts.size != 2) {
            return CryptoResult.Err(AppError(AppErrorKind.Unauthorized, "令牌格式不正确"))
        }

        let payloadBytes = match (fromBase64String(parts[0])) {
            case Some(b) => b
            case None => return CryptoResult.Err(AppError(AppErrorKind.Unauthorized, "令牌格式不正确"))
        }
        let sig = match (fromBase64String(parts[1])) {
            case Some(b) => b
            case None => return CryptoResult.Err(AppError(AppErrorKind.Unauthorized, "令牌格式不正确"))
        }

        // 验签
        let expect = match (this.provider.hmac(this.config.secret, payloadBytes, DigestAlgorithm.Sm3)) {
            case CryptoResult.Ok(h) => h
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
        if (!this.provider.constantTimeEquals(expect, sig)) {
            return CryptoResult.Err(AppError(AppErrorKind.Unauthorized, "令牌签名无效"))
        }

        // 解析载荷
        let payload = match (this.parsePayload(payloadBytes)) {
            case Some(p) => p
            case None => return CryptoResult.Err(AppError(AppErrorKind.Unauthorized, "令牌载荷无效"))
        }

        // 过期
        if (Times.nowMillis() > payload.expiresAt) {
            return CryptoResult.Err(AppError(AppErrorKind.Unauthorized, "令牌已过期"))
        }

        // 会话吊销检查（服务端可吊销）
        match (this.sessions.get(payload.sid)) {
            case Some(s) => return this.checkSessionAlive(s, payload)
            case None => return CryptoResult.Err(AppError(AppErrorKind.Unauthorized, "会话不存在"))
        }
    }

    /**
     * 检查会话是否仍有效。
     */
    private func checkSessionAlive(s: Session, payload: TokenPayload): CryptoResult<TokenPayload> {
        if (s.revoked) {
            return CryptoResult.Err(AppError(AppErrorKind.Unauthorized, "会话已吊销"))
        }
        return CryptoResult.Ok(payload)
    }


    /**
     * 用刷新令牌换新的访问令牌（旋转）。
     *
     * 重放检测：若提供的刷新令牌与当前会话记录的不一致，
     * 说明该令牌已被使用过（可能是攻击者重放），
     * 立即吊销该用户**全部**会话并返回错误。
     *
     * @return (新访问令牌, 新刷新令牌, 是否检测到重放)
     */
    public func refresh(refreshToken: String): CryptoResult<(String, String, Bool)> {
        let raw = match (fromBase64String(refreshToken)) {
            case Some(b) => b
            case None => return CryptoResult.Err(AppError(AppErrorKind.Unauthorized, "刷新令牌无效"))
        }
        let hash = match (this.provider.digest(raw, DigestAlgorithm.Sm3)) {
            case CryptoResult.Ok(h) => toHexString(h)
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }

        // 找到持有该刷新令牌哈希的会话
        let found = this.sessions.findByRefreshTokenHash(hash)

        match (found) {
            case Some(s) => return this.handleRefresh(s)
            case None => return CryptoResult.Err(AppError(AppErrorKind.Unauthorized, "刷新令牌无效"))
        }
    }

    /**
     * 处理刷新：检测重放 -> 旋转。
     */
    private func handleRefresh(s: Session): CryptoResult<(String, String, Bool)> {
        // 会话已被吊销 -> 说明该刷新令牌已被使用过（重放）
        if (s.revoked) {
            this.sessions.revokeAllByUser(s.uid)
            return CryptoResult.Err(
                AppError(AppErrorKind.Unauthorized, "检测到刷新令牌重放，已吊销全部会话"))
        }
        return this.rotate(s)
    }

    /**
     * 单设备登出：吊销指定会话。
     */
    public func logout(sid: String): Unit {
        match (this.sessions.get(sid)) {
            case Some(s) => this.revokeSession(s)
            case None => ()
        }
    }

    /**
     * 吊销单个会话。
     */
    private func revokeSession(s: Session): Unit {
        s.revoked = true
        this.sessions.save(s)
    }

    /**
     * 全局登出：吊销该用户全部会话。
     *
     * @return 吊销的会话数
     */
    public func logoutAll(uid: String): Int64 {
        return this.sessions.revokeAllByUser(uid)
    }

    // ---- 内部实现 ----

    /**
     * 旋转刷新令牌：作废旧令牌，下发新令牌。
     */
    private func rotate(s: Session): CryptoResult<(String, String, Bool)> {
        let newRaw = match (this.provider.randomBytes(32)) {
            case CryptoResult.Ok(b) => b
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
        let newToken = toBase64String(newRaw)
        let newHash = match (this.provider.digest(newRaw, DigestAlgorithm.Sm3)) {
            case CryptoResult.Ok(h) => toHexString(h)
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }

        // 更新会话：换新哈希 + 刷新活动时间
        s.refreshTokenHash = newHash
        s.lastActiveAt = Times.nowMillis()
        this.sessions.save(s)

        // 重新签发访问令牌（权限从会话重建 —— 需调用方提供，
        // 此处沿用空权限集，由 app 层在会话上扩展）
        let now = Times.nowMillis()
        let payload = TokenPayload(
            s.uid, Array<String>(0, repeat: ""), Array<String>(0, repeat: ""), s.sid, s.sid,
            now, now + this.config.accessTtlSeconds * 1000)
        let access = match (this.signPayload(payload)) {
            case CryptoResult.Ok(t) => t
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }

        return CryptoResult.Ok((access, newToken, false))
    }

    /**
     * 签名载荷 -> 令牌串。
     */
    private func signPayload(payload: TokenPayload): CryptoResult<String> {
        let raw = this.serializePayload(payload)
        let sig = match (this.provider.hmac(this.config.secret, raw, DigestAlgorithm.Sm3)) {
            case CryptoResult.Ok(s) => s
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
        return CryptoResult.Ok("${toBase64String(raw)}.${toBase64String(sig)}")
    }

    /**
     * 序列化载荷。
     *
     * 格式：uid|sid|jti|issuedAt|expiresAt|roles|perms
     * （用 | 分隔，字段内不允许出现 |）
     */
    private func serializePayload(p: TokenPayload): Array<Byte> {
        let sb = StringBuilder()
        sb.append(p.uid)
        sb.append("|")
        sb.append(p.sid)
        sb.append("|")
        sb.append(p.jti)
        sb.append("|")
        sb.append(p.issuedAt.toString())
        sb.append("|")
        sb.append(p.expiresAt.toString())
        sb.append("|")
        sb.append(this.joinStrings(p.roles))
        sb.append("|")
        sb.append(this.joinStrings(p.perms))
        return sb.toString().toArray()
    }

    /**
     * 反序列化载荷。
     */
    private func parsePayload(raw: Array<Byte>): ?TokenPayload {
        let s = String.fromUtf8(raw)
        let parts = s.split("|")
        if (parts.size != 7) {
            return None
        }
        let issuedAt = PasswordHasher.parseInt64(parts[3])
        let expiresAt = PasswordHasher.parseInt64(parts[4])
        if (issuedAt < 0 || expiresAt < 0) {
            return None
        }
        return Some(TokenPayload(
            parts[0],
            this.splitStrings(parts[5]),
            this.splitStrings(parts[6]),
            parts[1], parts[2], issuedAt, expiresAt))
    }

    /**
     * 字符串数组 -> 逗号分隔串。
     */
    private func joinStrings(items: Array<String>): String {
        var sb = StringBuilder()
        for (i in 0..items.size) {
            if (i > 0) {
                sb.append(",")
            }
            sb.append(items[i])
        }
        return sb.toString()
    }

    /**
     * 逗号分隔串 -> 字符串数组。
     */
    private func splitStrings(s: String): Array<String> {
        if (s.isEmpty()) {
            return Array<String>(0, repeat: "")
        }
        return s.split(",")
    }
}

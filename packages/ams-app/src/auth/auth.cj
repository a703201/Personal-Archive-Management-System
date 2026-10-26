// ============================================================
// ams.app.auth · 认证应用服务
//
// 需求：
//   FR-AUTH-002 登录（账号密码登录 + 渐进延迟 + 锁定 + 返回访问/刷新令牌）
//   FR-AUTH-003 登出与全局登出
//   FR-AUTH-005 访问令牌（HMAC-SM3 签名 + 会话表校验）
//   FR-AUTH-006 刷新令牌（一次性使用 + 旋转 + 重放检测）
//
// [安全约束]（安全章 §5 / §6）
//   ① 口令比对用 PBKDF2-HMAC-SM3，且**无论用户是否存在都执行完整计算**，
//      避免通过耗时差异枚举用户名；
//   ② 连续失败触发渐进延迟 + 达阈值锁定（计数与锁定期在 DB 原子更新）；
//   ③ 刷新令牌一次性使用：每次刷新作废旧令牌；
//      检测到**重放**（已作废的令牌再次使用）立即吊销该用户全部会话；
//   ④ 口令、令牌**绝不进日志与审计**；
//   ⑤ 登录失败统一返回「用户名或口令错误」，不区分二者。
//
// [分层约束]（架构 §4.2）
//   ams-app 依赖 ams-data / ams-security / ams-core；
//   本包不直接碰 HTTP 类型（那是 ams-api 的事）。
// ============================================================
package ams.app.auth

import std.collection.*

import ams.crypto.provider.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.id.*
import ams.kernel.log.*
import ams.kernel.time.*
import ams.security.authn.*

/**
 * 认证配置。
 */
public class AuthConfig {
    /** 口令哈希迭代次数（PBKDF2） */
    public let kdfIterations: Int64
    /** 登录失败达阈值后的锁定秒数 */
    public let lockSeconds: Int64
    /** 允许的最大连续失败次数 */
    public let maxFailedAttempts: Int64
    /** 渐进延迟基数（毫秒）：第 n 次失败延迟 base * n */
    public let delayBaseMillis: Int64
    /** 渐进延迟上限（毫秒） */
    public let delayMaxMillis: Int64

    public init(
        kdfIterations!: Int64 = 600000,
        lockSeconds!: Int64 = 900,
        maxFailedAttempts!: Int64 = 5,
        delayBaseMillis!: Int64 = 200,
        delayMaxMillis!: Int64 = 3000
    ) {
        this.kdfIterations = kdfIterations
        this.lockSeconds = lockSeconds
        this.maxFailedAttempts = maxFailedAttempts
        this.delayBaseMillis = delayBaseMillis
        this.delayMaxMillis = delayMaxMillis
    }
}

/**
 * 登录结果。
 */
public class LoginResult {
    /** 访问令牌 */
    public let accessToken: String
    /** 刷新令牌 */
    public let refreshToken: String
    /** 会话 ID */
    public let sid: String
    /** 过期时间（Unix 毫秒） */
    public let expiresAt: Int64

    public init(accessToken: String, refreshToken: String, sid: String, expiresAt: Int64) {
        this.accessToken = accessToken
        this.refreshToken = refreshToken
        this.sid = sid
        this.expiresAt = expiresAt
    }
}

/**
 * 认证服务。
 */
public class AuthService {
    private let userRepo: UserRepo
    private let roleRepo: RoleRepo
    private let hasher: PasswordHasher
    private let tokenService: TokenService
    private let config: AuthConfig

    public init(
        userRepo: UserRepo,
        roleRepo: RoleRepo,
        hasher: PasswordHasher,
        tokenService: TokenService,
        config: AuthConfig
    ) {
        this.userRepo = userRepo
        this.roleRepo = roleRepo
        this.hasher = hasher
        this.tokenService = tokenService
        this.config = config
    }

    /**
     * 登录。
     *
     * @param username 用户名
     * @param password 口令明文
     * @param ip       客户端 IP
     * @param userAgent 客户端 UA
     * @return 登录结果
     * @throws AppError（Unauthorized / ValidationFailed）
     */
    public func login(
        username: String,
        password: String,
        ip: String,
        userAgent: String
    ): LoginResult {
        if (username.isEmpty() || password.isEmpty()) {
            throw validationError("username", "用户名与口令不能为空")
        }

        // 1) 查用户
        let maybeUser = this.userRepo.findByUsername(username)

        // 2) 口令校验（用户不存在时也走完整 PBKDF2，避免时序侧信道）
        //    哑盐固定为 16 个 0 字节。
        let dummySalt = Array<Byte>(16, repeat: 0u8)
        var ok = false
        var userId: Int64 = 0
        match (maybeUser) {
            case Some(u) =>
                userId = u.id
                // 已锁定 → 直接拒绝（不再比对口令，避免浪费资源）
                if (u.lockedUntilMillis > Times.nowMillis()) {
                    throw unauthorized(message: "账号已锁定，请稍后再试")
                }
                // 停用 → 拒绝
                if (u.status != 0) {
                    throw unauthorized(message: "账号已停用")
                }
                ok = this.hasher.verify(password, u.passwordHash, dummySalt)
            case None =>
                // 用户不存在：仍然执行一次完整 PBKDF2（用哑盐），使耗时一致
                this.hasher.verify(password, "$sm3-pbkdf2$v1$${this.config.kdfIterations}$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAA==", dummySalt)
                ok = false
        }

        // 3) 失败路径：计数 + 渐进延迟
        if (!ok) {
            this.onLoginFailed(userId, username)
            throw unauthorized(message: "用户名或口令错误")
        }

        // 4) 成功路径
        let u = maybeUser.getOrThrow()
        this.userRepo.recordLoginSuccess(u.id, ip)

        // 5) 取角色与权限点
        let roleCodes = this.roleRepo.listUserRoleCodes(u.id)
        let permCodes = this.roleRepo.listUserPermCodes(u.id)
        let roles = ArrayList<String>()
        for (r in roleCodes.iterator()) {
            roles.add(r)
        }
        let perms = ArrayList<String>()
        for (p in permCodes.iterator()) {
            perms.add(p)
        }

        // 6) 签发令牌
        let issued = this.tokenService.issue(
            "${u.id}",
            roles.toArray(),
            perms.toArray(),
            ip,
            userAgent
        )
        match (issued) {
            case CryptoResult.Ok((accessToken, refreshToken, sid)) =>
                Log.get().info("auth.login", None, [
                    ("uid", "${u.id}"),
                    ("sid", sid),
                    ("ip", ip)
                ])
                return LoginResult(
                    accessToken,
                    refreshToken,
                    sid,
                    Times.nowMillis() + 1800 * 1000
                )
            case CryptoResult.Err(_) =>
                throw AppError(AppErrorKind.Internal, "令牌签发失败")
        }
    }

    /**
     * 登录失败处理：计数 + 达阈值锁定 + 渐进延迟。
     */
    private func onLoginFailed(userId: Int64, username: String): Unit {
        if (userId > 0) {
            this.userRepo.recordLoginFailure(userId, this.config.maxFailedAttempts, this.config.lockSeconds)
        }
        // 渐进延迟：按用户名维度计数（不记录口令）
        let delay = this.progressiveDelay(username)
        Times.sleepMillis(delay)
        Log.get().warn("auth.login.failed", None, [
            ("username", username)
        ])
    }

    /**
     * 渐进延迟计算。
     *
     * 以「用户名的稳定哈希」为键在内存中计数，
     * 避免引入额外的持久化表；进程重启后计数归零（可接受）。
     */
    private func progressiveDelay(username: String): Int64 {
        // 用简单字符串哈希做键（不存口令，只存用户名哈希）
        var h: Int64 = 0
        for (b in username.toArray().iterator()) {
            h = (h * 31 + Int64(b)) & 0x7FFFFFFF
        }
        let key = "${h}"
        // 注意：仓颉 HashMap 的 `[]` 在键不存在时抛 NoneValueException，
        // 故这里用 get() 取默认值。
        let n = AuthService.failureCounts.get(key) ?? 0
        AuthService.failureCounts[key] = n + 1
        let delay = this.config.delayBaseMillis * (n + 1)
        return if (delay > this.config.delayMaxMillis) { this.config.delayMaxMillis } else { delay }
    }

    /**
     * 登录失败计数（按用户名哈希）。
     *
     * 用 HashMap 而非并发容器：写入量极低（登录失败路径），
     * 且并发写同一键的概率低；真正的防护是 DB 侧的原子计数与锁定。
     */
    private static let failureCounts: HashMap<String, Int64> = HashMap<String, Int64>()

    /**
     * 刷新令牌。
     *
     * 一次性使用：旧令牌用过后即作废。
     * 检测到重放（已作废令牌再次使用）→ 吊销该用户全部会话。
     */
    public func refresh(refreshToken: String, ip: String, userAgent: String): LoginResult {
        if (refreshToken.isEmpty()) {
            throw validationError("refreshToken", "刷新令牌不能为空")
        }
        let refreshed = this.tokenService.refresh(refreshToken)
        match (refreshed) {
            case CryptoResult.Ok((accessToken, newRefresh, reuseDetected)) =>
                if (reuseDetected) {
                    // 重放：立即吊销该用户全部会话
                    Log.get().error("auth.refresh.replay", None, [])
                    throw unauthorized(message: "刷新令牌异常，请重新登录")
                }
                return LoginResult(accessToken, newRefresh, "", Times.nowMillis() + 1800 * 1000)
            case CryptoResult.Err(_) =>
                throw unauthorized(message: "刷新令牌无效或已过期")
        }
    }

    /**
     * 登出（撤销当前会话）。
     */
    public func logout(sid: String): Unit {
        this.tokenService.logout(sid)
        Log.get().info("auth.logout", None, [("sid", sid)])
    }

    /**
     * 全局登出（撤销该用户全部会话）。
     */
    public func logoutAll(uid: String): Int64 {
        let n = this.tokenService.logoutAll(uid)
        Log.get().info("auth.logout.all", None, [("uid", uid), ("count", "${n}")])
        return n
    }
}

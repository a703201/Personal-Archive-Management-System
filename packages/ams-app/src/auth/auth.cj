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
import std.sync.*

import ams.app.audit.*
import ams.crypto.provider.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.id.*
import ams.kernel.log.*
import ams.kernel.time.*
import ams.security.audit.*
import ams.security.authn.*
import ams.security.totp.*

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
    /**
     * 触发图形验证码所需的连续登录失败次数（FR-AUTH-011）。
     *
     * 与「锁定阈值」maxFailedAttempts 解耦：先在较少的失败次数上叠加
     * 图形验证码这道摩擦（默认 3），达到锁定阈值才真正锁账号（默认 5）。
     */
    public let captchaTriggerFailures: Int64

    public init(
        kdfIterations!: Int64 = 600000,
        lockSeconds!: Int64 = 900,
        maxFailedAttempts!: Int64 = 5,
        delayBaseMillis!: Int64 = 200,
        delayMaxMillis!: Int64 = 3000,
        captchaTriggerFailures!: Int64 = 3
    ) {
        this.kdfIterations = kdfIterations
        this.lockSeconds = lockSeconds
        this.maxFailedAttempts = maxFailedAttempts
        this.delayBaseMillis = delayBaseMillis
        this.delayMaxMillis = delayMaxMillis
        this.captchaTriggerFailures = captchaTriggerFailures
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
    /** 口令策略校验器（FR-AUTH-004 / FR-AUTH-001 注册复用） */
    private let passwordValidator: PasswordValidator
    /**
     * 审计记录器（FR-AUD-001）。
     *
     * 可选：未装配时**不影响**认证功能（便于单元测试与工具场景）。
     */
    private let recorder: ?AuditRecorder
    /**
     * TOTP 仓储（FR-AUTH-009）。
     *
     * 可选：未装配时退化为「口令单因子」，便于测试与工具场景。
     */
    private let totpRepo: ?TotpRepo

    public init(
        userRepo: UserRepo,
        roleRepo: RoleRepo,
        hasher: PasswordHasher,
        tokenService: TokenService,
        config: AuthConfig,
        passwordValidator: PasswordValidator,
        recorder!: ?AuditRecorder = None,
        totpRepo!: ?TotpRepo = None
    ) {
        this.userRepo = userRepo
        this.roleRepo = roleRepo
        this.hasher = hasher
        this.tokenService = tokenService
        this.config = config
        this.passwordValidator = passwordValidator
        this.recorder = recorder
        this.totpRepo = totpRepo
    }

    /**
     * 记录一条审计（未装配记录器时静默跳过）。
     */
    private func audit(
        actorId: String,
        action: AuditAction,
        targetType: String,
        targetId: String,
        result: AuditResult,
        errorCode: String,
        ip: String,
        userAgent: String
    ): Unit {
        match (this.recorder) {
            case Some(r) =>
                r.record(
                    actorId,
                    ActorType.User,
                    action,
                    targetType,
                    targetId,
                    "",
                    0,
                    result,
                    errorCode,
                    ip,
                    userAgent,
                    "",
                    Array<(String, String)>()
                )
            case None => ()
        }
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
        userAgent: String,
        totpCode!: String = ""
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
            // FR-AUD-001：登录失败必须留痕
            this.audit("${userId}", AuditAction.LoginFailed, "user", username,
                       AuditResult.Failure, "AUTH_FAILED", ip, userAgent)
            throw unauthorized(message: "用户名或口令错误")
        }

        // 3.5) 双因子（FR-AUTH-009）：口令正确后、签发令牌前校验
        let u = maybeUser.getOrThrow()
        this.checkTotp(u.id, username, totpCode, ip, userAgent)

        // 4) 成功路径
        this.userRepo.recordLoginSuccess(u.id, ip)
        // FR-AUTH-011：登录成功即清零「连续失败」内存计数，
        // 保证验证码只在连续失败达到阈值后触发，成功一次后重新开始计。
        this.resetFailureCount(username)

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

        // FR-AUD-001：登录成功留痕
        this.audit("${u.id}", AuditAction.Login, "user", username,
                   AuditResult.Success, "", ip, userAgent)

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
    /**
     * 双因子校验（FR-AUTH-009）。
     *
     * 只在「已绑定且已验证」时生效：用户若只跑过 setup 没完成确认，
     * 登录不受影响（否则半成品绑定会把人锁在门外）。
     *
     * 重放保护：同一 30 秒时间步只允许成功一次（touchStep 条件更新）。
     */
    private func checkTotp(userId: Int64, username: String, code: String, ip: String, ua: String): Unit {
        let repo = match (this.totpRepo) {
            case Some(r) => r
            case None => return
        }
        let rec = match (repo.find(userId)) {
            case Some(r) => r
            case None => return
        }
        if (!rec.bool("verified")) {
            return
        }
        if (code.trimAscii().isEmpty()) {
            this.audit("${userId}", AuditAction.LoginFailed, "user", username,
                       AuditResult.Denied, "TOTP_REQUIRED", ip, ua)
            throw AppError(AppErrorKind.Unauthorized, "该账号已启用双因子，请输入 6 位动态码")
        }
        let step = Totp.verify(rec.str("secret_b32"), code, Times.nowMillis(), 1)
        if (step < 0) {
            this.audit("${userId}", AuditAction.LoginFailed, "user", username,
                       AuditResult.Failure, "TOTP_INVALID", ip, ua)
            throw AppError(AppErrorKind.Unauthorized, "动态码不正确或已过期")
        }
        if (!repo.touchStep(userId, step)) {
            this.audit("${userId}", AuditAction.LoginFailed, "user", username,
                       AuditResult.Denied, "TOTP_REPLAY", ip, ua)
            throw AppError(AppErrorKind.Unauthorized, "该动态码已使用，请等待下一次刷新")
        }
    }

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
        // 用用户名的稳定哈希做键（不存口令，只存用户名哈希）。
        // 【并发安全】计数器的读写全部经 Mutex 串行化，见 LoginFailureCounter；
        // 此前直接读写无锁 HashMap，并发登录会破坏哈希桶结构导致 get() 死循环，
        // 占死工作线程并连锁拖垮整个 stdx 线程池（2026-11-11 全局 dead lock）。
        let n = LoginFailureCounter.increment(
            AuthService.failureKey(username), Times.nowMillis())
        let delay = this.config.delayBaseMillis * n
        return if (delay > this.config.delayMaxMillis) { this.config.delayMaxMillis } else { delay }
    }

    /**
     * 用户名 → 失败计数键（稳定哈希，避免把用户名本身放进内存表）。
     */
    private static func failureKey(username: String): String {
        var h: Int64 = 0
        for (b in username.toArray().iterator()) {
            h = (h * 31 + Int64(b)) & 0x7FFFFFFF
        }
        return "${h}"
    }

    /**
     * FR-AUTH-011：判断该账号是否已连续失败到需要图形验证码。
     *
     * 复用 progressiveDelay 的同一份内存计数（按用户名哈希），不新开表；
     * 阈值来自 AuthConfig.captchaTriggerFailures（默认 3，可配置）。
     * 该查询在「口令校验之前」由接口层调用，因此未命中时零回归。
     */
    public func captchaRequired(username: String): Bool {
        let n = LoginFailureCounter.get(AuthService.failureKey(username))
        return n >= this.config.captchaTriggerFailures
    }

    /**
     * 登录成功后清零连续失败计数（使「连续」语义正确）。
     */
    private func resetFailureCount(username: String): Unit {
        LoginFailureCounter.reset(AuthService.failureKey(username))
    }

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

    /**
     * 用户自助注册（FR-AUTH-001）。
     *
     * 安全约束：
     *  - 邮箱 / 手机号二选一（均做非空 + 唯一性校验）；
     *  - 口令须通过策略校验（复用 `PasswordValidator`，FR-AUTH-004）；
     *  - 重复用户名 / 邮箱 / 手机号返回 409 冲突（而非被 `toDbError` 统一映射的 503）；
     *  - 口令盐与哈希生成失败一律按内部错误抛出，不泄露细节。
     *
     * @return 新用户 ID
     * @throws AppError（ValidationFailed / Conflict）
     */
    public func register(
        username: String,
        password: String,
        email: String,
        phone: String,
        nickname: String
    ): Int64 {
        if (username.isEmpty() || password.isEmpty()) {
            throw validationError("username", "用户名与口令不能为空")
        }
        // 邮箱 / 手机号二选一
        if (email.isEmpty() && phone.isEmpty()) {
            throw validationError("contact", "邮箱与手机号至少填写一项")
        }
        // 口令策略校验（FR-AUTH-004）
        match (this.passwordValidator.check(password, username)) {
            case PasswordCheck.Ok => ()
            case PasswordCheck.TooShort(min) =>
                throw validationError("password", "口令长度至少 ${min} 位")
            case PasswordCheck.TooFewCharClasses(n) =>
                throw validationError("password", "口令至少包含 ${n} 类字符（大小写/数字/符号）")
            case PasswordCheck.InWeakDictionary =>
                throw validationError("password", "口令过于常见，请更换")
            case PasswordCheck.ContainsUsername =>
                throw validationError("password", "口令不得包含用户名")
            case PasswordCheck.RepeatedChars =>
                throw validationError("password", "口令不得包含连续重复字符")
        }
        // 唯一性校验（任何一项冲突即 409，而非 503）
        match (this.userRepo.findByUsername(username)) {
            case Some(_) => throw conflict("用户名已被占用")
            case None => ()
        }
        if (!email.isEmpty()) {
            match (this.userRepo.findByEmail(email)) {
                case Some(_) => throw conflict("邮箱已被占用")
                case None => ()
            }
        }
        if (!phone.isEmpty()) {
            match (this.userRepo.findByPhone(phone)) {
                case Some(_) => throw conflict("手机号已被占用")
                case None => ()
            }
        }
        // 生成盐与哈希（与 createUser 一致）
        var salt: Array<Byte> = Array<Byte>(16, repeat: 0u8)
        match (this.hasher.generateSalt()) {
            case CryptoResult.Ok(b) => salt = b
            case CryptoResult.Err(_) => throw AppError(AppErrorKind.Internal, "口令哈希生成失败")
        }
        var hash = ""
        match (this.hasher.hash(password, salt)) {
            case CryptoResult.Ok(h) => hash = h
            case CryptoResult.Err(_) => throw AppError(AppErrorKind.Internal, "口令哈希生成失败")
        }
        // 空串 → NULL，避免撞 email/phone 唯一部分索引
        var emailOpt: Option<String> = None
        if (!email.isEmpty()) {
            emailOpt = Some(email)
        }
        var phoneOpt: Option<String> = None
        if (!phone.isEmpty()) {
            phoneOpt = Some(phone)
        }
        var nickOpt: Option<String> = None
        if (!nickname.isEmpty()) {
            nickOpt = Some(nickname)
        }
        return this.userRepo.create(
            username,
            emailOpt,
            phoneOpt,
            nickOpt,
            hash,
            this.config.kdfIterations,
            0 // 自助注册无操作员，operatorId 记为 0
        )
    }
}

// ============================================================
// 登录失败计数器（进程内 · 并发安全）
//
// 【为什么必须加锁 · 2026-11-11 线上故障复盘】
// 旧实现把失败次数放在无锁 `HashMap<String, Int64>` 里，由
// progressiveDelay（写）、captchaRequired（读）、resetFailureCount（删）
// 三处直接读写。Web 与移动端并发登录时，并发写会破坏哈希桶内部结构，
// 使 get() 落入环链死循环，占死工作线程；stdx 线程池被逐步耗尽后，
// 所有接口（含 /api/branding、/api/setup/status）排队 30s 并抛
// "Exception: dead lock"，仅 /api/health 因不进业务链路仍可用。
// 当时只做了 docker restart 恢复，未根治。此处把读 / 写 / 删全部收进
// 一把 Mutex，与 CaptchaStore / ChunkUploadStore 的线程安全范式一致。
//
// 【为什么不落库】该计数只用于「渐进延迟 + 图形验证码摩擦」，
// 真正的安全边界是 DB 侧 recordLoginFailure 的原子计数与账号锁定；
// 进程重启清零属可接受降级，不引入额外表与写放大。
//
// 【容量与 TTL】用户名哈希可被枚举，故用 TTL + 桶上限兜住内存。
// 触顶时不再新增桶，并对未知键返回保守值（触发验证码 + 最大延迟），
// 即 fail-closed：绝不因表满而降低登录摩擦。
// ============================================================
public class LoginFailureCounter {
    /** 桶上限：达到后不再新增键。 */
    public static let MaxBuckets: Int64 = 10000
    /** 超过该规模才触发一次过期扫描，避免每次登录都遍历全表。 */
    private static let SweepThreshold: Int64 = 512
    /**
     * 两次扫描的最小间隔。
     * 否则在大规模枚举用户名的场景下，每次失败登录都会 O(n) 遍历全表，
     * 反而把「防内存耗尽」的措施变成新的 CPU 瓶颈。
     */
    private static let SweepIntervalMillis: Int64 = 60 * 1000
    /** 计数保留时长（1 小时），与「连续失败」语义一致。 */
    public static let TtlMillis: Int64 = 60 * 60 * 1000

    private static let counts: HashMap<String, Int64> = HashMap<String, Int64>()
    private static let touched: HashMap<String, Int64> = HashMap<String, Int64>()
    private static let mutex: Mutex = Mutex()
    private static var lastSweepMillis: Int64 = 0

    /** 读取当前连续失败次数（不存在返回 0）。 */
    public static func get(key: String): Int64 {
        LoginFailureCounter.mutex.lock()
        try {
            return LoginFailureCounter.counts.get(key) ?? 0
        } finally {
            LoginFailureCounter.mutex.unlock()
        }
    }

    /**
     * 递增并返回递增后的值（1-based）。
     * 表满且过期清理无效时不再新增桶，返回 MaxBuckets 使验证码阈值判定为真。
     */
    public static func increment(key: String, nowMillis: Int64): Int64 {
        LoginFailureCounter.mutex.lock()
        try {
            LoginFailureCounter.sweepLocked(nowMillis)
            match (LoginFailureCounter.counts.get(key)) {
                case Some(n) =>
                    LoginFailureCounter.counts[key] = n + 1
                    LoginFailureCounter.touched[key] = nowMillis
                    return n + 1
                case None =>
                    if (LoginFailureCounter.counts.size >= LoginFailureCounter.MaxBuckets) {
                        return LoginFailureCounter.MaxBuckets
                    }
                    LoginFailureCounter.counts[key] = 1
                    LoginFailureCounter.touched[key] = nowMillis
                    return 1
            }
        } finally {
            LoginFailureCounter.mutex.unlock()
        }
    }

    /** 登录成功后清零（使「连续」语义正确）。 */
    public static func reset(key: String): Unit {
        LoginFailureCounter.mutex.lock()
        try {
            LoginFailureCounter.counts.remove(key)
            LoginFailureCounter.touched.remove(key)
        } finally {
            LoginFailureCounter.mutex.unlock()
        }
    }

    /** 当前桶数（观测 / 单测用）。 */
    public static func size(): Int64 {
        LoginFailureCounter.mutex.lock()
        try {
            return LoginFailureCounter.counts.size
        } finally {
            LoginFailureCounter.mutex.unlock()
        }
    }

    /** 全量清空（进程内运维级重置 / 单测隔离）。 */
    public static func clear(): Unit {
        LoginFailureCounter.mutex.lock()
        try {
            let keys = ArrayList<String>()
            for ((k, _) in LoginFailureCounter.counts) {
                keys.add(k)
            }
            for (k in keys) {
                LoginFailureCounter.counts.remove(k)
                LoginFailureCounter.touched.remove(k)
            }
            LoginFailureCounter.lastSweepMillis = 0
        } finally {
            LoginFailureCounter.mutex.unlock()
        }
    }

    /** 过期桶清理（调用方必须持有 mutex）。 */
    private static func sweepLocked(nowMillis: Int64): Unit {
        if (LoginFailureCounter.counts.size < LoginFailureCounter.SweepThreshold) {
            return
        }
        if (LoginFailureCounter.lastSweepMillis != 0 &&
            nowMillis - LoginFailureCounter.lastSweepMillis < LoginFailureCounter.SweepIntervalMillis) {
            return
        }
        LoginFailureCounter.lastSweepMillis = nowMillis
        let expired = ArrayList<String>()
        for ((k, t) in LoginFailureCounter.touched) {
            if (nowMillis - t > LoginFailureCounter.TtlMillis) {
                expired.add(k)
            }
        }
        for (k in expired) {
            LoginFailureCounter.counts.remove(k)
            LoginFailureCounter.touched.remove(k)
        }
    }
}

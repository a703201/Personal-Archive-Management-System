// ============================================================
// ams.app.auth · 自助找回口令（FR-AUTH-008）
//
// 需求原文：
//   邮箱/短信验证码 → 重置链接；重置后强制下线全部会话；
//   重置令牌一次性且短时效。
//
// 落地链路（三步，全部走 HTTP，无外部依赖）：
//   ① POST /api/auth/password/forgot  {account}
//        → 生成 6 位数字验证码（10 分钟、5 次尝试、60 秒冷却）
//        → 写入 sys_password_reset（只存 SM3 摘要）
//        → 邮件进 ntf_email_outbox（复用 FR-NTF-004 的 Mailer，不直连 SMTP）
//   ② POST /api/auth/password/verify  {account, code}
//        → 校验通过后签发一次性重置令牌（15 分钟，只存摘要）
//   ③ POST /api/auth/password/reset   {token, newPassword}
//        → 校验令牌 → 口令策略校验 → 改哈希 → **吊销该用户全部会话**
//
// 安全取舍（写在这里，便于评审对照）：
//   · 验证码/令牌都只存摘要：库被拖走也无法直接冒用；摘要加域前缀，
//     验证码再以 user_id 作盐，避免 10^6 空间被离线彩虹表秒破；
//   · 验证码错误次数落库（不是内存计数）：进程重启不会把穷举计数清零；
//   · 令牌消费用「带条件的 UPDATE + rowCount」实现，并发下只有一次成功；
//   · 「账号是否存在」对本次接口是**可见**的（sent 字段）：本系统注册接口
//     本身开放，账号存在性不是秘密，这里优先可用性 —— 用户能立刻知道
//     该换账号还是该找管理员，而不是对着「已发送」干等一封永远不来的信。
//     所有失败原因都会进审计（errorCode=AUTH_RESET_*），便于排查滥用。
// ============================================================
package ams.app.auth

import std.collection.*

import ams.app.audit.*
import ams.app.notification.*
import ams.crypto.provider.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.log.*
import ams.kernel.time.*
import ams.security.audit.*
import ams.security.authn.*

/**
 * 找回流程的时间与次数常量。
 */
public class ResetPolicy {
    /** 验证码有效期：10 分钟 */
    public static let CodeTtlMillis: Int64 = 10 * 60 * 1000
    /** 重置令牌有效期：15 分钟 */
    public static let TokenTtlMillis: Int64 = 15 * 60 * 1000
    /** 重复索取冷却：60 秒 */
    public static let CooldownMillis: Int64 = 60 * 1000
    /** 验证码最大错误次数 */
    public static let MaxAttempts: Int64 = 5
    /** 过期行保留时长（便于审计复盘）：1 天 */
    public static let PurgeKeepMillis: Int64 = 24 * 60 * 60 * 1000
}

/**
 * 索取验证码的结果。
 */
public class ResetSent {
    /** 是否真的发出了验证码 */
    public let sent: Bool
    /** 下发渠道：email / none */
    public let channel: String
    /** 打码后的收件地址（未发出时为空串） */
    public let masked: String
    /** 验证码有效期（秒） */
    public let expiresIn: Int64
    /** 人话提示（未发出时说明下一步怎么做） */
    public let notice: String

    public init(sent: Bool, channel: String, masked: String, expiresIn: Int64, notice: String) {
        this.sent = sent
        this.channel = channel
        this.masked = masked
        this.expiresIn = expiresIn
        this.notice = notice
    }
}

/**
 * 验证码校验通过后拿到的重置票据。
 */
public class ResetTicket {
    /** 一次性重置令牌（明文只在此刻出现一次） */
    public let token: String
    /** 令牌有效期（秒） */
    public let expiresIn: Int64

    public init(token: String, expiresIn: Int64) {
        this.token = token
        this.expiresIn = expiresIn
    }
}

/**
 * 自助找回服务。
 */
public class PasswordResetService {
    private let userRepo: UserRepo
    private let resetRepo: PasswordResetRepo
    private let hasher: PasswordHasher
    private let validator: PasswordValidator
    private let mailer: Mailer
    private let crypto: CryptoProvider
    private let tokenService: TokenService
    private let recorder: ?AuditRecorder
    private let kdfIterations: Int64

    public init(
        userRepo: UserRepo,
        resetRepo: PasswordResetRepo,
        hasher: PasswordHasher,
        validator: PasswordValidator,
        mailer: Mailer,
        crypto: CryptoProvider,
        tokenService: TokenService,
        kdfIterations: Int64,
        recorder!: ?AuditRecorder = None
    ) {
        this.userRepo = userRepo
        this.resetRepo = resetRepo
        this.hasher = hasher
        this.validator = validator
        this.mailer = mailer
        this.crypto = crypto
        this.tokenService = tokenService
        this.kdfIterations = kdfIterations
        this.recorder = recorder
    }

    /**
     * ① 索取验证码。
     *
     * @param account 用户名 / 邮箱 / 手机号，三者任一
     * @param ip      来源 IP
     * @param ua      UA
     * @return 下发结果（sent=false 时 notice 说明原因）
     */
    public func request(account: String, ip: String, ua: String): ResetSent {
        let acc = account.trimAscii()
        if (acc.isEmpty()) {
            throw AppError(AppErrorKind.ValidationFailed, "请填写用户名、邮箱或手机号")
        }
        let now = Times.nowMillis()
        let found = this.lookup(acc)
        let user = match (found) {
            case Some(u) => u
            case None =>
                this.audit("0", AuditAction.PasswordReset, "user", acc,
                           AuditResult.Failure, "AUTH_RESET_NO_USER", ip, ua)
                return ResetSent(false, "none", "", 0, "账号不存在，请核对后重试")
        }
        if (user.status != 0) {
            this.audit("${user.id}", AuditAction.PasswordReset, "user", user.username,
                       AuditResult.Denied, "AUTH_RESET_DISABLED", ip, ua)
            return ResetSent(false, "none", "", 0, "该账号已停用，请联系管理员")
        }
        if (user.email.isEmpty()) {
            this.audit("${user.id}", AuditAction.PasswordReset, "user", user.username,
                       AuditResult.Denied, "AUTH_RESET_NO_EMAIL", ip, ua)
            return ResetSent(false, "none", "", 0, "该账号未绑定邮箱，无法自助找回，请联系管理员")
        }
        // 冷却：60 秒内不允许重复索取（防止把邮箱当炮台）
        let recent = this.resetRepo.countSince(user.id, now - ResetPolicy.CooldownMillis)
        if (recent > 0) {
            this.audit("${user.id}", AuditAction.PasswordReset, "user", user.username,
                       AuditResult.Denied, "AUTH_RESET_COOLDOWN", ip, ua)
            return ResetSent(false, "none", "", 0, "请求过于频繁，请 1 分钟后再试")
        }
        // 生成验证码：4 字节随机数取模 1000000（十进制 6 位）
        let code = this.nextCode()
        let codeHash = this.digestOf("pr:${user.id}:${code}")
        this.resetRepo.create(
            user.id,
            codeHash,
            now + ResetPolicy.CodeTtlMillis,
            ResetPolicy.MaxAttempts,
            ip,
            ua,
            now
        )
        let minutes = ResetPolicy.CodeTtlMillis / 60000
        let subject = "【AMS 档案管理系统】口令重置验证码"
        let body = "您好 ${user.username}：\n\n" +
            "您正在申请重置 AMS 口令，本次验证码为：\n\n" +
            "    ${code}\n\n" +
            "验证码 ${minutes} 分钟内有效，最多可尝试 ${ResetPolicy.MaxAttempts} 次。\n" +
            "如果这不是您本人的操作，请忽略本邮件 —— 您的口令不会发生任何变化。\n\n" +
            "—— AMS 档案管理系统（本邮件由系统自动发送，请勿回复）"
        this.mailer.sendSafe(user.email, subject, body)
        this.audit("${user.id}", AuditAction.PasswordReset, "user", user.username,
                   AuditResult.Success, "AUTH_RESET_CODE_SENT", ip, ua)
        Log.get().info("auth.reset.code_sent", None, [
            ("uid", "${user.id}"),
            ("channel", "email")
        ])
        return ResetSent(
            true,
            "email",
            PasswordResetService.maskEmail(user.email),
            ResetPolicy.CodeTtlMillis / 1000,
            "验证码已发送，请查收邮件"
        )
    }

    /**
     * ② 校验验证码，换取一次性重置令牌。
     */
    public func verify(account: String, code: String, ip: String, ua: String): ResetTicket {
        let acc = account.trimAscii()
        let plain = code.trimAscii()
        if (acc.isEmpty() || plain.isEmpty()) {
            throw AppError(AppErrorKind.ValidationFailed, "账号与验证码不能为空")
        }
        let found = this.lookup(acc)
        let user = match (found) {
            case Some(u) => u
            case None => throw AppError(AppErrorKind.ValidationFailed, "验证码不正确或已过期")
        }
        let now = Times.nowMillis()
        let row = match (this.resetRepo.latestCode(user.id, now)) {
            case Some(r) => r
            case None => throw AppError(AppErrorKind.ValidationFailed, "验证码不正确或已过期")
        }
        let id = row.i64("id")
        let expect = row.str("code_hash")
        if (this.digestOf("pr:${user.id}:${plain}") != expect) {
            let n = this.resetRepo.bumpAttempts(id)
            let left = ResetPolicy.MaxAttempts - n
            this.audit("${user.id}", AuditAction.PasswordReset, "user", user.username,
                       AuditResult.Failure, "AUTH_RESET_CODE_BAD", ip, ua)
            if (left <= 0) {
                throw AppError(AppErrorKind.ValidationFailed, "验证码错误次数过多，请重新获取")
            }
            throw AppError(AppErrorKind.ValidationFailed, "验证码不正确，还可尝试 ${left} 次")
        }
        // 一次性：先抢「验证码未被使用」这个条件，抢不到说明有人并发用了
        if (!this.resetRepo.markCodeUsed(id)) {
            throw AppError(AppErrorKind.ValidationFailed, "验证码已使用，请重新获取")
        }
        let token = this.nextToken()
        let tokenHash = this.digestOf("tk:${token}")
        let exp = now + ResetPolicy.TokenTtlMillis
        if (!this.resetRepo.issueToken(id, tokenHash, exp)) {
            throw AppError(AppErrorKind.Internal, "重置令牌签发失败，请重试")
        }
        this.audit("${user.id}", AuditAction.PasswordReset, "user", user.username,
                   AuditResult.Success, "AUTH_RESET_CODE_OK", ip, ua)
        return ResetTicket(token, ResetPolicy.TokenTtlMillis / 1000)
    }

    /**
     * ③ 凭令牌重置口令，并强制下线该用户全部会话。
     *
     * @return 被重置口令的用户名
     */
    public func reset(token: String, newPassword: String, ip: String, ua: String): String {
        let tk = token.trimAscii()
        if (tk.isEmpty() || newPassword.isEmpty()) {
            throw AppError(AppErrorKind.ValidationFailed, "重置令牌与新口令不能为空")
        }
        let now = Times.nowMillis()
        let row = match (this.resetRepo.findByTokenHash(this.digestOf("tk:${tk}"), now)) {
            case Some(r) => r
            case None =>
                this.audit("0", AuditAction.PasswordReset, "user", "",
                           AuditResult.Failure, "AUTH_RESET_TOKEN_BAD", ip, ua)
                throw AppError(AppErrorKind.ValidationFailed, "重置令牌无效或已过期，请重新获取验证码")
        }
        let uid = row.i64("user_id")
        let user = match (this.userRepo.findById(uid)) {
            case Some(u) => u
            case None => throw AppError(AppErrorKind.ValidationFailed, "账号不存在")
        }
        // 口令策略（FR-AUTH-004）——与注册/改密口径一致
        match (this.validator.check(newPassword, user.username)) {
            case PasswordCheck.Ok => ()
            case PasswordCheck.TooShort(min) =>
                throw AppError(AppErrorKind.ValidationFailed, "口令长度至少 ${min} 位")
            case PasswordCheck.TooFewCharClasses(n) =>
                throw AppError(AppErrorKind.ValidationFailed, "口令至少包含 ${n} 类字符（大小写/数字/符号）")
            case PasswordCheck.InWeakDictionary =>
                throw AppError(AppErrorKind.ValidationFailed, "口令过于常见，请更换")
            case PasswordCheck.ContainsUsername =>
                throw AppError(AppErrorKind.ValidationFailed, "口令不得包含用户名")
            case PasswordCheck.RepeatedChars =>
                throw AppError(AppErrorKind.ValidationFailed, "口令不得包含连续重复字符")
        }
        // 先消费令牌：抢不到说明已被用过（并发/重放）
        if (!this.resetRepo.consume(row.i64("id"), now)) {
            this.audit("${uid}", AuditAction.PasswordReset, "user", user.username,
                       AuditResult.Denied, "AUTH_RESET_TOKEN_REPLAY", ip, ua)
            throw AppError(AppErrorKind.ValidationFailed, "重置令牌已被使用，请重新获取验证码")
        }
        // 生成盐与哈希（与注册一致）
        var salt: Array<Byte> = Array<Byte>(16, repeat: 0u8)
        match (this.hasher.generateSalt()) {
            case CryptoResult.Ok(b) => salt = b
            case CryptoResult.Err(_) => throw AppError(AppErrorKind.Internal, "口令哈希生成失败")
        }
        var hash = ""
        match (this.hasher.hash(newPassword, salt)) {
            case CryptoResult.Ok(h) => hash = h
            case CryptoResult.Err(_) => throw AppError(AppErrorKind.Internal, "口令哈希生成失败")
        }
        // updatePassword 同时清零失败计数与锁定时间
        if (!this.userRepo.updatePassword(uid, hash, this.kdfIterations, uid)) {
            throw AppError(AppErrorKind.Internal, "口令更新失败，请重试")
        }
        // 强制下线：吊销该用户全部会话（含当前被劫持的会话）
        let revoked = this.tokenService.logoutAll("${uid}")
        // 清理该用户其余未消费的找回流程
        this.resetRepo.revokeAllOf(uid, now)
        this.audit("${uid}", AuditAction.PasswordReset, "user", user.username,
                   AuditResult.Success, "AUTH_RESET_DONE", ip, ua)
        Log.get().info("auth.reset.done", None, [
            ("uid", "${uid}"),
            ("revokedSessions", "${revoked}")
        ])
        return user.username
    }

    /**
     * 顺手清理过期行（由定时任务调用，失败不影响主流程）。
     */
    public func purge(): Int64 {
        return this.resetRepo.purgeExpired(Times.nowMillis(), ResetPolicy.PurgeKeepMillis)
    }

    // ---- 内部 ----

    /**
     * 账号 → 用户：先按用户名，再按邮箱，最后按手机号。
     */
    private func lookup(acc: String): ?UserRecord {
        match (this.userRepo.findByUsername(acc)) {
            case Some(u) => return Some(u)
            case None => ()
        }
        match (this.userRepo.findByEmail(acc)) {
            case Some(u) => return Some(u)
            case None => ()
        }
        match (this.userRepo.findByPhone(acc)) {
            case Some(u) => return Some(u)
            case None => ()
        }
        return None
    }

    /**
     * 生成 6 位数字验证码。
     *
     * 用 4 字节随机数取模；**不用位移**拼值，避免 32 位有符号溢出
     * （本仓在多字节解码上踩过同类坑）。
     */
    private func nextCode(): String {
        let bytes = match (this.crypto.randomBytes(4)) {
            case CryptoResult.Ok(b) => b
            case CryptoResult.Err(_) => throw AppError(AppErrorKind.Internal, "随机数生成失败")
        }
        var v: Int64 = 0
        for (b in bytes) {
            v = v * 256 + Int64(b)
        }
        let n = v % 1000000
        var s = "${n}"
        while (s.size < 6) {
            s = "0" + s
        }
        return s
    }

    /**
     * 生成重置令牌：32 字节随机数 → 64 位十六进制。
     */
    private func nextToken(): String {
        let bytes = match (this.crypto.randomBytes(32)) {
            case CryptoResult.Ok(b) => b
            case CryptoResult.Err(_) => throw AppError(AppErrorKind.Internal, "随机数生成失败")
        }
        let sb = StringBuilder()
        for (b in bytes) {
            sb.append(PasswordResetService.hex2(Int64(b)))
        }
        return sb.toString()
    }

    /**
     * 字符串 → SM3 摘要（十六进制小写）。
     */
    private func digestOf(text: String): String {
        let raw = match (this.crypto.digest(text.toArray(), DigestAlgorithm.Sm3)) {
            case CryptoResult.Ok(b) => b
            case CryptoResult.Err(_) => throw AppError(AppErrorKind.Internal, "摘要计算失败")
        }
        let sb = StringBuilder()
        for (b in raw) {
            sb.append(PasswordResetService.hex2(Int64(b)))
        }
        return sb.toString()
    }

    /**
     * 字节 → 两位十六进制。
     */
    private static func hex2(v: Int64): String {
        let digits = "0123456789abcdef"
        let hi = (v / 16) % 16
        let lo = v % 16
        return digits[hi..hi + 1] + digits[lo..lo + 1]
    }

    /**
     * 邮箱打码：保留首字符与域名，中间用 *** 代替。
     *
     * 用 runes 遍历（String 的 [a..b] 按**字节**切片，中文会切坏）。
     */
    public static func maskEmail(email: String): String {
        var at = -1
        var idx: Int64 = 0
        let rs = ArrayList<Rune>()
        for (r in email.runes()) {
            rs.add(r)
            if (r == r'@') {
                at = idx
            }
            idx = idx + 1
        }
        if (at <= 0) {
            return "***"
        }
        var head = ""
        var i: Int64 = 0
        while (i < at) {
            if (i < 1) {
                head = head + rs[i].toString()
            }
            i = i + 1
        }
        var domain = ""
        i = at
        while (i < rs.size) {
            domain = domain + rs[i].toString()
            i = i + 1
        }
        return head + "***" + domain
    }

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
}

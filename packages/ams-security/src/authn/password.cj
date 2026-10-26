// ============================================================
// ams.security.authn.password · 口令策略与口令哈希
//
// 需求（FR-AUTH-004）：长度 ≥ 12 且含 3 类字符；禁用弱口令字典；
//   两次修改间隔 ≥ 24 小时（可配置）；**不做**强制定期更换。
//
// 存储（安全章 §4.1）：
//   $sm3-pbkdf2$v1$<iterations>$<salt_b64>$<dk_b64>
//   DK = PBKDF2-HMAC-SM3(password, salt, iterations, dkLen=32)
//
// 强制项：
//   - 口令**不得**出现在任何日志 / 审计 / 异常消息中
//   - 校验失败统一返回「凭据无效」，不区分「用户不存在」与「口令错误」
//   - 弱口令字典只存 SM3 摘要，不存明文
// ============================================================
package ams.security.authn

import std.collection.*
import stdx.encoding.base64.*
import stdx.encoding.hex.*

import ams.crypto.provider.*
import ams.kernel.error.*

/**
 * 口令策略配置。
 */
public class PasswordPolicy {
    /** 最小长度 */
    public let minLength: Int64
    /** 要求包含的字符类别数（小写/大写/数字/符号） */
    public let minCharClasses: Int64
    /** PBKDF2 迭代次数（OWASP 建议 ≥ 600,000） */
    public let iterations: Int64
    /** 两次修改的最小间隔（小时） */
    public let minChangeIntervalHours: Int64

    public init(
        minLength!: Int64 = 12,
        minCharClasses!: Int64 = 3,
        iterations!: Int64 = 600000,
        minChangeIntervalHours!: Int64 = 24
    ) {
        this.minLength = minLength
        this.minCharClasses = minCharClasses
        this.iterations = iterations
        this.minChangeIntervalHours = minChangeIntervalHours
    }
}

/**
 * 口令校验结果。
 */
public enum PasswordCheck {
    | Ok
    | TooShort(Int64)
    | TooFewCharClasses(Int64)
    | InWeakDictionary
    | ContainsUsername
    | RepeatedChars
}

/**
 * 口令策略校验器。
 */
public class PasswordValidator {
    private let policy: PasswordPolicy
    private let provider: CryptoProvider
    /** 弱口令摘要集合（SM3 摘要的十六进制串） */
    private let weakDigests: HashSet<String>

    /**
     * @param policy 策略配置
     * @param provider 密码学服务（用于弱口令摘要比对）
     * @param weakPasswords 弱口令明文列表（构造时即转摘要，内存不留明文）
     */
    public init(
        policy: PasswordPolicy,
        provider: CryptoProvider,
        weakPasswords: Array<String>
    ) {
        this.policy = policy
        this.provider = provider
        this.weakDigests = HashSet<String>()
        for (w in weakPasswords) {
            let d = provider.digest(w.toAsciiLower().toArray(), DigestAlgorithm.Sm3)
            match (d) {
                case CryptoResult.Ok(bytes) => this.weakDigests.add(toHexString(bytes))
                case CryptoResult.Err(_) => ()
            }
        }
    }

    /**
     * 校验口令是否符合策略。
     *
     * @param password 待校验口令
     * @param username 用户名（用于「口令不得包含用户名」检查）
     */
    public func check(password: String, username: String): PasswordCheck {
        if (password.size < this.policy.minLength) {
            return PasswordCheck.TooShort(this.policy.minLength)
        }

        let classes = PasswordValidator.countCharClasses(password)
        if (classes < this.policy.minCharClasses) {
            return PasswordCheck.TooFewCharClasses(this.policy.minCharClasses)
        }

        // 口令不得包含用户名（大小写不敏感）
        if (username != "" && password.toAsciiLower().contains(username.toAsciiLower())) {
            return PasswordCheck.ContainsUsername
        }

        // 连续重复字符（如 "aaaaaaaaaaaa"）
        if (PasswordValidator.hasRepeatedChars(password)) {
            return PasswordCheck.RepeatedChars
        }

        // 弱口令字典
        if (this.isWeakPassword(password)) {
            return PasswordCheck.InWeakDictionary
        }

        return PasswordCheck.Ok
    }

    /**
     * 是否命中弱口令字典。
     *
     * 字典只存 SM3 摘要（不存明文），比对用哈希集合。
     */
    private func isWeakPassword(password: String): Bool {
        let d = this.provider.digest(password.toAsciiLower().toArray(), DigestAlgorithm.Sm3)
        match (d) {
            case CryptoResult.Ok(bytes) => return this.weakDigests.contains(toHexString(bytes))
            case CryptoResult.Err(_) => return true
        }
    }

    /**
     * 统计口令包含的字符类别数。
     *
     * 类别：小写字母、大写字母、数字、符号。
     */
    public static func countCharClasses(password: String): Int64 {
        var hasLower = false
        var hasUpper = false
        var hasDigit = false
        var hasSymbol = false

        for (i in 0..password.size) {
            let c = password[i]
            if (c >= 97u8 && c <= 122u8) {          // a-z
                hasLower = true
            } else if (c >= 65u8 && c <= 90u8) {   // A-Z
                hasUpper = true
            } else if (c >= 48u8 && c <= 57u8) {   // 0-9
                hasDigit = true
            } else {
                hasSymbol = true
            }
        }

        var count: Int64 = 0
        if (hasLower) { count += 1 }
        if (hasUpper) { count += 1 }
        if (hasDigit) { count += 1 }
        if (hasSymbol) { count += 1 }
        return count
    }

    /**
     * 是否存在连续 4 个以上相同字符。
     */
    public static func hasRepeatedChars(password: String): Bool {
        if (password.size < 4) {
            return false
        }
        var run: Int64 = 1
        for (i in 1..password.size) {
            if (password[i] == password[i - 1]) {
                run += 1
                if (run >= 4) {
                    return true
                }
            } else {
                run = 1
            }
        }
        return false
    }
}

/**
 * 口令哈希器。
 */
public class PasswordHasher {
    private let provider: CryptoProvider
    private let policy: PasswordPolicy

    public init(provider: CryptoProvider, policy: PasswordPolicy) {
        this.provider = provider
        this.policy = policy
    }

    /**
     * 计算口令哈希。
     *
     * @param password 口令明文
     * @param salt 盐值（16 字节随机；首次生成时由调用方提供）
     * @return 存储串 `$sm3-pbkdf2$v1$<iterations>$<salt_b64>$<dk_b64>`
     */
    public func hash(password: String, salt: Array<Byte>): CryptoResult<String> {
        let dk = this.provider.deriveKey(
            password.toArray(), salt, this.policy.iterations, 32)
        match (dk) {
            case CryptoResult.Ok(k) => return CryptoResult.Ok(
                "$sm3-pbkdf2$v1$${this.policy.iterations}$${toBase64String(salt)}$${toBase64String(k)}")
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
    }

    /**
     * 生成随机盐（16 字节）。
     */
    public func generateSalt(): CryptoResult<Array<Byte>> {
        return this.provider.randomBytes(16)
    }

    /**
     * 校验口令。
     *
     * 实现要点：无论成功与否都执行**完整**的 PBKDF2 计算，
     * 避免通过耗时差异区分「用户不存在」与「口令错误」。
     *
     * @param password 待校验口令
     * @param stored 存储串
     * @param dummySalt 用户不存在时使用的哑盐（保证耗时一致）
     */
    public func verify(password: String, stored: String, dummySalt: Array<Byte>): Bool {
        let parts = PasswordHasher.splitStored(stored)
        // 注意：match 的每个分支都必须是**单个表达式**，
        // 不能写成 { 多行语句 }，故两个分支都抽成方法。
        match (parts) {
            case Some(p) => return this.verifyWithParts(password, p)
            case None => return this.verifyWithDummy(password, dummySalt)
        }
    }

    /**
     * 存储串格式异常时的兜底校验。
     *
     * 仍执行一次等价 KDF 计算，使「用户不存在」与「口令错误」的耗时一致，
     * 避免通过响应时间区分两者。
     */
    private func verifyWithDummy(password: String, dummySalt: Array<Byte>): Bool {
        let _ = this.provider.deriveKey(
            password.toArray(), dummySalt, this.policy.iterations, 32)
        return false
    }

    /**
     * 用已解析的存储串分量校验口令。
     */
    private func verifyWithParts(password: String, p: (String, Int64, Array<Byte>, Array<Byte>)): Bool {
        let dk = this.provider.deriveKey(
            password.toArray(), p[2], p[1], 32)
        match (dk) {
            case CryptoResult.Ok(k) => return this.provider.constantTimeEquals(k, p[3])
            case CryptoResult.Err(_) => return false
        }
    }

    /**
     * 解析存储串。
     *
     * @return Some((算法版本, 迭代次数, 盐, 派生密钥)) 或 None
     */
    public static func splitStored(stored: String): ?(String, Int64, Array<Byte>, Array<Byte>) {
        let parts = stored.split("$")
        // 形如 ["", "sm3-pbkdf2", "v1", "600000", "salt", "dk"] —— 期望 6 段
        if (parts.size != 6) {
            return None
        }
        if (parts[1] != "sm3-pbkdf2" || parts[2] != "v1") {
            return None
        }
        // 迭代次数：手动解析（仓颉无 Int64.parse）
        let iter = PasswordHasher.parseInt64(parts[3])
        if (iter < 0) {
            return None
        }
        // Base64 解码返回 Option（可能因非法字符失败）
        // 注意：match 分支是**表达式**，块内不能用 return，故抽成方法
        let salt = PasswordHasher.decodeOrEmpty(fromBase64String(parts[4]))
        let dk = PasswordHasher.decodeOrEmpty(fromBase64String(parts[5]))
        if (salt.isEmpty() || dk.isEmpty()) {
            return None
        }
        return Some((parts[2], iter, salt, dk))
    }

    /**
     * Base64 解码结果转字节数组；失败返回空数组。
     */
    private static func decodeOrEmpty(r: ?Array<Byte>): Array<Byte> {
        match (r) {
            case Some(b) => return b
            case None => return Array<Byte>(0, repeat: 0u8)
        }
    }

    /**
     * 手动解析十进制整数。
     *
     * 仓颉标准库未提供 Int64.parse，此处自行实现；
     * 非法输入返回 -1。
     */
    public static func parseInt64(s: String): Int64 {
        if (s.isEmpty()) {
            return -1
        }
        var v: Int64 = 0
        for (i in 0..s.size) {
            let c = s[i]
            if (c < 48u8 || c > 57u8) {
                return -1
            }
            v = v * 10 + (Int64(c) - 48)
        }
        return v
    }
}

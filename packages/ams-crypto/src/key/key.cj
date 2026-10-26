// ============================================================
// ams.crypto.key · 密钥管理
//
// 职责（安全章 §5.3 密钥层级）：
//   - KEK（主密钥）：包裹 DEK，永不直接用于数据加密
//   - DEK（数据密钥）：包裹在 KEK 下，用于实际字段加密
//   - 派生密钥：由 PBKDF2 从口令派生，用于盲索引与口令校验
//
// 规约：
//   - 密钥材料不得进入日志、异常消息、审计记录
//   - 密钥版本号必带，支持轮换后仍能解开历史数据
//   - 包裹结果包含：版本号 + nonce + 密文 + HMAC 校验
// ============================================================
package ams.crypto.key

import ams.crypto.provider.*
import ams.kernel.error.*

/**
 * 密钥版本标识。
 */
public class KeyVersion {
    /** 密钥标识（用于查 KEK） */
    public let keyId: String
    /** 版本号（同一 keyId 下的第几代） */
    public let version: Int64

    public init(keyId: String, version: Int64) {
        this.keyId = keyId
        this.version = version
    }

    /**
     * 规范化字符串形式（写进包裹结果，供解密时定位密钥）。
     *
     * @param alg 包裹算法标识（见 KeyManager.algReuseKek / algDerivedSubkeys）
     */
    public func toStorageKey(alg!: Int64 = KeyManager.algReuseKek): String {
        if (alg == KeyManager.algReuseKek) {
            return "${this.keyId}:v${this.version}"
        }
        // 分离派生时把算法标识带进存储键，使包裹结果**自描述**：
        // 解包时无需外部约定即可知道该用哪套密钥派生方式。
        return "${this.keyId}:v${this.version}:a${alg}"
    }
}

/**
 * 被包裹的数据密钥。
 *
 * 布局（拼接后整体 base64 存储）：
 *   storageKeyLen(1) | storageKey | nonce(16) | ciphertext | hmac(32)
 *
 * 说明：采用 Encrypt-then-MAC。
 *   - 密文用 SM4-CBC 加密（子密钥 encKey）
 *   - HMAC-SM3 覆盖 storageKey + nonce + ciphertext（子密钥 macKey）
 *   - encKey 与 macKey **相互独立**，均由 KEK 派生（见 KeyManager.deriveSubKey）
 *
 * 关于 SM4-GCM：stdx 1.2.0.1 上实测不可用
 *   （"Encrypt failed due to create tag error"），
 *   故本项目一律用 SM4-CBC + HMAC-SM3 的 Encrypt-then-MAC 组合。
 *   详见 docs/03-安全设计说明.md §5 密码学方案。
 */
public class WrappedKey {
    /** 密钥标识与版本 */
    public let keyVersion: KeyVersion
    /** 包裹算法标识（1 = 复用 KEK；2 = 分离派生子密钥） */
    public let alg: Int64
    /** 完整性校验值（HMAC-SM3） */
    public let mac: Array<Byte>
    /** 密文 */
    public let ciphertext: Array<Byte>

    public init(
        keyVersion: KeyVersion,
        mac: Array<Byte>,
        ciphertext: Array<Byte>,
        alg!: Int64 = KeyManager.algReuseKek
    ) {
        this.keyVersion = keyVersion
        this.alg = alg
        this.mac = mac
        this.ciphertext = ciphertext
    }
}

/**
 * 密钥管理服务。
 */
public class KeyManager {
    /**
     * 包裹算法 1：**直接复用 KEK** 做加密与认证。
     *
     * 历史格式（v1），仅用于兼容已存在的包裹数据。
     * 该方式加密密钥与认证密钥相同，违反密钥分离原则，新数据不再使用。
     */
    public static let algReuseKek: Int64 = 1

    /**
     * 包裹算法 2：**从 KEK 派生出独立的加密子密钥与认证子密钥**。
     *
     * 当前默认。加密用 encKey、认证用 macKey，二者相互独立，
     * 满足「密钥分离」要求（见安全设计说明 §5.4）。
     */
    public static let algDerivedSubkeys: Int64 = 2

    /** 加密子密钥的派生标签 */
    private static let labelEnc: String = "AMS-KEK-ENC-v1"

    /** 认证子密钥的派生标签 */
    private static let labelMac: String = "AMS-KEK-MAC-v1"

    private let provider: CryptoProvider
    /** KEK 提供器：按 keyId 返回主密钥 */
    private let kekProvider: (String) -> Array<Byte>

    /**
     * @param provider 密码学服务
     * @param kekProvider 主密钥获取器（生产环境应从 KMS / HSM 取，禁止硬编码）
     */
    public init(provider: CryptoProvider, kekProvider: (String) -> Array<Byte>) {
        this.provider = provider
        this.kekProvider = kekProvider
    }

    /**
     * 从 KEK 派生子密钥。
     *
     * 派生方式：SM3(label || 0x00 || kek)，取前 16 字节。
     *
     * 说明：仓颉标准库与 stdx 都没有 HKDF，故用 SM3 手工构造
     * 一个带用途标签的单步派生（domain separation）：
     *   - 标签不同 → 派生出完全不同的子密钥
     *   - 0x00 分隔符 → 避免标签与密钥拼接产生歧义
     *
     * @param kek     主密钥
     * @param purpose 用途标签（加密 / 认证）
     * @return 16 字节子密钥
     */
    private func deriveSubKey(kek: Array<Byte>, purpose: String): CryptoResult<Array<Byte>> {
        let sep = Array<Byte>(1, repeat: 0u8)
        let input = KeyManager.concat(purpose.toArray(), KeyManager.concat(sep, kek))
        match (this.provider.digest(input, DigestAlgorithm.Sm3)) {
            case CryptoResult.Ok(d) =>
                if (d.size < 16) {
                    return CryptoResult.Err(AppError(AppErrorKind.CryptoFailure, "子密钥派生失败"))
                }
                let sub = Array<Byte>(16, repeat: 0u8)
                for (i in 0..16) {
                    sub[i] = d[i]
                }
                return CryptoResult.Ok(sub)
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
    }

    /**
     * 按算法标识取得加密子密钥与认证子密钥。
     */
    private func subKeys(kek: Array<Byte>, alg: Int64): CryptoResult<(Array<Byte>, Array<Byte>)> {
        if (alg == KeyManager.algReuseKek) {
            // 历史格式：两者都是 KEK 本身
            return CryptoResult.Ok((kek, kek))
        }
        let encKey = match (this.deriveSubKey(kek, KeyManager.labelEnc)) {
            case CryptoResult.Ok(k) => k
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
        let macKey = match (this.deriveSubKey(kek, KeyManager.labelMac)) {
            case CryptoResult.Ok(k) => k
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
        return CryptoResult.Ok((encKey, macKey))
    }

    /**
     * 生成新的数据密钥（DEK），并用 KEK 包裹。
     */
    public func generateDataKey(keyVersion: KeyVersion): CryptoResult<WrappedKey> {
        // DEK 长度：SM4 为 16 字节
        let dek = match (this.provider.randomBytes(16)) {
            case CryptoResult.Ok(b) => b
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
        return this.wrap(keyVersion, dek)
    }

    /**
     * 用 KEK 包裹给定密钥。
     */
    public func wrap(keyVersion: KeyVersion, plainKey: Array<Byte>): CryptoResult<WrappedKey> {
        let kek = this.kekProvider(keyVersion.keyId)
        if (kek.size != 16) {
            return CryptoResult.Err(AppError(AppErrorKind.CryptoFailure, "KEK 长度必须为 16 字节"))
        }

        let alg = KeyManager.algDerivedSubkeys
        let (encKey, macKey) = match (this.subKeys(kek, alg)) {
            case CryptoResult.Ok(t) => t
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }

        // 随机 nonce：SM4-CBC 要求 IV 不可预测
        let nonce = match (this.provider.randomBytes(16)) {
            case CryptoResult.Ok(b) => b
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }

        // 明文 = storageKey || dek，便于解包时定位密钥
        let storageKey = keyVersion.toStorageKey(alg: alg).toArray()
        let plain = KeyManager.concat(storageKey, plainKey)

        let ciphertext = match (this.provider.encrypt(encKey, nonce, plain, CipherMode.Cbc)) {
            case CryptoResult.Ok(c) => c
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }

        // MAC 覆盖 storageKey + nonce + ciphertext
        let macInput = KeyManager.concat(KeyManager.concat(storageKey, nonce), ciphertext)
        let mac = match (this.provider.hmac(macKey, macInput, DigestAlgorithm.Sm3)) {
            case CryptoResult.Ok(m) => m
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }

        return CryptoResult.Ok(WrappedKey(keyVersion, mac, KeyManager.concat(nonce, ciphertext), alg: alg))
    }

    /**
     * 解包：校验完整性后还原明文密钥。
     *
     * 失败返回 Err(CryptoFailure)，**不区分**「MAC 不符」与「密钥不存在」，
     * 避免向攻击者泄露信息。
     */
    public func unwrap(wrapped: WrappedKey): CryptoResult<Array<Byte>> {
        let kek = this.kekProvider(wrapped.keyVersion.keyId)
        if (kek.size != 16) {
            return CryptoResult.Err(AppError(AppErrorKind.CryptoFailure, "解包失败"))
        }

        if (wrapped.ciphertext.size < 16) {
            return CryptoResult.Err(AppError(AppErrorKind.CryptoFailure, "解包失败"))
        }

        // 按包裹算法取子密钥（alg=1 复用 KEK；alg=2 分离派生）
        let alg = wrapped.alg
        let (encKey, macKey) = match (this.subKeys(kek, alg)) {
            case CryptoResult.Ok(t) => t
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }

        // 拆出 nonce 与密文
        let nonce = Array<Byte>(16, repeat: 0u8)
        for (i in 0..16) {
            nonce[i] = wrapped.ciphertext[i]
        }
        let ctLen = wrapped.ciphertext.size - 16
        let ct = Array<Byte>(ctLen, repeat: 0u8)
        for (i in 0..ctLen) {
            ct[i] = wrapped.ciphertext[16 + i]
        }

        // 先验 MAC（Encrypt-then-MAC：先验证再解密）
        let storageKey = wrapped.keyVersion.toStorageKey(alg: alg).toArray()
        let macInput = KeyManager.concat(KeyManager.concat(storageKey, nonce), ct)
        let expect = match (this.provider.hmac(macKey, macInput, DigestAlgorithm.Sm3)) {
            case CryptoResult.Ok(m) => m
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
        if (!this.provider.constantTimeEquals(expect, wrapped.mac)) {
            return CryptoResult.Err(AppError(AppErrorKind.CryptoFailure, "解包失败"))
        }

        // 解密
        let plain = match (this.provider.decrypt(encKey, nonce, ct, CipherMode.Cbc)) {
            case CryptoResult.Ok(p) => p
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }

        // 去掉 storageKey 前缀
        if (plain.size <= storageKey.size) {
            return CryptoResult.Err(AppError(AppErrorKind.CryptoFailure, "解包失败"))
        }
        let keyLen = plain.size - storageKey.size
        let key = Array<Byte>(keyLen, repeat: 0u8)
        for (i in 0..keyLen) {
            key[i] = plain[storageKey.size + i]
        }
        return CryptoResult.Ok(key)
    }

    /**
     * 字节数组拼接。
     */
    private static func concat(a: Array<Byte>, b: Array<Byte>): Array<Byte> {
        let out = Array<Byte>(a.size + b.size, repeat: 0u8)
        for (i in 0..a.size) {
            out[i] = a[i]
        }
        for (i in 0..b.size) {
            out[a.size + i] = b[i]
        }
        return out
    }
}

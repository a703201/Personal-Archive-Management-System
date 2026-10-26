// ============================================================
// ams.crypto.impl · PBKDF2-HMAC-SM3
//
// 依据：RFC 2898 PKCS #5 v2.0（PBKDF2）
// 原理：
//   DK = T1 || T2 || ... || Tdkl
//   Ti = F(P, S, c, i)
//   F(P, S, c, i) = U1 xor U2 xor ... xor Uc
//   U1 = PRF(P, S || INT_32_BE(i))
//   Uj = PRF(P, U(j-1))
//   PRF = HMAC-SM3
//
// 参考实现：Python hashlib.pbkdf2_hmac('sm3', ...) 在支持 SM3 的
// OpenSSL 3.x 上与本实现一致（已用测试向量核对）。
// ============================================================
package ams.crypto.impl

import stdx.crypto.digest.*

/**
 * PBKDF2 派生。
 */
public class Pbkdf2 {
    /**
     * PBKDF2-HMAC-SM3。
     *
     * @param password 口令
     * @param salt 盐值
     * @param iterations 迭代次数
     * @param keyLength 派生密钥长度（字节）
     */
    public static func deriveSm3(
        password: Array<Byte>,
        salt: Array<Byte>,
        iterations: Int64,
        keyLength: Int64
    ): Array<Byte> {
        // hLen = SM3 输出长度 = 32
        let hLen: Int64 = 32
        let blockCount = (keyLength + hLen - 1) / hLen

        var result = Array<Byte>(keyLength, repeat: 0u8)
        var offset: Int64 = 0

        for (blockIndex in 1..(blockCount + 1)) {
            // T_i = F(P, S, c, i) = U1 xor U2 xor ... xor Uc
            // 注意：f() 内部**已完成全部 c 次迭代**，此处不可重复迭代
            // （曾因重复迭代导致 iterations>1 时结果错误，iterations=1 恰好通过）
            let t = Pbkdf2.f(password, salt, iterations, blockIndex)

            // 拷入结果
            for (j in 0..hLen) {
                if (offset < keyLength) {
                    result[offset] = t[j]
                    offset += 1
                }
            }
        }

        return result
    }

    /**
     * F(P, S, c, i)：U1 xor U2 xor ... xor Uc
     */
    private static func f(
        password: Array<Byte>,
        salt: Array<Byte>,
        iterations: Int64,
        blockIndex: Int64
    ): Array<Byte> {
        var u = Pbkdf2.prf(password, Pbkdf2.concat(salt, Pbkdf2.int32Be(blockIndex)))
        var t = u
        for (i in 2..(iterations + 1)) {
            u = Pbkdf2.prf(password, u)
            for (j in 0..u.size) {
                t[j] = t[j] ^ u[j]
            }
        }
        return t
    }

    /**
     * PRF(P, S) = HMAC-SM3(P, S)
     */
    private static func prf(password: Array<Byte>, data: Array<Byte>): Array<Byte> {
        let h = HMAC(password, HashType.SM3)
        h.write(data)
        return h.finish()
    }

    /**
     * 4 字节大端整数（RFC 2898 的 INT_32_BE）。
     */
    private static func int32Be(v: Int64): Array<Byte> {
        let b = Array<Byte>(4, repeat: 0u8)
        b[0] = UInt8((v >> 24) & 0xFF)
        b[1] = UInt8((v >> 16) & 0xFF)
        b[2] = UInt8((v >> 8) & 0xFF)
        b[3] = UInt8(v & 0xFF)
        return b
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

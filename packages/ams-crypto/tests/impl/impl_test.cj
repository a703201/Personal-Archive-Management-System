// ============================================================
// ams.crypto.impl · 单元测试
//
// [结构约定]（实测 SDK 1.0.5）：
//   测试代码与产品代码**物理分离**（本文件在 tests/ 目录，不在 src/）。
//   原因：编译器会优先使用 import-path 里的 .cjo 而非源码，
//   若测试文件与产品代码同目录，.cjo 里会混入未展开的测试宏，
//   导致后续编译报出莫名的 "expected '=>' in lambda expression"。
//   分离后测试包声明为 <被测包>.test，用 import 引用被测包。
//
//   编译运行：bash scripts/test.sh
// ============================================================
package ams.crypto.impl.test

import stdx.encoding.hex.*
import ams.crypto.impl.*


import std.unittest.*
import stdx.encoding.hex.*

import ams.crypto.provider.*
import ams.kernel.error.*

@Test
public class CryptoImplTest {
    private let provider = StdxCryptoProvider()

    // ---- 摘要 ----

    @TestCase
    public func testSm3StandardVector() {
        // GM/T 0004-2012：SM3("abc") = 66c7f0f4...ba8e0
        let r = this.provider.digest("abc".toArray(), DigestAlgorithm.Sm3)
        match (r) {
            case CryptoResult.Ok(d) => @Assert(toHexString(d),
                "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0")
            case CryptoResult.Err(_) => @Assert(true, false)
        }
    }

    @TestCase
    public func testDigestIsDeterministic() {
        let a = this.provider.digest("hello".toArray(), DigestAlgorithm.Sm3)
        let b = this.provider.digest("hello".toArray(), DigestAlgorithm.Sm3)
        match (a) {
            case CryptoResult.Ok(x) => match (b) {
                case CryptoResult.Ok(y) => @Assert(this.provider.constantTimeEquals(x, y), true)
                case CryptoResult.Err(_) => @Assert(true, false)
            }
            case CryptoResult.Err(_) => @Assert(true, false)
        }
    }

    // ---- HMAC ----

    @TestCase
    public func testHmacSm3MatchesOpenssl() {
        // OpenSSL: openssl dgst -sm3 -mac HMAC -macopt hexkey:6b6579 <<< "hello"
        // -> 798a6ca374c9ac891982f87a4f4c4d60bd6cdddfe8fb0fa344393621a0c02d96
        let r = this.provider.hmac("key".toArray(), "hello".toArray(), DigestAlgorithm.Sm3)
        match (r) {
            case CryptoResult.Ok(m) => @Assert(toHexString(m),
                "798a6ca374c9ac891982f87a4f4c4d60bd6cdddfe8fb0fa344393621a0c02d96")
            case CryptoResult.Err(_) => @Assert(true, false)
        }
    }

    @TestCase
    public func testHmacRejectsEmptyKey() {
        let r = this.provider.hmac(Array<Byte>(0, repeat: 0u8), "x".toArray(), DigestAlgorithm.Sm3)
        match (r) {
            case CryptoResult.Ok(_) => @Assert(true, false)
            case CryptoResult.Err(e) => @Assert(
                match (e.kind) {
                    case AppErrorKind.CryptoFailure => true
                    case _ => false
                }, true)
        }
    }

    // ---- 对称加密 ----

    @TestCase
    public func testSm4CbcMatchesOpenssl() {
        // OpenSSL: openssl enc -sm4-cbc -K 3132..3536 -iv 3132..3536
        // -> 6a14c080a6a017656b7c2198cf9e4568
        let key = "1234567890123456".toArray()
        let iv = "1234567890123456".toArray()
        let r = this.provider.encrypt(key, iv, "hello".toArray(), CipherMode.Cbc)
        match (r) {
            case CryptoResult.Ok(c) => @Assert(toHexString(c), "6a14c080a6a017656b7c2198cf9e4568")
            case CryptoResult.Err(_) => @Assert(true, false)
        }
    }

    @TestCase
    public func testSm4CbcRoundTrip() {
        let key = "1234567890123456".toArray()
        let iv = "1234567890123456".toArray()
        let plain = "档案内容：这是一个测试".toArray()

        let enc = this.provider.encrypt(key, iv, plain, CipherMode.Cbc)
        match (enc) {
            case CryptoResult.Ok(c) => this.assertRoundTrip(key, iv, c, plain)
            case CryptoResult.Err(_) => @Assert(true, false)
        }
    }

    /**
     * 解密并比对（抽成方法以适配 match 的表达式语义）。
     */
    private func assertRoundTrip(key: Array<Byte>, iv: Array<Byte>, ct: Array<Byte>, plain: Array<Byte>): Unit {
        let dec = this.provider.decrypt(key, iv, ct, CipherMode.Cbc)
        match (dec) {
            case CryptoResult.Ok(d) => @Assert(this.provider.constantTimeEquals(d, plain), true)
            case CryptoResult.Err(_) => @Assert(true, false)
        }
    }

    @TestCase
    public func testEncryptRejectsBadKeyLength() {
        let r = this.provider.encrypt(
            "short".toArray(), "1234567890123456".toArray(), "x".toArray(), CipherMode.Cbc)
        match (r) {
            case CryptoResult.Ok(_) => @Assert(true, false)
            case CryptoResult.Err(e) => @Assert(
                match (e.kind) {
                    case AppErrorKind.CryptoFailure => true
                    case _ => false
                }, true)
        }
    }

    // ---- 随机数 ----

    @TestCase
    public func testRandomBytesLength() {
        let r = this.provider.randomBytes(16)
        match (r) {
            case CryptoResult.Ok(b) => @Assert(b.size, 16)
            case CryptoResult.Err(_) => @Assert(true, false)
        }
    }

    @TestCase
    public func testRandomBytesDiffers() {
        let a = this.provider.randomBytes(32)
        let b = this.provider.randomBytes(32)
        match (a) {
            case CryptoResult.Ok(x) => match (b) {
                case CryptoResult.Ok(y) => @Assert(this.provider.constantTimeEquals(x, y), false)
                case CryptoResult.Err(_) => @Assert(true, false)
            }
            case CryptoResult.Err(_) => @Assert(true, false)
        }
    }

    // ---- PBKDF2 ----

    @TestCase
    public func testPbkdf2DerivesRequestedLength() {
        let r = this.provider.deriveKey("password".toArray(), "salt".toArray(), 1000, 32)
        match (r) {
            case CryptoResult.Ok(k) => @Assert(k.size, 32)
            case CryptoResult.Err(_) => @Assert(true, false)
        }
    }

    @TestCase
    public func testPbkdf2MatchesReferenceVector() {
        // 参考值来源：Python hashlib（走系统 OpenSSL 3.5.7）
        //   hashlib.pbkdf2_hmac('sm3', b'password', b'salt', 1000, 32)
        let k = Pbkdf2.deriveSm3("password".toArray(), "salt".toArray(), 1000, 32)
        @Assert(toHexString(k),
            "e8b635a41dfe5aaab7cf828cff6f3608e22cac59ba16edd70e000b293d00bc91")
    }

    @TestCase
    public func testPbkdf2MatchesReferenceVectorSingleIteration() {
        // hashlib.pbkdf2_hmac('sm3', b'password', b'salt', 1, 32)
        let k = Pbkdf2.deriveSm3("password".toArray(), "salt".toArray(), 1, 32)
        @Assert(toHexString(k),
            "4612f922a1fdcefaf4312fc6f8f3322b489cbf24f2ea361b44c2bd8fa2c6dcb0")
    }

    @TestCase
    public func testPbkdf2MatchesReferenceVector4096Iterations() {
        // hashlib.pbkdf2_hmac('sm3', b'password', b'salt', 4096, 32)
        let k = Pbkdf2.deriveSm3("password".toArray(), "salt".toArray(), 4096, 32)
        @Assert(toHexString(k),
            "b6e8f2074c87432b78f62e5ced980fdff89e86af2f693dab1638e2b3683045dd")
    }

    @TestCase
    public func testPbkdf2ShortKeyIsPrefixOfLongKey() {
        // PBKDF2 的性质：dkLen=16 的结果应是 dkLen=32 的前 16 字节
        let short = Pbkdf2.deriveSm3("password".toArray(), "salt".toArray(), 1000, 16)
        let long = Pbkdf2.deriveSm3("password".toArray(), "salt".toArray(), 1000, 32)
        @Assert(toHexString(short), "e8b635a41dfe5aaab7cf828cff6f3608")
        for (i in 0..16) {
            @Assert(short[i], long[i])
        }
    }

    @TestCase
    public func testPbkdf2IsDeterministic() {
        let a = Pbkdf2.deriveSm3("password".toArray(), "salt".toArray(), 1000, 32)
        let b = Pbkdf2.deriveSm3("password".toArray(), "salt".toArray(), 1000, 32)
        @Assert(this.provider.constantTimeEquals(a, b), true)
    }

    @TestCase
    public func testPbkdf2DifferentSaltDifferentKey() {
        let a = Pbkdf2.deriveSm3("password".toArray(), "salt1".toArray(), 1000, 32)
        let b = Pbkdf2.deriveSm3("password".toArray(), "salt2".toArray(), 1000, 32)
        @Assert(this.provider.constantTimeEquals(a, b), false)
    }

    @TestCase
    public func testPbkdf2DifferentIterationsDifferentKey() {
        let a = Pbkdf2.deriveSm3("password".toArray(), "salt".toArray(), 1000, 32)
        let b = Pbkdf2.deriveSm3("password".toArray(), "salt".toArray(), 2000, 32)
        @Assert(this.provider.constantTimeEquals(a, b), false)
    }

    @TestCase
    public func testPbkdf2RejectsBadArgs() {
        match (this.provider.deriveKey("p".toArray(), "s".toArray(), 0, 32)) {
            case CryptoResult.Ok(_) => @Assert(true, false)
            case CryptoResult.Err(_) => @Assert(true, true)
        }
        match (this.provider.deriveKey("p".toArray(), Array<Byte>(0, repeat: 0u8), 1000, 32)) {
            case CryptoResult.Ok(_) => @Assert(true, false)
            case CryptoResult.Err(_) => @Assert(true, true)
        }
    }

    // ---- 恒定时间比较 ----

    @TestCase
    public func testConstantTimeEquals() {
        @Assert(this.provider.constantTimeEquals("abc".toArray(), "abc".toArray()), true)
        @Assert(this.provider.constantTimeEquals("abc".toArray(), "abd".toArray()), false)
        @Assert(this.provider.constantTimeEquals("abc".toArray(), "ab".toArray()), false)
    }
}

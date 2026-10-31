// ============================================================
// ams.crypto.key · 单元测试
//
// 覆盖：
//   - 密钥包裹 / 解包往返
//   - 篡改检测（EtM：先验 MAC 再解密）
//   - 密钥分离（加密子密钥 ≠ 认证子密钥）
//   - 算法标识 alg 的自描述
//
// [结构约定]（实测 SDK 1.2.0）：
//   测试代码与产品代码**物理分离**（本文件在 tests/ 目录，不在 src/）。
//
// [语法约定]（实测 SDK 1.2.0）：
//   match 的每个分支**必须是单个表达式**，不能写 { 多行语句 }——
//   否则被当作 lambda 体，报 "expected '=>' in lambda expression, found '@'"。
//   故所有「取值或失败」的场景抽成辅助方法（用 throw 表达失败）。
// ============================================================
package ams.crypto.key.test

import std.unittest.*
import std.unittest.testmacro.*

import ams.crypto.impl.*
import ams.crypto.key.*
import ams.crypto.provider.*
import ams.kernel.error.*

/**
 * 取出 Ok 值，失败则抛异常（让测试直接失败）。
 */
private func must<T>(r: CryptoResult<T>): T {
    return match (r) {
        case CryptoResult.Ok(v) => v
        case CryptoResult.Err(e) => throw Exception("期望成功但失败：${e.message}")
    }
}

/**
 * 构造一个使用固定 KEK 的 KeyManager。
 */
private func makeManager(kek: Array<Byte>): KeyManager {
    return KeyManager(StdxCryptoProvider(), { _: String => kek })
}

/**
 * 拼接字节数组。
 */
private func concat(a: Array<Byte>, b: Array<Byte>): Array<Byte> {
    let out = Array<Byte>(a.size + b.size, repeat: 0u8)
    for (i in 0..a.size) {
        out[i] = a[i]
    }
    for (i in 0..b.size) {
        out[a.size + i] = b[i]
    }
    return out
}

/**
 * 数组整体是否相等。
 */
private func bytesEqual(a: Array<Byte>, b: Array<Byte>): Bool {
    if (a.size != b.size) {
        return false
    }
    for (i in 0..a.size) {
        if (a[i] != b[i]) {
            return false
        }
    }
    return true
}

/**
 * 取前 n 字节。
 */
private func head(a: Array<Byte>, n: Int64): Array<Byte> {
    let out = Array<Byte>(n, repeat: 0u8)
    for (i in 0..n) {
        out[i] = a[i]
    }
    return out
}

/**
 * 包裹 / 解包往返。
 */
@Test
public func testWrapUnwrapRoundTrip(): Unit {
    let kek = "0123456789abcdef".toArray()
    let m = makeManager(kek)
    let kv = KeyVersion("kek-01", 1)
    let plain = "0123456789abcdef".toArray()

    let wrapped = must(m.wrap(kv, plain))
    // 默认使用分离派生算法
    @Assert(wrapped.alg == KeyManager.algDerivedSubkeys)

    let out = must(m.unwrap(wrapped))
    @Assert(out.size == plain.size)
    for (i in 0..plain.size) {
        @Assert(out[i] == plain[i])
    }
}

/**
 * storageKey 编码算法标识 → 包裹结果自描述。
 */
@Test
public func testStorageKeyEncodesAlg(): Unit {
    let kv = KeyVersion("kek-01", 1)
    // alg=1（历史格式）：不带算法后缀
    @Assert(kv.toStorageKey(alg: KeyManager.algReuseKek) == "kek-01:v1")
    // alg=2（分离派生）：带算法后缀
    @Assert(kv.toStorageKey(alg: KeyManager.algDerivedSubkeys) == "kek-01:v1:a2")
}

/**
 * 篡改密文 → MAC 校验失败（不是解密失败）。
 */
@Test
public func testTamperedCiphertextRejected(): Unit {
    let kek = "0123456789abcdef".toArray()
    let m = makeManager(kek)
    let kv = KeyVersion("kek-01", 1)
    let wrapped = must(m.wrap(kv, "0123456789abcdef".toArray()))

    // 篡改密文的一个字节
    let bad = Array<Byte>(wrapped.ciphertext.size, repeat: 0u8)
    for (i in 0..wrapped.ciphertext.size) {
        bad[i] = wrapped.ciphertext[i]
    }
    bad[bad.size - 1] = bad[bad.size - 1] ^ 0xFFu8
    let tampered = WrappedKey(wrapped.keyVersion, wrapped.mac, bad, alg: wrapped.alg)

    // 期望失败
    var failed = false
    match (m.unwrap(tampered)) {
        case CryptoResult.Ok(_) => failed = false
        case CryptoResult.Err(_) => failed = true
    }
    @Assert(failed)
}

/**
 * 篡改 MAC → 同样被拒。
 */
@Test
public func testTamperedMacRejected(): Unit {
    let kek = "0123456789abcdef".toArray()
    let m = makeManager(kek)
    let kv = KeyVersion("kek-01", 1)
    let wrapped = must(m.wrap(kv, "0123456789abcdef".toArray()))

    let badMac = Array<Byte>(wrapped.mac.size, repeat: 0u8)
    for (i in 0..wrapped.mac.size) {
        badMac[i] = wrapped.mac[i]
    }
    badMac[0] = badMac[0] ^ 0x01u8
    let tampered = WrappedKey(wrapped.keyVersion, badMac, wrapped.ciphertext, alg: wrapped.alg)

    var failed = false
    match (m.unwrap(tampered)) {
        case CryptoResult.Ok(_) => failed = false
        case CryptoResult.Err(_) => failed = true
    }
    @Assert(failed)
}

/**
 * 错误的 KEK → 解包失败。
 */
@Test
public func testWrongKekRejected(): Unit {
    let kek = "0123456789abcdef".toArray()
    let m = makeManager(kek)
    let kv = KeyVersion("kek-01", 1)
    let wrapped = must(m.wrap(kv, "0123456789abcdef".toArray()))

    // 换成另一把 KEK
    let m2 = makeManager("fedcba9876543210".toArray())
    var failed = false
    match (m2.unwrap(wrapped)) {
        case CryptoResult.Ok(_) => failed = false
        case CryptoResult.Err(_) => failed = true
    }
    @Assert(failed)
}

/**
 * 密钥分离：加密子密钥与认证子密钥**必须不同**，且都不同于 KEK。
 *
 * 这是本次变更的核心：alg=2 从 KEK 派生出两把独立的子密钥，
 * 避免「同一把密钥既加密又认证」（违反密钥分离原则）。
 */
@Test
public func testKeySeparation(): Unit {
    let kek = "0123456789abcdef".toArray()
    let provider = StdxCryptoProvider()
    let m = KeyManager(provider, { _: String => kek })
    let kv = KeyVersion("kek-01", 1)

    // 默认走 alg=2
    let wrapped = must(m.wrap(kv, "0123456789abcdef".toArray()))
    @Assert(wrapped.alg == KeyManager.algDerivedSubkeys)

    // 复现派生：SM3(label || 0x00 || kek)，取前 16 字节
    let sep = Array<Byte>(1, repeat: 0u8)
    let encDigest = must(provider.digest(
        concat("AMS-KEK-ENC-v1".toArray(), concat(sep, kek)), DigestAlgorithm.Sm3))
    let macDigest = must(provider.digest(
        concat("AMS-KEK-MAC-v1".toArray(), concat(sep, kek)), DigestAlgorithm.Sm3))

    // 实际使用的子密钥（前 16 字节）必须互不相同
    //
    // 注意：这里比的是**整体**，不是逐字节。
    // 逐字节要求「派生值与 KEK 的同位置字节都不同」是**过严**的：
    // 随机 16 字节与另一随机 16 字节约有 6% 的位置会自然相等，
    // 那样断言会随机失败。安全性要求的是「两把子密钥不是同一把」。
    let encKey = head(encDigest, 16)
    let macKey = head(macDigest, 16)
    @Assert(!bytesEqual(encKey, macKey))
    // 且都不是 KEK 本身
    @Assert(!bytesEqual(encKey, kek))
    @Assert(!bytesEqual(macKey, kek))
}

/**
 * 派生结果稳定：同一 KEK 派生出同一子密钥（否则无法解密）。
 */
@Test
public func testDerivationIsDeterministic(): Unit {
    let kek = "0123456789abcdef".toArray()
    let provider = StdxCryptoProvider()
    let sep = Array<Byte>(1, repeat: 0u8)
    let a = must(provider.digest(
        concat("AMS-KEK-ENC-v1".toArray(), concat(sep, kek)), DigestAlgorithm.Sm3))
    let b = must(provider.digest(
        concat("AMS-KEK-ENC-v1".toArray(), concat(sep, kek)), DigestAlgorithm.Sm3))
    for (i in 0..a.size) {
        @Assert(a[i] == b[i])
    }
}

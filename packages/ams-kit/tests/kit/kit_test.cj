// ============================================================
// ams.kit · 框架对外 API 单元测试
//
// 验证 functional facade 的三个工厂与版本常量可用、且返回的能力真实可用
// （不做「永远返回非空」的弱断言 —— 直接跑密码学原语的已知向量 / 往返）。
//
// 编译运行：bash scripts/test.sh ams-kit
// ============================================================
package ams.kit.test

import std.unittest.*
import stdx.encoding.hex.*

import ams.kit.*
import ams.crypto.provider.*
import ams.crypto.key.*
import ams.crypto.blindindex.*


@Test
public class KitFacadeTest {
    private let provider = newCryptoProvider()

    // ---- 版本常量 ----

    @TestCase
    public func testKitVersionNonEmpty() {
        @Assert(KIT_VERSION.size > 0, true)
        // 与 CHANGELOG / cjpm.toml 对齐的 0.1.0-alpha
        @Assert(KIT_VERSION, "0.1.0-alpha")
    }

    // ---- 密码学提供者工厂 ----

    @TestCase
    public func testNewCryptoProviderSm3Vector() {
        // 工厂返回的提供者必须真正可用：SM3("abc") = GM/T 0004-2012 标准向量
        let r = this.provider.digest("abc".toArray(), DigestAlgorithm.Sm3)
        match (r) {
            case CryptoResult.Ok(d) => @Assert(toHexString(d),
                "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0")
            case CryptoResult.Err(_) => @Assert(true, false)
        }
    }

    // ---- 密钥管理工厂 ----

    @TestCase
    public func testNewKeyManagerRoundTrip() {
        // KEK 至少 16 字节（128 bit 下限）
        let kek = "ams-dev-kek-change-me-in-prod".toArray()
        let km = newKeyManager(this.provider, kek)
        let dek = "0123456789abcdef".toArray()   // 已知 16 字节 DEK
        match (km.wrap(KeyVersion("k1", 1), dek)) {
            case CryptoResult.Ok(wrapped) =>
                match (km.unwrap(wrapped)) {
                    case CryptoResult.Ok(recovered) =>
                        @Assert(this.provider.constantTimeEquals(recovered, dek), true)
                    case CryptoResult.Err(_) => @Assert(true, false)
                }
            case CryptoResult.Err(_) => @Assert(true, false)
        }
    }

    // ---- 盲索引工厂 ----

    @TestCase
    public func testNewBlindIndexGenerateAndMatch() {
        let bi = newBlindIndex(this.provider)
        let dk = "0123456789abcdef0123456789abcdef".toArray()  // 32 字节派生密钥
        match (bi.generate(dk, "Value123", NormalizeRule.GenericV1)) {
            case CryptoResult.Ok(idx) => @Assert(idx.size, 32)   // SM3 摘要长度
            case CryptoResult.Err(_) => @Assert(true, false)
        }
        // 归一化（小写）后命中
        @Assert(bi.matches(dk, "VALUE123", "value123", NormalizeRule.GenericV1), true)
        // 不同值不命中
        @Assert(bi.matches(dk, "Different", "value123", NormalizeRule.GenericV1), false)
    }
}

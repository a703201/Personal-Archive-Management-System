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
import std.collection.*
import stdx.encoding.hex.*

import ams.kit.*
import ams.crypto.provider.*
import ams.crypto.key.*
import ams.crypto.blindindex.*
import ams.security.audit.*


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

// ============================================================
// Phase 3（docs/15 §4.1）：审计哈希链 / 检索 / 导入模板内核
// 不做「非空即通过」的弱断言 —— 每个 facade 都跑真实能力。
// ============================================================
@Test
public class KitPhase3Test {
    private let provider = newCryptoProvider()

    @TestCase
    public func testAuditChainFacadeComputesRealHash() {
        let g = auditGenesisHash()
        @Assert(g.size, 32)
        var allZero = true
        for (b in g) {
            if (b != 0u8) { allZero = false }
        }
        @Assert(allZero, true)

        let chain = newAuditChain(this.provider)
        let e = AuditEntry(
            1, "u1", ActorType.User, AuditAction.Login, "登录", "user", "u1", "s1", 0,
            AuditResult.Success, "", "127.0.0.1", "kit-test", "trace1",
            Array<(String, String)>(), 1790000000000
        )
        match (chain.computeHash(e, g)) {
            case CryptoResult.Ok(h) => @Assert(h.size, 32)   // 真 SM3 摘要
            case CryptoResult.Err(_) => @Assert(true, false)
        }
    }

    @TestCase
    public func testSearchFacades() {
        let toks = tokenizeForSearch("档案管理系统")
        @Assert(toks.size > 0, true)
        var hasBigram = false
        for (t in toks) {
            if (t == "档案") { hasBigram = true }
        }
        @Assert(hasBigram, true)
        // 掩码按字符而非字节，中文首尾各留 1 字
        let m = maskValue("市公安局", 2)
        @Assert(m.startsWith("市"), true)
        @Assert(m.endsWith("局"), true)
        // 高亮分段 JSON 命中与未命中都在
        let j = highlightJson("清华大学硕士学位证书", "硕士")
        @Assert(j.contains("\"hit\":true"), true)
        @Assert(j.contains("学位证书"), true)
    }

    @TestCase
    public func testCsvColumnTemplateMappingAndDefaults() {
        let mapping = HashMap<String, String>()
        mapping["姓名"] = "title"
        mapping["编号"] = "external_id"
        let defaults = HashMap<String, String>()
        defaults["status"] = "1"
        let t = CsvColumnTemplate(["姓名", "编号", "备注"], mapping, defaults)
        @Assert(t.hasField("title"), true)
        @Assert(t.hasField("备注"), false)
        @Assert(t.resolve("title", ["张三", "A001", "x"]), "张三")
        @Assert(t.resolve("external_id", ["张三", "A001", "x"]), "A001")
        // 未映射字段走默认值
        @Assert(t.resolve("status", ["张三"]), "1")
        // 已映射但缺列、且无默认值 → 空串（不抛异常）
        @Assert(t.resolve("title", []), "")
    }

    @TestCase
    public func testCsvColumnTemplateDuplicateHeaderFirstWins() {
        let mapping = HashMap<String, String>()
        mapping["姓名"] = "title"
        let t = CsvColumnTemplate(["姓名", "姓名"], mapping, HashMap<String, String>())
        @Assert(t.resolve("title", ["第一列", "第二列"]), "第一列")
    }
}

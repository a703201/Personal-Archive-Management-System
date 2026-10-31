// ============================================================
// ams.app.importer · 导出包回导验签（FR-EXP-008）
//
// [为什么手工组包而不是读真实导出产物]
//   验签的关键是「签名覆盖 manifest 原文 + items 原文」，
//   测试必须能精确构造「只改一个字节」的样本。故这里按导出侧
//   （ams.app.export.async.bundle）同一格式手工拼包，再用同一个
//   StdxCryptoProvider 计算摘要。
//
//   钉住的是「校验算法对原始字节逐一致性的要求」：
//   任何重新序列化、任何空白差异，都必须被判为不匹配。
// ============================================================
package ams.app.importer.test

import std.collection.*
import std.unittest.*

import ams.app.importer.*
import ams.crypto.impl.*
import ams.crypto.provider.*

/** 十六进制编码（测试用）。 */
func toHex(bytes: Array<Byte>): String {
    let hex = ["0", "1", "2", "3", "4", "5", "6", "7",
               "8", "9", "a", "b", "c", "d", "e", "f"]
    let sb = StringBuilder()
    for (b in bytes) {
        let v = Int64(b)
        sb.append(hex[(v >> 4) & 15])
        sb.append(hex[v & 15])
    }
    return sb.toString()
}

/** 按导出侧格式手工组一个合法的可携带导出包。 */
func makeBundle(
    provider: CryptoProvider,
    signKey: String,
    itemsJson: String,
    tag: String
): String {
    let itemsSha = match (provider.digest(itemsJson.toArray(), DigestAlgorithm.Sha256)) {
        case CryptoResult.Ok(b) => toHex(b)
        case CryptoResult.Err(_) => ""
    }
    let manifest = "{\"type\":\"ams-portable-export\",\"version\":1," +
                   "\"taskNo\":\"${tag}\",\"generatedAt\":1700000000000," +
                   "\"itemCount\":1,\"truncated\":false," +
                   "\"segments\":[{\"name\":\"items\",\"bytes\":${itemsJson.toArray().size}," +
                   "\"sha256\":\"${itemsSha}\"}]}"
    let signed = "${manifest}${itemsJson}"
    let sig = match (provider.hmac(signKey.toArray(), signed.toArray(), DigestAlgorithm.Sm3)) {
        case CryptoResult.Ok(b) => toHex(b)
        case CryptoResult.Err(_) => ""
    }
    return "{\"manifest\":${manifest},\"items\":${itemsJson}," +
           "\"signature\":{\"alg\":\"HMAC-SM3\",\"value\":\"${sig}\"}}"
}

@Test
public class BundleVerifyTest {
    func sampleItems(): String {
        return "[{\"id\":\"1\",\"subjectId\":\"7\",\"category\":3," +
               "\"title\":\"本科学历证书\",\"status\":0,\"sensitivity\":1," +
               "\"issuer\":\"某大学\",\"issuedDate\":\"2020-09-01\"," +
               "\"expiresAt\":\"\",\"updatedMs\":1700000000000}]"
    }

    @TestCase
    public func testValidBundlePasses() {
        let provider: CryptoProvider = StdxCryptoProvider()
        let key = "test-sign-key-32-bytes-0123456789"
        let bundle = makeBundle(provider, key, this.sampleItems(), "EXP1")
        let r = ImportService.verifyPortableBundle(Some(provider), key, bundle)
        @Assert(r.valid, true)
        @Assert(r.alg, "HMAC-SM3")
        @Assert(r.itemCount, 1)
    }

    @TestCase
    public func testTamperedItemsRejected() {
        let provider: CryptoProvider = StdxCryptoProvider()
        let key = "test-sign-key-32-bytes-0123456789"
        let bundle = makeBundle(provider, key, this.sampleItems(), "EXP1")
        // 改一个字符：签名对不上，必须拒绝
        let tampered = bundle.replace("本科学历证书", "被篡改的证书")
        let r = ImportService.verifyPortableBundle(Some(provider), key, tampered)
        @Assert(r.valid, false)
    }

    @TestCase
    public func testWrongKeyRejected() {
        let provider: CryptoProvider = StdxCryptoProvider()
        let bundle = makeBundle(provider, "key-a", this.sampleItems(), "EXP1")
        let r = ImportService.verifyPortableBundle(Some(provider), "key-b", bundle)
        @Assert(r.valid, false)
    }

    @TestCase
    public func testMissingSignatureRejected() {
        let provider: CryptoProvider = StdxCryptoProvider()
        let bundle = "{\"manifest\":{\"type\":\"x\",\"itemCount\":0,\"segments\":[]},\"items\":[]}"
        let r = ImportService.verifyPortableBundle(Some(provider), "k", bundle)
        @Assert(r.valid, false)
    }

    @TestCase
    public func testUnsupportedAlgRejected() {
        let provider: CryptoProvider = StdxCryptoProvider()
        let bundle = "{\"manifest\":{\"type\":\"x\",\"itemCount\":0,\"segments\":[]}," +
                     "\"items\":[],\"signature\":{\"alg\":\"SM2\",\"value\":\"deadbeef\"}}"
        let r = ImportService.verifyPortableBundle(Some(provider), "k", bundle)
        @Assert(r.valid, false)
    }
}

// ============================================================
// ams-storage · AWS Signature V4 单元测试
//
// 基准：AWS 官方文档「Example: GET Object」向量
//   AK  AKIAIOSFODNN7EXAMPLE / SK wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
//   GET /test.txt, 20130524T000000Z, us-east-1 / s3
//   Signature = f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41
//
// 中间值（canonical hash / string-to-sign hash / signing key）由一份独立的
// Python hashlib+hmac 实现交叉算出，便于任何一步出错时定位，而不是只看最终签名。
//
// 注意：这是**真实可用的签名计算**，不是骨架；搭配 http_transport.cj 的
// HttpS3Transport（SigV4 + 自实现 HTTP/1.1 客户端）即为完整可用的对象存储驱动。
// ============================================================
package ams.storage.test

import std.unittest.*
import std.collection.*

import ams.crypto.impl.*
import ams.storage.*

@Test
public class SigV4Test {
    private let signer = SigV4Signer(StdxCryptoProvider())
    private static let EMPTY_SHA256: String =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /** headers 故意乱序且大写，验证 normalizeHeaders 会自动小写 + 排序。 */
    private static func exampleHeaders(): Array<SigV4Header> {
        return [
            SigV4Header("X-Amz-Date", "20130524T000000Z"),
            SigV4Header("Range", " bytes=0-9 "),
            SigV4Header("Host", "examplebucket.s3.amazonaws.com"),
            SigV4Header("X-Amz-Content-Sha256", SigV4Test.EMPTY_SHA256)
        ]
    }

    private func example(): SigV4Result {
        return this.signer.sign(
            "GET", "/test.txt", "", SigV4Test.exampleHeaders(),
            SigV4Test.EMPTY_SHA256,
            "AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "us-east-1", "s3", "20130524T000000Z")
    }

    @TestCase
    public func testEmptyPayloadHash() {
        @Assert(this.signer.payloadHash(Array<Byte>(0, repeat: 0u8)),
            SigV4Test.EMPTY_SHA256)
    }

    @TestCase
    public func testAwsOfficialExampleSignature() {
        let r = this.example()
        @Assert(r.signature,
            "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @TestCase
    public func testAwsOfficialExampleIntermediateValues() {
        let r = this.example()
        @Assert(r.canonicalRequestHash,
            "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972")
        @Assert(r.stringToSignHash,
            "d13fa69f8728f0ba10a9fdfb29c15582bc9a47e376d4f69b5a77bd095f18c682")
        @Assert(r.signingKeyHex,
            "dbb893acc010964918f1fd433add87c70e8b0db6be30c1fbeafefa5ec6ba8378")
    }

    @TestCase
    public func testScopeAndSignedHeaders() {
        let r = this.example()
        @Assert(r.scope, "20130524/us-east-1/s3/aws4_request")
        @Assert(r.signedHeaders, "host;range;x-amz-content-sha256;x-amz-date")
        @Assert(r.canonicalRequest.contains("host:examplebucket.s3.amazonaws.com"), true)
        // 值首尾空白被裁剪
        @Assert(r.canonicalRequest.contains("range:bytes=0-9"), true)
    }

    @TestCase
    public func testAuthorizationHeader() {
        let r = this.example()
        @Assert(r.authorization,
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " +
            "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, " +
            "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @TestCase
    public func testSecretKeyNeverLeaksIntoResult() {
        let r = this.example()
        let sk = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        @Assert(r.authorization.contains(sk), false)
        @Assert(r.canonicalRequest.contains(sk), false)
        @Assert(r.stringToSign.contains(sk), false)
        @Assert(r.signingKeyHex.contains(sk), false)
    }

    @TestCase
    public func testDifferentRegionChangesSignature() {
        let a = this.example()
        let b = this.signer.sign(
            "GET", "/test.txt", "", SigV4Test.exampleHeaders(),
            SigV4Test.EMPTY_SHA256,
            "AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "cn-north-4", "s3", "20130524T000000Z")
        @Assert(a.signature == b.signature, false)
        @Assert(b.scope.contains("cn-north-4"), true)
    }

    @TestCase
    public func testSignatureIsDeterministic() {
        @Assert(this.example().signature, this.example().signature)
    }

    @TestCase
    public func testPutObjectIsAlsoSignable() {
        let body = "archive-ciphertext".toArray()
        let hash = this.signer.payloadHash(body)
        @Assert(hash.size, 64)
        let headers = [
            SigV4Header("Host", "ams-attachments.obs.cn-north-4.myhuaweicloud.com"),
            SigV4Header("X-Amz-Date", "20261108T140000Z"),
            SigV4Header("X-Amz-Content-Sha256", hash)
        ]
        let r = this.signer.sign(
            "PUT", "/ams-attachments/attachments/a1.enc", "", headers, hash,
            "AK-EXAMPLE", "SK-EXAMPLE", "cn-north-4", "s3", "20261108T140000Z")
        @Assert(r.scope, "20261108/cn-north-4/s3/aws4_request")
        @Assert(r.signedHeaders, "host;x-amz-content-sha256;x-amz-date")
        @Assert(r.signature.size, 64)
        @Assert(r.authorization.contains(
            "Credential=AK-EXAMPLE/20261108/cn-north-4/s3/aws4_request"), true)
    }

    @TestCase
    public func testMissingCredentialsRejected() {
        var rejected = false
        try {
            let r = this.signer.sign(
                "GET", "/x", "", SigV4Test.exampleHeaders(), SigV4Test.EMPTY_SHA256,
                "", "", "us-east-1", "s3", "20130524T000000Z")
            if (r.signature.size > 0) { rejected = false }
        } catch (e: Exception) {
            rejected = true
        }
        @Assert(rejected, true)
    }
}

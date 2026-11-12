// ============================================================
// ams-storage · AWS Signature V4 签名器（多厂商 OBS 共用）
//
// 【适用范围】
//   华为云 OBS / 阿里云 OSS / 腾讯云 COS / 七牛 S3 兼容网关 / AWS S3 /
//   自建 MinIO 都接受 SigV4。本类把签名计算（最容易各家写歪的部分）
//   收敛成一份实现，厂商间只差 endpoint、region 与寻址风格（见 providers.cj）。
//
// 【依赖】
//   `ams.crypto.provider.CryptoProvider.hmac(..., Sha256)` —— 本批补上的
//   HMAC-SHA256（RFC 2104 + stdx SHA256），已用 RFC 4231 向量验证。
//
// 【已验证】
//   AWS 官方文档「Example: GET Object」完整向量：
//   Signature = f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41
//   见 packages/ams-storage/tests/storage/sigv4_test.cj。
//
// 【如实边界】
//   本类只做**签名计算**，不发 HTTP 请求。真正的 S3Transport（请求构造 +
//   TLS + 错误码映射）仍未实现；因此各家对象存储尚不能真实上传。
//   canonical headers 的规范化按 SigV4 要求做了「名称小写 + 字典序排序 +
//   值首尾空白裁剪」，但**未实现**多值 header 合并与连续内部空白压缩
//   （这两类在本项目的 GET/PUT 对象请求里不出现）。
//
// 【安全】
//   secretKey 只参与中间 HMAC 计算，绝不进入 SigV4Result / 日志 / 异常消息。
// ============================================================
package ams.storage

import std.collection.*

import ams.crypto.provider.*
import ams.kernel.error.*

/** 参与签名的 HTTP 头（name 会被自动转小写并排序）。 */
public class SigV4Header {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        this.name = name
        this.value = value
    }
}

/** 签名结果（含各中间值，便于审计与单测定位；不含任何密钥）。 */
public class SigV4Result {
    public let canonicalRequest: String
    public let canonicalRequestHash: String
    public let stringToSign: String
    public let stringToSignHash: String
    public let signingKeyHex: String
    public let scope: String
    public let signedHeaders: String
    public let signature: String
    public let authorization: String

    public init(
        canonicalRequest: String, canonicalRequestHash: String,
        stringToSign: String, stringToSignHash: String, signingKeyHex: String,
        scope: String, signedHeaders: String, signature: String, authorization: String
    ) {
        this.canonicalRequest = canonicalRequest
        this.canonicalRequestHash = canonicalRequestHash
        this.stringToSign = stringToSign
        this.stringToSignHash = stringToSignHash
        this.signingKeyHex = signingKeyHex
        this.scope = scope
        this.signedHeaders = signedHeaders
        this.signature = signature
        this.authorization = authorization
    }
}

public class SigV4Signer {
    private static let ALGORITHM: String = "AWS4-HMAC-SHA256"
    private static let TERMINATOR: String = "aws4_request"
    private static let HEX_DIGITS: Array<String> = [
        "0", "1", "2", "3", "4", "5", "6", "7",
        "8", "9", "a", "b", "c", "d", "e", "f"
    ]

    private let provider: CryptoProvider

    public init(provider: CryptoProvider) {
        this.provider = provider
    }

    /** 便捷方法：算请求体（payload）的 SHA256 hex；空体对应 SigV4 的 EMPTY_SHA256。 */
    public func payloadHash(payload: Array<Byte>): String {
        return SigV4Signer.hexOf(this.digestBytes(payload))
    }

    /**
     * 计算 SigV4 签名。
     *
     * @param method        GET / PUT / DELETE（大写）
     * @param canonicalUri  已 URI 编码的路径，如 `/ams-attachments/attachments/a.enc`
     * @param canonicalQuery 已排序的查询串（无参数时传空串）
     * @param headers       参与签名的头；自动小写 + 按名称字典序排序
     * @param payloadHashHex payload 的 SHA256 hex（用 payloadHash() 生成）
     * @param amzDate       ISO8601 基本格式 `yyyyMMdd'T'HHmmss'Z'`
     */
    public func sign(
        method: String,
        canonicalUri: String,
        canonicalQuery: String,
        headers: Array<SigV4Header>,
        payloadHashHex: String,
        accessKey: String,
        secretKey: String,
        region: String,
        service: String,
        amzDate: String
    ): SigV4Result {
        if (accessKey.isEmpty() || secretKey.isEmpty()) {
            throw validationError("credentials", "SigV4 需要 AK / SK")
        }
        if (amzDate.size < 8) {
            throw validationError("amzDate", "amzDate 必须是 yyyyMMddTHHmmssZ 格式")
        }
        let dateStamp = amzDate[0..8]
        let scope = "${dateStamp}/${region}/${service}/${SigV4Signer.TERMINATOR}"

        let sorted = SigV4Signer.normalizeHeaders(headers)
        let canonicalHeaders = StringBuilder()
        let signedList = StringBuilder()
        var i: Int64 = 0
        while (i < sorted.size) {
            canonicalHeaders.append("${sorted[i].name}:${sorted[i].value}\n")
            if (i > 0) {
                signedList.append(";")
            }
            signedList.append(sorted[i].name)
            i = i + 1
        }
        let signedHeaders = signedList.toString()

        // SigV4 canonical request（注意 canonicalHeaders 自身以 \n 结尾，
        // 拼接时再补一个 \n，与官方示例一致）
        let sb = StringBuilder()
        sb.append("${method}\n${canonicalUri}\n${canonicalQuery}\n")
        sb.append(canonicalHeaders.toString())
        sb.append("\n${signedHeaders}\n${payloadHashHex}")
        let canonicalRequest = sb.toString()
        let crHash = SigV4Signer.hexOf(this.digestBytes(canonicalRequest.toArray()))

        let sts = "${SigV4Signer.ALGORITHM}\n${amzDate}\n${scope}\n${crHash}"
        let stsHash = SigV4Signer.hexOf(this.digestBytes(sts.toArray()))

        // 派生签名密钥：HMAC 链 AWS4+SK -> date -> region -> service -> terminator
        let k0 = this.hmacBytes("AWS4${secretKey}".toArray(), dateStamp.toArray())
        let k1 = this.hmacBytes(k0, region.toArray())
        let k2 = this.hmacBytes(k1, service.toArray())
        let signingKey = this.hmacBytes(k2, SigV4Signer.TERMINATOR.toArray())
        let sig = SigV4Signer.hexOf(this.hmacBytes(signingKey, sts.toArray()))

        let auth = "${SigV4Signer.ALGORITHM} Credential=${accessKey}/${scope}, " +
                   "SignedHeaders=${signedHeaders}, Signature=${sig}"
        return SigV4Result(
            canonicalRequest, crHash, sts, stsHash,
            SigV4Signer.hexOf(signingKey), scope, signedHeaders, sig, auth)
    }

    // ---------------------------------------------------------
    // 内部工具
    // ---------------------------------------------------------

    private func digestBytes(data: Array<Byte>): Array<Byte> {
        match (this.provider.digest(data, DigestAlgorithm.Sha256)) {
            case CryptoResult.Ok(d) => return d
            case CryptoResult.Err(e) => throw e
        }
    }

    private func hmacBytes(key: Array<Byte>, data: Array<Byte>): Array<Byte> {
        match (this.provider.hmac(key, data, DigestAlgorithm.Sha256)) {
            case CryptoResult.Ok(m) => return m
            case CryptoResult.Err(e) => throw e
        }
    }

    private static func hexOf(data: Array<Byte>): String {
        let sb = StringBuilder()
        for (b in data) {
            let v = Int64(b)
            sb.append(SigV4Signer.HEX_DIGITS[(v >> 4) & 15])
            sb.append(SigV4Signer.HEX_DIGITS[v & 15])
        }
        return sb.toString()
    }

    /** 头名称转 ASCII 小写、值首尾空白裁剪，再按名称字节序升序。 */
    private static func normalizeHeaders(headers: Array<SigV4Header>): Array<SigV4Header> {
        let a = ArrayList<SigV4Header>()
        for (h in headers) {
            a.add(SigV4Header(SigV4Signer.lowerAscii(h.name), SigV4Signer.trim(h.value)))
        }
        // 插入排序（header 数 <= 10，无需引排序库；也不用猜 String 的 '<' 运算符）
        var i: Int64 = 1
        while (i < a.size) {
            let key = a[i]
            var j = i - 1
            while (j >= 0 && SigV4Signer.strLess(key.name, a[j].name)) {
                a[j + 1] = a[j]
                j = j - 1
            }
            a[j + 1] = key
            i = i + 1
        }
        return a.toArray()
    }

    /** 字节序字典比较（header 名均为 ASCII）。 */
    private static func strLess(a: String, b: String): Bool {
        let n = if (a.size < b.size) { a.size } else { b.size }
        var i: Int64 = 0
        while (i < n) {
            if (a[i] < b[i]) {
                return true
            }
            if (a[i] > b[i]) {
                return false
            }
            i = i + 1
        }
        return a.size < b.size
    }

    /**
     * HTTP header 名按规范只能是 ASCII token，故逐字节处理是安全的；
     * 大写转小写用 Rune 生成字符，避免 `String.fromUtf8([单字节])` 的
     * 类型推断陷阱（本仓 ocr.cj 踩过）。
     */
    private static func lowerAscii(s: String): String {
        let sb = StringBuilder()
        var i: Int64 = 0
        while (i < s.size) {
            let b = s[i]
            if (b >= 0x41u8 && b <= 0x5Au8) {
                sb.append(Rune(Int32(Int64(b) + 32)))
            } else {
                sb.append(s[i..(i + 1)])
            }
            i = i + 1
        }
        return sb.toString()
    }

    private static func trim(s: String): String {
        var a: Int64 = 0
        var b: Int64 = s.size
        while (a < b && SigV4Signer.isSpace(s[a])) {
            a = a + 1
        }
        while (b > a && SigV4Signer.isSpace(s[b - 1])) {
            b = b - 1
        }
        return s[a..b]
    }

    private static func isSpace(b: Byte): Bool {
        return b == 0x20u8 || b == 0x09u8 || b == 0x0Au8 || b == 0x0Du8
    }
}

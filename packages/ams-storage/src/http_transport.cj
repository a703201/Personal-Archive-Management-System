// ============================================================
// ams-storage · 真实 S3/OBS HTTP 传输层（Q2 方案 A 落地）
//
// 【本次补齐：S3Transport 的 HTTP 客户端】
//   此前只有 SigV4 签名计算 + 失败关闭的 UnavailableS3Transport。
//   现用仓颉标准库 std.net（TcpSocket / StreamingSocket）+ stdx.net.tls
//   （TlsSocket）自实现 HTTP/1.1 客户端，把经过 SigV4 签名的请求**真正发出**：
//     · PUT 对象（附件密文上传）
//     · GET 对象（404 → None，其他错误 → AppError 失败关闭）
//     · DELETE 对象（可选，便于将来 StorageBackend 增加删除）
//   寻址风格（path-style / virtual-host）完全由 S3StorageConfig.objectUrl
//   决定；HTTP 与 HTTPS（TLS）均可用 —— 因此 MinIO 与各家云 OBS
//   （华为/阿里/腾讯/七牛/AWS）走同一份代码，差异仅在 endpoint / region /
//   寻址风格（见 providers.cj），由运维配置驱动。
//
// 【为什么不自成 HTTP/2 客户端】
//   选择自实现 HTTP/1.1 而非 stdx.net.http 的 HttpClient：S3 接口就是
//   普通的签名 GET/PUT/DELETE，HTTP/1.1 足够且行为完全可控（尤其响应解析
//   与「404 = 对象不存在」的语义映射），不依赖对 stdx HTTP 客户端 API 的猜测。
//   底层 TCP / TLS 复用 opengauss 驱动已验证可用的 std.net / stdx.net.tls 原语。
//
// 【安全约束】
//   ① 凭据（SK）只参与 SigV4 HMAC 派生，绝不进入日志 / 异常 / Authorization 之外的任何字段。
//   ② 失败关闭：连接失败 / 非预期状态码 / 响应不完整 → 抛 AppError(StorageFailure)，
//      绝不返回空内容伪装「对象不存在」（只有真正的 HTTP 404 才映射为 None）。
//   ③ TLS 默认校验证书（TlsClientConfig 默认行为），不降级为明文回落。
//
// 【依赖】
//   std.net（TcpSocket/StreamingSocket）、stdx.net.tls（TlsSocket）、
//   ams.crypto.impl（StdxCryptoProvider，仅 forConfig 默认实现）、
//   ams.kernel.error（AppError）。
// ============================================================
package ams.storage

import std.collection.*
import std.net.*
import stdx.net.tls.*
import std.time.*

import ams.crypto.provider.*
import ams.crypto.impl.*
import ams.kernel.error.*

/** 解析后的 URL：scheme / host / port / 已编码路径 / Host 头值。 */
public class ParsedUrl {
    public let scheme: String
    public let host: String
    public let port: UInt16
    public let path: String
    public let hostHeader: String

    public init(
        scheme: String, host: String, port: UInt16, path: String, hostHeader: String
    ) {
        this.scheme = scheme
        this.host = host
        this.port = port
        this.path = path
        this.hostHeader = hostHeader
    }
}

/**
 * 真实 S3 兼容 HTTP 传输层。
 *
 * 这是把「选某家 OBS 并真正读写」从骨架变成可用的关键一环：
 * 签名由 SigV4Signer 完成（sigv4.cj），本类负责组装 HTTP 请求、建立连接、
 * 发送、读取并解析响应。
 */
public class HttpS3Transport <: S3Transport {
    private let config: S3StorageConfig
    private let provider: CryptoProvider
    private let signer: SigV4Signer
    private let connectTimeout: Duration
    private let ioTimeout: Duration

    public init(config: S3StorageConfig, provider: CryptoProvider) {
        config.validate()
        this.config = config
        this.provider = provider
        this.signer = SigV4Signer(provider)
        this.connectTimeout = Duration.second * 10
        this.ioTimeout = Duration.second * 60
    }

    /** 用默认 stdx 密码提供者构造（工厂与测试便捷入口）。 */
    public static func forConfig(config: S3StorageConfig): HttpS3Transport {
        return HttpS3Transport(config, StdxCryptoProvider())
    }

    public func putObject(url: String, data: Array<Byte>): Unit {
        let r = this.request("PUT", url, data, [200, 204])
        // 成功返回 Some（body 可能为空）；PUT 不会返回 404，若异常已被 request 抛出。
        if (r.isNone()) {
            throw AppError(AppErrorKind.StorageFailure,
                "OBS 上传未收到预期响应（${url}）")
        }
    }

    public func getObject(url: String): Option<Array<Byte>> {
        match (this.request("GET", url, Array<Byte>(), [200, 206])) {
            case Some(b) => return Some(b)
            case None => return None
        }
    }

    /** 删除对象（S3 DELETE）；成功返回 Unit，失败抛 AppError。 */
    public func deleteObject(url: String): Unit {
        this.request("DELETE", url, Array<Byte>(), [200, 204])
    }

    /**
     * 发送一次 SigV4 签名的 HTTP 请求。
     * 返回 Some(body) 表示成功取到对象；None **仅**在 GET 且 HTTP 404 时返回，
     * 用于把「对象不存在」与「存储故障」明确区分（存附件前已由上层加密，这里只存密文）。
     */
    private func request(
        method: String, url: String, body: Array<Byte>, okCodes: Array<Int64>
    ): Option<Array<Byte>> {
        let parsed = HttpS3Transport.parseUrl(url)
        let payloadHash = this.payloadHashHex(body)
        let amzDate = HttpS3Transport.amzDateNow()

        let sig = this.signer.sign(
            method,
            parsed.path,
            "",
            [
                SigV4Header("host", parsed.hostHeader),
                SigV4Header("x-amz-content-sha256", payloadHash),
                SigV4Header("x-amz-date", amzDate)
            ],
            payloadHash,
            this.config.accessKey,
            this.config.secretKey,
            this.config.region,
            "s3",
            amzDate)

        // 请求头文本（顺序无关，签名只认 SignedHeaders 列表）
        let sb = StringBuilder()
        sb.append("${method} ${parsed.path} HTTP/1.1\r\n")
        sb.append("Host: ${parsed.hostHeader}\r\n")
        sb.append("x-amz-date: ${amzDate}\r\n")
        sb.append("x-amz-content-sha256: ${payloadHash}\r\n")
        sb.append("Content-Type: application/octet-stream\r\n")
        sb.append("Content-Length: ${body.size}\r\n")
        sb.append("Authorization: ${sig.authorization}\r\n")
        sb.append("\r\n")
        let headBytes = sb.toString().toArray()

        var conn: StreamingSocket
        let tcp = TcpSocket(parsed.host, parsed.port)
        tcp.connect(timeout: this.connectTimeout)
        if (parsed.scheme == "https") {
            let tcfg = TlsClientConfig()
            let tls = TlsSocket.client(tcp, session: None, clientConfig: tcfg)
            tls.handshake(timeout: this.connectTimeout)
            conn = tls
        } else {
            conn = tcp
        }
        conn.readTimeout = this.ioTimeout
        conn.writeTimeout = this.ioTimeout

        try {
            conn.write(headBytes)
            if (body.size > 0) {
                conn.write(body)
            }
            conn.flush()
            let raw = this.readAll(conn)
            return this.parseResponse(method, raw, okCodes)
        } catch (e: Exception) {
            throw AppError(AppErrorKind.StorageFailure,
                "OBS 请求失败（${method} ${parsed.path}）：${e.toString()}")
        } finally {
            try { conn.close() } catch (_: Exception) { () }
        }
    }

    /** payload 的 SHA256 hex（SigV4 必填）。 */
    private func payloadHashHex(data: Array<Byte>): String {
        match (this.provider.digest(data, DigestAlgorithm.Sha256)) {
            case CryptoResult.Ok(d) => return HttpS3Transport.hexOf(d)
            case CryptoResult.Err(e) => throw e
        }
    }

    /**
     * 读取连接上的全部响应字节（累积到 ArrayList，最后转 Array）。
     * 结束判定（按优先级）：Content-Length 收齐 → chunked 完整 → 对端关闭（EOF）。
     * 既保证普通对象 GET（带 Content-Length）精确收齐，也兼容分块与 keep-alive 关闭。
     */
    private func readAll(conn: StreamingSocket): Array<Byte> {
        let raw = ArrayList<UInt8>()
        let tmp = Array<UInt8>(16384, repeat: 0u8)
        var headerEnd = Int64(-1)
        let crlfcrlf: Array<UInt8> = [13u8, 10u8, 13u8, 10u8]
        while (true) {
            let n = conn.read(tmp)
            if (n <= 0) {
                // EOF：若连响应头都没收到，视为不完整响应
                if (headerEnd < 0) {
                    throw AppError(AppErrorKind.StorageFailure,
                        "OBS 响应不完整：未收到响应头")
                }
                break
            }
            var i: Int64 = 0
            while (i < n) {
                raw.add(tmp[i])
                i = i + 1
            }
            if (headerEnd < 0) {
                headerEnd = HttpS3Transport.indexOf(raw, crlfcrlf)
            }
            if (headerEnd >= 0) {
                let cl = HttpS3Transport.contentLengthOf(raw, headerEnd)
                if (cl >= 0) {
                    if (raw.size - (headerEnd + 4) >= cl) {
                        break
                    }
                } else if (HttpS3Transport.isChunked(raw, headerEnd)) {
                    if (HttpS3Transport.chunkedComplete(raw, headerEnd)) {
                        break
                    }
                }
                // 其余（无长度、非分块或分块未完）继续读，直到 EOF
            }
        }
        return raw.toArray()
    }

    // ============================================================
    // 公开工具：响应解析（便于单元测试用合成响应字节验证）
    // ============================================================

    /**
     * 解析响应：提取状态码，映射语义。
     *   · 404 且 method==GET → None（对象不存在）
     *   · 状态码 ∈ okCodes   → Some(body)
     *   · 其他              → 抛 AppError（失败关闭）
     */
    public func parseResponse(
        method: String, raw: Array<Byte>, okCodes: Array<Int64>
    ): Option<Array<Byte>> {
        let arr = ArrayList<UInt8>()
        for (b in raw) {
            arr.add(b)
        }
        return this.parseResponseImpl(method, arr, okCodes)
    }

    private func parseResponseImpl(
        method: String, raw: ArrayList<UInt8>, okCodes: Array<Int64>
    ): Option<Array<Byte>> {
        let crlfcrlf: Array<UInt8> = [13u8, 10u8, 13u8, 10u8]
        let headerEnd = HttpS3Transport.indexOf(raw, crlfcrlf)
        if (headerEnd < 0) {
            throw AppError(AppErrorKind.StorageFailure, "OBS 响应缺少头部分隔")
        }
        let status = HttpS3Transport.parseStatusCode(raw, headerEnd)
        if (status == 404 && method == "GET") {
            return None
        }
        let bodyStart = headerEnd + 4
        var body: Array<Byte>
        if (HttpS3Transport.isChunked(raw, headerEnd)) {
            body = HttpS3Transport.decodeChunked(raw, headerEnd)
        } else {
            let cl = HttpS3Transport.contentLengthOf(raw, headerEnd)
            let end = if (cl >= 0) { bodyStart + cl } else { raw.size }
            body = Array<Byte>(end - bodyStart, repeat: 0u8)
            var k: Int64 = 0
            while (k < body.size) {
                body[k] = raw[bodyStart + k]
                k = k + 1
            }
        }

        var ok = false
        for (c in okCodes) {
            if (c == status) {
                ok = true
            }
        }
        if (!ok) {
            throw AppError(AppErrorKind.StorageFailure,
                "OBS 返回非预期状态码 HTTP ${status}（${method}）；对象存储不可用")
        }
        return Some(body)
    }

    // ---------------------------------------------------------
    // URL 解析与编码
    // ---------------------------------------------------------

    /** 解析 http(s)://host[:port][/path]；path 做 RFC 3986 编码（保留 /）。 */
    public static func parseUrl(url: String): ParsedUrl {
        let schemeEnd = HttpS3Transport.strIndexOf(url, 0x3Au8)   // ':'
        if (schemeEnd < 0) {
            throw AppError(AppErrorKind.StorageFailure, "非法 URL（缺少 scheme）：${url}")
        }
        let scheme = url[0..schemeEnd]
        let rest = url[(schemeEnd + 3)..url.size]   // 跳过 "://"
        let slash = HttpS3Transport.strIndexOfFrom(rest, 0x2Fu8, 0)  // '/'
        let hostport = if (slash >= 0) { rest[0..slash] } else { rest }
        let rawPath = if (slash >= 0) { rest[slash..rest.size] } else { "/" }

        var host: String
        var port: UInt16
        if (hostport.startsWith("[")) {
            // IPv6 [host]:port
            let rb = HttpS3Transport.strIndexOfFrom(hostport, 0x5Du8, 0)  // ']'
            if (rb < 0) {
                throw AppError(AppErrorKind.StorageFailure, "非法 IPv6 hostport：${url}")
            }
            host = hostport[1..rb]
            let after = hostport[(rb + 1)..hostport.size]
            if (after.startsWith(":")) {
                port = HttpS3Transport.parsePort(after[1..after.size])
            } else {
                port = HttpS3Transport.defaultPort(scheme)
            }
        } else if (HttpS3Transport.strIndexOfFrom(hostport, 0x3Au8, 0) >= 0) {
            let ci = HttpS3Transport.lastIndexOfByte(hostport, 0x3Au8)
            host = hostport[0..ci]
            port = HttpS3Transport.parsePort(hostport[(ci + 1)..hostport.size])
        } else {
            host = hostport
            port = HttpS3Transport.defaultPort(scheme)
        }

        let path = HttpS3Transport.encodeUriPath(rawPath)
        let defPort = HttpS3Transport.defaultPort(scheme)
        let hostHeader = if (port == defPort) { host } else { "${host}:${port}" }
        return ParsedUrl(scheme, host, port, path, hostHeader)
    }

    private static func defaultPort(scheme: String): UInt16 {
        if (scheme == "https") {
            return 443u16
        }
        return 80u16
    }

    private static func parsePort(s: String): UInt16 {
        let v = HttpS3Transport.parseDecimal(s.trimAscii())
        if (v < 0) {
            throw AppError(AppErrorKind.StorageFailure, "非法端口：${s}")
        }
        return UInt16(v)
    }

    /**
     * RFC 3986 路径编码：保留 unreserved（A-Za-z0-9-_.~）与字面 '/'
     * （路径分隔符，SigV4 要求不编码），其余字节编码为 %XX（大写）。
     * 中文字节会被逐字节编码，正好满足 SigV4 canonical URI 的字节级编码要求。
     */
    public static func encodeUriPath(s: String): String {
        let b = s.toArray()
        let sb = StringBuilder()
        var i: Int64 = 0
        while (i < b.size) {
            let c = b[i]
            if (HttpS3Transport.isUnreserved(c) || c == 0x2Fu8) {
                sb.append(String.fromUtf8([c]))
            } else {
                sb.append("%")
                sb.append(HttpS3Transport.hex2(c))
            }
            i = i + 1
        }
        return sb.toString()
    }

    private static func isUnreserved(c: UInt8): Bool {
        // A-Z / a-z / 0-9 / - . _ ~
        if (c >= 0x41u8 && c <= 0x5Au8) { return true }
        if (c >= 0x61u8 && c <= 0x7Au8) { return true }
        if (c >= 0x30u8 && c <= 0x39u8) { return true }
        if (c == 0x2Du8 || c == 0x2Eu8) { return true }
        if (c == 0x5Fu8 || c == 0x7Eu8) { return true }
        return false
    }

    // ---------------------------------------------------------
    // 响应头 / 状态码解析（全部按字节处理，避免 String 编码歧义）
    // ---------------------------------------------------------

    /** 状态码：status line 的第二个空格分隔字段。 */
    private static func parseStatusCode(raw: ArrayList<UInt8>, headerEnd: Int64): Int64 {
        var i: Int64 = 0
        while (i < headerEnd && raw[i] != 0x20u8) {
            i = i + 1
        }
        if (i >= headerEnd) {
            throw AppError(AppErrorKind.StorageFailure, "OBS 响应首行缺少空格")
        }
        let start = i + 1
        var j = start
        while (j < headerEnd && raw[j] != 0x20u8) {
            j = j + 1
        }
        var v: Int64 = 0
        var k = start
        while (k < j) {
            let d = raw[k] - 0x30u8
            if (d < 0 || d > 9) {
                throw AppError(AppErrorKind.StorageFailure, "OBS 状态码非数字")
            }
            v = v * 10 + Int64(d)
            k = k + 1
        }
        return v
    }

    /** 取响应头字段值（大小写不敏感），找不到返回空串。 */
    private static func getHeader(
        raw: ArrayList<UInt8>, headerEnd: Int64, name: String
    ): String {
        let target = name.toArray()
        var i: Int64 = 0
        while (i < headerEnd) {
            let eol = HttpS3Transport.indexOfFrom(raw, [13u8, 10u8], i)
            let lineEnd = if (eol >= 0) { eol } else { headerEnd }
            let colon = HttpS3Transport.indexOfFrom(raw, [0x3Au8], i)
            if (colon >= 0 && colon < lineEnd) {
                if (HttpS3Transport.ciEquals(raw, i, colon, target)) {
                    var vs = colon + 1
                    while (vs < lineEnd && (raw[vs] == 0x20u8 || raw[vs] == 0x09u8)) {
                        vs = vs + 1
                    }
                    var ve = lineEnd
                    while (ve > vs && (raw[ve - 1] == 0x20u8 || raw[ve - 1] == 0x09u8 || raw[ve - 1] == 0x0Du8)) {
                        ve = ve - 1
                    }
                    return HttpS3Transport.sliceStr(raw, vs, ve)
                }
            }
            i = lineEnd + 2
        }
        return ""
    }

    private static func ciEquals(
        raw: ArrayList<UInt8>, start: Int64, end: Int64, target: Array<Byte>
    ): Bool {
        if (end - start != target.size) {
            return false
        }
        var k: Int64 = 0
        while (k < target.size) {
            let a = raw[start + k]
            let b = target[k]
            let al = if (a >= 0x41u8 && a <= 0x5Au8) { a + 32u8 } else { a }
            let bl = if (b >= 0x41u8 && b <= 0x5Au8) { b + 32u8 } else { b }
            if (al != bl) {
                return false
            }
            k = k + 1
        }
        return true
    }

    private static func contentLengthOf(raw: ArrayList<UInt8>, headerEnd: Int64): Int64 {
        let v = HttpS3Transport.getHeader(raw, headerEnd, "content-length")
        if (v.isEmpty()) {
            return Int64(-1)
        }
        return HttpS3Transport.parseDecimal(v.trimAscii())
    }

    private static func isChunked(raw: ArrayList<UInt8>, headerEnd: Int64): Bool {
        let v = HttpS3Transport.getHeader(raw, headerEnd, "transfer-encoding")
        return v.toAsciiLower().contains("chunked")
    }

    /** 分块编码是否完整（已读到 0 长度分块）。 */
    private static func chunkedComplete(raw: ArrayList<UInt8>, headerEnd: Int64): Bool {
        var idx = headerEnd + 4
        while (true) {
            let eol = HttpS3Transport.indexOfFrom(raw, [13u8, 10u8], idx)
            if (eol < 0) {
                return false
            }
            let semi = HttpS3Transport.indexOfFrom(raw, [0x3Bu8], idx)
            let sizeEnd = if (semi >= 0 && semi < eol) { semi } else { eol }
            let sizeLine = HttpS3Transport.sliceStr(raw, idx, sizeEnd)
            let size = HttpS3Transport.parseHex(sizeLine.trimAscii())
            idx = eol + 2
            if (size < 0) {
                return false
            }
            if (size == 0) {
                return true
            }
            idx = idx + size + 2
            if (idx > raw.size) {
                return false
            }
        }
        // 不可达兜底：while(true) 内已穷尽 return；此处仅满足「所有路径返回」校验
        return false
    }

    /** 解码分块响应体。 */
    private static func decodeChunked(raw: ArrayList<UInt8>, headerEnd: Int64): Array<Byte> {
        let out = ArrayList<UInt8>()
        var idx = headerEnd + 4
        while (true) {
            let eol = HttpS3Transport.indexOfFrom(raw, [13u8, 10u8], idx)
            if (eol < 0) {
                break
            }
            let semi = HttpS3Transport.indexOfFrom(raw, [0x3Bu8], idx)
            let sizeEnd = if (semi >= 0 && semi < eol) { semi } else { eol }
            let sizeLine = HttpS3Transport.sliceStr(raw, idx, sizeEnd)
            let size = HttpS3Transport.parseHex(sizeLine.trimAscii())
            idx = eol + 2
            if (size <= 0) {
                break
            }
            var k: Int64 = 0
            while (k < size) {
                out.add(raw[idx + k])
                k = k + 1
            }
            idx = idx + size + 2
        }
        return out.toArray()
    }

    // ---------------------------------------------------------
    // 字符串 / 字节工具
    // ---------------------------------------------------------

    private static func strIndexOf(s: String, ch: UInt8): Int64 {
        let b = s.toArray()
        var i: Int64 = 0
        while (i < b.size) {
            if (b[i] == ch) {
                return i
            }
            i = i + 1
        }
        return Int64(-1)
    }

    private static func strIndexOfFrom(s: String, ch: UInt8, from: Int64): Int64 {
        let b = s.toArray()
        var i = from
        while (i < b.size) {
            if (b[i] == ch) {
                return i
            }
            i = i + 1
        }
        return Int64(-1)
    }

    private static func lastIndexOfByte(s: String, ch: UInt8): Int64 {
        let b = s.toArray()
        var i = b.size - 1
        while (i >= 0) {
            if (b[i] == ch) {
                return i
            }
            i = i - 1
        }
        return Int64(-1)
    }

    /** 在字节数组（ArrayList）中找子数组首次位置；未找到返回 -1。 */
    private static func indexOf(hay: ArrayList<UInt8>, needle: Array<UInt8>): Int64 {
        return HttpS3Transport.indexOfFrom(hay, needle, 0)
    }

    private static func indexOfFrom(
        hay: ArrayList<UInt8>, needle: Array<UInt8>, from: Int64
    ): Int64 {
        if (needle.size == 0) {
            return from
        }
        var i = from
        let last = hay.size - needle.size
        while (i <= last) {
            var ok = true
            var k: Int64 = 0
            while (k < needle.size) {
                if (hay[i + k] != needle[k]) {
                    ok = false
                    break
                }
                k = k + 1
            }
            if (ok) {
                return i
            }
            i = i + 1
        }
        return Int64(-1)
    }

    private static func sliceStr(raw: ArrayList<UInt8>, start: Int64, end: Int64): String {
        let len = end - start
        let b = Array<UInt8>(len, repeat: 0u8)
        var k: Int64 = 0
        while (k < len) {
            b[k] = raw[start + k]
            k = k + 1
        }
        return String.fromUtf8(b)
    }

    /** 解析十进制非负整数（替代 Int64.parse，避免 std.convert 扩展依赖）。 */
    private static func parseDecimal(s: String): Int64 {
        if (s.isEmpty()) {
            return Int64(-1)
        }
        let b = s.toArray()
        var v: Int64 = 0
        var i: Int64 = 0
        while (i < b.size) {
            let c = b[i]
            if (c < 0x30u8 || c > 0x39u8) {
                return Int64(-1)
            }
            v = v * 10 + Int64(c - 0x30u8)
            i = i + 1
        }
        return v
    }

    /** 解析十六进制字符串为 Int64（分块大小）。 */
    private static func parseHex(s: String): Int64 {
        if (s.isEmpty()) {
            return Int64(-1)
        }
        let b = s.toArray()
        var v: Int64 = 0
        var i: Int64 = 0
        while (i < b.size) {
            let c = b[i]
            var d: Int64 = -1
            if (c >= 0x30u8 && c <= 0x39u8) {
                d = Int64(c - 0x30u8)
            } else if (c >= 0x41u8 && c <= 0x46u8) {
                d = Int64(c - 0x41u8) + 10
            } else if (c >= 0x61u8 && c <= 0x66u8) {
                d = Int64(c - 0x61u8) + 10
            }
            if (d < 0) {
                return Int64(-1)
            }
            v = v * 16 + d
            i = i + 1
        }
        return v
    }

    private static func hex2(c: UInt8): String {
        let h = "0123456789ABCDEF"
        let hi = Int64(c >> 4)
        let lo = Int64(c & 15u8)
        return "${h[hi..(hi + 1)]}${h[lo..(lo + 1)]}"
    }

    private static func hexOf(data: Array<Byte>): String {
        let sb = StringBuilder()
        for (b in data) {
            sb.append(HttpS3Transport.hex2(b))
        }
        return sb.toString()
    }

    // ---------------------------------------------------------
    // 时间：生成 SigV4 需要的 ISO8601 基本格式（UTC）
    // ---------------------------------------------------------

    /** 当前 UTC 时间 → yyyyMMdd'T'HHmmss'Z'（SigV4 x-amz-date）。 */
    public static func amzDateNow(): String {
        let ms = DateTime.now().toUnixTimeStamp().toMilliseconds()
        return HttpS3Transport.formatAmz(ms)
    }

    private static func formatAmz(ms: Int64): String {
        let days = ms / 86400000
        let remMs = ms - days * 86400000
        let (year, month, day) = HttpS3Transport.dateFromDays(days)
        let secs = remMs / 1000
        let hour = secs / 3600
        let minute = (secs % 3600) / 60
        let second = secs % 60
        return "${HttpS3Transport.pad4(year)}${HttpS3Transport.pad2(month)}" +
               "${HttpS3Transport.pad2(day)}T${HttpS3Transport.pad2(hour)}" +
               "${HttpS3Transport.pad2(minute)}${HttpS3Transport.pad2(second)}Z"
    }

    /** days since 1970-01-01（UTC）→ (year, month, day)。 */
    private static func dateFromDays(days: Int64): (Int64, Int64, Int64) {
        var y = 1970
        var d = days
        while (true) {
            let leap = if (HttpS3Transport.isLeap(y)) { 366 } else { 365 }
            if (d < leap) {
                break
            }
            d = d - leap
            y = y + 1
        }
        var m = 1
        var day = d
        let lens = HttpS3Transport.monthLengths(y)
        while (true) {
            let len = lens[m - 1]
            if (day < len) {
                break
            }
            day = day - len
            m = m + 1
        }
        return (y, m, day + 1)
    }

    private static func isLeap(y: Int64): Bool {
        return (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0)
    }

    private static func monthLengths(y: Int64): Array<Int64> {
        let feb = if (HttpS3Transport.isLeap(y)) { 29 } else { 28 }
        return [31, feb, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    }

    private static func pad2(n: Int64): String {
        if (n < 10) {
            return "0${n}"
        }
        return "${n}"
    }

    private static func pad4(n: Int64): String {
        if (n < 10) {
            return "000${n}"
        }
        if (n < 100) {
            return "00${n}"
        }
        if (n < 1000) {
            return "0${n}"
        }
        return "${n}"
    }
}

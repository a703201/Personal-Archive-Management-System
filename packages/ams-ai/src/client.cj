// ============================================================
// ams.ai.client · OpenAI 兼容 /chat/completions 出站客户端
//
// 复刻 ams-storage/src/http_transport.cj 的成熟模式（std.net + stdx.net.tls
// 自实现 HTTP/1.1），但**去掉 SigV4 签名**（AI 用 Bearer），并加超时。
//
// 【失败关闭】
//   - 非 2xx / 超时 / 非 JSON / 缺 choices[0].message.content
//     → 返回 AiCallResult.failure(reason)，由 app 层回退
//   - 密钥只进 Authorization 头，绝不进日志 / 异常 / 回显
// ============================================================
package ams.ai

import std.collection.*
import std.net.*
import stdx.net.tls.*

import ams.kernel.util.*
import ams.kernel.time.*

/**
 * OpenAI 兼容客户端。
 */
public class OpenAIClient {
    private let config: ProviderConfig

    public init(config: ProviderConfig) {
        this.config = config
    }

    /**
     * 发送聊天请求。任何失败都返回 AiCallResult.failure(原因码)，不抛异常。
     */
    public func chat(req: AiChatRequest): AiCallResult {
        let reason = this.config.unavailableReason()
        if (!reason.isEmpty()) { return AiCallResult.failure(reason) }

        let body = OpenAIClient.buildBody(this.config.model, req)
        let url = AiUrl.trimSlash(this.config.baseUrl) + "/chat/completions"
        let parsed = match (AiUrl.parse(url)) {
            case Some(u) => u
            case None => return AiCallResult.failure("bad_endpoint")
        }
        let startMs = Times.nowMillis()

        let tcp = TcpSocket(parsed.host, parsed.port)
        let timeout = Duration.millisecond * this.config.timeoutMs
        try {
            tcp.connect(timeout: timeout)
            var conn: StreamingSocket = tcp
            if (parsed.scheme == "https") {
                let tcfg = TlsClientConfig()
                let tls = TlsSocket.client(tcp, session: None, clientConfig: tcfg)
                tls.handshake(timeout: timeout)
                conn = tls
            }
            conn.readTimeout = timeout
            conn.writeTimeout = timeout
            try {
                let head = OpenAIClient.buildHeaders(parsed.path, parsed.hostHeader,
                    this.config.apiKey, "${body.size}")
                conn.write(head)
                conn.write(body.toArray())
                conn.flush()
                let raw = OpenAIClient.readAll(conn)
                let code = AiUrl.statusCode(raw)
                if (code < 200 || code >= 300) {
                    return AiCallResult.failure("http_${code}")
                }
                let bodyBytes = AiUrl.bodyOf(raw)
                let text = String.fromUtf8(bodyBytes)
                return OpenAIClient.parseReply(text, providerName(this.config.kind),
                    this.config.model, Times.nowMillis() - startMs)
            } finally {
                try { conn.close() } catch (_: Exception) { () }
            }
        } catch (e: Exception) {
            return AiCallResult.failure("transport_error")
        }
    }

    /**
     * 解析 {choices:[{message:{content:"..."}}], usage:{...}}。
     */
    private static func parseReply(text: String, provider: String, model: String, latency: Int64): AiCallResult {
        let j = match (AiJson.of(text)) {
            case Some(x) => x
            case None => return AiCallResult.failure("invalid_json")
        }
        let content = match (j.messageContent()) {
            case Some(s) => s
            case None => return AiCallResult.failure("missing_content")
        }
        if (content.isEmpty()) { return AiCallResult.failure("empty_content") }
        var promptT: Int64 = 0
        var completionT: Int64 = 0
        match (j.str("usage.prompt_tokens")) {
            case Some(s) => promptT = RowDataI64.parse(s)
            case None => ()
        }
        match (j.str("usage.completion_tokens")) {
            case Some(s) => completionT = RowDataI64.parse(s)
            case None => ()
        }
        let resp = AiChatResponse(
            content, provider, model, latency,
            usage: AiUsage(promptTokens: promptT, completionTokens: completionT))
        return AiCallResult.success(resp)
    }

    /**
     * 构造 JSON 请求体（手写，避免依赖 JSON 序列化 API）。
     */
    /** 构造 OpenAI 兼容请求体（public 供单测验证 JSON 合法性）。 */
    public static func buildBody(model: String, req: AiChatRequest): Array<Byte> {
        let sb = StringBuilder()
        sb.append("{\"model\":\"${AiJsonEscape.s(model)}\",")
        sb.append("\"messages\":[")
        sb.append("{\"role\":\"system\",\"content\":\"${AiJsonEscape.s(req.system)}\"},")
        sb.append("{\"role\":\"user\",\"content\":")
        if (req.images.isEmpty()) {
            sb.append("\"${AiJsonEscape.s(req.userText)}\"")
        } else {
            // 必须闭合 text 对象（"}），否则后面追加的 image_url 元素会被解析成
            // text 对象的下一个键，产出非法 JSON → Ollama 400（V 域图片识别失败根因）
            sb.append("[{\"type\":\"text\",\"text\":\"${AiJsonEscape.s(req.userText)}\"}")
            for (img in req.images) {
                sb.append(",{\"type\":\"image_url\",\"image_url\":{\"url\":\"")
                sb.append(AiJsonEscape.s(img.dataUri))
                sb.append("\"}}")
            }
            sb.append("]")
        }
        sb.append("}],")
        sb.append("\"temperature\":${req.temperature},")
        sb.append("\"max_tokens\":${req.maxTokens}")
        // Ollama 默认 context 只有 4096：一张证书图转视觉 token 后约 4k，
        // 加上长提示词必然超限（400 request exceeds context size）。
        // 仅对带图片的请求抬高 num_ctx（其他 provider 忽略此选项）。
        if (!req.images.isEmpty()) {
            sb.append(",\"options\":{\"num_ctx\":16384}")
        }
        if (req.responseFormat == "json_object") {
            sb.append(",\"response_format\":{\"type\":\"json_object\"}")
        }
        sb.append("}")
        return sb.toString().toArray()
    }

    private static func buildHeaders(path: String, host: String, apiKey: String, contentLen: String): Array<Byte> {
        let sb = StringBuilder()
        sb.append("POST ${path} HTTP/1.1\r\n")
        sb.append("Host: ${host}\r\n")
        sb.append("Content-Type: application/json\r\n")
        if (!apiKey.isEmpty()) {
            sb.append("Authorization: Bearer ${apiKey}\r\n")
        }
        sb.append("Content-Length: ${contentLen}\r\n")
        sb.append("Connection: close\r\n")
        sb.append("\r\n")
        return sb.toString().toArray()
    }

    /**
     * 读到完整响应体（Content-Length 或 EOF）。
     */
    private static func readAll(conn: StreamingSocket): Array<Byte> {
        let raw = ArrayList<UInt8>()
        let tmp = Array<UInt8>(16384, repeat: 0u8)
        var headerEnd = Int64(-1)
        let sep: Array<UInt8> = [13u8, 10u8, 13u8, 10u8]
        while (true) {
            let n = conn.read(tmp)
            if (n <= 0) { break }
            var i: Int64 = 0
            while (i < n) { raw.add(tmp[i]); i = i + 1 }
            if (headerEnd < 0) { headerEnd = AiUrl.indexOf(raw.toArray(), sep, 0) }
            if (headerEnd >= 0) {
                let cl = AiUrl.contentLength(raw.toArray(), headerEnd)
                if (cl >= 0 && raw.size - (headerEnd + 4) >= cl) { break }
            }
        }
        return raw.toArray()
    }
}

/**
 * 小工具：安全解析 Int64 字符串。
 */
public class RowDataI64 {
    public static func parse(s: String): Int64 {
        let t = trimSpace(s)
        if (t.isEmpty()) { return 0 }
        var negative = false
        var start = 0
        let b = t.toArray()
        if (b[0] == 45u8) { negative = true; start = 1 }
        var v: Int64 = 0
        for (i in start..b.size) {
            let c = b[i]
            if (c < 48u8 || c > 57u8) { break }
            v = v * 10 + Int64(c - 48u8)
        }
        return if (negative) { -v } else { v }
    }
}

/**
 * JSON 字符串转义（写入请求体时用）。
 */
public class AiJsonEscape {
    /**
     * 按 Unicode 码点遍历（runes），绝不能逐字节 toArray()+fromUtf8([byte])：
     * 中文等多字节字符的单个字节不是合法 UTF-8，会抛 Invalid utf8 byte sequence
     * （Q 域中文问题 500 的根因，2026-11-17 修复）。语义与 ApiResponse.escape 对齐。
     */
    public static func s(text: String): String {
        let sb = StringBuilder()
        for (ch in text.runes().iterator()) {
            let cp = UInt32(ch)
            match (cp) {
                case 34 => sb.append("\\\"")
                case 92 => sb.append("\\\\")
                case 10 => sb.append("\\n")
                case 13 => sb.append("\\r")
                case 9 => sb.append("\\t")
                case 8 => sb.append("\\b")
                case 12 => sb.append("\\f")
                case _ =>
                    if (cp < 0x20) {
                        sb.append("\\u00")
                        sb.append(AiJsonEscape.hexDigit(UInt8((cp >> 4) & 15)))
                        sb.append(AiJsonEscape.hexDigit(UInt8(cp & 15)))
                    } else {
                        sb.append(ch.toString())
                    }
            }
        }
        return sb.toString()
    }

    private static func hexDigit(n: UInt8): String {
        if (n < 10) { return Rune(48 + n).toString() }
        return Rune(87 + n).toString()
    }
}

/**
 * URL 解析与响应切片（纯字节扫描）。
 */
public class AiUrl {
    public let scheme: String
    public let host: String
    public let port: UInt16
    public let path: String
    public let hostHeader: String

    private init(scheme: String, host: String, port: UInt16, path: String, hostHeader: String) {
        this.scheme = scheme
        this.host = host
        this.port = port
        this.path = path
        this.hostHeader = hostHeader
    }

    public static func parse(url: String): Option<AiUrl> {
        let s = url
        var idx = 0
        let b = s.toArray()
        var scheme = "http"
        if (s.startsWith("https://")) {
            scheme = "https"
            idx = 8
        } else if (s.startsWith("http://")) {
            idx = 7
        } else {
            return None
        }
        var hostEnd = idx
        while (hostEnd < b.size && b[hostEnd] != 47u8 && b[hostEnd] != 58u8) {
            hostEnd = hostEnd + 1
        }
        if (hostEnd == idx) { return None }
        let host = String.fromUtf8(b[idx..hostEnd])
        var port: UInt16 = if (scheme == "https") { 443u16 } else { 80u16 }
        var pathStart = hostEnd
        if (hostEnd < b.size && b[hostEnd] == 58u8) {
            var p = hostEnd + 1
            var pv: Int64 = 0
            while (p < b.size && b[p] >= 48u8 && b[p] <= 57u8) {
                pv = pv * 10 + Int64(b[p] - 48u8)
                p = p + 1
            }
            if (pv > 0 && pv < 65536) { port = UInt16(pv) }
            pathStart = p
        }
        var path = "/"
        if (pathStart < b.size && b[pathStart] == 47u8) {
            path = String.fromUtf8(b[pathStart..b.size])
        }
        let hh = if ((scheme == "https" && port == 443u16) || (scheme == "http" && port == 80u16)) {
            host
        } else {
            "${host}:${port}"
        }
        return Some(AiUrl(scheme, host, port, path, hh))
    }

    public static func statusCode(raw: Array<Byte>): Int64 {
        var i = 0
        while (i < raw.size && raw[i] != 32u8) { i = i + 1 }
        i = i + 1
        var v: Int64 = 0
        while (i < raw.size && raw[i] >= 48u8 && raw[i] <= 57u8) {
            v = v * 10 + Int64(raw[i] - 48u8)
            i = i + 1
        }
        return v
    }

    public static func contentLength(raw: Array<Byte>, headerEnd: Int64): Int64 {
        let head = String.fromUtf8(raw[0..headerEnd])
        let lines = head.split("\r\n")
        for (line in lines) {
            let lower = AiUrl.lower(line)
            if (lower.startsWith("content-length:")) {
                let v = AiUrl.after(lower, 15)
                return RowDataI64.parse(trimSpace(v))
            }
        }
        return -1
    }

    public static func bodyOf(raw: Array<Byte>): Array<Byte> {
        let sep: Array<UInt8> = [13u8, 10u8, 13u8, 10u8]
        let he = indexOf(raw, sep, 0)
        if (he < 0 || he + 4 >= raw.size) { return [] }
        return raw[he + 4..raw.size]
    }

    /**
     * ASCII 小写化（字节安全）：只改 ASCII 大写字母，其余字节原样保留，
     * 最后一次性 fromUtf8 —— 逐字节 fromUtf8 会把多字节字符拆坏。
     */
    public static func lower(s: String): String {
        let b = s.toArray()
        let out = Array<Byte>(b.size, repeat: 0u8)
        for (i in 0..b.size) {
            var c = b[i]
            if (c >= 65u8 && c <= 90u8) { c = c + 32u8 }
            out[i] = c
        }
        return String.fromUtf8(out)
    }

    /** 去掉末尾的 '/'（替代被 MSYS/SDK 影响的 String.trimEnd）。 */
    public static func trimSlash(s: String): String {
        let b = s.toArray()
        var end = b.size
        while (end > 0 && b[end - 1] == 47u8) { end = end - 1 }
        return String.fromUtf8(b[0..end])
    }

    /** 取 from 之后的子串（避免 substring API 差异）。 */
    public static func after(s: String, from: Int64): String {
        let b = s.toArray()
        if (from >= b.size) { return "" }
        return String.fromUtf8(b[from..b.size])
    }

    public static func indexOf(b: Array<Byte>, needle: Array<Byte>, from: Int64): Int64 {
        var i = from
        while (i + needle.size <= b.size) {
            var ok = true
            for (j in 0..needle.size) {
                if (b[i + j] != needle[j]) { ok = false; break }
            }
            if (ok) { return i }
            i = i + 1
        }
        return -1
    }
}

/**
 * String 小工具：避免 substring API 差异（静态函数，不 extend 内置类型）。
 */

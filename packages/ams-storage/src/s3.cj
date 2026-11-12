// ============================================================
// ams-storage · S3 兼容对象存储驱动（Q2 方案 A / NFR-EXT-002）
//
// 【定位：可用的对象存储驱动】
//   Q2 的最终选型（自建 MinIO / 华为云 OBS / 本地 FS）仍待运维·甲方确认，
//   但「切换后端时必改的点」已全部收敛：
//     · 配置模型（endpoint / bucket / region / AK / SK / pathStyle）
//     · 对象键消毒与 URL 组装（path-style / virtual-host 两种寻址）
//     · StorageBackend 实现与后端码（1 = s3）
//     · 真实传输层 HttpS3Transport（见 http_transport.cj）：SigV4 签名 +
//       基于 std.net / stdx.net.tls 自实现的 HTTP/1.1 客户端，PUT/GET/DELETE
//       真正发出，404 → None、其余失败关闭。
//   业务层零改动即可从本地 FS 切到任意一家 S3 兼容 OBS。
//
// 【签名与传输均已落地】
//   HMAC-SHA256（RFC 2104，RFC 4231 向量）、SigV4 签名计算（AWS 官方 GET
//   Object 向量）、以及真实 HTTP 传输层均已实现并通过单元 + 端到端验证。
//   多厂商差异收敛在 providers.cj 的 profile 里（主要是 endpoint / region /
//   寻址风格）；七牛 QiniuV2、阿里 OssV1 自有签名标注为未实现，本期只走
//   各家 S3 兼容 + SigV4。
//
// 【安全约束】
//   ① 附件在写入后端前已由 AttachmentService 做 SM4-CBC + HMAC-SM3 加密，
//      对象存储始终只存密文（安全章 §信任边界：存储视为不可信介质）。
//   ② 键消毒阻断 `..` / 反斜杠 / 控制字符，防键名注入与前缀逃逸。
//   ③ 缺配置、连接/签名/响应失败一律**失败关闭**，绝不降级成明文或本地静默回落。
// ============================================================
package ams.storage

import std.collection.*
import std.env.*

import ams.kernel.error.*

/** S3 兼容后端配置。 */
public class S3StorageConfig {
    public let endpoint: String
    public let bucket: String
    public let region: String
    public let accessKey: String
    public let secretKey: String
    public let pathStyle: Bool
    /** 键前缀（按用途隔离：attachments / exports / backups） */
    public let prefix: String
    /** 平台 code（见 StorageProviders），决定 endpoint / region 提示与寻址风格 */
    public let provider: String

    public init(
        endpoint: String, bucket: String, region: String,
        accessKey: String, secretKey: String, pathStyle: Bool, prefix: String,
        provider!: String = "s3"
    ) {
        this.endpoint = endpoint
        this.bucket = bucket
        this.region = region
        this.accessKey = accessKey
        this.secretKey = secretKey
        this.pathStyle = pathStyle
        this.prefix = prefix
        this.provider = provider
    }

    /**
     * 从环境变量装配配置；任一必填项缺失返回 None（由调用方决定失败关闭）。
     * 敏感项（secretKey）不写入任何日志 / 错误信息。
     */
    public static func fromEnv(prefix: String, provider!: String = "s3"): ?S3StorageConfig {
        let endpoint = getVariable("AMS_S3_ENDPOINT") ?? ""
        let bucket = getVariable("AMS_S3_BUCKET") ?? ""
        let region = getVariable("AMS_S3_REGION") ?? ""
        let ak = getVariable("AMS_S3_ACCESS_KEY") ?? ""
        let sk = getVariable("AMS_S3_SECRET_KEY") ?? ""
        if (endpoint.isEmpty() || bucket.isEmpty() || region.isEmpty() ||
            ak.isEmpty() || sk.isEmpty()) {
            return None
        }
        // 寻址风格默认值来自厂商 profile（MinIO 默认 path-style，
        // 华为云/阿里云/腾讯/七牛/AWS 默认 virtual-host）；运维可用
        // AMS_S3_PATH_STYLE 显式覆盖。
        var style = true
        match (StorageProviders.find(provider)) {
            case Some(p) => style = p.defaultPathStyle
            case None => style = true
        }
        let styleRaw = getVariable("AMS_S3_PATH_STYLE") ?? ""
        if (!styleRaw.isEmpty()) {
            style = !(styleRaw == "false" || styleRaw == "0")
        }
        return Some(S3StorageConfig(
            endpoint, bucket, region, ak, sk, style, prefix, provider: provider))
    }

    /** 必填项校验（失败抛 AppError，不静默容忍）。 */
    public func validate(): Unit {
        if (this.endpoint.isEmpty()) {
            throw validationError("AMS_S3_ENDPOINT", "缺少 AMS_S3_ENDPOINT")
        }
        if (this.bucket.isEmpty()) {
            throw validationError("AMS_S3_BUCKET", "缺少 AMS_S3_BUCKET")
        }
        if (this.accessKey.isEmpty() || this.secretKey.isEmpty()) {
            throw validationError("AMS_S3_ACCESS_KEY", "缺少 S3 访问凭据")
        }
        if (!(this.endpoint.startsWith("https://") || this.endpoint.startsWith("http://"))) {
            throw validationError("AMS_S3_ENDPOINT", "AMS_S3_ENDPOINT 必须以 http(s):// 开头")
        }
    }

    /**
     * 对象 URL（签名与请求头由 S3Transport 负责，本层只组装地址）。
     * pathStyle=true：`endpoint/bucket/prefix/key`
     * pathStyle=false：`bucket.endpoint/prefix/key`（virtual-host 形态）
     */
    public func objectUrl(key: String): String {
        let safe = S3StorageConfig.sanitizeKey(key)
        let fullKey = if (this.prefix.isEmpty()) {
            safe
        } else {
            "${S3StorageConfig.sanitizePrefix(this.prefix)}/${safe}"
        }
        if (this.pathStyle) {
            return "${S3StorageConfig.trimSlash(this.endpoint)}/${this.bucket}/${fullKey}"
        }
        // 仓颉原生 `String.indexOf` 返回 Option[Int64]，不能直接与 0 比较；
        // 这里只需要找 ASCII 的 "://"，用逐字节比较自己实现（见 indexOfAscii）。
        let schemePos = S3StorageConfig.indexOfAscii(this.endpoint, "://")
        if (schemePos < 0) {
            return "${S3StorageConfig.trimSlash(this.endpoint)}/${this.bucket}/${fullKey}"
        }
        let scheme = this.endpoint[0..(schemePos + 3)]
        let host = S3StorageConfig.trimSlash(this.endpoint[(schemePos + 3)..this.endpoint.size])
        return "${scheme}${this.bucket}.${host}/${fullKey}"
    }

    /**
     * 对象键消毒：阻断路径逃逸、反斜杠与控制字符；保留 `/` 作为合法前缀分隔。
     *
     * 【必须按 UTF-8 字符边界走】逐字节 `s[i..(i+1)]` 会把中文的首字节
     * 单独切成非法 UTF-8 String 并抛异常（本仓 `MediaOcr.upperByte` /
     * `SearchHighlighter.escapeJson` 都踩过同一个坑）。中文文件名很常见，
     * 不能假设对象键只有 ASCII。
     */
    public static func sanitizeKey(key: String): String {
        let s = key.replace("\\", "_").replace("..", "_")
        let out = StringBuilder()
        var i: Int64 = 0
        while (i < s.size) {
            let b = s[i]
            var n = S3StorageConfig.utf8Len(b)
            if (n <= 0) {
                i = i + 1
                continue
            }
            if (i + n > s.size) {
                n = s.size - i
            }
            if (n == 1 && (b < 0x20u8 || b == 0x7Fu8)) {
                out.append("_")
            } else {
                out.append(s[i..(i + n)])
            }
            i = i + n
        }
        return out.toString()
    }

    private static func utf8Len(b: Byte): Int64 {
        if (b < 0x80u8) {
            return 1
        }
        if (b >= 0xC0u8 && b < 0xE0u8) {
            return 2
        }
        if (b >= 0xE0u8 && b < 0xF0u8) {
            return 3
        }
        if (b >= 0xF0u8 && b < 0xF8u8) {
            return 4
        }
        return 0
    }

    /** 找 ASCII 子串，返回字节下标；未找到返回 -1。 */
    private static func indexOfAscii(s: String, sub: String): Int64 {
        if (sub.isEmpty()) {
            return 0
        }
        var i: Int64 = 0
        while (i + sub.size <= s.size) {
            var ok = true
            var j: Int64 = 0
            while (j < sub.size) {
                if (s[i + j] != sub[j]) {
                    ok = false
                    break
                }
                j = j + 1
            }
            if (ok) {
                return i
            }
            i = i + 1
        }
        return -1
    }

    private static func sanitizePrefix(p: String): String {
        return p.replace("\\", "_").replace("..", "_").replace("/", "_")
    }

    private static func trimSlash(s: String): String {
        if (s.endsWith("/")) {
            return s[0..(s.size - 1)]
        }
        return s
    }
}

/**
 * 传输层注入点（S3 兼容对象存储）。
 *
 * 真实实现见 http_transport.cj 的 `HttpS3Transport`：基于 std.net（TcpSocket）
 * + stdx.net.tls（TlsSocket）自实现 HTTP/1.1 客户端，负责 SigV4 签名、HTTPS
 * 请求与错误码映射（404 → None、5xx → AppError 失败关闭）。
 * 工厂 `StorageBackends.make` 默认注入 `HttpS3Transport.forConfig(cfg)`。
 */
public interface S3Transport {
    func putObject(url: String, data: Array<Byte>): Unit
    func getObject(url: String): Option<Array<Byte>>
}

/**
 * 失败关闭桩：仅当**直接**构造 `S3ObjectStorage` 而不传 transport 时作为默认
 * 兜底（例如旧测试）。业务路径一律经工厂注入真实 `HttpS3Transport`，不会落到这里。
 * 一旦被调用即抛 AppError（绝不静默返回空内容伪装「对象不存在」）。
 */
public class UnavailableS3Transport <: S3Transport {
    public init() {}

    public func putObject(_url: String, _data: Array<Byte>): Unit {
        throw AppError(AppErrorKind.StorageFailure,
            "S3 传输层未注入：请求 ${_url}（payload ${_data.size} 字节）失败；" +
            "请经 StorageBackends.make 构造（默认 HttpS3Transport），或直接传入 transport")
    }

    public func getObject(_url: String): Option<Array<Byte>> {
        throw AppError(AppErrorKind.StorageFailure,
            "S3 传输层未注入：请求 ${_url} 失败；" +
            "请经 StorageBackends.make 构造（默认 HttpS3Transport），或直接传入 transport")
    }
}

/** S3 兼容存储驱动（骨架）。 */
public class S3ObjectStorage <: StorageBackend {
    private let config: S3StorageConfig
    private let transport: S3Transport

    public init(config: S3StorageConfig, transport!: S3Transport = UnavailableS3Transport()) {
        config.validate()
        this.config = config
        this.transport = transport
    }

    public func put(key: String, data: Array<Byte>): Unit {
        this.transport.putObject(this.config.objectUrl(key), data)
    }

    public func get(key: String): Option<Array<Byte>> {
        return this.transport.getObject(this.config.objectUrl(key))
    }

    /** 后端码：1 = s3（对应 arc_attachments.storage_backend） */
    public func backendCode(): Int64 {
        return 1
    }
}

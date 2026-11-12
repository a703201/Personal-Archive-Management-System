// ============================================================
// ams-storage · 多厂商对象存储 Provider Registry（Q2 方案 A 扩展）
//
// 【设计意图】
//   把「选哪家云」从硬编码变成一份**可查询、可扩展的元数据表**：
//   华为云 OBS / 阿里云 OSS / 七牛云 Kodo / 腾讯云 COS / AWS S3 /
//   自建 MinIO / 通用 S3 兼容，以及**本地 FS**（默认，零回归）。
//   上层业务只依赖 `StorageBackend`，厂商差异全部收敛在 profile 里。
//
// 【这些 profile 到底提供什么】
//   endpoint 模板、region 样例、桶命名约束、默认寻址风格
//   （path-style / virtual-host）、签名协议标识、接入说明。
//   它们是**配置提示与路由元数据**，不是各家 SDK 的实现。
//   真实上传由 S3Transport 的真实实现 HttpS3Transport 完成（见 http_transport.cj）：
//   SigV4 签名计算（sigv4.cj）+ 基于 std.net / stdx.net.tls 自实现的 HTTP/1.1
//   客户端，PUT/GET/DELETE 真正发出，404 → None、其余失败关闭。
//
// 【为什么统一到 SigV4】
//   除七牛自有 Kodo API / 阿里 OSS 自有 V1 签名外，上述厂商都提供
//   S3 兼容接口并接受 AWS Signature V4。故共用一套 SigV4 签名器
//   （依赖本批补上的 HMAC-SHA256），厂商间只差 endpoint 与寻址风格。
//   自有签名协议在 profile 里明确标注「未实现」，不假装支持。
//
// 【endpoint 模板的诚实边界】
//   模板仅用于给运维生成配置提示；各家区域名、是否要求 HTTPS、
//   内网/外网域名会变，以厂商控制台为准。模板里的占位符用 <...>。
// ============================================================
package ams.storage

import std.collection.*
import std.env.*

import ams.kernel.error.*

/** 对象存储签名协议。 */
public enum ObjectSignature {
    | Local       // 本地 FS，不需要签名
    | SigV4       // AWS Signature V4（S3 兼容接口，本仓已实现签名计算）
    | QiniuV2     // 七牛 Kodo 自有签名（HMAC-SHA1，未实现）
    | OssV1       // 阿里云 OSS 自有 V1（HMAC-SHA1，未实现）
}

/** 一个可接入的存储平台档案。 */
public class StorageProviderProfile {
    public let code: String
    public let displayName: String
    /** "local" | "object" */
    public let kind: String
    public let signature: ObjectSignature
    public let endpointTemplate: String
    public let regionHint: String
    public let defaultPathStyle: Bool
    public let supportsVirtualHost: Bool
    public let bucketRule: String
    public let notes: String
    public let docsUrl: String

    public init(
        code: String, displayName: String, kind: String,
        signature: ObjectSignature, endpointTemplate: String, regionHint: String,
        defaultPathStyle: Bool, supportsVirtualHost: Bool, bucketRule: String,
        notes: String, docsUrl: String
    ) {
        this.code = code
        this.displayName = displayName
        this.kind = kind
        this.signature = signature
        this.endpointTemplate = endpointTemplate
        this.regionHint = regionHint
        this.defaultPathStyle = defaultPathStyle
        this.supportsVirtualHost = supportsVirtualHost
        this.bucketRule = bucketRule
        this.notes = notes
        this.docsUrl = docsUrl
    }

    /** 后端码：0 = 本地 FS，1 = 对象存储（与 arc_attachments.storage_backend 一致） */
    public func backendCode(): Int64 {
        if (this.kind == "local") {
            return 0
        }
        return 1
    }

    public func isLocal(): Bool {
        return this.kind == "local"
    }

    /** 是否需要对象存储凭据 */
    public func needsCredentials(): Bool {
        return !this.isLocal()
    }
}

/**
 * 平台注册表。静态表（8 个内置 profile），支持 `AMS_STORAGE_PROVIDER` 选择。
 * 新增厂商只需在 `seed()` 里加一条，不改工厂、不改 API、不改业务层。
 */
public class StorageProviders {
    /** 默认平台：本地 FS（零回归） */
    public static let DEFAULT_CODE: String = "local"
    /** 通用 S3 兼容代码（旧 AMS_STORAGE_BACKEND=s3 的兼容落点） */
    public static let GENERIC_S3_CODE: String = "s3"

    private static let profiles: ArrayList<StorageProviderProfile> = StorageProviders.seed()

    private static func seed(): ArrayList<StorageProviderProfile> {
        let list = ArrayList<StorageProviderProfile>()

        list.add(StorageProviderProfile(
            "local", "本地文件系统", "local", ObjectSignature.Local,
            "", "", true, false,
            "不需要桶；数据目录由 AMS_STORAGE_DIR / AMS_EXPORT_DIR / AMS_BACKUP_DIR 指定",
            "默认且唯一已完全可用的后端。隔离区恒定本地 FS，不受本选项影响。",
            "https://github.com/a703201/Archive_manager/blob/main/deploy/README.md"))

        list.add(StorageProviderProfile(
            "minio", "自建 MinIO", "object", ObjectSignature.SigV4,
            "http://<host>:9000", "us-east-1", true, true,
            "桶名 3~63 位小写字母/数字/连字符",
            "私有化/离线可用。默认 path-style；compose 提供 --profile s3 的可选容器。",
            "https://min.io/docs/minio/linux/index.html"))

        list.add(StorageProviderProfile(
            "huawei", "华为云 OBS", "object", ObjectSignature.SigV4,
            "https://obs.<region>.myhuaweicloud.com", "cn-north-4", false, true,
            "桶名全局唯一；建议加租户前缀避免撞名",
            "走 OBS 的 S3 兼容接口（Signature V4）。AK/SK 由密钥管理注入；桶策略禁公共读。",
            "https://support.huaweicloud.com/obs/index.html"))

        list.add(StorageProviderProfile(
            "aliyun", "阿里云 OSS", "object", ObjectSignature.SigV4,
            "https://oss-<region>.aliyuncs.com", "oss-cn-hangzhou", false, true,
            "桶名全局唯一，小写字母/数字/连字符",
            "走 OSS 的 S3 兼容 V4 签名；OSS 自有 V1 签名（HMAC-SHA1）标注为未实现，不在本期支持。",
            "https://help.aliyun.com/product/31815.html"))

        list.add(StorageProviderProfile(
            "qiniu", "七牛云 Kodo", "object", ObjectSignature.SigV4,
            "https://s3-<region>.qiniucs.com", "cn-east-1", false, true,
            "桶名由七牛控制台分配",
            "需先在七牛开启 S3 兼容网关并选用 SigV4；Kodo 自有 API 的 QiniuV2 签名（HMAC-SHA1）未实现。",
            "https://developer.qiniu.com/kodo"))

        list.add(StorageProviderProfile(
            "tencent", "腾讯云 COS", "object", ObjectSignature.SigV4,
            "https://cos.<region>.myqcloud.com", "ap-guangzhou", false, true,
            "桶名格式 <name>-<appid>",
            "COS 兼容 S3 Signature V4；SecretId/SecretKey 由密钥管理注入。",
            "https://cloud.tencent.com/document/product/436"))

        list.add(StorageProviderProfile(
            "aws", "AWS S3", "object", ObjectSignature.SigV4,
            "https://s3.<region>.amazonaws.com", "us-east-1", false, true,
            "桶名全球唯一",
            "标准 SigV4；跨境存储需自行评估数据合规，本项目默认不跨境。",
            "https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-authenticating-requests.html"))

        list.add(StorageProviderProfile(
            "s3", "通用 S3 兼容", "object", ObjectSignature.SigV4,
            "https://<custom-endpoint>", "us-east-1", true, true,
            "按服务商要求",
            "兜底项：兼容旧 AMS_STORAGE_BACKEND=s3。endpoint/region/寻址风格全部由运维显式给出。",
            ""))

        return list
    }

    /** 全部可选平台（供管理接口列出）。 */
    public static func all(): Array<StorageProviderProfile> {
        return StorageProviders.profiles.toArray()
    }

    /** 按 code 查；未知返回 None。 */
    public static func find(code: String): ?StorageProviderProfile {
        if (code.isEmpty()) {
            return None
        }
        for (p in StorageProviders.profiles) {
            if (p.code == code) {
                return Some(p)
            }
        }
        return None
    }

    /**
     * 当前平台代码。优先级：
     *   ① `AMS_STORAGE_PROVIDER`（新，多厂商选择）
     *   ② `AMS_STORAGE_BACKEND`（旧，Q2 上一批的 fs/s3，兼容保留）
     *   ③ 默认 `local`
     */
    public static func currentCode(): String {
        let provider = getVariable("AMS_STORAGE_PROVIDER") ?? ""
        if (!provider.isEmpty()) {
            return provider
        }
        let legacy = getVariable("AMS_STORAGE_BACKEND") ?? ""
        if (legacy == "fs" || legacy.isEmpty()) {
            return StorageProviders.DEFAULT_CODE
        }
        if (legacy == "s3") {
            return StorageProviders.GENERIC_S3_CODE
        }
        // 未知旧值不静默回落，由 current() 明确报错
        return legacy
    }

    /** 当前平台档案；未知代码失败关闭。 */
    public static func current(): StorageProviderProfile {
        let code = StorageProviders.currentCode()
        match (StorageProviders.find(code)) {
            case Some(p) => return p
            case None => throw validationError("AMS_STORAGE_PROVIDER",
                "未知存储平台：${code}；可用值见 GET /api/admin/storage/providers")
        }
    }

    /** 平台 code 是否对应本地 FS。 */
    public static func isLocalCode(code: String): Bool {
        match (StorageProviders.find(code)) {
            case Some(p) => return p.isLocal()
            case None => return false
        }
    }

    /**
     * 生成某平台的配置提示（不含任何密钥）。
     * 供管理接口返回，避免运维猜 endpoint / region。
     */
    public static func hint(code: String): String {
        match (StorageProviders.find(code)) {
            case Some(p) =>
                return "endpoint=${p.endpointTemplate} region=${p.regionHint} " +
                       "pathStyle=${p.defaultPathStyle} signature=${StorageProviders.signatureName(p.signature)}"
            case None => return ""
        }
    }

    public static func signatureName(s: ObjectSignature): String {
        match (s) {
            case ObjectSignature.Local => return "none"
            case ObjectSignature.SigV4 => return "sigv4"
            case ObjectSignature.QiniuV2 => return "qiniu-v2(not-implemented)"
            case ObjectSignature.OssV1 => return "oss-v1(not-implemented)"
        }
    }
}

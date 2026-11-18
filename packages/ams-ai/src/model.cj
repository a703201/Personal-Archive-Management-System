// ============================================================
// ams.ai.model · 通用 AI 调用入参 / 结果类型
//
// 本文件只包含**领域无关**的数据结构。ams-app 负责把
// 「档案 / 条目 / 字段模板」翻译成这些通用类型，再把结果翻译回去。
// ============================================================
package ams.ai


/**
 * 能力域（docs/20 §2.1）。
 */
public enum AiDomain {
    | Vision
    | Summary
    | Query
    | Advice
}

/**
 * 能力域 -> 稳定标识（审计 / 配置键 / 指标标签统一用此值）。
 */
public func domainName(d: AiDomain): String {
    match (d) {
        case AiDomain.Vision => "vision"
        case AiDomain.Summary => "summary"
        case AiDomain.Query => "query"
        case AiDomain.Advice => "advice"
    }
}

/**
 * 多模态图片输入：data URI（data:<mime>;base64,<payload>）。
 * 只放 base64 字符串，ams-ai 不读文件、不解密附件（那是 ams-app 的职责）。
 */
public class AiImage {
    public let dataUri: String
    public let label: String

    public init(dataUri: String, label!: String = "") {
        this.dataUri = dataUri
        this.label = label
    }
}

/**
 * 通用聊天请求。
 *
 * system / userText 由 ams-app 用 PromptBuilder 拼好；
 * images 仅 V 域使用；responseFormat 取值为 "json_object" / "text"。
 */
public class AiChatRequest {
    public let system: String
    public let userText: String
    public let images: Array<AiImage>
    public let responseFormat: String
    public let temperature: Float64
    public let maxTokens: Int64
    public let domain: AiDomain
    public let promptVersion: String

    public init(
        system: String,
        userText: String,
        domain: AiDomain,
        promptVersion: String,
        images!: Array<AiImage> = [],
        responseFormat!: String = "json_object",
        temperature!: Float64 = 0.0,
        maxTokens!: Int64 = 2048
    ) {
        this.system = system
        this.userText = userText
        this.domain = domain
        this.promptVersion = promptVersion
        this.images = images
        this.responseFormat = responseFormat
        this.temperature = temperature
        this.maxTokens = maxTokens
    }
}

/**
 * token 用量（模型给了才填，未给为 0，不猜）。
 */
public class AiUsage {
    public let promptTokens: Int64
    public let completionTokens: Int64

    public init(promptTokens!: Int64 = 0, completionTokens!: Int64 = 0) {
        this.promptTokens = promptTokens
        this.completionTokens = completionTokens
    }
}

/**
 * 通用聊天响应。content 是模型返回的原始文本（通常是 JSON 串）。
 */
public class AiChatResponse {
    public let content: String
    public let usage: AiUsage
    public let provider: String
    public let model: String
    public let latencyMs: Int64

    public init(
        content: String,
        provider: String,
        model: String,
        latencyMs: Int64,
        usage!: AiUsage = AiUsage()
    ) {
        this.content = content
        this.provider = provider
        this.model = model
        this.latencyMs = latencyMs
        this.usage = usage
    }
}

/**
 * 调用结果：成功携带响应，失败携带原因码（不抛到前端，由 app 层回退）。
 *
 * 注意：error 里**只放原因码**（如 "no_key" / "timeout" / "invalid_json"），
 * 绝不放密钥、请求体或完整响应——沿用全仓脱敏口径。
 */
public class AiCallResult {
    public let ok: Bool
    public let response: ?AiChatResponse
    public let error: String
    public let engine: String

    private init(ok: Bool, response: ?AiChatResponse, error: String, engine: String) {
        this.ok = ok
        this.response = response
        this.error = error
        this.engine = engine
    }

    public static func success(r: AiChatResponse): AiCallResult {
        return AiCallResult(true, r, "", "ai-${r.provider}:${r.model}")
    }

    public static func failure(reason: String): AiCallResult {
        return AiCallResult(false, None, reason, "fallback-builtin(${reason})")
    }
}

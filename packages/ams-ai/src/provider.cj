// ============================================================
// ams.ai.provider · Provider 抽象、配置与引擎选择链
//
// 对应 docs/20 §6.3 / §7：
//   - 统一 OpenAI 兼容主干，各家差异收敛到 ProviderConfig
//   - 本地优先 → 在线（需出境同意）→ 失败回退内置
//   - 内置离线模型（§7.7）作为默认本地引擎，排在外部 provider 之前
//
// 【失败关闭】配置缺失 / 同意缺失 → 根本不构造可用 provider，
//   由 app 层据此回退，绝不降级成弱 token / 空摘要。
// ============================================================
package ams.ai


/**
 * Provider 类型。covered by docs/20 §7.2 / §7.3 / §7.7。
 */
public enum AiProviderKind {
    | LocalBuiltin      // 内置离线模型（PP-OCRv5 + Qwen 0.5B，§7.7）
    | Ollama
    | LMStudio
    | CherryStudio      // 透传：指向 Cherry 所配置后端，无独立协议
    | SiliconFlow
    | Aliyun
    | Huawei
    | DeepSeek
    | OpenAI
    | Custom
}

public func providerName(k: AiProviderKind): String {
    match (k) {
        case AiProviderKind.LocalBuiltin => "local"
        case AiProviderKind.Ollama => "ollama"
        case AiProviderKind.LMStudio => "lmstudio"
        case AiProviderKind.CherryStudio => "cherry"
        case AiProviderKind.SiliconFlow => "siliconflow"
        case AiProviderKind.Aliyun => "aliyun"
        case AiProviderKind.Huawei => "huawei"
        case AiProviderKind.DeepSeek => "deepseek"
        case AiProviderKind.OpenAI => "openai"
        case AiProviderKind.Custom => "custom"
    }
}

public func parseProvider(s: String): AiProviderKind {
    match (s) {
        case "local" => AiProviderKind.LocalBuiltin
        case "ollama" => AiProviderKind.Ollama
        case "lmstudio" => AiProviderKind.LMStudio
        case "cherry" => AiProviderKind.CherryStudio
        case "siliconflow" => AiProviderKind.SiliconFlow
        case "aliyun" => AiProviderKind.Aliyun
        case "huawei" => AiProviderKind.Huawei
        case "deepseek" => AiProviderKind.DeepSeek
        case "openai" => AiProviderKind.OpenAI
        case _ => AiProviderKind.Custom
    }
}

/**
 * 是否在线 provider（出境判定）。本地内置 / Ollama / LM Studio / Cherry 后端均不出境。
 */
public func isOnlineProvider(k: AiProviderKind): Bool {
    match (k) {
        case AiProviderKind.LocalBuiltin => false
        case AiProviderKind.Ollama => false
        case AiProviderKind.LMStudio => false
        case AiProviderKind.CherryStudio => false
        case _ => true
    }
}

/**
 * 是否支持读图（docs/20 §7.4）。
 * DeepSeek 主线模型非视觉，只做文本二次结构化。
 */
public func supportsVision(k: AiProviderKind): Bool {
    match (k) {
        case AiProviderKind.DeepSeek => false
        case _ => true
    }
}

/**
 * Provider 连接配置（由 ams-app 从 deployment.env / cfg_settings 构造后传入）。
 * apiKey 为空时在线 provider 视为不可用（失败关闭）。
 */
public class ProviderConfig {
    public let kind: AiProviderKind
    public let baseUrl: String
    public let apiKey: String
    public let model: String
    public let timeoutMs: Int64
    public let maxImageBytes: Int64

    public init(
        kind: AiProviderKind,
        baseUrl: String,
        apiKey: String,
        model: String,
        // 视觉模型处理大图（证书扫描件/截图）常需 1-2 分钟，60s 会 transport_error
        timeoutMs!: Int64 = 300000,
        maxImageBytes!: Int64 = 4194304
    ) {
        this.kind = kind
        this.baseUrl = baseUrl
        this.apiKey = apiKey
        this.model = model
        this.timeoutMs = timeoutMs
        this.maxImageBytes = maxImageBytes
    }

    /**
     * 可用性校验：在线必须有 key 与合法端点；本地必须有端点。
     * 不合法时返回原因码（不抛），由选择链据此跳过。
     */
    public func unavailableReason(): String {
        if (this.baseUrl.isEmpty()) { return "no_endpoint" }
        if (!this.baseUrl.startsWith("http://") && !this.baseUrl.startsWith("https://")) {
            return "bad_endpoint"
        }
        if (isOnlineProvider(this.kind) && this.apiKey.isEmpty()) { return "no_key" }
        if (this.model.isEmpty()) { return "no_model" }
        return ""
    }
}

/**
 * 能力发现结果（GET /api/ai/capabilities 的数据源，§6.9.1）。
 * 前端只消费此结果，不在各页面自行判断开关组合。
 */
public class AiCapabilities {
    public let aiEnabled: Bool
    public let optOut: Bool
    public let onlineAllowed: Bool
    public let vision: Bool
    public let summary: Bool
    public let query: Bool
    public let advice: Bool

    public init(
        aiEnabled: Bool,
        optOut: Bool,
        onlineAllowed: Bool,
        vision: Bool,
        summary: Bool,
        query: Bool,
        advice: Bool
    ) {
        this.aiEnabled = aiEnabled
        this.optOut = optOut
        this.onlineAllowed = onlineAllowed
        this.vision = vision
        this.summary = summary
        this.query = query
        this.advice = advice
    }

    /**
     * 任一能力域可用？关闭态判定：opt-out 或总开关关时一律 false。
     */
    public func anyEnabled(): Bool {
        if (this.optOut || !this.aiEnabled) { return false }
        return this.vision || this.summary || this.query || this.advice
    }

    public func domainEnabled(d: AiDomain): Bool {
        if (this.optOut || !this.aiEnabled) { return false }
        match (d) {
            case AiDomain.Vision => return this.vision
            case AiDomain.Summary => return this.summary
            case AiDomain.Query => return this.query
            case AiDomain.Advice => return this.advice
        }
    }
}

/**
 * 引擎选择链（§3.3）。返回第一个可用 provider；在线须显式同意。
 *
 * 顺序：local builtin → 外部本地 → 在线（需 onlineAllowed）→ None（回退内置能力）。
 */
public func selectProvider(
    ordered: Array<ProviderConfig>,
    onlineAllowed: Bool
): Option<ProviderConfig> {
    for (p in ordered) {
        if (!p.unavailableReason().isEmpty()) { continue }
        if (isOnlineProvider(p.kind) && !onlineAllowed) { continue }
        return Some(p)
    }
    return None
}

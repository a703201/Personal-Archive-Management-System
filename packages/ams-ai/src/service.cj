// ============================================================
// ams.ai.service · AI 底座门面服务
//
// ams-app 只需构造 AiGateway（注入配置提供者），然后：
//   - capabilities() 拿能力发现结果（关闭态统一判定）
//   - chat(req) 发一次通用调用，拿 AiCallResult（失败由 app 回退）
//
// 【职责边界】AiGateway 不知道"档案/条目/主体"，只做：
//   能力判定 → provider 选择 → OpenAI 客户端调用 → 结果/原因码返回。
// ============================================================
package ams.ai


import ams.kernel.log.*

/**
 * AI 运行时配置（由 ams-app 从 deployment.env / cfg_settings 构造）。
 */
public class AiRuntimeConfig {
    public let enabled: Bool
    public let optOut: Bool
    public let onlineAllowed: Bool
    public let enableVision: Bool
    public let enableSummary: Bool
    public let enableQuery: Bool
    public let enableAdvice: Bool
    public let providers: Array<ProviderConfig>

    public init(
        enabled: Bool,
        optOut: Bool,
        onlineAllowed: Bool,
        enableVision: Bool,
        enableSummary: Bool,
        enableQuery: Bool,
        enableAdvice: Bool,
        providers: Array<ProviderConfig>
    ) {
        this.enabled = enabled
        this.optOut = optOut
        this.onlineAllowed = onlineAllowed
        this.enableVision = enableVision
        this.enableSummary = enableSummary
        this.enableQuery = enableQuery
        this.enableAdvice = enableAdvice
        this.providers = providers
    }
}

/**
 * AI 网关：底座唯一入口。
 */
public class AiGateway {
    private let config: AiRuntimeConfig
    private let log: Log

    public init(config: AiRuntimeConfig) {
        this.config = config
        this.log = Log.get()
    }

    /**
     * 能力发现（GET /api/ai/capabilities 数据源）。
     */
    public func capabilities(): AiCapabilities {
        return AiCapabilities(
            this.config.enabled,
            this.config.optOut,
            this.config.onlineAllowed,
            this.config.enableVision,
            this.config.enableSummary,
            this.config.enableQuery,
            this.config.enableAdvice
        )
    }

    /**
     * 通用聊天调用。关闭态 / 分域关闭 → 直接返回 skipped 原因码，零出站请求。
     */
    public func chat(req: AiChatRequest): AiCallResult {
        let caps = this.capabilities()
        if (!caps.domainEnabled(req.domain)) {
            return AiCallResult.failure("skipped_disabled")
        }
        let chosen = match (selectProvider(this.config.providers, this.config.onlineAllowed)) {
            case Some(p) => p
            case None => return AiCallResult.failure("no_provider")
        }
        // 视觉域但 provider 不支持读图 → 由 app 层走文本二次结构化；
        // 这里返回明确的 reason，不静默当成功。
        let needsVision = match (req.domain) {
            case AiDomain.Vision => true
            case _ => false
        }
        if (needsVision && !req.images.isEmpty() && !supportsVision(chosen.kind)) {
            return AiCallResult.failure("vision_unsupported")
        }
        let client = OpenAIClient(chosen)
        let result = client.chat(req)
        // 审计只记原因码 / 引擎 / 耗时，绝不记密钥或正文
        this.log.info("ai.call", None, [
            ("domain", domainName(req.domain)),
            ("provider", providerName(chosen.kind)),
            ("promptVersion", req.promptVersion),
            ("ok", "${result.ok}"),
            ("reason", result.error),
            ("latencyMs", match (result.response) { case Some(r) => "${r.latencyMs}"; case None => "0" })
        ])
        return result
    }
}

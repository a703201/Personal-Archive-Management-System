// ============================================================
// ams.app.ai · AI 配置管理服务（system:admin）
//
// 对应 docs/20 §6.3 / I2：
//   - provider / base_url / model / API 密钥（脱敏展示）写 deployment.env
//   - 总开关 / 出境同意 / 分域开关写 cfg_settings(scope=ai)
//   - 连通性测试：发一个最小 OpenAI 兼容请求，不暴露密钥
//
// 【安全】密钥写入即用，展示一律 ***；测试失败只回可读原因码。
// ============================================================
package ams.app.ai

import std.collection.*

import ams.ai.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.storage.*

/**
 * AI 配置管理服务。
 */
public class AiAdminService {
    private let deployStore: DeploymentStore
    private let configRepo: ConfigRepo

    public init(deployStore: DeploymentStore, configRepo: ConfigRepo) {
        this.deployStore = deployStore
        this.configRepo = configRepo
    }

    /**
     * 读取配置（脱敏）。返回可直接序列化的 JSON 串。
     */
    public func readJson(): String {
        let provider = this.deployStore.resolve("AI_PROVIDER", "AI_PROVIDER", "ollama")
        let baseUrl = this.deployStore.resolve("AI_BASE_URL", "AI_BASE_URL", "")
        let model = this.deployStore.resolve("AI_MODEL", "AI_MODEL", "")
        let keySet = !this.deployStore.resolve("AI_API_KEY", "AI_API_KEY", "").isEmpty()
        let sb = StringBuilder()
        sb.append("{\"provider\":\"${AiJsonEscape.s(provider)}\",")
        sb.append("\"baseUrl\":\"${AiJsonEscape.s(baseUrl)}\",")
        sb.append("\"model\":\"${AiJsonEscape.s(model)}\",")
        sb.append("\"apiKeySet\":${keySet},")
        sb.append("\"apiKey\":\"***\",")
        sb.append("\"enabled\":${this.boolSetting("AI_ENABLED", "false")},")
        sb.append("\"onlineAllowed\":${this.boolSetting("AI_ALLOW_ONLINE", "false")},")
        sb.append("\"vision\":${this.boolSetting("AI_ENABLE_VISION", "true")},")
        sb.append("\"summary\":${this.boolSetting("AI_ENABLE_SUMMARY", "true")},")
        sb.append("\"query\":${this.boolSetting("AI_ENABLE_QUERY", "true")},")
        sb.append("\"advice\":${this.boolSetting("AI_ENABLE_ADVICE", "true")}")
        sb.append("}")
        return sb.toString()
    }

    /**
     * 保存配置。密钥留空表示"不修改"（避免脱敏的 *** 覆盖真实密钥）。
     */
    public func save(provider: String, baseUrl: String, model: String, apiKey: String,
                     enabled: Bool, onlineAllowed: Bool,
                     vision: Bool, summary: Bool, query: Bool, advice: Bool,
                     operatorId: Int64): Unit {
        if (!baseUrl.isEmpty() && !baseUrl.startsWith("http://") && !baseUrl.startsWith("https://")) {
            throw validationError("baseUrl", "端点必须以 http:// 或 https:// 开头")
        }
        let updates = HashMap<String, String>()
        if (!provider.isEmpty()) { updates.add("AI_PROVIDER", provider) }
        if (!baseUrl.isEmpty()) { updates.add("AI_BASE_URL", baseUrl) }
        if (!model.isEmpty()) { updates.add("AI_MODEL", model) }
        if (!apiKey.isEmpty() && apiKey != "***") { updates.add("AI_API_KEY", apiKey) }
        this.deployStore.setAll(updates)

        this.setSetting("AI_ENABLED", enabled, operatorId)
        this.setSetting("AI_ALLOW_ONLINE", onlineAllowed, operatorId)
        this.setSetting("AI_ENABLE_VISION", vision, operatorId)
        this.setSetting("AI_ENABLE_SUMMARY", summary, operatorId)
        this.setSetting("AI_ENABLE_QUERY", query, operatorId)
        this.setSetting("AI_ENABLE_ADVICE", advice, operatorId)
    }

    /**
     * 连通性测试：发一个最小的 chat 请求（max_tokens=1），只看能否拿到 2xx + JSON。
     * 不回显响应正文，只回 ok / reason。
     */
    public func testConnection(): String {
        let baseUrl = this.deployStore.resolve("AI_BASE_URL", "AI_BASE_URL", "")
        let key = this.deployStore.resolve("AI_API_KEY", "AI_API_KEY", "")
        let model = this.deployStore.resolve("AI_MODEL", "AI_MODEL", "")
        let kind = parseProvider(this.deployStore.resolve("AI_PROVIDER", "AI_PROVIDER", "ollama"))
        let cfg = ProviderConfig(kind, baseUrl, key, model)
        let reason = cfg.unavailableReason()
        if (!reason.isEmpty()) { return "{\"ok\":false,\"reason\":\"${reason}\"}" }

        let req = AiChatRequest(
            "Reply with OK only.", "ping", AiDomain.Summary, "config-test",
            responseFormat: "text", maxTokens: 1)
        let result = OpenAIClient(cfg).chat(req)
        let ok = result.ok
        let r = if (ok) { "ok" } else { result.error }
        return "{\"ok\":${ok},\"reason\":\"${AiJsonEscape.s(r)}\"}"
    }

    private func boolSetting(key: String, fallback: String): Bool {
        return this.configRepo.getValue("ai", key,
            this.deployStore.resolve(key, key, fallback)) == "true"
    }

    private func setSetting(key: String, value: Bool, operatorId: Int64): Unit {
        let v = if (value) { "true" } else { "false" }
        this.configRepo.setSetting("ai", key, v, "bool", false,
            "AI 配置：${key}", operatorId)
    }
}

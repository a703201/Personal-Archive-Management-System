// ============================================================
// ams.app.ai · AI 应用服务（领域翻译层）
//
// 职责（docs/20 §3.5）：
//   - 把 deployment.env / cfg_settings 装配成 ams.ai 的通用配置
//   - 用户级 opt-out（cfg_settings scope=ai.user, key=userId，OQ12 已定稿）
//   - 对外暴露 capability / chat，供 api 层路由调用
//
// 【边界】ams-app 依赖 ams-ai（基础设施层），ams-ai 不反向依赖本包。
// ============================================================
package ams.app.ai

import std.collection.*

import ams.ai.*
import ams.data.repo.*
import ams.kernel.log.*
import ams.storage.*

/**
 * AI 应用服务：配置装配 + 能力发现 + 通用调用。
 */
public class AiService {
    private let deployStore: DeploymentStore
    private let configRepo: ConfigRepo
    private let log: Log

    public init(deployStore: DeploymentStore, configRepo: ConfigRepo) {
        this.deployStore = deployStore
        this.configRepo = configRepo
        this.log = Log.get()
    }

    /**
     * 读用户级 opt-out（OQ12：存服务端，不用 localStorage）。
     */
    public func isOptedOut(userId: String): Bool {
        let v = this.configRepo.getValue("ai.user", userId, "false")
        return v == "true"
    }

    /**
     * 写用户级 opt-out（PUT /api/me/ai-preference）。
     * userId 由路由从鉴权上下文注入，不接受请求体传入（防越权）。
     */
    public func setOptOut(userId: String, optedOut: Bool, operatorId: Int64): Unit {
        let val = if (optedOut) { "true" } else { "false" }
        this.configRepo.setSetting("ai.user", userId, val, "bool", false,
            "用户级 AI 服务偏好（true=不使用 AI）", operatorId)
        this.log.info("ai.consent.optout", None, [
            ("userId", userId), ("optedOut", val)
        ])
    }

    /**
     * 构造运行时配置：读取部署配置与系统开关。
     */
    private func runtimeConfig(userId: String): AiRuntimeConfig {
        let enabled = this.configRepo.getValue("ai", "AI_ENABLED",
            this.deployStore.resolve("AI_ENABLED", "AI_ENABLED", "false")) == "true"
        let onlineAllowed = this.configRepo.getValue("ai", "AI_ALLOW_ONLINE",
            this.deployStore.resolve("AI_ALLOW_ONLINE", "AI_ALLOW_ONLINE", "false")) == "true"
        let optOut = this.isOptedOut(userId)

        let providers = this.buildProviders()
        return AiRuntimeConfig(
            enabled,
            optOut,
            onlineAllowed,
            this.domainOn("AI_ENABLE_VISION", true),
            this.domainOn("AI_ENABLE_SUMMARY", true),
            this.domainOn("AI_ENABLE_QUERY", true),
            this.domainOn("AI_ENABLE_ADVICE", true),
            providers
        )
    }

    private func domainOn(key: String, fallback: Bool): Bool {
        let def = if (fallback) { "true" } else { "false" }
        return this.configRepo.getValue("ai", key,
            this.deployStore.resolve(key, key, def)) == "true"
    }

    /**
     * 构造 provider 列表，顺序即引擎选择链（§3.3）：
     *   内置本地 → Ollama → LM Studio → 在线 providers。
     */
    private func buildProviders(): Array<ProviderConfig> {
        let out = ArrayList<ProviderConfig>()
        // 内置离线模型（§7.7）：默认指向挂载卷，本地、零出境
        let localPath = this.deployStore.resolve("AI_LOCAL_MODEL_PATH", "AI_LOCAL_MODEL_PATH", "")
        // 内置离线模型：FFI 未接线前不得当作 HTTP provider（GGUF 不是服务端点），
        // 否则会把文件路径拼成 http URL 发出去。探测可用才加入选择链。
        let local = LocalTextModel.probe()
        if (local.available && !localPath.isEmpty()) {
            out.add(ProviderConfig(
                AiProviderKind.LocalBuiltin, localPath, "", "local-qwen0.5b"))
        }
        let ollamaUrl = this.deployStore.resolve("AI_BASE_URL", "AI_BASE_URL",
            "http://127.0.0.1:11434/v1")
        let key = this.deployStore.resolve("AI_API_KEY", "AI_API_KEY", "")
        let kind = parseProvider(this.deployStore.resolve("AI_PROVIDER", "AI_PROVIDER", "ollama"))
        out.add(ProviderConfig(kind, ollamaUrl, key,
            this.deployStore.resolve("AI_MODEL", "AI_MODEL", "qwen2.5vl")))
        return out.toArray()
    }

    /**
     * 能力发现（GET /api/ai/capabilities）。
     */
    public func capabilities(userId: String): AiCapabilities {
        return AiGateway(this.runtimeConfig(userId)).capabilities()
    }

    /**
     * 通用调用（供 V/S/Q/A 各域服务复用）。
     */
    public func chat(userId: String, req: AiChatRequest): AiCallResult {
        return AiGateway(this.runtimeConfig(userId)).chat(req)
    }
}

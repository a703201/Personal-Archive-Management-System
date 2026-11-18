// ============================================================
// ams.ai.localmodel · 内置离线文本模型接入口（骨架）
//
// 对应 docs/20 §7.7：PP-OCRv5（V 域，已在生产跑通）+ Qwen2.5-0.5B
// 文本模型（S/Q/A 域）。后者在本版本**只有 FFI 骨架，未接线**：
//
//   · `packages/ams-ai/native/llama/llama_bridge.c` 提供 llama.cpp 桥接；
//   · `llama_bridge_stub.c` 提供零依赖桩（缺权重/缺 llama.cpp 时用）；
//   · 当前构建**不链接** .so，本类恒返回 unavailable，上层 AiGateway
//     的 provider 选择链自动回退到外部 OpenAI 兼容端点（失败关闭）。
//
// 【为什么这样设计】权重（≈350MB）不随仓库分发，环境也未装 llama.cpp；
//   若现在就声明 foreign func，Windows 门禁与 Linux 构建都会因缺符号失败。
//   故先把"可用性判定 + 明确回退"落地，FFI 真接线等资产齐备时按
//   ocr_ext.cj 的 @When[os] 范式启用（见 §7.7.4）。
// ============================================================
package ams.ai

import std.env.*

/**
 * 内置离线文本模型状态。
 */
public class LocalModelStatus {
    public let available: Bool
    public let reason: String

    public init(available: Bool, reason: String) {
        this.available = available
        this.reason = reason
    }
}

/**
 * 内置离线模型探测（当前恒定不可用，返回可读原因码）。
 */
public class LocalTextModel {
    /**
     * 探测内置模型是否可用。
     *
     * 当前实现：即使配置打开，也返回 false + reason="ffinotwired"，
     * 由上层回退外部 provider。资产齐备后在此处改为 foreign 调用
     * ams_llama_init(modelPath) 并按返回值判定。
     */
    public static func probe(): LocalModelStatus {
        let enabled = getVariable("AMS_LOCAL_MODEL_ENABLED") ?? "false"
        let path = getVariable("AI_LOCAL_MODEL_PATH") ?? ""
        if (enabled != "true") {
            return LocalModelStatus(false, "disabled")
        }
        if (path.isEmpty()) {
            return LocalModelStatus(false, "no_model_path")
        }
        // FFI 未接线：明确报告，不伪造可用（失败关闭红线）。
        return LocalModelStatus(false, "ffinotwired")
    }
}

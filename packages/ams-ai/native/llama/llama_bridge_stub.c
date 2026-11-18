// ============================================================
// AMS · local-qwen0.5b · 零依赖桩桥接层（C）
//
// 提供与 llama_bridge.c 一致的导出符号：
//   ams_llama_init(model_path) / ams_llama_chat(prompt, out, cap) /
//   ams_llama_free()
// 运行时一律「不可用」：init 返回 -1、chat 返回 0（空文本）。
//
// 用途（与 ocr_bridge_stub.c 同构）：
//   · Windows 门禁：不编译任何 C，仓颉侧 @When 裁掉 FFI；本桩仅在
//     可选本地 C 编译时保证链接不缺符号；
//   · Linux 无权重/无 llama.cpp 时：编译本桩，ams.server 链接通过，
//     运行期 LocalTextModel.available() 为 false，上层自动回退外部
//     OpenAI 兼容 provider（docs/20 §7.7）。
//
// 真正的推理只在模型权重 + llama.cpp 资产齐备的部署里通过
// llama_bridge.c 启用（需 AMS_LOCAL_MODEL_ENABLED=true 且路径有效）。
// ============================================================
#include <stdint.h>

int ams_llama_init(const char* model_path) {
    (void)model_path;
    return -1;  // 不可用：上层回退外部 provider
}

int ams_llama_chat(const char* prompt, char* out_text, int out_cap) {
    (void)prompt;
    if (out_text && out_cap > 0) out_text[0] = 0;
    return 0;  // 0 = 无输出 -> 上层回退
}

int ams_llama_free(void) {
    return 0;
}

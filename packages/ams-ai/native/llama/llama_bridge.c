// ============================================================
// AMS · local-qwen0.5b · llama.cpp 桥接骨架（C，Linux）
//
// 【当前状态：骨架，未启用真推理】
//   本文件在 AMS_HAS_LLAMA 未定义时退化为与 llama_bridge_stub.c
//   完全一致的桩行为（init=-1 / chat 空），因此**默认编译也安全**。
//
// 【启用真推理的条件】
//   1. 部署环境提供 llama.cpp 的 llama.h 与 libllama（GGUF CPU 推理）；
//   2. 编译时定义 AMS_HAS_LLAMA 并链接 libllama；
//   3. 配置 AMS_LOCAL_MODEL_ENABLED=true + AI_LOCAL_MODEL_PATH 指向
//      Qwen2.5-0.5B-Instruct Q4_K_M GGUF 权重（约 350MB，不随仓库分发）；
//   4. 走 OpenAI 兼容 chat 格式（system + user → 纯文本输出）。
//
// 【部署形态】仍是单进程单端口，.so 随镜像 / 挂载卷，无独立进程。
// 【失败关闭】任一环节失败 → init=-1，上层回退外部 provider，绝不伪造结果。
// ============================================================
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char* g_model_path = NULL;
static int g_ready = 0;

#ifdef AMS_HAS_LLAMA
// 真推理分支：以下头文件与 API 由部署环境的 llama.cpp 提供。
// 注意：llama.cpp 的 C API 随版本变化，此处以 llama.h 为准，
// 若版本不兼容则编译期失败（ fail closed ），不会静默降级成弱结果。
#include <llama.h>

int ams_llama_init(const char* model_path) {
    if (!model_path || !*model_path) return -1;
    if (g_ready) return 0;

    llama_backend_init();
    llama_model_params mparams = llama_model_default_params();
    llama_model* model = llama_load_model_from_file(model_path, mparams);
    if (!model) {
        fprintf(stderr, "[ams-ai] llama_load_model_from_file failed: %s\n", model_path);
        return -1;
    }
    llama_context_params cparams = llama_context_default_params();
    llama_context* ctx = llama_new_context_with_model(model, cparams);
    if (!ctx) {
        llama_free_model(model);
        fprintf(stderr, "[ams-ai] llama_new_context_with_model failed\n");
        return -1;
    }
    // 简化：单例保存 model/ctx；生产可改为 session 池 + 并发控制。
    // 这里仅验证链路可达，真实服务仍由 OpenAI 兼容客户端承担。
    static llama_model* s_model = NULL;
    static llama_context* s_ctx = NULL;
    if (s_model) llama_free_model(s_model);
    if (s_ctx) llama_free(s_ctx);
    s_model = model;
    s_ctx = ctx;

    size_t len = strlen(model_path) + 1;
    g_model_path = (char*)malloc(len);
    if (!g_model_path) return -1;
    memcpy(g_model_path, model_path, len);
    g_ready = 1;
    return 0;
}

int ams_llama_chat(const char* prompt, char* out_text, int out_cap) {
    if (!g_ready || !prompt || !out_text || out_cap <= 0) return 0;
    // TODO(部署时实现)：tokenize → llama_decode → 逐 token 采样 → detokenize。
    // 未完成前保持空输出，由上层回退外部 provider（失败关闭）。
    out_text[0] = 0;
    return 0;
}

int ams_llama_free(void) {
    g_ready = 0;
    if (g_model_path) { free(g_model_path); g_model_path = NULL; }
    return 0;
}

#else /* !AMS_HAS_LLAMA —— 默认：桩行为，零外部依赖 */

int ams_llama_init(const char* model_path) {
    (void)model_path;
    return -1;
}

int ams_llama_chat(const char* prompt, char* out_text, int out_cap) {
    (void)prompt;
    if (out_text && out_cap > 0) out_text[0] = 0;
    return 0;
}

int ams_llama_free(void) {
    g_ready = 0;
    if (g_model_path) { free(g_model_path); g_model_path = NULL; }
    return 0;
}

#endif

// ============================================================
// AMS · external-ppocrv5 · 零依赖桩桥接层（C）
//
// 提供与 ocr_bridge.c 完全一致的三个导出符号（ams_ocr_init /
// ams_ocr_run / ams_ocr_free），但运行时一律「不可用」：init 返回
// -1、run 返回 0（空文本）。用途：
//   · Linux 构建：当 onnxruntime 资产缺失时，build-linux.sh 编译本桩，
//     保证 ams.server 链接不缺符号，运行期自动回退内置三路 OCR；
//   · Windows 构建：仓颉侧通过 @When[os == "Windows"] 已裁剪掉 FFI，
//     本桩可作为「若存在本地 MinGW/LLVM C 编译器时」的可选编译目标，
//     使 Windows 也能体验外部引擎（默认 @When 方案不需要它）。
//
// 真正的推理只在资产齐备的 Linux 容器里通过 ocr_bridge.c 启用。
// ============================================================
#include <stdint.h>

int ams_ocr_init(void) {
    // 无 ORT/模型：明确报告不可用，由上层回退内置引擎。
    return -1;
}

int ams_ocr_run(const uint8_t* rgb, int w, int h, char* out_text, int out_cap) {
    (void)rgb; (void)w; (void)h;
    if (out_text && out_cap > 0) out_text[0] = 0;
    return 0;  // 0 = 无文本 -> 上层回退
}

int ams_ocr_free(void) {
    return 0;
}

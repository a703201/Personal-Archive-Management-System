// ============================================================
// ams.core.media · 外部 PP-OCRv5 引擎 FFI 封装（进程内，跨平台）
//
// 【跨平台策略：条件编译】
//   · Linux：声明 foreign func（对接 native/ocr_ext/ocr_bridge.c），
//     启用真推理；由 ams_ocr_init 加载模型，ams_ocr_run 跑 det+rec。
//   · Windows：FFI 符号与「真推理」分支整体被 @When[os == "Windows"]
//     裁剪掉，PpOcrV5 恒返回「不可用 / 空文本」，上层自动回退内置三路。
//     这样 Windows 构建/单测门禁完全无外部依赖，也无需在 Windows 上
//     编译任何 C（无本地 MinGW/LLVM C 编译器可用）。
//   两条分支签名完全一致，调用方（MediaOcr）拿到的 contract 不变。
//
// 【开关 + 回退】
//   · 默认关闭：仅当 AMS_OCR_ENGINE=external（且 Linux）才尝试启用；
//   · 惰性初始化（ams_ocr_init），结果缓存到 static；
//   · 任一环节失败（缺模型 / ORT 缺失 / 初始化异常）available() 即
//     返回 false，上层 MediaOcr 自动回退内置三路（CJK / 手写 / 5×7）。
//
// 【部署形态不变】
//   仍是单进程、单端口；外部引擎以 .so 形式随镜像分发，由
//   Dockerfile.prebuilt 拷贝 + LD_LIBRARY_PATH 加载，无独立进程/
//   无端口/无网络调用。
//
// 指针取值采用仓颉 FFI 官方接口（Array 不满足 CType，不能直接当 FFI 参数；
// 元素满足 CType 时用 acquireArrayRawData 先 pin 出裸指针，用完 release）：
//   · acquireArrayRawData(arr): CPointerHandle<T>（.pointer 即 CPointer<T>）
//   · releaseArrayRawData(h) 解除 pin（仅解绑，不释放 Array 内存）
//   · 同步 FFI 调用期间数组被 pin，GC 不搬移；调用后随即解码。
// 注：getRawArray() 是 StringBuilder 的方法，不是 Array 的，勿混用。
// ============================================================
package ams.core.media

@When[os == "Linux"]
import std.env.*
@When[os == "Linux"]
import std.interop.*

// ---- FFI 符号（仅 Linux；Windows 上不声明，从而避免对 .dll 的链接依赖）----
@When[os == "Linux"]
foreign func ams_ocr_init(): Int32
@When[os == "Linux"]
foreign func ams_ocr_run(rgb: CPointer<Byte>, w: Int32, h: Int32, out: CPointer<Byte>, cap: Int32): Int32
@When[os == "Linux"]
foreign func ams_ocr_free(): Int32

/** 外部 PP-OCRv5 引擎封装（Linux 真推理 / Windows 恒不可用）。 */
public class PpOcrV5 {
    private static var initTried: Bool = false
    private static var initOk: Bool = false

    /** 外部引擎是否可用：仅 Linux + AMS_OCR_ENGINE=external + 初始化成功。 */
    @When[os == "Linux"]
    public static func available(): Bool {
        let mode = getVariable("AMS_OCR_ENGINE") ?? "builtin"
        if (mode != "external") {
            return false
        }
        if (PpOcrV5.initTried) {
            return PpOcrV5.initOk
        }
        PpOcrV5.initTried = true
        // init 只加载一次模型；失败即标记不可用，后续请求直接回退。
        PpOcrV5.initOk = (unsafe { ams_ocr_init() } == 0)
        return PpOcrV5.initOk
    }

    @When[os == "Windows"]
    public static func available(): Bool {
        false
    }

    /** 识别整张图，返回纯文本（多行以 \n 分隔）；不可用 / 空结果返回空串。 */
    @When[os == "Linux"]
    public static func recognize(img: RasterImage): String {
        if (!PpOcrV5.available()) {
            return ""
        }
        let n = Int64(img.width) * Int64(img.height) * 3
        if (n <= 0) {
            return ""
        }
        // 文本缓冲：OCR 输出不会很大，1 MiB 充裕。
        let cap: Int64 = 1048576
        let buf = Array<Byte>(cap, repeat: 0u8)
        let text = unsafe {
            // Array 不满足 CType，需先 pin 出裸指针（acquire/release 配对），
            // 保证 FFI 调用期间 GC 不搬移数组内存。
            let hin = acquireArrayRawData(img.pixels)
            let hout = acquireArrayRawData(buf)
            let written = ams_ocr_run(hin.pointer, Int32(img.width), Int32(img.height), hout.pointer, Int32(cap))
            releaseArrayRawData(hout)
            releaseArrayRawData(hin)
            if (written <= 0) {
                ""
            } else {
                // 取前 written 字节，按 UTF-8 解码为 String。
                String.fromUtf8(buf[0..Int64(written)])
            }
        }
        return text
    }

    @When[os == "Windows"]
    public static func recognize(img: RasterImage): String {
        ""
    }
}

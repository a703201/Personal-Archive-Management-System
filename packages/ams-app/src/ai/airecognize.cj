// ============================================================
// ams.app.ai · V5 附件解析与字段预填服务
//
// 对应 docs/20 §5.6 / §5.5：
//   附件 → 内置 OCR 提示 → AI 结构化提取 → 字段候选（来源 + 置信度）
//   → 敏感字段过滤（P9）→ 前端逐条确认后才落库（P10）
//
// 【不做什么】
//   - 不自动写库：只返回候选，采纳走既有编辑接口
//   - 不生成敏感字段明文：sensitivity>=2 只给"建议填写"提示
// ============================================================
package ams.app.ai

import std.collection.*
import stdx.encoding.base64.*

import ams.ai.*
import ams.data.repo.*
import ams.kernel.util.*

/**
 * 附件识别候选字段（前端「待确认字段」卡片的数据源）。
 */
public class FieldCandidate {
    public let code: String
    public let label: String
    public let value: String
    public let confidence: Float64
    public let sourcePage: Int64
    public let needsReview: Bool

    public init(code: String, label: String, value: String, confidence: Float64,
                sourcePage: Int64, needsReview: Bool) {
        this.code = code
        this.label = label
        this.value = value
        this.confidence = confidence
        this.sourcePage = sourcePage
        this.needsReview = needsReview
    }
}

/**
 * 识别结果（含回退标注）。
 */
public class RecognizeOutcome {
    public let fields: Array<FieldCandidate>
    public let engine: String
    public let reason: String

    public init(fields: Array<FieldCandidate>, engine: String, reason: String) {
        this.fields = fields
        this.engine = engine
        this.reason = reason
    }
}

/**
 * V5 附件解析服务。
 */
public class AiRecognizeService {
    private let ai: AiService
    private let fieldDefRepo: FieldDefRepo

    public init(ai: AiService, fieldDefRepo: FieldDefRepo) {
        this.ai = ai
        this.fieldDefRepo = fieldDefRepo
    }

    /**
     * 解析附件为字段候选。
     *
     * @param userId 当前用户（用于 opt-out 与归属）
     * @param category 当前条目分类（决定字段模板）
     * @param subjectId 主体 id（取个人字段模板）
     * @param plainBytes 已解密的附件明文（由 app 层 download，ams-ai 不接触）
     * @param ocrHint 内置 OCR 提示（可选，作为线索非答案）
     */
    public func recognize(
        userId: String,
        category: Int64,
        subjectId: Int64,
        plainBytes: Array<Byte>,
        ocrHint: String
    ): RecognizeOutcome {
        let caps = this.ai.capabilities(userId)
        // 关闭态：不加载模型、不推理（P12），返回明确 skipped
        if (!caps.domainEnabled(AiDomain.Vision)) {
            return RecognizeOutcome([], "skipped", "disabled")
        }

        let defs = this.fieldDefRepo.listByCategory(category, subjectId)
        let safeFields = ArrayList<(String, String, Int64)>()   // key, name, sensitivity
        let sensitiveKeys = ArrayList<String>()
        for (d in defs) {
            if (d.sensitivity >= 2) {
                sensitiveKeys.add(d.fieldKey)
            } else {
                safeFields.add((d.fieldKey, d.fieldName, d.sensitivity))
            }
        }

        let schema = AiRecognizeService.buildSchema(safeFields)
        let (system, userText) = this.buildPrompt(schema, ocrHint, sensitiveKeys)

        // 必须用真实图片 MIME：Ollama /v1/chat/completions 的视觉输入拒绝
        // data:application/octet-stream（返回 400 invalid image input），
        // 只接受 image/png、image/jpeg 等。按 magic bytes 推断，不依赖文件名。
        let mime = AiRecognizeService.imageMime(plainBytes)
        let dataUri = "data:${mime};base64," + toBase64String(plainBytes)
        let req = AiChatRequest(
            system, userText, AiDomain.Vision, "ocr-v1",
            images: [AiImage(dataUri)],
            responseFormat: "json_object")

        let result = this.ai.chat(userId, req)
        match (result.response) {
            case Some(resp) =>
                let fields = AiRecognizeService.parseFields(resp.content, safeFields)
                return RecognizeOutcome(fields, result.engine, "")
            case None =>
                // 失败关闭：回退内置 OCR 提示，不编造字段
                return RecognizeOutcome([], result.engine, result.error)
        }
    }

    /**
     * 新建档案时的一次性文件解析：files 不经附件落库，直接解码后调用视觉识别。
     * 供 POST /api/ai/parse-file 使用；限制文件格式与大小在路由层完成。
     */
    public func recognizeUpload(
        userId: String,
        category: Int64,
        subjectId: Int64,
        base64Data: String,
        fileName: String
    ): RecognizeOutcome {
        let bytes = match (fromBase64String(base64Data)) {
            case Some(b) => b
            case None => return RecognizeOutcome([], "", "read_failed")
        }
        if (bytes.isEmpty()) {
            return RecognizeOutcome([], "", "read_failed")
        }
        // 视觉模型只认图片：PDF 直接给明确原因码，不发必然 400 的请求，
        // 也不把内部引擎名（fallback-builtin(http_400)）暴露给用户。
        let mime = AiRecognizeService.imageMime(bytes)
        if (!mime.startsWith("image/")) {
            return RecognizeOutcome([], "", "unsupported_format")
        }
        // 文件明文作为视觉输入；不给内置 OCR 提示（新建态尚未走附件 OCR 链路）
        return this.recognize(userId, category, subjectId, bytes, "upload:${fileName}")
    }

    /**
     * 按 magic bytes 推断图片 MIME（视觉模型只认具体图片类型，不认 octet-stream）。
     * PDF 无法作为视觉输入交给 Ollama，标记为 application/pdf 让下游明确失败并降级。
     */
    private static func imageMime(bytes: Array<Byte>): String {
        if (bytes.size >= 8 &&
            bytes[0] == 0x89u8 && bytes[1] == 0x50u8 && bytes[2] == 0x4Eu8 && bytes[3] == 0x47u8) {
            return "image/png"
        }
        if (bytes.size >= 3 &&
            bytes[0] == 0xFFu8 && bytes[1] == 0xD8u8 && bytes[2] == 0xFFu8) {
            return "image/jpeg"
        }
        if (bytes.size >= 6 &&
            bytes[0] == 0x47u8 && bytes[1] == 0x49u8 && bytes[2] == 0x46u8) {
            return "image/gif"
        }
        if (bytes.size >= 12 && bytes[0] == 0x52u8 && bytes[1] == 0x49u8 &&
            bytes[2] == 0x46u8 && bytes[3] == 0x46u8 && bytes[8] == 0x57u8 &&
            bytes[9] == 0x45u8 && bytes[10] == 0x42u8 && bytes[11] == 0x50u8) {
            return "image/webp"
        }
        if (bytes.size >= 4 &&
            bytes[0] == 0x25u8 && bytes[1] == 0x50u8 && bytes[2] == 0x44u8 && bytes[3] == 0x46u8) {
            return "application/pdf"
        }
        // 兜底 octet-stream：模型会明确 400，由既有降级链处理，不臆造类型
        return "application/octet-stream"
    }

    private func buildPrompt(schema: String, ocrHint: String, sensitiveKeys: ArrayList<String>): (String, String) {
        let b = PromptBuilder()
        b.system(AI_SYSTEM_BASE)
        b.task("Extract archive fields from the document image. Return JSON only.")
        b.schema("Allowed fields (fieldCode -> label): ${schema}")
        b.data("document_hint", ocrHint)
        let sens = StringBuilder()
        for (k in sensitiveKeys) { sens.append("${k},") }
        b.instruction("Never output these sensitive field keys: ${sens.toString()}")
        // 等级/级别类字段的常见误判：证书上最醒目的大字常是「认证方向/技术名」
        // （如 openEuler），而真正的「等级」在徽章里（HCIA/HCIP/HCIE）。
        // 给模型一条通用语义规则，避免把方向当成等级。
        b.instruction("For a 'level/grade' field (code containing 'level' or label containing 等级/级别), " +
            "output the certification LEVEL shown on the credential (e.g. HCIA, HCIP, HCIE, " +
            "初级/中级/高级, Level 1/2/3), NOT the technology/direction name " +
            "(e.g. openEuler, Kunpeng, AI). Look inside badges/seals for the level mark.")
        b.outputContract(AI_OUTPUT_CONTRACT +
            " Output: {\"fields\":[{\"code\":\"...\",\"value\":\"...\"," +
            "\"confidence\":0.0-1.0,\"sourcePage\":1}]}")
        return b.build([])
    }

    private static func buildSchema(fields: ArrayList<(String, String, Int64)>): String {
        let sb = StringBuilder()
        sb.append("{")
        var first = true
        for ((k, name, _) in fields) {
            if (!first) { sb.append(",") }
            first = false
            sb.append("\"${AiJsonEscape.s(k)}\":\"${AiJsonEscape.s(name)}\"")
        }
        sb.append("}")
        return sb.toString()
    }

    /**
     * 解析模型返回的 fields 数组，按白名单过滤未知/敏感字段。
     * 用 AiJson 提取每个元素的原始串（不做完整 AST）。
     */
    public static func parseFields(content: String, allowed: ArrayList<(String, String, Int64)>): Array<FieldCandidate> {
        let out = ArrayList<FieldCandidate>()
        let j = match (AiJson.of(content)) {
            case Some(x) => x
            case None => return out.toArray()
        }
        let rawFields = j.value("fields")   // 原始数组串
        match (rawFields) {
            case Some(arrJson) =>
                for ((code, label, _) in allowed) {
                    // 在数组里找该 code 的元素（简化：整段文本里定位 "code":"<code>"）
                    match (AiRecognizeService.findFieldValue(arrJson, code)) {
                        case Some((value, conf, page)) =>
                            let needsReview = conf < 0.9
                            out.add(FieldCandidate(code, label, value, conf, page, needsReview))
                        case None => ()
                    }
                }
            case None => ()
        }
        return out.toArray()
    }

    /**
     * 从 fields 数组原始串里找指定 code 的 value/confidence/sourcePage。
     * 采用分段扫描：按 "code" 切块，在块内取三个字段。
     */
    public static func findFieldValue(arr: String, code: String): Option<(String, Float64, Int64)> {
        // 旧实现硬匹配 "\"code\":\"x\""（冒号后无空格），但模型常输出
        // pretty JSON（"code": "x"，带空格/换行）→ 字段全部匹配不上、返回空。
        // 改为用 AiJson 逐个解析 {...} 对象片段，按 str("code") 比对，
        // 完全不依赖空白与键顺序。
        let b = arr.toArray()
        var i: Int64 = 0
        while (i < b.size) {
            if (b[i] != b'{') { i = i + 1; continue }
            // 找匹配的右花括号（字段对象无嵌套，遇到第一个 } 即止）
            var end = i + 1
            while (end < b.size && b[end] != b'}') { end = end + 1 }
            if (end >= b.size) { break }
            let obj = String.fromUtf8(b[i..end + 1])
            match (AiJson.of(obj)) {
                case Some(oj) =>
                    if (match (oj.str("code")) { case Some(c) => c == code; case None => false }) {
                        let value = match (oj.str("value")) { case Some(v) => v; case None => "" }
                        let conf = match (oj.str("confidence")) {
                            case Some(c) => AiRecognizeService.toFloat(c)
                            case None => 0.0
                        }
                        let page = match (oj.str("sourcePage")) {
                            case Some(p) => AiRecognizeService.toInt(p)
                            case None => 1
                        }
                        return Some((value, conf, page))
                    }
                case None => ()
            }
            i = end + 1
        }
        return None
    }

    private static func toFloat(s: String): Float64 {
        let t = trimSpace(s)
        if (t.isEmpty()) { return 0.0 }
        // 简单解析：支持 "0.93"
        var intPart: Int64 = 0
        var frac: Int64 = 0
        var scale: Int64 = 1
        var dot = false
        let b = t.toArray()
        for (c in b) {
            if (c == 46u8) { dot = true; continue }
            if (c < 48u8 || c > 57u8) { break }
            if (dot) {
                frac = frac * 10 + Int64(c - 48u8)
                scale = scale * 10
            } else {
                intPart = intPart * 10 + Int64(c - 48u8)
            }
        }
        return Float64(intPart) + Float64(frac) / Float64(scale)
    }

    private static func toInt(s: String): Int64 {
        let t = trimSpace(s)
        var v: Int64 = 0
        for (c in t.toArray()) {
            if (c < 48u8 || c > 57u8) { break }
            v = v * 10 + Int64(c - 48u8)
        }
        return if (v == 0) { 1 } else { v }
    }
}

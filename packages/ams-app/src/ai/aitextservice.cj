// ============================================================
// ams.app.ai · S 档案总结 / A 智能建议服务（只读版）
//
// 对应 docs/20 §5.2 / §5.4：
//   - S：对条目字段生成摘要 + 关键词（Grounded，不编造）
//   - A：分类归属 / 缺失字段 / 到期提醒候选
//
// 【本期边界·如实标注】只返回候选给前端预览，**不自动落库**：
//   落库走既有编辑接口 + 人工确认（P10），避免整条目 update 的并发覆盖。
// 【敏感最小化 P9】sensitivity>=2 的字段值不进模型上下文，只给字段名。
// ============================================================
package ams.app.ai

import std.collection.*

import ams.ai.*
import ams.data.repo.*
import ams.kernel.util.*

/**
 * 文本域结果（摘要或建议，统一结构）。
 */
public class AiTextOutcome {
    public let kind: String
    public let text: String
    public let keywords: Array<String>
    public let reason: String

    public init(kind: String, text: String, keywords: Array<String>, reason: String) {
        this.kind = kind
        this.text = text
        this.keywords = keywords
        this.reason = reason
    }
}

/**
 * S/A 文本域服务。
 */
public class AiTextService {
    private let ai: AiService
    private let itemRepo: ItemRepo
    private let fieldRepo: ItemFieldRepo
    private let defRepo: FieldDefRepo

    public init(ai: AiService, itemRepo: ItemRepo, fieldRepo: ItemFieldRepo, defRepo: FieldDefRepo) {
        this.ai = ai
        this.itemRepo = itemRepo
        this.fieldRepo = fieldRepo
        this.defRepo = defRepo
    }

    /**
     * S 域：单条目摘要。
     */
    public func summarize(userId: String, itemId: Int64): AiTextOutcome {
        let caps = this.ai.capabilities(userId)
        if (!caps.domainEnabled(AiDomain.Summary)) {
            return AiTextOutcome("summary", "", [], "disabled")
        }
        let rec = match (this.itemRepo.findByIdRaw(itemId)) {
            case Some(r) => r
            case None => return AiTextOutcome("summary", "", [], "not_found")
        }
        let safe = this.collectSafeFields(itemId)
        let (system, userText) = this.buildSummaryPrompt(rec.title, safe)
        let req = AiChatRequest(system, userText, AiDomain.Summary, "summary-v1")
        let result = this.ai.chat(userId, req)
        match (result.response) {
            case Some(resp) =>
                let j = match (AiJson.of(resp.content)) {
                    case Some(x) => x
                    case None => return AiTextOutcome("summary", "", [], "invalid_json")
                }
                let summary = match (j.str("summary")) { case Some(s) => s; case None => "" }
                var kws = ArrayList<String>()
                for (k in j.array("keywords")) { kws.add(AiTextService.unquote(k)) }
                return AiTextOutcome("summary", summary, kws.toArray(), "")
            case None =>
                return AiTextOutcome("summary", "", [], result.error)
        }
    }

    /**
     * A 域：分类归属建议（只读候选）。
     */
    public func adviseCategory(userId: String, itemId: Int64): AiTextOutcome {
        let caps = this.ai.capabilities(userId)
        if (!caps.domainEnabled(AiDomain.Advice)) {
            return AiTextOutcome("advice", "", [], "disabled")
        }
        let rec = match (this.itemRepo.findByIdRaw(itemId)) {
            case Some(r) => r
            case None => return AiTextOutcome("advice", "", [], "not_found")
        }
        let b = PromptBuilder()
        b.system(AI_SYSTEM_BASE)
        b.task("Suggest one archive category (1..11) for the item, with a reason and confidence.")
        b.schema("Allowed: 1个人基本信息 2证件信息 3教育经历 4职业经历 5资质证书 6联系方式 7家庭关系 8健康信息 9资产信息 10影像附件 11自定义分类")
        b.data("item", rec.title)
        b.outputContract("Output: {\"suggestion\":\"2\",\"reason\":\"...\",\"confidence\":0.0-1.0}. Do not include execute/send fields.")
        let (system, userText) = b.build([])
        let req = AiChatRequest(system, userText, AiDomain.Advice, "advise-v1")
        let result = this.ai.chat(userId, req)
        match (result.response) {
            case Some(resp) =>
                match (AiJson.of(resp.content)) {
                    case Some(j) =>
                        let sug = match (j.str("suggestion")) { case Some(s) => s; case None => "" }
                        let reason = match (j.str("reason")) { case Some(s) => s; case None => "" }
                        return AiTextOutcome("advice", "${sug}|${reason}", [], "")
                    case None => return AiTextOutcome("advice", "", [], "invalid_json")
                }
            case None => return AiTextOutcome("advice", "", [], result.error)
        }
    }

    /**
     * 收集非敏感字段值（P9）。ItemFieldValue 的字段名按实际结构调整。
     */
    private func collectSafeFields(itemId: Int64): String {
        let defs = this.defRepo.listBuiltin(1)
        let fields = this.fieldRepo.listByItem(itemId)
        let sb = StringBuilder()
        sb.append("[")
        var first = true
        for (f in fields) {
            let key = f.fieldKey
            // 敏感字段（证件号/手机/健康/资产等）只给键名，不给值
            if (AiTextService.isSensitiveKey(key)) { continue }
            if (!first) { sb.append(",") }
            first = false
            sb.append("{\"k\":\"${AiJsonEscape.s(key)}\"}")
        }
        sb.append("]")
        return sb.toString()
    }

    private static func isSensitiveKey(key: String): Bool {
        let lower = AiTextService.lower(key)
        let sensitive = ["id_card", "idcard", "phone", "email", "health", "asset", "member_id", "passport", "chip"]
        for (s in sensitive) {
            if (lower.contains(s)) { return true }
        }
        return false
    }

    private func buildSummaryPrompt(title: String, fields: String): (String, String) {
        let b = PromptBuilder()
        b.system(AI_SYSTEM_BASE)
        b.task("Summarize the archive item in one short non-sensitive paragraph with keywords.")
        b.data("title", title)
        b.data("fields", fields)
        b.outputContract("Output: {\"summary\":\"...\",\"keywords\":[\"...\"]}. Only use provided data; never invent facts.")
        return b.build([])
    }

    private static func unquote(s: String): String {
        let t = trimSpace(s)
        if (t.size >= 2 && t.startsWith("\"") && t.endsWith("\"")) {
            let b = t.toArray()
            return String.fromUtf8(b[1..b.size - 1])
        }
        return t
    }

    private static func lower(s: String): String {
        let b = s.toArray()
        let out = Array<Byte>(b.size, repeat: 0u8)
        for (i in 0..b.size) {
            var c = b[i]
            if (c >= 65u8 && c <= 90u8) { c = c + 32u8 }
            out[i] = c
        }
        return String.fromUtf8(out)
    }
}

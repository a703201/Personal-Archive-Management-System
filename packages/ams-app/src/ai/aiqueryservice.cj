// ============================================================
// ams.app.ai · Q 域自然语言查询服务
//
// 对应 docs/20 §5.3：两阶段——NL→结构化条件（走现有 SearchService），
// 再对命中条目做 grounded 回答（本期可选）。
//
// 【安全红线 P8】归属绝不委托：subjectIds 恒由服务端注入，
//   模型输出中任何 subject/owner/permission 字段一律拒绝整条请求。
// 【不另起检索】零新基础设施，复用 SearchQueryBuilder + SearchService。
// ============================================================
package ams.app.ai

import std.collection.*

import ams.ai.*
import ams.app.search.*
import ams.core.search.*
import ams.data.repo.*
import ams.kernel.util.*

/**
 * 查询请求结果（供 api 层序列化）。
 */
public class AiQueryOutcome {
    public let query: String
    public let keyword: String
    public let categories: Array<Int64>
    public let expiresTo: String
    public let itemIds: Array<Int64>
    public let reason: String

    public init(query: String, keyword: String, categories: Array<Int64>,
                expiresTo: String, itemIds: Array<Int64>, reason: String) {
        this.query = query
        this.keyword = keyword
        this.categories = categories
        this.expiresTo = expiresTo
        this.itemIds = itemIds
        this.reason = reason
    }
}

/**
 * Q 域自然语言查询服务。
 */
public class AiQueryService {
    private let ai: AiService
    private let search: SearchService
    private let userRepo: UserRepo

    public init(ai: AiService, search: SearchService, userRepo: UserRepo) {
        this.ai = ai
        this.search = search
        this.userRepo = userRepo
    }

    /**
     * 自然语言 → 结构化搜索条件 → 现有 SearchService。
     *
     * @param userId 当前用户（鉴权上下文）
     * @param question 用户问题（作为数据，不作为指令）
     */
    public func ask(userId: String, question: String): AiQueryOutcome {
        let caps = this.ai.capabilities(userId)
        if (!caps.domainEnabled(AiDomain.Query)) {
            // 关闭态：降级为把问题原样当关键词（§3.3），不调用模型
            return this.runSearch(userId, question, [], "", "")
        }
        if (trimSpace(question).isEmpty()) {
            return AiQueryOutcome(question, "", [], "", [], "empty_question")
        }

        // 提示词：只给白名单键，从 Schema 层不给越权字段（P8）
        let (system, userText) = this.buildPrompt(question)
        let req = AiChatRequest(system, userText, AiDomain.Query, "query-v1")
        let result = this.ai.chat(userId, req)

        match (result.response) {
            case Some(resp) =>
                match (this.parseConditions(resp.content)) {
                    case Some((kw, cats, expTo)) =>
                        return this.runSearch(userId, kw, cats, expTo, "")
                    case None =>
                        // 非法条件（含越权字段）→ 拒绝，不猜默认值（§4.5）
                        return AiQueryOutcome(question, "", [], "", [], "query_rejected")
                }
            case None =>
                // 模型不可用 → 降级普通搜索（§3.3）
                return this.runSearch(userId, question, [], "", result.error)
        }
    }

    private func buildPrompt(question: String): (String, String) {
        let b = PromptBuilder()
        b.system(AI_SYSTEM_BASE)
        b.task("Translate the user question into search conditions. Output JSON only.")
        b.schema("Allowed keys ONLY: keyword(string), category(array of int 1..11), expiresTo(string YYYY-MM-DD). " +
                 "NEVER output subjectIds/subject/owner/permission/limit/cursor/sort.")
        b.data("question", question)
        b.outputContract("Output: {\"keyword\":\"...\",\"category\":[2],\"expiresTo\":\"\"}")
        return b.build([])
    }

    /**
     * 解析并强校验条件。返回 None 表示整条拒绝（含越权字段/非法值）。
     */
    private func parseConditions(content: String): Option<(String, Array<Int64>, String)> {
        let j = match (AiJson.of(content)) {
            case Some(x) => x
            case None => return None
        }
        // P8：任何越权字段出现即整条拒绝
        let forbidden = ["subjectIds", "subject", "owner", "permission", "limit", "cursor", "sort"]
        for (k in forbidden) {
            match (j.value(k)) {
                case Some(_) => return None
                case None => ()
            }
        }
        let keyword = match (j.str("keyword")) { case Some(v) => v; case None => "" }
        var cats = ArrayList<Int64>()
        for (raw in j.array("category")) {
            let v = AiQueryService.parseInt(raw)
            if (v < 1 || v > 11) { return None }
            cats.add(v)
        }
        let expiresTo = match (j.str("expiresTo")) {
            case Some(v) => if (AiQueryService.isDate(v)) { v } else { return None }
            case None => ""
        }
        return Some((keyword, cats.toArray(), expiresTo))
    }

    /**
     * 用现有 SearchService 执行；subjectIds 由服务端注入（P8）。
     */
    private func runSearch(userId: String, keyword: String, cats: Array<Int64>,
                           expiresTo: String, reason: String): AiQueryOutcome {
        let uid = UserRepo.parseId(userId)
        let subjects = this.userRepo.listAccessibleSubjectIds(uid).toArray()
        let b = SearchQueryBuilder()
        b.keyword_(keyword).subjectScope(subjects).category(cats)
        if (!expiresTo.isEmpty()) {
            b.expiresRange("", expiresTo)
        }
        let q = b.build()
        let rows = this.search.search(q).all()
        var ids = ArrayList<Int64>()
        for (r in rows) {
            ids.add(r.i64("id"))
        }
        return AiQueryOutcome("", keyword, cats, expiresTo, ids.toArray(), reason)
    }

    private static func parseInt(s: String): Int64 {
        let t = trimSpace(s)
        var v: Int64 = 0
        for (c in t.toArray()) {
            if (c < 48u8 || c > 57u8) { break }
            v = v * 10 + Int64(c - 48u8)
        }
        return v
    }

    private static func isDate(s: String): Bool {
        let b = s.toArray()
        if (b.size != 10) { return false }
        for (i in 0..b.size) {
            if (i == 4 || i == 7) {
                if (b[i] != 45u8) { return false }
            } else {
                if (b[i] < 48u8 || b[i] > 57u8) { return false }
            }
        }
        return true
    }
}

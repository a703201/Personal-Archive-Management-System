// ============================================================
// ams.api.routes.ai · AI 能力接口
//
// 覆盖 docs/20：
//   GET  /api/ai/capabilities     能力发现（关闭态统一判定，§6.9.1）
//   PUT  /api/me/ai-preference    用户级 opt-out（OQ12，存服务端）
//
// 【越权防护】偏好只能改当前用户：userId 恒取自 req.subjectId，
//   请求体不接受 userId / ownerId（与 P8 / FR-ACL-006 同构）。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.ai.*
import ams.api.http.*
import ams.app.ai.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.util.*

/**
 * AI 能力路由。
 */
public class AiRoutes {
    private let service: AiService
    private let intake: ?AiIntakeService
    private let recognizer: ?AiRecognizeService
    private let query: ?AiQueryService
    private let text: ?AiTextService
    private let admin: ?AiAdminService
    /** 对象级归属校验依赖：未装配时相关接口一律拒绝（失败关闭） */
    private let itemRepo: ?ItemRepo
    private let attachmentRepo: ?AttachmentRepo
    private let userRepo: ?UserRepo

    public init(service: AiService, intake!: ?AiIntakeService = None,
                recognizer!: ?AiRecognizeService = None,
                query!: ?AiQueryService = None, text!: ?AiTextService = None,
                admin!: ?AiAdminService = None,
                itemRepo!: ?ItemRepo = None,
                attachmentRepo!: ?AttachmentRepo = None,
                userRepo!: ?UserRepo = None) {
        this.service = service
        this.intake = intake
        this.recognizer = recognizer
        this.query = query
        this.text = text
        this.admin = admin
        this.itemRepo = itemRepo
        this.attachmentRepo = attachmentRepo
        this.userRepo = userRepo
    }

    /**
     * AI 接口的对象级归属校验：条目/附件必须属于调用者可访问主体。
     * 与 items 路由 guard 同源（可访问主体集合由服务端计算），
     * 不信任前端传入的 subjectId。
     */
    private func requireSubjectAccess(req: ApiRequest, subjectId: Int64): Unit {
        let ur = match (this.userRepo) {
            case Some(r) => r
            case None => throw AppError(AppErrorKind.Forbidden, "AI 对象级鉴权未装配")
        }
        let allowed = ur.listAccessibleSubjectIds(UserRepo.parseId(req.subjectId))
        for (s in allowed) {
            if (RowData.toI64(s) == subjectId) {
                return
            }
        }
        throw AppError(AppErrorKind.Forbidden, "无权访问该条目或附件")
    }

    private func requireItemAccess(req: ApiRequest, itemId: Int64): Unit {
        let ir = match (this.itemRepo) {
            case Some(r) => r
            case None => throw AppError(AppErrorKind.Forbidden, "AI 对象级鉴权未装配")
        }
        let rec = match (ir.findByIdRaw(itemId)) {
            case Some(r) => r
            case None => throw AppError(AppErrorKind.NotFound, "条目不存在")
        }
        this.requireSubjectAccess(req, RowData.toI64(rec.subjectId))
    }

    private func requireAttachmentAccess(req: ApiRequest, attachmentId: Int64): Unit {
        let ar = match (this.attachmentRepo) {
            case Some(r) => r
            case None => throw AppError(AppErrorKind.Forbidden, "AI 对象级鉴权未装配")
        }
        let rec = match (ar.findById(attachmentId)) {
            case Some(r) => r
            case None => throw AppError(AppErrorKind.NotFound, "附件不存在")
        }
        this.requireSubjectAccess(req, rec.subjectId)
    }

    public func register(router: Router): Unit {
        router.get("/api/ai/capabilities", { req: ApiRequest => this.capabilities(req) },
                   requiredPerm: "archive:read:own")
        router.put("/api/me/ai-preference", { req: ApiRequest => this.setPreference(req) },
                   requiredPerm: "archive:read:own")
        router.post("/api/attachments/:id/ai-parse", { req: ApiRequest => this.aiParse(req) },
                    requiredPerm: "archive:read:own")
        router.post("/api/ai/parse-file", { req: ApiRequest => this.parseFile(req) },
                    requiredPerm: "attachment:upload:own")
        router.post("/api/search/ask", { req: ApiRequest => this.ask(req) },
                    requiredPerm: "archive:read:own")
        router.post("/api/summary/items/:id", { req: ApiRequest => this.summarize(req) },
                    requiredPerm: "archive:read:own")
        router.post("/api/advice/items/:id", { req: ApiRequest => this.advise(req) },
                    requiredPerm: "archive:read:own")
        router.get("/api/admin/ai/config", { req: ApiRequest => this.adminRead(req) },
                   requiredPerm: "system:admin")
        router.put("/api/admin/ai/config", { req: ApiRequest => this.adminSave(req) },
                   requiredPerm: "system:admin")
        router.post("/api/admin/ai/test", { req: ApiRequest => this.adminTest(req) },
                    requiredPerm: "system:admin")
    }

    private func requireAdmin(req: ApiRequest): AiAdminService {
        match (this.admin) {
            case Some(a) => return a
            case None => throw validationError("admin", "AI 配置管理不可用")
        }
    }

    private func adminRead(req: ApiRequest): ApiResponse {
        let a = this.requireAdmin(req)
        return ApiResponse.ok(a.readJson(), req.requestId)
    }

    private func adminSave(req: ApiRequest): ApiResponse {
        let a = this.requireAdmin(req)
        let j = match (SimpleJson.parse(req.bodyText())) {
            case Some(x) => x
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        let operatorId = AiRoutes.parseId(req.subjectId)
        a.save(
            j.get("provider") ?? "", j.get("baseUrl") ?? "",
            j.get("model") ?? "", j.get("apiKey") ?? "",
            AiRoutes.boolField(j, "enabled", false),
            AiRoutes.boolField(j, "onlineAllowed", false),
            AiRoutes.boolField(j, "vision", true),
            AiRoutes.boolField(j, "summary", true),
            AiRoutes.boolField(j, "query", true),
            AiRoutes.boolField(j, "advice", true), operatorId)
        return ApiResponse.ok(a.readJson(), req.requestId)
    }

    private func adminTest(req: ApiRequest): ApiResponse {
        let a = this.requireAdmin(req)
        return ApiResponse.ok(a.testConnection(), req.requestId)
    }

    /**
     * 序列化文本域结果（S 摘要 / A 建议）。候选不自动落库（P10）。
     */
    private func textResponse(out: AiTextOutcome, req: ApiRequest): ApiResponse {
        let sb = StringBuilder()
        sb.append("{\"kind\":\"${ApiResponse.escape(out.kind)}\",")
        sb.append("\"text\":\"${ApiResponse.escape(out.text)}\",")
        sb.append("\"keywords\":[")
        for (i in 0..out.keywords.size) {
            if (i > 0) { sb.append(",") }
            sb.append("\"${ApiResponse.escape(out.keywords[i])}\"")
        }
        sb.append("],\"reason\":\"${ApiResponse.escape(out.reason)}\"}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    private func summarize(req: ApiRequest): ApiResponse {
        let svc = match (this.text) {
            case Some(t) => t
            case None => return ApiResponse.ok("{\"text\":\"\",\"reason\":\"disabled\"}", req.requestId)
        }
        let id = AiRoutes.parseId(req.pathParam("id") ?? "")
        if (id == 0) { throw validationError("id", "条目 id 无效") }
        this.requireItemAccess(req, id)
        let uid = AiRoutes.parseId(req.subjectId)
        return this.textResponse(svc.summarize("${uid}", id), req)
    }

    private func advise(req: ApiRequest): ApiResponse {
        let svc = match (this.text) {
            case Some(t) => t
            case None => return ApiResponse.ok("{\"text\":\"\",\"reason\":\"disabled\"}", req.requestId)
        }
        let id = AiRoutes.parseId(req.pathParam("id") ?? "")
        if (id == 0) { throw validationError("id", "条目 id 无效") }
        this.requireItemAccess(req, id)
        let uid = AiRoutes.parseId(req.subjectId)
        return this.textResponse(svc.adviseCategory("${uid}", id), req)
    }

    /**
     * POST /api/search/ask —— Q 域自然语言查询（docs/20 §5.3）。
     * 返回 {query, keyword, category, expiresTo, itemIds, reason}；
     * 归属由服务端注入，模型给的越权字段整条拒绝。
     */
    private func ask(req: ApiRequest): ApiResponse {
        let svc = match (this.query) {
            case Some(q) => q
            case None => return ApiResponse.ok("{\"itemIds\":[],\"reason\":\"disabled\"}", req.requestId)
        }
        let json = match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        let question = json.get("question") ?? ""
        let uid = AiRoutes.parseId(req.subjectId)
        let out = svc.ask("${uid}", question)
        let sb = StringBuilder()
        sb.append("{\"query\":\"${ApiResponse.escape(out.query)}\",")
        sb.append("\"keyword\":\"${ApiResponse.escape(out.keyword)}\",")
        sb.append("\"category\":[")
        for (i in 0..out.categories.size) {
            if (i > 0) { sb.append(",") }
            sb.append("${out.categories[i]}")
        }
        sb.append("],\"expiresTo\":\"${ApiResponse.escape(out.expiresTo)}\",")
        sb.append("\"itemIds\":[")
        for (i in 0..out.itemIds.size) {
            if (i > 0) { sb.append(",") }
            sb.append("${out.itemIds[i]}")
        }
        sb.append("],\"reason\":\"${ApiResponse.escape(out.reason)}\"}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * POST /api/attachments/:id/ai-parse —— V5 附件解析（docs/20 §5.6）。
     * 返回字段候选（含来源页与置信度）；失败只给原因码，不暴露堆栈（§5.6.6）。
     */
    private func aiParse(req: ApiRequest): ApiResponse {
        let svc = match (this.intake) {
            case Some(s) => s
            case None => return ApiResponse.ok("{\"fields\":[],\"reason\":\"disabled\"}", req.requestId)
        }
        let id = AiRoutes.parseId(req.pathParam("id") ?? "")
        if (id == 0) { throw validationError("id", "附件 id 无效") }
        this.requireAttachmentAccess(req, id)
        let uid = AiRoutes.parseId(req.subjectId)
        let out = svc.parseAttachment("${uid}", id)
        return ApiResponse.ok(AiRoutes.serializeOutcome(out), req.requestId)
    }

    /** 新建档案时的一次性文件解析：文件不落库，直接 base64 送入视觉模型。 */
    private func parseFile(req: ApiRequest): ApiResponse {
        let svc = match (this.recognizer) {
            case Some(s) => s
            case None => return ApiResponse.ok("{\"fields\":[],\"reason\":\"disabled\"}", req.requestId)
        }
        let json = match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        let fileName = json.get("fileName") ?? ""
        let data = json.get("data") ?? ""
        let ext = AiRoutes.lowerExt(fileName)
        if (!["jpg", "jpeg", "png", "pdf"].contains(ext)) {
            return ApiResponse.ok("{\"fields\":[],\"reason\":\"unsupported_format\"}", req.requestId)
        }
        // 50MB 上限（base64 膨胀约 4/3）
        if (data.size > 70_000_000) {
            return ApiResponse.ok("{\"fields\":[],\"reason\":\"read_failed\"}", req.requestId)
        }
        let category = AiRoutes.parseId(json.get("category") ?? "0")
        let subjectId = AiRoutes.parseId(json.get("subjectId") ?? "0")
        let uid = AiRoutes.parseId(req.subjectId)
        let out = svc.recognizeUpload("${uid}", category, subjectId, data, fileName)
        return ApiResponse.ok(AiRoutes.serializeOutcome(out), req.requestId)
    }

    private static func serializeOutcome(out: RecognizeOutcome): String {
        let sb = StringBuilder()
        sb.append("{\"fields\":[")
        var first = true
        for (f in out.fields) {
            if (!first) { sb.append(",") }
            first = false
            sb.append("{\"code\":\"${ApiResponse.escape(f.code)}\",")
            sb.append("\"label\":\"${ApiResponse.escape(f.label)}\",")
            sb.append("\"value\":\"${ApiResponse.escape(f.value)}\",")
            sb.append("\"confidence\":${f.confidence},")
            sb.append("\"sourcePage\":${f.sourcePage},")
            sb.append("\"needsReview\":${f.needsReview}}")
        }
        sb.append("],\"engine\":\"${ApiResponse.escape(out.engine)}\",")
        sb.append("\"reason\":\"${ApiResponse.escape(out.reason)}\"}")
        return sb.toString()
    }

    private func capabilities(req: ApiRequest): ApiResponse {
        let uid = AiRoutes.parseId(req.subjectId)
        let c = this.service.capabilities("${uid}")
        // reason 码不返回给前端（P12：关闭态连"AI 已关闭"提示都不渲染）
        let sb = StringBuilder()
        sb.append("{\"aiEnabled\":${c.aiEnabled},")
        sb.append("\"optOut\":${c.optOut},")
        sb.append("\"onlineAllowed\":${c.onlineAllowed},")
        sb.append("\"domains\":{")
        sb.append("\"vision\":${c.vision},\"summary\":${c.summary},")
        sb.append("\"query\":${c.query},\"advice\":${c.advice}")
        sb.append("}}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * PUT /api/me/ai-preference —— body: {"optOut": true|false}
     */
    private func setPreference(req: ApiRequest): ApiResponse {
        let json = match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        // 明确拒绝归属字段（防越权）
        if (json.get("userId").isSome() || json.get("ownerId").isSome()) {
            throw validationError("userId", "偏好只能修改当前用户自己")
        }
        let optedOut = json.get("optOut") == "true"
        let uid = AiRoutes.parseId(req.subjectId)
        this.service.setOptOut("${uid}", optedOut, uid)
        return ApiResponse.ok("{\"optOut\":${optedOut}}", req.requestId)
    }

    /** 从 SimpleJson 读布尔字段（缺省用默认值），避免多参数 lambda。 */
    private static func boolField(j: SimpleJson, key: String, def: Bool): Bool {
        match (j.get(key)) {
            case Some(v) => return v == "true"
            case None => return def
        }
    }

    /** 与 UserRepo.parseId 同语义；内联避免 api 层新增 ams.data.repo import（跨层基线 26）。 */
    private static func parseId(s: String): Int64 {
        if (s.isEmpty()) { return 0 }
        var acc: Int64 = 0
        for (b in s.toArray()) {
            if (b < 48u8 || b > 57u8) { return 0 }
            acc = acc * 10 + Int64(b - 48u8)
        }
        return acc
    }

    /** 取文件名最后一段扩展名并转小写（字节处理，避免 toLowerCase/字符字面量差异）。 */
    private static func lowerExt(fileName: String): String {
        let b = fileName.toArray()
        var dot: Int64 = -1
        for (i in 0..b.size) {
            if (b[i] == 46u8) { dot = i }
        }
        if (dot < 0 || dot >= b.size - 1) { return "" }
        let len = b.size - dot - 1
        let out = Array<Byte>(len, repeat: 0u8)
        var j: Int64 = 0
        for (i in dot + 1..b.size) {
            var c = b[i]
            if (c >= 65u8 && c <= 90u8) { c = c + 32u8 }
            out[j] = c
            j = j + 1
        }
        return String.fromUtf8(out)
    }
}

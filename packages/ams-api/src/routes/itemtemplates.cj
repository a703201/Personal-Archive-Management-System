// ============================================================
// ams.api.routes.itemtemplates · 条目模板（FR-ARCH-012 · 方案 C）
//
// 路由：
//   GET    /api/item-templates            列出本人模板
//   POST   /api/item-templates            新建模板
//   PUT    /api/item-templates/:id        修改模板
//   DELETE /api/item-templates/:id        删除模板
//   POST   /api/item-templates/:id/apply  套用模板批量创建条目
//
// 模板 = 条目骨架（分类/标题/状态/敏感度/签发机关/备注）
//        + 扩展字段默认值（extra JSON）
//        + 有效期偏移（expires_offset_days）
//
// 套用规则：
//   · 标题含 `{n}` → 替换为序号 1..count；
//   · 不含占位且 count > 1 → 追加 ` (n)`，避免同名条目无法区分；
//   · count 限制 1..50：模板是「常用条目」不是「批量造数」入口，
//     再大就应走 CSV 导入（那边有预检与错误报告）。
//
// 权限：archive:write:own（模板产物就是条目，写入权限已覆盖风险面）
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.core.item.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.time.*

/**
 * 条目模板接口。
 */
public class ItemTemplateRoutes {
    private let templateRepo: ItemTemplateRepo
    private let itemRepo: ItemRepo
    private let userRepo: UserRepo

    /** 单次套用上限：防止把模板当批量造数工具 */
    private static let MAX_APPLY: Int64 = 50

    public init(templateRepo: ItemTemplateRepo, itemRepo: ItemRepo, userRepo: UserRepo) {
        this.templateRepo = templateRepo
        this.itemRepo = itemRepo
        this.userRepo = userRepo
    }

    public func register(router: Router): Unit {
        router.get("/api/item-templates", { req: ApiRequest => this.list(req) },
            requiredPerm: "archive:write:own")
        router.post("/api/item-templates", { req: ApiRequest => this.create(req) },
            requiredPerm: "archive:write:own")
        router.put("/api/item-templates/:id", { req: ApiRequest => this.update(req) },
            requiredPerm: "archive:write:own")
        router.delete("/api/item-templates/:id", { req: ApiRequest => this.remove(req) },
            requiredPerm: "archive:write:own")
        router.post("/api/item-templates/:id/apply", { req: ApiRequest => this.apply(req) },
            requiredPerm: "archive:write:own")
    }

    /**
     * GET /api/item-templates
     */
    private func list(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let rows = this.templateRepo.list(uid)
        let sb = StringBuilder()
        sb.append("{\"items\":[")
        var first = true
        for (r in rows.all().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append(ItemTemplateRoutes.json(r))
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * POST /api/item-templates
     */
    private func create(req: ApiRequest): ApiResponse {
        let json = ItemTemplateRoutes.body(req)
        let uid = UserRepo.parseId(req.subjectId)
        let name = ItemTemplateRoutes.strOf(json, "name", "").trimAscii()
        let title = ItemTemplateRoutes.strOf(json, "title", "").trimAscii()
        ItemTemplateRoutes.validate(name, title, json)
        let id = this.templateRepo.create(
            uid,
            name,
            ItemTemplateRoutes.intOf(json, "category", 1),
            title,
            ItemTemplateRoutes.intOf(json, "status", 0),
            ItemTemplateRoutes.intOf(json, "sensitivity", 1),
            ItemTemplateRoutes.strOf(json, "issuer", "").trimAscii(),
            ItemTemplateRoutes.strOf(json, "remark", "").trimAscii(),
            ItemTemplateRoutes.intOf(json, "expiresOffsetDays", 0),
            ItemTemplateRoutes.extraOf(json),
            uid
        )
        return ApiResponse.ok("{\"id\":\"${id}\"}", req.requestId)
    }

    /**
     * PUT /api/item-templates/:id
     */
    private func update(req: ApiRequest): ApiResponse {
        let json = ItemTemplateRoutes.body(req)
        let uid = UserRepo.parseId(req.subjectId)
        let id = ItemTemplateRoutes.idOf(req)
        let name = ItemTemplateRoutes.strOf(json, "name", "").trimAscii()
        let title = ItemTemplateRoutes.strOf(json, "title", "").trimAscii()
        ItemTemplateRoutes.validate(name, title, json)
        let ok = this.templateRepo.update(
            id,
            uid,
            name,
            ItemTemplateRoutes.intOf(json, "category", 1),
            title,
            ItemTemplateRoutes.intOf(json, "status", 0),
            ItemTemplateRoutes.intOf(json, "sensitivity", 1),
            ItemTemplateRoutes.strOf(json, "issuer", "").trimAscii(),
            ItemTemplateRoutes.strOf(json, "remark", "").trimAscii(),
            ItemTemplateRoutes.intOf(json, "expiresOffsetDays", 0),
            ItemTemplateRoutes.extraOf(json),
            uid
        )
        if (!ok) {
            throw notFound("模板")
        }
        return ApiResponse.ok("{\"updated\":true}", req.requestId)
    }

    /**
     * DELETE /api/item-templates/:id
     */
    private func remove(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let id = ItemTemplateRoutes.idOf(req)
        if (!this.templateRepo.delete(id, uid)) {
            throw notFound("模板")
        }
        return ApiResponse.ok("{\"deleted\":true}", req.requestId)
    }

    /**
     * POST /api/item-templates/:id/apply
     *
     * 入参：{"subjectId": 123, "count": 3}
     */
    private func apply(req: ApiRequest): ApiResponse {
        let json = ItemTemplateRoutes.body(req)
        let uid = UserRepo.parseId(req.subjectId)
        let id = ItemTemplateRoutes.idOf(req)
        let row = match (this.templateRepo.findById(id, uid)) {
            case Some(r) => r
            case None => throw notFound("模板")
        }
        let subjectId = ItemTemplateRoutes.intOf(json, "subjectId", 0)
        if (subjectId <= 0) {
            throw validationError("subjectId", "请指定目标主体")
        }
        if (!this.subjectAllowed(req, uid, subjectId)) {
            throw AppError(AppErrorKind.Forbidden, "主体不存在或无写入权限")
        }
        var count = ItemTemplateRoutes.intOf(json, "count", 1)
        if (count < 1) {
            count = 1
        }
        if (count > MAX_APPLY) {
            count = MAX_APPLY
        }

        let category = row.i64("category")
        let baseTitle = row.str("title")
        let status = row.i64("status")
        let sensitivity = row.i64("sensitivity")
        let issuer = row.str("issuer")
        let remark = row.str("remark")
        let offsetDays = row.i64("expires_offset_days")
        let extra = row.str("extra")
        let extraJson = if (extra.isEmpty()) { "{}" } else { extra }

        // 有效期偏移：以「套用当天 + N 天」为准，而不是模板里存绝对日期
        let expiresAt = TemplatePlan.expiryDate(Times.nowMillis(), offsetDays)

        let ids = StringBuilder()
        var created: Int64 = 0
        for (title in TemplatePlan.titles(baseTitle, count)) {
            let newId = this.itemRepo.create(
                subjectId, category, title, status, sensitivity,
                "", expiresAt, issuer, remark, extraJson, uid,
                source: 0
            )
            if (created > 0) {
                ids.append(",")
            }
            ids.append("\"${newId}\"")
            created = created + 1
        }
        return ApiResponse.ok(
            "{\"created\":${created},\"ids\":[${ids.toString()}]}", req.requestId
        )
    }

    // ---- 辅助 ----

    private func subjectAllowed(req: ApiRequest, uid: Int64, subjectId: Int64): Bool {
        let scopeAny = req.perms.contains("archive:write:any")
        let ids = if (scopeAny) {
            this.userRepo.listAccessibleSubjectIds(uid)
        } else {
            this.userRepo.listOwnedSubjectIds(uid)
        }
        let want = "${subjectId}"
        for (s in ids) {
            if (s == want) {
                return true
            }
        }
        return false
    }

    private static func validate(name: String, title: String, json: SimpleJson): Unit {
        if (name.isEmpty()) {
            throw validationError("name", "模板名称不能为空")
        }
        if (name.toArray().size > 100) {
            throw validationError("name", "模板名称超过 100 字节")
        }
        if (title.isEmpty()) {
            throw validationError("title", "标题模板不能为空")
        }
        if (title.toArray().size > 200) {
            throw validationError("title", "标题模板超过 200 字节")
        }
        let category = ItemTemplateRoutes.intOf(json, "category", 1)
        if (category < 1 || category > 11) {
            throw validationError("category", "分类必须是 1-11 的数字")
        }
        let status = ItemTemplateRoutes.intOf(json, "status", 0)
        if (status < 0 || status > 9) {
            throw validationError("status", "状态必须是 0-9")
        }
        let sens = ItemTemplateRoutes.intOf(json, "sensitivity", 1)
        if (sens < 1 || sens > 3) {
            throw validationError("sensitivity", "敏感度必须是 1-3")
        }
        let offset = ItemTemplateRoutes.intOf(json, "expiresOffsetDays", 0)
        if (offset < 0 || offset > TemplatePlan.MAX_OFFSET_DAYS) {
            throw validationError(
                "expiresOffsetDays",
                "有效期偏移必须是 0-${TemplatePlan.MAX_OFFSET_DAYS} 天"
            )
        }
    }

    /**
     * 扩展字段默认值：必须是 JSON 对象文本。
     *
     * 传给 `?::jsonb` 的若不是合法 JSON，数据库会抛类型错误；
     * 这里先做「首尾括号」这一最低成本的守门。
     */
    private static func extraOf(json: SimpleJson): String {
        let raw = ItemTemplateRoutes.strOf(json, "extra", "").trimAscii()
        if (raw.isEmpty()) {
            return "{}"
        }
        if (raw.startsWith("{") && raw.endsWith("}")) {
            return raw
        }
        throw validationError("extra", "扩展字段默认值必须是 JSON 对象")
    }

    private static func json(r: RowData): String {
        let extra = r.str("extra")
        let extraJson = if (extra.isEmpty()) { "{}" } else { extra }
        let sb = StringBuilder()
        sb.append("{\"id\":\"${r.str("id")}\",")
        sb.append("\"name\":\"${ApiResponse.escape(r.str("name"))}\",")
        sb.append("\"category\":${r.i64("category")},")
        sb.append("\"title\":\"${ApiResponse.escape(r.str("title"))}\",")
        sb.append("\"status\":${r.i64("status")},")
        sb.append("\"sensitivity\":${r.i64("sensitivity")},")
        sb.append("\"issuer\":\"${ApiResponse.escape(r.str("issuer"))}\",")
        sb.append("\"remark\":\"${ApiResponse.escape(r.str("remark"))}\",")
        sb.append("\"expiresOffsetDays\":${r.i64("expires_offset_days")},")
        sb.append("\"extra\":${extraJson},")
        sb.append("\"updatedAt\":${r.i64("updated_ms")}}")
        return sb.toString()
    }

    private static func body(req: ApiRequest): SimpleJson {
        return match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
    }

    private static func idOf(req: ApiRequest): Int64 {
        let raw = req.pathParam("id") ?? ""
        let id = RowData.toI64(raw)
        if (id <= 0) {
            throw validationError("id", "缺少合法的模板 ID")
        }
        return id
    }

    private static func strOf(j: SimpleJson, key: String, def: String): String {
        return match (j.get(key)) {
            case Some(v) => v
            case None => def
        }
    }

    private static func intOf(j: SimpleJson, key: String, def: Int64): Int64 {
        return match (j.get(key)) {
            case Some(v) => if (v.isEmpty()) { def } else { RowData.toI64(v) }
            case None => def
        }
    }
}

// ============================================================
// ams.api.routes.fielddefs · 字段定义与扩展字段值接口
//
// 覆盖：
//   FR-ARCH-003 字段定义表 → GET/POST/PUT/DELETE /api/field-defs
//   FR-ARCH-004 扩展字段存储 → GET/PUT /api/items/:id/fields
//
// 【为什么不改 items.cj 的 create/update】
//   arc_item_fields 是「明细表」，主键为 (item_id, field_def_id)，
//   单独给一组端点更清晰，也避免动到已验证通过的条目主流程。
//   写入前必须**服务端**解析 field_key → field_def_id：
//   前端只传「键 + 值」，绝不接受前端指定 field_def_id，
//   否则可越权写入他人/他分类的字段定义（FR-ACL-006）。
//
// 【归属校验】
//   /api/items/:id/fields 走**带归属过滤**的 ItemRepo.findById，
//   不可访问即 404（不泄露资源存在性，FR-ACL-006）。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.app.search.*
import ams.core.search.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.log.*

/**
 * 字段定义接口（FR-ARCH-003）。
 */
public class FieldDefRoutes {
    private let fieldDefRepo: FieldDefRepo
    private let userRepo: UserRepo

    public init(fieldDefRepo: FieldDefRepo, userRepo: UserRepo) {
        this.fieldDefRepo = fieldDefRepo
        this.userRepo = userRepo
    }

    public func register(router: Router): Unit {
        router.get("/api/field-defs", { req: ApiRequest => this.listDefs(req) },
                   requiredPerm: "archive:read:own")
        router.post("/api/field-defs", { req: ApiRequest => this.createDef(req) },
                    requiredPerm: "archive:write:own")
        router.put("/api/field-defs/:id", { req: ApiRequest => this.updateDef(req) },
                   requiredPerm: "archive:write:own")
        router.delete("/api/field-defs/:id", { req: ApiRequest => this.deleteDef(req) },
                      requiredPerm: "archive:write:own")
    }

    // ---------------------------------------------------------

    /**
     * GET /api/field-defs?category=N
     *
     * 未带 category 时返回全部 11 个分类的模板 + 调用者自定义字段。
     */
    private func listDefs(req: ApiRequest): ApiResponse {
        let category = FieldDefRoutes.intOfQuery(req, "category", 0)
        let subjectId = UserRepo.parseId(req.subjectId)
        let cats = if (category > 0) {
            [category]
        } else {
            FieldDefRoutes.allCategories()
        }
        let sb = StringBuilder()
        sb.append("{\"fields\":[")
        var first = true
        for (c in cats) {
            for (fd in this.fieldDefRepo.listByCategory(c, subjectId)) {
                if (!first) {
                    sb.append(",")
                }
                first = false
                sb.append(FieldDefRoutes.toJson(fd))
            }
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * POST /api/field-defs —— 新建**用户自定义**字段（归属于调用者主体）。
     */
    private func createDef(req: ApiRequest): ApiResponse {
        let body = FieldDefRoutes.body(req)
        let category = FieldDefRoutes.intOf(body, "category", 0)
        if (category < 1 || category > 11) {
            throw validationError("category", "分类须在 1~11 之间")
        }
        let fieldKey = body.get("fieldKey") ?? ""
        if (fieldKey.isEmpty()) {
            throw validationError("fieldKey", "字段键不能为空")
        }
        let fieldName = body.get("fieldName") ?? ""
        if (fieldName.isEmpty()) {
            throw validationError("fieldName", "字段名不能为空")
        }
        let dataType = FieldDefRoutes.intOf(body, "dataType", 0)
        if (dataType < 1 || dataType > 11) {
            throw validationError("dataType", "数据类型须在 1~11 之间")
        }
        let sens = FieldDefRoutes.intOf(body, "sensitivity", 1)
        if (sens < 1 || sens > 3) {
            throw validationError("sensitivity", "敏感度须为 1(普通)/2(敏感)/3(高敏)")
        }

        let subjectId = UserRepo.parseId(req.subjectId)
        let operatorId = subjectId

        // 同主体 + 同分类下字段键不得重复（唯一索引也会拦，但这里提前返回 409）
        for (fd in this.fieldDefRepo.listByCategory(category, subjectId)) {
            if (fd.fieldKey == fieldKey) {
                throw conflict("该分类下字段键 ${fieldKey} 已存在")
            }
        }

        let id = this.fieldDefRepo.create(
            subjectId,
            category,
            fieldKey,
            fieldName,
            dataType,
            sens,
            FieldDefRoutes.boolOf(body, "isRequired"),
            FieldDefRoutes.boolOf(body, "isSearchable"),
            FieldDefRoutes.boolOf(body, "isFilterable"),
            FieldDefRoutes.boolOf(body, "isBidxCapable"),
            body.get("enumDictCode") ?? "",
            FieldDefRoutes.intOf(body, "displayOrder", 100),
            body.get("validationRule") ?? "",
            body.get("defaultValue") ?? "",
            false,
            operatorId
        )
        return ApiResponse.ok("{\"id\":${id}}", req.requestId)
    }

    /**
     * PUT /api/field-defs/:id —— 仅允许改自己创建的自定义字段。
     */
    private func updateDef(req: ApiRequest): ApiResponse {
        let idStr = req.pathParam("id") ?? ""
        let id = RowData.toI64(idStr)
        let rec = FieldDefRoutes.requireDef(this.fieldDefRepo, id)
        let subjectId = UserRepo.parseId(req.subjectId)
        if (rec.subjectId != subjectId) {
            throw notFound("字段定义")
        }
        let body = FieldDefRoutes.body(req)
        this.fieldDefRepo.update(
            id,
            body.get("fieldName") ?? rec.fieldName,
            FieldDefRoutes.intOf(body, "displayOrder", rec.displayOrder),
            body.get("validationRule") ?? rec.validationRule,
            body.get("defaultValue") ?? rec.defaultValue,
            FieldDefRoutes.boolOf(body, "isRequired"),
            subjectId
        )
        return ApiResponse.ok("{\"id\":${id}}", req.requestId)
    }

    /**
     * DELETE /api/field-defs/:id —— 软删除自己的自定义字段。
     */
    private func deleteDef(req: ApiRequest): ApiResponse {
        let idStr = req.pathParam("id") ?? ""
        let id = RowData.toI64(idStr)
        let rec = FieldDefRoutes.requireDef(this.fieldDefRepo, id)
        let subjectId = UserRepo.parseId(req.subjectId)
        if (rec.subjectId != subjectId) {
            throw notFound("字段定义")
        }
        this.fieldDefRepo.softDelete(id)
        return ApiResponse.ok("{\"id\":${id},\"deleted\":true}", req.requestId)
    }

    // ---------------------------------------------------------

    private static func requireDef(repo: FieldDefRepo, id: Int64): FieldDefRecord {
        match (repo.findById(id)) {
            case Some(r) => return r
            case None => throw notFound("字段定义")
        }
    }

    private static func allCategories(): Array<Int64> {
        return [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
    }

    private static func toJson(fd: FieldDefRecord): String {
        let sb = StringBuilder()
        sb.append("{\"id\":${fd.id},")
        sb.append("\"category\":${fd.category},")
        sb.append("\"fieldKey\":\"${ApiResponse.escape(fd.fieldKey)}\",")
        sb.append("\"fieldName\":\"${ApiResponse.escape(fd.fieldName)}\",")
        sb.append("\"dataType\":${fd.dataType},")
        sb.append("\"sensitivity\":${fd.sensitivity},")
        sb.append("\"isRequired\":${fd.isRequired},")
        sb.append("\"isSearchable\":${fd.isSearchable},")
        sb.append("\"isFilterable\":${fd.isFilterable},")
        sb.append("\"isBidxCapable\":${fd.isBidxCapable},")
        sb.append("\"enumDictCode\":\"${ApiResponse.escape(fd.enumDictCode)}\",")
        sb.append("\"displayOrder\":${fd.displayOrder},")
        sb.append("\"defaultValue\":\"${ApiResponse.escape(fd.defaultValue)}\",")
        sb.append("\"isSystem\":${fd.isSystem},")
        sb.append("\"isCustom\":${fd.subjectId != 0}}")
        return sb.toString()
    }

    // ---------------------------------------------------------
    // 通用取值辅助
    // ---------------------------------------------------------

    private static func body(req: ApiRequest): SimpleJson {
        match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => return j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
    }

    private static func intOfQuery(req: ApiRequest, key: String, default: Int64): Int64 {
        match (req.queryParam(key)) {
            case Some(v) =>
                if (v.isEmpty()) {
                    return default
                }
                return RowData.toI64(v)
            case None => return default
        }
    }

    private static func intOf(json: SimpleJson, key: String, default: Int64): Int64 {
        match (json.get(key)) {
            case Some(v) =>
                if (v.isEmpty()) {
                    return default
                }
                return RowData.toI64(v)
            case None => return default
        }
    }

    private static func boolOf(json: SimpleJson, key: String): Bool {
        match (json.get(key)) {
            case Some(v) => return v == "true" || v == "1"
            case None => return false
        }
    }
}

/**
 * 条目扩展字段值接口（FR-ARCH-004）。
 *
 * 请求/响应均以 **field_key 作为键**（前端不需要知道 field_def_id），
 * 由服务端把 key 解析成 (field_def_id, data_type) 后落明细表。
 */
public class ItemFieldRoutes {
    private let itemRepo: ItemRepo
    private let fieldDefRepo: FieldDefRepo
    private let itemFieldRepo: ItemFieldRepo
    private let userRepo: UserRepo
    private let searchService: ?SearchService
    private let blindIndexService: ?BlindIndexService

    public init(
        itemRepo: ItemRepo,
        fieldDefRepo: FieldDefRepo,
        itemFieldRepo: ItemFieldRepo,
        userRepo: UserRepo,
        searchService!: ?SearchService = None,
        blindIndexService!: ?BlindIndexService = None
    ) {
        this.itemRepo = itemRepo
        this.fieldDefRepo = fieldDefRepo
        this.itemFieldRepo = itemFieldRepo
        this.userRepo = userRepo
        this.searchService = searchService
        this.blindIndexService = blindIndexService
    }

    public func register(router: Router): Unit {
        router.get("/api/items/:id/fields", { req: ApiRequest => this.listValues(req) },
                   requiredPerm: "archive:read:own")
        router.put("/api/items/:id/fields", { req: ApiRequest => this.saveValues(req) },
                   requiredPerm: "archive:write:own")
    }

    // ---------------------------------------------------------

    /**
     * GET /api/items/:id/fields —— 读取明细字段值（含元信息，供表单渲染）。
     */
    private func listValues(req: ApiRequest): ApiResponse {
        let id = RowData.toI64(req.pathParam("id") ?? "")
        let rec = this.requireAccessible(req, id)
        let values = this.itemFieldRepo.listByItem(id)
        // FR-SRC-006：敏感字段默认掩码；仅持 archive:read_sensitive 才返回明文
        let canReveal = req.perms.contains("archive:read_sensitive")
        let sb = StringBuilder()
        sb.append("{\"itemId\":${rec.id},\"category\":${rec.category},\"fields\":[")
        var first = true
        for (v in values) {
            if (!first) {
                sb.append(",")
            }
            first = false
            let shown = if (canReveal) { v.value } else { this.maskField(v.fieldKey, v.value, v.sensitivity) }
            sb.append("{\"fieldDefId\":${v.fieldDefId},")
            sb.append("\"fieldKey\":\"${ApiResponse.escape(v.fieldKey)}\",")
            sb.append("\"fieldName\":\"${ApiResponse.escape(v.fieldName)}\",")
            sb.append("\"dataType\":${v.dataType},")
            sb.append("\"sensitivity\":${v.sensitivity},")
            sb.append("\"value\":\"${ApiResponse.escape(shown)}\"}")
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * 按字段键选择掩码器（FR-SRC-006）：
     *   id_number/id_card → 前4后2；phone/mobile → 前3后4；其余按敏感度首尾掩码。
     * sensitivity < 2 视为普通字段，不掩码。
     */
    private func maskField(fieldKey: String, value: String, sensitivity: Int64): String {
        if (sensitivity < 2 || value.isEmpty()) {
            return value
        }
        let k = fieldKey.toAsciiLower()
        if (k.contains("id") || k.contains("card")) {
            return Masker.maskIdCard(value)
        }
        if (k.contains("phone") || k.contains("mobile")) {
            return Masker.maskPhone(value)
        }
        return Masker.mask(value, sensitivity)
    }

    /**
     * PUT /api/items/:id/fields —— 覆盖写入明细字段值（幂等 upsert）。
     *
     * 请求体是**扁平对象**：{"school":"某某大学","major":"计算机"}
     * 键不在该分类可见字段定义内的，一律忽略（不允许凭空造字段）。
     */
    private func saveValues(req: ApiRequest): ApiResponse {
        let id = RowData.toI64(req.pathParam("id") ?? "")
        let rec = this.requireAccessible(req, id)
        let subjectId = UserRepo.parseId(req.subjectId)

        // SimpleJson 不暴露键集合，故这里按同样的规则再解一遍扁平对象。
        let pairs = ItemFieldRoutes.flatPairs(req.bodyText())
        if (pairs.size == 0) {
            throw validationError("body", "请求体为空或不是合法的 JSON 对象")
        }

        let defs = this.fieldDefRepo.listByCategory(rec.category, subjectId)
        var saved: Int64 = 0
        for (kv in pairs) {
            let key = kv.key
            let value = kv.value
            for (fd in defs) {
                if (fd.fieldKey == key) {
                    // 盲索引：由服务按字段键选规则算出（写入侧落 value_bidx，供精确检索）
                    let bidx = match (this.blindIndexService) {
                        case Some(s) => s.bidx(fd.fieldKey, value)
                        case None => None<Array<Byte>>
                    }
                    this.itemFieldRepo.save(id, fd.id, fd.dataType, value, bidx: bidx)
                    saved = saved + 1
                }
            }
        }
        // 扩展字段参与索引内容，保存后需重建（失败不影响写入结果）
        if (saved > 0) {
            this.reindex(UserRepo.parseId(rec.id))
        }
        return ApiResponse.ok("{\"itemId\":${rec.id},\"saved\":${saved}}", req.requestId)
    }

    /**
     * 重建检索索引（尽力而为，失败仅记日志）。
     */
    private func reindex(itemId: Int64): Unit {
        match (this.searchService) {
            case Some(svc) =>
                try {
                    svc.indexItem(itemId)
                } catch (e: Exception) {
                    Log.get().warn("search.index.failed", None, [
                        ("itemId", "${itemId}"),
                        ("reason", e.toString())
                    ])
                }
            case None => ()
        }
    }

    // ---------------------------------------------------------

    /**
     * 校验条目可访问（**带归属过滤**），不可见即 404。
     */
    private func requireAccessible(req: ApiRequest, id: Int64): ItemRecord {
        let uid = UserRepo.parseId(req.subjectId)
        let subjects = this.userRepo.listAccessibleSubjectIds(uid).toArray()
        match (this.itemRepo.findById(id, subjects)) {
            case Some(r) => return r
            case None => throw notFound("条目")
        }
    }

    /**
     * 解析扁平 JSON 对象为「键/值对」列表。
     *
     * 与 SimpleJson.parse 规则一致（逗号分割 + 去引号），
     * 但额外保留**键**以便遍历 —— SimpleJson 把 fields 藏在 HashMap 里且不暴露键集合，
     * 而扩展字段的键随模板动态变化，必须能枚举。
     */
    private static func flatPairs(text: String): ArrayList<FieldPair> {
        let out = ArrayList<FieldPair>()
        let t = text.trimStart().trimEnd()
        if (!t.startsWith("{") || !t.endsWith("}")) {
            return out
        }
        let inner = t[1..t.size - 1]
        if (inner.trimStart().trimEnd().isEmpty()) {
            return out
        }
        for (part in inner.split(",")) {
            let kv = part.split(":", 2)
            if (kv.size >= 2) {
                let k = SimpleJson.unquotePublic(kv[0].trimStart().trimEnd())
                let v = SimpleJson.unquotePublic(kv[1].trimStart().trimEnd())
                if (!k.isEmpty()) {
                    out.add(FieldPair(k, v))
                }
            }
        }
        return out
    }
}

/**
 * 扁平对象的键/值对。
 *
 * 为什么不直接复用 SimpleJson：它内部是 HashMap 且**没有暴露键集合**，
 * 而扩展字段的键是动态的（随模板变化），必须能遍历。
 * 这里按与 SimpleJson 完全相同的规则解析一遍（逗号分割 + 去引号），
 * 保持行为一致：值内含逗号的场景同样不受支持（SimpleJson 本身亦如此）。
 */
public class FieldPair {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        this.key = key
        this.value = value
    }
}

// ============================================================
// ams.api.routes.importtemplate · 导入模板接口（FR-IMP-005）
//
// 路由：
//   GET    /api/import-templates            列出本人的全部模板
//   POST   /api/import-templates            新建模板
//   PUT    /api/import-templates/:id        更新模板
//   DELETE /api/import-templates/:id        删除模板
//
// 权限：导入模板本质是「自己的导入偏好」，复用 archive:write:own 即可，
//       归属由仓储层 owner_id 强制隔离（非本人一律 404/409）。
//
// 【mapping / defaults 的存储】
//   两者都是 JSON 对象（mapping: {csvHeader: fieldKey}，defaults: {fieldKey: value}），
//   以原文落 JSONB。接口层用 extractJsonObject 从请求体里抽取原文子串，
//   不依赖 SimpleJson 暴露键集合（它不暴露）。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.data.repo.*
import ams.kernel.error.*

/**
 * 导入模板接口。
 */
public class ImportTemplateRoutes {
    private let repo: ImportTemplateRepo

    public init(repo: ImportTemplateRepo) {
        this.repo = repo
    }

    public func register(router: Router): Unit {
        router.get("/api/import-templates", { req: ApiRequest => this.list(req) },
                   requiredPerm: "archive:write:own")
        router.post("/api/import-templates", { req: ApiRequest => this.create(req) },
                    requiredPerm: "archive:write:own")
        router.put("/api/import-templates/:id", { req: ApiRequest => this.update(req) },
                   requiredPerm: "archive:write:own")
        router.delete("/api/import-templates/:id", { req: ApiRequest => this.delete(req) },
                      requiredPerm: "archive:write:own")
    }

    /** GET /api/import-templates —— 列出本人模板。 */
    private func list(req: ApiRequest): ApiResponse {
        let owner = UserRepo.parseId(req.subjectId)
        let rows = this.repo.listByOwner(owner)
        let sb = StringBuilder()
        sb.append("{\"templates\":[")
        var first = true
        for (r in rows) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("{\"id\":${r.id},\"name\":\"${ApiResponse.escape(r.name)}\",")
            // mapping / defaults 已是合法 JSON 对象，直接内联
            sb.append("\"mapping\":${r.mappingJson},\"defaults\":${r.defaultsJson},")
            sb.append("\"createdAt\":${r.createdAt},\"updatedAt\":${r.updatedAt}}")
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /** POST /api/import-templates —— 新建模板。 */
    private func create(req: ApiRequest): ApiResponse {
        let owner = UserRepo.parseId(req.subjectId)
        let body = req.bodyText()
        let cloneFrom = ImportTemplateRoutes.cloneFromOf(body)
        var name = ImportTemplateRoutes.nameOf(body)
        var mapping = ImportTemplateRoutes.extractJsonObject(body, "mapping")
        var defaults = ImportTemplateRoutes.extractJsonObject(body, "defaults")
        if (cloneFrom > 0) {
            // 复制：以本人既有模板为蓝本，mapping / defaults 取源模板，
            // 名称缺省为「原名 副本」。复制只限本人（findByIdAndOwner 带 owner 校验）。
            match (this.repo.findByIdAndOwner(cloneFrom, owner)) {
                case Some(t) =>
                    mapping = t.mappingJson
                    defaults = t.defaultsJson
                    if (name.isEmpty()) {
                        name = t.name + " 副本"
                    }
                case None => throw notFound("导入模板")
            }
        }
        if (name.isEmpty()) {
            throw validationError("name", "模板名称不能为空")
        }
        let id = this.repo.create(owner, name, mapping, defaults, owner)
        return ApiResponse.ok("{\"id\":${id}}", req.requestId)
    }

    /** PUT /api/import-templates/:id —— 更新（仅本人）。 */
    private func update(req: ApiRequest): ApiResponse {
        let owner = UserRepo.parseId(req.subjectId)
        let id = RowData.toI64(req.pathParam("id") ?? "")
        let rec = match (this.repo.findByIdAndOwner(id, owner)) {
            case Some(r) => r
            case None => throw notFound("导入模板")
        }
        let body = req.bodyText()
        let name = ImportTemplateRoutes.nameOf(body)
        if (name.isEmpty()) {
            throw validationError("name", "模板名称不能为空")
        }
        let mapping = ImportTemplateRoutes.extractJsonObject(body, "mapping")
        let defaults = ImportTemplateRoutes.extractJsonObject(body, "defaults")
        this.repo.update(id, owner, name, mapping, defaults, owner)
        return ApiResponse.ok("{\"id\":${id},\"updated\":true}", req.requestId)
    }

    /** DELETE /api/import-templates/:id —— 删除（仅本人）。 */
    private func delete(req: ApiRequest): ApiResponse {
        let owner = UserRepo.parseId(req.subjectId)
        let id = RowData.toI64(req.pathParam("id") ?? "")
        if (!this.repo.delete(id, owner)) {
            throw notFound("导入模板")
        }
        return ApiResponse.ok("{\"id\":${id},\"deleted\":true}", req.requestId)
    }

    // ---------------------------------------------------------
    // 解析辅助
    // ---------------------------------------------------------

    /** 取请求体里的 name 字段（字符串）。 */
    private static func nameOf(body: String): String {
        match (SimpleJson.parse(body)) {
            case Some(j) =>
                match (j.get("name")) {
                    case Some(v) => return v
                    case None => return ""
                }
            case None => return ""
        }
    }

    /** 取请求体里的 cloneFrom 字段（整数 id；缺省 / 非法为 0）。 */
    private static func cloneFromOf(body: String): Int64 {
        match (SimpleJson.parse(body)) {
            case Some(j) =>
                match (j.get("cloneFrom")) {
                    case Some(v) => return if (v.isEmpty()) { 0 } else { RowData.toI64(v) }
                    case None => return 0
                }
            case None => return 0
        }
    }

    /**
     * 抽取顶层对象的原文子串：定位 `"key"` 后首个 `{`，按括号配平切到对应 `}`。
     *
     * 与 SimpleJson 不暴露键集合的限制相配套：mapping / defaults 是动态对象，
     * 直接抽原文落库比强行拆成 HashMap 更稳妥（值里也能含引号/逗号）。
     */
    private static func extractJsonObject(text: String, key: String): String {
        let bytes = text.toArray()
        let kb = "\"${key}\"".toArray()
        var i: Int64 = 0
        while (i + kb.size <= bytes.size) {
            var matched = true
            for (k in 0..kb.size) {
                if (bytes[i + k] != kb[k]) {
                    matched = false
                    break
                }
            }
            if (matched) {
                var j = i + kb.size
                while (j < bytes.size && ImportTemplateRoutes.isWs(Int64(bytes[j]))) {
                    j = j + 1
                }
                if (j < bytes.size && Int64(bytes[j]) == 58) {  // ':'
                    j = j + 1
                    while (j < bytes.size && ImportTemplateRoutes.isWs(Int64(bytes[j]))) {
                        j = j + 1
                    }
                    if (j < bytes.size && Int64(bytes[j]) == 123) {  // '{'
                        let open = Int64(bytes[j])
                        let close = 125  // '}'
                        var depth: Int64 = 0
                        var k2 = j
                        while (k2 < bytes.size) {
                            let c = Int64(bytes[k2])
                            if (c == open) {
                                depth = depth + 1
                            } else if (c == close) {
                                depth = depth - 1
                                if (depth == 0) {
                                    return String.fromUtf8(bytes[j..k2 + 1])
                                }
                            }
                            k2 = k2 + 1
                        }
                    }
                }
            }
            i = i + 1
        }
        return "{}"
    }

    private static func isWs(c: Int64): Bool {
        return c == 32 || c == 9 || c == 13 || c == 10
    }
}

// ============================================================
// ams.api.routes.items · 档案条目接口
//
// 覆盖 FR-ARCH-001 ~ FR-ARCH-008：
//   GET    /api/items                 列表（按归属 + 分类 + 状态 + 关键字）
//   POST   /api/items                 创建
//   GET    /api/items/:id             详情
//   PUT    /api/items/:id             更新（带乐观锁）
//   POST   /api/items/:id/status      状态流转
//   DELETE /api/items/:id             软删除（进回收站）
//   GET    /api/items/recycle-bin     回收站列表
//   POST   /api/items/:id/restore     从回收站恢复
//
// 【资源级鉴权】
//   本模块的每条**涉及具体条目**的路由都挂了 guard，
//   由鉴权中间件执行对象级判定（FR-ACL-006/007/008/009）：
//     - 数据归属：条目必须属于调用者可访问的主体
//     - 敏感度分级：high 分类需显式授权
//     - 显式授权与有效期：临时授权在服务端判定是否仍有效
//   guard 返回的 AuthzResource 由**服务端查库**得到，
//   前端无法伪造归属（FR-ACL-006）。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.id.*
import ams.security.authz.*

/**
 * 条目接口。
 */
public class ItemRoutes {
    private let itemRepo: ItemRepo
    private let userRepo: UserRepo

    public init(itemRepo: ItemRepo, userRepo: UserRepo) {
        this.itemRepo = itemRepo
        this.userRepo = userRepo
    }

    /**
     * 注册路由。
     */
    public func register(router: Router): Unit {
        router.get("/api/items", { req: ApiRequest => this.listItems(req) },
                   requiredPerm: "archive:read:own")
        router.post("/api/items", { req: ApiRequest => this.createItem(req) },
                    requiredPerm: "archive:write:own")
        router.get("/api/items/recycle-bin", { req: ApiRequest => this.listRecycleBin(req) },
                   requiredPerm: "archive:read:own")
        router.get("/api/items/:id", { req: ApiRequest => this.getItem(req) },
                   requiredPerm: "archive:read:own",
                   guard: { req: ApiRequest => this.guardOf(req) })
        router.put("/api/items/:id", { req: ApiRequest => this.updateItem(req) },
                   requiredPerm: "archive:write:own",
                   guard: { req: ApiRequest => this.guardOf(req) })
        router.post("/api/items/:id/status", { req: ApiRequest => this.transitionItem(req) },
                    requiredPerm: "archive:write:own",
                    guard: { req: ApiRequest => this.guardOf(req) })
        router.delete("/api/items/:id", { req: ApiRequest => this.deleteItem(req) },
                     requiredPerm: "archive:delete:own",
                     guard: { req: ApiRequest => this.guardOf(req) })
        router.post("/api/items/:id/restore", { req: ApiRequest => this.restoreItem(req) },
                    requiredPerm: "archive:write:own",
                    guard: { req: ApiRequest => this.guardOf(req) })
    }

    // ---------------------------------------------------------------
    // 资源守卫
    // ---------------------------------------------------------------

    /**
     * 解析本请求涉及的条目，构造资源描述供鉴权中间件判定。
     *
     * 查不到条目时返回 None —— 此时只做功能权限判定，
     * 由业务处理器返回 404（不泄露资源存在性）。
     */
    private func guardOf(req: ApiRequest): Option<AuthzResource> {
        let idStr = req.pathParam("id") ?? ""
        if (idStr.isEmpty()) {
            return None
        }
        let id = UserRepo.parseId(idStr)
        // ⚠️ 这里**必须**用不过滤归属的查询：
        //   归属与显式授权的判定由 Authorizer 负责（它同时看
        //   「可访问主体集合」与「acl_grants 显式授权」）。
        //   若这里先按归属过滤，被显式授权的用户会在这里就查不到 →
        //   guard 返回 None → 跳过判定 → 404，
        //   于是 FR-ACL-008（临时授权）端到端不通。
        let rec = this.itemRepo.findByIdRaw(id)
        match (rec) {
            case Some(r) => return Some(AuthzResource(
                r.subjectId,
                r.category,
                ItemRoutes.toSensitivity(r.sensitivity),
                itemId: r.id
            ))
            case None => return None
        }
    }

    /**
     * 调用者可访问的主体 ID 集合（服务端算出）。
     */
    private func accessibleSubjects(req: ApiRequest): Array<String> {
        let uid = UserRepo.parseId(req.subjectId)
        return this.userRepo.listAccessibleSubjectIds(uid).toArray()
    }

    // ---------------------------------------------------------------
    // 处理器
    // ---------------------------------------------------------------

    /**
     * 列表。
     */
    private func listItems(req: ApiRequest): ApiResponse {
        let category = ItemRoutes.intOfQuery(req, "category", 0)
        let status = ItemRoutes.intOfQuery(req, "status", -1)
        let keyword = match (req.queryParam("keyword")) {
            case Some(v) => v
            case None => ""
        }
        let page = ItemRoutes.intOfQuery(req, "page", 1)
        let size = ItemRoutes.intOfQuery(req, "size", 20)
        if (size < 1 || size > 200) {
            throw validationError("size", "每页条数须在 1~200 之间")
        }
        let subjects = this.accessibleSubjects(req)
        let rows = this.itemRepo.list(subjects, category, status, keyword, size, (page - 1) * size)
        let total = this.itemRepo.count(subjects, category, status, keyword)
        let sb = StringBuilder()
        sb.append("{\"items\":[")
        var first = true
        for (r in rows.all().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append(ItemRoutes.toJson(r))
        }
        sb.append("],\"total\":${total},\"page\":${page},\"size\":${size}}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * 详情。
     */
    private func getItem(req: ApiRequest): ApiResponse {
        let idStr = req.pathParam("id") ?? ""
        let rec = this.itemRepo.findByIdRaw(UserRepo.parseId(idStr))
        match (rec) {
            case Some(r) =>
                let sb = StringBuilder()
                sb.append("{\"item\":")
                sb.append(ItemRoutes.toJsonOf(r))
                sb.append("}")
                return ApiResponse.ok(sb.toString(), req.requestId)
            case None => throw notFound("条目")
        }
    }

    /**
     * 创建。
     */
    private func createItem(req: ApiRequest): ApiResponse {
        let json = ItemRoutes.body(req)
        let title = json.get("title") ?? ""
        if (title.isEmpty()) {
            throw validationError("title", "标题不能为空")
        }
        let subjectIdStr = json.get("subjectId") ?? ""
        if (subjectIdStr.isEmpty()) {
            throw validationError("subjectId", "所属主体不能为空")
        }
        // 归属校验：创建时也要确认调用者可访问该主体
        let subjects = this.accessibleSubjects(req)
        var allowed = false
        for (s in subjects) {
            if (s == subjectIdStr) {
                allowed = true
            }
        }
        if (!allowed) {
            throw AppError(AppErrorKind.Forbidden, "无权限在该主体下创建条目")
        }
        let category = ItemRoutes.intOf(json, "category", 0)
        let sensitivity = ItemRoutes.intOf(json, "sensitivity", 1)
        let id = this.itemRepo.create(
            UserRepo.parseId(subjectIdStr),
            category,
            title,
            ItemRoutes.intOf(json, "status", 0),
            sensitivity,
            json.get("issuedDate") ?? "",
            json.get("expiresAt") ?? "",
            json.get("issuer") ?? "",
            json.get("remark") ?? "",
            json.get("extra") ?? "{}",
            UserRepo.parseId(req.subjectId)
        )
        return ApiResponse.ok("{\"id\":\"${id}\"}", req.requestId)
    }

    /**
     * 更新（带乐观锁）。
     */
    private func updateItem(req: ApiRequest): ApiResponse {
        let idStr = req.pathParam("id") ?? ""
        let id = UserRepo.parseId(idStr)
        let json = ItemRoutes.body(req)
        let expected = ItemRoutes.intOf(json, "version", -1)
        if (expected < 0) {
            throw validationError("version", "缺少版本号（乐观锁必填）")
        }
        let rec = this.itemRepo.findByIdRaw(id)
        match (rec) {
            case Some(r) => return this.doUpdate(req, id, expected, r, json)
            case None => throw notFound("条目")
        }
    }

    /**
     * 执行更新（乐观锁）。
     *
     * 独立成方法的原因：仓颉的 match 分支**必须是单个表达式**，
     * 不能写 { 多行语句 }（会被当作 lambda 体）。
     */
    private func doUpdate(
        req: ApiRequest,
        id: Int64,
        expected: Int64,
        r: ItemRecord,
        json: SimpleJson
    ): ApiResponse {
        let ok = this.itemRepo.update(
            id,
            expected,
            UserRepo.parseId(r.subjectId),
            json.get("title") ?? r.title,
            ItemRoutes.intOf(json, "sensitivity", r.sensitivity),
            json.get("issuedDate") ?? r.issuedDate,
            json.get("expiresAt") ?? r.expiresAt,
            json.get("issuer") ?? r.issuer,
            json.get("remark") ?? r.remark,
            json.get("extra") ?? r.extraJson,
            UserRepo.parseId(req.subjectId)
        )
        if (!ok) {
            // 乐观锁失败 → 409 冲突（FR-ARCH-007），并说明当前版本
            throw ItemRoutes.conflict(r.version)
        }
        return ApiResponse.ok("{\"updated\":true}", req.requestId)
    }

    /**
     * 状态流转。
     */
    private func transitionItem(req: ApiRequest): ApiResponse {
        let idStr = req.pathParam("id") ?? ""
        let id = UserRepo.parseId(idStr)
        let json = ItemRoutes.body(req)
        let to = ItemRoutes.intOf(json, "status", -1)
        if (to < 0) {
            throw validationError("status", "目标状态不能为空")
        }
        let expected = ItemRoutes.intOf(json, "version", -1)
        if (expected < 0) {
            throw validationError("version", "缺少版本号（乐观锁必填）")
        }
        let rec = this.itemRepo.findByIdRaw(id)
        match (rec) {
            case Some(r) => return this.doTransition(req, id, expected, to, r)
            case None => throw notFound("条目")
        }
    }

    /**
     * 执行状态流转（乐观锁）。
     */
    private func doTransition(
        req: ApiRequest,
        id: Int64,
        expected: Int64,
        to: Int64,
        r: ItemRecord
    ): ApiResponse {
        let ok = this.itemRepo.transition(
            id, expected, to, UserRepo.parseId(r.subjectId), UserRepo.parseId(req.subjectId))
        if (!ok) {
            throw ItemRoutes.conflict(r.version)
        }
        return ApiResponse.ok("{\"updated\":true}", req.requestId)
    }

    /**
     * 软删除。
     */
    private func deleteItem(req: ApiRequest): ApiResponse {
        let idStr = req.pathParam("id") ?? ""
        let id = UserRepo.parseId(idStr)
        let json = ItemRoutes.body(req)
        let expected = ItemRoutes.intOf(json, "version", -1)
        let rec = this.itemRepo.findByIdRaw(id)
        match (rec) {
            case Some(r) => return this.doDelete(req, id, expected, r)
            case None => throw notFound("条目")
        }
    }

    /**
     * 执行软删除（进回收站）。
     */
    private func doDelete(
        req: ApiRequest,
        id: Int64,
        expected: Int64,
        r: ItemRecord
    ): ApiResponse {
        let ok = this.itemRepo.softDelete(
            id, expected, UserRepo.parseId(r.subjectId), UserRepo.parseId(req.subjectId))
        if (!ok) {
            throw ItemRoutes.conflict(r.version)
        }
        return ApiResponse.ok("{\"deleted\":true}", req.requestId)
    }

    /**
     * 回收站列表。
     */
    private func listRecycleBin(req: ApiRequest): ApiResponse {
        let rows = this.itemRepo.listRecycleBin(this.accessibleSubjects(req))
        let sb = StringBuilder()
        sb.append("{\"items\":[")
        var first = true
        for (r in rows.all().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append(ItemRoutes.toJson(r))
        }
        sb.append("],\"total\":${rows.size()}}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * 恢复。
     */
    private func restoreItem(req: ApiRequest): ApiResponse {
        let idStr = req.pathParam("id") ?? ""
        let id = UserRepo.parseId(idStr)
        // 恢复的归属以**条目自身**的 subject_id 为准
        // （已删除的条目不在 findById 结果里，故用 restore 内部的条件表达）
        let ok = this.itemRepo.restoreAny(
            id,
            this.accessibleSubjects(req),
            UserRepo.parseId(req.subjectId)
        )
        if (!ok) {
            throw notFound("条目")
        }
        return ApiResponse.ok("{\"restored\":true}", req.requestId)
    }

    // ---------------------------------------------------------------
    // 工具
    // ---------------------------------------------------------------

    /**
     * 敏感度码 → 枚举。
     */
    private static func toSensitivity(code: Int64): Sensitivity {
        if (code >= 3) {
            return Sensitivity.High
        }
        if (code == 2) {
            return Sensitivity.Sensitive
        }
        return Sensitivity.Normal
    }

    /**
     * 条目记录 → JSON（详情接口用）。
     */
    private static func toJsonOf(r: ItemRecord): String {
        let sb = StringBuilder()
        sb.append("{\"id\":\"${r.id}\",")
        sb.append("\"subjectId\":\"${r.subjectId}\",")
        sb.append("\"category\":${r.category},")
        sb.append("\"title\":\"${ItemRoutes.escape(r.title)}\",")
        sb.append("\"status\":${r.status},")
        sb.append("\"sensitivity\":${r.sensitivity},")
        sb.append("\"issuedDate\":\"${ItemRoutes.escape(r.issuedDate)}\",")
        sb.append("\"expiresAt\":\"${ItemRoutes.escape(r.expiresAt)}\",")
        sb.append("\"issuer\":\"${ItemRoutes.escape(r.issuer)}\",")
        sb.append("\"remark\":\"${ItemRoutes.escape(r.remark)}\",")
        sb.append("\"version\":${r.version},")
        sb.append("\"createdAt\":${r.createdAt},")
        sb.append("\"updatedAt\":${r.updatedAt}}")
        return sb.toString()
    }

    /**
     * 行记录 → JSON（列表接口用）。
     */
    private static func toJson(r: RowData): String {
        let sb = StringBuilder()
        sb.append("{\"id\":\"${r.i64("id")}\",")
        sb.append("\"subjectId\":\"${r.i64("subject_id")}\",")
        sb.append("\"category\":${r.i64("category")},")
        sb.append("\"title\":\"${ItemRoutes.escape(r.str("title"))}\",")
        sb.append("\"status\":${r.i64("status")},")
        sb.append("\"sensitivity\":${r.i64("sensitivity")},")
        sb.append("\"issuer\":\"${ItemRoutes.escape(r.getOpt("issuer") ?? "")}\",")
        sb.append("\"remark\":\"${ItemRoutes.escape(r.getOpt("remark") ?? "")}\",")
        sb.append("\"version\":${r.i64("version")},")
        sb.append("\"createdAt\":${r.i64("created_ms")},")
        sb.append("\"updatedAt\":${r.i64("updated_ms")}}")
        return sb.toString()
    }

    /**
     * JSON 字符串转义。
     */
    private static func escape(s: String): String {
        return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n")
    }

    /**
     * 取整数参数。
     */
    private static func intOf(src: Map<String, String>, key: String, def: Int64): Int64 {
        match (src.get(key)) {
            case Some(v) =>
                if (v.isEmpty()) {
                    return def
                }
                return RowData.toI64(v)
            case None => return def
        }
    }

    /**
     * 取整数参数（JSON）。
     */
    private static func intOf(src: SimpleJson, key: String, def: Int64): Int64 {
        match (src.get(key)) {
            case Some(v) => return RowData.toI64(v)
            case None => return def
        }
    }

    /**
     * 取查询串中的整数参数。
     */
    private static func intOfQuery(req: ApiRequest, key: String, def: Int64): Int64 {
        match (req.queryParam(key)) {
            case Some(v) =>
                if (v.isEmpty()) {
                    return def
                }
                return RowData.toI64(v)
            case None => return def
        }
    }

    /**
     * 乐观锁冲突（409）。
     */
    private static func conflict(currentVersion: Int64): AppError {
        return AppError(
            AppErrorKind.Conflict,
            "您基于旧版本，当前版本为 ${currentVersion}，请刷新后重试"
        )
    }

    /**
     * 解析请求体。
     */
    private static func body(req: ApiRequest): SimpleJson {
        return match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
    }
}

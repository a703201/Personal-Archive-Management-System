// ============================================================
// ams.api.routes.subjects · 档案主体接口
//
// 为什么需要这个模块（里程碑缺口）：
//   arc_items.subject_id 是「归属强制」的锚点（FR-ACL-006），
//   ItemRoutes.createItem 会校验 subjectId 属于调用者的可访问主体集合。
//   但此前**没有任何创建主体的入口** —— arc_subjects 恒为空，
//   于是所有用户都卡在 403「无权限在该主体下创建条目」，
//   即「登录后无法添加档案」的根因。
//
//   GET  /api/subjects      列表（首次访问自动补建「本人」主体）
//   POST /api/subjects      新建
//   PUT  /api/subjects/:id  更新（乐观锁）
//   DELETE /api/subjects/:id 软删除
//
// 【自愈设计】
//   GET 会调用 ensureDefault()：若调用者名下无任何主体，
//   立即建一个 relation=0、is_primary=true 的「本人」主体。
//   存量账号（含 tester）无需任何数据迁移即可开始建档。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.app.subject.*
import ams.data.repo.*
import ams.kernel.error.*

/**
 * 档案主体接口。
 */
public class SubjectRoutes {
    private let service: SubjectService
    private let userRepo: UserRepo

    public init(service: SubjectService, userRepo: UserRepo) {
        this.service = service
        this.userRepo = userRepo
    }

    public func register(router: Router): Unit {
        router.get("/api/subjects", { req: ApiRequest => this.list(req) },
                   requiredPerm: "subject:read:own")
        router.post("/api/subjects", { req: ApiRequest => this.create(req) },
                    requiredPerm: "subject:write:own")
        router.put("/api/subjects/:id", { req: ApiRequest => this.update(req) },
                   requiredPerm: "subject:write:own")
        router.delete("/api/subjects/:id", { req: ApiRequest => this.remove(req) },
                      requiredPerm: "subject:write:own")
    }

    // ---------------------------------------------------------------

    /**
     * GET /api/subjects —— 可读主体列表。
     */
    private func list(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        if (uid <= 0) {
            throw AppError(AppErrorKind.Unauthorized, "登录状态无效")
        }
        // 懒建「本人」主体：让新注册用户与存量账号都能立刻开始建档
        this.service.ensureDefault(uid, this.displayNameOf(uid))

        let items = this.service.list(uid)
        let sb = StringBuilder()
        sb.append("{\"subjects\":[")
        var first = true
        for (s in items.iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append(SubjectRoutes.toJson(s))
        }
        sb.append("],\"total\":${items.size}}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * POST /api/subjects —— 新建主体。
     *
     * 请求体：{"name","alias?","relation?","summary?"}
     */
    private func create(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let json = SubjectRoutes.body(req)
        let id = this.service.create(
            uid,
            json.get("name") ?? "",
            json.get("alias") ?? "",
            SubjectRoutes.intOf(json, "relation", 0),
            json.get("summary") ?? ""
        )
        return ApiResponse.ok("{\"id\":\"${id}\"}", req.requestId)
    }

    /**
     * PUT /api/subjects/:id —— 更新主体（乐观锁，version 必填）。
     */
    private func update(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let id = UserRepo.parseId(req.pathParam("id") ?? "")
        if (id <= 0) {
            throw validationError("id", "主体 ID 非法")
        }
        let json = SubjectRoutes.body(req)
        let expected = SubjectRoutes.intOf(json, "version", -1)
        if (expected < 0) {
            throw validationError("version", "缺少版本号（乐观锁必填）")
        }
        // 未传 name 时沿用原值：PATCH 语义更贴合「只改备注」的场景
        var name = json.get("name") ?? ""
        if (name.isEmpty()) {
            name = this.currentName(id, uid)
        }
        let ok = this.service.update(
            id,
            uid,
            expected,
            name,
            json.get("alias") ?? "",
            SubjectRoutes.intOf(json, "relation", 0),
            json.get("summary") ?? ""
        )
        if (!ok) {
            throw conflict("主体已被其他操作修改，请刷新后重试")
        }
        return ApiResponse.ok("{\"updated\":true}", req.requestId)
    }

    /**
     * DELETE /api/subjects/:id —— 软删除。
     *
     * 返回该主体下残留的条目数，前端可据此提示「条目仍可在回收站找回」。
     */
    private func remove(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let id = UserRepo.parseId(req.pathParam("id") ?? "")
        if (id <= 0) {
            throw validationError("id", "主体 ID 非法")
        }
        let n = this.service.itemCount(id)
        let ok = this.service.remove(id, uid)
        if (!ok) {
            throw notFound("主体")
        }
        return ApiResponse.ok("{\"deleted\":true,\"orphanItems\":${n}}", req.requestId)
    }

    // ---------------------------------------------------------------
    // 辅助
    // ---------------------------------------------------------------

    /**
     * 主体默认名：昵称优先，其次用户名。
     */
    private func displayNameOf(uid: Int64): String {
        match (this.userRepo.findById(uid)) {
            case Some(u) =>
                if (!u.nickname.isEmpty()) {
                    return u.nickname
                }
                return u.username
            case None => return ""
        }
    }

    /**
     * 取当前主体名（更新时未传 name 的兜底）。
     */
    private func currentName(id: Int64, uid: Int64): String {
        for (s in this.service.list(uid).iterator()) {
            if (s.id == "${id}") {
                return s.name
            }
        }
        throw notFound("主体")
    }

    /**
     * 解析请求体。
     */
    private static func body(req: ApiRequest): SimpleJson {
        match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => return j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
    }

    /**
     * 取整数参数（缺省或不可解析时用默认值）。
     */
    private static func intOf(json: SimpleJson, key: String, dflt: Int64): Int64 {
        match (json.get(key)) {
            case Some(v) =>
                if (v.isEmpty()) {
                    return dflt
                }
                return RowData.toI64(v)
            case None => return dflt
        }
    }

    /**
     * 主体 → JSON。
     *
     * 文件名密文永不出现在响应里；name 为已解密的明文。
     */
    private static func toJson(s: SubjectView): String {
        let sb = StringBuilder()
        sb.append("{\"id\":\"${s.id}\",")
        sb.append("\"name\":\"${ApiResponse.escape(s.name)}\",")
        sb.append("\"alias\":\"${ApiResponse.escape(s.alias)}\",")
        sb.append("\"relation\":${s.relation},")
        sb.append("\"isPrimary\":${s.isPrimary},")
        sb.append("\"status\":${s.status},")
        sb.append("\"completeness\":${s.completeness},")
        sb.append("\"summary\":\"${ApiResponse.escape(s.summary)}\",")
        sb.append("\"version\":${s.version},")
        sb.append("\"createdAt\":${s.createdMs},")
        sb.append("\"updatedAt\":${s.updatedMs}}")
        return sb.toString()
    }
}

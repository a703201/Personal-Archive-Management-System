// ============================================================
// ams.api.routes.tenantops · 租户运营接口（阶段 3 / docs/15 §4.2）
//
//   GET  /api/admin/tenants/:id/quota
//   PUT  /api/admin/tenants/:id/quota          {"maxUsers","maxItems","maxStorageMb"}
//   GET  /api/admin/tenants/:id/settings
//   PUT  /api/admin/tenants/:id/settings       {"key","value","isSecret"?}
//   GET  /api/admin/tenants/:id/audit-summary
//
// 全部要求 `acl:manage`（当前仅 org_admin 持有）。租户 ID 取自路径，
// **不与当前登录者的租户做强制相等校验** —— 组织管理员本来就需要
// 跨租户运营；越权面由权限码本身收口。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.data.repo.*
import ams.kernel.error.*

public class TenantOpsRoutes {
    private let repo: TenantOpsRepo

    public init(repo: TenantOpsRepo) {
        this.repo = repo
    }

    public func register(router: Router): Unit {
        router.get("/api/admin/tenants/:id/quota",
                   { req: ApiRequest => this.getQuota(req) }, requiredPerm: "acl:manage")
        router.put("/api/admin/tenants/:id/quota",
                   { req: ApiRequest => this.putQuota(req) }, requiredPerm: "acl:manage")
        router.get("/api/admin/tenants/:id/settings",
                   { req: ApiRequest => this.listSettings(req) }, requiredPerm: "acl:manage")
        router.put("/api/admin/tenants/:id/settings",
                   { req: ApiRequest => this.putSetting(req) }, requiredPerm: "acl:manage")
        router.get("/api/admin/tenants/:id/audit-summary",
                   { req: ApiRequest => this.auditSummary(req) }, requiredPerm: "acl:manage")
    }

    private static func tenantId(req: ApiRequest): Int64 {
        let raw = req.pathParam("id") ?? ""
        let id = RowData.toI64(raw)
        if (id <= 0) {
            throw validationError("id", "缺少合法的租户 ID")
        }
        return id
    }

    private static func body(req: ApiRequest): SimpleJson {
        return match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
    }

    private func getQuota(req: ApiRequest): ApiResponse {
        let tid = TenantOpsRoutes.tenantId(req)
        match (this.repo.getQuota(tid)) {
            case Some(q) =>
                return ApiResponse.ok(
                    "{\"tenantId\":${q.tenantId},\"maxUsers\":${q.maxUsers}," +
                    "\"maxItems\":${q.maxItems},\"maxStorageMb\":${q.maxStorageMb}}",
                    req.requestId)
            case None => throw notFound("租户配额")
        }
    }

    private func putQuota(req: ApiRequest): ApiResponse {
        let tid = TenantOpsRoutes.tenantId(req)
        let j = TenantOpsRoutes.body(req)
        let u = RowData.toI64(j.get("maxUsers") ?? "0")
        let it = RowData.toI64(j.get("maxItems") ?? "0")
        let s = RowData.toI64(j.get("maxStorageMb") ?? "0")
        let ok = this.repo.setQuota(tid, u, it, s)
        return ApiResponse.ok("{\"updated\":${ok}}", req.requestId)
    }

    private func listSettings(req: ApiRequest): ApiResponse {
        let tid = TenantOpsRoutes.tenantId(req)
        let rows = this.repo.listSettings(tid).all()
        let sb = StringBuilder()
        sb.append("{\"settings\":[")
        var i: Int64 = 0
        while (i < rows.size) {
            if (i > 0) { sb.append(",") }
            let r = rows[i]
            sb.append("{\"key\":\"${ApiResponse.escape(r.str("setting_key"))}\",")
            sb.append("\"value\":\"${ApiResponse.escape(r.str("value"))}\",")
            sb.append("\"isSecret\":${r.i64("is_secret")},")
            sb.append("\"updatedAt\":${r.i64("updated_ms")}}")
            i = i + 1
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    private func putSetting(req: ApiRequest): ApiResponse {
        let tid = TenantOpsRoutes.tenantId(req)
        let j = TenantOpsRoutes.body(req)
        let key = j.get("key") ?? ""
        let value = j.get("value") ?? ""
        // 机密标记：仅 INSERT 新建时生效（UPDATE 路径不改既有 is_secret）。
        // 缺省按 false 处理 —— 调用方不传 isSecret 时不应被误判为机密。
        let rawSecret = j.get("isSecret") ?? ""
        let isSecret = rawSecret == "true" || rawSecret == "1"
        let ok = this.repo.setSetting(tid, key, value, isSecret)
        return ApiResponse.ok(
            "{\"updated\":${ok},\"key\":\"${ApiResponse.escape(key)}\"," +
            "\"isSecret\":${isSecret}}", req.requestId)
    }

    private func auditSummary(req: ApiRequest): ApiResponse {
        let tid = TenantOpsRoutes.tenantId(req)
        let rows = this.repo.auditSummary(tid).all()
        let sb = StringBuilder()
        sb.append("{\"tenantId\":${tid},\"actions\":[")
        var i: Int64 = 0
        while (i < rows.size) {
            if (i > 0) { sb.append(",") }
            let r = rows[i]
            sb.append("{\"action\":\"${ApiResponse.escape(r.str("action"))}\",")
            sb.append("\"result\":${r.i64("result")},")
            sb.append("\"count\":${r.i64("event_count")},")
            sb.append("\"lastAt\":${r.i64("last_ms")}}")
            i = i + 1
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }
}

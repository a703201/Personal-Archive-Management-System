// ============================================================
// ams.api.routes.tenantregistry · 租户注册 / 首次引导接口
//
//   GET  /api/admin/tenants                          租户列表
//   POST /api/admin/tenants                         {"code","name"}
//   POST /api/admin/tenants/:id/bootstrap-admin     {"username","password"}
//
// 全部要求 `acl:manage`（当前仅 org_admin 持有），与 TenantOpsRoutes 同口径。
// 响应绝不回显口令 / 哈希 / 盐；引导只允许一次，重复调用返回 Conflict。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.crypto.provider.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.security.authn.*

public class TenantRegistryRoutes {
    private let registry: TenantRegistry
    private let hasher: PasswordHasher
    private let validator: PasswordValidator
    private let kdfCost: Int64

    public init(
        registry: TenantRegistry,
        hasher: PasswordHasher,
        validator: PasswordValidator,
        kdfCost: Int64
    ) {
        this.registry = registry
        this.hasher = hasher
        this.validator = validator
        this.kdfCost = kdfCost
    }

    public func register(router: Router): Unit {
        router.get("/api/admin/tenants",
                   { req: ApiRequest => this.list(req) }, requiredPerm: "acl:manage")
        router.post("/api/admin/tenants",
                    { req: ApiRequest => this.create(req) }, requiredPerm: "acl:manage")
        router.post("/api/admin/tenants/:id/bootstrap-admin",
                    { req: ApiRequest => this.bootstrap(req) }, requiredPerm: "acl:manage")
    }

    private static func body(req: ApiRequest): SimpleJson {
        return match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
    }

    private static func tenantId(req: ApiRequest): Int64 {
        let raw = req.pathParam("id") ?? ""
        let id = RowData.toI64(raw)
        if (id <= 0) {
            throw validationError("id", "缺少合法的租户 ID")
        }
        return id
    }

    private func list(req: ApiRequest): ApiResponse {
        let rows = this.registry.listTenants().all()
        let sb = StringBuilder()
        sb.append("{\"items\":[")
        var i: Int64 = 0
        while (i < rows.size) {
            if (i > 0) { sb.append(",") }
            let r = rows[i]
            sb.append("{\"id\":${r.i64("id")},")
            sb.append("\"code\":\"${ApiResponse.escape(r.str("code"))}\",")
            sb.append("\"name\":\"${ApiResponse.escape(r.str("name"))}\",")
            sb.append("\"status\":\"${ApiResponse.escape(r.str("status"))}\",")
            sb.append("\"createdAt\":${r.i64("created_ms")}}")
            i = i + 1
        }
        sb.append("],\"count\":${rows.size}}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    private func create(req: ApiRequest): ApiResponse {
        let j = TenantRegistryRoutes.body(req)
        let code = j.get("code") ?? ""
        let name = j.get("name") ?? ""
        let id = this.registry.createTenant(code, name)
        return ApiResponse.ok(
            "{\"tenantId\":${id},\"code\":\"${ApiResponse.escape(code)}\"," +
            "\"next\":\"POST /api/admin/tenants/${id}/bootstrap-admin\"}",
            req.requestId)
    }

    private func bootstrap(req: ApiRequest): ApiResponse {
        let tid = TenantRegistryRoutes.tenantId(req)
        let j = TenantRegistryRoutes.body(req)
        let username = j.get("username") ?? ""
        let password = j.get("password") ?? ""
        // 与注册主路径（FR-AUTH-004）同一套口令策略，不另立弱口径。
        match (this.validator.check(password, username)) {
            case PasswordCheck.Ok => ()
            case PasswordCheck.TooShort(min) =>
                throw validationError("password", "口令长度至少 ${min} 位")
            case PasswordCheck.TooFewCharClasses(n) =>
                throw validationError("password", "口令至少包含 ${n} 类字符（大小写/数字/符号）")
            case PasswordCheck.InWeakDictionary =>
                throw validationError("password", "口令过于常见，请更换")
            case PasswordCheck.ContainsUsername =>
                throw validationError("password", "口令不得包含用户名")
            case PasswordCheck.RepeatedChars =>
                throw validationError("password", "口令含过多重复字符")
        }
        let salt = match (this.hasher.generateSalt()) {
            case CryptoResult.Ok(s) => s
            case CryptoResult.Err(_) => throw AppError(AppErrorKind.CryptoFailure, "随机盐生成失败")
        }
        let hash = match (this.hasher.hash(password, salt)) {
            case CryptoResult.Ok(h) => h
            case CryptoResult.Err(_) => throw AppError(AppErrorKind.CryptoFailure, "口令哈希生成失败")
        }
        let uid = this.registry.bootstrapAdmin(tid, username, hash, this.kdfCost)
        return ApiResponse.ok(
            "{\"tenantId\":${tid},\"userId\":${uid}," +
            "\"username\":\"${ApiResponse.escape(username)}\",\"role\":\"org_admin\"}",
            req.requestId)
    }
}

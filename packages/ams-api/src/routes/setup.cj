// ============================================================
// ams.api.routes.setup · 首次部署初始化（公开接口）
// ------------------------------------------------------------
// 仅在「尚无管理员且 SETUP_INITIALIZED != true」时开放。
// 一旦创建管理员即写入 SETUP_INITIALIZED=true 永久关闭，
// 避免后续管理员被删除时向导重新开放造成越权创建。
//
// 顺序：状态 → 数据库（可测连接/可跳过）→ 邮件（可跳过）→ 管理员。
// 数据库配置写入 deployment.env 后需重启服务生效（见 README）。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.app.auth.*
import ams.data.db.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.storage.*

public class SetupRoutes {
    private let userRepo: UserRepo
    private let roleRepo: RoleRepo
    private let authService: AuthService
    private let store: DeploymentStore
    private let spool: MailSpool

    public init(
        userRepo: UserRepo,
        roleRepo: RoleRepo,
        authService: AuthService,
        store: DeploymentStore,
        spool!: MailSpool = MailSpool.disabled()
    ) {
        this.userRepo = userRepo
        this.roleRepo = roleRepo
        this.authService = authService
        this.store = store
        this.spool = spool
    }

    public func register(router: Router): Unit {
        router.get("/api/setup/status", { req: ApiRequest => this.status(req) }, isPublic: true)
        router.post("/api/setup/test-db", { req: ApiRequest => this.testDb(req) }, isPublic: true)
        router.post("/api/setup/database", { req: ApiRequest => this.saveDatabase(req) }, isPublic: true)
        router.post("/api/setup/mail", { req: ApiRequest => this.saveMail(req) }, isPublic: true)
        router.post("/api/setup/test-mail", { req: ApiRequest => this.testMail(req) }, isPublic: true)
        router.post("/api/setup/admin", { req: ApiRequest => this.createAdmin(req) }, isPublic: true)
    }

    private func body(req: ApiRequest): SimpleJson {
        return match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
    }

    private func hasAdmin(): Bool {
        for (a in this.userRepo.listAdmins().all().iterator()) {
            return true
        }
        return false
    }

    private func isInitialized(): Bool {
        let flag = this.store.get("SETUP_INITIALIZED") ?? "false"
        return flag == "true" || this.hasAdmin()
    }

    private func assertOpen(): Unit {
        if (this.isInitialized()) {
            throw AppError(AppErrorKind.Forbidden, "系统已完成初始化")
        }
    }

    /** GET /api/setup/status —— 前端路由守卫与向导首屏共用。 */
    private func status(req: ApiRequest): ApiResponse {
        let initialized = this.isInitialized()
        let db = this.dbSummary()
        let mail = this.mailSummary()
        return ApiResponse.ok(
            "{\"initialized\":${initialized},\"database\":${db},\"mail\":${mail}}",
            req.requestId)
    }

    private func dbSummary(): String {
        let h = this.store.resolve("DB_HOST", "AMS_DB_HOST", "127.0.0.1")
        let p = this.store.resolve("DB_PORT", "AMS_DB_PORT", "15432")
        let n = this.store.resolve("DB_NAME", "AMS_DB_NAME", "ams")
        let u = this.store.resolve("DB_USER", "AMS_DB_USER", "gaussdb")
        let configured = match (this.store.get("DB_HOST")) {
            case Some(_) => true
            case None => false
        }
        return "{\"host\":\"${DeploymentStore.escape(h)}\",\"port\":\"${DeploymentStore.escape(p)}\"," +
               "\"name\":\"${DeploymentStore.escape(n)}\",\"user\":\"${DeploymentStore.escape(u)}\"," +
               "\"password\":\"\",\"configured\":${configured}}"
    }

    private func mailSummary(): String {
        let enabled = this.store.resolve("MAIL_ENABLED", "AMS_MAIL_ENABLED", "false")
        let h = this.store.resolve("MAIL_HOST", "AMS_MAIL_HOST", "")
        let p = this.store.resolve("MAIL_PORT", "AMS_MAIL_PORT", "465")
        let u = this.store.resolve("MAIL_USER", "AMS_MAIL_USER", "")
        let f = this.store.resolve("MAIL_FROM", "AMS_MAIL_FROM", "")
        let s = this.store.resolve("MAIL_SECURE", "AMS_MAIL_SECURE", "ssl")
        return "{\"enabled\":${enabled == "true"},\"host\":\"${DeploymentStore.escape(h)}\"," +
               "\"port\":\"${DeploymentStore.escape(p)}\",\"user\":\"${DeploymentStore.escape(u)}\"," +
               "\"fromAddr\":\"${DeploymentStore.escape(f)}\",\"secure\":\"${DeploymentStore.escape(s)}\"," +
               "\"password\":\"\"}"
    }

    /** POST /api/setup/test-db —— 用传入参数建临时连接，验证连通性。 */
    private func testDb(req: ApiRequest): ApiResponse {
        this.assertOpen()
        let json = this.body(req)
        let cfg = SetupRoutes.dbConfigFrom(json, this.store)
        var ok = false
        var message = ""
        try {
            let probe = Database(cfg)
            ok = probe.ping()
            probe.close()
            if (!ok) { message = "数据库无响应" }
        } catch (e: Exception) {
            message = "连接失败：请检查地址、端口、账号与口令"
        }
        let msg = DeploymentStore.escape(message)
        return ApiResponse.ok("{\"ok\":${ok},\"message\":\"${msg}\"}", req.requestId)
    }

    /** POST /api/setup/database —— 写入 deployment.env；变更后需重启生效。 */
    private func saveDatabase(req: ApiRequest): ApiResponse {
        this.assertOpen()
        let json = this.body(req)
        let h = json.get("host") ?? ""
        let p = json.get("port") ?? ""
        let n = json.get("name") ?? ""
        let u = json.get("user") ?? ""
        let pass = json.get("password") ?? ""
        if (h.isEmpty() || p.isEmpty() || n.isEmpty() || u.isEmpty()) {
            throw validationError("database", "主机、端口、库名、用户名不能为空")
        }
        // 口令留空表示「沿用现有值」，不覆盖成空
        let updates = HashMap<String, String>()
        updates["DB_HOST"] = h
        updates["DB_PORT"] = p
        updates["DB_NAME"] = n
        updates["DB_USER"] = u
        if (!pass.isEmpty()) { updates["DB_PASSWORD"] = pass }
        this.store.setAll(updates)
        return ApiResponse.ok(
            "{\"saved\":true,\"needRestart\":true,\"message\":\"配置已保存，重启服务后生效\"}",
            req.requestId)
    }

    /** POST /api/setup/mail —— 邮件配置可跳过；跳过时什么都不写。 */
    private func saveMail(req: ApiRequest): ApiResponse {
        this.assertOpen()
        let json = this.body(req)
        let enabled = json.get("enabled") ?? "false"
        let updates = HashMap<String, String>()
        updates["MAIL_ENABLED"] = if (enabled == "true" || enabled == "1") { "true" } else { "false" }
        updates["MAIL_HOST"] = json.get("host") ?? ""
        updates["MAIL_PORT"] = json.get("port") ?? "465"
        updates["MAIL_USER"] = json.get("user") ?? ""
        updates["MAIL_FROM"] = json.get("fromAddr") ?? ""
        updates["MAIL_SECURE"] = json.get("secure") ?? "ssl"
        let pass = json.get("password") ?? ""
        if (!pass.isEmpty()) { updates["MAIL_PASSWORD"] = pass }
        this.store.setAll(updates)
        return ApiResponse.ok("{\"saved\":true}", req.requestId)
    }

    /** POST /api/setup/test-mail —— 立即投递一封测试信（需先保存邮件配置并重启）。 */
    private func testMail(req: ApiRequest): ApiResponse {
        this.assertOpen()
        let json = this.body(req)
        let to = json.get("to") ?? ""
        if (to.isEmpty()) { throw validationError("to", "请填写收件邮箱") }
        if (!this.spool.isEnabled()) {
            return ApiResponse.ok(
                "{\"ok\":false,\"message\":\"邮件服务未启用或未重启生效\"}", req.requestId)
        }
        this.spool.enqueue(to, "AMS 邮件服务测试", "这是一封来自 AMS 的测试邮件，用于验证 SMTP 配置。")
        return ApiResponse.ok("{\"ok\":true,\"message\":\"测试邮件已进入发送队列\"}", req.requestId)
    }

    /** POST /api/setup/admin —— 创建首个管理员并关闭向导。 */
    private func createAdmin(req: ApiRequest): ApiResponse {
        this.assertOpen()
        let json = this.body(req)
        let username = json.get("username") ?? ""
        let password = json.get("password") ?? ""
        let email = json.get("email") ?? ""
        let phone = json.get("phone") ?? ""
        let nickname = json.get("nickname") ?? ""
        if (username.isEmpty() || password.isEmpty()) {
            throw validationError("username", "账号名称与密码不能为空")
        }
        if (email.isEmpty() && phone.isEmpty()) {
            throw validationError("email", "请至少填写邮箱或手机号，便于找回口令")
        }
        let id = this.authService.register(username, password, email, phone, nickname)
        this.roleRepo.assignUserRole(id, "owner", 0, 0, 0)
        this.roleRepo.assignUserRole(id, "org_admin", 0, 0, 0)
        let done = HashMap<String, String>()
        done["SETUP_INITIALIZED"] = "true"
        this.store.setAll(done)
        return ApiResponse.ok("{\"id\":${id},\"initialized\":true}", req.requestId)
    }

    /** 从请求体或当前配置构造 DbConfig，供测试连接使用。 */
    public static func dbConfigFrom(json: SimpleJson, store: DeploymentStore): DbConfig {
        let h = json.get("host") ?? store.resolve("DB_HOST", "AMS_DB_HOST", "127.0.0.1")
        let p = json.get("port") ?? store.resolve("DB_PORT", "AMS_DB_PORT", "15432")
        let n = json.get("name") ?? store.resolve("DB_NAME", "AMS_DB_NAME", "ams")
        let u = json.get("user") ?? store.resolve("DB_USER", "AMS_DB_USER", "gaussdb")
        let pass = json.get("password") ?? store.resolve("DB_PASSWORD", "AMS_DB_PASSWORD", "")
        return DbConfig(h, SetupRoutes.toPort(p, 5432), n, u, pass, sslMode: "disable")
    }

    private static func toPort(raw: String, default: Int64): Int64 {
        if (raw.isEmpty()) { return default }
        var n: Int64 = 0
        for (b in raw.toArray().iterator()) {
            if (b < 48 || b > 57) { return default }
            n = n * 10 + Int64(b - 48)
        }
        if (n <= 0 || n > 65535) { return default }
        return n
    }
}

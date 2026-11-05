// ============================================================
// ams.api.routes.deployment · 部署配置管理接口（system:admin）
// ------------------------------------------------------------
// 与 SetupRoutes 的区别：
//   · SetupRoutes 公开、仅初始化前可用、一次性；
//   · 本接口需 system:admin，初始化后仍可反复修改数据库与邮件配置。
// 数据库配置写入 deployment.env 后重启服务生效；
// 邮件配置下一封信即读到新参数（spool 脚本按 .eml 头投递）。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.data.db.*
import ams.kernel.error.*
import ams.storage.*

public class DeploymentRoutes {
    private let store: DeploymentStore
    private let spool: MailSpool

    public init(store: DeploymentStore, spool: MailSpool) {
        this.store = store
        this.spool = spool
    }

    public func register(router: Router): Unit {
        router.get("/api/admin/deployment",
            { req: ApiRequest => this.read(req) }, requiredPerm: "system:admin")
        router.put("/api/admin/deployment/database",
            { req: ApiRequest => this.saveDatabase(req) }, requiredPerm: "system:admin")
        router.delete("/api/admin/deployment/database",
            { req: ApiRequest => this.resetDatabase(req) }, requiredPerm: "system:admin")
        router.put("/api/admin/deployment/mail",
            { req: ApiRequest => this.saveMail(req) }, requiredPerm: "system:admin")
        router.post("/api/admin/deployment/test-db",
            { req: ApiRequest => this.testDb(req) }, requiredPerm: "system:admin")
        router.post("/api/admin/deployment/test-mail",
            { req: ApiRequest => this.testMail(req) }, requiredPerm: "system:admin")
    }

    private func body(req: ApiRequest): SimpleJson {
        return match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
    }

    /** GET —— 返回脱敏后的全部部署配置，以及当前生效值。 */
    private func read(req: ApiRequest): ApiResponse {
        let h = this.store.resolve("DB_HOST", "AMS_DB_HOST", "127.0.0.1")
        let p = this.store.resolve("DB_PORT", "AMS_DB_PORT", "15432")
        let n = this.store.resolve("DB_NAME", "AMS_DB_NAME", "ams")
        let u = this.store.resolve("DB_USER", "AMS_DB_USER", "gaussdb")
        let db = "{\"host\":\"${DeploymentStore.escape(h)}\",\"port\":\"${DeploymentStore.escape(p)}\"," +
                 "\"name\":\"${DeploymentStore.escape(n)}\",\"user\":\"${DeploymentStore.escape(u)}\"," +
                 "\"password\":\"\"}"
        let me = this.store.resolve("MAIL_ENABLED", "AMS_MAIL_ENABLED", "false")
        let mh = this.store.resolve("MAIL_HOST", "AMS_MAIL_HOST", "")
        let mp = this.store.resolve("MAIL_PORT", "AMS_MAIL_PORT", "465")
        let mu = this.store.resolve("MAIL_USER", "AMS_MAIL_USER", "")
        let mf = this.store.resolve("MAIL_FROM", "AMS_MAIL_FROM", "")
        let ms = this.store.resolve("MAIL_SECURE", "AMS_MAIL_SECURE", "ssl")
        let mail = "{\"enabled\":${me == "true"},\"host\":\"${DeploymentStore.escape(mh)}\"," +
                   "\"port\":\"${DeploymentStore.escape(mp)}\",\"user\":\"${DeploymentStore.escape(mu)}\"," +
                   "\"fromAddr\":\"${DeploymentStore.escape(mf)}\",\"secure\":\"${DeploymentStore.escape(ms)}\"," +
                   "\"password\":\"\"}"
        return ApiResponse.ok(
            "{\"database\":${db},\"mail\":${mail},\"raw\":${this.store.redactedJson()}}",
            req.requestId)
    }

    private func saveDatabase(req: ApiRequest): ApiResponse {
        let json = this.body(req)
        let h = json.get("host") ?? ""
        let p = json.get("port") ?? ""
        let n = json.get("name") ?? ""
        let u = json.get("user") ?? ""
        let pass = json.get("password") ?? ""
        if (h.isEmpty() || p.isEmpty() || n.isEmpty() || u.isEmpty()) {
            throw validationError("database", "主机、端口、库名、用户名不能为空")
        }
        let updates = HashMap<String, String>()
        updates["DB_HOST"] = h
        updates["DB_PORT"] = p
        updates["DB_NAME"] = n
        updates["DB_USER"] = u
        if (!pass.isEmpty()) { updates["DB_PASSWORD"] = pass }
        this.store.setAll(updates)
        return ApiResponse.ok(
            "{\"saved\":true,\"needRestart\":true,\"message\":\"已保存，重启服务后生效\"}",
            req.requestId)
    }

    /** DELETE —— 清掉文件里的 DB_* 覆盖，恢复为环境变量/默认值。 */
    private func resetDatabase(req: ApiRequest): ApiResponse {
        this.store.clearAll([
            "DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD"
        ])
        return ApiResponse.ok(
            "{\"saved\":true,\"needRestart\":true,\"message\":\"已恢复为环境变量配置，重启服务后生效\"}",
            req.requestId)
    }

    private func saveMail(req: ApiRequest): ApiResponse {
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
        return ApiResponse.ok(
            "{\"saved\":true,\"needRestart\":true,\"message\":\"已保存，重启服务后邮件投递生效\"}",
            req.requestId)
    }

    private func testDb(req: ApiRequest): ApiResponse {
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
        return ApiResponse.ok(
            "{\"ok\":${ok},\"message\":\"${DeploymentStore.escape(message)}\"}", req.requestId)
    }

    private func testMail(req: ApiRequest): ApiResponse {
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
}

// ============================================================
// ams.api.routes.auth · 认证相关 HTTP 接口
//
// 需求：
//   FR-AUTH-002 登录       POST /api/auth/login
//   FR-AUTH-006 刷新令牌   POST /api/auth/refresh
//   FR-AUTH-003 登出       POST /api/auth/logout
//   FR-AUTH-003 全局登出   POST /api/auth/logout-all
//   健康检查               GET  /api/health
//
// [安全约束]
//   ① 登录接口**不写**请求体到日志（可能含口令）；
//   ② 失败统一返回「用户名或口令错误」，不区分用户是否存在；
//   ③ 登出需要有效令牌（走鉴权中间件）。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.app.auth.*
import ams.kernel.error.*
import ams.kernel.log.*

/**
 * 极简 JSON 解析。
 *
 * 只解析登录接口需要的扁平整���对象：
 *   {"username":"alice","password":"secret"}
 *
 * 说明：不引入完整 JSON 库（stdx.encoding.json 存在但对
 * 「只取几个顶层字符串字段」的场景过重）；
 * 如后续接口需要复杂 JSON，改为直接用 stdx.encoding.json。
 */
public class SimpleJson {
    private let fields: HashMap<String, String>

    public init() {
        this.fields = HashMap<String, String>()
    }

    /**
     * 取字符串字段。
     */
    public func get(key: String): Option<String> {
        return this.fields.get(key)
    }

    /**
     * 解析扁平整数字符串对象。
     *
     * 解析失败返回 None（调用方按缺字段处理）。
     */
    public static func parse(text: String): Option<SimpleJson> {
        let obj = SimpleJson()
        let t = text.trimStart().trimEnd()
        if (!t.startsWith("{") || !t.endsWith("}")) {
            return None
        }
        let inner = t[1..t.size - 1]
        if (inner.trimStart().trimEnd().isEmpty()) {
            return Some(obj)
        }
        for (part in inner.split(",")) {
            let kv = part.split(":", 2)
            if (kv.size < 2) {
                continue
            }
            let k = SimpleJson.unquote(kv[0].trimStart().trimEnd())
            let v = SimpleJson.unquote(kv[1].trimStart().trimEnd())
            if (!k.isEmpty()) {
                obj.fields[k] = v
            }
        }
        return Some(obj)
    }

    /**
     * 去掉外围引号并处理转义。
     */
    /**
     * 去掉外围引号（公开版本，供其它路由模块复用）。
     */
    public static func unquotePublic(s: String): String {
        return SimpleJson.unquote(s)
    }

    private static func unquote(s: String): String {
        if (s.size >= 2 && s.startsWith("\"") && s.endsWith("\"")) {
            let inner = s[1..s.size - 1]
            return inner.replace("\\\"", "\"").replace("\\\\", "\\")
        }
        return s
    }
}

/**
 * 认证接口处理器集合。
 */
public class AuthRoutes {
    private let authService: AuthService

    public init(authService: AuthService) {
        this.authService = authService
    }

    /**
     * 注册到路由表。
     */
    public func register(router: Router): Unit {
        router.post("/api/auth/login", { req: ApiRequest => this.login(req) }, isPublic: true)
        router.post("/api/auth/refresh", { req: ApiRequest => this.refresh(req) }, isPublic: true)
        router.post("/api/auth/logout", { req: ApiRequest => this.logout(req) })
        router.post("/api/auth/logout-all", { req: ApiRequest => this.logoutAll(req) })
    }

    /**
     * 健康检查（公开）。
     */
    public static func health(router: Router): Unit {
        router.get("/api/health", { req: ApiRequest =>
            ApiResponse.ok("{\"status\":\"ok\"}", req.requestId)
        }, isPublic: true)
    }

    /**
     * POST /api/auth/login
     */
    private func login(req: ApiRequest): ApiResponse {
        let body = req.bodyText()
        let json = match (SimpleJson.parse(body)) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        let username = json.get("username") ?? ""
        let password = json.get("password") ?? ""
        let ua = req.header("user-agent") ?? ""
        let result = this.authService.login(username, password, req.remoteAddr, ua)
        let data = "{\"accessToken\":\"${ApiResponse.escape(result.accessToken)}\"," +
            "\"refreshToken\":\"${ApiResponse.escape(result.refreshToken)}\"," +
            "\"sid\":\"${ApiResponse.escape(result.sid)}\"," +
            "\"expiresAt\":${result.expiresAt}}"
        return ApiResponse.ok(data, req.requestId)
    }

    /**
     * POST /api/auth/refresh
     */
    private func refresh(req: ApiRequest): ApiResponse {
        let body = req.bodyText()
        let json = match (SimpleJson.parse(body)) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        let refreshToken = json.get("refreshToken") ?? ""
        let ua = req.header("user-agent") ?? ""
        let result = this.authService.refresh(refreshToken, req.remoteAddr, ua)
        let data = "{\"accessToken\":\"${ApiResponse.escape(result.accessToken)}\"," +
            "\"refreshToken\":\"${ApiResponse.escape(result.refreshToken)}\"," +
            "\"expiresAt\":${result.expiresAt}}"
        return ApiResponse.ok(data, req.requestId)
    }

    /**
     * POST /api/auth/logout
     */
    private func logout(req: ApiRequest): ApiResponse {
        // 会话 ID 从令牌载荷取（鉴权中间件已校验令牌有效）
        let sid = req.sid
        if (sid.isEmpty()) {
            throw unauthorized(message: "缺少会话信息")
        }
        this.authService.logout(sid)
        return ApiResponse.ok("{\"loggedOut\":true}", req.requestId)
    }

    /**
     * POST /api/auth/logout-all
     */
    private func logoutAll(req: ApiRequest): ApiResponse {
        if (req.subjectId.isEmpty()) {
            throw unauthorized(message: "缺少用户信息")
        }
        let n = this.authService.logoutAll(req.subjectId)
        return ApiResponse.ok("{\"revokedSessions\":${n}}", req.requestId)
    }
}

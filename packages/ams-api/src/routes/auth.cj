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
 * 只解析登录接口需要的扁平对象：
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
     *
     * 【切分规则】只按**顶层**逗号切分（见 splitTopLevel）：
     *   引号内的 , 与 : 不参与切分，花括号 / 方括号内的逗号也不切分。
     *   此前用朴素 split(",")，导致昵称 / 备注 / 标题里出现半角逗号时
     *   该字段值被截断，并可能让后续字段错位。
     */
    public static func parse(text: String): Option<SimpleJson> {
        let t = text.trimStart().trimEnd()
        if (t.size < 2 || !t.startsWith("{") || !t.endsWith("}")) {
            return None
        }
        let obj = SimpleJson()
        for (part in SimpleJson.splitTopLevel(t).iterator()) {
            SimpleJson.putPair(obj, part)
        }
        return Some(obj)
    }

    /**
     * 按**顶层**逗号切分对象体（去掉外层花括号后的各段）。
     *
     * 「顶层」= 不在字符串字面量内、且不在嵌套 {} / [] 内。
     * 供需要保留键顺序的调用方复用（如扩展字段的扁平写入）。
     */
    public static func splitTopLevel(text: String): ArrayList<String> {
        let out = ArrayList<String>()
        let t = text.trimStart().trimEnd()
        if (t.size < 2 || !t.startsWith("{") || !t.endsWith("}")) {
            return out
        }
        let bytes = t.toArray()
        var i: Int64 = 1
        var start: Int64 = 1
        var inStr = false
        var escaped = false
        var depth: Int64 = 0
        while (i < bytes.size) {
            let b = bytes[i]
            if (inStr) {
                if (escaped) {
                    escaped = false
                } else if (b == 92) {
                    escaped = true
                } else if (b == 34) {
                    inStr = false
                }
            } else if (b == 34) {
                inStr = true
            } else if (b == 123 || b == 91) {
                depth = depth + 1
            } else if (b == 125 || b == 93) {
                if (depth > 0) {
                    depth = depth - 1
                }
            } else if (b == 44 && depth == 0) {
                out.add(String.fromUtf8(bytes[start..i]))
                start = i + 1
            }
            i = i + 1
        }
        // 末段：直到外层右花括号之前
        if (start < bytes.size - 1) {
            out.add(String.fromUtf8(bytes[start..bytes.size - 1]))
        }
        return out
    }

    /**
     * 解析一段 "key":value 并写入对象（键必为无逗号/冒号的标识符）。
     */
    private static func putPair(obj: SimpleJson, part: String): Unit {
        let p = part.trimStart().trimEnd()
        if (p.isEmpty()) {
            return
        }
        let kv = p.split(":", 2)
        if (kv.size < 2) {
            return
        }
        let k = SimpleJson.unquote(kv[0].trimStart().trimEnd())
        let v = SimpleJson.unquote(kv[1].trimStart().trimEnd())
        if (!k.isEmpty()) {
            obj.fields[k] = v
        }
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
        // 自助注册（FR-AUTH-001）：公开接口，不要求令牌；captcha 为 P1 暂未接入
        router.post("/api/auth/register", { req: ApiRequest => this.register(req) }, isPublic: true)
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

    /**
     * POST /api/auth/register（FR-AUTH-001）
     *
     * 请求体：{"username","password","email?","phone?","nickname?"}
     * 邮箱 / 手机号二选一；口令策略与唯一性校验由 AuthService 负责。
     */
    private func register(req: ApiRequest): ApiResponse {
        let body = req.bodyText()
        let json = match (SimpleJson.parse(body)) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        let username = json.get("username") ?? ""
        let password = json.get("password") ?? ""
        let email = json.get("email") ?? ""
        let phone = json.get("phone") ?? ""
        let nickname = json.get("nickname") ?? ""
        let id = this.authService.register(username, password, email, phone, nickname)
        return ApiResponse.ok("{\"id\":${id}}", req.requestId)
    }
}

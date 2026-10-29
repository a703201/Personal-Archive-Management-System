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
import ams.kernel.util.*

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
     * 遍历全部键值（顺序不保证）。
     *
     * 供「键名本身带信息」的场景使用：如附件批量导入用 `r.<目录名>` 表示
     * 该目录指定的目标条目，键是数据的一部分，无法用固定字段名取。
     */
    public func entries(): ArrayList<(String, String)> {
        let out = ArrayList<(String, String)>()
        for ((k, v) in this.fields) {
            out.add((k, v))
        }
        return out
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
        // trimSpace 而非 trimStart()/trimEnd()：后者在本 SDK 是空实现，
        // 请求体末尾带换行（如 `{...}\n`）时会因 endsWith("}") 失败而整包丢弃，
        // 表现为「用户名与口令不能为空」这类莫名其妙的校验错误。
        let t = trimSpace(text)
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
        let t = trimSpace(text)
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
        let p = trimSpace(part)
        if (p.isEmpty()) {
            return
        }
        // 自己找「字符串外的第一个冒号」，不用 split(":", 2)：
        //   split 的 limit 语义在不同 SDK 版本上不一致，实测标准 JSON 的
        //   `"csv": "a,b"`（冒号后带空格）会被切错，导致值被截断/丢失。
        //   扫描式定位只依赖「引号内不切分」这一条规则，行为可预测。
        let idx = SimpleJson.firstColon(p)
        if (idx < 0) {
            return
        }
        let k = SimpleJson.unquote(trimSpace(p[0..idx]))
        let v = SimpleJson.unquote(trimSpace(p[idx + 1..]))
        if (!k.isEmpty()) {
            obj.fields[k] = v
        }
    }

    /**
     * 返回字符串外的第一个 `:` 的**字节**下标；不存在返回 -1。
     */
    private static func firstColon(s: String): Int64 {
        let bytes = s.toArray()
        var inStr = false
        var escaped = false
        var i: Int64 = 0
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
            } else if (b == 58) {
                return i
            }
            i = i + 1
        }
        return -1
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

    private static func unquote(raw: String): String {
        // 先裁空白：调用方普遍传 ` "v"`（冒号后带空格）。本 SDK 的
        // String.trimStart()/trimEnd() 是空实现，若依赖调用方裁剪，
        // 引号判断会失败、值里残留空格与引号；故在此统一兜住。
        let s = trimSpace(raw)
        if (!(s.size >= 2 && s.startsWith("\"") && s.endsWith("\""))) {
            return s
        }
        let inner = s[1..s.size - 1]
        // 没有任何反斜杠 → 原样返回（绝大多数请求走这条路，避免无谓拷贝）
        if (!inner.contains("\\")) {
            return inner
        }
        let runes = ArrayList<Rune>()
        for (r in inner.runes()) {
            runes.add(r)
        }
        let sb = StringBuilder()
        var i: Int64 = 0
        while (i < runes.size) {
            let ch = runes[i].toString()
            if (ch == "\\" && i + 1 < runes.size) {
                let nx = runes[i + 1].toString()
                if (nx == "n") {
                    sb.append("\n")
                    i = i + 2
                } else if (nx == "r") {
                    sb.append("\r")
                    i = i + 2
                } else if (nx == "t") {
                    sb.append("\t")
                    i = i + 2
                } else if (nx == "b") {
                    sb.append("\u{0008}")
                    i = i + 2
                } else if (nx == "f") {
                    sb.append("\u{000C}")
                    i = i + 2
                } else if (nx == "\"") {
                    sb.append("\"")
                    i = i + 2
                } else if (nx == "\\") {
                    sb.append("\\")
                    i = i + 2
                } else if (nx == "/") {
                    sb.append("/")
                    i = i + 2
                } else if (nx == "u" && i + 5 < runes.size) {
                    // \uXXXX（BMP）；代理对按单个码位处理（本系统一律 UTF-8 直传，
                    // 该分支只用于兼容标准 JSON 客户端）
                    var cp: Int64 = 0
                    var k: Int64 = 0
                    while (k < 4) {
                        cp = cp * 16 + SimpleJson.hexOf(runes[i + 2 + k].toString())
                        k = k + 1
                    }
                    sb.append(Rune(UInt32(cp)).toString())
                    i = i + 6
                } else {
                    // 未知转义：保留反斜杠本身（宁可多一个字符，也不吞用户输入）
                    sb.append(ch)
                    i = i + 1
                }
            } else {
                sb.append(ch)
                i = i + 1
            }
        }
        return sb.toString()
    }

    /** 十六进制字符 → 数值（非法返回 0） */
    private static func hexOf(c: String): Int64 {
        if (c.size != 1) {
            return 0
        }
        let b = c.toArray()[0]
        if (b >= 48 && b <= 57) {
            return Int64(b) - 48
        }
        if (b >= 65 && b <= 70) {
            return Int64(b) - 55
        }
        if (b >= 97 && b <= 102) {
            return Int64(b) - 87
        }
        return 0
    }
}

/**
 * 认证接口处理器集合。
 */
public class AuthRoutes {
    private let authService: AuthService
    /**
     * 自助找回服务（FR-AUTH-008）。
     *
     * 可选：未装配时相关路由返回 501 语义的内部错误，
     * 不影响登录/刷新等主链路（便于裁剪部署与单测）。
     */
    private let resetService: ?PasswordResetService

    public init(authService: AuthService, resetService!: ?PasswordResetService = None) {
        this.authService = authService
        this.resetService = resetService
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
        // 自助找回口令（FR-AUTH-008）：三步链路，均公开
        router.post("/api/auth/password/forgot", { req: ApiRequest => this.forgotPassword(req) }, isPublic: true)
        router.post("/api/auth/password/verify", { req: ApiRequest => this.verifyResetCode(req) }, isPublic: true)
        router.post("/api/auth/password/reset", { req: ApiRequest => this.resetPassword(req) }, isPublic: true)
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
        // FR-AUTH-009：已启用双因子的账号必须带 totpCode
        let totpCode = json.get("totpCode") ?? ""
        let result = this.authService.login(username, password, req.remoteAddr, ua, totpCode: totpCode)
        let data = "{\"accessToken\":\"${ApiResponse.escape(result.accessToken)}\"," +
            "\"refreshToken\":\"${ApiResponse.escape(result.refreshToken)}\"," +
            "\"sid\":\"${ApiResponse.escape(result.sid)}\"," +
            "\"expiresAt\":${result.expiresAt}}"
        return ApiResponse.ok(data, req.requestId)
    }

    /**
     * POST /api/auth/password/forgot —— 索取重置验证码（FR-AUTH-008）。
     */
    private func forgotPassword(req: ApiRequest): ApiResponse {
        let json = match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        let svc = this.reset()
        let account = json.get("account") ?? ""
        let ua = req.header("user-agent") ?? ""
        let r = svc.request(account, req.remoteAddr, ua)
        let data = "{\"sent\":${if (r.sent) { "true" } else { "false" }}," +
            "\"channel\":\"${ApiResponse.escape(r.channel)}\"," +
            "\"masked\":\"${ApiResponse.escape(r.masked)}\"," +
            "\"expiresIn\":${r.expiresIn}," +
            "\"notice\":\"${ApiResponse.escape(r.notice)}\"}"
        return ApiResponse.ok(data, req.requestId)
    }

    /**
     * POST /api/auth/password/verify —— 校验验证码，换取一次性重置令牌。
     */
    private func verifyResetCode(req: ApiRequest): ApiResponse {
        let json = match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        let svc = this.reset()
        let account = json.get("account") ?? ""
        let code = json.get("code") ?? ""
        let ua = req.header("user-agent") ?? ""
        let ticket = svc.verify(account, code, req.remoteAddr, ua)
        let data = "{\"resetToken\":\"${ApiResponse.escape(ticket.token)}\"," +
            "\"expiresIn\":${ticket.expiresIn}}"
        return ApiResponse.ok(data, req.requestId)
    }

    /**
     * POST /api/auth/password/reset —— 凭令牌重置口令并强制下线全部会话。
     */
    private func resetPassword(req: ApiRequest): ApiResponse {
        let json = match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        let svc = this.reset()
        let token = json.get("resetToken") ?? ""
        let newPassword = json.get("newPassword") ?? ""
        let ua = req.header("user-agent") ?? ""
        let username = svc.reset(token, newPassword, req.remoteAddr, ua)
        return ApiResponse.ok(
            "{\"reset\":true,\"username\":\"${ApiResponse.escape(username)}\"}",
            req.requestId
        )
    }

    /**
     * 取查找回服务（未装配时给出明确的内部错误，而不是空指针崩溃）。
     */
    private func reset(): PasswordResetService {
        let svc = match (this.resetService) {
            case Some(s) => s
            case None => throw AppError(AppErrorKind.Internal, "自助找回功能未装配")
        }
        return svc
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

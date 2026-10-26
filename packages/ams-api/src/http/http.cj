// ============================================================
// ams.api.http · HTTP 基础类型（请求上下文 / 响应封装 / 路由表）
//
// 职责：
//   - 把 stdx.net.http 的 HttpContext 适配成 AMS 内部统一抽象
//   - 统一响应格式（RFC 7807 风格错误体 + 统一 data 包裹）
//   - 路径参数解析（/api/users/:id）
//
// [分层约束]（架构 §4.2）
//   ams-api 依赖 ams-kernel / ams-security / ams-app；
//   **不**直接依赖 ams-data（数据访问由 ams-app 编排）。
//
// [设计要点]
//   stdx.net.http 的 API（实测 1.2.0.1）：
//     ServerBuilder().addr(h).port(p).build()
//     server.distributor.register(path, { ctx: HttpContext => ... })
//     ctx.request.method / body / headers / url / remoteAddr
//     ctx.responseBuilder.status(..).header(..).body(..).build()
//   未注册路径由 distributor 内置返回 404。
// ============================================================
package ams.api.http

import std.collection.*
import std.io.*
import stdx.net.http.*

import ams.kernel.error.*
import ams.kernel.id.*
import ams.kernel.time.*

/**
 * 请求体最大读取字节数。
 *
 * 登录 / 注册等接口的请求体都在 KB 级，1 MiB 足够；
 * 大文件走附件上传接口（分片），不走 JSON 接口。
 */
public const MAX_BODY_BYTES: Int64 = 1048576

/**
 * 请求上下文（AMS 内部统一抽象）。
 *
 * 把 stdx 的 HttpContext 包一层，避免业务代码直接依赖 stdx 类型，
 * 也便于单元测试时构造假请求。
 */
public class ApiRequest {
    /** HTTP 方法（GET / POST / ...） */
    public let method: String
    /** 完整 URL */
    public let url: String
    /** 请求体（字节） */
    public let bodyBytes: Array<Byte>
    /** 请求头（键统一小写） */
    public let headers: HashMap<String, String>
    /** 客户端 IP */
    public let remoteAddr: String
    /** 路径参数（由路由表填充） */
    public var pathParams: HashMap<String, String> = HashMap<String, String>()
    /** 请求 ID（由中间件填充） */
    public var requestId: String = ""
    /** 认证主体（由鉴权中间件填充） */
    public var subjectId: String = ""
    /** 会话 ID（由鉴权中间件填充） */
    public var sid: String = ""
    /** 权限点集合（由鉴权中间件填充） */
    public var perms: ArrayList<String> = ArrayList<String>()
    /** 角色集合（由鉴权中间件填充） */
    public var roles: ArrayList<String> = ArrayList<String>()

    public init(
        method: String,
        url: String,
        bodyBytes: Array<Byte>,
        headers: HashMap<String, String>,
        remoteAddr: String
    ) {
        this.method = method.toAsciiUpper()
        this.url = url
        this.bodyBytes = bodyBytes
        this.headers = headers
        this.remoteAddr = remoteAddr
    }

    /**
     * 从 stdx 的 HttpContext 构造。
     */
    public static func fromContext(ctx: HttpContext): ApiRequest {
        let req = ctx.request
        let hs = HashMap<String, String>()
        // stdx 的 headers 是 HttpHeaders，实现键值遍历
        for ((k, vs) in req.headers) {
            // stdx 的 header 值是 Collection<String>（一个头可有多值），
            // 这里取第一个作为代表值。
            for (v in vs.iterator()) {
                hs.add(k.toAsciiLower(), v)
                break
            }
        }
        // req.body 是 InputStream（非 Option）；读空表示无请求体。
        // 一次读满缓冲区，够用（登录/注册等接口的请求体都很小）。
        let buf = Array<Byte>(MAX_BODY_BYTES, repeat: 0u8)
        var body = Array<Byte>()
        try {
            let n = req.body.read(buf)
            if (n > 0) {
                body = buf[0..n]
            }
        } catch (e: Exception) {
            body = Array<Byte>()
        }
        return ApiRequest(
            req.method,
            req.url.toString(),
            body,
            hs,
            req.remoteAddr.toString()
        )
    }

    /**
     * 取请求头（大小写不敏感）。
     */
    public func header(name: String): Option<String> {
        // 注意：仓颉 HashMap 的 `[]` 在键不存在时**抛 NoneValueException**，
        // 故这里必须用 get()。
        return this.headers.get(name.toAsciiLower())
    }

    /**
     * 取 Bearer 令牌。
     */
    public func bearerToken(): Option<String> {
        match (this.header("authorization")) {
            case Some(v) =>
                let lower = v.toAsciiLower()
                if (lower.startsWith("bearer ")) {
                    return Some(v[7..].trimStart())
                }
                return None
            case None => return None
        }
    }

    /**
     * 请求体文本。
     */
    public func bodyText(): String {
        return String.fromUtf8(this.bodyBytes)
    }

    /**
     * 取路径参数。
     */
    public func pathParam(name: String): Option<String> {
        // 同 header()：键不存在时用 get() 而非 []
        return this.pathParams.get(name)
    }

    /**
     * 从完整 URL 中取路径部分（去掉查询串与 fragment）。
     */
    public static func pathOf(url: String): String {
        let qi = ApiRequest.indexOf(url, "?")
        if (qi < 0) {
            return url
        }
        return url[0..qi]
    }

    /**
     * 查找子串首次出现的位置；未找到返回 -1。
     *
     * 说明：仓颉的 String.indexOf 返回 Option[Int64]，
     * 这里包一层便于在分支里直接比较。
     */
    public static func indexOf(s: String, sub: String): Int64 {
        match (s.indexOf(sub)) {
            case Some(i) => return i
            case None => return -1
        }
    }

    /**
     * 取查询参数（从 URL 的 ? 之后解析）。
     */
    public func queryParam(name: String): Option<String> {
        let qIdx = ApiRequest.indexOf(this.url, "?")
        if (qIdx < 0) {
            return None
        }
        let query = this.url[qIdx + 1..]
        for (pair in query.split("&")) {
            let kv = pair.split("=", 2)
            if (kv.size >= 2 && kv[0] == name) {
                return Some(kv[1])
            }
        }
        return None
    }
}

/**
 * 统一响应。
 *
 * 成功：{"code":"OK","message":"success","data":{...},"requestId":"..."}
 * 失败：{"code":"VALIDATION_FAILED","message":"...","details":{...},"requestId":"..."}
 */
public class ApiResponse {
    /** HTTP 状态码 */
    public let status: Int64
    /** 响应体（JSON 文本） */
    public let body: String
    /** 响应头 */
    public let headers: HashMap<String, String>

    public init(status: Int64, body: String, headers: HashMap<String, String>) {
        this.status = status
        this.body = body
        this.headers = headers
    }

    /**
     * 构造成功响应。
     */
    public static func ok(dataJson: String, requestId: String): ApiResponse {
        let body = "{\"code\":\"OK\",\"message\":\"success\",\"data\":${dataJson},\"requestId\":\"${requestId}\"}"
        return ApiResponse(200, body, jsonHeaders())
    }

    /**
     * 构造错误响应。
     */
    public static func error(
        kind: AppErrorKind,
        message: String,
        requestId: String,
        field!: String = ""
    ): ApiResponse {
        let code = kindToCode(kind)
        let status = kindToHttpStatus(kind)
        let sb = StringBuilder()
        sb.append("{\"code\":\"${code}\",\"message\":\"${ApiResponse.escape(message)}\"")
        if (!field.isEmpty()) {
            sb.append(",\"field\":\"${ApiResponse.escape(field)}\"")
        }
        sb.append(",\"requestId\":\"${requestId}\"}")
        return ApiResponse(status, sb.toString(), jsonHeaders())
    }

    /**
     * JSON 响应头。
     */
    private static func jsonHeaders(): HashMap<String, String> {
        let hs = HashMap<String, String>()
        hs["content-type"] = "application/json; charset=utf-8"
        return hs
    }

    /**
     * 单个半字节转小写十六进制字符。
     */
    private static func hexDigit(n: UInt8): String {
        if (n < 10) {
            return Rune(48 + n).toString()   // '0'..'9'
        }
        return Rune(87 + n).toString()       // 'a'..'f'
    }

    /**
     * JSON 字符串转义。
     *
     * 只处理必须转义的字符（引号、反斜杠、控制字符），
     * 其余（含中文）按 UTF-8 原样输出（符合 JSON 规范）。
     */
    public static func escape(s: String): String {
        let sb = StringBuilder()
        // 必须按 Unicode **码点**遍历（runes()），不能按字节（toArray()）：
        // 按字节会把中文拆成 3 个单字节，逐个判断会产出乱码。
        for (ch in s.runes().iterator()) {
            let cp = UInt32(ch)
            match (cp) {
                case 34 => sb.append("\\\"")     // "
                case 92 => sb.append("\\\\")     // \
                case 8 => sb.append("\\b")
                case 9 => sb.append("\\t")
                case 10 => sb.append("\\n")
                case 12 => sb.append("\\f")
                case 13 => sb.append("\\r")
                case _ =>
                    if (cp < 0x20) {
                        // 控制字符按 JSON 规范转义为 \u00XX
                        sb.append("\\u00")
                        sb.append(ApiResponse.hexDigit(UInt8((cp >> 4) & 15)))
                        sb.append(ApiResponse.hexDigit(UInt8(cp & 15)))
                    } else {
                        sb.append(ch.toString())
                    }
            }
        }
        return sb.toString()
    }
}

/**
 * 路由处理器。
 *
 * 接收 AMS 请求上下文，返回 AMS 响应。
 */
public type Handler = (ApiRequest) -> ApiResponse

/**
 * 路由条目。
 */
public class Route {
    /** HTTP 方法 */
    public let method: String
    /** 路径模式（支持 :param 占位） */
    public let pattern: String
    /** 处理器 */
    public let handler: Handler
    /** 需要的权限点（空表示仅需登录） */
    public let requiredPerm: String
    /** 是否允许匿名访问 */
    public let isPublic: Bool

    public init(
        method: String,
        pattern: String,
        handler: Handler,
        requiredPerm!: String = "",
        isPublic!: Bool = false
    ) {
        this.method = method.toAsciiUpper()
        this.pattern = pattern
        this.handler = handler
        this.requiredPerm = requiredPerm
        this.isPublic = isPublic
    }
}

/**
 * 路由表。
 *
 * 支持两种匹配：
 *   1. 精确匹配：/api/users
 *   2. 参数匹配：/api/users/:id（:id 捕获一段）
 */
public class Router {
    private let routes: ArrayList<Route>

    public init() {
        this.routes = ArrayList<Route>()
    }

    /**
     * 注册路由。
     */
    public func add(route: Route): Unit {
        this.routes.add(route)
    }

    /**
     * 注册 GET 路由。
     */
    public func get(pattern: String, handler: Handler, requiredPerm!: String = "", isPublic!: Bool = false): Unit {
        this.add(Route("GET", pattern, handler, requiredPerm: requiredPerm, isPublic: isPublic))
    }

    /**
     * 注册 POST 路由。
     */
    public func post(pattern: String, handler: Handler, requiredPerm!: String = "", isPublic!: Bool = false): Unit {
        this.add(Route("POST", pattern, handler, requiredPerm: requiredPerm, isPublic: isPublic))
    }

    /**
     * 注册 PUT 路由。
     */
    public func put(pattern: String, handler: Handler, requiredPerm!: String = "", isPublic!: Bool = false): Unit {
        this.add(Route("PUT", pattern, handler, requiredPerm: requiredPerm, isPublic: isPublic))
    }

    /**
     * 注册 DELETE 路由。
     */
    public func delete(pattern: String, handler: Handler, requiredPerm!: String = "", isPublic!: Bool = false): Unit {
        this.add(Route("DELETE", pattern, handler, requiredPerm: requiredPerm, isPublic: isPublic))
    }

    /**
     * 路由数量。
     */
    public func size(): Int64 {
        return this.routes.size
    }

    /**
     * 全部路由（供服务器逐条注册到 stdx 的 distributor）。
     */
    public func allRoutes(): ArrayList<Route> {
        return this.routes
    }

    /**
     * 查找匹配路由。
     *
     * @param method HTTP 方法
     * @param path   请求路径（不含查询串）
     * @return 匹配到的路由与解析出的路径参数；未匹配返回 None
     */
    public func find(method: String, path: String): Option<(Route, Map<String, String>)> {
        let m = method.toAsciiUpper()
        for (r in this.routes.iterator()) {
            if (r.method != m) {
                continue
            }
            let params = Router.matchPattern(r.pattern, path)
            if (params.isSome()) {
                return Some((r, params.getOrThrow()))
            }
        }
        return None
    }

    /**
     * 判断是否存在匹配该路径的路由（忽略方法）。
     *
     * 用于区分「路径不存在（404）」与「方法不匹配（405）」。
     */
    public func hasPath(path: String): Bool {
        for (r in this.routes.iterator()) {
            if (Router.matchPattern(r.pattern, path).isSome()) {
                return true
            }
        }
        return false
    }

    /**
     * 路径模式匹配。
     *
     * 例：pattern="/api/users/:id"  path="/api/users/42"
     *   → {"id": "42"}
     */
    public static func matchPattern(pattern: String, path: String): Option<Map<String, String>> {
        let ps = pattern.split("/")
        let qs = path.split("/")
        if (ps.size != qs.size) {
            return None
        }
        let params = HashMap<String, String>()
        for (i in 0..ps.size) {
            let seg = ps[i]
            if (seg.startsWith(":")) {
                let key = seg[1..]
                if (qs[i].isEmpty()) {
                    return None
                }
                params[key] = qs[i]
            } else if (seg != qs[i]) {
                return None
            }
        }
        return Some(params)
    }
}

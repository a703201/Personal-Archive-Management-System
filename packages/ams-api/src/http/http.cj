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
import ams.security.authz.*
import ams.kernel.time.*
import ams.kernel.util.*

/**
 * 请求体默认最大读取字节数。
 *
 * 登录 / 注册等接口的请求体都在 KB 级，1 MiB 足够。
 */
public const MAX_BODY_BYTES: Int64 = 1048576

/**
 * 大请求体上限（附件上传 / ZIP 批量导入）。
 *
 * 附件域对外承诺单文件 50 MB（FileTypes.maxFileSize），ZIP 批量导入
 * 还要在一包里装多份附件，故这两个入口单独放宽到 64 MiB。
 *
 * 为什么按路径分档而不是全局放到 64 MiB：
 *   请求体在**鉴权中间件之前**被读入内存，放宽全局上限等于让任何
 *   未认证请求都能逼服务器分配 64 MiB。只对确实需要大体积的两个
 *   入口放宽，其余接口维持 1 MiB，把放大倍数控制在必要范围内。
 *   残余风险（大体积请求仍需在读体后才鉴权）已在 docs/12 记录。
 */
public const MAX_LARGE_BODY_BYTES: Int64 = 67108864

/** 单次读取的块大小（64 KiB） */
private const BODY_CHUNK_BYTES: Int64 = 65536

/**
 * 按请求路径选请求体上限。
 *
 * 前缀匹配而非精确匹配：/api/attachments/12/versions 之类的子路径
 * 同样需要放宽。
 */
public func bodyCapFor(url: String): Int64 {
    let path = ApiRequest.pathOf(url)
    // 大体积入口：附件上传 / ZIP 批量导入 / 导出包回导（FR-EXP-008）。
    // 回导包内含整份条目数据，50000 行可达数 MB，1 MiB 会直接 413。
    if (path.startsWith("/api/attachments") ||
        path.startsWith("/api/import/attachments") ||
        path.startsWith("/api/import/bundle")) {
        return MAX_LARGE_BODY_BYTES
    }
    return MAX_BODY_BYTES
}

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
    /**
     * 请求体是否超过该路径的上限。
     *
     * 不在 fromContext 里直接抛异常：它运行在 stdx 的分发闭包内、位于
     * 所有 try/catch 之外，抛出去会变成连接层错误而不是 413。故只打标记，
     * 由 ApiServer.dispatch 在路由前统一转成 PAYLOAD_TOO_LARGE 响应。
     */
    public var bodyTooLarge: Bool = false
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
    /** 所属租户（由鉴权中间件填充，多租户隔离根） */
    public var tenantId: Int64 = 0

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
        // 请求体：**循环读到 EOF**。
        //
        // 旧实现只 read() 一次、缓冲区 1 MiB，超过 1 MiB 的部分既不报错
        // 也不返回，直接被丢掉 —— 附件上传声称支持 50 MB，实际 1 MiB 以上
        // 全部被静默截断（存进去的是半个文件，魔数校验还能通过）。
        // 这是「看起来能用、数据却是坏的」里最恶劣的一类，故改为循环读，
        // 并把上限按路径分档（见 bodyCapFor）。
        let cap = bodyCapFor(req.url.toString())
        var tooLarge = false
        let chunks = ArrayList<Array<Byte>>()
        var total: Int64 = 0
        try {
            let chunk = Array<Byte>(BODY_CHUNK_BYTES, repeat: 0u8)
            while (true) {
                let n = req.body.read(chunk)
                if (n <= 0) {
                    break
                }
                if (total + n > cap) {
                    tooLarge = true
                    break
                }
                chunks.add(ApiRequest.copyOf(chunk, n))
                total = total + n
            }
        } catch (e: Exception) {
            tooLarge = false
            chunks.clear()
            total = 0
        }
        let body = ApiRequest.concat(chunks, total)
        let out = ApiRequest(
            req.method,
            req.url.toString(),
            body,
            hs,
            req.remoteAddr.toString()
        )
        out.bodyTooLarge = tooLarge
        return out
    }

    /** 合并分块读取结果（一次性分配，避免逐字节扩容）。 */
    private static func concat(chunks: ArrayList<Array<Byte>>, total: Int64): Array<Byte> {
        if (total <= 0) {
            return Array<Byte>()
        }
        let flat = Array<Byte>(total, repeat: 0u8)
        var at: Int64 = 0
        for (c in chunks) {
            for (b in c) {
                flat[at] = b
                at = at + 1
            }
        }
        return flat
    }

    /**
     * 拷贝复用缓冲区的前 n 个字节。
     *
     * 【为什么必须显式拷贝，而不是 `chunk[0..n]`】
     *   分块读取只分配**一个**缓冲区并反复复用。若 `Array<Byte>[Range]`
     *   返回的是视图而非拷贝，所有分块都会指向同一段内存 —— 循环读完后
     *   每一块都是「最后一次读到的那 64 KiB」，拼出来的请求体
     *   **长度正确、内容全错**。这种错误极难看出来：日志里 size 对得上，
     *   只有解析 ZIP/图片时才会以「中央目录找不到」「魔数不符」的形式暴露。
     *   一次显式拷贝就把对切片语义的依赖彻底去掉，代价可以忽略。
     */
    private static func copyOf(src: Array<Byte>, n: Int64): Array<Byte> {
        let part = Array<Byte>(n, repeat: 0u8)
        var i: Int64 = 0
        while (i < n) {
            part[i] = src[i]
            i = i + 1
        }
        return part
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
                    return Some(trimSpace(v[7..]))
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
                return Some(ApiRequest.percentDecode(kv[1]))
            }
        }
        return None
    }

    /**
     * URL 百分号解码（RFC 3986，UTF-8 安全）。
     *
     * 【为什么必须补这一步】
     *   此前 queryParam 直接返回原始片段：浏览器/前端对中文与空格一律
     *   百分号编码，于是 `?keyword=清华` 在服务端拿到的是
     *   `%E6%B8%85%E5%8D%8E`，分词器把它当成 ASCII 串切成 e6/b8/85…
     *   —— 中文关键词检索**永远命中不了**，且排序/过滤里的中文值同样失效。
     *
     * 【实现要点】
     *   在**字节层**解码后一次性 fromUtf8，避免按字节拼接出非法 UTF-8
     *   （本仓已两次踩到这个坑：盲索引归一化、掩码切分）。
     *   `+` 不作空格处理：RFC 3986 的查询串里 `+` 是字面量，
     *   仅 application/x-www-form-urlencoded 的表单提交才需转换。
     */
    public static func percentDecode(s: String): String {
        let src = s.toArray()
        let out = ArrayList<Byte>()
        var i: Int64 = 0
        while (i < src.size) {
            let b = src[i]
            if (b == 37 && i + 2 < src.size) {
                let hi = ApiRequest.hexVal(src[i + 1])
                let lo = ApiRequest.hexVal(src[i + 2])
                if (hi >= 0 && lo >= 0) {
                    out.add(UInt8(hi * 16 + lo))
                    i = i + 3
                    continue
                }
            }
            out.add(b)
            i = i + 1
        }
        return String.fromUtf8(out.toArray())
    }

    /**
     * 十六进制字符 → 数值（非法返回 -1）。
     */
    private static func hexVal(b: Byte): Int64 {
        if (b >= 48 && b <= 57) {
            return Int64(b - 48)
        }
        if (b >= 97 && b <= 102) {
            return Int64(b - 87)
        }
        if (b >= 65 && b <= 70) {
            return Int64(b - 55)
        }
        return -1
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
/**
 * 资源守卫。
 *
 * 用途：声明「本路由操作的资源是什么」，供鉴权中间件做**对象级**判定。
 *
 * 返回 None 表示该请求不涉及具体资源（如列表接口的分类过滤），
 * 此时只做功能权限判定。
 */
public type ResourceGuard = (ApiRequest) -> Option<AuthzResource>

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
    /**
     * 资源守卫（可选）。
     *
     * 给了它，鉴权中间件会在功能权限通过后追加：
     *   - 数据归属校验（FR-ACL-006）
     *   - 分类敏感度分级（FR-ACL-007）
     *   - 显式授权与有效期（FR-ACL-008 / FR-ACL-009）
     */
    public let guard: ResourceGuard

    public init(
        method: String,
        pattern: String,
        handler: Handler,
        requiredPerm!: String = "",
        isPublic!: Bool = false,
        guard!: ResourceGuard = { _: ApiRequest => None }
    ) {
        this.method = method.toAsciiUpper()
        this.pattern = pattern
        this.handler = handler
        this.requiredPerm = requiredPerm
        this.isPublic = isPublic
        this.guard = guard
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
    public func get(
        pattern: String,
        handler: Handler,
        requiredPerm!: String = "",
        isPublic!: Bool = false,
        guard!: ResourceGuard = { _: ApiRequest => None }
    ): Unit {
        this.add(Route("GET", pattern, handler, requiredPerm: requiredPerm, isPublic: isPublic, guard: guard))
    }

    /**
     * 注册 POST 路由。
     */
    public func post(
        pattern: String,
        handler: Handler,
        requiredPerm!: String = "",
        isPublic!: Bool = false,
        guard!: ResourceGuard = { _: ApiRequest => None }
    ): Unit {
        this.add(Route("POST", pattern, handler, requiredPerm: requiredPerm, isPublic: isPublic, guard: guard))
    }

    /**
     * 注册 PUT 路由。
     */
    public func put(
        pattern: String,
        handler: Handler,
        requiredPerm!: String = "",
        isPublic!: Bool = false,
        guard!: ResourceGuard = { _: ApiRequest => None }
    ): Unit {
        this.add(Route("PUT", pattern, handler, requiredPerm: requiredPerm, isPublic: isPublic, guard: guard))
    }

    /**
     * 注册 DELETE 路由。
     */
    public func delete(
        pattern: String,
        handler: Handler,
        requiredPerm!: String = "",
        isPublic!: Bool = false,
        guard!: ResourceGuard = { _: ApiRequest => None }
    ): Unit {
        this.add(Route("DELETE", pattern, handler, requiredPerm: requiredPerm, isPublic: isPublic, guard: guard))
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

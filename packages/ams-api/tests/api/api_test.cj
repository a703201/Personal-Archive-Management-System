// ============================================================
// ams-api 单元测试
//
// 覆盖：
//   - 路由匹配（精确路径 / 参数路径 / 方法不匹配 / 路径不存在）
//   - 统一响应格式（成功体 / 错误体 / JSON 转义）
//   - 中间件链（请求ID / 鉴权短路 / 权限不足）
//   - 异常映射（AppError / 未知异常）
//
// 说明：不依赖数据库与真实服务器，全部用内存对象驱动。
// ============================================================
package ams.api.tests

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.net.http.*

import ams.api.http.*
import ams.api.middleware.*
import ams.api.server.*
import ams.crypto.provider.*
import ams.kernel.error.*
import ams.kernel.id.*
import ams.security.authn.*
import ams.crypto.impl.*
import ams.security.authz.*

/**
 * 构造一个内存请求。
 */
private func makeReq(
    method: String,
    url: String,
    token!: String = "",
    body!: String = ""
): ApiRequest {
    let hs = HashMap<String, String>()
    if (!token.isEmpty()) {
        hs.add("authorization", "Bearer ${token}")
    }
    return ApiRequest(
        method,
        url,
        body.toArray(),
        hs,
        "127.0.0.1"
    )
}

/**
 * 路由匹配：精确路径。
 */
@Test
public func testRouterExactMatch(): Unit {
    let r = Router()
    r.get("/api/health", { _: ApiRequest => ApiResponse.ok("{}", "req-1") })

    match (r.find("GET", "/api/health")) {
        case Some((route, params)) =>
            @Assert(route.method == "GET")
            @Assert(params.size == 0)
        case None => @Assert(false)
    }
    // 方法不匹配
    @Assert(r.find("POST", "/api/health").isNone())
    // 路径不匹配
    @Assert(r.find("GET", "/api/other").isNone())
}

/**
 * 路由匹配：参数路径。
 */
@Test
public func testRouterParamMatch(): Unit {
    let r = Router()
    r.get("/api/users/:id", { _: ApiRequest => ApiResponse.ok("{}", "req-1") })

    match (r.find("GET", "/api/users/42")) {
        case Some((_, params)) => @Assert(params["id"] == "42")
        case None => @Assert(false)
    }
    // 段数不匹配
    @Assert(r.find("GET", "/api/users").isNone())
    @Assert(r.find("GET", "/api/users/42/detail").isNone())
}

/**
 * 路由：hasPath 忽略方法，用于区分 404 / 405。
 */
@Test
public func testRouterHasPath(): Unit {
    let r = Router()
    r.get("/api/users", { _: ApiRequest => ApiResponse.ok("{}", "req-1") })
    @Assert(r.hasPath("/api/users"))
    @Assert(!r.hasPath("/api/nope"))
}

/**
 * 成功响应体格式。
 */
@Test
public func testResponseOkFormat(): Unit {
    let resp = ApiResponse.ok("{\"id\":1}", "req-abc")
    @Assert(resp.status == 200)
    @Assert(resp.body.contains("\"code\":\"OK\""))
    @Assert(resp.body.contains("\"data\":{\"id\":1}"))
    @Assert(resp.body.contains("\"requestId\":\"req-abc\""))
}

/**
 * 错误响应体格式与状态码映射。
 */
@Test
public func testResponseErrorFormat(): Unit {
    let resp = ApiResponse.error(AppErrorKind.Forbidden, "无权限", "req-1", field: "id")
    @Assert(resp.status == 403)
    @Assert(resp.body.contains("\"code\":\"FORBIDDEN\""))
    @Assert(resp.body.contains("\"message\":\"无权限\""))
    @Assert(resp.body.contains("\"field\":\"id\""))
}

/**
 * JSON 转义：引号、反斜杠、换行、控制字符。
 */
@Test
public func testJsonEscape(): Unit {
    @Assert(ApiResponse.escape("a\"b") == "a\\\"b")
    @Assert(ApiResponse.escape("a\\b") == "a\\\\b")
    @Assert(ApiResponse.escape("a\nb") == "a\\nb")
    @Assert(ApiResponse.escape("a\tb") == "a\\tb")
    // 中文按 UTF-8 原样输出
    @Assert(ApiResponse.escape("中文") == "中文")
}

/**
 * 请求头大小写不敏感 + Bearer 令牌解析。
 */
@Test
public func testRequestHeaderAndBearer(): Unit {
    let hs = HashMap<String, String>()
    hs.add("authorization", "Bearer tok-123")
    hs.add("content-type", "application/json")
    let req = ApiRequest("get", "/api/x", Array<Byte>(), hs, "1.2.3.4")
    @Assert(req.method == "GET")
    @Assert(req.header("Content-Type") == "application/json")
    @Assert(req.bearerToken().getOrThrow() == "tok-123")
}

/**
 * 无 Authorization 头时 bearerToken 返回 None。
 */
@Test
public func testRequestNoBearer(): Unit {
    let req = makeReq("GET", "/api/x")
    @Assert(req.bearerToken().isNone())
}

/**
 * 查询参数解析。
 */
@Test
public func testQueryParam(): Unit {
    let req = makeReq("GET", "/api/users?page=2&size=20")
    @Assert(req.queryParam("page").getOrThrow() == "2")
    @Assert(req.queryParam("size").getOrThrow() == "20")
    @Assert(req.queryParam("missing").isNone())
}

/**
 * 路径提取（去掉查询串）。
 */
@Test
public func testPathOf(): Unit {
    @Assert(ApiRequest.pathOf("/api/users?page=1") == "/api/users")
    @Assert(ApiRequest.pathOf("/api/users") == "/api/users")
}

/**
 * 异常映射：AppError 按其 kind 映射状态码。
 */
@Test
public func testMapErrorAppError(): Unit {
    let resp = mapError(AppError(AppErrorKind.NotFound, "用户不存在"), "req-1")
    @Assert(resp.status == 404)
    @Assert(resp.body.contains("NOT_FOUND"))
}

/**
 * 异常映射：未知异常统一 500，且不泄露内部细节。
 */
@Test
public func testMapErrorUnknown(): Unit {
    let resp = mapError(Exception("secret sql detail"), "req-1")
    @Assert(resp.status == 500)
    @Assert(resp.body.contains("INTERNAL_ERROR"))
    @Assert(!resp.body.contains("secret sql detail"))
}

/**
 * 中间件：请求 ID 优先取上游传入的 X-Request-Id。
 */
@Test
public func testRequestIdMiddleware(): Unit {
    let hs = HashMap<String, String>()
    hs.add("x-request-id", "upstream-1")
    let req = ApiRequest("GET", "/api/x", Array<Byte>(), hs, "1.1.1.1")
    let mw = requestIdMiddleware()
    @Assert(mw(req).isNone())
    @Assert(req.requestId == "upstream-1")
}

/**
 * 中间件：无上游请求 ID 时自动生成（非空）。
 */
@Test
public func testRequestIdMiddlewareAuto(): Unit {
    // 请求 ID 缺失时走雪花 ID 生成器，需先初始化
    Ids.setup(1)
    let req = makeReq("GET", "/api/x")
    let mw = requestIdMiddleware()
    @Assert(mw(req).isNone())
    @Assert(!req.requestId.isEmpty())
}

/**
 * 中间件：公开路由无令牌时放行。
 */
@Test
public func testAuthMiddlewarePublicRoute(): Unit {
    let r = Router()
    r.add(Route("GET", "/api/health", { _: ApiRequest => ApiResponse.ok("{}", "r") }, isPublic: true))
    let auth = AuthContext(
        TokenService(StdxCryptoProvider(), TokenConfig(secret: Array<Byte>(32, repeat: 0u8)), MemorySessionStore()),
        { _: String => UserAccess(ArrayList<String>(), ArrayList<String>(), ArrayList<String>(), 0) }
    )
    let req = makeReq("GET", "/api/health")
    let mw = authMiddleware(auth, r)
    @Assert(mw(req).isNone())
}

/**
 * 中间件：非公开路由无令牌时短路并返回 401。
 */
@Test
public func testAuthMiddlewareMissingToken(): Unit {
    let r = Router()
    r.get("/api/users", { _: ApiRequest => ApiResponse.ok("{}", "r") })
    let auth = AuthContext(
        TokenService(StdxCryptoProvider(), TokenConfig(secret: Array<Byte>(32, repeat: 0u8)), MemorySessionStore()),
        { _: String => UserAccess(ArrayList<String>(), ArrayList<String>(), ArrayList<String>(), 0) }
    )
    let req = makeReq("GET", "/api/users")
    let mw = authMiddleware(auth, r)
    match (mw(req)) {
        case Some(resp) => @Assert(resp.status == 401)
        case None => @Assert(false)
    }
}

/**
 * 服务器：未匹配路径返回 404 JSON。
 */
@Test
public func testServerNotFound(): Unit {
    let r = Router()
    r.get("/api/health", { _: ApiRequest => ApiResponse.ok("{}", "r") })
    let srv = ApiServer("127.0.0.1", 18080, r)
    let req = makeReq("GET", "/api/nope")
    let resp = srv.handleRequest(req)
    @Assert(resp.status == 404)
    @Assert(resp.body.contains("NOT_FOUND"))
}

/**
 * 服务器：路径存在但方法不匹配时返回 400（ValidationFailed）。
 */
@Test
public func testServerMethodNotAllowed(): Unit {
    let r = Router()
    r.get("/api/health", { _: ApiRequest => ApiResponse.ok("{}", "r") })
    let srv = ApiServer("127.0.0.1", 18080, r)
    let req = makeReq("POST", "/api/health")
    let resp = srv.handleRequest(req)
    @Assert(resp.status == 400)
    @Assert(resp.body.contains("VALIDATION_FAILED"))
}

/**
 * 服务器：处理器抛 AppError 时被统一映射。
 */
@Test
public func testServerHandlerThrows(): Unit {
    let r = Router()
    r.get("/api/boom", { _: ApiRequest => throw AppError(AppErrorKind.Conflict, "冲突") })
    let srv = ApiServer("127.0.0.1", 18080, r)
    let req = makeReq("GET", "/api/boom")
    let resp = srv.handleRequest(req)
    @Assert(resp.status == 409)
    @Assert(resp.body.contains("CONFLICT"))
}

/**
 * 服务器：正常路由返回 200。
 */
@Test
public func testServerOk(): Unit {
    let r = Router()
    r.get("/api/health", { req: ApiRequest => ApiResponse.ok("{\"ok\":true}", req.requestId) })
    let srv = ApiServer("127.0.0.1", 18080, r)
    let req = makeReq("GET", "/api/health")
    let resp = srv.handleRequest(req)
    @Assert(resp.status == 200)
    @Assert(resp.body.contains("\"ok\":true"))
}

/**
 * 自定义分发器的参数化路径匹配。
 *
 * stdx 内置的 DirectDistributor 只做精确路径匹配（参数化路由会 404），
 * 本项目的 ParamDistributor 补上了这个能力。
 */
/**
 * 判断分发器返回的处理器是否为本项目注册的 **TestHandler** 实例
 * （而非未命中时返回的 404 兜底处理器）。
 *
 * 说明：本版本仓颉编译器**不支持** `===` 引用相等运算符
 * （`a === b` 直接报 `expected expression after '==', found '='`），
 * 故改用安全转换 `a as TestHandler`（返回 `Option<TestHandler>`）做类型鉴别，
 * 等价于「返回的是同一个注册实例」这一原始意图。
 */
private func isTestHandler(h: HttpRequestHandler): Bool {
    match (h as TestHandler) {
        case Some(_) => return true
        case None => return false
    }
}

@Test
public func testParamDistributor(): Unit {
    let d = ParamDistributor()
    let h = TestHandler()
    d.register("/api/users", h)
    d.register("/api/users/:id", h)
    d.register("/api/users/:id/roles", h)
    d.register("/api/items/:itemId/tags/:tagId", h)

    // 精确路径命中
    @Assert(isTestHandler(d.distribute("/api/users")))
    // 单参数：任意段都命中
    @Assert(isTestHandler(d.distribute("/api/users/900001")))
    @Assert(isTestHandler(d.distribute("/api/users/abc")))
    // 参数 + 字面量段
    @Assert(isTestHandler(d.distribute("/api/users/900001/roles")))
    // 双参数
    @Assert(isTestHandler(d.distribute("/api/items/42/tags/7")))
    // 段数不匹配 → 返回 404 兜底处理器（不是 TestHandler）
    @Assert(!isTestHandler(d.distribute("/api/users/900001/roles/extra")))
    @Assert(!isTestHandler(d.distribute("/api/other")))
}

/**
 * 测试用处理器。
 */
public class TestHandler <: HttpRequestHandler {
    public func handle(ctx: HttpContext): Unit {
        ctx.responseBuilder.body("ok").build()
    }
}

// ============================================================
// ams.api.server · HTTP 服务器装配
//
// 职责：
//   - 把路由表挂到 stdx.net.http 的 distributor 上
//   - 装配中间件链（请求ID → 访问日志 → 鉴权）
//   - 统一异常捕获（业务异常 → 错误响应）
//
// [stdx.net.http API 实测要点]（1.2.0.1）
//   let server = ServerBuilder().addr("127.0.0.1").port(8080).build()
//   server.distributor.register(path, { ctx: HttpContext => ... })
//   server.serve()                      // 阻塞
//   ctx.request.method / body / headers / url / remoteAddr
//   ctx.responseBuilder.status(..).header(..).body(..).build()
//
//   ⚠️ distributor 的 register 是**精确路径匹配**（无参数占位），
//      故参数化路由（/api/users/:id）由 AMS 自己的 Router 处理，
//      这里为每条路由注册一个「前缀分发」入口。
// ============================================================
package ams.api.server

import std.collection.*
import stdx.net.http.*

import ams.api.http.*
import ams.api.middleware.*
import ams.kernel.error.*
import ams.kernel.log.*
import ams.kernel.time.*

/**
 * 应用服务器。
 *
 * 持有路由表与中间件链，对外暴露启动方法。
 */
public class ApiServer {
    private let router: Router
    private let middlewares: ArrayList<Middleware>
    private let host: String
    private let port: Int64

    public init(host: String, port: Int64, router: Router) {
        this.host = host
        this.port = port
        this.router = router
        this.middlewares = ArrayList<Middleware>()
    }

    /**
     * 追加中间件（按加入顺序执行）。
     */
    public func use(mw: Middleware): Unit {
        this.middlewares.add(mw)
    }

    /**
     * 启动服务（阻塞）。
     */
    public func serve(): Unit {
        let builder = ServerBuilder()
        builder.addr(this.host)
        builder.port(UInt16(this.port))

        // 为 AMS 路由在 stdx 的 distributor 上注册入口。
        //
        // 【stdx distributor 的两个限制】（实测 1.2.0.1）
        //   ① 精确路径匹配，**不支持** ":param" 占位
        //      （注册 "/api/users/:id" 后，请求 "/api/users/900001" 返回 404）
        //   ② **同一路径不能注册两次**
        //      （GET 与 POST 同路径会抛 "Path: xxx already registered"）
        //
        // 【处置】
        //   ① 参数化路由注册其**静态前缀**（"/api/users/:id" → "/api/users"），
        //      真正的匹配与参数解析交给 AMS 自己的 Router；
        //   ② 同一静态前缀只注册一次，多个方法/路由由 AMS 的 Router 分派；
        //   ③ 前缀冲突时（一个前缀是另一个的前缀）取**最长**的那个，
        //      避免 "/api/users" 抢走 "/api/users/:id/roles" 的请求。
        //
        // 举例：AMS 路由
        //   /api/users          → 注册 "/api/users"
        //   /api/users/:id      → 前缀 "/api/users"（已存在，跳过）
        //   /api/users/:id/roles→ 前缀 "/api/users"（已存在，跳过）
        //   实际请求 /api/users/42/roles 由 AMS Router 精确匹配到
        //   "/api/users/:id/roles" 并解析出 id=42。
        // 使用**自定义分发器**（支持 ":param" 占位）。
        // stdx 内置的 DirectDistributor 只做精确路径匹配，
        // 参数化路由会 404（详见 ParamDistributor 的说明）。
        let distributor = ParamDistributor()
        for (r in this.router.allRoutes().iterator()) {
            let pattern = r.pattern
            distributor.register(pattern, { ctx: HttpContext =>
                let resp = this.handle(ctx)
                ctx.responseBuilder
                   .status(UInt16(resp.status))
                   .body(resp.body)
                   .build()
            })
        }
        builder.distributor(distributor)
        let server = builder.build()

        Log.get().info("http.server.start", None, [
            ("host", this.host),
            ("port", "${this.port}"),
            ("routes", "${this.router.size()}")
        ])

        server.serve()
    }

    /**
     * 处理一次请求（供单元测试直接调用，不必起真实服务器）。
     */
    public func handle(ctx: HttpContext): ApiResponse {
        return this.handleRequest(ApiRequest.fromContext(ctx))
    }

    /**
     * 处理一次请求（内部）。
     */
    public func handleRequest(req: ApiRequest): ApiResponse {
        // ---- 中间件链 ----
        for (mw in this.middlewares.iterator()) {
            match (mw(req)) {
                case Some(resp) => return resp
                case None => ()
            }
        }

        // ---- 路由匹配 ----
        let path = ApiRequest.pathOf(req.url)
        match (this.router.find(req.method, path)) {
            case None =>
                // 路径存在但方法不匹配 → 405；否则 404
                if (this.router.hasPath(path)) {
                    return ApiResponse.error(
                        AppErrorKind.ValidationFailed,
                        "请求方法不被允许",
                        req.requestId
                    )
                }
                return ApiResponse.error(
                    AppErrorKind.NotFound,
                    "接口不存在",
                    req.requestId
                )
            case Some((route, params)) =>
                // matchPattern 返回的是 Map 接口，这里转成 HashMap 赋值
                for ((k, v) in params) {
                    req.pathParams.add(k, v)
                }
                // ---- 业务处理（异常统一映射）----
                try {
                    return route.handler(req)
                } catch (e: Exception) {
                    return mapError(e, req.requestId)
                }
        }
    }
}

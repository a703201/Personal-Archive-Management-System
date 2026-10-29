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
import ams.kernel.metrics.*
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
    /**
     * 前端静态资源目录（空 = 不托管）。
     *
     * 非空时，未命中任何 API 路由的请求交给 StaticFiles 处理 ——
     * 于是**一个进程同时提供前端页面与接口**，部署不再需要
     * 第二个静态服务器 / nginx，也就没有跨域与两个端口要维护。
     */
    private let staticDir: String

    public init(host: String, port: Int64, router: Router, staticDir!: String = "") {
        this.host = host
        this.port = port
        this.router = router
        this.middlewares = ArrayList<Middleware>()
        this.staticDir = staticDir
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
        // 请求体上限：**必须在这里设**，否则 stdx 在传输层就返回 413
        // 「The content too large.」，我们的读取循环根本跑不到
        // —— 表现为「附件明明说支持 50MB，1MB 以上一律 413」。
        // 分档策略见 http.cj 的 bodyCapFor（非附件接口仍是 1 MiB）。
        builder.maxRequestBodySize(MAX_LARGE_BODY_BYTES)

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
                let rb = ctx.responseBuilder.status(UInt16(resp.status))
                // 响应头必须显式应用：此前只写了 status 与 body，
                // 于是 ApiResponse.headers 里声明的 content-type 全部被丢弃 ——
                // 浏览器靠嗅探也能工作，但下载类响应与严格的模块脚本会因此出错。
                for ((k, v) in resp.headers) {
                    rb.header(k, v)
                }
                rb.body(resp.body).build()
            })
        }
        // ---- 前端托管：兜底接住所有未命中 API 的请求 ----
        if (!this.staticDir.isEmpty()) {
            distributor.setFallback(StaticHandler(StaticFiles(this.staticDir)))
            Log.get().info("http.static.enabled", None, [("root", this.staticDir)])
        } else {
            Log.get().warn("http.static.disabled", None,
                           [("hint", "未找到前端产物；设置 AMS_WEB_DIR 或先执行 npm run build")])
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
     *
     * 包一层只做一件事：把响应状态记入运行指标（FR-CFG-005）。
     *   放在这里而不是各路由里，是因为**所有**出口（中间件短路 / 405 / 404 /
     *   业务成功 / 异常映射）最终都会回到这一个返回值，
     *   天然不会漏计。
     */
    public func handleRequest(req: ApiRequest): ApiResponse {
        let resp = this.dispatch(req)
        metrics().record(resp.status)
        return resp
    }

    /**
     * 真正的分发与异常处理。
     */
    private func dispatch(req: ApiRequest): ApiResponse {
        // ---- 中间件链 ----
        for (mw in this.middlewares.iterator()) {
            match (mw(req)) {
                case Some(resp) => return resp
                case None => ()
            }
        }

        // ---- 请求体超限（在读体阶段只打标记，这里统一出 413）----
        // 放在中间件之后：此时 requestId 已生成、鉴权已判定，
        // 未认证的超大请求会先拿到 401 而不是 413，语义更准确。
        if (req.bodyTooLarge) {
            return ApiResponse.error(
                AppErrorKind.PayloadTooLarge,
                "请求体超过上限（附件与批量导入接口 64 MB，其余接口 1 MB）",
                req.requestId
            )
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

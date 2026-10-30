// ============================================================
// ams.api.middleware · 中间件链
//
// 职责（架构 §3.3 中间件链顺序）：
//   请求ID → 访问日志 → 限流 → 鉴权 → 业务处理
//
// [设计要点]
//   仓颉无 AOP 框架，故用**显式的处理链**实现：
//   每个中间件是 (ApiRequest) -> Option<ApiResponse> 的函数，
//   返回 None 表示放行，返回 Some 表示短路并直接响应。
//   这样既保留中间件语义，又完全可控可测。
//
// [安全约束]
//   ① 鉴权中间件在**业务处理之前**执行，且按
//      「认证 → 功能权限 → 数据归属 → 分类敏感度 → 字段敏感度」顺序判定
//      （安全章 §6.1，不可交换）；
//   ② 鉴权失败一律返回 401/403，不泄露内部细节；
//   ③ 访问令牌**不写日志**，只记 jti/sid。
// ============================================================
package ams.api.middleware

import std.collection.*

import ams.api.http.*
import ams.crypto.provider.*
import ams.kernel.error.*
import ams.kernel.id.*
import ams.kernel.log.*
import ams.kernel.time.*
import ams.security.authn.*
import ams.security.authz.*

/**
 * 中间件。
 *
 * @param req 请求上下文（可被中间件补充信息）
 * @return Some(响应) 表示短路；None 表示放行到下一环节
 */
public type Middleware = (ApiRequest) -> Option<ApiResponse>

/**
 * 鉴权所需的依赖。
 */
/**
 * 用户的可访问范围。
 *
 * 由仓储层一次性查出，供鉴权中间件构造 AccessContext。
 */
public class UserAccess {
    /** 权限点集合 */
    public let perms: ArrayList<String>
    /** 角色码集合 */
    public let roles: ArrayList<String>
    /** 可访问的主体 ID（本人 + 代管 + 被授权） */
    public let subjectIds: ArrayList<String>
    /**
     * 该用户**本人拥有**的主体 ID（不含代管）。
     *
     * 与 subjectIds 的区别见 AccessContext 的说明：
     * 归属校验用 subjectIds，敏感度判定用 ownedSubjectIds。
     */
    public let ownedSubjectIds: ArrayList<String>
    /** 数据可见上限（取所有角色的最大值） */
    public let maxDataLevel: Int64
    /**
     * 所属租户（多租户隔离根）。
     *
     * 所有数据访问都必须带上此值做行级过滤（见 docs/18 §4.2）。
     * 由 accessLoader 从 sys_users.tenant_id 取出，失败关闭为 0
     * （0 表示非法租户，仓储层据此拒绝而非放行）。
     */
    public let tenantId: Int64

    public init(
        perms: ArrayList<String>,
        roles: ArrayList<String>,
        subjectIds: ArrayList<String>,
        maxDataLevel: Int64,
        tenantId: Int64,
        ownedSubjectIds!: ArrayList<String> = ArrayList<String>()
    ) {
        this.perms = perms
        this.roles = roles
        this.subjectIds = subjectIds
        this.ownedSubjectIds = ownedSubjectIds
        this.maxDataLevel = maxDataLevel
        this.tenantId = tenantId
    }
}

public class AuthContext {
    /** 令牌服务（签发与校验） */
    public let tokenService: TokenService
    /** 权限查询（拿用户权限点、角色与可访问主体） */
    public let accessLoader: (String) -> UserAccess
    /** 临时授权查询（拿该用户的显式授权，含已撤销/已过期的，判定时自行过滤） */
    public let grantLoader: (String) -> Array<Grant>

    public init(
        tokenService: TokenService,
        accessLoader: (String) -> UserAccess,
        grantLoader!: (String) -> Array<Grant> = { _: String => Array<Grant>() }
    ) {
        this.tokenService = tokenService
        this.accessLoader = accessLoader
        this.grantLoader = grantLoader
    }
}

/**
 * 请求 ID 中间件。
 *
 * 为每个请求生成唯一 ID（雪花 ID 的字符串形式），写进响应体与响应头，
 * 便于全链路日志串联。优先采用上游传入的 X-Request-Id（信任网关）。
 */
public func requestIdMiddleware(): Middleware {
    return { req: ApiRequest =>
        // 说明：仓颉的 match 分支**不支持** if 守卫（"expected '=>' in case"），
        // 故在分支体内判断。
        match (req.header("x-request-id")) {
            case Some(v) =>
                if (!v.isEmpty()) {
                    req.requestId = v
                } else {
                    req.requestId = Ids.nextString()
                }
            case None => req.requestId = Ids.nextString()
        }
        return None
    }
}

/**
 * 访问日志中间件。
 *
 * 记录：方法、路径、状态码、耗时、请求 ID、用户 ID、客户端 IP。
 * **不记录** Authorization 头与请求体（可能含口令 / 敏感字段）。
 */
public func accessLogMiddleware(): Middleware {
    return { req: ApiRequest =>
        // 记录开始时间；真正的耗时在响应返回后由服务器侧统计，
        // 这里只记录请求元信息（避免中间件里做响应拦截，破坏短路语义）。
        Log.get().info("http.access", None, [
            ("requestId", req.requestId),
            ("method", req.method),
            ("path", req.url),
            ("ip", req.remoteAddr)
        ])
        return None
    }
}

/**
 * 鉴权中间件。
 *
 * 流程：
 *   1. 从 Authorization 头取 Bearer 令牌；
 *   2. 校验访问令牌（签名 + 过期 + 会话吊销）；
 *   3. 载入用户权限点与角色；
 *   4. 校验路由要求的权限点（功能权限）。
 *
 * @param auth 鉴权上下文
 * @param router 路由表（取该路由要求的权限点）
 */
public func authMiddleware(auth: AuthContext, router: Router): Middleware {
    return { req: ApiRequest =>
        // 取出匹配的路由以确定所需权限与资源守卫
        let path = ApiRequest.pathOf(req.url)
        var requiredPerm = ""
        var isPublic = false
        var guard: Option<ResourceGuard> = None
        match (router.find(req.method, path)) {
            case Some((route, params)) =>
                requiredPerm = route.requiredPerm
                isPublic = route.isPublic
                guard = Some(route.guard)
                // ⚠️ 必须把路径参数填进 req！
                //
                // 中间件链在**路由匹配之前**执行（见 server.handleRequest），
                // 此时 req.pathParams 还是空的 —— 路由分发阶段才会填。
                // 若这里不填，资源守卫（guard）拿不到 :id 等参数 →
                // 返回 None → **对象级鉴权被整体跳过**（FR-ACL-006/007/008/009
                // 全部形同虚设，任何登录用户都能读写他人条目）。
                //
                // 实测踩坑：family 用户读他人条目返回 200 而非 403。
                for ((k, v) in params) {
                    if (!req.pathParams.contains(k)) {
                        req.pathParams.add(k, v)
                    }
                }
            case None => ()
        }

        // 公开路由：只需解析令牌（有则填充身份），不强制
        match (req.bearerToken()) {
            case None =>
                if (!isPublic) {
                    return Some(ApiResponse.error(
                        AppErrorKind.Unauthorized,
                        "缺少访问令牌",
                        req.requestId
                    ))
                }
                return None
            case Some(token) =>
                match (auth.tokenService.verifyAccessToken(token)) {
                    case CryptoResult.Ok(payload) =>
                        req.subjectId = payload.uid
                        req.sid = payload.sid
                        let access = auth.accessLoader(payload.uid)
                        req.perms = access.perms
                        req.roles = access.roles
                        req.tenantId = access.tenantId
                        // 功能权限判定（安全章 §6.1 第 2 步）
                        //
                        // ⚠️ 必须用 satisfiesPerm（any 覆盖 own），**不能**用
                        //    access.perms.contains(requiredPerm) 精确匹配：
                        //    持有 archive:read:any 的用户读 own 范围的接口会被误拒，
                        //    且 Authorizer 的细粒度判定根本没机会执行（实测踩坑）。
                        let funcCtx = AccessContext(
                            payload.uid,
                            access.perms.toArray(),
                            access.subjectIds.toArray(),
                            access.maxDataLevel,
                            access.tenantId,
                            ownedSubjectIds: access.ownedSubjectIds.toArray()
                        )
                        if (!requiredPerm.isEmpty() && !funcCtx.satisfiesPerm(requiredPerm)) {
                            return Some(ApiResponse.error(
                                AppErrorKind.Forbidden,
                                "无权限执行该操作",
                                req.requestId
                            ))
                        }
                        // ---- 对象级判定（安全章 §6.1 第 3~5 步）----
                        //
                        // 路由可用 guard 声明「本操作涉及哪个资源」；
                        // 有 guard 时追加：数据归属 + 敏感度分级 + 显式授权/有效期。
                        //
                        // ⚠️ 这是 FR-ACL-006/007/008/009 真正生效的地方。
                        //    此前 Authorizer 虽已实现且有单测，但**没有任何业务路径调用**，
                        //    导致敏感度分级与授权到期形同虚设。
                        if (guard.isSome()) {
                            let denied = MiddlewareGuards.checkResource(
                                auth,
                                req,
                                access,
                                requiredPerm,
                                guard.getOrThrow(),
                                payload.uid
                            )
                            if (denied.isSome()) {
                                return denied
                            }
                        }
                        return None
                    case CryptoResult.Err(_) =>
                        if (!isPublic) {
                            return Some(ApiResponse.error(
                                AppErrorKind.Unauthorized,
                                "令牌无效或已过期",
                                req.requestId
                            ))
                        }
                        return None
                }
        }
    }
}

/**
 * 异常映射。
 *
 * 把业务异常转换为统一错误响应。
 *
 * 规约（架构 §3.3）：
 *   - 面向用户的 message 不含内部细节（SQL / 堆栈 / 密钥）；
 *   - 内部细节写日志。
 */
public func mapError(e: Exception, requestId: String): ApiResponse {
    // AppError 携带明确的错误种类，直接映射。
    // 注意：仓颉的 `as` 转换返回 Option[T]（不保证成功），需显式解包。
    match (e as AppError) {
        case Some(ae) =>
            Log.get().error("http.error", None, [
                ("requestId", requestId),
                ("code", ae.code),
                ("field", ae.field)
            ])
            return ApiResponse.error(ae.kind, ae.message, requestId, field: ae.field)
        case None =>
            // 未知异常：对外统一 INTERNAL_ERROR，细节只进日志
            Log.get().error("http.unhandled", None, [
                ("requestId", requestId),
                ("detail", e.toString())
            ])
            return ApiResponse.error(AppErrorKind.Internal, "服务内部错误", requestId)
    }
}


/**
 * 资源级鉴权的辅助逻辑。
 *
 * 抽成独立类而非塞进中间件闭包，原因：
 *   仓颉的 match 分支必须是**单个表达式**，不能写多行语句块；
 *   把判定逻辑放进方法里，中间件只需一行调用。
 */
public class MiddlewareGuards {
    /**
     * 判定请求涉及的资源是否可访问。
     *
     * @return 拒绝 → Some(403 响应)；允许 → None
     */
    public static func checkResource(
        auth: AuthContext,
        req: ApiRequest,
        access: UserAccess,
        requiredPerm: String,
        guard: ResourceGuard,
        userId: String
    ): Option<ApiResponse> {
        let resource = match (guard(req)) {
            case Some(r) => r
            case None => return None
        }
        let ctx = AccessContext(
            userId,
            access.perms.toArray(),
            access.subjectIds.toArray(),
            access.maxDataLevel,
            access.tenantId,
            ownedSubjectIds: access.ownedSubjectIds.toArray()
        )
        let authorizer = Authorizer(auth.grantLoader(userId))
        let decision = authorizer.authorize(
            ctx,
            requiredPerm,
            resource,
            Times.nowMillis()
        )
        match (decision.isAllowed()) {
            case true => return None
            case false => return Some(ApiResponse.error(
                AppErrorKind.Forbidden,
                "无权限访问该资源",
                req.requestId
            ))
        }
    }
}

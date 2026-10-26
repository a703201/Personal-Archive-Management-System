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
public class AuthContext {
    /** 令牌服务（签发与校验） */
    public let tokenService: TokenService
    /** 权限查询（拿用户权限点与角色） */
    public let permLoader: (String) -> (ArrayList<String>, ArrayList<String>)

    public init(
        tokenService: TokenService,
        permLoader: (String) -> (ArrayList<String>, ArrayList<String>)
    ) {
        this.tokenService = tokenService
        this.permLoader = permLoader
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
        // 取出匹配的路由以确定所需权限
        let path = ApiRequest.pathOf(req.url)
        var requiredPerm = ""
        var isPublic = false
        match (router.find(req.method, path)) {
            case Some((route, _)) =>
                requiredPerm = route.requiredPerm
                isPublic = route.isPublic
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
                        let (perms, roles) = auth.permLoader(payload.uid)
                        req.perms = perms
                        req.roles = roles
                        // 功能权限判定（安全章 §6.1 第 2 步）
                        if (!requiredPerm.isEmpty() && !perms.contains(requiredPerm)) {
                            return Some(ApiResponse.error(
                                AppErrorKind.Forbidden,
                                "无权限执行该操作",
                                req.requestId
                            ))
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

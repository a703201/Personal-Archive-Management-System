// ============================================================
// ams.api.middleware.tenantquota · 租户配额写路径闸门（统一入口）
//
// 为什么做成中间件：配额约束的是「创建」这个动作，而不是某个业务函数。
// 若分别改 item / user / attachment 三个服务的 create，写入语义会散落在
// 三处、难以一致地开关与压测；放在鉴权之后的单一中间件里，
// ① tenantId 已由鉴权链路填充；② 一处开关即可灰度/回退；
// ③ 新增创建端点时只需补一条路径规则。
//
// 超限时由 TenantQuotaGuard 抛 AppError(QuotaExceeded) → 对外
// `QUOTA_EXCEEDED` / HTTP 429，不返回 500，也不静默丢弃写入。
// ============================================================
package ams.api.middleware

import ams.api.http.*
import ams.data.repo.*

public class TenantQuotaMiddleware {
    /**
     * 判断一次请求是否属于受配额约束的创建动作（纯函数，可单测）。
     * 只认 POST；路径按 `/api` 前缀精确/前缀匹配，避免误伤查询与下载。
     */
    public static func quotaKindFor(method: String, url: String): ?QuotaKind {
        if (method.toAsciiUpper() != "POST") {
            return None
        }
        let parts = url.split("?")
        let path = if (parts.size > 0) { parts[0] } else { url }
        if (path == "/api/items" ||
            (path.startsWith("/api/items/") && path.endsWith("/clone"))) {
            return Some(QuotaKind.Items)
        }
        if (path == "/api/users" || path == "/api/auth/register") {
            return Some(QuotaKind.Users)
        }
        if (path.startsWith("/api/import/tasks")) {
            return Some(QuotaKind.Items)
        }
        if (path == "/api/attachments" || path.startsWith("/api/attachments/upload")) {
            return Some(QuotaKind.Storage)
        }
        return None
    }
}

/**
 * 构造配额闸门中间件。
 * Storage 按请求体字节计入增量；Users / Items 按「+1 条」计。
 */
public func tenantQuotaMiddleware(quotaGuard: TenantQuotaGuard): Middleware {
    return { req: ApiRequest =>
        match (TenantQuotaMiddleware.quotaKindFor(req.method, req.url)) {
            case Some(kind) =>
                let add = match (kind) {
                    case QuotaKind.Storage => req.bodyBytes.size
                    case _ => 0
                }
                quotaGuard.enforce(req.tenantId, kind, add)
            case None => ()
        }
        return None
    }
}

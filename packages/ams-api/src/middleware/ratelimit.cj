// ============================================================
// ams.api.middleware.ratelimit · 通用限流中间件（FR-EXP-007）
//
// 职责：在「请求ID → 访问日志 → **限流** → 鉴权」链中填补限流这一环。
//
// 默认按客户端 IP 做全局兜底（防接口被刷）；导出专属配额
// （5 次/小时、2000 条/天、高敏 24h ≤3 次、并发 2、≤5000 条/次）
// 由 ExportService 按用户精确计量，不属于本中间件职责。
//
// 超限返回 429（RateLimited），并带 Retry-After 头。
// ============================================================
package ams.api.middleware

import std.collection.*

import ams.api.http.*
import ams.kernel.error.*
import ams.kernel.time.*
import ams.security.ratelimit.*

/**
 * 通用限流中间件。
 *
 * @param limiter       共享限流器实例
 * @param perIpMax     单 IP 窗口内最大请求数（默认 300）
 * @param perIpWindowMillis 窗口长度（默认 60000ms）
 */
public func rateLimitMiddleware(
    limiter: RateLimiter,
    perIpMax!: Int64 = 300,
    perIpWindowMillis!: Int64 = 60000
): Middleware {
    return { req: ApiRequest =>
        let ip = if (req.remoteAddr.isEmpty()) { "unknown" } else { req.remoteAddr }
        let now = Times.nowMillis()
        let ok = limiter.allow("api:ip", ip, perIpMax, perIpWindowMillis, 1, now)
        if (!ok) {
            let h = HashMap<String, String>()
            h["Retry-After"] = "60"
            h["Content-Type"] = "application/json; charset=utf-8"
            return Some(ApiResponse(
                429,
                "{\"error\":\"RATE_LIMITED\",\"message\":\"请求过于频繁，请稍后再试\"}",
                h
            ))
        }
        return None
    }
}

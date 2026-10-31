// ============================================================
// ams.security.ratelimit · 进程内固定窗口限流器
//
// 供导出配额（FR-EXP-007）与通用限流中间件（FR-EXP-007 / 防滥用）共用。
//
// 设计约束（架构 §4.2 分层）：
//   - 位于 ams-security 之下，ams-app 与 ams-api 均可依赖，**不引入反向依赖**；
//   - 不依赖任何存储，纯内存定点计数；进程重启后计数归零
//     （导出为非高频操作，可接受；如需跨重启持久化再引入 Redis/DB）。
// ============================================================
package ams.security.ratelimit

import std.collection.*

/**
 * 单个命名限额的窗口状态（存于 HashMap，按引用共享，原地可改）。
 */
public class WindowState {
    public var start: Int64
    public var count: Int64

    public init(start: Int64, count: Int64) {
        this.start = start
        this.count = count
    }
}

/**
 * 固定窗口限流器。
 *
 * 一个实例可同时维护多个「限额名 × 维度键」的窗口。
 *
 * @param limitName 限额名（如 "export:hour" / "export:rows:day" / "export:high" / "api:ip"）
 * @param key       维度键（如用户 ID / 客户端 IP）
 * @param max       窗口内允许的最大额度
 * @param windowMillis 窗口长度（毫秒）
 * @param cost      本次消耗的额度（请求计数传 1，行数配额传本次行数）
 * @param now       当前毫秒时间戳（由调用方传入，便于测试与统一时钟）
 * @return true 放行并已计入；false 超限
 */
public class RateLimiter {
    private let windows: HashMap<String, WindowState> = HashMap<String, WindowState>()

    public init() {}

    public func allow(
        limitName: String,
        key: String,
        max: Int64,
        windowMillis: Int64,
        cost: Int64,
        now: Int64
    ): Bool {
        if (cost <= 0) {
            return true
        }
        // 单次花费超过上限 → 直接拒绝（如单次要导 5000 行但日限额仅 2000）
        if (cost > max) {
            return false
        }
        let k = "${limitName}:${key}"
        match (this.windows.get(k)) {
            case Some(w) =>
                // 窗口滑动：重置起点与计数
                if (now - w.start >= windowMillis) {
                    w.start = now
                    w.count = cost
                    return true
                }
                if (w.count + cost <= max) {
                    w.count = w.count + cost
                    return true
                }
                return false
            case None =>
                this.windows[k] = WindowState(now, cost)
                return true
        }
    }
}

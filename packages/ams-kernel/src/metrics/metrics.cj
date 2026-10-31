// ============================================================
// ams.kernel.metrics · 进程内运行指标（FR-CFG-005 系统健康看板支撑）
//
// 采集口径：
//   - 请求总数、4xx 数、5xx 数（自进程启动 / 上次 reset 起累计）
//   - 错误率以「千分比」返回（整数），避免在指标层引入浮点
//   - 指标**不落库**：它服务于「此刻是否健康」的运维判断，
//     历史趋势应由外部监控系统采集（设计约束见安全章 §6）
//
// 线程安全：HTTP 服务是多线程的，计数器一律在锁内读写。
//   （与 MemorySessionStore 一致，用 std.sync.ReentrantMutex，
//     不引原子类型 —— 本仓未使用过 AtomicInt64，避免 API 形态不确定。）
//
// 【为什么放 ams-kernel】
//   ams-api 的 server 负责记录，ams-app 的 SystemService 负责汇总，
//   两者都要读它；只有 ams-kernel 是二者的公共下层。
// ============================================================
package ams.kernel.metrics

import std.sync.*

import ams.kernel.time.*

/**
 * 运行指标采集器（进程内单例）。
 */
public class Metrics {
    private let lock = ReentrantMutex()

    private var totalRequests: Int64 = 0
    private var clientErrors: Int64 = 0
    private var serverErrors: Int64 = 0
    private var startedAtMs: Int64 = 0
    private var resetAtMs: Int64 = 0

    public init() {
        this.startedAtMs = Metrics.now()
        this.resetAtMs = this.startedAtMs
    }

    /**
     * 当前时间（毫秒）。
     *
     * 必须走 `Times.nowMillis()`：直接用 DateTime.now().toUnixTimeStamp()
     * 拿到的是**本地时间**对应的纪元毫秒，东八区会差 8 小时
     * （见 ams.kernel.time 的踩坑注释）。
     */
    private static func now(): Int64 {
        return Times.nowMillis()
    }

    /**
     * 记录一次请求的响应状态。
     */
    public func record(status: Int64): Unit {
        this.lock.lock()
        try {
            this.totalRequests += 1
            if (status >= 500) {
                this.serverErrors += 1
            } else if (status >= 400) {
                this.clientErrors += 1
            }
        } finally {
            this.lock.unlock()
        }
    }

    /**
     * 累计请求数。
     */
    public func requests(): Int64 {
        this.lock.lock()
        try {
            return this.totalRequests
        } finally {
            this.lock.unlock()
        }
    }

    /**
     * 4xx 数量（客户端错误：鉴权失败、参数非法、限流等）。
     */
    public func error4xx(): Int64 {
        this.lock.lock()
        try {
            return this.clientErrors
        } finally {
            this.lock.unlock()
        }
    }

    /**
     * 5xx 数量（服务端错误：DB 异常、内部错误等）。
     */
    public func error5xx(): Int64 {
        this.lock.lock()
        try {
            return this.serverErrors
        } finally {
            this.lock.unlock()
        }
    }

    /**
     * 服务端错误率（千分比，整数）。
     *
     * 只看 5xx：4xx 多半是调用方问题（口令错、参数缺），
     * 计入「健康度」会掩盖真正的服务端故障。
     */
    public func serverErrorPermille(): Int64 {
        this.lock.lock()
        try {
            if (this.totalRequests <= 0) {
                return 0
            }
            return (this.serverErrors * 1000) / this.totalRequests
        } finally {
            this.lock.unlock()
        }
    }

    /**
     * 进程启动时刻。
     */
    public func startedAt(): Int64 {
        return this.startedAtMs
    }

    /**
     * 上次清零时刻（看板用它换算「统计窗口」）。
     */
    public func windowStart(): Int64 {
        return this.resetAtMs
    }

    /**
     * 清零计数（运维手工重置统计窗口）。
     */
    public func reset(): Unit {
        this.lock.lock()
        try {
            this.totalRequests = 0
            this.clientErrors = 0
            this.serverErrors = 0
            this.resetAtMs = Metrics.now()
        } finally {
            this.lock.unlock()
        }
    }
}

/**
 * 进程内唯一实例。
 *
 * 与 Log.get() 同形态：包级可变静态变量 + 访问器，
 * 免得把 Metrics 实例一路透传到 server / 各路由。
 */
private var globalMetrics: Metrics = Metrics()

/**
 * 取全局指标采集器。
 */
public func metrics(): Metrics {
    return globalMetrics
}

// ============================================================
// ams-kernel.id · 雪花 ID 生成
//
// 选型理由（架构 §2.1 / 数据模型 §2.2）：
//   - 分布式无中心发号器
//   - 时间有序，便于按 ID 范围归档
//   - 比 UUID 短（8 字节）
//
// [注意] 雪花 ID 超出 JS Number.MAX_SAFE_INTEGER，
//   传给前端时必须转字符串（开发规范 §7.3）。
//
// 实测 API（SDK 1.0.5）：
//   - 当前毫秒：DateTime.now().toUnixTimeStamp().toMilliseconds()
//   - 互斥锁：Mutex 的 lock() / unlock()（**没有** synchronized 函数）
// ============================================================
package ams.kernel.id

import std.sync.*

import ams.kernel.error.*
import ams.kernel.time.*

/**
 * 雪花 ID 生成器（线程安全）。
 *
 * 位布局（64 bit）：
 *   1 位符号位(0) | 41 位时间戳(ms) | 5 位数据中心 | 5 位序列 | 12 位序列内计数
 */
public class SnowflakeIdGenerator {
    /** 起始纪元：2024-01-01T00:00:00Z 的毫秒数 */
    private static let EPOCH: Int64 = 1704067200000

    /** 序列掩码（12 bit） */
    private static let SEQUENCE_MASK: Int64 = 4095

    /** 工作节点位移（5 bit） */
    private static let WORKER_SHIFT: Int64 = 17

    /** 时间戳位移（22 bit：5 位节点 + 12 位序列 + 5 位保留） */
    private static let TIMESTAMP_SHIFT: Int64 = 22

    private let workerId: Int64
    private let lock: Mutex

    private var lastTimestamp: Int64 = -1
    private var sequence: Int64 = 0

    /**
     * @param workerId 工作节点 ID（0~31）
     */
    public init(workerId: Int64) {
        if (workerId < 0 || workerId > 31) {
            throw IllegalArgumentException("workerId 必须在 0~31 之间")
        }
        this.workerId = workerId
        this.lock = Mutex()
    }

    /**
     * 生成下一个 ID。
     */
    public func next(): Int64 {
        this.lock.lock()
        try {
            return this.doNext()
        } finally {
            this.lock.unlock()
        }
    }

    private func doNext(): Int64 {
        var ts = SnowflakeIdGenerator.currentMillis()

        if (ts < this.lastTimestamp) {
            // 时钟回拨：等待追平，避免生成重复 ID
            var waited = 0
            while (waited < 10000 && currentMillis() < this.lastTimestamp) {
                Times.sleepMillis(1)   // 1 ms
                waited += 1
            }
            ts = currentMillis()
            if (ts < this.lastTimestamp) {
                throw AppError(AppErrorKind.Internal, "时钟回拨过大，无法生成 ID")
            }
        }

        if (ts == this.lastTimestamp) {
            this.sequence = (this.sequence + 1) & SnowflakeIdGenerator.SEQUENCE_MASK
            if (this.sequence == 0) {
                // 同一毫秒内序列耗尽，等待下一毫秒
                while (ts <= this.lastTimestamp) {
                    Times.sleepMillis(1)
                    ts = currentMillis()
                }
            }
        } else {
            this.sequence = 0
        }

        this.lastTimestamp = ts

        let elapsed = ts - SnowflakeIdGenerator.EPOCH
        return (elapsed << SnowflakeIdGenerator.TIMESTAMP_SHIFT) |
               (this.workerId << SnowflakeIdGenerator.WORKER_SHIFT) |
               this.sequence
    }

    /**
     * 当前 Unix 毫秒时间戳。
     */
    public static func currentMillis(): Int64 {
        return Times.nowMillis()
    }
}

/**
 * 全局 ID 生成器（单例）。workerId 由部署配置注入。
 */
public class Ids {
    private static var generator: ?SnowflakeIdGenerator = None

    /**
     * 初始化全局生成器。
     */
    public static func setup(workerId: Int64): Unit {
        Ids.generator = Some(SnowflakeIdGenerator(workerId))
    }

    /**
     * 取下一个 ID。未初始化时抛错（fail-fast，避免静默用 0）。
     */
    public static func next(): Int64 {
        match (Ids.generator) {
            case Some(g) => return g.next()
            case None => throw AppError(AppErrorKind.Internal, "ID 生成器未初始化")
        }
    }

    /**
     * 生成 ID 的字符串形式（传给前端时用这个，避免 JS 精度丢失）。
     */
    public static func nextString(): String {
        return Ids.next().toString()
    }
}

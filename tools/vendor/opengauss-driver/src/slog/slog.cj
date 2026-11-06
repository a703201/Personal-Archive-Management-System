/**
 * Copyright (c) [2022] Huawei Technologies Co., Ltd.
 * [opengauss-driver] is licensed under Mulan PSL v2.
 * You can use this software according to the terms and conditions of the Mulan PSL v2.
 * You may obtain a copy of the Mulan PSL v2 at:
 *            http://license.coscl.org.cn/MulanPSL2
 * THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS,
 * WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED,
 * INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
 * See the Mulan PSL v2 for more details.
 *
 * ============================ 适配说明（AMS 项目本地补丁） ============================
 *
 * 背景：
 *   原实现依赖 stdx.log / stdx.logger 的 `Logger` 接口与全局 `logger` 变量。
 *   stdx 1.2.0（配合仓颉 SDK 1.2.0 STS）对该接口做了**破坏性变更**：
 *     - 全局 `logger` 变量被移除，改为 `getGlobalLogger()` / `setGlobalLogger()`；
 *     - `Logger` 接口的方法集由 `log(record: LogRecord)` 改为
 *       `log(level, message, attrs)`，`LogRecord` / `LogValue` 的构造方式亦变；
 *     - 旧的 `Logger` 实现（SimpleLogger 等）签名不兼容，
 *       导致 `HashMap<String,String>` 走 LogValue 转换时抛
 *       "extensionData is nullptr, itf: stdx.serialization.serialization:Serializable<...>"。
 *
 *   后果：驱动在 stdx 1.2.0 下**编译通过但运行时崩溃**（connect 阶段即中止）。
 *
 * 处置：
 *   本文件改为**自包含的最小日志实现**，不再依赖 stdx.log / stdx.logger。
 *   驱动全仓只用到 3 个级别方法（debug / warn / error）与 level 属性，
 *   自实现成本远低于适配上游破坏性变更，且让驱动与 stdx 版本解耦
 *   （后续 stdx 再升级也不会影响数据库驱动）。
 *
 *   保留原有对外接口：
 *     - `Default(): Logger`      取全局 logger
 *     - `setDefault(l: Logger)`  替换全局 logger
 *     - `Logger` 的 debug/info/warn/error/trace/fatal 与 level 属性
 *   其余驱动包（chunkreader / driver / interx / pgconn / proto3 / sema /
 *   sqlpool / tinypool / url）均只通过 `slog.Default()` 获取 logger，无需改动。
 *
 * 行为：
 *   - 默认级别 INFO，DEBUG 级别不输出（与原 SimpleLogger 默认行为一致，
 *     也避免驱动连接期产生大量日志噪声）；
 *   - 输出到 stdout，格式：`[LEVEL] message`；
 *   - 线程安全（用 Mutex 保护写操作）。
 * ==================================================================================
 */
package cangjie_tpc::opengauss.slog

import std.sync.*

/**
 * 日志级别。数值越大越严重，与原 stdx.log 的比较语义一致。
 */
public enum LogLevel {
    | Trace
    | Debug
    | Info
    | Warn
    | Error
    | Fatal
    | Off

    /**
     * 级别序号（供大小比较）。
     */
    public func toInt(): Int64 {
        match (this) {
            case LogLevel.Trace => return 0
            case LogLevel.Debug => return 1
            case LogLevel.Info => return 2
            case LogLevel.Warn => return 3
            case LogLevel.Error => return 4
            case LogLevel.Fatal => return 5
            case LogLevel.Off => return 6
        }
    }

    /**
     * 级别名（用于输出前缀）。
     */
    public func label(): String {
        match (this) {
            case LogLevel.Trace => return "TRACE"
            case LogLevel.Debug => return "DEBUG"
            case LogLevel.Info => return "INFO"
            case LogLevel.Warn => return "WARN"
            case LogLevel.Error => return "ERROR"
            case LogLevel.Fatal => return "FATAL"
            case LogLevel.Off => return "OFF"
        }
    }

    /**
     * 级别比较（>=）。
     *
     * 说明：仓颉的 enum **不支持** `>=` 等比较运算符
     *（编译报 "invalid binary operator '>=' on type 'Enum-LogLevel'"），
     * 故显式提供比较方法，调用方改为 `logger.level.ge(LogLevel.Debug)`。
     */
    public func ge(other: LogLevel): Bool {
        return this.toInt() >= other.toInt()
    }

    /**
     * 级别比较（>）。
     */
    public func gt(other: LogLevel): Bool {
        return this.toInt() > other.toInt()
    }

    /**
     * 级别比较（<=）。
     */
    public func le(other: LogLevel): Bool {
        return this.toInt() <= other.toInt()
    }

    /**
     * 级别比较（<）。
     */
    public func lt(other: LogLevel): Bool {
        return this.toInt() < other.toInt()
    }

    /**
     * 级别相等。
     */
    public func eq(other: LogLevel): Bool {
        return this.toInt() == other.toInt()
    }
}

/**
 * 日志器接口。
 *
 * 与驱动其余代码的使用方式保持一致：
 *   logger.debug("...") / logger.warn("...") / logger.error("...")
 *   logger.level >= LogLevel.Debug
 */
public interface Logger {
    /**
     * 写一条日志。
     */
    func log(level: LogLevel, message: String): Unit

    /**
     * TRACE 级别日志。
     */
    func trace(message: String): Unit {
        this.log(LogLevel.Trace, message)
    }

    /**
     * DEBUG 级别日志。
     */
    func debug(message: String): Unit {
        this.log(LogLevel.Debug, message)
    }

    /**
     * INFO 级别日志。
     */
    func info(message: String): Unit {
        this.log(LogLevel.Info, message)
    }

    /**
     * WARN 级别日志。
     */
    func warn(message: String): Unit {
        this.log(LogLevel.Warn, message)
    }

    /**
     * ERROR 级别日志。
     */
    func error(message: String): Unit {
        this.log(LogLevel.Error, message)
    }

    /**
     * FATAL 级别日志。
     */
    func fatal(message: String): Unit {
        this.log(LogLevel.Fatal, message)
    }

    /**
     * 当前最低输出级别。
     */
    mut prop level: LogLevel

    /**
     * 是否已关闭。
     */
    func isClosed(): Bool {
        return false
    }

    /**
     * 关闭日志器。
     */
    func close(): Unit {
        ()
    }
}

/**
 * 简单控制台日志器。
 *
 * 写操作加锁，保证多线程下不交错。
 */
public class SimpleLogger <: Logger {
    private let lock = Mutex()
    private var minLevel: LogLevel = LogLevel.Info
    private var closed: Bool = false

    public init() {
        // 默认 INFO：驱动连接期 DEBUG 日志量很大，默认不输出
        this.minLevel = LogLevel.Info
    }

    public init(minLevel: LogLevel) {
        this.minLevel = minLevel
    }

    public mut prop level: LogLevel {
        get() {
            return this.minLevel
        }
        set(value) {
            this.minLevel = value
        }
    }

    public func log(level: LogLevel, message: String): Unit {
        if (this.closed) {
            return
        }
        if (level.toInt() < this.minLevel.toInt()) {
            return
        }
        this.lock.lock()
        try {
            println("[${level.label()}] ${message}")
        } finally {
            this.lock.unlock()
        }
    }

    public func isClosed(): Bool {
        return this.closed
    }

    public func close(): Unit {
        this.lock.lock()
        try {
            this.closed = true
        } finally {
            this.lock.unlock()
        }
    }
}

/**
 * 全局日志器持有者。
 *
 * 说明：AtomicReference 的类型参数要求是 Object 子类，
 * 而 Logger 是接口（接口在仓颉里不是 Object 子类），
 * 故这里用「可变静态字段 + Mutex」实现线程安全的读写。
 */
public class LoggerWrapper {
    private static let lock = Mutex()
    private static var current: Logger = SimpleLogger()

    /**
     * 读取当前全局日志器。
     */
    public static func get(): Logger {
        LoggerWrapper.lock.lock()
        try {
            return LoggerWrapper.current
        } finally {
            LoggerWrapper.lock.unlock()
        }
    }

    /**
     * 替换全局日志器。
     */
    public static func set(l: Logger): Unit {
        LoggerWrapper.lock.lock()
        try {
            LoggerWrapper.current = l
        } finally {
            LoggerWrapper.lock.unlock()
        }
    }
}

/**
 * 取当前全局日志器。
 */
public func Default(): Logger {
    return LoggerWrapper.get()
}

/**
 * 替换全局日志器。
 */
public func setDefault(l: Logger): Unit {
    LoggerWrapper.set(l)
}

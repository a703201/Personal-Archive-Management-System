// ============================================================
// ams.kernel.log · 结构化日志
//
// 规约（开发规范 §4.3）：
//   - 业务代码禁止 println / print，统一走本包
//   - 日志字段用 camelCase，值不做字符串拼接
//   - 敏感字段必须用 SensitiveValue 包装，输出时自动脱敏
//   - 级别：ERROR(需人工介入) / WARN(可自愈) / INFO(关键业务事件)
//           / DEBUG(开发) / TRACE(极端调试，默认关闭)
//
// [为什么自己实现输出而不用 stdx.log]
//   实测 SDK 1.0.5 的 stdx.log 默认**不向 stdout 输出**（需额外配置
//   LogWriter 与 Logger.set），而其 LogWriter / LogValue 的构造 API
//   在当前版本不易稳定使用。为避免日志"写了但看不到"，此处自行实现
//   JSON Lines 输出（每行一条 JSON），保证：
//     - 结构化、可被日志采集器直接解析
//     - 无外部依赖、行为确定
//   后续如需接入 stdx.log 或其他采集器，只需替换 writeLine 实现。
//
// [实测踩坑要点]
//   ① DateTime.now().toUnixTimeStamp().toMilliseconds() 返回的是
//      **本地时间**对应的纪元毫秒（东八区偏 8 小时），不能直接当 Unix
//      时间戳用。正确做法：取本地时刻的墙上时间 + 时区偏移，parse 回该
//      时刻后再取纪元毫秒。
//   ② String 的 s[i] 是**字节**下标，中文是 UTF-8 多字节，按字节遍历
//      会得到非法序列（报 "Invalid utf8 byte sequence"）。必须用
//      **runes()** 按 Unicode 码点遍历。
//   ③ Rune 无 toUInt32 等转码点整数的方法，故按字符字面量比较。
// ============================================================
package ams.kernel.log

import std.collection.*
import std.time.*

/**
 * 日志级别。默认 INFO，DEBUG/TRACE 需显式开启。
 */
public enum LogLevel {
    | Trace
    | Debug
    | Info
    | Warn
    | Error
    | Fatal
}

/**
 * 敏感值包装。输出时替换为 ***(fingerprint:xxxx)，保留可关联性但不泄漏原文。
 */
public class SensitiveValue {
    private let raw: String
    private let fingerprint: String

    public init(raw: String) {
        this.raw = raw
        // 指纹用原文长度的派生量，够用且不泄漏内容
        this.fingerprint = "len${raw.size}"
    }

    /** 脱敏后的展示串 */
    public func masked(): String {
        return "***(fingerprint:${this.fingerprint})"
    }

    /** 原始值。仅在确需使用时（如加密前）取用，禁止写日志。 */
    public func reveal(): String {
        return this.raw
    }
}

/**
 * 日志上下文。承载 traceId 等贯穿一次请求的字段。
 */
public class LogContext {
    public let traceId: String
    public let userId: String

    public init(traceId!: String = "", userId!: String = "") {
        this.traceId = traceId
        this.userId = userId
    }
}

/**
 * 全局日志器。输出 JSON Lines（每行一条 JSON）到标准输出。
 */
public class Log {
    private static var instance: Log = Log()

    private var minLevel: LogLevel = LogLevel.Info

    private init() {
    }

    /**
     * 获取全局日志器。
     */
    public static func get(): Log {
        return Log.instance
    }

    /**
     * 设置最低输出级别。低于此级别的日志被丢弃。
     */
    public func setMinLevel(level: LogLevel): Unit {
        this.minLevel = level
    }

    /**
     * 当前最低输出级别。
     */
    public func getMinLevel(): LogLevel {
        return this.minLevel
    }

    private func shouldLog(level: LogLevel): Bool {
        return Log.levelValue(level) >= Log.levelValue(this.minLevel)
    }

    private static func levelValue(level: LogLevel): Int64 {
        match (level) {
            case LogLevel.Trace => 0
            case LogLevel.Debug => 1
            case LogLevel.Info => 2
            case LogLevel.Warn => 3
            case LogLevel.Error => 4
            case LogLevel.Fatal => 5
        }
    }

    private static func levelName(level: LogLevel): String {
        match (level) {
            case LogLevel.Trace => "TRACE"
            case LogLevel.Debug => "DEBUG"
            case LogLevel.Info => "INFO"
            case LogLevel.Warn => "WARN"
            case LogLevel.Error => "ERROR"
            case LogLevel.Fatal => "FATAL"
        }
    }

    /**
     * 写一条结构化日志。
     *
     * @param level 日志级别
     * @param action 动作码，如 "archive.item.created"
     * @param ctx 请求上下文（可空）
     * @param fields 附加字段，键为 camelCase
     */
    public func log(
        level: LogLevel,
        action: String,
        ctx: ?LogContext,
        fields: Array<(String, String)>
    ): Unit {
        if (!this.shouldLog(level)) {
            return
        }

        // 注意：StringBuilder.append 返回 Unit，**不能链式调用**
        var sb = StringBuilder()
        sb.append("{\"ts\":\"")
        sb.append(Log.isoNow())
        sb.append("\",")
        sb.append("\"level\":\"")
        sb.append(Log.levelName(level))
        sb.append("\",")
        sb.append("\"action\":\"")
        sb.append(Log.escape(action))
        sb.append("\"")

        match (ctx) {
            case Some(c) =>
                if (c.traceId != "") {
                    sb.append(",\"traceId\":\"")
                    sb.append(Log.escape(c.traceId))
                    sb.append("\"")
                }
                if (c.userId != "") {
                    sb.append(",\"uid\":\"")
                    sb.append(Log.escape(c.userId))
                    sb.append("\"")
                }
            case None => ()
        }

        for ((k, v) in fields) {
            sb.append(",\"")
            sb.append(Log.escape(k))
            sb.append("\":\"")
            sb.append(Log.escape(v))
            sb.append("\"")
        }
        sb.append("}")

        Log.writeLine(sb.toString())
    }

    // ---- 便捷方法 ----

    public func trace(action: String, ctx: ?LogContext, fields: Array<(String, String)>): Unit {
        this.log(LogLevel.Trace, action, ctx, fields)
    }

    public func debug(action: String, ctx: ?LogContext, fields: Array<(String, String)>): Unit {
        this.log(LogLevel.Debug, action, ctx, fields)
    }

    public func info(action: String, ctx: ?LogContext, fields: Array<(String, String)>): Unit {
        this.log(LogLevel.Info, action, ctx, fields)
    }

    public func warn(action: String, ctx: ?LogContext, fields: Array<(String, String)>): Unit {
        this.log(LogLevel.Warn, action, ctx, fields)
    }

    public func error(action: String, ctx: ?LogContext, fields: Array<(String, String)>): Unit {
        this.log(LogLevel.Error, action, ctx, fields)
    }

    public func fatal(action: String, ctx: ?LogContext, fields: Array<(String, String)>): Unit {
        this.log(LogLevel.Fatal, action, ctx, fields)
    }

    // ---- 内部实现 ----

    /**
     * 输出一行日志到标准输出。
     *
     * 单独抽成方法，便于后续替换为文件 / 网络采集器。
     */
    private static func writeLine(line: String): Unit {
        println(line)
    }

    /**
     * 当前时间的 ISO-8601 UTC 字符串（带毫秒）。
     *
     * 时区处理：DateTime.now().toString() 形如
     * "2026-10-25T13:43:05.1509074+08:00"（本地时间 + 时区偏移）。
     * 取其「墙上时间 + 时区」重新 parse，得到该时刻，再取纪元毫秒 ——
     * 这才是真正的 UTC 纪元毫秒。
     */
    private static func isoNow(): String {
        let s = DateTime.now().toString()
        let wall = s[0..19]                       // 2026-10-25T13:43:05
        let ms = DateTime.parse("${wall}${Log.timeZoneOf(s)}")
            .toUnixTimeStamp().toMilliseconds()
        return Log.toIsoUtc(ms)
    }

    /**
     * Unix 毫秒 → ISO-8601 UTC 字符串（纯算术，无时区歧义）。
     *
     * 算法：civil-from-days（Howard Hinnant）。
     */
    private static func toIsoUtc(ms: Int64): String {
        let msPerDay: Int64 = 86400000
        var days = ms / msPerDay
        var rest = ms % msPerDay
        if (rest < 0) {
            rest += msPerDay
            days -= 1
        }
        let (year, month, day) = Log.civilFromDays(days)
        let hour = rest / 3600000
        let minute = (rest % 3600000) / 60000
        let second = (rest % 60000) / 1000
        let milli = rest % 1000
        return "${year}-${Log.pad2(month)}-${Log.pad2(day)}T" +
               "${Log.pad2(hour)}:${Log.pad2(minute)}:${Log.pad2(second)}.${Log.pad3(milli)}Z"
    }

    /**
     * 从 DateTime.toString() 中提取时区偏移（如 "+08:00"）。
     */
    private static func timeZoneOf(s: String): String {
        for (i in 11..s.size) {
            let c = s[i]
            if (c == 43u8 || c == 45u8) {   // '+' or '-'
                return s[i..s.size]
            }
        }
        return "Z"
    }

    /**
     * 天数 → 年月日（civil-from-days，Howard Hinnant 算法）。
     */
    private static func civilFromDays(z0: Int64): (Int64, Int64, Int64) {
        var z = z0 + 719468
        let era = (if (z >= 0) { z } else { z - 146096 }) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (if (mp < 10) { 3 } else { -9 })
        let year = y + (if (m <= 2) { 1 } else { 0 })
        return (year, m, d)
    }

    private static func pad2(v: Int64): String {
        if (v < 10) {
            return "0${v}"
        }
        return v.toString()
    }

    private static func pad3(v: Int64): String {
        if (v < 10) {
            return "00${v}"
        } else if (v < 100) {
            return "0${v}"
        }
        return v.toString()
    }

    /**
     * JSON 字符串转义。
     */
    private static func escape(s: String): String {
        var out = StringBuilder()
        // 必须用 **runes()** 按 Unicode 码点遍历：
        //   - s[i] 是**字节**下标，中文是 UTF-8 多字节，按字节切分会得到
        //     非法序列（实测报 "Invalid utf8 byte sequence"）
        //   - s[i..(i+1)] 同样是按字节切分，对中文无效
        // Rune 无转码点整数的方法，故按字符字面量比较。
        for (r in s.runes()) {
            let ch = r.toString()
            if (ch == "\"") {
                out.append("\\\"")
            } else if (ch == "\\") {
                out.append("\\\\")
            } else if (ch == "\n") {
                out.append("\\n")
            } else if (ch == "\r") {
                out.append("\\r")
            } else if (ch == "\t") {
                out.append("\\t")
            } else {
                out.append(ch)
            }
        }
        return out.toString()
    }
}

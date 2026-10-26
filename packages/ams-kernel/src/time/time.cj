// ============================================================
// ams-kernel.time · 时间处理
//
// 规约（开发规范 §7.3）：
//   - 存储统一 UTC，展示层本地化
//   - 对外 JSON 用 ISO-8601 UTC（带 Z）
//   - 内部用 Unix 毫秒时间戳
//
// [注意] 为什么用纯算术而不是 std.time：
//   实测 SDK 1.0.5 中：
//   - DateTime 的 month 是枚举、**没有公开的 day 字段**
//   - getDate / getTime / toUnixTimeStamp 都是包内私有
//   - **Duration 没有公开构造器**（只有 Duration.Zero）
//   -> 无法稳定地把「Unix 毫秒」换算成「年月日时分秒」。
//   故此处用标准的 civil-from-days 算法自行换算，**不依赖 std.time**，
//   好处是行为完全确定、可单测、无时区歧义（纯 UTC）。
//
//   仅用 std.time 做一件事：取「当前时刻的 Unix 毫秒」。
// ============================================================
package ams.kernel.time

import std.time.*

/**
 * 时间工具。统一 UTC 存储与 ISO-8601 格式化（纯 UTC，无时区歧义）。
 */
public class Times {
    /** 一天的毫秒数 */
    private static let MS_PER_DAY: Int64 = 86400000

    /** 一小时的毫秒数 */
    private static let MS_PER_HOUR: Int64 = 3600000

    /** 一分钟的毫秒数 */
    private static let MS_PER_MINUTE: Int64 = 60000

    /** 一秒的毫秒数 */
    private static let MS_PER_SECOND: Int64 = 1000

    /**
     * 当前 Unix 毫秒时间戳。
     */
    public static func nowMillis(): Int64 {
        // 注意：DateTime.now().toUnixTimeStamp().toMilliseconds() 返回的是
        // **本地时间**对应的纪元毫秒（比 UTC 纪元偏移一个时区差），
        // 直接当 Unix 时间戳用会差 8 小时（东八区）。
        // 正确做法：先把当前本地时刻格式化成带时区偏移的字符串，
        //           再从该字符串取其**UTC 时刻**，最后取纪元毫秒。
        let local = DateTime.now()
        let s = local.toString()
        // 形如 2026-10-25T13:43:05.5528085+08:00
        // 取「墙上时间 + 毫秒」：s[0..23] = 2026-10-25T13:43:05.552
        // 注意不能只取到秒（s[0..19]）—— 那会把毫秒抹掉，
        // 导致两次取值差为 0（毫秒级计时断言会失败）。
        let wall = s[0..23]
        // 用带时区偏移的字符串构造，parse 后即为该时刻
        let withZone = "${wall}${Times.timeZoneOf(s)}"
        return DateTime.parse(withZone).toUnixTimeStamp().toMilliseconds()
    }

    /**
     * 从 DateTime.toString() 中提取时区偏移（如 "+08:00"）。
     *
     * 形如 "2026-10-25T13:43:05.1509074+08:00"，
     * 时区部分从第 10 个字符之后的第一个 '+' 或 '-' 开始。
     */
    public static func timeZoneOf(s: String): String {
        for (i in 11..s.size) {
            let c = s[i]
            if (c == 43u8 || c == 45u8) {   // '+' or '-'
                return s[i..s.size]
            }
        }
        return "Z"
    }

    /**
     * 当前时间的 ISO-8601 UTC 字符串（形如 2026-10-25T00:31:05.641Z）。
     */
    public static func nowIso8601(): String {
        return Times.toIso8601(Times.nowMillis())
    }

    /**
     * Unix 毫秒 -> ISO-8601 UTC 字符串。
     *
     * 例：1792859693002 -> "2026-10-25T00:34:53.002Z"
     */
    public static func toIso8601(millis: Int64): String {
        // 向下取整到天，负数也要正确处理
        var days = millis / Times.MS_PER_DAY
        var rest = millis % Times.MS_PER_DAY
        if (rest < 0) {
            rest += Times.MS_PER_DAY
            days -= 1
        }

        let (year, month, day) = Times.civilFromDays(days)

        let hour = rest / Times.MS_PER_HOUR
        let minute = (rest % Times.MS_PER_HOUR) / Times.MS_PER_MINUTE
        let second = (rest % Times.MS_PER_MINUTE) / Times.MS_PER_SECOND
        let milli = rest % Times.MS_PER_SECOND

        return "${year}-${Times.pad2(month)}-${Times.pad2(day)}" +
               "T${Times.pad2(hour)}:${Times.pad2(minute)}:${Times.pad2(second)}" +
               ".${Times.pad3(milli)}Z"
    }

    /**
     * ISO-8601 UTC 字符串 -> Unix 毫秒时间戳。
     *
     * 支持形如 "2026-10-25T00:34:53.002Z" 的输入。
     */
    public static func fromIso8601(iso: String): Int64 {
        if (iso.size < 19) {
            throw IllegalArgumentException("ISO-8601 字符串长度不足：${iso}")
        }

        let year = Times.parseNum(iso, 0, 4)
        let month = Times.parseNum(iso, 5, 7)
        let day = Times.parseNum(iso, 8, 10)
        let hour = Times.parseNum(iso, 11, 13)
        let minute = Times.parseNum(iso, 14, 16)
        let second = Times.parseNum(iso, 17, 19)

        var millis = Times.daysFromCivil(year, month, day) * Times.MS_PER_DAY
        millis += hour * Times.MS_PER_HOUR
        millis += minute * Times.MS_PER_MINUTE
        millis += second * Times.MS_PER_SECOND

        // 毫秒部分（形如 ".002Z"）
        if (iso.size >= 23 && iso[19] == 46) {   // '.'
            millis += Times.parseNum(iso, 20, 23)
        }

        return millis
    }

    /**
     * 睡眠指定毫秒数。
     *
     * 用 MonoTime 之差得到 Duration（Duration 无公开构造器），
     * 比较其毫秒值即可，无需构造。
     */
    public static func sleepMillis(millis: Int64): Unit {
        let start = MonoTime.now()
        while ((MonoTime.now() - start).toMilliseconds() < millis) {
            // 忙等，避免依赖线程调度 API
        }
    }

    /**
     * 天数 -> 年月日（civil from days，Howard Hinnant 算法）。
     *
     * 天数从 1970-01-01 起算，可为负。
     */
    private static func civilFromDays(z0: Int64): (Int64, Int64, Int64) {
        var z = z0
        z += 719468
        let era = (if (z >= 0) { z } else { z - 146096 }) / 146097
        let doe = z - era * 146097                                     // [0, 146096]
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365 // [0, 399]
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)             // [0, 365]
        let mp = (5 * doy + 2) / 153                                   // [0, 11]
        let d = doy - (153 * mp + 2) / 5 + 1                          // [1, 31]
        let m = mp + (if (mp < 10) { 3 } else { -9 })                  // [1, 12]
        let year = y + (if (m <= 2) { 1 } else { 0 })
        return (year, m, d)
    }

    /**
     * 年月日 -> 天数（days from civil，Howard Hinnant 算法）。
     */
    private static func daysFromCivil(y0: Int64, m: Int64, d: Int64): Int64 {
        let y = y0 - (if (m <= 2) { 1 } else { 0 })
        let era = (if (y >= 0) { y } else { y - 399 }) / 400
        let yoe = y - era * 400
        let mp = m + (if (m > 2) { -3 } else { 9 })
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    /**
     * 年月日 -> 天数（公开包装，供测试与日历计算使用）。
     */
    public static func daysFromCivilForTest(year: Int64, month: Int64, day: Int64): Int64 {
        return Times.daysFromCivil(year, month, day)
    }

    /**
     * 天数 -> 年月日（公开包装，供测试与日历计算使用）。
     */
    public static func civilFromDaysForTest(days: Int64): (Int64, Int64, Int64) {
        return Times.civilFromDays(days)
    }

    /**
     * 从字符串的 [start, end) 区间解析数字（非数字即停止）。
     */
    private static func parseNum(s: String, start: Int64, end: Int64): Int64 {
        if (s.size < end) {
            return 0
        }
        let slice = s[start..end]
        var v: Int64 = 0
        for (i in 0..slice.size) {
            let c = slice[i]
            if (c >= 48u8 && c <= 57u8) {     // '0'..'9'
                v = v * 10 + (Int64(c) - 48)
            } else {
                return v
            }
        }
        return v
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
}

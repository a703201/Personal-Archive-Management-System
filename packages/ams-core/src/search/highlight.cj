// ============================================================
// ams.core.search · 检索命中高亮片段
//
// 覆盖：FR-SRC-001「关键词全文检索」的补遗 —— 高亮片段。
//
// 【设计约束】
//   ① 按 **UTF-8 字符边界** 切分，绝不用 String 字节下标做切片：
//      仓颉的 `s[i]` 取回的是单个字节，中文被逐字节切碎后会抛
//      `Invalid utf8 byte sequence`（与 `Masker.mask` 踩过的坑同源）。
//   ② 返回「分段数组」而不是拼好 <mark> 的 HTML —— 前端用 v-for
//      渲染 <mark>，从根上消除 v-html 的 XSS 面。
//   ③ 本类只做纯粹的字符串分段，**不接触任何敏感字段**。调用方
//      （SearchRoutes）只把已允许明文返回的字段传进来；敏感度 >= 2
//      的 issuer 等字段一律不参与高亮，避免通过片段反推掩码内容。
//   ④ 长文本以首个命中为中心开窗（MAX_CHARS），避免把整个档案标题
//      塞进响应；首尾截断处补省略号段（hit=false）。
//   ⑤ 大小写不敏感仅针对 ASCII（中文无大小写），不引入 Unicode
//      大小写折叠表，行为可预测。
// ============================================================
package ams.core.search

import std.collection.*

/**
 * 高亮分段。`hit=true` 的段由前端渲染为 `<mark>`。
 */
public class HighlightSegment {
    public let text: String
    public let hit: Bool

    public init(text: String, hit: Bool) {
        this.text = text
        this.hit = hit
    }
}

/**
 * 把一段文本按关键词切成「命中 / 未命中」交替的片段。
 */
public class SearchHighlighter {
    /** 单词条高亮片段的最大字符数（中文按字符计，不是字节） */
    public static let MAX_CHARS: Int64 = 120
    /** 开窗时首个命中之前保留的上下文字符数 */
    private static let CONTEXT_BEFORE: Int64 = 24

    /**
     * 生成分段。
     *
     * - keyword 为空 / text 为空 → 返回单段原文（未命中），保证前端渲染稳定。
     * - 完整 keyword 有命中 → 高亮全部命中区间。
     * - 完整 keyword 无命中但 text 含 keyword 的单字 → 对齐后端
     *   「单字查询自动回退 LIKE」的语义，高亮这些单字（最多 8 处）。
     * - 无命中 → 单段原文。
     */
    public static func segments(text: String, keyword: String): Array<HighlightSegment> {
        if (text.isEmpty()) {
            return [HighlightSegment("", false)]
        }
        if (keyword.isEmpty()) {
            return [HighlightSegment(text, false)]
        }

        let cs = SearchHighlighter.chars(text)
        let ks = SearchHighlighter.chars(keyword)
        if (cs.size == 0 || ks.size == 0) {
            return [HighlightSegment(text, false)]
        }

        // ---- 1. 找命中区间（左闭右开，单位为「字符」）----
        var ranges = SearchHighlighter.matchAll(cs, ks)
        if (ranges.size == 0) {
            ranges = SearchHighlighter.matchChars(cs, ks)
        }
        if (ranges.size == 0) {
            return [HighlightSegment(text, false)]
        }

        // ---- 2. 长文本开窗：以首个命中为中心 ----
        var start: Int64 = 0
        var end: Int64 = cs.size
        var leadEllipsis = false
        var tailEllipsis = false
        if (cs.size > SearchHighlighter.MAX_CHARS) {
            let firstRange = ranges[0]
            let firstHit = firstRange[0]
            start = firstHit - SearchHighlighter.CONTEXT_BEFORE
            if (start < 0) {
                start = 0
            }
            end = start + SearchHighlighter.MAX_CHARS
            if (end > cs.size) {
                end = cs.size
            }
            leadEllipsis = start > 0
            tailEllipsis = end < cs.size
        }

        // ---- 3. 把命中区间平移到窗口坐标，并裁掉窗口外的部分 ----
        let clipped = ArrayList<Array<Int64>>()
        for (r in ranges) {
            let a = if (r[0] < start) { start } else { r[0] }
            let b = if (r[1] > end) { end } else { r[1] }
            if (a < b) {
                clipped.add([a - start, b - start])
            }
        }

        // ---- 4. 输出交替分段 ----
        let out = ArrayList<HighlightSegment>()
        if (leadEllipsis) {
            out.add(HighlightSegment("…", false))
        }
        // 【索引口径】clipped 里的区间是**窗口内坐标**（已减 start），
        // 而 cs 是原文本。join 时必须加回 start，否则长文本开窗后会
        // 错误地输出「文本开头」而不是命中窗口（实测倾斜于该 bug 的
        // 单测会拿到一串「填」而不是命中词）。
        var cursor: Int64 = 0
        for (r in clipped.toArray()) {
            if (r[0] > cursor) {
                out.add(HighlightSegment(
                    SearchHighlighter.join(cs, start + cursor, start + r[0]), false))
            }
            out.add(HighlightSegment(
                SearchHighlighter.join(cs, start + r[0], start + r[1]), true))
            cursor = r[1]
        }
        if (cursor < end - start) {
            out.add(HighlightSegment(
                SearchHighlighter.join(cs, start + cursor, end), false))
        }
        if (tailEllipsis) {
            out.add(HighlightSegment("…", false))
        }
        if (out.isEmpty()) {
            out.add(HighlightSegment(text, false))
        }
        return out.toArray()
    }

    /**
     * 直接生成 JSON 数组字符串，供路由层内嵌。
     * 形如：[{"text":"清华","hit":false},{"text":"硕士","hit":true}]
     */
    public static func toJson(text: String, keyword: String): String {
        let segs = SearchHighlighter.segments(text, keyword)
        let sb = StringBuilder()
        sb.append("[")
        var i: Int64 = 0
        while (i < segs.size) {
            if (i > 0) {
                sb.append(",")
            }
            let s = segs[i]
            sb.append("{\"text\":\"${SearchHighlighter.escapeJson(s.text)}\",\"hit\":${s.hit}}")
            i = i + 1
        }
        sb.append("]")
        return sb.toString()
    }

    // ---------------------------------------------------------
    // 内部工具
    // ---------------------------------------------------------

    /**
     * 完整子串匹配（大小写不敏感），返回全部互不重叠的命中区间。
     */
    private static func matchAll(cs: Array<String>, ks: Array<String>): Array<Array<Int64>> {
        let out = ArrayList<Array<Int64>>()
        if (ks.size > cs.size) {
            return out.toArray()
        }
        var i: Int64 = 0
        while (i + ks.size <= cs.size) {
            if (SearchHighlighter.eqAt(cs, i, ks)) {
                out.add([i, i + ks.size])
                i = i + ks.size
            } else {
                i = i + 1
            }
        }
        return out.toArray()
    }

    /**
     * 单字回退：高亮 text 中出现的、属于 keyword 字符集合的字符。
     * 最多 8 处，避免长关键词把整行都刷成高亮。
     */
    private static func matchChars(cs: Array<String>, ks: Array<String>): Array<Array<Int64>> {
        let out = ArrayList<Array<Int64>>()
        let set = HashSet<String>()
        for (k in ks) {
            set.add(SearchHighlighter.fold(k))
        }
        var i: Int64 = 0
        while (i < cs.size && out.size < 8) {
            if (set.contains(SearchHighlighter.fold(cs[i]))) {
                out.add([i, i + 1])
            }
            i = i + 1
        }
        return out.toArray()
    }

    /** 从 cs 的 [at, at+ks.size) 与 ks 逐字符比较（ASCII 折叠） */
    private static func eqAt(cs: Array<String>, at: Int64, ks: Array<String>): Bool {
        var j: Int64 = 0
        while (j < ks.size) {
            if (SearchHighlighter.fold(cs[at + j]) != SearchHighlighter.fold(ks[j])) {
                return false
            }
            j = j + 1
        }
        return true
    }

    /**
     * ASCII 大写转小写；多字节字符原样返回。
     * 单字节构造必须用 `Array<Byte> + String.fromUtf8`，
     * 直接 `String.fromUtf8([UInt8(v)])` 的类型推断在此编译器上不稳定；
     * 且绝不把 >=0x80 的字节单独转成 String（非法 UTF-8 会抛异常）。
     */
    private static func fold(c: String): String {
        if (c.size == 1 && c[0] >= 0x41u8 && c[0] <= 0x5Au8) {
            let v = Int64(c[0]) + 32
            let one = Array<Byte>(1, repeat: UInt8(v))
            return String.fromUtf8(one)
        }
        return c
    }

    /** 按 UTF-8 字符边界把字符串切成单字符数组 */
    private static func chars(s: String): Array<String> {
        let out = ArrayList<String>()
        var i: Int64 = 0
        while (i < s.size) {
            let len = SearchHighlighter.utf8Len(s[i])
            if (len <= 0) {
                i = i + 1
            } else if (i + len > s.size) {
                out.add(s[i..s.size])
                i = s.size
            } else {
                out.add(s[i..(i + len)])
                i = i + len
            }
        }
        return out.toArray()
    }

    private static func utf8Len(b: Byte): Int64 {
        if (b < 0x80u8) {
            return 1
        }
        if (b >= 0xC0u8 && b < 0xE0u8) {
            return 2
        }
        if (b >= 0xE0u8 && b < 0xF0u8) {
            return 3
        }
        if (b >= 0xF0u8 && b < 0xF8u8) {
            return 4
        }
        return 0
    }

    /** 拼接 cs[from..to) */
    private static func join(cs: Array<String>, from: Int64, to: Int64): String {
        let sb = StringBuilder()
        var i = from
        while (i < to) {
            sb.append(cs[i])
            i = i + 1
        }
        return sb.toString()
    }

    /**
     * JSON 字符串转义。
     *
     * 【必须按字符边界走】若逐字节 `s[i..(i+1)]`，中文的首字节会被单独
     * 切成非法 UTF-8 String 并抛异常（与 `MediaOcr.upperByte` 同源）。
     * 这里按 utf8Len 取整字符；只有 1 字节字符才可能是需转义的 ASCII。
     */
    private static func escapeJson(s: String): String {
        let sb = StringBuilder()
        var i: Int64 = 0
        while (i < s.size) {
            let len = SearchHighlighter.utf8Len(s[i])
            if (len <= 0) {
                i = i + 1
                continue
            }
            var n = len
            if (i + n > s.size) {
                n = s.size - i
            }
            let c = s[i..(i + n)]
            if (n == 1) {
                let b = s[i]
                if (b == 0x22u8) {
                    sb.append("\\\"")
                } else if (b == 0x5Cu8) {
                    sb.append("\\\\")
                } else if (b == 0x0Au8) {
                    sb.append("\\n")
                } else if (b == 0x0Du8) {
                    sb.append("\\r")
                } else if (b == 0x09u8) {
                    sb.append("\\t")
                } else if (b < 0x20u8) {
                    sb.append(" ")
                } else {
                    sb.append(c)
                }
            } else {
                sb.append(c)
            }
            i = i + n
        }
        return sb.toString()
    }
}

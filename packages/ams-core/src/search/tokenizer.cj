// ============================================================
// ams.core.search.tokenizer · 中英混合分词器
//
// 需求：FR-SRC-001 关键词全文检索 —— **此前中文分词完全未实现**，
//       `arc_search_index` 的 GIN 索引建在空的 tokens 上，等于没有索引。
//
// [为什么选二元切分（bigram）而不是词典分词]
//   主流词典分词（jieba 等）需内置词库与词频数据，体积大且要维护；
//   二元切分把「档案管理」切成「档案 / 案管 / 管理」，
//   查询侧用**同一套规则**切分后做数组交叠（&&）匹配，
//   ——召回率高、无词典依赖、结果稳定可复现。
//   这是 MySQL ngram / PostgreSQL pgroonga 在无词典场景下的常见做法。
//
// [不做什么]
//   不做词性标注、同义词、拼音检索 —— 属 P1/P2，PRD 未列入 P0。
// ============================================================
package ams.core.search

import std.collection.*

/**
 * 中英混合分词器。
 */
public class ChineseTokenizer {
    /**
     * 是否把相邻 CJK 字切成二元组的最小长度。
     * 单字串会产出单字 token（见下方 single-char 回退说明）。
     */
    public static let defaultMinToken: Int64 = 2

    /**
     * 分词的 JSONB / TEXT[] 存储上限（超出截断，防超大文本撑爆索引）。
     */
    public static let maxTokens: Int64 = 2000

    /**
     * 分词。
     *
     * 规则：
     *   ① ASCII 字母/数字 → 连续串为一个词，转小写（英文词整体入库）
     *   ② 非 ASCII（CJK 等）→ 先按字符切出，再对连续段做 **二元滑窗**
     *   ③ CJK 段长度 < 2 → 产出单字本身（保证单字查询也有对应 token）
     *   ④ ASCII 标点/空白 → 作为分隔符
     *
     * @return 去重后的 token 列表（顺序稳定）
     */
    public static func tokenize(text: String): Array<String> {
        let out = ArrayList<String>()
        let seen = ArrayList<String>()
        let chars = ChineseTokenizer.toChars(text)

        var i: Int64 = 0
        while (i < chars.size) {
            let first = chars[i]
            if (ChineseTokenizer.isAsciiAlnum(first)) {
                // ---- 英文/数字词 ----
                let sb = StringBuilder()
                var j: Int64 = i
                while (j < chars.size && ChineseTokenizer.isAsciiAlnum(chars[j])) {
                    sb.append(chars[j])
                    j = j + 1
                }
                ChineseTokenizer.emit(out, seen, ChineseTokenizer.lower(sb.toString()))
                i = j
            } else if (ChineseTokenizer.isCjkChar(first)) {
                // ---- CJK 连续段 ----
                var j: Int64 = i
                while (j < chars.size && ChineseTokenizer.isCjkChar(chars[j])) {
                    j = j + 1
                }
                let seg = ArrayList<String>()
                for (k in i..j) {
                    seg.add(chars[k])
                }
                if (seg.size < 2) {
                    // 单字：直接产出，保证单字查询能命中
                    ChineseTokenizer.emit(out, seen, seg[0])
                } else {
                    // 二元滑窗：档案案管管理
                    for (k in 0..(seg.size - 1)) {
                        let sb = StringBuilder()
                        sb.append(seg[k])
                        sb.append(seg[k + 1])
                        ChineseTokenizer.emit(out, seen, sb.toString())
                    }
                }
                i = j
            } else {
                // 标点/空白/其它 → 跳过
                i = i + 1
            }
        }
        return out.toArray()
    }

    /**
     * 是否为「单字查询」—— 这类查询无法用二元索引精确匹配，
     * 上层应回退到 content LIKE '%字%'（见 SearchRepo 的处理）。
     */
    public static func isSingleCharQuery(keyword: String): Bool {
        let chars = ChineseTokenizer.toChars(keyword)
        var cjk: Int64 = 0
        for (c in chars) {
            if (ChineseTokenizer.isCjkChar(c)) {
                cjk = cjk + 1
            }
        }
        return cjk == 1 && chars.size == 1
    }

    // ------------------------------------------------------------

    /**
     * UTF-8 字符串 → 单字符数组。
     *
     * 仓颉 String 按下标取到的是**字节**，直接下标遍历会把中文拆成乱码，
     * 故这里手动按 UTF-8 首字节判定长度后切出完整字符。
     */
    public static func toChars(s: String): Array<String> {
        let out = ArrayList<String>()
        var i: Int64 = 0
        while (i < s.size) {
            let b = s[i]
            let len = ChineseTokenizer.utf8Len(b)
            if (len <= 0) {
                // 非法首字节（理论上不会出现）：跳过，避免死循环
                i = i + 1
            } else {
                if (i + len > s.size) {
                    out.add(s[i..s.size])
                    i = s.size
                } else {
                    out.add(s[i..(i + len)])
                    i = i + len
                }
            }
        }
        return out.toArray()
    }

    /**
     * 按 UTF-8 首字节判定该字符占几字节。
     *
     * 直接把 Byte 与 u8 字面量比较（见 FileTypes.extensionOf 的 `== 46u8` 写法），
     * 不做 Byte→Int64 转换 —— 该转换在本项目的 API 形态下不可靠。
     */
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
        return -1
    }

    /**
     * ASCII 字母或数字。
     */
    private static func isAsciiAlnum(c: String): Bool {
        if (c.size != 1) {
            return false
        }
        let b = c[0]
        return (b >= 0x61u8 && b <= 0x7Au8) ||
               (b >= 0x41u8 && b <= 0x5Au8) ||
               (b >= 0x30u8 && b <= 0x39u8)
    }

    /**
     * 是否 CJK 字符（含中文标点一并纳入，避免标点打断相邻汉字）。
     *
     * 判定：非 ASCII（首字节 >= 0x80）。
     * 这样中文、日文假名、韩文都支持，对本系统的档案标题已足够。
     */
    private static func isCjkChar(c: String): Bool {
        if (c.size < 1) {
            return false
        }
        return c[0] >= 0x80u8
    }

    /**
     * 转小写（ASCII 范围）。
     *
     * 用标准库的 toAsciiLower，避免手写字节算术。
     */
    private static func lower(s: String): String {
        return s.toAsciiLower()
    }

    private static func emit(out: ArrayList<String>, seen: ArrayList<String>, token: String): Unit {
        if (token.isEmpty()) {
            return
        }
        if (out.size >= ChineseTokenizer.maxTokens) {
            return
        }
        var dup = false
        for (s in seen) {
            if (s == token) {
                dup = true
            }
        }
        if (!dup) {
            seen.add(token)
            out.add(token)
        }
    }
}

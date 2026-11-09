// ============================================================
// ams.core.search · 高亮片段单元测试
//
// 覆盖：FR-SRC-001 补遗（高亮片段）
// 重点：中文 UTF-8 边界、大小写折叠、多命中、单字回退、长文本开窗、JSON 转义
// ============================================================
package ams.core.search.test

import std.unittest.*
import std.collection.*

import ams.core.search.*

@Test
public class HighlightTest {

    /** 把分段拼回可读串，便于断言：命中段用 [] 包裹 */
    private static func render(segs: Array<HighlightSegment>): String {
        let sb = StringBuilder()
        for (s in segs) {
            if (s.hit) {
                sb.append("[${s.text}]")
            } else {
                sb.append(s.text)
            }
        }
        return sb.toString()
    }

    private static func hitCount(segs: Array<HighlightSegment>): Int64 {
        var n: Int64 = 0
        for (s in segs) {
            if (s.hit) {
                n = n + 1
            }
        }
        return n
    }

    @TestCase
    public func testEmptyKeywordReturnsSinglePlainSegment() {
        let segs = SearchHighlighter.segments("清华大学硕士学位证书", "")
        @Assert(segs.size, 1)
        @Assert(segs[0].hit, false)
        @Assert(segs[0].text, "清华大学硕士学位证书")
    }

    @TestCase
    public func testEmptyTextReturnsSinglePlainSegment() {
        let segs = SearchHighlighter.segments("", "硕士")
        @Assert(segs.size, 1)
        @Assert(segs[0].hit, false)
        @Assert(segs[0].text, "")
    }

    @TestCase
    public func testChineseExactMatchKeepsUtf8Boundary() {
        let segs = SearchHighlighter.segments("清华大学硕士学位证书", "硕士")
        @Assert(HighlightTest.render(segs), "清华大学[硕士]学位证书")
        @Assert(HighlightTest.hitCount(segs), 1)
    }

    @TestCase
    public func testAsciiCaseInsensitive() {
        let segs = SearchHighlighter.segments("Archive Manager OCR", "ocr")
        @Assert(HighlightTest.render(segs), "Archive Manager [OCR]")
    }

    @TestCase
    public func testMixedCaseKeyword() {
        let segs = SearchHighlighter.segments("archive MANAGER", "MANAGER")
        @Assert(HighlightTest.render(segs), "archive [MANAGER]")
    }

    @TestCase
    public func testMultipleMatches() {
        let segs = SearchHighlighter.segments("abABab", "ab")
        @Assert(HighlightTest.render(segs), "[ab][AB][ab]")
        @Assert(HighlightTest.hitCount(segs), 3)
    }

    @TestCase
    public func testNoMatchReturnsPlainText() {
        let segs = SearchHighlighter.segments("清华大学", "xyz")
        @Assert(segs.size, 1)
        @Assert(HighlightTest.hitCount(segs), 0)
        @Assert(segs[0].text, "清华大学")
    }

    @TestCase
    public func testSingleCharFallbackMatchesLikeQuery() {
        // 后端单字查询会回退 LIKE；完整串无命中时高亮出现的单字
        let segs = SearchHighlighter.segments("档案管理系统", "档案ABC")
        let r = HighlightTest.render(segs)
        @Assert(r.contains("[档]"), true)
        @Assert(r.contains("[案]"), true)
        @Assert(r.contains("管理系统"), true)
    }

    @TestCase
    public func testLongTextWindowWithEllipsis() {
        var sb = StringBuilder()
        var i: Int64 = 0
        while (i < 200) {
            sb.append("填")
            i = i + 1
        }
        sb.append("关键命中词")
        i = 0
        while (i < 200) {
            sb.append("尾")
            i = i + 1
        }
        let segs = SearchHighlighter.segments(sb.toString(), "关键命中词")
        let r = HighlightTest.render(segs)
        @Assert(r.contains("[关键命中词]"), true)
        @Assert(r.startsWith("…"), true)
        @Assert(r.endsWith("…"), true)
        // 开窗后字符数受控（render 的 [] 标记 + 首尾省略号共约 +4）
        @Assert(HighlightTest.charsOf(r).size <= SearchHighlighter.MAX_CHARS + 8, true)
    }

    @TestCase
    public func testToJsonEscapesQuotesAndBackslash() {
        let j = SearchHighlighter.toJson("a\"b\\c", "a")
        @Assert(j.contains("\\\"b\\\\c"), true)
        @Assert(j.contains("\"hit\":true"), true)
    }

    @TestCase
    public func testToJsonKeepsChineseIntact() {
        let j = SearchHighlighter.toJson("硕士学位证书", "硕士")
        @Assert(j.contains("硕士"), true)
        @Assert(j.contains("学位证书"), true)
    }

    /** 与产品代码同思路的按字符计数（仅测试内部使用） */
    private static func charsOf(s: String): ArrayList<String> {
        let out = ArrayList<String>()
        var i: Int64 = 0
        while (i < s.size) {
            let b = s[i]
            var n: Int64 = 1
            if (b >= 0xC0u8 && b < 0xE0u8) {
                n = 2
            } else if (b >= 0xE0u8 && b < 0xF0u8) {
                n = 3
            } else if (b >= 0xF0u8 && b < 0xF8u8) {
                n = 4
            }
            if (i + n > s.size) {
                n = s.size - i
            }
            out.add(s[i..(i + n)])
            i = i + n
        }
        return out
    }
}

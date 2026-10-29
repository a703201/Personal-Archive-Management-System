// ============================================================
// ams.core.item.TemplatePlan · 单元测试（FR-ARCH-012 · 方案 C）
//
// 覆盖点：
//   ① 标题序号展开：`{n}` 占位 / 无占位追加后缀 / 单条不加后缀
//   ② 有效期偏移：0 = 不设有效期；N 天按 UTC 日历推进；超限钳制
//
// [结构约定]：测试代码与产品代码**物理分离**（本文件在 tests/ 目录）。
// ============================================================
package ams.core.item.test

import std.collection.*
import std.unittest.*

import ams.core.item.*

@Test
public class TemplateTitleTest {
    // ---- `{n}` 占位 ----

    @TestCase
    public func testPlaceholderReplaced() {
        @Assert(TemplatePlan.title("证件副本 {n}", 1, 1), "证件副本 1")
        @Assert(TemplatePlan.title("证件副本 {n}", 3, 3), "证件副本 3")
    }

    @TestCase
    public func testPlaceholderReplacedEvenWhenSingle() {
        // 单条也要替换：否则用户会看到字面量 `{n}`
        @Assert(TemplatePlan.title("合同-{n}", 1, 1), "合同-1")
    }

    @TestCase
    public func testMultiplePlaceholders() {
        @Assert(TemplatePlan.title("{n}-{n}", 2, 2), "2-2")
    }

    // ---- 无占位 ----

    @TestCase
    public func testNoPlaceholderSingleKeepsBase() {
        // 套用 1 条时不该出现「 (1)」这种多余后缀
        @Assert(TemplatePlan.title("身份证", 1, 1), "身份证")
    }

    @TestCase
    public func testNoPlaceholderMultiGetsSuffix() {
        // 套用多条必须可区分，否则列表里是 N 行一模一样的记录
        @Assert(TemplatePlan.title("身份证", 1, 3), "身份证 (1)")
        @Assert(TemplatePlan.title("身份证", 3, 3), "身份证 (3)")
    }

    // ---- 批量 ----

    @TestCase
    public func testTitlesCount() {
        let ts = TemplatePlan.titles("证件 {n}", 3)
        @Assert(ts.size, 3)
        @Assert(ts[0], "证件 1")
        @Assert(ts[1], "证件 2")
        @Assert(ts[2], "证件 3")
    }

    @TestCase
    public func testTitlesZeroTreatedAsOne() {
        let ts = TemplatePlan.titles("身份证", 0)
        @Assert(ts.size, 1)
        @Assert(ts[0], "身份证")
    }

    @TestCase
    public func testTitlesNegativeTreatedAsOne() {
        let ts = TemplatePlan.titles("身份证", -5)
        @Assert(ts.size, 1)
    }

    @TestCase
    public func testTitlesAllUniqueWhenNoPlaceholder() {
        // 不变量：无论模板怎么填，同批产出的标题必须两两不同
        let ts = TemplatePlan.titles("身份证", 5)
        let seen = HashSet<String>()
        for (t in ts) {
            seen.add(t)
        }
        @Assert(seen.size, ts.size)
    }
}

@Test
public class TemplateExpiryTest {
    /** 2000-01-01T00:00:00Z */
    private static let EPOCH_2000: Int64 = 946684800000

    @TestCase
    public func testZeroOffsetMeansNoExpiry() {
        @Assert(TemplatePlan.expiryDate(EPOCH_2000, 0), "")
        @Assert(TemplatePlan.expiryDate(EPOCH_2000, -3), "")
    }

    @TestCase
    public func testOneDayOffset() {
        @Assert(TemplatePlan.expiryDate(EPOCH_2000, 1), "2000-01-02")
    }

    @TestCase
    public func testThirtyDayOffset() {
        // 2000-01-01 + 30 天 = 2000-01-31
        @Assert(TemplatePlan.expiryDate(EPOCH_2000, 30), "2000-01-31")
    }

    @TestCase
    public func testLeapYearBoundary() {
        // 2000-02-28 + 1 天 = 2000-02-29（2000 是闰年）→ 再 +1 = 03-01
        let feb28 = EPOCH_2000 + 58 * 24 * 3600 * 1000
        @Assert(TemplatePlan.expiryDate(feb28, 1), "2000-02-29")
        @Assert(TemplatePlan.expiryDate(feb28, 2), "2000-03-01")
    }

    @TestCase
    public func testOffsetClampedToMax() {
        // 超上限按 MAX 钳制，而不是抛错或溢出
        @Assert(
            TemplatePlan.expiryDate(EPOCH_2000, 999999),
            TemplatePlan.expiryDate(EPOCH_2000, TemplatePlan.MAX_OFFSET_DAYS)
        )
    }

    @TestCase
    public func testFormatShape() {
        let s = TemplatePlan.expiryDate(EPOCH_2000, 7)
        @Assert(s.size, 10)
        // 用切片而非 s[4]：String 单下标取到的是字节，不能直接与字符串比较
        @Assert(s[4..5], "-")
        @Assert(s[7..8], "-")
    }
}

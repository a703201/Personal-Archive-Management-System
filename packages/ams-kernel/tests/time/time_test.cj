// ============================================================
// ams.kernel.time · 单元测试
//
// [结构约定]（实测 SDK 1.0.5）：
//   测试代码与产品代码**物理分离**（本文件在 tests/ 目录，不在 src/）。
//   原因：编译器会优先使用 import-path 里的 .cjo 而非源码，
//   若测试文件与产品代码同目录，.cjo 里会混入未展开的测试宏，
//   导致后续编译报出莫名的 "expected '=>' in lambda expression"。
//   分离后测试包声明为 <被测包>.test，用 import 引用被测包。
//
//   编译运行：bash scripts/test.sh
// ============================================================
package ams.kernel.time.test

import ams.kernel.time.*


import std.unittest.*

@Test
public class TimeTest {
    @TestCase
    public func testNowMillisReasonable() {
        let ms = Times.nowMillis()
        // 2020-01-01 之后的毫秒数应大于 1.5e12
        @Assert(ms > 1577836800000)
    }

    @TestCase
    public func testIso8601Format() {
        let iso = Times.nowIso8601()
        // 形如 2026-10-25T00:34:53.002Z
        @Assert(iso.size, 24)
        @Assert(iso.endsWith("Z"))
        @Assert(iso.contains("T"))
    }

    @TestCase
    public func testEpochToIso() {
        // Unix 纪元 -> 1970-01-01T00:00:00.000Z
        @Assert(Times.toIso8601(0), "1970-01-01T00:00:00.000Z")
    }

    @TestCase
    public func testKnownTimestamp() {
        // 1792859693002 -> 2026-10-24T16:34:53.002Z（UTC）
        // 期望值由 Python datetime 独立计算核对：
        //   datetime.datetime.fromtimestamp(1792859693002/1000, timezone.utc)
        @Assert(Times.toIso8601(1792859693002), "2026-10-24T16:34:53.002Z")
    }

    @TestCase
    public func testIsoRoundTrip() {
        let ms = Times.nowMillis()
        let iso = Times.toIso8601(ms)
        // 往返误差应在 1 ms 内（毫秒精度）
        let back = Times.fromIso8601(iso)
        let diff = back - ms
        @Assert(diff >= -1 && diff <= 1)
    }

    @TestCase
    public func testLeapYearFeb29() {
        // 2024 是闰年，2 月有 29 天
        let feb29 = Times.daysFromCivilForTest(2024, 2, 29)
        let (y, m, d) = Times.civilFromDaysForTest(feb29)
        @Assert(y, 2024)
        @Assert(m, 2)
        @Assert(d, 29)
    }

    @TestCase
    public func testNonLeapYearFeb28() {
        // 2023 不是闰年，2 月 28 日后应进位到 3 月 1 日
        let feb28 = Times.daysFromCivilForTest(2023, 2, 28)
        let (y, m, d) = Times.civilFromDaysForTest(feb28 + 1)
        @Assert(y, 2023)
        @Assert(m, 3)
        @Assert(d, 1)
    }

    @TestCase
    public func testSleepMillis() {
        let start = Times.nowMillis()
        Times.sleepMillis(20)
        let elapsed = Times.nowMillis() - start
        @Assert(elapsed >= 15)
    }
}

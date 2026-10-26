// ============================================================
// ams.kernel.id · 单元测试
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
package ams.kernel.id.test

import ams.kernel.id.*


import std.unittest.*
import ams.kernel.time.*

@Test
public class KernelIdTest {
    @TestCase
    public func testSnowflakeIdIncreases() {
        let gen = SnowflakeIdGenerator(1)
        let a = gen.next()
        let b = gen.next()
        @Assert(b > a)
    }

    @TestCase
    public func testSnowflakeIdUniqueAcrossWorkers() {
        let g1 = SnowflakeIdGenerator(1)
        let g2 = SnowflakeIdGenerator(2)
        @Assert(g1.next() != g2.next())
    }

    @TestCase
    public func testSnowflakeIdTimeOrdered() {
        let gen = SnowflakeIdGenerator(3)
        let first = gen.next()
        Times.sleepMillis(2)
        let second = gen.next()
        @Assert(second > first)
    }
}

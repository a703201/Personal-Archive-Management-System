// ============================================================
// ams.kernel.log · 单元测试
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
package ams.kernel.log.test

import ams.kernel.log.*


import std.unittest.*

@Test
public class LogTest {
    @TestCase
    public func testSensitiveValueMasked() {
        let s = SensitiveValue("110101199001011234")
        let masked = s.masked()
        // 原文绝不能出现在脱敏输出里
        @Assert(!masked.contains("110101199001011234"))
        @Assert(masked.contains("***"))
    }

    @TestCase
    public func testSensitiveValueReveal() {
        let s = SensitiveValue("secret")
        @Assert(s.reveal(), "secret")
    }

    @TestCase
    public func testLogLevelOrder() {
        // 注意：@Assert 对 enum 参数无法推断泛型（实测报
        // "unable to infer generic argument of this function"），
        // 因此枚举比较一律用 match 判定。
        let log = Log.get()
        log.setMinLevel(LogLevel.Debug)
        let isDebug = match (log.getMinLevel()) {
            case LogLevel.Debug => true
            case _ => false
        }
        @Assert(isDebug, true)

        log.setMinLevel(LogLevel.Info)
        let isInfo = match (log.getMinLevel()) {
            case LogLevel.Info => true
            case _ => false
        }
        @Assert(isInfo, true)
    }

    @TestCase
    public func testLogContextDefaults() {
        let ctx = LogContext()
        @Assert(ctx.traceId, "")
        @Assert(ctx.userId, "")
    }

    @TestCase
    public func testLogContextValues() {
        let ctx = LogContext(traceId: "trace-1", userId: "u-1")
        @Assert(ctx.traceId, "trace-1")
        @Assert(ctx.userId, "u-1")
    }

    @TestCase
    public func testWriteDoesNotThrow() {
        // 日志写入不应抛异常（即使带上敏感字段与空上下文）
        let log = Log.get()
        let ctx = LogContext(traceId: "trace-1", userId: "u-1")
        log.info("test.action", Some(ctx), [("k", "v")])
        log.error("test.error", None, [("secret", SensitiveValue("s3cr3t").masked())])
    }
}

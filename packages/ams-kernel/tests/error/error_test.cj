// ============================================================
// ams.kernel.error · 单元测试
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
package ams.kernel.error.test

import ams.kernel.error.*


import std.unittest.*

@Test
public class KernelErrorTest {
    @TestCase
    public func testKindToCode() {
        @Assert(kindToCode(AppErrorKind.ValidationFailed), "VALIDATION_FAILED")
        @Assert(kindToCode(AppErrorKind.Unauthorized), "UNAUTHORIZED")
        @Assert(kindToCode(AppErrorKind.Forbidden), "FORBIDDEN")
        @Assert(kindToCode(AppErrorKind.NotFound), "NOT_FOUND")
        @Assert(kindToCode(AppErrorKind.Conflict), "CONFLICT")
        @Assert(kindToCode(AppErrorKind.RateLimited), "RATE_LIMITED")
        @Assert(kindToCode(AppErrorKind.CryptoFailure), "CRYPTO_FAILURE")
        @Assert(kindToCode(AppErrorKind.StorageFailure), "STORAGE_FAILURE")
        @Assert(kindToCode(AppErrorKind.DatabaseFailure), "DATABASE_FAILURE")
        @Assert(kindToCode(AppErrorKind.Internal), "INTERNAL_ERROR")
    }

    @TestCase
    public func testKindToHttpStatus() {
        @Assert(kindToHttpStatus(AppErrorKind.ValidationFailed), 400)
        @Assert(kindToHttpStatus(AppErrorKind.Unauthorized), 401)
        @Assert(kindToHttpStatus(AppErrorKind.Forbidden), 403)
        @Assert(kindToHttpStatus(AppErrorKind.NotFound), 404)
        @Assert(kindToHttpStatus(AppErrorKind.Conflict), 409)
        @Assert(kindToHttpStatus(AppErrorKind.PayloadTooLarge), 413)
        @Assert(kindToHttpStatus(AppErrorKind.UnsupportedMediaType), 415)
        @Assert(kindToHttpStatus(AppErrorKind.RateLimited), 429)
        @Assert(kindToHttpStatus(AppErrorKind.CryptoFailure), 500)
        @Assert(kindToHttpStatus(AppErrorKind.Internal), 500)
        @Assert(kindToHttpStatus(AppErrorKind.StorageFailure), 503)
        @Assert(kindToHttpStatus(AppErrorKind.DatabaseFailure), 503)
    }

    @TestCase
    public func testAppErrorCarriesContext() {
        let e = validationError("idCard", "证件号格式不正确")
        @Assert(e.code, "VALIDATION_FAILED")
        @Assert(e.httpStatus, 400)
        @Assert(e.field, "idCard")
        @Assert(e.message, "证件号格式不正确")
    }

    @TestCase
    public func testHelperConstructors() {
        @Assert(unauthorized().code, "UNAUTHORIZED")
        @Assert(unauthorized().httpStatus, 401)
        @Assert(forbidden().code, "FORBIDDEN")
        @Assert(notFound("档案条目").code, "NOT_FOUND")
        @Assert(conflict("版本冲突").code, "CONFLICT")
    }
}

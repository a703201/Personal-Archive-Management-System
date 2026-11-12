// ============================================================
// ams.api.middleware · 租户配额闸门单元测试
//
// 覆盖：创建动作识别（方法 / 路径 / query）、配额边界判定（正好等于上限放行、
//   +1 拒绝、字节向上取整）、QUOTA_EXCEEDED 错误码与 HTTP 状态、总开关。
// 纯函数驱动，不依赖数据库 / 网络。
// 运行：bash scripts/test.sh ams-api
// ============================================================
package ams.api.middleware.test

import std.env.*
import std.unittest.*
import std.unittest.testmacro.*

import ams.api.middleware.*
import ams.data.repo.*
import ams.kernel.error.*

@Test
public class TenantQuotaTest {
    private static func kindName(k: QuotaKind): String {
        match (k) {
            case QuotaKind.Users => return "users"
            case QuotaKind.Items => return "items"
            case QuotaKind.Storage => return "storage"
        }
    }

    private static func nameOf(method: String, url: String): String {
        match (TenantQuotaMiddleware.quotaKindFor(method, url)) {
            case Some(k) => return TenantQuotaTest.kindName(k)
            case None => return "none"
        }
    }

    @TestCase
    public func testCreateActionsAreRecognised(): Unit {
        @Assert(TenantQuotaTest.nameOf("POST", "/api/items"), "items")
        @Assert(TenantQuotaTest.nameOf("POST", "/api/items/42/clone"), "items")
        @Assert(TenantQuotaTest.nameOf("POST", "/api/import/tasks"), "items")
        @Assert(TenantQuotaTest.nameOf("POST", "/api/users"), "users")
        @Assert(TenantQuotaTest.nameOf("POST", "/api/auth/register"), "users")
        @Assert(TenantQuotaTest.nameOf("POST", "/api/attachments"), "storage")
        @Assert(TenantQuotaTest.nameOf("POST", "/api/attachments/upload/sessions"), "storage")
        // 带 query 不能漏判
        @Assert(TenantQuotaTest.nameOf("POST", "/api/items?x=1"), "items")
    }

    @TestCase
    public func testReadsAndUnrelatedWritesAreNotBlocked(): Unit {
        @Assert(TenantQuotaTest.nameOf("GET", "/api/items"), "none")
        @Assert(TenantQuotaTest.nameOf("GET", "/api/attachments/1/download"), "none")
        @Assert(TenantQuotaTest.nameOf("PUT", "/api/items/1"), "none")
        @Assert(TenantQuotaTest.nameOf("DELETE", "/api/items/1"), "none")
        @Assert(TenantQuotaTest.nameOf("POST", "/api/search"), "none")
        @Assert(TenantQuotaTest.nameOf("POST", "/api/auth/login"), "none")
        @Assert(TenantQuotaTest.nameOf("POST", "/api/other"), "none")
    }

    @TestCase
    public func testExceededBoundary(): Unit {
        let q = TenantQuota(1, 10, 100, 5)
        // 正好等于上限时，再写一条才超限
        @Assert(TenantQuotaGuard.exceeded(q, TenantUsage(9, 99, 0), QuotaKind.Users, 0), false)
        @Assert(TenantQuotaGuard.exceeded(q, TenantUsage(10, 99, 0), QuotaKind.Users, 0), true)
        @Assert(TenantQuotaGuard.exceeded(q, TenantUsage(0, 99, 0), QuotaKind.Items, 0), false)
        @Assert(TenantQuotaGuard.exceeded(q, TenantUsage(0, 100, 0), QuotaKind.Items, 0), true)
        // 5 MiB 上限：4 MiB + 1 MiB 恰好放行；多 1 字节因向上取整而拒绝
        let mb: Int64 = 1024 * 1024
        @Assert(TenantQuotaGuard.exceeded(q, TenantUsage(0, 0, 4 * mb), QuotaKind.Storage, mb), false)
        @Assert(TenantQuotaGuard.exceeded(q, TenantUsage(0, 0, 4 * mb), QuotaKind.Storage, mb + 1), true)
        @Assert(TenantQuotaGuard.exceeded(q, TenantUsage(0, 0, 0), QuotaKind.Storage, 6 * mb), true)
    }

    @TestCase
    public func testQuotaExceededCodeAndStatus(): Unit {
        @Assert(kindToCode(AppErrorKind.QuotaExceeded), "QUOTA_EXCEEDED")
        @Assert(kindToHttpStatus(AppErrorKind.QuotaExceeded), 429)
        let e = AppError(AppErrorKind.QuotaExceeded, "配额已达上限")
        @Assert(e.code, "QUOTA_EXCEEDED")
        @Assert(e.httpStatus, 429)
    }

    @TestCase
    public func testEnforceSwitch(): Unit {
        let original = getVariable("AMS_QUOTA_ENFORCE") ?? ""
        setVariable("AMS_QUOTA_ENFORCE", "true")
        @Assert(TenantQuotaGuard.enforceEnabled(), true)
        setVariable("AMS_QUOTA_ENFORCE", "FALSE")
        @Assert(TenantQuotaGuard.enforceEnabled(), false)
        setVariable("AMS_QUOTA_ENFORCE", "")
        @Assert(TenantQuotaGuard.enforceEnabled(), true)
        setVariable("AMS_QUOTA_ENFORCE", original)
    }

    @TestCase
    public func testLabels(): Unit {
        @Assert(TenantQuotaGuard.labelOf(QuotaKind.Users), "用户数")
        @Assert(TenantQuotaGuard.labelOf(QuotaKind.Items), "档案条目数")
        @Assert(TenantQuotaGuard.labelOf(QuotaKind.Storage), "附件存储容量")
    }
}

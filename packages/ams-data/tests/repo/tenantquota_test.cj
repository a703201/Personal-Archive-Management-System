// ============================================================
// ams.data.repo · 租户配额纯逻辑单元测试（阶段 3）
//
// 只测不依赖数据库的 `TenantQuota.valid`（配额边界），
// 运行：bash scripts/test.sh ams-data
// ============================================================
package ams.data.repo.test

import std.unittest.*

import ams.data.repo.*

@Test
public class TenantQuotaTest {
    @TestCase
    public func testTypicalValuesAccepted() {
        @Assert(TenantQuota.valid(100, 10000, 1024), true)
    }

    @TestCase
    public func testLowerBoundary() {
        @Assert(TenantQuota.valid(1, 1, 1), true)
    }

    @TestCase
    public func testUpperBoundary() {
        @Assert(TenantQuota.valid(1000000, 1000000, 1000000), true)
    }

    @TestCase
    public func testZeroRejected() {
        @Assert(TenantQuota.valid(0, 100, 100), false)
        @Assert(TenantQuota.valid(100, 0, 100), false)
        @Assert(TenantQuota.valid(100, 100, 0), false)
    }

    @TestCase
    public func testNegativeRejected() {
        @Assert(TenantQuota.valid(-1, 100, 100), false)
    }

    @TestCase
    public func testAboveUpperRejected() {
        @Assert(TenantQuota.valid(1000001, 100, 100), false)
    }

    @TestCase
    public func testRecordKeepsValues() {
        let q = TenantQuota(7, 50, 500, 2048)
        @Assert(q.tenantId, 7)
        @Assert(q.maxUsers, 50)
        @Assert(q.maxItems, 500)
        @Assert(q.maxStorageMb, 2048)
    }
}

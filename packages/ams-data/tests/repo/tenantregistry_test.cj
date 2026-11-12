// ============================================================
// ams.data.repo · 租户注册输入校验单元测试
//
// 纯函数驱动，不依赖数据库 / 网络 / 外部进程。
// 运行：bash scripts/test.sh ams-data
// ============================================================
package ams.data.repo.test

import std.unittest.*
import std.unittest.testmacro.*

import ams.data.repo.*

@Test
public class TenantRegistryTest {
    @TestCase
    public func testValidCode(): Unit {
        @Assert(TenantRegistry.validCode("acme"), true)
        @Assert(TenantRegistry.validCode("team-01_dev"), true)
        @Assert(TenantRegistry.validCode("a"), false)          // 过短
        @Assert(TenantRegistry.validCode("1acme"), false)      // 首字符须字母
        @Assert(TenantRegistry.validCode("Acme"), false)       // 大写不允许
        @Assert(TenantRegistry.validCode("a b"), false)        // 空格
        @Assert(TenantRegistry.validCode("a/b"), false)        // 路径分隔符
        @Assert(TenantRegistry.validCode(""), false)
    }

    @TestCase
    public func testValidName(): Unit {
        @Assert(TenantRegistry.validName("示例租户"), true)
        @Assert(TenantRegistry.validName("  ACME  "), true)
        @Assert(TenantRegistry.validName(""), false)
        @Assert(TenantRegistry.validName("   "), false)
        @Assert(TenantRegistry.validName("a\nb"), false)       // 控制字符
    }

    @TestCase
    public func testValidUsername(): Unit {
        @Assert(TenantRegistry.validUsername("admin01"), true)
        @Assert(TenantRegistry.validUsername("a.b_c-d"), true)
        @Assert(TenantRegistry.validUsername("abc"), false)    // 过短
        @Assert(TenantRegistry.validUsername("admin<script>"), false)
        @Assert(TenantRegistry.validUsername("admin name"), false)
        @Assert(TenantRegistry.validUsername(""), false)
    }

    @TestCase
    public func testBuiltinAdminRoleId(): Unit {
        // db/migrations/003_seed_perms_roles.sql 的 org_admin 固定 ID
        @Assert(TenantRegistry.OrgAdminRoleId, 800004)
    }
}

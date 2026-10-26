// ============================================================
// ams.security.authz · 单元测试
//
// 覆盖需求：FR-ACL-001 / 002 / 003 / 004 / 005 / 006 / 007 / 008 / 009
//
// [结构约定]（实测 SDK 1.0.5）：
//   测试代码与产品代码**物理分离**（本文件在 tests/ 目录，不在 src/）。
//   编译运行：bash scripts/test.sh ams-security
//
// [另一个约定]：仓颉的 match 分支必须是**单个表达式**，
//   不能写成 { 多行语句 }。故复杂场景一律抽成私有方法。
// ============================================================
package ams.security.authz.test

import std.collection.*
import std.unittest.*

import ams.security.authz.*

@Test
public class PermTest {
    @TestCase
    public func testParseValid() {
        let p = Perm.parse("archive:read:own")
        @Assert(PermTest.checkOwnPerm(Perm.parse("archive:read:own")), true)
    }

    @TestCase
    public func testParseWithoutScope() {
        let p = Perm.parse("audit:read")
        @Assert(PermTest.checkNoScopePerm(Perm.parse("audit:read")), true)
    }


    @TestCase
    public func testParseInvalid() {
        @Assert(Perm.parse("invalid").isSome(), false)
        @Assert(Perm.parse("archive").isSome(), false)
        @Assert(Perm.parse("a:b:c:d").isSome(), false)
        @Assert(Perm.parse(":read").isSome(), false)
    }

    /**
     * 校验 own 范围权限的解析结果。
     */
    private static func checkOwnPerm(p: ?Perm): Bool {
        match (p) {
            case Some(x) => return x.domain == "archive" && x.action == "read" &&
                x.scope == "own" && x.isOwnScope() && !x.isAnyScope()
            case None => return false
        }
    }

    /**
     * 校验无范围权限的解析结果。
     */
    private static func checkNoScopePerm(p: ?Perm): Bool {
        match (p) {
            case Some(x) => return x.domain == "audit" && x.action == "read" && x.scope == ""
            case None => return false
        }
    }

    @TestCase
    public func testAnyScope() {
        let p = Perm.parse("archive:read:any")
        match (p) {
            case Some(x) => @Assert(x.isAnyScope(), true)
            case None => @Assert(true, false)
        }
    }
}

@Test
public class BuiltinRoleTest {
    @TestCase
    public func testFiveBuiltinRolesExist() {
        // FR-ACL-001：至少 5 种内置角色
        @Assert(BuiltinRole.Owner.code(), "owner")
        @Assert(BuiltinRole.Curator.code(), "curator")
        @Assert(BuiltinRole.Family.code(), "family")
        @Assert(BuiltinRole.OrgAdmin.code(), "org_admin")
        @Assert(BuiltinRole.Auditor.code(), "auditor")
    }

    @TestCase
    public func testAuditorHasNoArchiveRead() {
        // 安全章 §6.2：审计员「查日志不看内容」—— 只有 audit:read
        let perms = BuiltinPerms.permsOf(BuiltinRole.Auditor)
        @Assert(perms.contains("audit:read"), true)
        @Assert(perms.contains("archive:read:own"), false)
        @Assert(perms.contains("archive:read:any"), false)
    }

    @TestCase
    public func testOrgAdminHasNoAuditWrite() {
        // 安全章 §6.2：机构管理员「审计不可篡改」—— 无 audit:write
        let perms = BuiltinPerms.permsOf(BuiltinRole.OrgAdmin)
        @Assert(perms.contains("user:manage"), true)
        @Assert(perms.contains("acl:manage"), true)
        @Assert(perms.contains("audit:read"), false)
    }

    @TestCase
    public func testFamilyIsReadOnly() {
        // 家庭成员：只读，不含写与导出
        let perms = BuiltinPerms.permsOf(BuiltinRole.Family)
        @Assert(perms.contains("archive:read:own"), true)
        @Assert(perms.contains("archive:write:own"), false)
        @Assert(perms.contains("archive:export:own"), false)
    }

    @TestCase
    public func testCuratorHasNoExportAny() {
        // 代管人：可写但不含 export:any
        let perms = BuiltinPerms.permsOf(BuiltinRole.Curator)
        @Assert(perms.contains("archive:write:own"), true)
        @Assert(perms.contains("archive:export:any"), false)
    }

    @TestCase
    public func testOwnerHasFullPerms() {
        let perms = BuiltinPerms.permsOf(BuiltinRole.Owner)
        @Assert(perms.contains("archive:read:own"), true)
        @Assert(perms.contains("archive:read:any"), true)
        @Assert(perms.contains("archive:write:any"), true)
        @Assert(perms.contains("archive:export:any"), true)
        @Assert(perms.contains("acl:grant:own"), true)
    }

    @TestCase
    public func testAllPermsParseable() {
        // 权限目录里每一条都必须能被 parse 解析
        let perms = BuiltinPerms.all()
        @Assert(perms.size > 0, true)
        for (p in perms) {
            @Assert(Perm.parse(p.code).isSome(), true)
        }
    }

    @TestCase
    public func testRolePermsAllInCatalog() {
        // 各角色用到的权限码必须都在权限目录里（避免拼错导致授权失效）
        let catalog = ArrayList<String>()
        for (p in BuiltinPerms.all()) {
            catalog.add(p.code)
        }
        let roles = [BuiltinRole.Owner, BuiltinRole.Curator, BuiltinRole.Family,
                     BuiltinRole.OrgAdmin, BuiltinRole.Auditor]
        for (r in roles) {
            for (code in BuiltinPerms.permsOf(r)) {
                @Assert(catalog.contains(code), true)
            }
        }
    }
}

@Test
public class AuthorizerTest {
    private let now: Int64 = 1790000000000

    /**
     * 构造访问上下文。
     */
    private func ctx(
        userId: String,
        perms: Array<String>,
        subjects: Array<String>,
        level: Int64,
        owned!: Array<String> = []
    ): AccessContext {
        return AccessContext(userId, perms, subjects, level, ownedSubjectIds: owned)
    }

    /**
     * 构造资源。
     */
    private func res(
        subjectId: String,
        category: Int64,
        sens: Sensitivity,
        itemId: String
    ): AuthzResource {
        return AuthzResource(subjectId, category, sens, itemId: itemId)
    }

    // ---- FR-ACL-005：默认拒绝 ----

    @TestCase
    public func testDenyWhenNoPerm() {
        // 默认拒绝：无权限点一律拒绝
        let a = Authorizer(Array<Grant>())
        let c = this.ctx("u1", [], ["s1"], 3)
        let r = a.authorize(c, "archive:read:own", this.res("s1", 1, Sensitivity.Normal, ""), this.now)
        @Assert(r.isAllowed(), false)
    }

    @TestCase
    public func testAllowOwnSubject() {
        let a = Authorizer(Array<Grant>())
        let c = this.ctx("u1", ["archive:read:own"], ["s1"], 3)
        let r = a.authorize(c, "archive:read:own", this.res("s1", 1, Sensitivity.Normal, ""), this.now)
        @Assert(r.isAllowed(), true)
    }

    @TestCase
    public func testDenyOtherSubject() {
        // FR-ACL-006：归属不符 → 拒绝
        let a = Authorizer(Array<Grant>())
        let c = this.ctx("u1", ["archive:read:own"], ["s1"], 3)
        let r = a.authorize(c, "archive:read:own", this.res("s2", 1, Sensitivity.Normal, ""), this.now)
        @Assert(r.isAllowed(), false)
    }

    @TestCase
    public func testAnyScopePermCoversOthers() {
        // archive:read:any 可读任意主体
        let a = Authorizer(Array<Grant>())
        let c = this.ctx("u1", ["archive:read:any"], [], 3)
        let r = a.authorize(c, "archive:read:own", this.res("s2", 1, Sensitivity.Normal, ""), this.now)
        @Assert(r.isAllowed(), true)
    }

    // ---- FR-ACL-007：分类敏感度分级 ----

    @TestCase
    public func testSensitiveCategoryNeedsExplicitGrant() {
        // sensitive 分类：**代管人**（可访问但非拥有）归属通过还不够，需显式授权
        let a = Authorizer(Array<Grant>())
        let c = this.ctx("u1", ["archive:read:own"], ["s1"], 3)
        let r = a.authorize(c, "archive:read:own",
            this.res("s1", 3, Sensitivity.Sensitive, ""), this.now)
        @Assert(r.isAllowed(), false)
    }

    /**
     * sensitive 分类的**所有者**天然可见（PRD FR-ACL-007：
     * 「high 默认仅所有者可见」——所有者不需要任何额外授权）。
     */
    public func testSensitiveCategoryVisibleToOwner() {
        let a = Authorizer(Array<Grant>())
        let c = this.ctx("u1", ["archive:read:own"], ["s1"], 3, owned: ["s1"])
        let r = a.authorize(c, "archive:read:own",
            this.res("s1", 3, Sensitivity.Sensitive, ""), this.now)
        @Assert(r.isAllowed(), true)
    }

    @TestCase
    public func testSensitiveCategoryWithGrantAllowed() {
        let g = Grant("owner1", "u1", "s1", ["archive:read:own"], "", 0, 0, 0)
        let a = Authorizer([g])
        let c = this.ctx("u1", ["archive:read:own"], [], 3)
        let r = a.authorize(c, "archive:read:own",
            this.res("s1", 3, Sensitivity.Sensitive, ""), this.now)
        @Assert(r.isAllowed(), true)
    }

    @TestCase
    public func testHighCategoryNeedsAnyOrGrant() {
        // high 分类：默认仅**所有者**可见 —— 代管人需 any 权限或显式授权
        let a = Authorizer(Array<Grant>())
        let c = this.ctx("u1", ["archive:read:own"], ["s1"], 3)
        let r = a.authorize(c, "archive:read:own",
            this.res("s1", 5, Sensitivity.High, ""), this.now)
        @Assert(r.isAllowed(), false)
    }

    /**
     * high 分类的**所有者**天然可见。
     */
    public func testHighCategoryVisibleToOwner() {
        let a = Authorizer(Array<Grant>())
        let c = this.ctx("u1", ["archive:read:own"], ["s1"], 3, owned: ["s1"])
        let r = a.authorize(c, "archive:read:own",
            this.res("s1", 5, Sensitivity.High, ""), this.now)
        @Assert(r.isAllowed(), true)
    }

    @TestCase
    public func testHighCategoryWithAnyPermAllowed() {
        let a = Authorizer(Array<Grant>())
        let c = this.ctx("u1", ["archive:read:any"], [], 3)
        let r = a.authorize(c, "archive:read:own",
            this.res("s1", 5, Sensitivity.High, ""), this.now)
        @Assert(r.isAllowed(), true)
    }

    @TestCase
    public func testSensitivityCodeRoundTrip() {
        @Assert(Sensitivity.Normal.toCode(), 1)
        @Assert(Sensitivity.Sensitive.toCode(), 2)
        @Assert(Sensitivity.High.toCode(), 3)
        // 枚举相等用 match 判定（仓颉的 enum 不支持 == 比较）
        @Assert(match (Sensitivity.fromCode(1)) {
            case Sensitivity.Normal => true
            case _ => false
        }, true)
        @Assert(match (Sensitivity.fromCode(2)) {
            case Sensitivity.Sensitive => true
            case _ => false
        }, true)
        @Assert(match (Sensitivity.fromCode(3)) {
            case Sensitivity.High => true
            case _ => false
        }, true)
    }

    // ---- FR-ACL-008：临时授权（条目级 / 分类级） ----

    @TestCase
    public func testItemLevelGrant() {
        // 条目级授权：只覆盖该条目
        let g = Grant("owner1", "u1", "s1", ["archive:read:own"], "i1", 0, 0, 0)
        let a = Authorizer([g])
        let c = this.ctx("u1", ["archive:read:own"], [], 3)
        @Assert(a.authorize(c, "archive:read:own",
            this.res("s1", 1, Sensitivity.Normal, "i1"), this.now).isAllowed(), true)
        @Assert(a.authorize(c, "archive:read:own",
            this.res("s1", 1, Sensitivity.Normal, "i2"), this.now).isAllowed(), false)
    }

    @TestCase
    public func testCategoryLevelGrant() {
        // 分类级授权：覆盖该分类下所有条目
        let g = Grant("owner1", "u1", "s1", ["archive:read:own"], "", 3, 0, 0)
        let a = Authorizer([g])
        let c = this.ctx("u1", ["archive:read:own"], [], 3)
        @Assert(a.authorize(c, "archive:read:own",
            this.res("s1", 3, Sensitivity.Normal, "i9"), this.now).isAllowed(), true)
        @Assert(a.authorize(c, "archive:read:own",
            this.res("s1", 4, Sensitivity.Normal, "i9"), this.now).isAllowed(), false)
    }

    @TestCase
    public func testGrantToOtherUserNotEffective() {
        // 授权给他人不应给自己放行
        let g = Grant("owner1", "u2", "s1", ["archive:read:own"], "", 0, 0, 0)
        let a = Authorizer([g])
        let c = this.ctx("u1", ["archive:read:own"], [], 3)
        @Assert(a.authorize(c, "archive:read:own",
            this.res("s1", 1, Sensitivity.Normal, ""), this.now).isAllowed(), false)
    }

    // ---- FR-ACL-009：到期与撤销 ----

    @TestCase
    public func testExpiredGrantRejected() {
        // 到期后立即失效（服务端校验，不依赖定时任务）
        let expired = this.now - 1
        let g = Grant("owner1", "u1", "s1", ["archive:read:own"], "", 0, expired, 0)
        let a = Authorizer([g])
        let c = this.ctx("u1", ["archive:read:own"], [], 3)
        @Assert(a.authorize(c, "archive:read:own",
            this.res("s1", 1, Sensitivity.Normal, ""), this.now).isAllowed(), false)
    }

    @TestCase
    public func testNotYetExpiredGrantValid() {
        let future = this.now + 60000
        let g = Grant("owner1", "u1", "s1", ["archive:read:own"], "", 0, future, 0)
        let a = Authorizer([g])
        let c = this.ctx("u1", ["archive:read:own"], [], 3)
        @Assert(a.authorize(c, "archive:read:own",
            this.res("s1", 1, Sensitivity.Normal, ""), this.now).isAllowed(), true)
    }

    @TestCase
    public func testRevokedGrantRejected() {
        // 撤销即时生效
        let g = Grant("owner1", "u1", "s1", ["archive:read:own"], "", 0, 0, this.now)
        let a = Authorizer([g])
        let c = this.ctx("u1", ["archive:read:own"], [], 3)
        @Assert(a.authorize(c, "archive:read:own",
            this.res("s1", 1, Sensitivity.Normal, ""), this.now).isAllowed(), false)
    }

    @TestCase
    public func testGrantValidityAt() {
        let g = Grant("owner1", "u1", "s1", ["archive:read:own"], "", 0, this.now + 1000, 0)
        @Assert(g.isValidAt(this.now), true)
        @Assert(g.isValidAt(this.now + 2000), false)
    }

    @TestCase
    public func testHasAnyGrantOnSubject() {
        let g = Grant("owner1", "u1", "s1", ["archive:read:own"], "", 0, 0, 0)
        let a = Authorizer([g])
        let c = this.ctx("u1", ["archive:read:own"], [], 3)
        @Assert(a.hasAnyGrantOnSubject(c, "s1", this.now), true)
        @Assert(a.hasAnyGrantOnSubject(c, "s2", this.now), false)
    }
}

// ============================================================
// ams.core.family.invite · 单元测试（FR-ACL-010 · 方案 B）
//
// 为什么这一层必须有单测：
//   邀请是整套功能里**唯一**「凭一串字符就能换到成员身份」的入口。
//   生成逻辑若偏置、判定顺序若写反，表现出来都只是「偶尔进不去」，
//   靠人工点一遍根本发现不了。这里的每条用例都对应 docs/14 的一条规则。
//
// 覆盖点：
//   ① 字符表与熵：32 字符表、无 0/1/I/O、8 位 = 40 bit
//   ② 生成确定性：给定字节 → 确定字符串（掩码取低位，不取模）
//   ③ 输入规范化：大小写 / 空格 / 连字符 / 下划线
//   ④ 格式判定：长度与字符集，查库前先拒
//   ⑤ 失效判定顺序：撤销 > 失败超限 > 过期 > 用尽
//   ⑥ 有效期与次数钳制：默认值、上界、非正数兜底
//   ⑦ 角色矩阵：谁能邀请 / 授权 / 移除 / 解散 / 提升
//   ⑧ 授权范围推导与权限子集判定
//
// [结构约定]：测试代码与产品代码**物理分离**（本文件在 tests/ 目录）。
// [match 约定]：仓颉的 match 分支只能是单个表达式，不能写 { 多行语句 }。
// [枚举约定]：仓颉自定义枚举没有内建 `==`，断言一律比 `reason()` / `code()`
//             这类字符串投影，不要写 `@Assert(state, InviteState.Expired)`。
// ============================================================
package ams.core.family.test

import std.collection.*
import std.unittest.*

import ams.core.family.*

/** 把 Int64 序列转成字节数组（测试里构造确定性随机源用） */
func bytesOf(vals: Array<Int64>): Array<Byte> {
    let out = Array<Byte>(vals.size, repeat: 0u8)
    for (i in 0..vals.size) {
        out[i] = UInt8(vals[i])
    }
    return out
}

/** 把一串 Int64 转成 Array<String>（权限码集合用） */
func stringsOf(vals: Array<String>): Array<String> {
    let out = Array<String>(vals.size, repeat: "")
    for (i in 0..vals.size) {
        out[i] = vals[i]
    }
    return out
}

// ============================================================
// ① 字符表
// ============================================================

@Test
public class InviteAlphabetTest {
    @TestCase
    public func testAlphabetIs32Runes() {
        // 32 个字符 × 每位 5 bit → 8 位正好 40 bit 熵
        @Assert(InviteCode.ALPHABET.size, 32)
    }

    @TestCase
    public func testAlphabetExcludesAmbiguousChars() {
        // 去掉 0 / 1 / I / O：手工抄写与口头念读不出错
        @Assert(InviteCode.ALPHABET.contains("0"), false)
        @Assert(InviteCode.ALPHABET.contains("1"), false)
        @Assert(InviteCode.ALPHABET.contains("I"), false)
        @Assert(InviteCode.ALPHABET.contains("O"), false)
        // L 保留（已无 1，不再有歧义）
        @Assert(InviteCode.ALPHABET.contains("L"), true)
    }

    @TestCase
    public func testCodeLengthIs8() {
        @Assert(InviteCode.LENGTH, 8)
    }
}

// ============================================================
// ② 生成
// ============================================================

@Test
public class InviteGenerateTest {
    @TestCase
    public func testGenerateIsDeterministic() {
        // 同样输入必须同样输出 —— 否则「生成逻辑可复现」无从谈起
        let b = bytesOf([0, 1, 2, 3, 4, 5, 6, 7])
        @Assert(InviteCode.generate(b), "23456789")
        @Assert(InviteCode.generate(b), InviteCode.generate(b))
    }

    @TestCase
    public func testGenerateUpperBound() {
        // 低 5 bit 全 1 → 字符表末位 'Z'
        @Assert(InviteCode.generate(bytesOf([31, 31, 31, 31, 31, 31, 31, 31])), "ZZZZZZZZ")
        // 0xFF & 31 = 31，同样落到 'Z'（掩码而非取模：256 % 32 == 0 时两者一致，
        // 但仍要确认高位被丢弃而不是溢出）
        @Assert(InviteCode.generate(bytesOf([255, 255, 255, 255, 255, 255, 255, 255])), "ZZZZZZZZ")
    }

    @TestCase
    public func testGenerateIndexWindow() {
        // 8..15 正好落在第二段字母 'A'..'H'
        @Assert(InviteCode.generate(bytesOf([8, 9, 10, 11, 12, 13, 14, 15])), "ABCDEFGH")
        // 高位被掩掉：0x28 = 40，40 & 31 = 8 → 'A'
        @Assert(InviteCode.generate(bytesOf([40, 41, 42, 43, 44, 45, 46, 47])), "ABCDEFGH")
    }

    @TestCase
    public func testGenerateRejectsShortRandom() {
        // 随机源短于 LENGTH 时返回空串，由调用方判失败 —— 绝不能「凑几个字节继续走」
        @Assert(InviteCode.generate(Array<Byte>(0, repeat: 0u8)), "")
        @Assert(InviteCode.generate(bytesOf([1, 2, 3, 4, 5, 6, 7])), "")
    }

    @TestCase
    public func testGeneratedCodeAlwaysWellFormed() {
        // 任意字节都必须产出通过格式校验的码（否则用户「正确输入」也被拒）
        var ok = true
        for (v in 0..256) {
            let b = bytesOf([v, v, v, v, v, v, v, v])
            if (!InviteCode.isWellFormed(InviteCode.generate(b))) {
                ok = false
            }
        }
        @Assert(ok, true)
    }
}

// ============================================================
// ③ 规范化
// ============================================================

@Test
public class InviteNormalizeTest {
    @TestCase
    public func testLowercaseToUppercase() {
        @Assert(InviteCode.normalize("abcdefgh"), "ABCDEFGH")
        @Assert(InviteCode.normalize("AbCdEfGh"), "ABCDEFGH")
    }

    @TestCase
    public func testStripsSeparators() {
        // 用户会输入 2345-6789 / 2345 6789 / 2345_6789
        @Assert(InviteCode.normalize("2345-6789"), "23456789")
        @Assert(InviteCode.normalize("2345 6789"), "23456789")
        @Assert(InviteCode.normalize("2345_6789"), "23456789")
        @Assert(InviteCode.normalize(" 23456789 "), "23456789")
    }

    @TestCase
    public func testStripsControlWhitespace() {
        // 制表 / 换行 / 回车（粘贴时常带进来）
        @Assert(InviteCode.normalize("2345\t6789"), "23456789")
        @Assert(InviteCode.normalize("2345\n6789"), "23456789")
        @Assert(InviteCode.normalize("2345\r\n6789"), "23456789")
    }

    @TestCase
    public func testNormalizeThenWellFormed() {
        // 规范化之后才校验 —— 若先校验再规范化，「小写但正确」会被误判为错，
        // 而失败上限只有 5 次，这种误判的代价很真实
        @Assert(InviteCode.isWellFormed("abcdefgh"), false)
        @Assert(InviteCode.isWellFormed(InviteCode.normalize("abcdefgh")), true)
    }

    @TestCase
    public func testNormalizeKeepsDigits() {
        @Assert(InviteCode.normalize("23456789"), "23456789")
    }
}

// ============================================================
// ④ 格式判定
// ============================================================

@Test
public class InviteWellFormedTest {
    @TestCase
    public func testAcceptsAllAlphabetChars() {
        @Assert(InviteCode.isWellFormed("ABCDEFGH"), true)
        @Assert(InviteCode.isWellFormed("JKLMNPQR"), true)
        @Assert(InviteCode.isWellFormed("STUVWXYZ"), true)
        @Assert(InviteCode.isWellFormed("23456789"), true)
    }

    @TestCase
    public func testRejectsWrongLength() {
        @Assert(InviteCode.isWellFormed(""), false)
        @Assert(InviteCode.isWellFormed("ABCDEFG"), false)
        @Assert(InviteCode.isWellFormed("ABCDEFGHJ"), false)
    }

    @TestCase
    public func testRejectsAmbiguousChars() {
        // 0 / 1 / I / O 不在字符表内：命中即拒，不必查库
        @Assert(InviteCode.isWellFormed("ABCDEFG0"), false)
        @Assert(InviteCode.isWellFormed("ABCDEFG1"), false)
        @Assert(InviteCode.isWellFormed("ABCDEFGI"), false)
        @Assert(InviteCode.isWellFormed("ABCDEFGO"), false)
    }

    @TestCase
    public func testRejectsLowercase() {
        // 小写属于「格式未规范化」，应走 normalize 而不是直接放过
        @Assert(InviteCode.isWellFormed("abcdefgh"), false)
    }

    @TestCase
    public func testRejectsPunctuationAndCjk() {
        @Assert(InviteCode.isWellFormed("ABCD-EFG"), false)
        @Assert(InviteCode.isWellFormed("ABCD EFG"), false)
        @Assert(InviteCode.isWellFormed("邀请码邀请码邀请"), false)
    }
}

// ============================================================
// ⑤ 失效判定顺序
// ============================================================

@Test
public class InviteStateTest {
    /** now = 1_000_000，邀请在 2_000_000 过期 */
    private static let NOW: Int64 = 1_000_000
    private static let LATER: Int64 = 2_000_000

    @TestCase
    public func testUsable() {
        let s = InviteSnapshot(false, LATER, 0, 1, 0, 5)
        @Assert(s.stateAt(NOW).reason(), "usable")
        @Assert(s.stateAt(NOW).isDead(), false)
    }

    @TestCase
    public func testRevokedBeatsEverything() {
        // 撤销 + 已过期 + 已用尽 + 失败超限：一律报「已撤销」
        let s = InviteSnapshot(true, LATER, 1, 1, 5, 5)
        @Assert(s.stateAt(NOW).reason(), "revoked")
    }

    @TestCase
    public func testFailLimitBeatsExpired() {
        // 失败超限排在过期之前：运维要能区分「被人试出来了」与「放太久了」
        let s = InviteSnapshot(false, LATER, 0, 1, 5, 5)
        @Assert(s.stateAt(NOW).reason(), "too_many_fails")
    }

    @TestCase
    public func testExpiredBeatsExhausted() {
        let s = InviteSnapshot(false, NOW, 1, 1, 0, 5)
        @Assert(s.stateAt(NOW).reason(), "expired")
    }

    @TestCase
    public func testExhausted() {
        let s = InviteSnapshot(false, LATER, 1, 1, 0, 5)
        @Assert(s.stateAt(NOW).reason(), "exhausted")
    }

    @TestCase
    public func testExpiryBoundaryIsInclusive() {
        // now == expires 即视为过期（不放宽 1 毫秒，避免边界上的争议）
        let s = InviteSnapshot(false, NOW, 0, 1, 0, 5)
        @Assert(s.stateAt(NOW).reason(), "expired")
        // now == expires - 1 仍可用
        let s2 = InviteSnapshot(false, NOW, 0, 1, 0, 5)
        @Assert(s2.stateAt(NOW - 1).reason(), "usable")
    }

    @TestCase
    public func testZeroExpiryMeansNeverExpires() {
        // expiresMs = 0 表示不限期（内部用法），不能被判成「已过期」
        let s = InviteSnapshot(false, 0, 0, 1, 0, 5)
        @Assert(s.stateAt(NOW).reason(), "usable")
    }

    @TestCase
    public func testZeroMaxFailsDisablesFailLimit() {
        // maxFails = 0 表示不启用失败上限
        let s = InviteSnapshot(false, LATER, 0, 1, 99, 0)
        @Assert(s.stateAt(NOW).reason(), "usable")
    }

    @TestCase
    public func testIsDeadCoversAllNonUsable() {
        @Assert(InviteSnapshot(false, LATER, 0, 1, 0, 5).stateAt(NOW).isDead(), false)
        @Assert(InviteSnapshot(true, LATER, 0, 1, 0, 5).stateAt(NOW).isDead(), true)
        @Assert(InviteSnapshot(false, NOW, 0, 1, 0, 5).stateAt(NOW).isDead(), true)
        @Assert(InviteSnapshot(false, LATER, 1, 1, 0, 5).stateAt(NOW).isDead(), true)
        @Assert(InviteSnapshot(false, LATER, 0, 1, 5, 5).stateAt(NOW).isDead(), true)
    }
}

// ============================================================
// ⑥ 剩余次数
// ============================================================

@Test
public class InviteRemainingTest {
    private static let NOW: Int64 = 1_000_000
    private static let LATER: Int64 = 2_000_000

    @TestCase
    public func testRemainingWhileUsable() {
        @Assert(InviteSnapshot(false, LATER, 0, 3, 0, 5).remainingUses(NOW), 3)
        @Assert(InviteSnapshot(false, LATER, 2, 3, 0, 5).remainingUses(NOW), 1)
    }

    @TestCase
    public func testRemainingIsZeroWhenDead() {
        // 已失效时不给「负数剩余」，界面直接显示 0
        @Assert(InviteSnapshot(true, LATER, 0, 3, 0, 5).remainingUses(NOW), 0)
        @Assert(InviteSnapshot(false, NOW, 0, 3, 0, 5).remainingUses(NOW), 0)
        @Assert(InviteSnapshot(false, LATER, 3, 3, 0, 5).remainingUses(NOW), 0)
    }
}

// ============================================================
// ⑦ 有效期与次数钳制
// ============================================================

@Test
public class InviteLimitsTest {
    @TestCase
    public func testMinutesDefaults() {
        // 非正数（未传 / 传 0 / 笔误负数）一律回落到默认 15 分钟
        @Assert(InviteLimits.clampMinutes(0), 15)
        @Assert(InviteLimits.clampMinutes(-30), 15)
    }

    @TestCase
    public func testMinutesUpperBound() {
        @Assert(InviteLimits.clampMinutes(1440), 1440)
        @Assert(InviteLimits.clampMinutes(1441), 1440)
        @Assert(InviteLimits.clampMinutes(999999), 1440)
    }

    @TestCase
    public func testMinutesPassThrough() {
        @Assert(InviteLimits.clampMinutes(1), 1)
        @Assert(InviteLimits.clampMinutes(60), 60)
    }

    @TestCase
    public func testUsesDefaults() {
        @Assert(InviteLimits.clampUses(0), 1)
        @Assert(InviteLimits.clampUses(-3), 1)
    }

    @TestCase
    public func testUsesUpperBound() {
        @Assert(InviteLimits.clampUses(10), 10)
        @Assert(InviteLimits.clampUses(11), 10)
    }

    @TestCase
    public func testUsesPassThrough() {
        @Assert(InviteLimits.clampUses(1), 1)
        @Assert(InviteLimits.clampUses(5), 5)
    }

    @TestCase
    public func testConstants() {
        @Assert(InviteLimits.DEFAULT_MINUTES, 15)
        @Assert(InviteLimits.MAX_MINUTES, 1440)
        @Assert(InviteLimits.DEFAULT_USES, 1)
        @Assert(InviteLimits.MAX_USES, 10)
        @Assert(InviteLimits.DEFAULT_MAX_FAILS, 5)
    }
}

// ============================================================
// ⑧ 角色矩阵
// ============================================================

@Test
public class FamilyRoleTest {
    @TestCase
    public func testCodes() {
        @Assert(FamilyRole.Owner.code(), "owner")
        @Assert(FamilyRole.Manager.code(), "manager")
        @Assert(FamilyRole.Member.code(), "member")
    }

    @TestCase
    public func testFromCodeRoundTrip() {
        @Assert(FamilyRole.fromCode("owner").code(), "owner")
        @Assert(FamilyRole.fromCode("manager").code(), "manager")
        @Assert(FamilyRole.fromCode("member").code(), "member")
    }

    @TestCase
    public func testUnknownRoleDegradesToMember() {
        // **最小权限**降级：脏数据 / 未来新增角色都不得意外获得管理能力
        @Assert(FamilyRole.fromCode("").code(), "member")
        @Assert(FamilyRole.fromCode("OWNER").code(), "member")
        @Assert(FamilyRole.fromCode("superuser").code(), "member")
    }

    @TestCase
    public func testInviteAndGrant() {
        @Assert(FamilyRole.Owner.canInvite(), true)
        @Assert(FamilyRole.Manager.canInvite(), true)
        @Assert(FamilyRole.Member.canInvite(), false)

        @Assert(FamilyRole.Owner.canGrant(), true)
        @Assert(FamilyRole.Manager.canGrant(), true)
        @Assert(FamilyRole.Member.canGrant(), false)
    }

    @TestCase
    public func testRemoveMatrix() {
        // Owner 可移除任何人
        @Assert(FamilyRole.Owner.canRemove(FamilyRole.Owner), true)
        @Assert(FamilyRole.Owner.canRemove(FamilyRole.Manager), true)
        @Assert(FamilyRole.Owner.canRemove(FamilyRole.Member), true)
        // Manager 只能移除 Member —— 否则被提升的人可以把管理层踢空再独吞
        @Assert(FamilyRole.Manager.canRemove(FamilyRole.Member), true)
        @Assert(FamilyRole.Manager.canRemove(FamilyRole.Manager), false)
        @Assert(FamilyRole.Manager.canRemove(FamilyRole.Owner), false)
        // Member 谁都不能移除
        @Assert(FamilyRole.Member.canRemove(FamilyRole.Member), false)
    }

    @TestCase
    public func testOwnerOnlyActions() {
        @Assert(FamilyRole.Owner.canDissolve(), true)
        @Assert(FamilyRole.Manager.canDissolve(), false)
        @Assert(FamilyRole.Member.canDissolve(), false)

        @Assert(FamilyRole.Owner.canPromote(), true)
        @Assert(FamilyRole.Manager.canPromote(), false)
        @Assert(FamilyRole.Member.canPromote(), false)
    }

    @TestCase
    public func testIsOwner() {
        @Assert(FamilyRole.Owner.isOwner(), true)
        @Assert(FamilyRole.Manager.isOwner(), false)
        @Assert(FamilyRole.Member.isOwner(), false)
    }
}

// ============================================================
// ⑨ 授权范围
// ============================================================

@Test
public class GrantScopeTest {
    @TestCase
    public func testItemWins() {
        // 条目级命中即放行，不再看分类与主体
        @Assert(GrantScope.resourceTypeOf("123", 0), "item")
        @Assert(GrantScope.resourceTypeOf("123", 5), "item")
    }

    @TestCase
    public func testCategory() {
        @Assert(GrantScope.resourceTypeOf("", 5), "category")
        @Assert(GrantScope.resourceTypeOf("0", 5), "category")
    }

    @TestCase
    public func testSubject() {
        @Assert(GrantScope.resourceTypeOf("", 0), "subject")
        @Assert(GrantScope.resourceTypeOf("0", 0), "subject")
    }

    @TestCase
    public func testNormalizeCategory() {
        // 负数归零 = 退回主体级（更宽，但授权人本就有该主体权限，不构成越权）
        @Assert(GrantScope.normalizeCategory(-1), 0)
        @Assert(GrantScope.normalizeCategory(-99), 0)
        @Assert(GrantScope.normalizeCategory(0), 0)
        @Assert(GrantScope.normalizeCategory(7), 7)
    }
}

// ============================================================
// ⑩ 权限子集
// ============================================================

@Test
public class PermSubsetTest {
    @TestCase
    public func testExactMatch() {
        let granted = stringsOf(["archive:read:own"])
        let grantor = stringsOf(["archive:read:own", "archive:write:own"])
        @Assert(PermSubset.isSubsetOf(granted, grantor), true)
    }

    @TestCase
    public func testAnyCoversOwn() {
        // 授权人有 any 时，可以把 own 授出
        let granted = stringsOf(["archive:read:own"])
        let grantor = stringsOf(["archive:read:any"])
        @Assert(PermSubset.isSubsetOf(granted, grantor), true)
    }

    @TestCase
    public func testAnyDoesNotFlowBackwards() {
        // 只有 own 的人**不能**授出 any
        let granted = stringsOf(["archive:read:any"])
        let grantor = stringsOf(["archive:read:own"])
        @Assert(PermSubset.isSubsetOf(granted, grantor), false)
    }

    @TestCase
    public func testMissingCodeRejected() {
        let granted = stringsOf(["archive:export:own"])
        let grantor = stringsOf(["archive:read:any"])
        @Assert(PermSubset.isSubsetOf(granted, grantor), false)
    }

    @TestCase
    public func testEmptyGrantedRejected() {
        // 「授出一片空白」不是合法授权记录
        @Assert(PermSubset.isSubsetOf(Array<String>(0, repeat: ""), stringsOf(["archive:read:any"])), false)
    }

    @TestCase
    public func testEmptyGrantorRejectsEverything() {
        @Assert(PermSubset.isSubsetOf(stringsOf(["archive:read:own"]), Array<String>(0, repeat: "")), false)
    }
}

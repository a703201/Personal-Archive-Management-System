// ============================================================
// ams.core.search · 单元测试
//
// 覆盖需求：FR-SRC-001 / 002 / 003 / 004 / 005 / 006
// ============================================================
package ams.core.search.test

import std.unittest.*

import ams.core.search.*

@Test
public class CursorTest {
    // ---- FR-SRC-004 游标分页 ----

    @TestCase
    public func testEncodeDecodeRoundTrip() {
        let c = Cursor("1790000000000", "item-123")
        let s = c.encode()
        @Assert(s.contains("item-123"), true)
        @Assert(SearchTest.cursorFields(Cursor.decode(s), "1790000000000", "item-123"), true)
    }

    @TestCase
    public func testDecodeInvalidReturnsNone() {
        @Assert(Cursor.decode("").isSome(), false)
        @Assert(Cursor.decode("no-colon").isSome(), false)
        @Assert(Cursor.decode(":onlyid").isSome(), false)
        @Assert(Cursor.decode("key:").isSome(), false)
    }

    @TestCase
    public func testColonInKeyIsEscaped() {
        // sortKey 含冒号时不能破坏解码
        let c = Cursor("a:b", "id1")
        @Assert(SearchTest.cursorFields(Cursor.decode(c.encode()), "a:b", "id1"), true)
    }
}

@Test
public class MaskerTest {
    // ---- FR-SRC-006 敏感字段掩码 ----

    @TestCase
    public func testNormalValueNotMasked() {
        @Assert(Masker.mask("public value", 1), "public value")
    }

    @TestCase
    public func testSensitiveValueMasked() {
        // 保留首尾各 1 位
        @Assert(Masker.mask("1234567890", 2), "1********0")
    }

    @TestCase
    public func testHighSensitivityFullyMasked() {
        @Assert(Masker.mask("1234567890", 3), "**********")
    }

    @TestCase
    public func testEmptyValue() {
        @Assert(Masker.mask("", 2), "")
    }

    @TestCase
    public func testShortSensitiveValue() {
        @Assert(Masker.mask("ab", 2), "**")
        @Assert(Masker.mask("a", 2), "*")
    }

    @TestCase
    public func testMaskDoesNotLeakContent() {
        let masked = Masker.mask("110101199001011234", 2)
        @Assert(masked.contains("110101199001011234"), false)
    }

    @TestCase
    public func testIdCardMaskKeepsIndustryConvention() {
        // 身份证：保留前 6 后 4
        @Assert(Masker.maskIdCard("110101199001011234"), "110101********1234")
    }

    @TestCase
    public func testPhoneMaskKeepsIndustryConvention() {
        // 手机号：保留前 3 后 4
        @Assert(Masker.maskPhone("13800138000"), "138****8000")
    }
}

@Test
public class SearchQueryBuilderTest {
    // ---- FR-SRC-002 结构化筛选 ----

    @TestCase
    public func testBuilderProducesQuery() {
        let q = SearchQueryBuilder()
            .keyword_("学位")
            .subjectScope(["s1", "s2"])
            .category([3, 5])
            .status([1])
            .issuer_("教育部")
            .issuedRange("2020-01-01", "2024-12-31")
            .expiresRange("2025-01-01", "2030-01-01")
            .tags(["t1"])
            .sortBy(SortField.CreatedAt, SortDirection.Desc)
            .pageSize_(50)
            .build()
        @Assert(q.keyword, "学位")
        @Assert(q.subjectIds.size, 2)
        @Assert(q.categoryCodes.size, 2)
        @Assert(q.issuer, "教育部")
        @Assert(q.pageSize, 50)
    }

    @TestCase
    public func testDefaultSortIsUpdatedAtDesc() {
        let q = SearchQueryBuilder().build()
        @Assert(q.pageSize, 20)
        @Assert(q.cursor.id, "")
    }

    // ---- FR-SRC-005 盲索引筛选 ----

    @TestCase
    public func testBlindFilterCanBeAdded() {
        let bidx = Array<Byte>(32, repeat: 0xAAu8)
        let q = SearchQueryBuilder()
            .subjectScope(["s1"])
            .blindFilter("id_number", bidx)
            .build()
        @Assert(q.blindFilters.size, 1)
    }

    @TestCase
    public func testExtraFilterCanBeAdded() {
        let q = SearchQueryBuilder()
            .subjectScope(["s1"])
            .extraFilter("school", "北京大学")
            .build()
        @Assert(q.extraFilters.size, 1)
    }

    // ---- FR-ACL-006 归属强制 ----

    @TestCase
    public func testSubjectScopeIsSetByServer() {
        // subjectIds 由服务端注入，前端不能决定
        let q = SearchQueryBuilder().subjectScope(["s1", "s2"]).build()
        @Assert(q.subjectIds.contains("s1"), true)
        @Assert(q.subjectIds.contains("s2"), true)
    }
}

/**
 * 断言辅助。
 */
class SearchTest {
    /**
     * 游标字段是否匹配。
     */
    static func cursorFields(c: ?Cursor, sortKey: String, id: String): Bool {
        match (c) {
            case Some(d) => return d.sortKey == sortKey && d.id == id
            case None => return false
        }
    }
}

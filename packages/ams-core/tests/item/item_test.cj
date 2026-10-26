// ============================================================
// ams.core.item · 单元测试
//
// 覆盖需求：FR-ARCH-001 / 002 / 003 / 005 / 006 / 007 / 008
//
// [结构约定]：测试代码与产品代码**物理分离**（本文件在 tests/ 目录）。
// [match 约定]：仓颉的 match 分支只能是单个表达式，不能写 { 多行语句 }。
// ============================================================
package ams.core.item.test

import std.collection.*
import std.unittest.*

import ams.core.item.*

@Test
public class ItemStatusTest {
    @TestCase
    public func testStatusCodes() {
        // 与数据模型 §11.2 的 ItemStatus 一致
        @Assert(ItemStatus.Draft.toCode(), 0)
        @Assert(ItemStatus.Active.toCode(), 1)
        @Assert(ItemStatus.Archived.toCode(), 2)
        @Assert(ItemStatus.Deleted.toCode(), 3)
    }

    @TestCase
    public func testStatusRoundTrip() {
        @Assert(ItemTest.eqStatus(ItemStatus.fromCode(0), ItemStatus.Draft), true)
        @Assert(ItemTest.eqStatus(ItemStatus.fromCode(1), ItemStatus.Active), true)
        @Assert(ItemTest.eqStatus(ItemStatus.fromCode(2), ItemStatus.Archived), true)
        @Assert(ItemTest.eqStatus(ItemStatus.fromCode(3), ItemStatus.Deleted), true)
    }
}

@Test
public class ItemStateMachineTest {
    // ---- FR-ARCH-006 状态流转 ----

    @TestCase
    public func testDraftToActive() {
        let r = ItemStateMachine.transition(ItemStatus.Draft, ItemEvent.Save)
        @Assert(r.isOk(), true)
    }

    @TestCase
    public func testActiveToArchived() {
        let r = ItemStateMachine.transition(ItemStatus.Active, ItemEvent.Archive)
        @Assert(r.isOk(), true)
    }

    @TestCase
    public func testArchivedToActive() {
        let r = ItemStateMachine.transition(ItemStatus.Archived, ItemEvent.Unarchive)
        @Assert(r.isOk(), true)
    }

    @TestCase
    public func testActiveToDeleted() {
        let r = ItemStateMachine.transition(ItemStatus.Active, ItemEvent.Delete)
        @Assert(r.isOk(), true)
    }

    @TestCase
    public func testArchivedCannotEdit() {
        // 归档后内容冻结
        let r = ItemStateMachine.transition(ItemStatus.Archived, ItemEvent.Edit)
        @Assert(r.isOk(), false)
    }

    @TestCase
    public func testDeletedOnlyRestore() {
        // 已删除状态只支持恢复
        @Assert(ItemStateMachine.transition(ItemStatus.Deleted, ItemEvent.Restore).isOk(), true)
        @Assert(ItemStateMachine.transition(ItemStatus.Deleted, ItemEvent.Edit).isOk(), false)
        @Assert(ItemStateMachine.transition(ItemStatus.Deleted, ItemEvent.Archive).isOk(), false)
    }

    @TestCase
    public func testDraftCannotArchive() {
        @Assert(ItemStateMachine.transition(ItemStatus.Draft, ItemEvent.Archive).isOk(), false)
    }

    @TestCase
    public func testCanEdit() {
        @Assert(ItemStateMachine.canEdit(ItemStatus.Draft), true)
        @Assert(ItemStateMachine.canEdit(ItemStatus.Active), true)
        @Assert(ItemStateMachine.canEdit(ItemStatus.Archived), false)
        @Assert(ItemStateMachine.canEdit(ItemStatus.Deleted), false)
    }

    // ---- FR-ARCH-008 回收站 ----

    @TestCase
    public func testRecycleBinKeeps30Days() {
        @Assert(ItemStateMachine.recycleBinDays, 30)
    }

    @TestCase
    public func testNotExpiredWithin30Days() {
        let now: Int64 = 1790000000000
        let deletedAt = now - 29 * 86400000
        @Assert(ItemStateMachine.isRecycleExpired(deletedAt, now), false)
        @Assert(ItemStateMachine.canRestore(deletedAt, now), true)
    }

    @TestCase
    public func testExpiredAfter30Days() {
        let now: Int64 = 1790000000000
        let deletedAt = now - 30 * 86400000
        @Assert(ItemStateMachine.isRecycleExpired(deletedAt, now), true)
        @Assert(ItemStateMachine.canRestore(deletedAt, now), false)
    }

    @TestCase
    public func testNotDeletedNeverExpires() {
        @Assert(ItemStateMachine.isRecycleExpired(0, 1790000000000), false)
    }
}

@Test
public class OptimisticLockTest {
    // ---- FR-ARCH-007 乐观锁 ----

    @TestCase
    public func testSameVersionOk() {
        @Assert(OptimisticLock.check(3, 3).isOk(), true)
    }

    @TestCase
    public func testDifferentVersionConflict() {
        let r = OptimisticLock.check(3, 5)
        @Assert(r.isConflict(), true)
        @Assert(r.isOk(), false)
    }

    @TestCase
    public func testVersionIncrements() {
        @Assert(OptimisticLock.nextVersion(1), 2)
        @Assert(OptimisticLock.nextVersion(99), 100)
    }

    @TestCase
    public func testConflictDescription() {
        let msg = OptimisticLock.describeConflict(3, 5, ["title", "issuer"])
        @Assert(msg.contains("3"), true)
        @Assert(msg.contains("5"), true)
        @Assert(msg.contains("title"), true)
        @Assert(msg.contains("issuer"), true)
    }
}

@Test
public class FieldValidatorTest {
    private func requiredDef(key: String, name: String, ftype: FieldType): FieldDef {
        return FieldDef(key, name, ftype, ItemSensitivity.Normal, true, true, true, false, 1, "", "", true)
    }

    private func optionalDef(key: String, name: String, ftype: FieldType): FieldDef {
        return FieldDef(key, name, ftype, ItemSensitivity.Normal, false, true, true, false, 1, "", "", true)
    }

    // ---- FR-ARCH-001 必填校验 ----

    @TestCase
    public func testMissingRequiredFieldFails() {
        let defs = [this.requiredDef("school", "学校名称", FieldType.Text)]
        let r = FieldValidator.validate(defs, Array<FieldValue>())
        @Assert(r.isSome(), true)
    }

    @TestCase
    public func testPresentRequiredFieldPasses() {
        let defs = [this.requiredDef("school", "学校名称", FieldType.Text)]
        let values = [FieldValue.ofText("school", "北京大学")]
        @Assert(FieldValidator.validate(defs, values).isSome(), false)
    }

    @TestCase
    public func testEmptyRequiredFieldFails() {
        let defs = [this.requiredDef("school", "学校名称", FieldType.Text)]
        let values = [FieldValue.ofText("school", "")]
        @Assert(FieldValidator.validate(defs, values).isSome(), true)
    }

    // ---- FR-ARCH-001 格式校验 ----

    @TestCase
    public func testEmailFormat() {
        @Assert(FieldValidator.isEmail("user@example.com"), true)
        @Assert(FieldValidator.isEmail("user@sub.example.com"), true)
        @Assert(FieldValidator.isEmail("userexample.com"), false)
        @Assert(FieldValidator.isEmail("user@"), false)
        @Assert(FieldValidator.isEmail("@example.com"), false)
        @Assert(FieldValidator.isEmail("user@example"), false)
    }

    @TestCase
    public func testPhoneFormat() {
        @Assert(FieldValidator.isPhone("13800138000"), true)
        @Assert(FieldValidator.isPhone("1380013800"), false)   // 10 位
        @Assert(FieldValidator.isPhone("138001380001"), false) // 12 位
        @Assert(FieldValidator.isPhone("23800138000"), false)  // 不以 1 开头
        @Assert(FieldValidator.isPhone("1380013800a"), false)  // 非数字
    }

    @TestCase
    public func testIdCardFormat() {
        @Assert(FieldValidator.isIdCard("110101199001011234"), true)
        @Assert(FieldValidator.isIdCard("11010119900101123X"), true)
        @Assert(FieldValidator.isIdCard("1101011990010112"), false)
        @Assert(FieldValidator.isIdCard("11010119900101123"), false)
    }

    @TestCase
    public func testUrlFormat() {
        @Assert(FieldValidator.isUrl("https://example.com/path"), true)
        @Assert(FieldValidator.isUrl("http://a.b"), true)
        @Assert(FieldValidator.isUrl("example.com"), false)
        @Assert(FieldValidator.isUrl("https://nodomain"), false)
    }

    @TestCase
    public func testInvalidEmailInValueIsReported() {
        let defs = [this.optionalDef("email", "邮箱", FieldType.Email)]
        let values = [FieldValue.ofText("email", "not-an-email")]
        @Assert(FieldValidator.validate(defs, values).isSome(), true)
    }
}

@Test
public class CategoryCatalogTest {
    // ---- FR-ARCH-005 分类模板预置 ----

    @TestCase
    public func testElevenBuiltinCategories() {
        @Assert(CategoryCatalog.all().size, 11)
    }

    @TestCase
    public func testCategoryCodesMatchSpec() {
        // 数据模型 §11.2：1 basic / 2 identity / ... / 11 custom
        @Assert(ArchiveCategory.Basic.toCode(), 1)
        @Assert(ArchiveCategory.Identity.toCode(), 2)
        @Assert(ArchiveCategory.Education.toCode(), 3)
        @Assert(ArchiveCategory.Experience.toCode(), 4)
        @Assert(ArchiveCategory.Certificate.toCode(), 5)
        @Assert(ArchiveCategory.Contact.toCode(), 6)
        @Assert(ArchiveCategory.Family.toCode(), 7)
        @Assert(ArchiveCategory.Health.toCode(), 8)
        @Assert(ArchiveCategory.Asset.toCode(), 9)
        @Assert(ArchiveCategory.Impression.toCode(), 10)
        @Assert(ArchiveCategory.Custom.toCode(), 11)
    }

    @TestCase
    public func testHighSensitivityCategories() {
        // health / asset → high（默认仅所有者可见）
        @Assert(ItemTest.eqSens(ArchiveCategory.Health.defaultSensitivity(), ItemSensitivity.High), true)
        @Assert(ItemTest.eqSens(ArchiveCategory.Asset.defaultSensitivity(), ItemSensitivity.High), true)
    }

    @TestCase
    public func testSensitiveCategories() {
        // identity / contact / family → sensitive
        @Assert(ItemTest.eqSens(ArchiveCategory.Identity.defaultSensitivity(), ItemSensitivity.Sensitive), true)
        @Assert(ItemTest.eqSens(ArchiveCategory.Contact.defaultSensitivity(), ItemSensitivity.Sensitive), true)
        @Assert(ItemTest.eqSens(ArchiveCategory.Family.defaultSensitivity(), ItemSensitivity.Sensitive), true)
    }

    @TestCase
    public func testNormalCategories() {
        @Assert(ItemTest.eqSens(ArchiveCategory.Basic.defaultSensitivity(), ItemSensitivity.Normal), true)
        @Assert(ItemTest.eqSens(ArchiveCategory.Education.defaultSensitivity(), ItemSensitivity.Normal), true)
    }

    @TestCase
    public func testEveryCategoryHasTemplate() {
        for (c in CategoryCatalog.all()) {
            let tpl = CategoryCatalog.template(c)
            @Assert(tpl.isEmpty(), false)
        }
    }

    @TestCase
    public func testIdentityTemplateHasSensitiveIdField() {
        // 身份证字段必须是敏感且支持盲索引
        let tpl = CategoryCatalog.template(ArchiveCategory.Identity)
        var found = false
        for (d in tpl) {
            if (d.fieldKey == "id_number") {
                found = true
                @Assert(ItemTest.eqSens(d.sensitivity, ItemSensitivity.Sensitive), true)
                @Assert(d.isBidxCapable, true)
                @Assert(ItemTest.eqType(d.dataType, FieldType.IdCard), true)
            }
        }
        @Assert(found, true)
    }

    @TestCase
    public func testContactTemplateHasPhoneWithBidx() {
        let tpl = CategoryCatalog.template(ArchiveCategory.Contact)
        var found = false
        for (d in tpl) {
            if (d.fieldKey == "phone") {
                found = true
                @Assert(d.isBidxCapable, true)
                @Assert(ItemTest.eqType(d.dataType, FieldType.Phone), true)
            }
        }
        @Assert(found, true)
    }

    @TestCase
    public func testFieldKeysUniqueInTemplate() {
        for (c in CategoryCatalog.all()) {
            let tpl = CategoryCatalog.template(c)
            let keys = ArrayList<String>()
            for (d in tpl) {
                @Assert(keys.contains(d.fieldKey), false)
                keys.add(d.fieldKey)
            }
        }
    }

    @TestCase
    public func testFieldTypeCodesMatchSpec() {
        // 数据模型 §11.2：FieldDataType 1..11
        @Assert(FieldType.Text.toCode(), 1)
        @Assert(FieldType.Number.toCode(), 2)
        @Assert(FieldType.Date.toCode(), 3)
        @Assert(FieldType.Enum.toCode(), 4)
        @Assert(FieldType.MultiEnum.toCode(), 5)
        @Assert(FieldType.`Bool`.toCode(), 6)
        @Assert(FieldType.Email.toCode(), 7)
        @Assert(FieldType.Phone.toCode(), 8)
        @Assert(FieldType.IdCard.toCode(), 9)
        @Assert(FieldType.Url.toCode(), 10)
        @Assert(FieldType.Json.toCode(), 11)
    }
}

/**
 * 枚举比较辅助。
 *
 * 仓颉的 enum 不支持 == 运算符（编译报
 * "invalid binary operator '==' on type 'Enum-XXX'"），
 * 故统一用 match 判定后比较。
 */
class ItemTest {
    static func eqStatus(a: ItemStatus, b: ItemStatus): Bool {
        match (a) {
            case ItemStatus.Draft => return match (b) {
                case ItemStatus.Draft => true
                case _ => false
            }
            case ItemStatus.Active => return match (b) {
                case ItemStatus.Active => true
                case _ => false
            }
            case ItemStatus.Archived => return match (b) {
                case ItemStatus.Archived => true
                case _ => false
            }
            case ItemStatus.Deleted => return match (b) {
                case ItemStatus.Deleted => true
                case _ => false
            }
        }
    }

    static func eqSens(a: ItemSensitivity, b: ItemSensitivity): Bool {
        match (a) {
            case ItemSensitivity.Normal => return match (b) {
                case ItemSensitivity.Normal => true
                case _ => false
            }
            case ItemSensitivity.Sensitive => return match (b) {
                case ItemSensitivity.Sensitive => true
                case _ => false
            }
            case ItemSensitivity.High => return match (b) {
                case ItemSensitivity.High => true
                case _ => false
            }
        }
    }

    static func eqType(a: FieldType, b: FieldType): Bool {
        match (a) {
            case FieldType.Text => return match (b) {
                case FieldType.Text => true
                case _ => false
            }
            case FieldType.Number => return match (b) {
                case FieldType.Number => true
                case _ => false
            }
            case FieldType.Date => return match (b) {
                case FieldType.Date => true
                case _ => false
            }
            case FieldType.Enum => return match (b) {
                case FieldType.Enum => true
                case _ => false
            }
            case FieldType.MultiEnum => return match (b) {
                case FieldType.MultiEnum => true
                case _ => false
            }
            case FieldType.`Bool` => return match (b) {
                case FieldType.`Bool` => true
                case _ => false
            }
            case FieldType.Email => return match (b) {
                case FieldType.Email => true
                case _ => false
            }
            case FieldType.Phone => return match (b) {
                case FieldType.Phone => true
                case _ => false
            }
            case FieldType.IdCard => return match (b) {
                case FieldType.IdCard => true
                case _ => false
            }
            case FieldType.Url => return match (b) {
                case FieldType.Url => true
                case _ => false
            }
            case FieldType.Json => return match (b) {
                case FieldType.Json => true
                case _ => false
            }
        }
    }
}

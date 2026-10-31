// ============================================================
// ams.core.item · 状态机 / 乐观锁 / 回收站
//
// 需求：
//   FR-ARCH-006 条目状态流转（draft → active → archived → deleted）
//   FR-ARCH-007 乐观锁与冲突提示（version 递增；冲突返回 409，不静默覆盖）
//   FR-ARCH-008 软删除与回收站（保留 30 天；恢复需有权限）
//
// [状态机]（PRD §6.2.2）
//   draft ──保存并归档──► active
//   draft ──删除────────► deleted
//   active ──编辑───────► active（版本递增）
//   active ──归档───────► archived（冻结编辑）
//   active ──删除───────► deleted
//   archived ──恢复编辑─► active
//   archived ──删除─────► deleted
//   deleted ──恢复─────► active（需权限，且未超保留期）
//
// [不变量]
//   - archived 状态禁止编辑（内容冻结）
//   - deleted 状态只能恢复到 active（不能恢复到 draft/archived）
//   - 任何写操作都必须递增 version
//   - 乐观锁冲突时**不修改**任何数据，由上层返回 409
// ============================================================
package ams.core.item

import std.collection.*

/**
 * 状态流转事件。
 */
public enum ItemEvent {
    | Save       // 保存（draft → active）
    | Edit       // 编辑
    | Archive    // 归档
    | Unarchive  // 恢复编辑
    | Delete     // 删除（软删除，进回收站）
    | Restore    // 从回收站恢复
}

/**
 * 流转结果。
 */
public enum TransitionResult {
    | Ok(ItemStatus)
    /** 不允许的流转 */
    | NotAllowed(String)
    /** 乐观锁冲突：期望版本与实际版本不符 */
    | Conflict
    /** 回收站保留期已过，无法恢复 */
    | Expired

    /**
     * 是否成功。
     */
    public func isOk(): Bool {
        match (this) {
            case TransitionResult.Ok(_) => return true
            case _ => return false
        }
    }

    /**
     * 是否为冲突。
     */
    public func isConflict(): Bool {
        match (this) {
            case TransitionResult.Conflict => return true
            case _ => return false
        }
    }

    /**
     * 冲突详情（期望版本、实际版本）；非冲突时返回 (0, 0)。
     */
    public func conflictSeq(): (Int64, Int64) {
        match (this) {
            case TransitionResult.Conflict => return (0, 0)
            case _ => return (0, 0)
        }
    }
}

/**
 * 条目状态机。
 */
public class ItemStateMachine {
    /**
     * 回收站保留天数（FR-ARCH-008：30 天）。
     */
    public static let recycleBinDays: Int64 = 30

    /**
     * 判定一次流转是否合法。
     *
     * @param from 当前状态
     * @param event 事件
     * @return 允许 → Ok(目标状态)；否则 → NotAllowed(原因)
     */
    public static func transition(from: ItemStatus, event: ItemEvent): TransitionResult {
        match (from) {
            case ItemStatus.Draft => return ItemStateMachine.fromDraft(event)
            case ItemStatus.Active => return ItemStateMachine.fromActive(event)
            case ItemStatus.Archived => return ItemStateMachine.fromArchived(event)
            case ItemStatus.Deleted => return ItemStateMachine.fromDeleted(event)
        }
    }

    /**
     * draft 的合法流转。
     */
    private static func fromDraft(event: ItemEvent): TransitionResult {
        match (event) {
            case ItemEvent.Save => return TransitionResult.Ok(ItemStatus.Active)
            case ItemEvent.Delete => return TransitionResult.Ok(ItemStatus.Deleted)
            case ItemEvent.Edit => return TransitionResult.Ok(ItemStatus.Draft)
            case _ => return TransitionResult.NotAllowed("草稿状态不支持该操作")
        }
    }

    /**
     * active 的合法流转。
     */
    private static func fromActive(event: ItemEvent): TransitionResult {
        match (event) {
            case ItemEvent.Edit => return TransitionResult.Ok(ItemStatus.Active)
            case ItemEvent.Archive => return TransitionResult.Ok(ItemStatus.Archived)
            case ItemEvent.Delete => return TransitionResult.Ok(ItemStatus.Deleted)
            case ItemEvent.Save => return TransitionResult.Ok(ItemStatus.Active)
            case _ => return TransitionResult.NotAllowed("正常状态不支持该操作")
        }
    }

    /**
     * archived 的合法流转（内容冻结，只能恢复编辑或删除）。
     */
    private static func fromArchived(event: ItemEvent): TransitionResult {
        match (event) {
            case ItemEvent.Unarchive => return TransitionResult.Ok(ItemStatus.Active)
            case ItemEvent.Delete => return TransitionResult.Ok(ItemStatus.Deleted)
            case _ => return TransitionResult.NotAllowed("归档状态内容已冻结")
        }
    }

    /**
     * deleted 的合法流转（仅能恢复）。
     */
    private static func fromDeleted(event: ItemEvent): TransitionResult {
        match (event) {
            case ItemEvent.Restore => return TransitionResult.Ok(ItemStatus.Active)
            case _ => return TransitionResult.NotAllowed("已删除状态不支持该操作")
        }
    }

    /**
     * 是否允许编辑（archived 冻结）。
     */
    public static func canEdit(status: ItemStatus): Bool {
        match (status) {
            case ItemStatus.Draft => return true
            case ItemStatus.Active => return true
            case ItemStatus.Archived => return false
            case ItemStatus.Deleted => return false
        }
    }

    /**
     * 回收站保留期是否已过（到期可物理清理）。
     */
    public static func isRecycleExpired(deletedAt: Int64, nowMillis: Int64): Bool {
        if (deletedAt == 0) {
            return false
        }
        let days = (nowMillis - deletedAt) / 86400000
        return days >= ItemStateMachine.recycleBinDays
    }

    /**
     * 恢复前检查：是否已超保留期。
     */
    public static func canRestore(deletedAt: Int64, nowMillis: Int64): Bool {
        return !ItemStateMachine.isRecycleExpired(deletedAt, nowMillis)
    }
}

/**
 * 乐观锁辅助（FR-ARCH-007）。
 */
public class OptimisticLock {
    /**
     * 校验期望版本。
     *
     * @param expectedVersion 客户端提交的版本号
     * @param actualVersion 数据库中的当前版本号
     * @return 一致 → Ok；不一致 → Conflict
     */
    public static func check(expectedVersion: Int64, actualVersion: Int64): TransitionResult {
        if (expectedVersion == actualVersion) {
            return TransitionResult.Ok(ItemStatus.Active)
        }
        return TransitionResult.Conflict
    }

    /**
     * 冲突详情（供上层组装 409 响应）。
     */
    public static func conflictInfo(expectedVersion: Int64, actualVersion: Int64): (Int64, Int64) {
        return (expectedVersion, actualVersion)
    }

    /**
     * 递增版本号。
     */
    public static func nextVersion(current: Int64): Int64 {
        return current + 1
    }

    /**
     * 冲突差异描述（供前端展示，FR-ARCH-007「展示差异，不静默覆盖」）。
     */
    public static func describeConflict(
        expectedVersion: Int64,
        actualVersion: Int64,
        changedFields: Array<String>
    ): String {
        var sb = StringBuilder()
        sb.append("数据已被他人修改（您基于版本 ")
        sb.append(expectedVersion.toString())
        sb.append("，当前版本 ")
        sb.append(actualVersion.toString())
        sb.append("）。冲突字段：")
        for (i in 0..changedFields.size) {
            if (i > 0) {
                sb.append("、")
            }
            sb.append(changedFields[i])
        }
        return sb.toString()
    }
}

/**
 * 字段值校验器（FR-ARCH-001：必填与格式校验，**后端为准**）。
 */
public class FieldValidator {
    /**
     * 校验一组字段值。
     *
     * @param defs 字段定义
     * @param values 字段取值
     * @return 全部通过 → None；否则 → 错误信息数组
     */
    public static func validate(
        defs: Array<FieldDef>,
        values: Array<FieldValue>
    ): ?Array<String> {
        var errors = ArrayList<String>()
        for (d in defs) {
            let v = FieldValidator.findValue(values, d.fieldKey)
            if (d.isRequired) {
                match (v) {
                    case Some(x) => errors = FieldValidator.checkRequired(d, x, errors)
                    case None => errors.add("字段「${d.fieldName}」为必填")
                }
            }
            match (v) {
                case Some(x) => FieldValidator.checkFormat(d, x, errors)
                case None => ()
            }
        }
        if (errors.isEmpty()) {
            return None
        }
        return errors.toArray()
    }

    /**
     * 必填校验（抽成方法以适配 match 的表达式语义）。
     */
    private static func checkRequired(
        d: FieldDef,
        v: FieldValue,
        errors: ArrayList<String>
    ): ArrayList<String> {
        if (!FieldValidator.hasContent(v)) {
            errors.add("字段「${d.fieldName}」为必填")
        }
        return errors
    }

    /**
     * 查找字段取值。
     */
    private static func findValue(
        values: Array<FieldValue>,
        key: String
    ): ?FieldValue {
        for (v in values) {
            if (v.fieldKey == key) {
                return Some(v)
            }
        }
        return None
    }

    /**
     * 是否有效内容。
     */
    private static func hasContent(v: FieldValue): Bool {
        if (v.sensitivePlain != "") {
            return true
        }
        if (v.text != "") {
            return true
        }
        if (v.boolValue) {
            return true
        }
        return v.number != 0.0
    }

    /**
     * 格式校验（按类型）。
     */
    private static func checkFormat(
        d: FieldDef,
        v: FieldValue,
        errors: ArrayList<String>
    ): Unit {
        let raw = if (v.sensitivePlain != "") { v.sensitivePlain } else { v.text }
        if (raw == "") {
            return
        }
        match (d.dataType) {
            case FieldType.Email => FieldValidator.checkEmail(d, raw, errors)
            case FieldType.Phone => FieldValidator.checkPhone(d, raw, errors)
            case FieldType.IdCard => FieldValidator.checkIdCard(d, raw, errors)
            case FieldType.Url => FieldValidator.checkUrl(d, raw, errors)
            case _ => ()
        }
    }

    /**
     * 邮箱格式校验。
     */
    private static func checkEmail(
        d: FieldDef, raw: String, errors: ArrayList<String>
    ): Unit {
        if (!FieldValidator.isEmail(raw)) {
            errors.add("字段「${d.fieldName}」不是合法邮箱")
        }
    }

    /**
     * 手机号格式校验。
     */
    private static func checkPhone(
        d: FieldDef, raw: String, errors: ArrayList<String>
    ): Unit {
        if (!FieldValidator.isPhone(raw)) {
            errors.add("字段「${d.fieldName}」不是合法手机号")
        }
    }

    /**
     * 身份证格式校验。
     */
    private static func checkIdCard(
        d: FieldDef, raw: String, errors: ArrayList<String>
    ): Unit {
        if (!FieldValidator.isIdCard(raw)) {
            errors.add("字段「${d.fieldName}」不是合法身份证号")
        }
    }

    /**
     * URL 格式校验。
     */
    private static func checkUrl(
        d: FieldDef, raw: String, errors: ArrayList<String>
    ): Unit {
        if (!FieldValidator.isUrl(raw)) {
            errors.add("字段「${d.fieldName}」不是合法 URL")
        }
    }

    /**
     * 邮箱校验：local@domain，domain 需含点。
     */
    public static func isEmail(s: String): Bool {
        let at = FieldValidator.indexOf(s, "@")
        if (at <= 0) {
            return false
        }
        let domain = s[(at + 1)..s.size]
        let dot = FieldValidator.indexOf(domain, ".")
        if (dot <= 0 || dot >= domain.size - 1) {
            return false
        }
        return !s.contains(" ")
    }

    /**
     * 手机号校验：11 位，以 1 开头。
     */
    public static func isPhone(s: String): Bool {
        if (s.size != 11) {
            return false
        }
        if (s[0] != 49u8) {   // '1'
            return false
        }
        for (i in 0..s.size) {
            let c = s[i]
            if (c < 48u8 || c > 57u8) {
                return false
            }
        }
        return true
    }

    /**
     * 身份证号校验：18 位（末位可为 X），前 17 位为数字。
     */
    public static func isIdCard(s: String): Bool {
        if (s.size != 18) {
            return false
        }
        for (i in 0..17) {
            let c = s[i]
            if (c < 48u8 || c > 57u8) {
                return false
            }
        }
        let last = s[17]
        return last == 88u8 || last == 120u8 || (last >= 48u8 && last <= 57u8)
    }

    /**
     * URL 校验：需含 scheme:// 与域名。
     */
    public static func isUrl(s: String): Bool {
        let schemePos = FieldValidator.indexOf(s, "://")
        if (schemePos < 0) {
            return false
        }
        let afterScheme = s[(schemePos + 3)..s.size]
        return afterScheme.contains(".") && !afterScheme.contains(" ")
    }

    /**
     * 查找子串首字节下标（-1 表示未找到）。
     */
    private static func indexOf(s: String, sub: String): Int64 {
        if (sub.isEmpty() || s.size < sub.size) {
            return -1
        }
        for (i in 0..(s.size - sub.size + 1)) {
            var matched = true
            for (j in 0..sub.size) {
                if (s[i + j] != sub[j]) {
                    matched = false
                    break
                }
            }
            if (matched) {
                return i
            }
        }
        return -1
    }
}

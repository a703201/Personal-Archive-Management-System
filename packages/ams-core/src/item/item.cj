// ============================================================
// ams.core.item · 档案条目领域模型
//
// 需求：
//   FR-ARCH-001 条目 CRUD（按分类渲染动态表单；必填与格式校验前后端双重执行，后端为准）
//   FR-ARCH-002 统一元数据模型（所有条目共享元字段）
//   FR-ARCH-003 字段定义表（类型：text/number/date/enum/multi_enum/bool/
//                          email/phone/idcard/url/json）
//   FR-ARCH-004 扩展字段存储（JSONB + 关键字段提升为真实列）
//   FR-ARCH-006 条目状态流转（draft → active → archived → deleted）
//   FR-ARCH-007 乐观锁与冲突提示（version 递增；冲突返回 409，不静默覆盖）
//   FR-ARCH-008 软删除与回收站（保留 30 天；恢复需有权限）
//
// [状态机]（PRD §6.2.2）
//   draft ──保存并归档──► active ──归档──► archived
//     ▲                     │  ▲              │
//     └──编辑────────────────┘  └──恢复编辑────┘
//   active/draft ──删除──► deleted ──30天到期──► [物理清理]
//
// [领域层约束]（架构 §4.2）：ams-core 不依赖 HTTP / DB / 存储，
//   纯领域模型与不变量。
// ============================================================
package ams.core.item


/**
 * 条目状态。
 */
public enum ItemStatus {
    | Draft    // 0 草稿
    | Active   // 1 正常
    | Archived // 2 归档（只读）
    | Deleted  // 3 已删除（回收站）

    public func toCode(): Int64 {
        match (this) {
            case ItemStatus.Draft => return 0
            case ItemStatus.Active => return 1
            case ItemStatus.Archived => return 2
            case ItemStatus.Deleted => return 3
        }
    }

    public static func fromCode(code: Int64): ItemStatus {
        if (code == 0) {
            return ItemStatus.Draft
        } else if (code == 2) {
            return ItemStatus.Archived
        } else if (code == 3) {
            return ItemStatus.Deleted
        }
        return ItemStatus.Active
    }
}

/**
 * 分类敏感度分级（与 ams.security.authz.Sensitivity 对齐，
 * 但领域层不依赖 security 包，故此处独立定义，由 app 层做转换）。
 */
public enum ItemSensitivity {
    | Normal    // 1 普通
    | Sensitive // 2 敏感
    | High      // 3 高敏

    public func toCode(): Int64 {
        match (this) {
            case ItemSensitivity.Normal => return 1
            case ItemSensitivity.Sensitive => return 2
            case ItemSensitivity.High => return 3
        }
    }
}

/**
 * 字段数据类型（FR-ARCH-003）。
 */
public enum FieldType {
    | Text      // 1
    | Number    // 2
    | Date      // 3
    | Enum      // 4
    | MultiEnum // 5
    | `Bool`    // 6
    | Email     // 7
    | Phone     // 8
    | IdCard    // 9
    | Url       // 10
    | Json      // 11

    public func toCode(): Int64 {
        match (this) {
            case FieldType.Text => return 1
            case FieldType.Number => return 2
            case FieldType.Date => return 3
            case FieldType.Enum => return 4
            case FieldType.MultiEnum => return 5
            case FieldType.`Bool` => return 6
            case FieldType.Email => return 7
            case FieldType.Phone => return 8
            case FieldType.IdCard => return 9
            case FieldType.Url => return 10
            case FieldType.Json => return 11
        }
    }

    public static func fromCode(code: Int64): FieldType {
        if (code == 2) { return FieldType.Number }
        if (code == 3) { return FieldType.Date }
        if (code == 4) { return FieldType.Enum }
        if (code == 5) { return FieldType.MultiEnum }
        if (code == 6) { return FieldType.`Bool` }
        if (code == 7) { return FieldType.Email }
        if (code == 8) { return FieldType.Phone }
        if (code == 9) { return FieldType.IdCard }
        if (code == 10) { return FieldType.Url }
        if (code == 11) { return FieldType.Json }
        return FieldType.Text
    }

    /**
     * 是否为敏感类型（需加密存储 + 盲索引）。
     */
    public func isSensitiveByType(): Bool {
        match (this) {
            case FieldType.IdCard => return true
            case _ => return false
        }
    }
}

/**
 * 字段定义（FR-ARCH-003）。
 */
public class FieldDef {
    /** 字段键（英文，程序使用） */
    public let fieldKey: String
    /** 字段名（中文，展示用） */
    public let fieldName: String
    /** 数据类型 */
    public let dataType: FieldType
    /** 敏感度 */
    public let sensitivity: ItemSensitivity
    /** 是否必填 */
    public let isRequired: Bool
    /** 是否进入全文索引 */
    public let isSearchable: Bool
    /** 是否可筛选 */
    public let isFilterable: Bool
    /** 是否支持盲索引等值检索 */
    public let isBidxCapable: Bool
    /** 展示顺序 */
    public let displayOrder: Int64
    /** 校验规则（JSON 文本） */
    public let validationRule: String
    /** 枚举字典类型码（dataType 为 enum 时有效） */
    public let enumDictCode: String
    /** 是否系统内置（不可删除） */
    public let isSystem: Bool

    public init(
        fieldKey: String,
        fieldName: String,
        dataType: FieldType,
        sensitivity: ItemSensitivity,
        isRequired: Bool,
        isSearchable: Bool,
        isFilterable: Bool,
        isBidxCapable: Bool,
        displayOrder: Int64,
        validationRule: String,
        enumDictCode: String,
        isSystem: Bool
    ) {
        this.fieldKey = fieldKey
        this.fieldName = fieldName
        this.dataType = dataType
        this.sensitivity = sensitivity
        this.isRequired = isRequired
        this.isSearchable = isSearchable
        this.isFilterable = isFilterable
        this.isBidxCapable = isBidxCapable
        this.displayOrder = displayOrder
        this.validationRule = validationRule
        this.enumDictCode = enumDictCode
        this.isSystem = isSystem
    }
}

/**
 * 字段取值。
 *
 * 敏感字段的明文**不得**长期驻留 —— 敏感值应落到 valueEnc，
 * 此处仅承载非敏感值与「待加密」的瞬时明文。
 */
public class FieldValue {
    /** 字段键 */
    public let fieldKey: String
    /** 文本值（非敏感字段） */
    public let text: String
    /** 数值（非敏感字段） */
    public let number: Float64
    /** 布尔值 */
    public let boolValue: Bool
    /** 敏感字段的待加密明文（落库前立即加密） */
    public let sensitivePlain: String

    public init(
        fieldKey: String,
        text: String,
        number: Float64,
        boolValue: Bool,
        sensitivePlain: String
    ) {
        this.fieldKey = fieldKey
        this.text = text
        this.number = number
        this.boolValue = boolValue
        this.sensitivePlain = sensitivePlain
    }

    /**
     * 文本值构造。
     */
    public static func ofText(fieldKey: String, text: String): FieldValue {
        return FieldValue(fieldKey, text, 0.0, false, "")
    }

    /**
     * 数值构造。
     */
    public static func ofNumber(fieldKey: String, number: Float64): FieldValue {
        return FieldValue(fieldKey, "", number, false, "")
    }

    /**
     * 布尔构造。
     */
    public static func ofBool(fieldKey: String, value: Bool): FieldValue {
        return FieldValue(fieldKey, "", 0.0, value, "")
    }

    /**
     * 敏感值构造（落库前需加密）。
     */
    public static func ofSensitive(fieldKey: String, plain: String): FieldValue {
        return FieldValue(fieldKey, "", 0.0, false, plain)
    }
}

/**
 * 档案条目（统一元数据模型，FR-ARCH-002）。
 */
public class ArchiveItem {
    /** 条目 ID（雪花 ID） */
    public let id: String
    /** 所属主体 ID */
    public let subjectId: String
    /** 分类码 */
    public let category: Int64
    /** 标题 */
    public var title: String
    /** 状态 */
    public var status: ItemStatus
    /** 敏感度（继承分类默认，可上调不可下调） */
    public var sensitivity: ItemSensitivity
    /** 颁发/生效日期 */
    public var issuedDate: String
    /** 失效日期 */
    public var expiresAt: String
    /** 颁发机构 */
    public var issuer: String
    /** 扩展字段（非敏感部分） */
    public var extra: Array<(String, String)>
    /** 备注 */
    public var remark: String
    /** 乐观锁版本号 */
    public var version: Int64
    /** 创建时间 */
    public let createdAt: Int64
    /** 更新时间 */
    public var updatedAt: Int64
    /** 删除时间（0 = 未删除） */
    public var deletedAt: Int64

    public init(
        id: String,
        subjectId: String,
        category: Int64,
        title: String,
        status: ItemStatus,
        sensitivity: ItemSensitivity,
        issuedDate: String,
        expiresAt: String,
        issuer: String,
        extra: Array<(String, String)>,
        remark: String,
        version: Int64,
        createdAt: Int64,
        updatedAt: Int64,
        deletedAt: Int64
    ) {
        this.id = id
        this.subjectId = subjectId
        this.category = category
        this.title = title
        this.status = status
        this.sensitivity = sensitivity
        this.issuedDate = issuedDate
        this.expiresAt = expiresAt
        this.issuer = issuer
        this.extra = extra
        this.remark = remark
        this.version = version
        this.createdAt = createdAt
        this.updatedAt = updatedAt
        this.deletedAt = deletedAt
    }
}

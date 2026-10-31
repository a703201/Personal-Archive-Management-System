// ============================================================
// ams.core.item · 分类目录与字段模板
//
// 需求：FR-ARCH-005 分类模板预置
//   系统预置 12 分类的字段模板与中文标签，用户可增删字段。
//
// [分类枚举]（数据模型 §11.2，硬编码）
//   1 basic 个人基本信息 / 2 identity 证件信息 / 3 education 教育经历
//   4 experience 职业经历 / 5 certificate 资质证书 / 6 contact 联系方式
//   7 family 家庭关系 / 8 health 健康信息 / 9 asset 资产信息
//   10 impression 影像附件 / 11 custom 自定义分类
//
// ⚠️ 中文名以 `docs/06-数据模型设计.md` §12.3 为唯一口径。
//    此处曾用「基本信息 / 身份证明 / 工作经历 / 资格证书」，
//    与文档和前端字典（`web/src/composables/useCatalog.ts`）不一致，
//    导致同一分类在不同页面显示不同名字 —— 已统一。
//
// [敏感度]（PRD §5.5）
//   basic/education/experience/certificate/impression → normal
//   identity/contact/family → sensitive
//   health/asset → high（默认仅所有者可见）
//
// [字段模板]
//   模板存于 arc_field_defs 中 subject_id IS NULL 的记录。
//   本包提供代码内的模板定义（作为初始化数据源），
//   落库时由 app 层写入。
// ============================================================
package ams.core.item


/**
 * 档案分类。
 */
public enum ArchiveCategory {
    | Basic       // 1 个人基本信息
    | Identity    // 2 证件信息
    | Education   // 3 教育经历
    | Experience  // 4 职业经历
    | Certificate // 5 资质证书
    | Contact     // 6 联系方式
    | Family      // 7 家庭关系
    | Health      // 8 健康信息
    | Asset       // 9 资产信息
    | Impression  // 10 影像附件
    | Custom      // 11 自定义分类

    public func toCode(): Int64 {
        match (this) {
            case ArchiveCategory.Basic => return 1
            case ArchiveCategory.Identity => return 2
            case ArchiveCategory.Education => return 3
            case ArchiveCategory.Experience => return 4
            case ArchiveCategory.Certificate => return 5
            case ArchiveCategory.Contact => return 6
            case ArchiveCategory.Family => return 7
            case ArchiveCategory.Health => return 8
            case ArchiveCategory.Asset => return 9
            case ArchiveCategory.Impression => return 10
            case ArchiveCategory.Custom => return 11
        }
    }

    public static func fromCode(code: Int64): ArchiveCategory {
        if (code == 2) { return ArchiveCategory.Identity }
        if (code == 3) { return ArchiveCategory.Education }
        if (code == 4) { return ArchiveCategory.Experience }
        if (code == 5) { return ArchiveCategory.Certificate }
        if (code == 6) { return ArchiveCategory.Contact }
        if (code == 7) { return ArchiveCategory.Family }
        if (code == 8) { return ArchiveCategory.Health }
        if (code == 9) { return ArchiveCategory.Asset }
        if (code == 10) { return ArchiveCategory.Impression }
        if (code == 11) { return ArchiveCategory.Custom }
        return ArchiveCategory.Basic
    }

    /**
     * 分类代码（英文）。
     */
    public func code(): String {
        match (this) {
            case ArchiveCategory.Basic => return "basic"
            case ArchiveCategory.Identity => return "identity"
            case ArchiveCategory.Education => return "education"
            case ArchiveCategory.Experience => return "experience"
            case ArchiveCategory.Certificate => return "certificate"
            case ArchiveCategory.Contact => return "contact"
            case ArchiveCategory.Family => return "family"
            case ArchiveCategory.Health => return "health"
            case ArchiveCategory.Asset => return "asset"
            case ArchiveCategory.Impression => return "impression"
            case ArchiveCategory.Custom => return "custom"
        }
    }

    /**
     * 分类中文名。
     *
     * 口径：`docs/06-数据模型设计.md` §12.3，与前端 `useCatalog.ts` 保持一致。
     */
    public func displayName(): String {
        match (this) {
            case ArchiveCategory.Basic => return "个人基本信息"
            case ArchiveCategory.Identity => return "证件信息"
            case ArchiveCategory.Education => return "教育经历"
            case ArchiveCategory.Experience => return "职业经历"
            case ArchiveCategory.Certificate => return "资质证书"
            case ArchiveCategory.Contact => return "联系方式"
            case ArchiveCategory.Family => return "家庭关系"
            case ArchiveCategory.Health => return "健康信息"
            case ArchiveCategory.Asset => return "资产信息"
            case ArchiveCategory.Impression => return "影像附件"
            case ArchiveCategory.Custom => return "自定义分类"
        }
    }

    /**
     * 分类默认敏感度。
     */
    public func defaultSensitivity(): ItemSensitivity {
        match (this) {
            case ArchiveCategory.Identity => return ItemSensitivity.Sensitive
            case ArchiveCategory.Contact => return ItemSensitivity.Sensitive
            case ArchiveCategory.Family => return ItemSensitivity.Sensitive
            case ArchiveCategory.Health => return ItemSensitivity.High
            case ArchiveCategory.Asset => return ItemSensitivity.High
            case _ => return ItemSensitivity.Normal
        }
    }
}

/**
 * 分类目录：内置分类的字段模板。
 */
public class CategoryCatalog {
    /**
     * 全部内置分类。
     */
    public static func all(): Array<ArchiveCategory> {
        return [
            ArchiveCategory.Basic, ArchiveCategory.Identity, ArchiveCategory.Education,
            ArchiveCategory.Experience, ArchiveCategory.Certificate, ArchiveCategory.Contact,
            ArchiveCategory.Family, ArchiveCategory.Health, ArchiveCategory.Asset,
            ArchiveCategory.Impression, ArchiveCategory.Custom
        ]
    }

    /**
     * 某分类的字段模板。
     *
     * @param category 分类
     * @return 字段定义列表（已按 displayOrder 排序）
     */
    public static func template(category: ArchiveCategory): Array<FieldDef> {
        match (category) {
            case ArchiveCategory.Basic => return CategoryCatalog.basicTemplate()
            case ArchiveCategory.Identity => return CategoryCatalog.identityTemplate()
            case ArchiveCategory.Education => return CategoryCatalog.educationTemplate()
            case ArchiveCategory.Experience => return CategoryCatalog.experienceTemplate()
            case ArchiveCategory.Certificate => return CategoryCatalog.certificateTemplate()
            case ArchiveCategory.Contact => return CategoryCatalog.contactTemplate()
            case ArchiveCategory.Family => return CategoryCatalog.familyTemplate()
            case ArchiveCategory.Health => return CategoryCatalog.healthTemplate()
            case ArchiveCategory.Asset => return CategoryCatalog.assetTemplate()
            case ArchiveCategory.Impression => return CategoryCatalog.impressionTemplate()
            case ArchiveCategory.Custom => return CategoryCatalog.customTemplate()
        }
    }

    /**
     * 基本信息模板。
     */
    private static func basicTemplate(): Array<FieldDef> {
        return [
            CategoryCatalog.field("nickname", "昵称", FieldType.Text, ItemSensitivity.Normal, false, true, false, false, 1),
            CategoryCatalog.field("birth_date", "出生日期", FieldType.Date, ItemSensitivity.Normal, false, true, true, false, 2),
            CategoryCatalog.field("gender", "性别", FieldType.Enum, ItemSensitivity.Normal, false, true, true, false, 3),
            CategoryCatalog.field("blood_type", "血型", FieldType.Enum, ItemSensitivity.Normal, false, true, true, false, 4),
            CategoryCatalog.field("marital_status", "婚姻状况", FieldType.Enum, ItemSensitivity.Normal, false, true, true, false, 5),
            CategoryCatalog.field("height", "身高(cm)", FieldType.Number, ItemSensitivity.Normal, false, false, true, false, 6),
            CategoryCatalog.field("weight", "体重(kg)", FieldType.Number, ItemSensitivity.Normal, false, false, true, false, 7),
            CategoryCatalog.field("remark", "备注", FieldType.Text, ItemSensitivity.Normal, false, false, false, false, 8)
        ]
    }

    /**
     * 身份证明模板。
     */
    private static func identityTemplate(): Array<FieldDef> {
        return [
            CategoryCatalog.field("id_type", "证件类型", FieldType.Enum, ItemSensitivity.Normal, true, true, true, false, 1),
            CategoryCatalog.field("id_number", "证件号码", FieldType.IdCard, ItemSensitivity.Sensitive, true, false, true, true, 2),
            CategoryCatalog.field("issued_by", "签发机关", FieldType.Text, ItemSensitivity.Normal, false, true, true, false, 3),
            CategoryCatalog.field("issued_date", "签发日期", FieldType.Date, ItemSensitivity.Normal, false, true, true, false, 4),
            CategoryCatalog.field("valid_until", "有效期限", FieldType.Date, ItemSensitivity.Normal, false, true, true, false, 5),
            CategoryCatalog.field("passport_no", "护照号码", FieldType.Text, ItemSensitivity.Sensitive, false, false, true, true, 6)
        ]
    }

    /**
     * 教育经历模板。
     */
    private static func educationTemplate(): Array<FieldDef> {
        return [
            CategoryCatalog.field("school", "学校名称", FieldType.Text, ItemSensitivity.Normal, true, true, true, false, 1),
            CategoryCatalog.field("major", "专业", FieldType.Text, ItemSensitivity.Normal, false, true, true, false, 2),
            CategoryCatalog.field("degree", "学历", FieldType.Enum, ItemSensitivity.Normal, true, true, true, false, 3),
            CategoryCatalog.field("start_date", "入学日期", FieldType.Date, ItemSensitivity.Normal, false, true, true, false, 4),
            CategoryCatalog.field("end_date", "毕业日期", FieldType.Date, ItemSensitivity.Normal, false, true, true, false, 5),
            CategoryCatalog.field("diploma_no", "毕业证编号", FieldType.Text, ItemSensitivity.Normal, false, true, true, true, 6),
            CategoryCatalog.field("degree_no", "学位证编号", FieldType.Text, ItemSensitivity.Normal, false, true, true, true, 7)
        ]
    }

    /**
     * 工作经历模板。
     */
    private static func experienceTemplate(): Array<FieldDef> {
        return [
            CategoryCatalog.field("company", "单位名称", FieldType.Text, ItemSensitivity.Normal, true, true, true, false, 1),
            CategoryCatalog.field("position", "职务", FieldType.Text, ItemSensitivity.Normal, true, true, true, false, 2),
            CategoryCatalog.field("department", "部门", FieldType.Text, ItemSensitivity.Normal, false, true, true, false, 3),
            CategoryCatalog.field("start_date", "入职日期", FieldType.Date, ItemSensitivity.Normal, false, true, true, false, 4),
            CategoryCatalog.field("end_date", "离职日期", FieldType.Date, ItemSensitivity.Normal, false, true, true, false, 5),
            CategoryCatalog.field("social_insurance_no", "社保号", FieldType.Text, ItemSensitivity.Sensitive, false, false, true, true, 6)
        ]
    }

    /**
     * 资格证书模板。
     */
    private static func certificateTemplate(): Array<FieldDef> {
        return [
            CategoryCatalog.field("cert_name", "证书名称", FieldType.Text, ItemSensitivity.Normal, true, true, true, false, 1),
            CategoryCatalog.field("cert_no", "证书编号", FieldType.Text, ItemSensitivity.Normal, false, true, true, true, 2),
            CategoryCatalog.field("issuer", "颁发机构", FieldType.Text, ItemSensitivity.Normal, true, true, true, false, 3),
            CategoryCatalog.field("issue_date", "发证日期", FieldType.Date, ItemSensitivity.Normal, false, true, true, false, 4),
            CategoryCatalog.field("expire_date", "到期日期", FieldType.Date, ItemSensitivity.Normal, false, true, true, false, 5),
            CategoryCatalog.field("cert_level", "证书等级", FieldType.Enum, ItemSensitivity.Normal, false, true, true, false, 6)
        ]
    }

    /**
     * 联系方式模板。
     */
    private static func contactTemplate(): Array<FieldDef> {
        return [
            CategoryCatalog.field("phone", "手机号", FieldType.Phone, ItemSensitivity.Sensitive, true, false, true, true, 1),
            CategoryCatalog.field("email", "邮箱", FieldType.Email, ItemSensitivity.Sensitive, false, false, true, true, 2),
            CategoryCatalog.field("backup_email", "备用邮箱", FieldType.Email, ItemSensitivity.Sensitive, false, false, true, true, 3),
            CategoryCatalog.field("im_account", "即时通讯账号", FieldType.Text, ItemSensitivity.Normal, false, true, true, false, 4),
            CategoryCatalog.field("address", "通讯地址", FieldType.Text, ItemSensitivity.Sensitive, false, true, true, false, 5),
            CategoryCatalog.field("emergency_contact", "紧急联系人", FieldType.Text, ItemSensitivity.Normal, false, true, true, false, 6),
            CategoryCatalog.field("emergency_phone", "紧急联系电话", FieldType.Phone, ItemSensitivity.Sensitive, false, false, true, true, 7)
        ]
    }

    /**
     * 家庭关系模板。
     */
    private static func familyTemplate(): Array<FieldDef> {
        return [
            CategoryCatalog.field("member_name", "家庭成员姓名", FieldType.Text, ItemSensitivity.Sensitive, true, true, true, true, 1),
            CategoryCatalog.field("relation", "关系", FieldType.Enum, ItemSensitivity.Normal, true, true, true, false, 2),
            CategoryCatalog.field("relation_to_self", "与本人关系", FieldType.Enum, ItemSensitivity.Normal, false, true, true, false, 3),
            CategoryCatalog.field("birth_date", "出生日期", FieldType.Date, ItemSensitivity.Normal, false, true, true, false, 4),
            CategoryCatalog.field("id_number", "证件号", FieldType.IdCard, ItemSensitivity.Sensitive, false, false, true, true, 5),
            CategoryCatalog.field("occupation", "职业", FieldType.Text, ItemSensitivity.Normal, false, true, true, false, 6),
            CategoryCatalog.field("is_cohabiting", "是否同住", FieldType.`Bool`, ItemSensitivity.Normal, false, false, true, false, 7)
        ]
    }

    /**
     * 健康信息模板。
     */
    private static func healthTemplate(): Array<FieldDef> {
        return [
            CategoryCatalog.field("allergy", "过敏史", FieldType.Text, ItemSensitivity.High, false, false, true, false, 1),
            CategoryCatalog.field("medical_history", "既往病史", FieldType.Text, ItemSensitivity.High, false, false, true, false, 2),
            CategoryCatalog.field("surgery_history", "手术史", FieldType.Text, ItemSensitivity.High, false, false, true, false, 3),
            CategoryCatalog.field("medication", "用药记录", FieldType.Text, ItemSensitivity.High, false, false, true, false, 4),
            CategoryCatalog.field("physical_exam", "体检报告", FieldType.Text, ItemSensitivity.High, false, false, true, false, 5),
            CategoryCatalog.field("vaccination", "疫苗接种", FieldType.Text, ItemSensitivity.High, false, false, true, false, 6),
            CategoryCatalog.field("disability_level", "残疾等级", FieldType.Enum, ItemSensitivity.High, false, false, true, false, 7),
            CategoryCatalog.field("insurance_info", "医保信息", FieldType.Text, ItemSensitivity.High, false, false, true, false, 8)
        ]
    }

    /**
     * 资产信息模板。
     */
    private static func assetTemplate(): Array<FieldDef> {
        return [
            CategoryCatalog.field("asset_type", "资产类型", FieldType.Enum, ItemSensitivity.High, true, true, true, false, 1),
            CategoryCatalog.field("asset_desc", "标的描述", FieldType.Text, ItemSensitivity.High, false, true, true, false, 2),
            CategoryCatalog.field("valuation", "估值", FieldType.Number, ItemSensitivity.High, false, false, true, false, 3),
            CategoryCatalog.field("currency", "币种", FieldType.Enum, ItemSensitivity.Normal, false, true, true, false, 4),
            CategoryCatalog.field("ownership_ratio", "权属比例", FieldType.Number, ItemSensitivity.High, false, false, true, false, 5),
            CategoryCatalog.field("acquire_date", "获取日期", FieldType.Date, ItemSensitivity.Normal, false, true, true, false, 6),
            CategoryCatalog.field("debt_info", "负债信息", FieldType.Text, ItemSensitivity.High, false, false, true, false, 7)
        ]
    }

    /**
     * 影像附件模板（附件为主，字段为辅）。
     */
    private static func impressionTemplate(): Array<FieldDef> {
        return [
            CategoryCatalog.field("capture_date", "拍摄日期", FieldType.Date, ItemSensitivity.Normal, false, true, true, false, 1),
            CategoryCatalog.field("capture_device", "拍摄设备", FieldType.Text, ItemSensitivity.Normal, false, false, false, false, 2),
            CategoryCatalog.field("doc_type", "单据类型", FieldType.Enum, ItemSensitivity.Normal, false, true, true, false, 3)
        ]
    }

    /**
     * 自定义分类模板（继承通用元数据）。
     */
    private static func customTemplate(): Array<FieldDef> {
        return [
            CategoryCatalog.field("summary", "摘要", FieldType.Text, ItemSensitivity.Normal, false, true, true, false, 1),
            CategoryCatalog.field("tags_hint", "备注", FieldType.Text, ItemSensitivity.Normal, false, false, false, false, 2)
        ]
    }

    /**
     * 构造字段定义（模板用，校验规则与字典码留空）。
     */
    private static func field(
        key: String,
        name: String,
        ftype: FieldType,
        sens: ItemSensitivity,
        required: Bool,
        searchable: Bool,
        filterable: Bool,
        bidxCapable: Bool,
        order: Int64
    ): FieldDef {
        return FieldDef(key, name, ftype, sens, required, searchable, filterable,
            bidxCapable, order, "", "", true)
    }
}

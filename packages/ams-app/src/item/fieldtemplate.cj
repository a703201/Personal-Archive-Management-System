// ============================================================
// ams.app.item.fieldtemplate · 分类字段模板播种服务
//
// 职责（FR-ARCH-005 分类模板预置）：
//   ams-core 的 CategoryCatalog 里有 11 套内置分类的字段模板，
//   但**模板一直只存在于代码中**（"有模型差接线"）。
//   本服务把它们写入 arc_field_defs（subject_id IS NULL = 内置模板），
//   从而让档案动态表单、元数据校验、字段级检索都有「落库的模板」可依。
//
// [幂等设计]
//   唯一索引 uk_arc_field_defs(COALESCE(subject_id,0), category, field_key)
//   保证同一分类下字段键不重复。
//   播种前先比对「已存在条数」，达到预期则整体跳过，
//   未达标再逐条 findBuiltinByKey 判重后插入 —— 支持反复执行与部分补齐。
//
// [分层]
//   ams-app 依赖 ams-core（构建拓扑中 ams-core 先于 ams-app），
//   由应用层编排「领域模板 → 数据库」的写入，符合架构 §4.2。
// ============================================================
package ams.app.item

import ams.core.item.*
import ams.data.repo.*
import ams.kernel.log.*

/**
 * 字段模板播种服务。
 */
public class FieldTemplateService {
    private let fieldDefRepo: FieldDefRepo

    public init(fieldDefRepo: FieldDefRepo) {
        this.fieldDefRepo = fieldDefRepo
    }

    /**
     * 确保 11 套内置分类字段模板已落库（幂等，可反复调用）。
     *
     * @return 本次**新写入**的字段定义条数
     */
    public func ensureBuiltinTemplates(): Int64 {
        let expected = FieldTemplateService.expectedCount()
        let existing = this.fieldDefRepo.countBuiltin()

        if (existing >= expected) {
            Log.get().info("field.template.skip", None, [
                ("existing", "${existing}"), ("expected", "${expected}")
            ])
            return 0
        }

        var created: Int64 = 0
        for (cat in CategoryCatalog.all()) {
            let code = cat.toCode()
            for (fd in CategoryCatalog.template(cat)) {
                // match 分支保持单表达式，故先归约为 Bool 再分支
                var exists = false
                match (this.fieldDefRepo.findBuiltinByKey(code, fd.fieldKey)) {
                    case Some(_) => exists = true
                    case None => exists = false
                }
                if (!exists) {
                    this.fieldDefRepo.create(
                        0,                       // subjectId = 0 → 内置模板（DB 写 NULL）
                        code,
                        fd.fieldKey,
                        fd.fieldName,
                        fd.dataType.toCode(),
                        fd.sensitivity.toCode(),
                        fd.isRequired,
                        fd.isSearchable,
                        fd.isFilterable,
                        fd.isBidxCapable,
                        fd.enumDictCode,
                        fd.displayOrder,
                        fd.validationRule,
                        "",                      // defaultValue
                        fd.isSystem,
                        0                        // operatorId = 0 → 系统播种
                    )
                    created = created + 1
                }
            }
        }

        Log.get().info("field.template.seed", None, [
            ("created", "${created}"), ("expected", "${expected}")
        ])
        return created
    }

    /**
     * 内置模板的字段总条数（由 CategoryCatalog 现算，避免硬编码漂移）。
     */
    private static func expectedCount(): Int64 {
        var n: Int64 = 0
        for (cat in CategoryCatalog.all()) {
            n = n + CategoryCatalog.template(cat).size
        }
        return n
    }
}

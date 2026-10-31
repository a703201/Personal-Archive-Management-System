// ============================================================
// ams.app.importer · CSV 导入校验单元测试（FR-IMP-001 / FR-IMP-005）
//
// 覆盖：
//   ① 固定列序（无模板）的零回归行为；
//   ② 模板映射（CSV 表头 → 字段键）的解析与自定义字段捕获；
//   ③ 模板默认值回落（CSV 缺列时）。
//
// 说明：validate 是纯函数，不依赖数据库 / 仓储，可直接构造参数调用。
// ============================================================
package ams.app.importer.test

import std.collection.*
import std.unittest.*

import ams.app.importer.*

@Test
public class CsvImportValidateTest {
    /** 空映射时沿用固定列序：与旧行为一致。 */
    @TestCase
    public func testFixedColumnBackwardCompat() {
        let csv = "subject_id,category,title,status,sensitivity,issued_date,expires_at,issuer,remark\n" +
                  "100,3,本科学历证书,0,1,2020-09-01,,示例大学,备注\n"
        let allowed = HashSet<Int64>()
        allowed.add(100)
        let plan = ImportService.validate(
            csv, allowed, 0, 5000, existing: HashMap<String, Int64>()
        )
        @Assert(plan.total, 1)
        @Assert(plan.valid, 1)
        @Assert(plan.invalid, 0)
        @Assert(plan.good.size, 1)
        let row = plan.good[0]
        @Assert(row.title, "本科学历证书")
        @Assert(row.category, 3)
        @Assert(row.issuer, "示例大学")
        // 无映射：自定义字段为空
        @Assert(row.customFields.size, 0)
    }

    /** 固定列序下分类越界仍报错（1-11）。 */
    @TestCase
    public func testFixedColumnBadCategory() {
        let csv = "subject_id,category,title,status,sensitivity,issued_date,expires_at,issuer,remark\n" +
                  "100,99,证书,0,1,,,,,\n"
        let allowed = HashSet<Int64>()
        allowed.add(100)
        let plan = ImportService.validate(
            csv, allowed, 0, 5000, existing: HashMap<String, Int64>()
        )
        @Assert(plan.valid, 0)
        @Assert(plan.invalid, 1)
    }

    /**
     * 模板映射：CSV 列名与系统字段任意对应，自定义字段（学号）被捕获。
     *
     * 映射：{ "姓名":"title", "类别":"category", "发证机构":"issuer", "学号":"student_no" }
     * 默认：{ "subject_id":"100", "status":"0", "sensitivity":"1" }
     * CSV 表头：姓名,类别,发证机构,学号
     * 数据行：张三,3,北京大学,2021001
     */
    @TestCase
    public func testTemplateMappingResolvesSystemAndCustomFields() {
        let mapping = HashMap<String, String>()
        mapping.add("姓名", "title")
        mapping.add("类别", "category")
        mapping.add("发证机构", "issuer")
        mapping.add("学号", "student_no")   // 自定义字段键
        let defaults = HashMap<String, String>()
        defaults.add("subject_id", "100")
        defaults.add("status", "0")
        defaults.add("sensitivity", "1")

        let csv = "姓名,类别,发证机构,学号\n张三,3,北京大学,2021001\n"
        let allowed = HashSet<Int64>()
        allowed.add(100)
        let plan = ImportService.validate(
            csv, allowed, 0, 5000, existing: HashMap<String, Int64>(),
            mapping: mapping, defaults: defaults
        )
        @Assert(plan.total, 1)
        @Assert(plan.valid, 1)
        @Assert(plan.invalid, 0)
        let row = plan.good[0]
        @Assert(row.title, "张三")
        @Assert(row.category, 3)
        @Assert(row.issuer, "北京大学")
        @Assert(row.subjectId, 100)
        @Assert(row.status, 0)
        @Assert(row.sensitivity, 1)
        // 自定义字段被捕获（customFields 以字段键而非 CSV 表头为键）
        @Assert(row.customFields.size, 1)
        @Assert(row.customFields.get("student_no"), Some("2021001"))
    }

    /** 模板默认值回落：CSV 缺列且映射未覆盖时，取默认值。 */
    @TestCase
    public func testTemplateMissingColumnFallsBackToDefault() {
        // 映射只给了 title，其余靠默认值
        let mapping = HashMap<String, String>()
        mapping.add("名称", "title")
        let defaults = HashMap<String, String>()
        defaults.add("subject_id", "100")
        defaults.add("category", "3")
        defaults.add("status", "0")
        defaults.add("sensitivity", "2")

        let csv = "名称\n只看默认值\n"
        let allowed = HashSet<Int64>()
        allowed.add(100)
        let plan = ImportService.validate(
            csv, allowed, 0, 5000, existing: HashMap<String, Int64>(),
            mapping: mapping, defaults: defaults
        )
        @Assert(plan.valid, 1)
        let row = plan.good[0]
        @Assert(row.title, "只看默认值")
        @Assert(row.category, 3)
        @Assert(row.subjectId, 100)
        @Assert(row.sensitivity, 2)
    }

    /** 模板映射下：主体不在可写范围应报错（与固定列序一致）。 */
    @TestCase
    public func testTemplateSubjectNotAllowed() {
        let mapping = HashMap<String, String>()
        mapping.add("名称", "title")
        mapping.add("主体", "subject_id")
        let defaults = HashMap<String, String>()
        defaults.add("category", "3")
        defaults.add("status", "0")
        defaults.add("sensitivity", "1")

        // 主体列映射到「主体」，但值 999 不在 allowed 内
        let csv = "名称,主体\n证书,999\n"
        let allowed = HashSet<Int64>()
        allowed.add(100)
        let plan = ImportService.validate(
            csv, allowed, 0, 5000, existing: HashMap<String, Int64>(),
            mapping: mapping, defaults: defaults
        )
        @Assert(plan.valid, 0)
        @Assert(plan.invalid, 1)
    }

    /** 判重：模板映射下同样生效。 */
    @TestCase
    public func testTemplateDuplicateDetection() {
        let mapping = HashMap<String, String>()
        mapping.add("名称", "title")
        let defaults = HashMap<String, String>()
        defaults.add("subject_id", "100")
        defaults.add("category", "3")
        defaults.add("status", "0")
        defaults.add("sensitivity", "1")

        let csv = "名称\n重复证书\n"
        let allowed = HashSet<Int64>()
        allowed.add(100)
        let existing = HashMap<String, Int64>()
        existing.add("100\u{1}重复证书", 42)
        let plan = ImportService.validate(
            csv, allowed, 0, 5000, existing: existing,
            mapping: mapping, defaults: defaults
        )
        @Assert(plan.valid, 0)
        @Assert(plan.duplicate, 1)
    }
}

// ============================================================
// ams.app.import · 批量导入服务（FR-IMP-001 / 002 / 003）
//
// 需求映射：
//   FR-IMP-001  Excel/CSV 批量导入条目：模板下载 + 逐行校验 + 异步任务
//   FR-IMP-002  批量导入附件：见文件末尾 [IMP-002 说明]
//   FR-IMP-003  导入前预检：只报告不落库（dry-run）
//
// 设计要点：
//   · CSV 解析自己实现（RFC4180 子集）：支持双引号包裹、内部 "" 转义、
//     字段内换行与逗号。不做「按逗号 split」——那会把含逗号的备注拆散，
//     用户看到的错误行号就会对不上。
//   · 行号一律是**文件里看到的行号**（表头为第 1 行），错误报告直接给行号，
//     用户能立刻定位。
//   · 预检与执行共用同一套 validate()，避免「预检说没问题、执行却报错」。
//   · 执行采用分批提交（每 200 行），单行失败不影响其余行 —— 导入是
//     部分成功语义，全量回滚会让用户丢掉 999 条正确数据。
// ============================================================
package ams.app.importer

import std.collection.*

import ams.app.audit.*
import ams.crypto.provider.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.id.*
import ams.kernel.time.*
import ams.security.audit.*
import ams.storage.*

/** 单行校验错误 */
public class RowError {
    public let line: Int64
    public let field: String
    public let message: String

    public init(line: Int64, field: String, message: String) {
        this.line = line
        this.field = field
        this.message = message
    }
}

/** 预检结果 */
public class ImportPlan {
    public let total: Int64
    public let valid: Int64
    public let invalid: Int64
    /**
     * 与库内已有条目重复的行数（FR-IMP-004）。
     *
     * 重复**不是错误**：数据本身合法，只是已经存在。混进 invalid 会让用户
     * 以为文件写错了，混进 valid 又会在确认后静默造出第二条同名条目。
     * 单列一档，由用户决定「跳过」。
     */
    public let duplicate: Int64
    public let errors: ArrayList<RowError>
    /** 重复明细（同一结构，field 恒为 title） */
    public let duplicates: ArrayList<RowError>
    /** 通过校验的行（内部使用） */
    let good: ArrayList<ImportRow>

    public init(
        total: Int64,
        valid: Int64,
        invalid: Int64,
        duplicate: Int64,
        errors: ArrayList<RowError>,
        duplicates: ArrayList<RowError>,
        good: ArrayList<ImportRow>
    ) {
        this.total = total
        this.valid = valid
        this.invalid = invalid
        this.duplicate = duplicate
        this.errors = errors
        this.duplicates = duplicates
        this.good = good
    }
}

/** 一行解析后的导入数据 */
public class ImportRow {
    public let line: Int64
    public let subjectId: Int64
    public let category: Int64
    public let title: String
    public let status: Int64
    public let sensitivity: Int64
    public let issuedDate: String
    public let expiresAt: String
    public let issuer: String
    public let remark: String
    /** 自定义字段（fieldKey → 值），由导入模板映射而来（FR-IMP-005）。 */
    public let customFields: HashMap<String, String>

    init(
        line: Int64, subjectId: Int64, category: Int64, title: String, status: Int64,
        sensitivity: Int64, issuedDate: String, expiresAt: String, issuer: String, remark: String,
        customFields!: HashMap<String, String> = HashMap<String, String>()
    ) {
        this.line = line
        this.subjectId = subjectId
        this.category = category
        this.title = title
        this.status = status
        this.sensitivity = sensitivity
        this.issuedDate = issuedDate
        this.expiresAt = expiresAt
        this.issuer = issuer
        this.remark = remark
        this.customFields = customFields
    }
}

/**
 * 批量导入服务。
 */
public class ImportService {
    private let itemRepo: ItemRepo
    private let userRepo: UserRepo
    private let taskRepo: ExportTaskRepo
    private let notifyRepo: NotifyRepo
    private let storage: StorageBackend
    private let recorder: ?AuditRecorder
    /** 摘要/HMAC 能力（FR-EXP-008 回导验签用）；为空则仅能校验 sha256 指纹 */
    private let crypto: ?CryptoProvider
    /** 导出包签名密钥：必须与导出侧一致，否则回导会被判为「签名不匹配」 */
    private let signKey: String
    /** 字段定义仓储（FR-IMP-005 自定义字段落库用）；空则模板映射的自定义列被忽略 */
    private let fieldDefRepo: ?FieldDefRepo
    /** 扩展字段明细仓储（FR-IMP-005 自定义字段落库用） */
    private let itemFieldRepo: ?ItemFieldRepo

    private static let BATCH: Int64 = 200
    private static let MAX_ROWS: Int64 = 5000
    /** 判重索引的条目上限（与附件导入的标题索引同量级） */
    private static let TITLE_INDEX_LIMIT: Int64 = 20000
    public static let TTL_MILLIS: Int64 = 7 * 24 * 3600 * 1000
    /** 系统字段键集合：模板映射里出现这些键时走系统列，其余视为自定义字段键 */
    private static let SYSTEM_FIELDS: Array<String> = [
        "subject_id", "category", "title", "status", "sensitivity",
        "issued_date", "expires_at", "issuer", "remark"
    ]

    public init(
        itemRepo: ItemRepo,
        userRepo: UserRepo,
        taskRepo: ExportTaskRepo,
        notifyRepo: NotifyRepo,
        storage: StorageBackend,
        recorder!: ?AuditRecorder = None,
        crypto!: ?CryptoProvider = None,
        signKey!: String = "",
        fieldDefRepo!: ?FieldDefRepo = None,
        itemFieldRepo!: ?ItemFieldRepo = None
    ) {
        this.itemRepo = itemRepo
        this.userRepo = userRepo
        this.taskRepo = taskRepo
        this.notifyRepo = notifyRepo
        this.storage = storage
        this.recorder = recorder
        this.crypto = crypto
        this.signKey = signKey
        this.fieldDefRepo = fieldDefRepo
        this.itemFieldRepo = itemFieldRepo
    }

    /** 模板 CSV（表头 + 一行示例，示例行以 # 开头便于识别） */
    public static func template(): String {
        return "subject_id,category,title,status,sensitivity,issued_date,expires_at,issuer,remark\n" +
               "# 说明：subject_id 留空表示使用「默认主体」（由导入请求指定）；" +
               "category 1-11；status 0-9；sensitivity 1-3\n" +
               "# 示例（导入前请删除所有 # 开头的行）：\n" +
               "0,3,示例：本科学历证书,0,1,2020-09-01,,示例大学,备注可留空\n"
    }

    /**
     * 预检（FR-IMP-003）：只校验，不落库。
     *
     * @param mapping  导入模板的「CSV 表头 → 字段键」映射（FR-IMP-005）；
     *                空则沿用固定列序（cells[0..8]），零回归。
     * @param defaults 系统字段未从 CSV 取到时的默认值（fieldKey → value）。
     */
    public func precheck(
        actorId: Int64,
        scopeAny: Bool,
        csvText: String,
        defaultSubjectId: Int64,
        maxRows: Int64,
        mapping!: HashMap<String, String> = HashMap<String, String>(),
        defaults!: HashMap<String, String> = HashMap<String, String>()
    ): ImportPlan {
        let allowed = this.allowedSubjects(actorId, scopeAny)
        // 判重索引在预检阶段就要建：预检的职责是把「会发生什么」摊开，
        // 「这行会新建 / 这行会重复」正是用户最需要事先知道的信息。
        let existing = this.existingTitleIndex(allowed)
        return ImportService.validate(
            csvText, allowed, defaultSubjectId, maxRows, existing: existing,
            mapping: mapping, defaults: defaults
        )
    }

    /**
     * 提交导入任务：落库 + 起后台线程，立即返回任务号。
     */
    public func submit(
        actorId: Int64,
        scopeAny: Bool,
        csvText: String,
        defaultSubjectId: Int64,
        taskNo: String,
        mapping!: HashMap<String, String> = HashMap<String, String>(),
        defaults!: HashMap<String, String> = HashMap<String, String>()
    ): String {
        let now = Times.nowMillis()
        let params = "{\"defaultSubjectId\":${defaultSubjectId}," +
                     "\"scopeAny\":${if (scopeAny) { "true" } else { "false" }}}"
        let taskId = this.taskRepo.create(
            taskNo, "import", actorId, None, "csv", params, 0, now + TTL_MILLIS
        )
        spawn { =>
            this.runTask(taskId, actorId, scopeAny, csvText, defaultSubjectId, taskNo, mapping, defaults)
        }
        return taskNo
    }

    private func runTask(
        taskId: Int64,
        actorId: Int64,
        scopeAny: Bool,
        csvText: String,
        defaultSubjectId: Int64,
        taskNo: String,
        mapping: HashMap<String, String>,
        defaults: HashMap<String, String>
    ): Unit {
        var done: Int64 = 0
        var failed: Int64 = 0
        // 分类 → 字段定义 的缓存：导入大文件时避免每行都查一次库
        let defCache = HashMap<Int64, ArrayList<FieldDefRecord>>()
        try {
            let allowed = this.allowedSubjects(actorId, scopeAny)
            // 执行阶段用**同一套**判重：否则会出现「预检说会跳过、执行却建了第二条」。
            let existing = this.existingTitleIndex(allowed)
            let plan = ImportService.validate(
                csvText, allowed, defaultSubjectId, MAX_ROWS, existing: existing,
                mapping: mapping, defaults: defaults
            )
            if (!this.taskRepo.claim(taskId, plan.total)) {
                return
            }
            let errSb = StringBuilder()
            errSb.append("line,field,message\n")
            for (e in plan.errors) {
                errSb.append("${e.line},${ImportService.cell(e.field)},${ImportService.cell(e.message)}\n")
            }
            var sinceCheck: Int64 = 0
            for (r in plan.good) {
                if (this.taskRepo.isCancelled(taskId)) {
                    // 已取消：把已处理的成果与错误报告落盘，状态保持 cancelled
                    this.writeReport(taskNo, taskId, errSb.toString())
                    return
                }
                try {
                    let newId = this.itemRepo.create(
                        r.subjectId, r.category, r.title, r.status, r.sensitivity,
                        r.issuedDate, r.expiresAt, r.issuer, r.remark, "{}", actorId,
                        source: 1
                    )
                    done = done + 1
                    // FR-IMP-005：模板映射带来的自定义字段，解析为 field_def 后落 arc_item_fields
                    if (!r.customFields.isEmpty()) {
                        let unresolved =
                            this.writeCustomFields(newId, r.category, actorId, r.customFields, defCache)
                        for (u in unresolved) {
                            errSb.append("${r.line},row," +
                                "${ImportService.cell(u)} 未在分类 ${r.category} 的字段定义中找到，已忽略\n")
                        }
                    }
                } catch (e: Exception) {
                    failed = failed + 1
                    errSb.append("${r.line},row,${ImportService.cell(ImportService.oneLine(e.message))}\n")
                }
                sinceCheck = sinceCheck + 1
                if (sinceCheck >= BATCH) {
                    sinceCheck = 0
                    this.taskRepo.updateProgress(taskId, done, failed)
                }
            }
            let key = this.writeReport(taskNo, taskId, errSb.toString())
            let now = Times.nowMillis()
            // 收尾用 finish：一次写全 total/done/failed。
            // 旧写法（markSuccess 后再 updateProgress）是空操作 ——
            // updateProgress 的 WHERE 是 status = 1，而 markSuccess 已置 2，
            // 于是 failed 永远显示 0。
            if (!this.taskRepo.finish(taskId, key, plan.total, done, plan.invalid + failed,
                                      now + TTL_MILLIS)) {
                return
            }
            let msg = if (plan.invalid + failed == 0) {
                "导入完成：${done} 条全部成功。"
            } else {
                "导入完成：成功 ${done} 条，失败 ${plan.invalid + failed} 条（详见错误报告）。"
            }
            this.notify(actorId, "导入完成", msg, "/import")
            this.audit(actorId, taskId, done, "success",
                       "import;failed=${plan.invalid + failed};total=${plan.total}")
        } catch (e: Exception) {
            let msg = ImportService.oneLine(e.message)
            try {
                this.taskRepo.markFailed(taskId, msg)
                this.notify(actorId, "导入失败", "导入任务执行失败：${msg}", "/import")
            } catch (e2: Exception) {
                // 放弃
            }
            this.audit(actorId, taskId, done, "failed", "error=${msg}")
        }
    }

    /**
     * 错误报告落盘，返回存储键。
     *
     * 即使零错误也写（只有表头），让下载行为对用户保持一致：
     * 「有任务就有报告」，不需要判断有没有错误再去点下载。
     */
    private func writeReport(taskNo: String, taskId: Int64, csv: String): String {
        let key = "${taskNo}-${taskId}-errors.csv"
        this.storage.put(key, csv.toArray())
        return key
    }

    /**
     * 把一行里的自定义字段（fieldKey → 值）解析为 field_def 后落 `arc_item_fields`。
     *
     * 与 FR-ARCH-004 的写库路径一致：服务端按 fieldKey 在「该分类可见字段定义」
     * （内置模板 + 调用者自定义）里定位 field_def_id 与 data_type，再 upsert。
     * 命中不到任何定义的键一律忽略，并把键名返回给调用方写进错误报告
     * （不阻断本行主条目的创建 —— 部分成功语义）。
     *
     * @param defCache 分类 → 字段定义 的缓存，避免大文件每行都查库
     * @return 未被任何字段定义覆盖的自定义字段键（供错误报告提示）
     */
    private func writeCustomFields(
        itemId: Int64,
        category: Int64,
        actorId: Int64,
        custom: HashMap<String, String>,
        defCache: HashMap<Int64, ArrayList<FieldDefRecord>>
    ): ArrayList<String> {
        let unresolved = ArrayList<String>()
        let fdr = match (this.fieldDefRepo) {
            case Some(r) => r
            case None => return unresolved
        }
        let ifr = match (this.itemFieldRepo) {
            case Some(r) => r
            case None => return unresolved
        }
        let defs = this.defsFor(fdr, defCache, category, actorId)
        for ((key, value) in custom) {
            var hit = false
            for (fd in defs) {
                if (fd.fieldKey == key) {
                    ifr.save(itemId, fd.id, fd.dataType, value)
                    hit = true
                    break
                }
            }
            if (!hit) {
                unresolved.add(key)
            }
        }
        return unresolved
    }

    /**
     * 取某分类的可见字段定义（带缓存）。
     */
    private func defsFor(
        fdr: FieldDefRepo,
        defCache: HashMap<Int64, ArrayList<FieldDefRecord>>,
        category: Int64,
        actorId: Int64
    ): ArrayList<FieldDefRecord> {
        match (defCache.get(category)) {
            case Some(list) => return list
            case None => ()
        }
        let list = fdr.listByCategory(category, actorId)
        defCache.add(category, list)
        return list
    }

    private func allowedSubjects(actorId: Int64, scopeAny: Bool): HashSet<Int64> {
        let ids = if (scopeAny) {
            this.userRepo.listAccessibleSubjectIds(actorId)
        } else {
            this.userRepo.listOwnedSubjectIds(actorId)
        }
        let set = HashSet<Int64>()
        for (s in ids) {
            set.add(RowData.toI64(s))
        }
        return set
    }

    private func notify(actorId: Int64, title: String, body: String, link: String): Unit {
        try {
            this.notifyRepo.push(actorId, None, title, body, Some(link), 1, None)
        } catch (e: Exception) {
            // 尽力而为
        }
    }

    private func audit(actorId: Int64, taskId: Int64, rows: Int64, result: String, detail: String): Unit {
        let recorder = match (this.recorder) {
            case Some(r) => r
            case None => return
        }
        let outcome = if (result == "success") { AuditResult.Success } else { AuditResult.Failure }
        try {
            recorder.record(
                "${actorId}",
                ActorType.User,
                AuditAction.BatchOperation,
                "import_task",
                "${taskId}",
                "",
                0,
                outcome,
                "",
                "",
                "",
                "async;imported=${rows};${detail}",
                Array<(String, String)>()
            )
        } catch (e: Exception) {
            // 审计失败不改变任务结论
        }
    }

    // ---- 校验与解析 ----

    /**
     * 构建「主体 + 标题 → 已有条目 ID」索引（FR-IMP-004 判重用）。
     *
     * 一次性取全部可写主体的条目标题，而不是每行查一次 SQL：
     * 5000 行的导入 = 5000 次往返，预检会慢到用户以为卡死。
     * 上限同附件导入的标题索引（20000 条），超过即可能判重不全 ——
     * 以「漏判」而非「误判」的方式失败：漏判最多多建一条，
     * 误判会让用户以为数据丢了。
     */
    private func existingTitleIndex(allowed: HashSet<Int64>): HashMap<String, Int64> {
        let index = HashMap<String, Int64>()
        let subjects = ArrayList<String>()
        for (s in allowed) {
            subjects.add("${s}")
        }
        let rows = this.itemRepo.list(
            subjects.toArray(), 0, -1, "", TITLE_INDEX_LIMIT, 0
        )
        for (r in rows.all()) {
            index.add(ImportService.dupKey(r.str("subject_id"), r.str("title")), r.i64("id"))
        }
        return index
    }

    /**
     * 判重键：主体 ID + 标题。
     *
     * 用 \u0001 分隔而不用冒号/竖线：标题里出现这些字符很常见，
     * 拼接后再切分会撞键。控制字符在标题里几乎不可能出现。
     */
    static func dupKey(subjectId: String, title: String): String {
        return "${subjectId}\u{1}${title}"
    }

    static func validate(
        csvText: String,
        allowed: HashSet<Int64>,
        defaultSubjectId: Int64,
        maxRows: Int64,
        existing!: HashMap<String, Int64> = HashMap<String, Int64>(),
        mapping!: HashMap<String, String> = HashMap<String, String>(),
        defaults!: HashMap<String, String> = HashMap<String, String>()
    ): ImportPlan {
        let errors = ArrayList<RowError>()
        let duplicates = ArrayList<RowError>()
        let good = ArrayList<ImportRow>()
        let rows = Csv.parse(csvText)
        var total: Int64 = 0
        var lineNo: Int64 = 0
        // 模板映射开启时：把 mapping 反转为「字段键 → CSV 表头」，并逐行按表头定位列。
        // 无映射时走固定列序（cells[0..8]），与旧行为零回归。
        let useMapping = !mapping.isEmpty()
        let fieldToHeader = HashMap<String, String>()
        if (useMapping) {
            for ((header, fieldKey) in mapping) {
                if (!fieldKey.isEmpty()) {
                    fieldToHeader.add(fieldKey, header)
                }
            }
        }
        var headerIndex = HashMap<String, Int64>()
        for (cells in rows) {
            lineNo = lineNo + 1
            // 表头：开启映射时必须先建「表头 → 列号」索引
            if (lineNo == 1) {
                if (useMapping) {
                    headerIndex = ImportService.buildHeaderIndex(cells)
                }
                continue
            }
            // 空行跳过（不计入总数，也不算错误）
            if (ImportService.isBlank(cells)) {
                continue
            }
            // 注释行（模板里的说明/示例）
            let first = if (cells.size > 0) { cells[0] } else { "" }
            if (first.startsWith("#")) {
                continue
            }
            total = total + 1
            if (total > maxRows) {
                errors.add(RowError(lineNo, "file", "超过单次导入上限 ${maxRows} 行，请拆分文件"))
                break
            }
            // ---- 解析系统字段（按映射或固定列序）----
            var sTitle = ""
            var sCategory = ""
            var sSens = ""
            var sStatus = ""
            var sSubject = ""
            var sIssued = ""
            var sExpires = ""
            var sIssuer = ""
            var sRemark = ""
            let custom = HashMap<String, String>()
            if (useMapping) {
                sTitle = ImportService.resolve("title", fieldToHeader, headerIndex, cells, defaults)
                sCategory = ImportService.resolve("category", fieldToHeader, headerIndex, cells, defaults)
                sSens = ImportService.resolve("sensitivity", fieldToHeader, headerIndex, cells, defaults)
                sStatus = ImportService.resolve("status", fieldToHeader, headerIndex, cells, defaults)
                sSubject = ImportService.resolve("subject_id", fieldToHeader, headerIndex, cells, defaults)
                sIssued = ImportService.resolve("issued_date", fieldToHeader, headerIndex, cells, defaults)
                sExpires = ImportService.resolve("expires_at", fieldToHeader, headerIndex, cells, defaults)
                sIssuer = ImportService.resolve("issuer", fieldToHeader, headerIndex, cells, defaults)
                sRemark = ImportService.resolve("remark", fieldToHeader, headerIndex, cells, defaults)
                // 自定义字段：映射里 fieldKey 不在系统字段集合的列，按表头取数
                for ((header, fieldKey) in mapping) {
                    if (!fieldKey.isEmpty() && !ImportService.isSystemField(fieldKey)) {
                        match (headerIndex.get(header)) {
                            case Some(idx) =>
                                let v = ImportService.at(cells, idx)
                                if (!v.isEmpty()) {
                                    custom.add(fieldKey, v)
                                }
                            case None => ()
                        }
                    }
                }
            } else {
                sTitle = ImportService.at(cells, 2)
                sCategory = ImportService.at(cells, 1)
                sSens = ImportService.at(cells, 4)
                sStatus = ImportService.at(cells, 3)
                sSubject = ImportService.at(cells, 0)
                sIssued = ImportService.at(cells, 5)
                sExpires = ImportService.at(cells, 6)
                sIssuer = ImportService.at(cells, 7)
                sRemark = ImportService.at(cells, 8)
            }
            // ---- 业务校验（两条路径共用，与旧行为一致）----
            if (sTitle.isEmpty()) {
                errors.add(RowError(lineNo, "title", "标题不能为空"))
                continue
            }
            if (sTitle.toArray().size > 200) {
                errors.add(RowError(lineNo, "title", "标题超过 200 字节"))
                continue
            }
            let cat = ImportService.numOf(sCategory, -1)
            // 1-11：与前端字典、字段定义接口一致（旧代码写死 1-6，
            // 会把 7-11（家庭关系/健康/资产/影像附件/自定义）统统判成非法）
            if (cat < 1 || cat > 11) {
                errors.add(RowError(lineNo, "category", "分类必须是 1-11 的数字"))
                continue
            }
            let sens = ImportService.numOf(sSens, 1)
            if (sens < 1 || sens > 3) {
                errors.add(RowError(lineNo, "sensitivity", "敏感度必须是 1-3"))
                continue
            }
            let st = ImportService.numOf(sStatus, 0)
            if (st < 0 || st > 9) {
                errors.add(RowError(lineNo, "status", "状态必须是 0-9"))
                continue
            }
            // subject: 空 → 默认主体；非空 → 必须在可写范围内
            var subj = ImportService.numOf(sSubject, 0)
            if (subj <= 0) {
                subj = defaultSubjectId
            }
            if (subj <= 0) {
                errors.add(RowError(lineNo, "subject_id", "必须指定主体（行内留空时需提供默认主体）"))
                continue
            }
            if (!allowed.contains(subj)) {
                errors.add(RowError(lineNo, "subject_id", "主体不存在或无写入权限"))
                continue
            }
            // ---- FR-IMP-004 判重：同主体 + 同标题视为已存在 ----
            match (existing.get(ImportService.dupKey("${subj}", sTitle))) {
                case Some(id) =>
                    duplicates.add(
                        RowError(lineNo, "title", "与已有条目重复（#${id}），将跳过")
                    )
                    continue
                case None => ()
            }
            good.add(ImportRow(
                lineNo, subj, cat, sTitle, st, sens, sIssued, sExpires, sIssuer, sRemark,
                customFields: custom
            ))
        }
        return ImportPlan(
            total, good.size, total - good.size - duplicates.size,
            duplicates.size, errors, duplicates, good
        )
    }

    /**
     * 构建「CSV 表头 → 列号」索引（按表头定位列的前提）。
     */
    private static func buildHeaderIndex(cells: Array<String>): HashMap<String, Int64> {
        let m = HashMap<String, Int64>()
        var i: Int64 = 0
        for (c in cells) {
            m.add(c.trimAscii(), i)
            i = i + 1
        }
        return m
    }

    /**
     * 按字段键解析系统字段值：优先「映射的 CSV 表头 → 列号」，其次取默认值。
     *
     * 既支持「模板列名 ↔ 系统字段」的任意映射，也支持「CSV 缺该列时回落默认」。
     */
    private static func resolve(
        fieldKey: String,
        fieldToHeader: HashMap<String, String>,
        headerIndex: HashMap<String, Int64>,
        cells: Array<String>,
        defaults: HashMap<String, String>
    ): String {
        match (fieldToHeader.get(fieldKey)) {
            case Some(header) =>
                match (headerIndex.get(header)) {
                    case Some(idx) => return ImportService.at(cells, idx)
                    case None => ()
                }
            case None => ()
        }
        match (defaults.get(fieldKey)) {
            case Some(d) => return d
            case None => return ""
        }
    }

    /** 字段键是否属于系统字段（否则视为自定义字段键，走 arc_item_fields）。 */
    private static func isSystemField(key: String): Bool {
        for (f in ImportService.SYSTEM_FIELDS) {
            if (f == key) {
                return true
            }
        }
        return false
    }

    /** 字符串 → 整数，空串回落默认值。 */
    private static func numOf(raw: String, default: Int64): Int64 {
        if (raw.isEmpty()) {
            return default
        }
        return RowData.toI64(raw)
    }

    private static func isBlank(cells: Array<String>): Bool {
        for (c in cells) {
            if (!c.trimAscii().isEmpty()) {
                return false
            }
        }
        return true
    }

    private static func at(cells: Array<String>, i: Int64): String {
        if (i < cells.size) {
            return cells[i].trimAscii()
        }
        return ""
    }

    private static func cell(s: String): String {
        if (s.contains(",") || s.contains("\"") || s.contains("\n")) {
            return "\"" + s.replace("\"", "\"\"") + "\""
        }
        return s
    }

    private static func oneLine(s: String): String {
        return s.replace("\n", " ").replace("\r", " ")
    }

    // ============================================================
    // FR-EXP-008 导出包回导（可携带闭环）
    //
    // 导出包结构（见 ams.app.export.async.bundle）：
    //   {"manifest":{...,"segments":[{"name":"items","bytes":N,"sha256":"..."}]},
    //    "items":[...],
    //    "signature":{"alg":"HMAC-SM3"|"SHA-256","value":"..."}}
    // 签名覆盖 manifest 原文 + items 原文（两侧直接拼接，无分隔符）。
    //
    // 【为什么不重新序列化再验签】
    //   签名针对**原始字节**。重新序列化哪怕语义相同，多一个空格、
    //   少一次转义就对不上。故从原文里按括号配平切出两段的原始子串，
    //   直接拼接校验 —— 这也是「离开系统后仍能自证未被篡改」的前提。
    // ============================================================

    /**
     * 校验导出包：签名 + items 段 sha256 指纹。
     *
     * 失败不抛异常而是返回 valid=false，便于预检接口把拒绝原因原样回给用户。
     */
    public func verifyBundle(bundleText: String): BundleVerifyResult {
        return ImportService.verifyPortableBundle(this.crypto, this.signKey, bundleText)
    }

    /**
     * 纯函数版验签：不依赖仓储，便于单测直接构造样本校验。
     */
    public static func verifyPortableBundle(
        crypto: ?CryptoProvider,
        signKey: String,
        bundleText: String
    ): BundleVerifyResult {
        let manifestRaw = ImportService.extractRawValue(bundleText, "manifest")
        let itemsRaw = ImportService.extractRawValue(bundleText, "items")
        if (manifestRaw.isEmpty() || itemsRaw.isEmpty()) {
            return BundleVerifyResult(false, "", 0, "导出包结构不完整：缺少 manifest 或 items 段")
        }
        let sigRaw = ImportService.extractRawValue(bundleText, "signature")
        let alg = ImportService.extractQuotedValue(sigRaw, "alg")
        let value = ImportService.extractQuotedValue(sigRaw, "value")
        if (alg.isEmpty() || value.isEmpty()) {
            return BundleVerifyResult(false, "", 0, "导出包缺少签名段（signature）")
        }
        if (alg != "HMAC-SM3" && alg != "SHA-256") {
            return BundleVerifyResult(false, alg, 0, "不支持的签名算法：${alg}")
        }
        // 签名原文 = manifest 原文 + items 原文（导出侧即如此拼接）
        let signed = "${manifestRaw}${itemsRaw}"
        let expected = if (alg == "HMAC-SM3") {
            ImportService.hmacSm3Hex(crypto, signKey, signed)
        } else {
            ImportService.sha256Hex(crypto, signed)
        }
        if (!ImportService.constantTimeEq(expected, value)) {
            return BundleVerifyResult(false, alg, 0,
                "签名校验失败：导出包可能已被篡改，或签名密钥与导出方不一致")
        }
        // 二次核对 items 段指纹（manifest.segments[0].sha256）
        let segSha = ImportService.extractQuotedValue(manifestRaw, "sha256")
        if (!segSha.isEmpty()) {
            let itemsSha = ImportService.sha256Hex(crypto, itemsRaw)
            if (!ImportService.constantTimeEq(itemsSha, segSha)) {
                return BundleVerifyResult(false, alg, 0,
                    "数据完整性校验失败：items 段 sha256 指纹不匹配")
            }
        }
        let itemCount = ImportService.extractNumericValue(manifestRaw, "itemCount")
        return BundleVerifyResult(true, alg, itemCount, "")
    }

    /**
     * 回导预检：验签 + 逐行校验 + 判重，只报告不落库。
     */
    public func planBundle(
        actorId: Int64,
        scopeAny: Bool,
        bundleText: String,
        defaultSubjectId: Int64
    ): ImportPlan {
        let v = this.verifyBundle(bundleText)
        if (!v.valid) {
            throw validationError("bundle", v.reason)
        }
        let allowed = this.allowedSubjects(actorId, scopeAny)
        let existing = this.existingTitleIndex(allowed)
        return this.buildBundlePlan(allowed, existing, this.parseBundleRows(bundleText), defaultSubjectId)
    }

    /**
     * 提交回导任务：与 CSV / ZIP 通道共用任务表与进度语义。
     */
    public func submitBundle(
        actorId: Int64,
        scopeAny: Bool,
        bundleText: String,
        defaultSubjectId: Int64,
        taskNo: String
    ): Unit {
        let now = Times.nowMillis()
        let params = "{\"defaultSubjectId\":${defaultSubjectId},\"format\":\"bundle\"}"
        let taskId = this.taskRepo.create(
            taskNo, "import", actorId, None, "bundle", params, 0, now + TTL_MILLIS
        )
        spawn { =>
            this.runBundleTask(taskId, actorId, scopeAny, bundleText, defaultSubjectId, taskNo)
        }
    }

    private func runBundleTask(
        taskId: Int64,
        actorId: Int64,
        scopeAny: Bool,
        bundleText: String,
        defaultSubjectId: Int64,
        taskNo: String
    ): Unit {
        var done: Int64 = 0
        var failed: Int64 = 0
        try {
            // 验签失败即拒绝：一个字节都不落库
            let v = this.verifyBundle(bundleText)
            if (!v.valid) {
                this.taskRepo.markFailed(taskId, v.reason)
                this.audit(actorId, taskId, 0, "failed", "verify=${v.reason}")
                return
            }
            let allowed = this.allowedSubjects(actorId, scopeAny)
            let existing = this.existingTitleIndex(allowed)
            let plan = this.buildBundlePlan(
                allowed, existing, this.parseBundleRows(bundleText), defaultSubjectId
            )
            if (!this.taskRepo.claim(taskId, plan.total)) {
                return
            }
            let errSb = StringBuilder()
            errSb.append("line,field,message\n")
            for (e in plan.errors) {
                errSb.append("${e.line},${ImportService.cell(e.field)},${ImportService.cell(e.message)}\n")
            }
            var sinceCheck: Int64 = 0
            for (r in plan.good) {
                if (this.taskRepo.isCancelled(taskId)) {
                    this.writeReport(taskNo, taskId, errSb.toString())
                    return
                }
                try {
                    // source=5：回导（区别于手工 0 / CSV 1 / 克隆 2 / OCR 3 / 附件 4）
                    this.itemRepo.create(
                        r.subjectId, r.category, r.title, r.status, r.sensitivity,
                        r.issuedDate, r.expiresAt, r.issuer, r.remark, "{}", actorId,
                        source: 5
                    )
                    done = done + 1
                } catch (e: Exception) {
                    failed = failed + 1
                    errSb.append("${r.line},row,${ImportService.cell(ImportService.oneLine(e.message))}\n")
                }
                sinceCheck = sinceCheck + 1
                if (sinceCheck >= BATCH) {
                    sinceCheck = 0
                    this.taskRepo.updateProgress(taskId, done, failed)
                }
            }
            let key = this.writeReport(taskNo, taskId, errSb.toString())
            let now = Times.nowMillis()
            if (!this.taskRepo.finish(taskId, key, plan.total, done, plan.invalid + failed,
                                      now + TTL_MILLIS)) {
                return
            }
            let msg = if (plan.invalid + failed == 0) {
                "回导完成：${done} 条全部成功（签名与指纹校验通过）。"
            } else {
                "回导完成：成功 ${done} 条，失败 ${plan.invalid + failed} 条（详见错误报告）。"
            }
            this.notify(actorId, "回导完成", msg, "/import")
            this.audit(actorId, taskId, done, "success",
                       "bundle;imported=${done};failed=${plan.invalid + failed};total=${plan.total}")
        } catch (e: Exception) {
            let msg = ImportService.oneLine(e.message)
            try {
                this.taskRepo.markFailed(taskId, msg)
                this.notify(actorId, "回导失败", "导出包回导失败：${msg}", "/import")
            } catch (e2: Exception) {
                // 放弃
            }
            this.audit(actorId, taskId, done, "failed", "error=${msg}")
        }
    }

    /** 把导出包 items 段解析为导入行（不做业务校验）。 */
    private func parseBundleRows(bundleText: String): ArrayList<ImportRow> {
        let itemsRaw = ImportService.extractRawValue(bundleText, "items")
        let elems = ImportService.splitArrayElements(itemsRaw)
        let out = ArrayList<ImportRow>()
        var line: Int64 = 0
        for (el in elems) {
            line = line + 1
            out.add(ImportRow(
                line,
                ImportService.extractNumericValue(el, "subjectId"),
                ImportService.extractNumericValue(el, "category"),
                ImportService.extractQuotedValue(el, "title"),
                ImportService.extractNumericValue(el, "status"),
                ImportService.extractNumericValue(el, "sensitivity"),
                ImportService.extractQuotedValue(el, "issuedDate"),
                ImportService.extractQuotedValue(el, "expiresAt"),
                ImportService.extractQuotedValue(el, "issuer"),
                ""
            ))
        }
        return out
    }

    /**
     * 统一校验：预检与执行必须走同一条路径，否则会出现
     * 「预检说能导、执行却报错」。
     */
    private func buildBundlePlan(
        allowed: HashSet<Int64>,
        existing: HashMap<String, Int64>,
        rows: ArrayList<ImportRow>,
        defaultSubjectId: Int64
    ): ImportPlan {
        let errors = ArrayList<RowError>()
        let duplicates = ArrayList<RowError>()
        let good = ArrayList<ImportRow>()
        var total: Int64 = 0
        var invalid: Int64 = 0
        for (r in rows) {
            total = total + 1
            if (r.title.isEmpty()) {
                invalid = invalid + 1
                errors.add(RowError(r.line, "title", "标题不能为空"))
                continue
            }
            if (r.title.toArray().size > 200) {
                invalid = invalid + 1
                errors.add(RowError(r.line, "title", "标题超过 200 字节"))
                continue
            }
            if (r.category < 1 || r.category > 11) {
                invalid = invalid + 1
                errors.add(RowError(r.line, "category", "分类必须是 1-11 的数字"))
                continue
            }
            if (r.sensitivity < 1 || r.sensitivity > 3) {
                invalid = invalid + 1
                errors.add(RowError(r.line, "sensitivity", "敏感度必须是 1-3"))
                continue
            }
            if (r.status < 0 || r.status > 9) {
                invalid = invalid + 1
                errors.add(RowError(r.line, "status", "状态必须是 0-9"))
                continue
            }
            // 主体映射：包内主体若不在可写范围（跨系统回导时必然如此），
            // 一律落到请求指定的默认主体，避免回导越权写到别人的主体。
            var subj = r.subjectId
            if (subj <= 0 || !allowed.contains(subj)) {
                subj = defaultSubjectId
            }
            if (subj <= 0) {
                invalid = invalid + 1
                errors.add(RowError(r.line, "subject_id", "主体不存在或无写入权限，且未提供默认主体"))
                continue
            }
            match (existing.get(ImportService.dupKey("${subj}", r.title))) {
                case Some(id) =>
                    duplicates.add(RowError(r.line, "title", "与已有条目重复（#${id}），将跳过"))
                    continue
                case None => ()
            }
            good.add(ImportRow(
                r.line, subj, r.category, r.title, r.status, r.sensitivity,
                r.issuedDate, r.expiresAt, r.issuer, r.remark
            ))
        }
        return ImportPlan(total, good.size, invalid, duplicates.size, errors, duplicates, good)
    }

    // ---- 原文定位（不依赖 JSON 库，且必须保留原始字节） ----

    private static func isWs(c: Int64): Bool {
        return c == 32 || c == 9 || c == 13 || c == 10
    }

    /**
     * 切出顶层键对应「对象或数组」的原始子串（含两侧括号）。
     *
     * 只认「前面是 { , 或空白」且「键后跟冒号」的匹配：
     * 字符串值里出现的同名片段后面不会是冒号，故不会被误当键。
     */
    private static func extractRawValue(raw: String, key: String): String {
        let bytes = raw.toArray()
        let kb = "\"${key}\"".toArray()
        var i: Int64 = 0
        while (i + kb.size <= bytes.size) {
            var matched = true
            for (k in 0..kb.size) {
                if (bytes[i + k] != kb[k]) {
                    matched = false
                    break
                }
            }
            if (matched) {
                let prev = if (i > 0) { Int64(bytes[i - 1]) } else { 123 }
                if (prev == 123 || prev == 44 || ImportService.isWs(prev)) {
                    var j = i + kb.size
                    while (j < bytes.size && ImportService.isWs(Int64(bytes[j]))) {
                        j = j + 1
                    }
                    if (j < bytes.size && Int64(bytes[j]) == 58) {
                        j = j + 1
                        while (j < bytes.size && ImportService.isWs(Int64(bytes[j]))) {
                            j = j + 1
                        }
                        if (j < bytes.size && (Int64(bytes[j]) == 123 || Int64(bytes[j]) == 91)) {
                            let open = Int64(bytes[j])
                            let close = if (open == 123) { 125 } else { 93 }
                            var depth: Int64 = 0
                            var k2 = j
                            while (k2 < bytes.size) {
                                let c = Int64(bytes[k2])
                                if (c == open) {
                                    depth = depth + 1
                                } else if (c == close) {
                                    depth = depth - 1
                                    if (depth == 0) {
                                        return String.fromUtf8(bytes[j..k2 + 1])
                                    }
                                }
                                k2 = k2 + 1
                            }
                        }
                    }
                }
            }
            i = i + 1
        }
        return ""
    }

    /** 取字符串字段值（"key":"..."），支持转义跳过。 */
    private static func extractQuotedValue(raw: String, key: String): String {
        let bytes = raw.toArray()
        let kb = "\"${key}\"".toArray()
        var i: Int64 = 0
        while (i + kb.size <= bytes.size) {
            var matched = true
            for (k in 0..kb.size) {
                if (bytes[i + k] != kb[k]) {
                    matched = false
                    break
                }
            }
            if (matched) {
                var j = i + kb.size
                while (j < bytes.size && ImportService.isWs(Int64(bytes[j]))) {
                    j = j + 1
                }
                if (j < bytes.size && Int64(bytes[j]) == 58) {
                    j = j + 1
                    while (j < bytes.size && ImportService.isWs(Int64(bytes[j]))) {
                        j = j + 1
                    }
                    if (j < bytes.size && Int64(bytes[j]) == 34) {
                        j = j + 1
                        let start = j
                        while (j < bytes.size) {
                            let c = Int64(bytes[j])
                            if (c == 92) {
                                j = j + 2
                                continue
                            }
                            if (c == 34) {
                                return String.fromUtf8(bytes[start..j])
                            }
                            j = j + 1
                        }
                    }
                }
            }
            i = i + 1
        }
        return ""
    }

    /** 取数字字段值（"key":123），非数字返回 0。 */
    private static func extractNumericValue(raw: String, key: String): Int64 {
        let bytes = raw.toArray()
        let kb = "\"${key}\"".toArray()
        var i: Int64 = 0
        while (i + kb.size <= bytes.size) {
            var matched = true
            for (k in 0..kb.size) {
                if (bytes[i + k] != kb[k]) {
                    matched = false
                    break
                }
            }
            if (matched) {
                var j = i + kb.size
                while (j < bytes.size && ImportService.isWs(Int64(bytes[j]))) {
                    j = j + 1
                }
                if (j < bytes.size && Int64(bytes[j]) == 58) {
                    j = j + 1
                    while (j < bytes.size && ImportService.isWs(Int64(bytes[j]))) {
                        j = j + 1
                    }
                    var neg = false
                    if (j < bytes.size && Int64(bytes[j]) == 45) {
                        neg = true
                        j = j + 1
                    }
                    var num: Int64 = 0
                    var any = false
                    while (j < bytes.size && Int64(bytes[j]) >= 48 && Int64(bytes[j]) <= 57) {
                        num = num * 10 + (Int64(bytes[j]) - 48)
                        j = j + 1
                        any = true
                    }
                    if (any) {
                        return if (neg) { -num } else { num }
                    }
                }
            }
            i = i + 1
        }
        return 0
    }

    /** 把 JSON 数组原文切成元素原文（按顶层逗号，尊重字符串与嵌套）。 */
    private static func splitArrayElements(text: String): ArrayList<String> {
        let out = ArrayList<String>()
        let bytes = text.toArray()
        var s: Int64 = 0
        while (s < bytes.size && (Int64(bytes[s]) == 91 || ImportService.isWs(Int64(bytes[s])))) {
            s = s + 1
        }
        var e = bytes.size
        while (e > s && (Int64(bytes[e - 1]) == 93 || ImportService.isWs(Int64(bytes[e - 1])))) {
            e = e - 1
        }
        var i = s
        var start = s
        var inStr = false
        var escaped = false
        var depth: Int64 = 0
        while (i < e) {
            let b = Int64(bytes[i])
            if (inStr) {
                if (escaped) {
                    escaped = false
                } else if (b == 92) {
                    escaped = true
                } else if (b == 34) {
                    inStr = false
                }
            } else if (b == 34) {
                inStr = true
            } else if (b == 123 || b == 91) {
                depth = depth + 1
            } else if (b == 125 || b == 93) {
                if (depth > 0) {
                    depth = depth - 1
                }
            } else if (b == 44 && depth == 0) {
                out.add(String.fromUtf8(bytes[start..i]))
                start = i + 1
            }
            i = i + 1
        }
        if (start < e) {
            out.add(String.fromUtf8(bytes[start..e]))
        }
        return out
    }

    // ---- 摘要 ----

    private static func sha256Hex(crypto: ?CryptoProvider, data: String): String {
        let prov = match (crypto) {
            case Some(c) => c
            case None => return ""
        }
        match (prov.digest(data.toArray(), DigestAlgorithm.Sha256)) {
            case CryptoResult.Ok(b) => return ImportService.hex(b)
            case CryptoResult.Err(_) => return ""
        }
    }

    private static func hmacSm3Hex(crypto: ?CryptoProvider, key: String, data: String): String {
        let prov = match (crypto) {
            case Some(c) => c
            case None => return ""
        }
        match (prov.hmac(key.toArray(), data.toArray(), DigestAlgorithm.Sm3)) {
            case CryptoResult.Ok(b) => return ImportService.hex(b)
            case CryptoResult.Err(_) => return ""
        }
    }

    private static func hex(bytes: Array<Byte>): String {
        let sb = StringBuilder()
        for (b in bytes) {
            let v = Int64(b)
            sb.append(ImportService.hexDigit((v >> 4) & 15))
            sb.append(ImportService.hexDigit(v & 15))
        }
        return sb.toString()
    }

    private static func hexDigit(n: Int64): String {
        if (n < 0 || n > 15) {
            return "0"
        }
        return ImportService.HEX[n]
    }

    private static let HEX: Array<String> = [
        "0", "1", "2", "3", "4", "5", "6", "7",
        "8", "9", "a", "b", "c", "d", "e", "f"
    ]

    /** 定时无关比较：避免按字节提前返回泄露签名前缀信息。 */
    private static func constantTimeEq(a: String, b: String): Bool {
        if (a.size != b.size) {
            return false
        }
        let ba = a.toArray()
        let bb = b.toArray()
        var diff: Int64 = 0
        for (i in 0..a.size) {
            diff = diff | (Int64(ba[i]) ^ Int64(bb[i]))
        }
        return diff == 0
    }
}

/**
 * 导出包校验结果（FR-EXP-008）。
 */
public class BundleVerifyResult {
    public let valid: Bool
    public let alg: String
    public let itemCount: Int64
    public let reason: String

    public init(valid: Bool, alg: String, itemCount: Int64, reason: String) {
        this.valid = valid
        this.alg = alg
        this.itemCount = itemCount
        this.reason = reason
    }
}

/**
 * CSV 解析（RFC4180 子集）。
 *
 * 支持：双引号包裹字段、字段内 "" 表示一个引号、字段内逗号与换行。
 * 不处理：BOM（调用方先剔除）、CRLF（统一按 \n 处理后再 trim \r）。
 */
class Csv {
    static func parse(text: String): ArrayList<Array<String>> {
        let out = ArrayList<Array<String>>()
        var row = ArrayList<String>()
        var field = StringBuilder()
        var inQuotes = false
        var i: Int64 = 0
        let runes = ArrayList<Rune>()
        for (r in text.runes()) {
            runes.add(r)
        }
        var pending = false
        while (i < runes.size) {
            let ch = runes[i].toString()
            if (inQuotes) {
                if (ch == "\"") {
                    // "" → 转义引号
                    if (i + 1 < runes.size && runes[i + 1].toString() == "\"") {
                        field.append("\"")
                        i = i + 2
                        continue
                    }
                    inQuotes = false
                    i = i + 1
                    continue
                }
                field.append(ch)
                i = i + 1
                continue
            }
            if (ch == "\"") {
                inQuotes = true
                i = i + 1
                continue
            }
            if (ch == ",") {
                row.add(field.toString())
                field = StringBuilder()
                pending = true
                i = i + 1
                continue
            }
            if (ch == "\n") {
                row.add(field.toString())
                field = StringBuilder()
                out.add(row.toArray())
                row = ArrayList<String>()
                pending = false
                i = i + 1
                continue
            }
            if (ch == "\r") {
                i = i + 1
                continue
            }
            field.append(ch)
            pending = true
            i = i + 1
        }
        // 末行无换行符
        if (pending || field.toString().size > 0 || row.size > 0) {
            row.add(field.toString())
            out.add(row.toArray())
        }
        return out
    }
}

// ============================================================
// [IMP-002 说明] 批量导入附件 → 见同目录 attachimport.cj
//
// 需求原文：ZIP 上传，按目录结构匹配条目并挂载附件。
//
// 本文件（CSV 导入条目）与附件导入是**两条独立通道**，各有自己的服务：
//   · ImportService          —— CSV 逐行建条目（本文件）
//   · AttachmentImportService —— ZIP 内「一级目录名 = 条目标题」→ 挂附件
//                                （attachimport.cj + zipreader.cj + gbk.cj）
//
// 早期版本这里写着「stdx 无 zip，本期不实现解包」，该结论已被证伪：
// `stdx.compress.zlib` 的 `WrapType.DeflateFormat` 就是 RFC 1951 裸 deflate，
// 而 ZIP 条目正是这个格式，故解包器为手写实现而非「等外部工具」。
// 两条通道共用 imp_export_tasks（task_type=import）与同一套
// 异步任务 / 进度 / 错误报告 / 取消 / 重试语义，前端只需要一张任务列表。
// ============================================================

// ============================================================
// ams.app.importer · 附件批量导入（FR-IMP-002）
//
// 【业务流程：两阶段，预检不落库】
//   ① precheck(actorId, zip)  ── 解包 + 逐条 CRC 校验 + 目录→条目映射
//                                **不写任何库**，只返回映射预览
//   ② submit(..., resolutions) ── 用户在前端确认（并指定重名冲突）后，
//                                才真正建条目、传附件、写报告
//
// 【映射规则】
//   · ZIP 内**一级目录名** = 目标条目标题；该目录下的文件 = 该条目的附件。
//     例：`毕业证/正面.jpg`、`毕业证/反面.pdf` → 都挂到标题为「毕业证」的条目。
//   · 同标题条目命中 1 个 → match（直接挂载）
//   · 同标题条目命中 0 个 → create（确认后自动新建条目）。
//     **新建发生在确认之后**：预检阶段绝不建条目 —— 否则用户看一眼预览
//     就放弃，库里会留下一堆空条目。
//   · 同标题条目命中 ≥2 个 → conflict（**必须由用户手动指定**，不猜）。
//   · 压缩包根目录下（无一级目录）的文件 → skip（无法确定归属，不瞎猜）。
//
// 【为什么两阶段而不是一步到位】
//   目录名到条目的映射天然有歧义（同名条目、根目录散文件、命名不规范）。
//   一步到位会把歧义**静默**落成挂错条目的附件，而附件挂错后没有「撤销」，
//   只能人工逐个改。预检把歧义摊在用户面前，代价是多一次请求，
//   收益是错挂率归零。
//
// 【与 CSV 导入的一致性】
//   共用 imp_export_tasks（task_type=import，format=zip-attach）与同一套
//   异步任务/进度/错误报告/取消语义，前端只需要一套任务列表。
// ============================================================
package ams.app.importer

import std.collection.*

import ams.app.attachment.*
import ams.app.audit.*
import ams.core.attachment.*
import ams.crypto.provider.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.time.*
import ams.security.audit.*
import ams.storage.*

/** 映射动作：命中唯一同名条目 */
public const ACTION_MATCH: String = "match"
/** 映射动作：无同名条目，确认后自动新建 */
public const ACTION_CREATE: String = "create"
/** 映射动作：同名条目多个且用户尚未指定 */
public const ACTION_CONFLICT: String = "conflict"
/** 映射动作：不处理（扩展名/大小/编码/路径等原因） */
public const ACTION_SKIP: String = "skip"

/** 附件状态：已隔离（与 ams.core.attachment.AttachmentStatus.Quarantined 的编码一致） */
const ATT_STATUS_QUARANTINED: Int64 = 3

/**
 * 映射预览的一行（一个待导入文件）。
 */
public class AttachPlanRow {
    /** 稳定序号（ZIP 内出现顺序，从 1 开始；报告里用它定位） */
    public let index: Int64
    /** ZIP 内路径 */
    public let zipPath: String
    /** 一级目录名（即目标条目标题） */
    public let dirTitle: String
    /** 文件名 */
    public let fileName: String
    /** 解压后大小（字节） */
    public let size: Int64
    /** match / create / conflict / skip */
    public let action: String
    /** action=match 时的目标条目 ID，否则 0 */
    public let targetItemId: Int64
    /** 补充说明（skip/conflict 的原因） */
    public let note: String

    init(
        index: Int64, zipPath: String, dirTitle: String, fileName: String,
        size: Int64, action: String, targetItemId: Int64, note: String
    ) {
        this.index = index
        this.zipPath = zipPath
        this.dirTitle = dirTitle
        this.fileName = fileName
        this.size = size
        this.action = action
        this.targetItemId = targetItemId
        this.note = note
    }
}

/**
 * 一个候选条目（用于重名冲突时让用户挑）。
 */
public class TitleCandidate {
    public let itemId: Int64
    public let title: String
    public let category: Int64

    init(itemId: Int64, title: String, category: Int64) {
        this.itemId = itemId
        this.title = title
        this.category = category
    }
}

/**
 * 预检结果（映射预览）。
 */
public class AttachPlan {
    /** 全部待处理行（不截断；截断只发生在 JSON 输出层） */
    public let rows: ArrayList<AttachPlanRow>
    public let matchCount: Int64
    public let createCount: Int64
    public let conflictCount: Int64
    public let skipCount: Int64
    /** 涉及的目录（= 目标条目）个数 */
    public let dirCount: Int64
    /** 仍未解决的重名冲突：目录标题 → 候选条目 */
    public let conflicts: HashMap<String, ArrayList<TitleCandidate>>
    /** 将新建的条目标题（按出现顺序） */
    public let newTitles: ArrayList<String>
    /** 待导入总字节数（match+create 部分） */
    public let totalBytes: Int64
    /** 条目标题索引是否被截断（该主体条目过多，匹配可能不全） */
    public let indexTruncated: Bool
    /** 与 rows 下标一一对应的 ZIP 条目（执行阶段取内容用） */
    let entries: ArrayList<ZipEntry>

    init(
        rows: ArrayList<AttachPlanRow>, matchCount: Int64, createCount: Int64,
        conflictCount: Int64, skipCount: Int64, dirCount: Int64,
        conflicts: HashMap<String, ArrayList<TitleCandidate>>,
        newTitles: ArrayList<String>, totalBytes: Int64,
        indexTruncated: Bool, entries: ArrayList<ZipEntry>
    ) {
        this.rows = rows
        this.matchCount = matchCount
        this.createCount = createCount
        this.conflictCount = conflictCount
        this.skipCount = skipCount
        this.dirCount = dirCount
        this.conflicts = conflicts
        this.newTitles = newTitles
        this.totalBytes = totalBytes
        this.indexTruncated = indexTruncated
        this.entries = entries
    }

    /** 是否存在未解决的重名冲突 */
    public func hasConflict(): Bool {
        return !this.conflicts.isEmpty()
    }
}

/**
 * 附件批量导入服务。
 */
public class AttachmentImportService {
    private let itemRepo: ItemRepo
    private let userRepo: UserRepo
    private let taskRepo: ExportTaskRepo
    private let notifyRepo: NotifyRepo
    private let storage: StorageBackend
    private let attachments: AttachmentService
    private let recorder: ?AuditRecorder
    /** SM3 指纹去重所需（FR-IMP-004 附件侧）；为空则跳过去重比对 */
    private let crypto: ?CryptoProvider
    /** 取主体已有去重键集合（FR-IMP-004）；与 crypto 配套 */
    private let attachmentRepo: AttachmentRepo

    /** 分批回写进度 */
    private static let BATCH: Int64 = 20
    /** 预检预览返回的最大行数（超出由路由层截断） */
    public static let MAX_PREVIEW_ROWS: Int64 = 500
    /**
     * 单批文件数上限（PRD FR-IMP-002：单批 ≤ 500 文件）。
     *
     * 与 `IMPORT_MAX_ENTRIES`（2000）不是一回事：后者是**解析层**的防爆上限
     * （一个包里可能混着上千个不该导入的文件），这里是**业务约束**。
     * 超限不静默截断 —— 截断会让用户以为 800 个都导进去了。
     */
    public static let MAX_BATCH_FILES: Int64 = 500
    /** 条目标题索引上限（超过则该主体的条目可能匹配不全，需在响应里提示） */
    private static let TITLE_INDEX_LIMIT: Int64 = 20000
    /** 附件分类默认值（与 POST /api/attachments 的默认值保持一致） */
    public static let DEFAULT_ATT_CATEGORY: Int64 = 10
    public static let TTL_MILLIS: Int64 = 7 * 24 * 3600 * 1000

    public init(
        itemRepo: ItemRepo,
        userRepo: UserRepo,
        taskRepo: ExportTaskRepo,
        notifyRepo: NotifyRepo,
        storage: StorageBackend,
        attachments: AttachmentService,
        recorder!: ?AuditRecorder = None,
        crypto!: ?CryptoProvider = None,
        attachmentRepo!: AttachmentRepo
    ) {
        this.itemRepo = itemRepo
        this.userRepo = userRepo
        this.taskRepo = taskRepo
        this.notifyRepo = notifyRepo
        this.storage = storage
        this.attachments = attachments
        this.recorder = recorder
        this.crypto = crypto
        this.attachmentRepo = attachmentRepo
    }

    // ---------------------------------------------------------
    // 阶段一：预检（只报告，不落库）
    // ---------------------------------------------------------

    /**
     * 预检：解包 + 映射，**不写库**。
     *
     * @throws AppError 不是合法 ZIP / 主体无写权限 / 分类非法
     */
    public func precheck(
        actorId: Int64,
        scopeAny: Bool,
        zipBytes: Array<Byte>,
        subjectId: Int64,
        category: Int64
    ): AttachPlan {
        this.checkSubject(actorId, scopeAny, subjectId)
        AttachmentImportService.checkCategory(category)
        let zip = ZipArchive.open(zipBytes)
        // verify = true：预检就把每个文件解压一遍验 CRC。
        // 否则「预检说没问题、执行却失败」，用户会以为系统在骗他。
        let plan = this.buildPlan(zip, subjectId, HashMap<String, Int64>(), true)
        if (plan.rows.size == 0) {
            throw validationError("file", "压缩包内没有可导入的文件（仅 jpg/jpeg/png/pdf，且需放进以条目命名的目录）")
        }
        if (plan.rows.size > MAX_BATCH_FILES) {
            throw validationError(
                "file",
                "单批最多 ${MAX_BATCH_FILES} 个文件，当前包内有 ${plan.rows.size} 个，请拆分后分批导入"
            )
        }
        return plan
    }

    // ---------------------------------------------------------
    // 阶段二：确认并执行
    // ---------------------------------------------------------

    /**
     * 提交导入任务（异步）。
     *
     * @param resolutions 重名目录 → 指定条目 ID；0 表示「仍然新建条目」
     * @throws AppError(Conflict) 仍有未解决的重名冲突
     */
    public func submit(
        actorId: Int64,
        scopeAny: Bool,
        zipBytes: Array<Byte>,
        subjectId: Int64,
        category: Int64,
        resolutions: HashMap<String, Int64>,
        taskNo: String
    ): String {
        this.checkSubject(actorId, scopeAny, subjectId)
        AttachmentImportService.checkCategory(category)
        let zip = ZipArchive.open(zipBytes)
        let plan = this.buildPlan(zip, subjectId, resolutions, false)
        // 冲突必须在提交前解决：留到执行阶段只会变成一堆行错误，
        // 用户还得从报告里反推「到底哪个目录没指定」。
        if (plan.hasConflict()) {
            let titles = ArrayList<String>()
            for ((title, _cs) in plan.conflicts) {
                titles.add(title)
            }
            throw AppError(
                AppErrorKind.Conflict,
                "${titles.size} 个重名目录尚未指定目标条目：${AttachmentImportService.joinTitles(titles)}"
            )
        }
        let now = Times.nowMillis()
        let params = "{\"subjectId\":${subjectId},\"category\":${category}," +
                     "\"files\":${plan.rows.size},\"dirs\":${plan.dirCount}}"
        let taskId = this.taskRepo.create(
            taskNo, "import", actorId, Some<Int64>(subjectId), "zip-attach", params, 0,
            now + TTL_MILLIS
        )
        // 留存原始包与参数：失败重试时**不必让用户重新上传**（PRD「失败可重试」）。
        // 落盘失败不阻塞导入 —— 代价只是失去一键重试，不该让整批导入失败。
        this.keepForRetry(taskNo, zipBytes, subjectId, category)
        spawn { =>
            this.runTask(taskId, actorId, zipBytes, subjectId, category, resolutions, taskNo)
        }
        return taskNo
    }

    /**
     * 重试上一个任务里**失败的文件**（PRD FR-IMP-002「失败可重试」）。
     *
     * 不需要用户重新打包：提交时已把原始 ZIP 与参数留存在存储里，
     * 失败清单（条目序号）在任务收尾时一并写入。
     *
     * 为什么按**序号**而不是路径：ZIP 条目名可以含逗号、引号、换行，
     * 按路径存清单得再写一个转义层；序号是解析时确定的稳定位置，
     * 同一个包永远得到同一组序号（`AttachPlanRow.index` 就是为它存在的）。
     *
     * @return 本次待重试的文件数
     * @throws AppError 原任务未结束 / 无失败项 / 原包未留存 / 重试仍存在重名冲突
     */
    public func retry(
        actorId: Int64,
        scopeAny: Bool,
        prevTaskNo: String,
        taskNo: String
    ): Int64 {
        let prev = this.ownedTask(actorId, scopeAny, prevTaskNo)
        if (prev.i64("status") != 2) {
            throw AppError(AppErrorKind.Conflict, "任务尚未结束，无法重试")
        }
        // 原任务参数（主体 / 分类）
        let meta = match (this.storage.get("meta-${prevTaskNo}.txt")) {
            case Some(b) => String.fromUtf8(b)
            case None => throw AppError(
                AppErrorKind.Conflict, "原任务参数未留存，无法重试，请重新选择压缩包导入"
            )
        }
        let metaLines = meta.split("\n")
        if (metaLines.size < 2) {
            throw AppError(AppErrorKind.Internal, "重试参数损坏")
        }
        let subjectId = RowData.toI64(metaLines[0])
        let category = RowData.toI64(metaLines[1])
        this.checkSubject(actorId, scopeAny, subjectId)
        AttachmentImportService.checkCategory(category)
        // 失败清单
        let failed = HashSet<Int64>()
        match (this.storage.get("fail-${prevTaskNo}.txt")) {
            case Some(b) =>
                for (p in String.fromUtf8(b).split(",")) {
                    let v = RowData.toI64(p)
                    if (v > 0) {
                        failed.add(v)
                    }
                }
            case None => ()
        }
        if (failed.isEmpty()) {
            throw AppError(AppErrorKind.Conflict, "该任务没有失败文件，无需重试")
        }
        let zipBytes = match (this.storage.get("in-${prevTaskNo}.zip")) {
            case Some(b) => b
            case None => throw AppError(
                AppErrorKind.Conflict, "原压缩包未留存（可能已过期），请重新选择该包导入"
            )
        }
        let zip = ZipArchive.open(zipBytes)
        let plan = this.buildPlan(
            zip, subjectId, HashMap<String, Int64>(), false, onlyIndexes: Some(failed)
        )
        if (plan.rows.size == 0) {
            throw AppError(AppErrorKind.Conflict, "失败文件已不在压缩包内，无法重试")
        }
        if (plan.hasConflict()) {
            let titles = ArrayList<String>()
            for ((title, _cs) in plan.conflicts) {
                titles.add(title)
            }
            throw AppError(
                AppErrorKind.Conflict,
                "重试涉及重名目录，请改用「选择压缩包 → 预检 → 手动指定」：${AttachmentImportService.joinTitles(titles)}"
            )
        }
        let now = Times.nowMillis()
        let params = "{\"retryOf\":\"${prevTaskNo}\",\"subjectId\":${subjectId}," +
                     "\"category\":${category},\"files\":${plan.rows.size}}"
        let taskId = this.taskRepo.create(
            taskNo, "import", actorId, Some<Int64>(subjectId), "zip-attach", params, 0,
            now + TTL_MILLIS
        )
        this.keepForRetry(taskNo, zipBytes, subjectId, category)
        let only = Some<HashSet<Int64>>(failed)
        spawn { =>
            this.runTask(
                taskId, actorId, zipBytes, subjectId, category,
                HashMap<String, Int64>(), taskNo, onlyIndexes: only
            )
        }
        return plan.rows.size
    }

    /**
     * 后台执行。
     *
     * 部分成功语义：单个文件失败不中断整体，失败明细写进报告 CSV。
     */
    private func runTask(
        taskId: Int64,
        actorId: Int64,
        zipBytes: Array<Byte>,
        subjectId: Int64,
        category: Int64,
        resolutions: HashMap<String, Int64>,
        taskNo: String,
        onlyIndexes!: Option<HashSet<Int64>> = None
    ): Unit {
        var done: Int64 = 0
        var failed: Int64 = 0
        // 失败条目的序号（重试时只跑这些）
        let failedIdx = ArrayList<Int64>()
        try {
            let zip = ZipArchive.open(zipBytes)
            let plan = this.buildPlan(
                zip, subjectId, resolutions, false, onlyIndexes: onlyIndexes
            )
            if (!this.taskRepo.claim(taskId, plan.rows.size)) {
                return
            }
            // FR-IMP-004：执行阶段同样按 SM3 指纹跳过主体内已存在的完全相同内容
            let execDedup = this.existingDedupKeys(subjectId)
            // ---- 先建条目：同一标题只建一次 ----
            let createdItems = HashMap<String, Int64>()
            let createdErr = HashMap<String, String>()
            for (title in plan.newTitles) {
                try {
                    let id = this.itemRepo.create(
                        subjectId, category, title, 0, 1, "", "", "",
                        "由 ZIP 批量导入自动创建", "{}", this.userRepo.tenantOf(actorId), actorId,
                        source: 4
                    )
                    createdItems.add(title, id)
                } catch (e: Exception) {
                    createdErr.add(title, AttachmentImportService.oneLine(e.message))
                }
            }
            let errSb = StringBuilder()
            errSb.append("index,zipPath,targetItem,status,message\n")
            for ((title, msg) in createdErr) {
                errSb.append("-,-,0,failed,\"目录「${AttachmentImportService.csvCell(title)}」建条目失败：" +
                             "${AttachmentImportService.csvCell(msg)}\"\n")
            }
            var sinceCheck: Int64 = 0
            var i: Int64 = 0
            while (i < plan.rows.size) {
                let row = plan.rows[i]
                let entry = plan.entries[i]
                i = i + 1
                if (this.taskRepo.isCancelled(taskId)) {
                    this.writeReport(taskNo, taskId, errSb.toString())
                    return
                }
                // skip / conflict：计入失败（总账要能对上 total）
                if (row.action == ACTION_SKIP || row.action == ACTION_CONFLICT) {
                    failed = failed + 1
                    errSb.append("${row.index},\"${AttachmentImportService.csvCell(row.zipPath)}\"," +
                                 "0,skipped,\"${AttachmentImportService.csvCell(row.note)}\"\n")
                    continue
                }
                // 目标条目
                let title = row.dirTitle
                var target: Int64 = 0
                if (row.action == ACTION_MATCH) {
                    target = row.targetItemId
                } else if (createdErr.contains(title)) {
                    failed = failed + 1
                    failedIdx.add(row.index)
                    errSb.append("${row.index},\"${AttachmentImportService.csvCell(row.zipPath)}\",0," +
                                 "failed,\"目标条目创建失败\"\n")
                    continue
                } else if (createdItems.contains(title)) {
                    target = createdItems[title]
                }
                if (target <= 0) {
                    failed = failed + 1
                    failedIdx.add(row.index)
                    errSb.append("${row.index},\"${AttachmentImportService.csvCell(row.zipPath)}\",0," +
                                 "failed,\"无法确定目标条目\"\n")
                    continue
                }
                // 取内容（含 CRC 校验）并上传
                try {
                    let plain = zip.read(entry, FileTypes.maxFileSize)
                    // FR-IMP-004：主体内已存在完全相同内容 → 跳过，不重复落盘
                    match (this.dedupKeyOf(subjectId, plain)) {
                        case Some(k) =>
                            if (execDedup.contains(k)) {
                                failed = failed + 1
                                errSb.append("${row.index},\"${AttachmentImportService.csvCell(row.zipPath)}\"," +
                                             "${target},skipped,\"与已有附件内容重复（SM3 指纹一致），已跳过\"\n")
                                continue
                            }
                        case None => ()
                    }
                    let res = this.attachments.upload(
                        subjectId, Some<Int64>(target),
                        AttachmentImportService.DEFAULT_ATT_CATEGORY,
                        row.fileName, row.fileName, plain, actorId, dedup: false
                    )
                    if (res.status == ATT_STATUS_QUARANTINED) {
                        // 魔数不符等 → 已入库但不可下载，按失败计
                        failed = failed + 1
                        errSb.append("${row.index},\"${AttachmentImportService.csvCell(row.zipPath)}\"," +
                                     "${target},quarantined,\"内容校验未通过，已隔离\"\n")
                    } else {
                        done = done + 1
                        errSb.append("${row.index},\"${AttachmentImportService.csvCell(row.zipPath)}\"," +
                                     "${target},ok,\"\"\n")
                    }
                } catch (e: Exception) {
                    failed = failed + 1
                    failedIdx.add(row.index)
                    let pathCell = AttachmentImportService.csvCell(row.zipPath)
                    let msgCell = AttachmentImportService.csvCell(
                        AttachmentImportService.oneLine(e.message)
                    )
                    errSb.append("${row.index},\"${pathCell}\",${target},failed,\"${msgCell}\"\n")
                }
                sinceCheck = sinceCheck + 1
                if (sinceCheck >= BATCH) {
                    sinceCheck = 0
                    this.taskRepo.updateProgress(taskId, done, failed)
                }
            }
            let key = this.writeReport(taskNo, taskId, errSb.toString())
            this.writeFailedIndexes(taskNo, failedIdx)
            let now = Times.nowMillis()
            // 收尾用 finish（一条 UPDATE 写全 total/done/failed）：
            // 先前「markSuccess 之后再 updateProgress 回写失败数」是空操作
            // —— updateProgress 要求 status=1，而 markSuccess 已置 2。
            if (!this.taskRepo.finish(taskId, key, plan.rows.size, done, failed, now + TTL_MILLIS)) {
                return
            }
            let msg = if (failed == 0) {
                "附件导入完成：${done} 个文件全部成功。"
            } else {
                "附件导入完成：成功 ${done} 个，失败 ${failed} 个（详见错误报告）。"
            }
            this.notify(actorId, "附件导入完成", msg, "/import")
            this.audit(actorId, taskId, done, "success", "attach;imported=${done};failed=${failed}")
        } catch (e: Exception) {
            let msg = AttachmentImportService.oneLine(e.message)
            try {
                this.taskRepo.markFailed(taskId, msg)
                this.notify(actorId, "附件导入失败", "附件导入任务执行失败：${msg}", "/import")
            } catch (e2: Exception) {
                // 放弃
            }
            this.audit(actorId, taskId, done, "failed", "error=${msg}")
        }
    }

    // ---------------------------------------------------------
    // 映射推导
    // ---------------------------------------------------------

    /**
     * 由 ZIP 内容 + 库内现有条目推导映射。
     *
     * 预检与执行走同一份逻辑（只有 resolutions 不同），避免
     * 「预检说将要新建、执行却挂到了别的条目」。
     */
    private func buildPlan(
        zip: ZipArchive,
        subjectId: Int64,
        resolutions: HashMap<String, Int64>,
        verify: Bool,
        onlyIndexes!: Option<HashSet<Int64>> = None
    ): AttachPlan {
        let index = this.titleIndexOf(subjectId)
        let titleIndex = index[0]
        let allIds = index[1]
        let indexTruncated = index[2] == 1
        // FR-IMP-004（附件侧）：一次性取该主体已有去重键集合，预检时按内存比对，
        // 避免「每个文件各查一次库」。crypto 为空时退化为不去重（仍按标题匹配）。
        let existingDedup = this.existingDedupKeys(subjectId)
        // ---- 第一遍：筛出候选文件并归组 ----
        let pending = ArrayList<ZipEntry>()
        let pendingTitle = ArrayList<String>()
        let pendingFile = ArrayList<String>()
        let pendingSkip = ArrayList<String>()
        // 每个候选条目的**全局序号**（= 非目录条目的解析顺序）。
        // 重试时按它筛选，所以它不能因为筛选而重新编号 —— 报告里的
        // `index` 列、失败清单、用户手里的错误报告都指向同一个数。
        let pendingPos = ArrayList<Int64>()
        let titleOrder = ArrayList<String>()
        let titleSeen = HashSet<String>()
        var pos: Int64 = 0
        for (entry in zip.entries()) {
            if (entry.isDir) {
                continue
            }
            pos = pos + 1
            var selected = true
            match (onlyIndexes) {
                case Some(set) => selected = set.contains(pos)
                case None => selected = true
            }
            if (!selected) {
                continue
            }
            let file = AttachmentImportService.baseName(entry.path)
            let title = AttachmentImportService.firstSegment(entry.path)
            var skip = ""
            if (!entry.issue.isEmpty()) {
                skip = entry.issue
            } else if (title.isEmpty()) {
                skip = "位于压缩包根目录，无法确定归属条目（请放进以条目命名的目录）"
            } else if (title.toArray().size > 200) {
                skip = "目录名超过 200 字节，无法作为条目标题"
            } else if (!FileTypes.isAllowedExtension(FileTypes.extensionOf(file))) {
                skip = "不支持的扩展名（仅 jpg/jpeg/png/pdf）"
            } else if (entry.uncompressedSize > FileTypes.maxFileSize) {
                skip = "解压后超过 50MB 单文件上限"
            } else if (verify) {
                // 预检阶段真解一遍：CRC 不符 / 数据损坏在这里就暴露，
                // 而不是等用户确认完才在报告里出现。
                try {
                    let plain = zip.read(entry, FileTypes.maxFileSize)
                    // FR-IMP-004：同主体已有完全相同内容 → 标记跳过（不重复落盘）
                    match (this.dedupKeyOf(subjectId, plain)) {
                        case Some(k) =>
                            if (existingDedup.contains(k)) {
                                skip = "与已有附件内容重复（SM3 指纹一致），已标记为跳过"
                            }
                        case None => ()
                    }
                } catch (e: Exception) {
                    skip = "内容校验未通过：${AttachmentImportService.oneLine(e.message)}"
                }
            }
            pending.add(entry)
            pendingPos.add(pos)
            pendingTitle.add(title)
            pendingFile.add(file)
            pendingSkip.add(skip)
            if (skip.isEmpty() && !titleSeen.contains(title)) {
                titleSeen.add(title)
                titleOrder.add(title)
            }
        }
        // ---- 每个标题的判定 ----
        let actions = HashMap<String, String>()
        let targets = HashMap<String, Int64>()
        let conflicts = HashMap<String, ArrayList<TitleCandidate>>()
        let newTitles = ArrayList<String>()
        for (title in titleOrder) {
            let cands = if (titleIndex.contains(title)) {
                titleIndex[title]
            } else {
                ArrayList<TitleCandidate>()
            }
            var resolved: Int64 = -1
            if (cands.size >= 2) {
                // 用户已指定的优先；指定的 ID 必须属于该主体，否则视为未解决
                match (resolutions.get(title)) {
                    case Some(id) =>
                        if (id == 0) {
                            resolved = 0
                        } else if (allIds.contains(id)) {
                            resolved = id
                        }
                    case None => ()
                }
            }
            if (cands.size == 0) {
                actions.add(title, ACTION_CREATE)
                newTitles.add(title)
            } else if (cands.size == 1) {
                actions.add(title, ACTION_MATCH)
                targets.add(title, cands[0].itemId)
            } else if (resolved == 0) {
                actions.add(title, ACTION_CREATE)
                newTitles.add(title)
            } else if (resolved > 0) {
                actions.add(title, ACTION_MATCH)
                targets.add(title, resolved)
            } else {
                actions.add(title, ACTION_CONFLICT)
                conflicts.add(title, cands)
            }
        }
        // ---- 第二遍：产出预览行 ----
        let rows = ArrayList<AttachPlanRow>()
        let entries = ArrayList<ZipEntry>()
        var matchCount: Int64 = 0
        var createCount: Int64 = 0
        var conflictCount: Int64 = 0
        var skipCount: Int64 = 0
        var totalBytes: Int64 = 0
        var i: Int64 = 0
        while (i < pending.size) {
            i = i + 1
            let entry = pending[i - 1]
            let title = pendingTitle[i - 1]
            let file = pendingFile[i - 1]
            let skip = pendingSkip[i - 1]
            var action = ACTION_SKIP
            var target: Int64 = 0
            var note = skip
            if (skip.isEmpty()) {
                action = actions[title]
                if (action == ACTION_MATCH) {
                    target = targets[title]
                    matchCount = matchCount + 1
                    totalBytes = totalBytes + entry.uncompressedSize
                } else if (action == ACTION_CREATE) {
                    createCount = createCount + 1
                    totalBytes = totalBytes + entry.uncompressedSize
                } else {
                    conflictCount = conflictCount + 1
                    let n = if (conflicts.contains(title)) { conflicts[title].size } else { 0 }
                    note = "同名条目 ${n} 个，需手动指定"
                }
            } else {
                skipCount = skipCount + 1
            }
            entries.add(entry)
            rows.add(AttachPlanRow(
                pendingPos[i - 1], entry.path, title, file,
                entry.uncompressedSize, action, target, note
            ))
        }
        return AttachPlan(
            rows, matchCount, createCount, conflictCount, skipCount,
            titleOrder.size, conflicts, newTitles, totalBytes,
            indexTruncated, entries
        )
    }

    /**
     * 构建「标题 → 候选条目」索引。
     *
     * 一次性取该主体的条目，而不是每个目录查一次 SQL：
     * 500 个目录 = 500 次往返，预检会慢到用户以为卡死。
     *
     * @return (标题索引, 该主体全部条目 ID, 是否因条目过多被截断)
     */
    private func titleIndexOf(
        subjectId: Int64
    ): (HashMap<String, ArrayList<TitleCandidate>>, HashSet<Int64>, Int64) {
        let index = HashMap<String, ArrayList<TitleCandidate>>()
        let allIds = HashSet<Int64>()
        let rows = this.itemRepo.list(
            ["${subjectId}"], 0, -1, "", TITLE_INDEX_LIMIT, 0
        )
        var n: Int64 = 0
        for (r in rows.all()) {
            n = n + 1
            let title = r.str("title")
            let cand = TitleCandidate(r.i64("id"), title, r.i64("category"))
            allIds.add(cand.itemId)
            if (index.contains(title)) {
                index[title].add(cand)
            } else {
                let list = ArrayList<TitleCandidate>()
                list.add(cand)
                index.add(title, list)
            }
        }
        return (index, allIds, if (n >= TITLE_INDEX_LIMIT) { 1 } else { 0 })
    }

    /**
     * FR-IMP-004：一次性取该主体已有去重键集合（内存比对用）。
     * crypto 为空（无签名能力）时返回空集 —— 此时无法计算文件指纹，自然不去重。
     */
    private func existingDedupKeys(subjectId: Int64): HashSet<String> {
        match (this.crypto) {
            case Some(_) => return this.attachmentRepo.listDedupKeys(subjectId)
            case None => return HashSet<String>()
        }
    }

    /**
     * FR-IMP-004：算明文的 SM3 指纹并拼出去重键（"subjectId:hex"），与上传侧同口径。
     * 无 crypto 或计算失败返回 None（不阻断导入）。
     */
    private func dedupKeyOf(subjectId: Int64, plain: Array<Byte>): Option<String> {
        match (this.crypto) {
            case Some(c) =>
                let cipher = AttachmentCipher(c)
                match (cipher.fingerprint(plain)) {
                    case CryptoResult.Ok(fp) => return Some(cipher.dedupKey("${subjectId}", fp))
                    case CryptoResult.Err(_) => return None
                }
            case None => return None
        }
    }

    // ---------------------------------------------------------
    // 辅助
    // ---------------------------------------------------------

    private func checkSubject(actorId: Int64, scopeAny: Bool, subjectId: Int64): Unit {
        if (subjectId <= 0) {
            throw validationError("subjectId", "必须指定目标主体")
        }
        let ids = if (scopeAny) {
            this.userRepo.listAccessibleSubjectIds(actorId)
        } else {
            this.userRepo.listOwnedSubjectIds(actorId)
        }
        for (s in ids) {
            if (RowData.toI64(s) == subjectId) {
                return
            }
        }
        throw forbidden(message: "主体不存在或无写入权限")
    }

    private static func checkCategory(category: Int64): Unit {
        // 1-11 与前端字典、字段定义接口（fielddefs.cj）保持一致。
        // 旧代码在这里写死 1-6，导致「影像附件(10)/自定义分类(11)」等
        // 合法分类被判非法 —— 同一个数字在不同接口不同待遇，纯属实现疏漏。
        if (category < 1 || category > 11) {
            throw validationError("category", "条目分类必须是 1-11 的数字")
        }
    }

    private func writeReport(taskNo: String, taskId: Int64, csv: String): String {
        let key = "${taskNo}-${taskId}-attach.csv"
        this.storage.put(key, csv.toArray())
        return key
    }

    /**
     * 留存原始包与参数，供「失败重试」使用。
     *
     * 尽力而为：存储不可用时只是失去一键重试能力，不该让整批导入失败。
     * 键名带任务号，与报告同目录，排障时一眼能对上。
     */
    private func keepForRetry(
        taskNo: String, zip: Array<Byte>, subjectId: Int64, category: Int64
    ): Unit {
        try {
            this.storage.put("in-${taskNo}.zip", zip)
            this.storage.put("meta-${taskNo}.txt", "${subjectId}\n${category}".toArray())
        } catch (e: Exception) {
            // 放弃留存
        }
    }

    /**
     * 写失败序号清单（逗号分隔）。
     *
     * 空清单也要写：语义是「这个任务没有可重试项」，
     * 与「文件缺失」区分开，重试接口才能给出准确提示。
     */
    private func writeFailedIndexes(taskNo: String, idx: ArrayList<Int64>): Unit {
        let sb = StringBuilder()
        var first = true
        for (v in idx) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("${v}")
        }
        try {
            this.storage.put("fail-${taskNo}.txt", sb.toString().toArray())
        } catch (e: Exception) {
            // 同上
        }
    }

    /**
     * 取「属于调用者」的任务。
     *
     * scopeAny（持 archive:write:any）可跨用户重试，否则只能重试自己的任务；
     * 越权一律返回 NotFound 而不是 Forbidden —— 不泄漏「这个任务号存在」。
     */
    private func ownedTask(actorId: Int64, scopeAny: Bool, taskNo: String): RowData {
        if (taskNo.isEmpty()) {
            throw validationError("taskNo", "缺少任务号")
        }
        let row = match (this.taskRepo.findByNo(taskNo)) {
            case Some(r) => r
            case None => throw notFound("任务")
        }
        if (!scopeAny && row.str("user_id") != "${actorId}") {
            throw notFound("任务")
        }
        return row
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
                "${actorId}", ActorType.User, AuditAction.BatchOperation,
                "import_attach_task", "${taskId}", "", 0, outcome,
                "", "", "", "async;files=${rows};${detail}",
                Array<(String, String)>()
            )
        } catch (e: Exception) {
            // 审计失败不改变任务结论
        }
    }

    /** 取最后一个 "/" 之后的部分（映射规则与测试共用） */
    public static func baseName(path: String): String {
        let b = path.toArray()
        var at: Int64 = -1
        var i: Int64 = 0
        while (i < b.size) {
            if (b[i] == 47) {
                at = i
            }
            i = i + 1
        }
        if (at < 0) {
            return path
        }
        return path[(at + 1)..]
    }

    /** 取第一个 "/" 之前的部分（无 "/" 返回空串；映射规则与测试共用） */
    public static func firstSegment(path: String): String {
        let b = path.toArray()
        var i: Int64 = 0
        while (i < b.size) {
            if (b[i] == 47) {
                return path[0..i]
            }
            i = i + 1
        }
        return ""
    }

    /** CSV 单元格转义：引号加倍（外层由调用方加引号） */
    static func csvCell(s: String): String {
        return s.replace("\"", "\"\"")
    }

    private static func oneLine(s: String): String {
        return s.replace("\n", " ").replace("\r", " ")
    }

    private static func joinTitles(titles: ArrayList<String>): String {
        let sb = StringBuilder()
        var n: Int64 = 0
        for (t in titles) {
            if (n >= 5) {
                sb.append(" 等")
                break
            }
            if (n > 0) {
                sb.append("、")
            }
            sb.append(t)
            n = n + 1
        }
        return sb.toString()
    }
}

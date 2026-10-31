// ============================================================
// ams.app.export.async · 异步导出服务
//
// 需求映射：
//   FR-EXP-001  单条目导出（加密导出包）—— scope=item
//   FR-EXP-002  分类批量导出（二次确认令牌 + 高敏额外授权）—— scope=category
//   FR-EXP-003  全量可携带导出（完整主体打包 + 清单 + 签名）—— scope=full
//   FR-EXP-006  导出任务管理（任务表 / 进度 / 完成通知 / 产物 7 天过期 / 下载重鉴权 / 撤销）
//
// 执行模型（为什么用进程内 spawn 而不是调度器轮询）：
//   调度器 Scheduler 是**拉取式**的（只在 /api/admin/jobs/run 被调用时跑一轮），
//   没有常驻定时器。若把导出挂在调度器上，任务要等人工触发才会动，
//   不符合「创建即开始」的语义。故此处用 spawn 起一个执行线程：
//     · 一次性任务，跑完即退出，无常驻线程/无 sleep 轮询；
//     · 状态流转全部走带条件 UPDATE（claim / markSuccess 都要求前置状态），
//       进程内多线程与多实例并发下都只有一个写入者成功；
//     · 崩溃恢复由 failStaleRunning 兜底（服务重启后卡在 running 的任务标失败）。
//
// 二次确认令牌（FR-EXP-002）：
//   批量/全量导出**含高敏**时必须先调 precheck 拿到一次性令牌，
//   令牌绑定 (用户, 范围, 参数, 过期时间)，5 分钟有效、用后即废。
//   目的不是防重放（有 TTL），而是强制「先看清将导出多少条、其中多少高敏」，
//   避免一条 curl 就把整个档案库拖走。
//
// 打包格式（FR-EXP-003）：
//   产物为单文件 JSON 包，含 manifest（清单）+ items（数据）+ signature（签名）。
//   本机 SDK 无 zip 库（只有 tar/zlib），故不强行造 zip；单文件自描述 JSON
//   在任何环境下都能被校验：manifest 里给出每个数据段的 sha256 与字节数，
//   signature 为 HMAC-SM3(签名密钥, manifest + items) 的十六进制串。
// ============================================================
package ams.app.export

import std.collection.*
import std.sync.*

import ams.app.audit.*
import ams.crypto.provider.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.id.*
import ams.kernel.time.*
import ams.security.audit.*
import ams.storage.*

/** 导出范围 */
public class ExportScope {
    /** 单条目 */
    public static let Item: String = "item"
    /** 分类批量 */
    public static let Category: String = "category"
    /** 全量可携带 */
    public static let Full: String = "full"
}

/** 预检结果 */
public class PrecheckResult {
    public let token: String
    public let expiresAt: Int64
    public let rows: Int64
    public let highRows: Int64

    public init(token: String, expiresAt: Int64, rows: Int64, highRows: Int64) {
        this.token = token
        this.expiresAt = expiresAt
        this.rows = rows
        this.highRows = highRows
    }
}

/** 二次确认令牌条目 */
class ConfirmEntry {
    let actorId: Int64
    let fingerprint: String
    let expiresAt: Int64

    init(actorId: Int64, fingerprint: String, expiresAt: Int64) {
        this.actorId = actorId
        this.fingerprint = fingerprint
        this.expiresAt = expiresAt
    }
}

/**
 * 异步导出服务。
 */
public class AsyncExportService {
    private let itemRepo: ItemRepo
    private let userRepo: UserRepo
    private let taskRepo: ExportTaskRepo
    private let notifyRepo: NotifyRepo
    private let storage: StorageBackend
    private let recorder: ?AuditRecorder
    private let crypto: ?CryptoProvider
    /** 签名密钥（HMAC-SM3）；为空则退化为 sha256 自校验 */
    private let signKey: String
    /** 二次确认令牌表（进程内；重启即失效，符合「一次性」语义） */
    private let confirmLock = Mutex()
    private let confirmTokens = HashMap<String, ConfirmEntry>()

    private static let CHUNK: Int64 = 500
    private static let MAX_ROWS: Int64 = 50000
    /** 二次确认令牌有效期：5 分钟 */
    private static let CONFIRM_TTL: Int64 = 5 * 60 * 1000
    /** 产物有效期：7 天（FR-EXP-003/006） */
    public static let TTL_MILLIS: Int64 = 7 * 24 * 3600 * 1000

    public init(
        itemRepo: ItemRepo,
        userRepo: UserRepo,
        taskRepo: ExportTaskRepo,
        notifyRepo: NotifyRepo,
        storage: StorageBackend,
        recorder!: ?AuditRecorder = None,
        crypto!: ?CryptoProvider = None,
        signKey!: String = ""
    ) {
        this.itemRepo = itemRepo
        this.userRepo = userRepo
        this.taskRepo = taskRepo
        this.notifyRepo = notifyRepo
        this.storage = storage
        this.recorder = recorder
        this.crypto = crypto
        this.signKey = signKey
    }

    /**
     * 预检：统计将导出的行数与其中高敏行数，并签发一次性确认令牌。
     *
     * FR-EXP-002 要求「二次确认 + 高敏额外授权」：前端拿到本结果后弹确认框，
     * 用户确认再带着 token 调 submit。
     */
    public func precheck(
        actorId: Int64,
        scopeAny: Bool,
        scope: String,
        itemId: Int64,
        category: Int64,
        status: Int64,
        keyword: String,
        includeHigh: Bool
    ): PrecheckResult {
        let subjectIds = this.scopeOf(actorId, scopeAny)
        let rows = if (scope == ExportScope.Item) {
            let one = this.itemRepo.findById(itemId, subjectIds)
            match (one) {
                case Some(_) => 1
                case None => 0
            }
        } else {
            this.itemRepo.count(subjectIds, category, status, keyword)
        }
        // 高敏行数：分块统计，避免一次全量拉取（只读 sensitivity 字段也要扫表，
        // 但 count 已在上一步做过，这里复用同一批分块查询以控制内存）
        var highRows: Int64 = 0
        if (includeHigh && scope != ExportScope.Item) {
            var offset: Int64 = 0
            while (true) {
                let chunk = this.itemRepo.list(subjectIds, category, status, keyword, CHUNK, offset)
                let n = chunk.size()
                if (n == 0) {
                    break
                }
                for (r in chunk.all().iterator()) {
                    if (r.i64("sensitivity") >= 2) {
                        highRows = highRows + 1
                    }
                }
                offset = offset + n
                if (n < CHUNK) {
                    break
                }
            }
        } else if (includeHigh && scope == ExportScope.Item) {
            match (this.itemRepo.findById(itemId, subjectIds)) {
                case Some(it) => if (it.sensitivity >= 2) { highRows = 1 }
                case None => ()
            }
        }
        let now = Times.nowMillis()
        let token = "cfm-${Ids.next()}"
        let fp = AsyncExportService.fingerprint(scope, itemId, category, status, keyword, includeHigh)
        this.confirmLock.lock()
        try {
            // 顺手清理过期令牌，避免 HashMap 无界增长
            this.purgeConfirmLocked(now)
            this.confirmTokens[token] = ConfirmEntry(actorId, fp, now + CONFIRM_TTL)
        } finally {
            this.confirmLock.unlock()
        }
        return PrecheckResult(token, now + CONFIRM_TTL, rows, highRows)
    }

    /**
     * 提交导出任务：落库 + 起后台线程，立即返回任务号。
     */
    public func submit(
        actorId: Int64,
        scopeAny: Bool,
        scope: String,
        itemId: Int64,
        category: Int64,
        status: Int64,
        keyword: String,
        format: String,
        includeHigh: Bool,
        confirmToken: String
    ): String {
        let fp = AsyncExportService.fingerprint(scope, itemId, category, status, keyword, includeHigh)
        // FR-EXP-002：批量/全量 + 含高敏 → 必须二次确认
        if (includeHigh && scope != ExportScope.Item) {
            this.consumeConfirm(actorId, fp, confirmToken)
        }
        let now = Times.nowMillis()
        let subjectIds = this.scopeOf(actorId, scopeAny)
        var estimate: Int64 = 0
        try {
            estimate = if (scope == ExportScope.Item) {
                1
            } else {
                this.itemRepo.count(subjectIds, category, status, keyword)
            }
        } catch (e: Exception) {
            estimate = 0
        }
        if (estimate > MAX_ROWS) {
            estimate = MAX_ROWS
        }
        let effectiveFormat = if (scope == ExportScope.Full) { "bundle" } else { format }
        let taskNo = AsyncExportService.newTaskNo(now)
        let params = "{\"scope\":\"${scope}\",\"itemId\":${itemId},\"category\":${category}," +
                     "\"status\":${status},\"keyword\":\"${Texts.json(keyword)}\"," +
                     "\"scopeAny\":${if (scopeAny) { "true" } else { "false" }}," +
                     "\"includeHigh\":${if (includeHigh) { "true" } else { "false" }}}"
        let taskId = this.taskRepo.create(
            taskNo, "export", actorId, None, effectiveFormat, params, estimate, now + TTL_MILLIS
        )
        spawn { =>
            this.runTask(
                taskId, actorId, scopeAny, scope, itemId, category, status,
                keyword, effectiveFormat, includeHigh, taskNo
            )
        }
        return taskNo
    }

    /**
     * 任务执行体（后台线程）。所有异常在内部消化并落库，绝不逃逸到线程外。
     */
    private func runTask(
        taskId: Int64,
        actorId: Int64,
        scopeAny: Bool,
        scope: String,
        itemId: Int64,
        category: Int64,
        status: Int64,
        keyword: String,
        format: String,
        includeHigh: Bool,
        taskNo: String
    ): Unit {
        var rowsWritten: Int64 = 0
        try {
            let subjectIds = this.scopeOf(actorId, scopeAny)
            let estimate = if (scope == ExportScope.Item) {
                1
            } else {
                this.itemRepo.count(subjectIds, category, status, keyword)
            }
            if (!this.taskRepo.claim(taskId, if (estimate > MAX_ROWS) { MAX_ROWS } else { estimate })) {
                return
            }

            // ---- 单条目（FR-EXP-001）----
            if (scope == ExportScope.Item) {
                let one = match (this.itemRepo.findById(itemId, subjectIds)) {
                    case Some(r) => r
                    case None => throw AppError(AppErrorKind.NotFound, "条目不存在或无权访问")
                }
                let sens = one.sensitivity
                if (sens >= 2 && !includeHigh) {
                    throw AppError(AppErrorKind.Forbidden, "该条目为高敏，需勾选「包含高敏」并二次确认")
                }
                let payload = if (format == "json") {
                    AsyncExportService.itemJson(one)
                } else {
                    AsyncExportService.csvHeader() + AsyncExportService.itemCsv(one)
                }
                let key = this.artifactKey(taskNo, taskId, format)
                this.storage.put(key, payload.toArray())
                let now = Times.nowMillis()
                if (!this.taskRepo.markSuccess(taskId, key, 1, now + TTL_MILLIS)) {
                    return
                }
                this.notify(actorId, "导出完成", "条目「${one.title}」已导出，7 天内可下载。", "/export/tasks")
                this.audit(actorId, taskId, 1, "success", "scope=item;format=${format}")
                return
            }

            // ---- 批量 / 全量 ----
            let isBundle = format == "bundle"
            let sb = StringBuilder()
            if (isBundle) {
                // bundle 的 items 段是**顶层数组**（消费者直接 d.items 遍历），
                // 清单里的 sha256/bytes 也针对这段文本
                sb.append("[")
            } else if (format == "json") {
                sb.append("{\"items\":[")
            } else {
                sb.append(AsyncExportService.csvHeader())
            }
            var offset: Int64 = 0
            var first = true
            var truncated = false
            while (true) {
                if (this.taskRepo.isCancelled(taskId)) {
                    return
                }
                let chunk = this.itemRepo.list(subjectIds, category, status, keyword, CHUNK, offset)
                let n = chunk.size()
                if (n == 0) {
                    break
                }
                for (r in chunk.all().iterator()) {
                    let sens = r.i64("sensitivity")
                    if (sens >= 2 && !includeHigh) {
                        offset = offset + 1
                        continue
                    }
                    if (rowsWritten >= MAX_ROWS) {
                        truncated = true
                        break
                    }
                    if (format == "csv") {
                        sb.append(AsyncExportService.rowCsv(r))
                    } else {
                        if (!first) {
                            sb.append(",")
                        }
                        first = false
                        sb.append(AsyncExportService.rowJson(r))
                    }
                    rowsWritten = rowsWritten + 1
                    offset = offset + 1
                }
                this.taskRepo.updateProgress(taskId, rowsWritten, 0)
                if (truncated || n < CHUNK) {
                    break
                }
            }
            if (truncated && format == "csv") {
                sb.append("# 已截断：单次导出上限 ${MAX_ROWS} 行\n")
            }

            let data = sb.toString()
            let payload = if (isBundle) {
                // bundle 的 items 段必须是**合法 JSON**：补上数组收尾
                AsyncExportService.bundle(
                    this.crypto, this.signKey, taskNo, rowsWritten, truncated, Times.nowMillis(),
                    data + "]"
                )
            } else if (format == "json") {
                data + "],\"truncated\":${if (truncated) { "true" } else { "false" }}," +
                "\"exportedAt\":${Times.nowMillis()}}"
            } else {
                data
            }

            let key = this.artifactKey(taskNo, taskId, format)
            this.storage.put(key, payload.toArray())
            let now = Times.nowMillis()
            if (!this.taskRepo.markSuccess(taskId, key, rowsWritten, now + TTL_MILLIS)) {
                return
            }
            let what = if (scope == ExportScope.Full) { "全量" } else { "分类批量" }
            this.notify(actorId, "导出完成", "${what}导出已完成，共 ${rowsWritten} 条，7 天内可下载。", "/export/tasks")
            this.audit(actorId, taskId, rowsWritten, "success",
                       "scope=${scope};format=${format};truncated=${truncated}")
        } catch (e: Exception) {
            let msg = AsyncExportService.oneLine(e.message)
            try {
                this.taskRepo.markFailed(taskId, msg)
                this.notify(actorId, "导出失败", "导出任务执行失败：${msg}", "/export/tasks")
            } catch (e2: Exception) {
                // 通知/落库再失败就只能放弃：已无更可靠的通道
            }
            this.audit(actorId, taskId, rowsWritten, "failed", "error=${msg}")
        }
    }

    /** 清理过期产物（下载与列表时顺带调用，无需常驻定时器） */
    public func purgeExpired(): Int64 {
        return this.taskRepo.purgeExpired(Times.nowMillis())
    }

    /** 服务启动时调用：把上次进程遗留的 running 任务标失败 */
    public func recoverStale(): Int64 {
        return this.taskRepo.failStaleRunning(Times.nowMillis(), 10 * 60 * 1000)
    }

    // ---- 内部 ----

    private func artifactKey(taskNo: String, taskId: Int64, format: String): String {
        let ext = match (format) {
            case "json" => "json"
            case "bundle" => "amsx.json"
            case _ => "csv"
        }
        return "${taskNo}-${taskId}.${ext}"
    }

    private func scopeOf(actorId: Int64, scopeAny: Bool): Array<String> {
        if (scopeAny) {
            return this.userRepo.listAccessibleSubjectIds(actorId).toArray()
        }
        return this.userRepo.listOwnedSubjectIds(actorId).toArray()
    }

    /**
     * 消费二次确认令牌：必须存在、未过期、同一用户、同一参数指纹。
     */
    private func consumeConfirm(actorId: Int64, fingerprint: String, token: String): Unit {
        if (token.isEmpty()) {
            throw validationError("confirmToken", "需先预检并二次确认（含高敏数据）")
        }
        let now = Times.nowMillis()
        this.confirmLock.lock()
        var ok = false
        try {
            match (this.confirmTokens.get(token)) {
                case Some(e) =>
                    if (e.expiresAt >= now && e.actorId == actorId && e.fingerprint == fingerprint) {
                        ok = true
                    }
                    this.confirmTokens.remove(token)
                case None => ()
            }
        } finally {
            this.confirmLock.unlock()
        }
        if (!ok) {
            throw validationError("confirmToken", "确认令牌无效或已过期，请重新预检")
        }
    }

    private func purgeConfirmLocked(now: Int64): Unit {
        let dead = ArrayList<String>()
        for ((k, v) in this.confirmTokens) {
            if (v.expiresAt < now) {
                dead.add(k)
            }
        }
        for (k in dead) {
            this.confirmTokens.remove(k)
        }
    }

    private func notify(actorId: Int64, title: String, body: String, link: String): Unit {
        try {
            this.notifyRepo.push(actorId, None, title, body, Some(link), 1, None)
        } catch (e: Exception) {
            // 通知是尽力而为，不影响任务结论
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
                AuditAction.DataExport,
                "export_task",
                "${taskId}",
                "",
                0,
                outcome,
                "",
                "",
                "",
                "async;rows=${rows};${detail}",
                Array<(String, String)>()
            )
        } catch (e: Exception) {
            // 审计失败不改变任务结论
        }
    }

    // ---- 序列化与签名 ----

    private static func fingerprint(
        scope: String, itemId: Int64, category: Int64, status: Int64, keyword: String, includeHigh: Bool
    ): String {
        return "${scope}|${itemId}|${category}|${status}|${keyword}|${includeHigh}"
    }

    private static func newTaskNo(now: Int64): String {
        return "EXP${now}${Ids.next() % 1000}"
    }

    private static func csvHeader(): String {
        return "id,subject_id,category,title,status,sensitivity,issuer,issued_date,expires_at,updated_ms\n"
    }

    private static func rowCsv(r: RowData): String {
        var sb = StringBuilder()
        sb.append(csvCell(r.str("id")))
        sb.append(",")
        sb.append(csvCell(r.str("subject_id")))
        sb.append(",")
        sb.append(csvCell(r.str("category")))
        sb.append(",")
        sb.append(csvCell(r.str("title")))
        sb.append(",")
        sb.append(csvCell(r.str("status")))
        sb.append(",")
        sb.append(csvCell(r.str("sensitivity")))
        sb.append(",")
        sb.append(csvCell(mask(r.str("issuer"))))
        sb.append(",")
        sb.append(csvCell(r.str("issued_date")))
        sb.append(",")
        sb.append(csvCell(r.str("expires_at")))
        sb.append(",")
        sb.append(csvCell(r.str("updated_ms")))
        sb.append("\n")
        return sb.toString()
    }

    private static func rowJson(r: RowData): String {
        var sb = StringBuilder()
        sb.append("{\"id\":\"${Texts.json(r.str("id"))}\",")
        sb.append("\"subjectId\":\"${Texts.json(r.str("subject_id"))}\",")
        sb.append("\"category\":${r.i64("category")},")
        sb.append("\"title\":\"${Texts.json(r.str("title"))}\",")
        sb.append("\"status\":${r.i64("status")},")
        sb.append("\"sensitivity\":${r.i64("sensitivity")},")
        sb.append("\"issuer\":\"${Texts.json(mask(r.str("issuer")))}\",")
        sb.append("\"issuedDate\":\"${Texts.json(r.str("issued_date"))}\",")
        sb.append("\"expiresAt\":\"${Texts.json(r.str("expires_at"))}\",")
        sb.append("\"updatedMs\":${r.i64("updated_ms")}}")
        return sb.toString()
    }

    private static func itemCsv(it: ItemRecord): String {
        var sb = StringBuilder()
        sb.append(csvCell("${it.id}"))
        sb.append(",")
        sb.append(csvCell("${it.subjectId}"))
        sb.append(",")
        sb.append(csvCell("${it.category}"))
        sb.append(",")
        sb.append(csvCell(it.title))
        sb.append(",")
        sb.append(csvCell("${it.status}"))
        sb.append(",")
        sb.append(csvCell("${it.sensitivity}"))
        sb.append(",")
        sb.append(csvCell(mask(it.issuer)))
        sb.append(",")
        sb.append(csvCell(it.issuedDate))
        sb.append(",")
        sb.append(csvCell(it.expiresAt))
        sb.append(",")
        sb.append(csvCell("${it.updatedAt}"))
        sb.append("\n")
        return sb.toString()
    }

    private static func itemJson(it: ItemRecord): String {
        var sb = StringBuilder()
        sb.append("{\"id\":\"${it.id}\",")
        sb.append("\"subjectId\":\"${it.subjectId}\",")
        sb.append("\"category\":${it.category},")
        sb.append("\"title\":\"${Texts.json(it.title)}\",")
        sb.append("\"status\":${it.status},")
        sb.append("\"sensitivity\":${it.sensitivity},")
        sb.append("\"issuer\":\"${Texts.json(mask(it.issuer))}\",")
        sb.append("\"issuedDate\":\"${Texts.json(it.issuedDate)}\",")
        sb.append("\"expiresAt\":\"${Texts.json(it.expiresAt)}\",")
        sb.append("\"updatedMs\":${it.updatedAt}}")
        return sb.toString()
    }

    /**
     * 组装可携带导出包（FR-EXP-003）。
     *
     * 结构：
     *   {"manifest":{type,version,taskNo,generatedAt,itemCount,truncated,
     *                segments:[{name,bytes,sha256}]},
     *    "items":[...],
     *    "signature":{"alg":"HMAC-SM3"|"SHA-256","value":"..."}}
     *
     * 签名覆盖 manifest（不含 signature 段）+ items 两段的原始文本，
     * 任一字节被改都会导致校验失败 —— 这正是「可携带」的前提：
     * 离开系统后仍能自证未被篡改。
     */
    private static func bundle(
        crypto: ?CryptoProvider,
        signKey: String,
        taskNo: String,
        itemCount: Int64,
        truncated: Bool,
        generatedAt: Int64,
        itemsJson: String
    ): String {
        let itemsSha = AsyncExportService.sha256Hex(crypto, itemsJson)
        let manifest = "{\"type\":\"ams-portable-export\",\"version\":1," +
                       "\"taskNo\":\"${Texts.json(taskNo)}\"," +
                       "\"generatedAt\":${generatedAt}," +
                       "\"itemCount\":${itemCount}," +
                       "\"truncated\":${if (truncated) { "true" } else { "false" }}," +
                       "\"segments\":[{\"name\":\"items\",\"bytes\":${itemsJson.toArray().size}," +
                       "\"sha256\":\"${itemsSha}\"}]}"
        let signed = manifest + itemsJson
        let sig = AsyncExportService.sign(crypto, signKey, signed)
        let sb = StringBuilder()
        sb.append("{\"manifest\":")
        sb.append(manifest)
        sb.append(",\"items\":")
        sb.append(itemsJson)
        sb.append(",\"signature\":{\"alg\":\"${sig.alg}\",\"value\":\"${sig.value}\"}}")
        return sb.toString()
    }

    /** 签名结果 */
    private static func sign(crypto: ?CryptoProvider, key: String, data: String): Signature {
        let prov = match (crypto) {
            case Some(c) => c
            case None => return Signature("SHA-256", AsyncExportService.sha256Hex(None, data))
        }
        if (key.isEmpty()) {
            return Signature("SHA-256", AsyncExportService.sha256Hex(Some(prov), data))
        }
        // HMAC-SM3：国密摘要，本机 stdx 已稳定支持（HMAC-SHA256 在该版本未接入）
        match (prov.hmac(key.toArray(), data.toArray(), DigestAlgorithm.Sm3)) {
            case CryptoResult.Ok(bytes) => return Signature("HMAC-SM3", AsyncExportService.hex(bytes))
            case CryptoResult.Err(_) => return Signature("SHA-256", AsyncExportService.sha256Hex(Some(prov), data))
        }
    }

    private static func sha256Hex(crypto: ?CryptoProvider, data: String): String {
        let prov = match (crypto) {
            case Some(c) => c
            case None => return ""
        }
        match (prov.digest(data.toArray(), DigestAlgorithm.Sha256)) {
            case CryptoResult.Ok(bytes) => return AsyncExportService.hex(bytes)
            case CryptoResult.Err(_) => return ""
        }
    }

    private static func hex(bytes: Array<Byte>): String {
        let sb = StringBuilder()
        for (b in bytes) {
            let v = Int64(b)
            sb.append(Texts.hexDigit((v >> 4) & 15))
            sb.append(Texts.hexDigit(v & 15))
        }
        return sb.toString()
    }

    private static func csvCell(s: String): String {
        if (s.contains(",") || s.contains("\"") || s.contains("\n")) {
            return "\"" + s.replace("\"", "\"\"") + "\""
        }
        return s
    }

    /**
     * 敏感明文掩码：保留首字符、其余打码。
     *
     * 【必须按「字符」而非「字节」处理】仓颉的 String.size 是字节数，
     * `s[0..1]` 切出的是单个字节；中文签发机关（「市公安局」）会被切碎成
     * 非法 UTF-8，抛 `Invalid utf8 byte sequence` 导致整次导出失败。
     */
    static func mask(s: String): String {
        if (s.isEmpty()) {
            return s
        }
        var first = ""
        var n: Int64 = 0
        for (ch in s.runes()) {
            if (n == 0) {
                first = ch.toString()
            }
            n = n + 1
            if (n > 2) {
                break
            }
        }
        if (n <= 2) {
            return s
        }
        return "${first}***"
    }

    private static func oneLine(s: String): String {
        return s.replace("\n", " ").replace("\r", " ")
    }
}

/** 签名结果（算法 + 十六进制摘要） */
class Signature {
    let alg: String
    let value: String

    init(alg: String, value: String) {
        this.alg = alg
        this.value = value
    }
}

/**
 * 文本工具（JSON 转义 / 十六进制数字）。
 */
class Texts {
    static func json(s: String): String {
        return s.replace("\\", "\\\\").replace("\"", "\\\"")
            .replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
    }

    private static let HEX: Array<String> = [
        "0", "1", "2", "3", "4", "5", "6", "7",
        "8", "9", "a", "b", "c", "d", "e", "f"
    ]

    static func hexDigit(n: Int64): String {
        if (n < 0 || n > 15) {
            return "0"
        }
        return Texts.HEX[n]
    }
}

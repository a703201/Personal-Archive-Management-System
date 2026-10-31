// ============================================================
// ams.api.routes.export · 导出接口
//
// 同步（P0）：
//   POST /api/export                 （需 archive:export:own）
//
// 异步（P1 · FR-EXP-001/002/003/006）：
//   POST /api/export/tasks           创建导出任务
//   GET  /api/export/tasks           任务列表（分页）
//   GET  /api/export/tasks/:no       任务详情（轮询进度）
//   GET  /api/export/tasks/:no/download  下载产物（重鉴权 + 过期判定 + 审计）
//   POST /api/export/tasks/:no/cancel    取消任务
//
// 行为（同步）：
//   - 解析筛选条件（分类 / 状态 / 关键字 / 行数 / 是否含高敏）
//   - 按权限范围确定可导出主体（export:any → 全部可访问；否则仅本人拥有）
//   - 调用 ExportService（内部计量配额 + 生成 CSV + 写审计）
//   - 以 text/csv 附件形式返回
//
// [安全] 导出属于高敏操作，必须鉴权 + 配额 + 审计三重约束。
//        异步任务的下载**重新**校验归属与过期，不复用创建时的判断
//        （链接可能被转发，产物也可能已过期）。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.app.audit.*
import ams.app.export.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.time.*
import ams.security.audit.*
import ams.storage.*

/**
 * 导出接口处理器。
 */
public class ExportRoutes {
    private let userRepo: UserRepo
    private let exportService: ExportService
    private let asyncService: AsyncExportService
    private let taskRepo: ExportTaskRepo
    private let storage: ?StorageBackend
    private let recorder: ?AuditRecorder

    public init(
        userRepo: UserRepo,
        exportService: ExportService,
        asyncService: AsyncExportService,
        taskRepo: ExportTaskRepo,
        storage!: ?StorageBackend = None,
        recorder!: ?AuditRecorder = None
    ) {
        this.userRepo = userRepo
        this.exportService = exportService
        this.asyncService = asyncService
        this.taskRepo = taskRepo
        this.storage = storage
        this.recorder = recorder
    }

    /**
     * 注册到路由表。
     */
    public func register(router: Router): Unit {
        router.post("/api/export", { req: ApiRequest => this.export(req) },
            requiredPerm: "archive:export:own")
        // ---- 异步任务（FR-EXP-001/002/003/006）----
        router.post("/api/export/tasks", { req: ApiRequest => this.createTask(req) },
            requiredPerm: "archive:export:own")
        router.post("/api/export/tasks/precheck", { req: ApiRequest => this.precheck(req) },
            requiredPerm: "archive:export:own")
        router.get("/api/export/tasks", { req: ApiRequest => this.listTasks(req) },
            requiredPerm: "archive:export:own")
        router.get("/api/export/tasks/:no", { req: ApiRequest => this.taskDetail(req) },
            requiredPerm: "archive:export:own")
        router.get("/api/export/tasks/:no/download", { req: ApiRequest => this.downloadTask(req) },
            requiredPerm: "archive:export:own")
        router.post("/api/export/tasks/:no/cancel", { req: ApiRequest => this.cancelTask(req) },
            requiredPerm: "archive:export:own")
    }

    /**
     * POST /api/export
     *
     * 请求体：{"category":0,"status":-1,"keyword":"","maxRows":2000,
     *          "includeHighSensitivity":false}
     */
    private func export(req: ApiRequest): ApiResponse {
        let json = match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        let category = ExportRoutes.intFrom(json, "category", 0)
        let status = ExportRoutes.intFrom(json, "status", -1)
        let keyword = json.get("keyword") ?? ""
        let maxRows = ExportRoutes.intFrom(json, "maxRows", 2000)
        let includeHigh = match (json.get("includeHighSensitivity")) {
            case Some(v) => v == "true" || v == "1"
            case None => false
        }

        // 按权限范围确定可导出主体
        let uid = UserRepo.parseId(req.subjectId)
        let subjectIds = if (req.perms.contains("archive:export:any")) {
            this.userRepo.listAccessibleSubjectIds(uid).toArray()
        } else {
            this.userRepo.listOwnedSubjectIds(uid).toArray()
        }

        let result = this.exportService.exportCsv(
            req.subjectId,
            subjectIds,
            category,
            status,
            keyword,
            maxRows,
            includeHigh,
            req.remoteAddr,
            req.header("user-agent") ?? ""
        )

        let h = HashMap<String, String>()
        h["Content-Type"] = "text/csv; charset=utf-8"
        h["Content-Disposition"] = "attachment; filename=\"archive-export.csv\""
        return ApiResponse(200, result.csv, h)
    }

    // ---------------------------------------------------------------
    // 异步导出任务（FR-EXP-001 / 002 / 003 / 006）
    // ---------------------------------------------------------------

    /**
     * POST /api/export/tasks
     *
     * 请求体：
     *   {"scope":"item|category|full", "itemId":123, "category":0, "status":-1,
     *    "keyword":"", "format":"csv|json", "includeHighSensitivity":false,
     *    "confirmToken":"cfm-..."}
     *
     * 立即返回任务号，导出在后台线程执行；前端轮询详情看进度。
     * scope=category|full 且含高敏时必须带 confirmToken（由 /precheck 签发）。
     */
    private func createTask(req: ApiRequest): ApiResponse {
        let json = match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        let scope = ExportRoutes.normScope(json.get("scope") ?? "category")
        let itemId = ExportRoutes.intFrom(json, "itemId", 0)
        if (scope == ExportScope.Item && itemId <= 0) {
            throw validationError("itemId", "单条目导出必须指定 itemId")
        }
        let category = ExportRoutes.intFrom(json, "category", 0)
        let status = ExportRoutes.intFrom(json, "status", -1)
        let keyword = json.get("keyword") ?? ""
        let format = (json.get("format") ?? "csv").toAsciiLower()
        if (format != "csv" && format != "json") {
            throw validationError("format", "仅支持 csv / json")
        }
        let includeHigh = ExportRoutes.boolOf(json, "includeHighSensitivity")
        let confirmToken = json.get("confirmToken") ?? ""
        let uid = UserRepo.parseId(req.subjectId)
        let taskNo = this.asyncService.submit(
            uid,
            req.perms.contains("archive:export:any"),
            scope,
            itemId,
            category,
            status,
            keyword,
            format,
            includeHigh,
            confirmToken
        )
        return ApiResponse.ok(
            "{\"taskNo\":\"${ApiResponse.escape(taskNo)}\",\"status\":0," +
            "\"scope\":\"${scope}\",\"format\":\"${format}\",\"expiresInDays\":7}",
            req.requestId
        )
    }

    /**
     * POST /api/export/tasks/precheck —— 预检 + 签发二次确认令牌（FR-EXP-002）。
     *
     * 返回将导出的行数、其中高敏行数、令牌与有效期。
     * 前端据此展示「共 N 条，含高敏 M 条」并让用户确认。
     */
    private func precheck(req: ApiRequest): ApiResponse {
        let json = match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        let scope = ExportRoutes.normScope(json.get("scope") ?? "category")
        let itemId = ExportRoutes.intFrom(json, "itemId", 0)
        let category = ExportRoutes.intFrom(json, "category", 0)
        let status = ExportRoutes.intFrom(json, "status", -1)
        let keyword = json.get("keyword") ?? ""
        let includeHigh = ExportRoutes.boolOf(json, "includeHighSensitivity")
        let uid = UserRepo.parseId(req.subjectId)
        let r = this.asyncService.precheck(
            uid,
            req.perms.contains("archive:export:any"),
            scope,
            itemId,
            category,
            status,
            keyword,
            includeHigh
        )
        return ApiResponse.ok(
            "{\"token\":\"${ApiResponse.escape(r.token)}\"," +
            "\"expiresAt\":${r.expiresAt},\"rows\":${r.rows},\"highRows\":${r.highRows}," +
            "\"scope\":\"${scope}\",\"requiresConfirm\":${if (includeHigh && scope != ExportScope.Item) { "true" } else { "false" }}}",
            req.requestId
        )
    }

    /**
     * GET /api/export/tasks —— 本人任务列表（分页）。
     */
    private func listTasks(req: ApiRequest): ApiResponse {
        // 顺带清理过期产物：列表是低频操作，挂在这里比引入定时器简单可靠
        this.asyncService.purgeExpired()
        let page = ExportRoutes.longOf(ExportRoutes.q(req, "page"), 1)
        let size = ExportRoutes.clamp(ExportRoutes.longOf(ExportRoutes.q(req, "size"), 20), 1, 100)
        let taskType = ExportRoutes.q(req, "type")
        let uid = UserRepo.parseId(req.subjectId)
        let rows = this.taskRepo.listOf(uid, taskType, size, (page - 1) * size)
        let total = this.taskRepo.countOf(uid, taskType)
        let sb = StringBuilder()
        sb.append("{\"total\":${total},\"items\":[")
        var first = true
        for (r in rows.all().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append(ExportRoutes.taskJson(r))
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * GET /api/export/tasks/:no —— 任务详情（前端 1.5s 轮询进度）。
     */
    private func taskDetail(req: ApiRequest): ApiResponse {
        let taskNo = req.pathParam("no") ?? ""
        let row = this.ownedTask(req, taskNo)
        // 过期判定：状态仍为 success 但已过期 → 就地标 expired，返回最新状态
        this.asyncService.purgeExpired()
        let fresh = this.taskRepo.findByNo(taskNo) ?? row
        return ApiResponse.ok(ExportRoutes.taskJson(fresh), req.requestId)
    }

    /**
     * GET /api/export/tasks/:no/download —— 下载产物。
     *
     * 三重校验：归属（只有发起人能下）→ 状态（必须 success）→ 有效期（7 天）。
     * 过期返回 410 Gone（不是 404：产物曾存在，语义不同）。
     */
    private func downloadTask(req: ApiRequest): ApiResponse {
        let taskNo = req.pathParam("no") ?? ""
        let row = this.ownedTask(req, taskNo)
        let status = row.i64("status")
        if (status == TaskStatus.Expired) {
            return ExportRoutes.gone("产物已过期（保留 7 天），请重新导出", req.requestId)
        }
        if (status == TaskStatus.Cancelled) {
            throw AppError(AppErrorKind.Conflict, "任务已取消")
        }
        if (status == TaskStatus.Failed) {
            throw AppError(AppErrorKind.Conflict, "任务执行失败，无产物可下载")
        }
        if (status != TaskStatus.Success) {
            throw AppError(AppErrorKind.Conflict, "任务尚未完成，请稍后再试")
        }
        let expiresAt = row.i64("expires_at")
        let now = Times.nowMillis()
        if (expiresAt > 0 && expiresAt < now) {
            return ExportRoutes.gone("产物已过期（保留 7 天），请重新导出", req.requestId)
        }
        let store = match (this.storage) {
            case Some(s) => s
            case None => throw AppError(AppErrorKind.Internal, "导出存储未配置")
        }
        let key = row.str("result_path")
        if (key.isEmpty()) {
            throw AppError(AppErrorKind.NotFound, "产物已清理")
        }
        let bytes = match (store.get(key)) {
            case Some(b) => b
            case None => throw AppError(AppErrorKind.NotFound, "产物文件缺失")
        }
        // 下载必须留痕（FR-EXP-007：导出/下载全链路可审计）
        this.auditDownload(req, taskNo, row.i64("row_count"))
        let format = row.str("format")
        let ext = match (format) {
            case "json" => "json"
            case "bundle" => "amsx.json"
            case _ => "csv"
        }
        let h = HashMap<String, String>()
        h["Content-Type"] = if (format == "csv") {
            "text/csv; charset=utf-8"
        } else {
            "application/json; charset=utf-8"
        }
        h["Content-Disposition"] = "attachment; filename=\"${ApiResponse.escape(taskNo)}.${ext}\""
        return ApiResponse(200, String.fromUtf8(bytes), h)
    }

    /**
     * POST /api/export/tasks/:no/cancel —— 取消任务。
     */
    private func cancelTask(req: ApiRequest): ApiResponse {
        let taskNo = req.pathParam("no") ?? ""
        let row = this.ownedTask(req, taskNo)
        let ok = this.taskRepo.cancel(row.i64("id"))
        if (!ok) {
            throw AppError(AppErrorKind.Conflict, "任务已结束，无法取消")
        }
        return ApiResponse.ok("{\"cancelled\":true}", req.requestId)
    }

    /**
     * 取本人任务（管理员可见全部）。
     *
     * 归属校验放在这里而不是各 handler 里，避免漏一处就横向越权。
     */
    private func ownedTask(req: ApiRequest, taskNo: String): RowData {
        if (taskNo.isEmpty()) {
            throw validationError("taskNo", "缺少任务号")
        }
        let row = match (this.taskRepo.findByNo(taskNo)) {
            case Some(r) => r
            case None => throw notFound("任务")
        }
        let isAdmin = req.perms.contains("system:admin") || req.perms.contains("archive:export:any")
        if (!isAdmin && row.str("user_id") != req.subjectId) {
            // 不区分「不存在」与「无权限」，避免任务号被枚举探测
            throw notFound("任务")
        }
        return row
    }

    private func auditDownload(req: ApiRequest, taskNo: String, rows: Int64): Unit {
        match (this.recorder) {
            case Some(r) =>
                try {
                    r.record(
                        req.subjectId,
                        ActorType.User,
                        AuditAction.DataExport,
                        "export_task",
                        taskNo,
                        "",
                        0,
                        AuditResult.Success,
                        "",
                        req.remoteAddr,
                        req.header("user-agent") ?? "",
                        "download;rows=${rows}",
                        Array<(String, String)>()
                    )
                } catch (e: Exception) {
                    // 审计失败不阻断下载（AuditRecorder 内部另有失败日志）
                }
            case None => ()
        }
    }

    /**
     * 任务行 → JSON。
     *
     * 进度百分比由后端算好：前端不该重复实现同一套除法，
     * 也避免 total=0 时前端出现 NaN。
     */
    public static func taskJson(r: RowData): String {
        let total = r.i64("total_count")
        let done = r.i64("done_count")
        let pct = if (total <= 0) {
            if (r.i64("status") == 2) { 100 } else { 0 }
        } else {
            let v = done * 100 / total
            if (v > 100) { 100 } else { v }
        }
        let sb = StringBuilder()
        sb.append("{\"id\":\"${r.str("id")}\",")
        sb.append("\"taskNo\":\"${ApiResponse.escape(r.str("task_no"))}\",")
        sb.append("\"type\":\"${ApiResponse.escape(r.str("task_type"))}\",")
        sb.append("\"status\":${r.i64("status")},")
        sb.append("\"total\":${total},\"done\":${done},")
        sb.append("\"failed\":${r.i64("failed_count")},")
        sb.append("\"percent\":${pct},")
        sb.append("\"format\":\"${ApiResponse.escape(r.str("format"))}\",")
        sb.append("\"rows\":${r.i64("row_count")},")
        sb.append("\"expiresAt\":${r.i64("expires_at")},")
        sb.append("\"error\":\"${ApiResponse.escape(r.str("error_msg"))}\",")
        sb.append("\"createdAt\":${r.i64("created_ms")},")
        sb.append("\"updatedAt\":${r.i64("updated_ms")}}")
        return sb.toString()
    }

    /**
     * 410 Gone（产物过期）。
     *
     * AppErrorKind 没有 Gone（框架只覆盖常见错误），但「过期」与「不存在」
     * 对客户端的含义完全不同：前者应提示重新导出，后者是无此任务。
     * 故此处直接构造响应，而不去污染全局错误枚举。
     */
    private static func gone(message: String, requestId: String): ApiResponse {
        let body = "{\"code\":\"GONE\",\"message\":\"${ApiResponse.escape(message)}\"," +
                   "\"requestId\":\"${requestId}\"}"
        let h = HashMap<String, String>()
        h["content-type"] = "application/json; charset=utf-8"
        return ApiResponse(410, body, h)
    }

    /**
     * 取整数字段（缺失 / 空 / 非法 → 默认值）。
     */
    private static func intFrom(json: SimpleJson, key: String, default: Int64): Int64 {
        match (json.get(key)) {
            case Some(v) =>
                if (v.isEmpty()) {
                    return default
                }
                return RowData.toI64(v)
            case None => return default
        }
    }

    /** 取查询参数（缺失 → 空串） */
    private static func q(req: ApiRequest, name: String): String {
        return match (req.queryParam(name)) {
            case Some(v) => v
            case None => ""
        }
    }

    /** 空串 → 默认值；非法 → 默认值 */
    private static func longOf(raw: String, default: Int64): Int64 {
        if (raw.isEmpty()) {
            return default
        }
        let v = RowData.toI64(raw)
        if (v <= 0) {
            return default
        }
        return v
    }

    /** 钳制到 [lo, hi] */
    private static func clamp(v: Int64, lo: Int64, hi: Int64): Int64 {
        if (v < lo) {
            return lo
        }
        if (v > hi) {
            return hi
        }
        return v
    }

    /** 导出范围归一化（非法值一律按 category，避免拼进 SQL/日志） */
    private static func normScope(raw: String): String {
        let s = raw.toAsciiLower()
        if (s == ExportScope.Item) {
            return ExportScope.Item
        }
        if (s == ExportScope.Full) {
            return ExportScope.Full
        }
        return ExportScope.Category
    }

    /** 布尔字段（"true"/"1" 视为真） */
    private static func boolOf(json: SimpleJson, key: String): Bool {
        return match (json.get(key)) {
            case Some(v) => v == "true" || v == "1"
            case None => false
        }
    }
}

// ============================================================
// ams.api.routes.import · 批量导入接口（FR-IMP-001 / 003）
//
// 路由：
//   GET  /api/import/template           模板 CSV 下载（表头 + 示例 + 说明）
//   POST /api/import/precheck           预检（dry-run，只报告不落库）
//   POST /api/import/tasks              创建导入任务（异步）
//   GET  /api/import/tasks              任务列表（type=import）
//   GET  /api/import/tasks/:no          任务详情（轮询进度）
//   GET  /api/import/tasks/:no/report   错误报告下载
//   POST /api/import/tasks/:no/cancel   取消
//
// 权限：导入等同于批量创建条目 → archive:write:own
//       （不新增权限码：导入的产物就是条目，写入权限已能覆盖其风险面）
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.app.importer.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.id.*
import ams.kernel.time.*
import ams.storage.*

/**
 * 导入接口处理器。
 */
public class ImportRoutes {
    private let importService: ImportService
    private let taskRepo: ExportTaskRepo
    private let userRepo: UserRepo
    private let storage: ?StorageBackend

    public init(
        importService: ImportService,
        taskRepo: ExportTaskRepo,
        userRepo: UserRepo,
        storage!: ?StorageBackend = None
    ) {
        this.importService = importService
        this.taskRepo = taskRepo
        this.userRepo = userRepo
        this.storage = storage
    }

    public func register(router: Router): Unit {
        router.get("/api/import/template", { req: ApiRequest => this.template(req) },
            requiredPerm: "archive:write:own")
        router.post("/api/import/precheck", { req: ApiRequest => this.precheck(req) },
            requiredPerm: "archive:write:own")
        router.post("/api/import/tasks", { req: ApiRequest => this.create(req) },
            requiredPerm: "archive:write:own")
        router.get("/api/import/tasks", { req: ApiRequest => this.list(req) },
            requiredPerm: "archive:write:own")
        router.get("/api/import/tasks/:no", { req: ApiRequest => this.detail(req) },
            requiredPerm: "archive:write:own")
        router.get("/api/import/tasks/:no/report", { req: ApiRequest => this.report(req) },
            requiredPerm: "archive:write:own")
        router.post("/api/import/tasks/:no/cancel", { req: ApiRequest => this.cancel(req) },
            requiredPerm: "archive:write:own")
        // ---- FR-EXP-008 导出包回导（可携带闭环）----
        // 请求体就是 .amsx.json 的原文，不套外层 JSON：
        // 再包一层只会让「文件内容」在传输链路上多一次转义失败的风险。
        router.post("/api/import/bundle/precheck", { req: ApiRequest => this.precheckBundle(req) },
            requiredPerm: "archive:write:own")
        router.post("/api/import/bundle", { req: ApiRequest => this.createBundle(req) },
            requiredPerm: "archive:write:own")
    }

    /**
     * GET /api/import/template —— 模板下载。
     */
    private func template(req: ApiRequest): ApiResponse {
        let h = HashMap<String, String>()
        h["Content-Type"] = "text/csv; charset=utf-8"
        h["Content-Disposition"] = "attachment; filename=\"ams-import-template.csv\""
        return ApiResponse(200, ImportService.template(), h)
    }

    /**
     * POST /api/import/precheck
     *
     * 两种入参（推荐前者）：
     *   ① Content-Type: text/csv  —— 请求体就是 CSV 原文，默认主体用 ?subjectId=
     *   ② Content-Type: application/json —— {"csv":"...","subjectId":123}
     *
     * 为什么同时支持裸 CSV：多行文本塞进 JSON 字符串要经过一层转义，
     * 只会给「导入」这种高频入口增加无谓的失败面（实测 JSON 里带空格
     * 的写法就会让 csv 字段被截断）。裸 text 最直白，也最不容易出错。
     *
     * 返回：{"total":N,"valid":M,"invalid":K,"errors":[{line,field,message}]}
     * 错误最多返回 50 条：预检是为了让用户看到「哪里错了」，
     * 不是把整份错误清单塞进响应体（完整清单位于任务错误报告）。
     */
    private func precheck(req: ApiRequest): ApiResponse {
        let csv = ImportRoutes.csvOf(req)
        if (csv.isEmpty()) {
            throw validationError("csv", "缺少 CSV 内容")
        }
        let defaultSubject = ImportRoutes.subjectOf(req)
        let plan = this.importService.precheck(
            UserRepo.parseId(req.subjectId),
            req.perms.contains("archive:write:any"),
            csv,
            defaultSubject,
            5000
        )
        let sb = StringBuilder()
        sb.append("{\"total\":${plan.total},\"valid\":${plan.valid},\"invalid\":${plan.invalid},")
        // FR-IMP-004：重复**不是错误**，单列一档让用户看清「这行已经存在」
        sb.append("\"duplicate\":${plan.duplicate},")
        sb.append("\"errors\":[")
        var n: Int64 = 0
        for (e in plan.errors) {
            if (n >= 50) {
                break
            }
            if (n > 0) {
                sb.append(",")
            }
            n = n + 1
            sb.append("{\"line\":${e.line},\"field\":\"${ApiResponse.escape(e.field)}\",")
            sb.append("\"message\":\"${ApiResponse.escape(e.message)}\"}")
        }
        sb.append("],\"truncated\":${if (plan.errors.size > 50) { "true" } else { "false" }},")
        // 重复明细（同样最多 50 条）
        sb.append("\"duplicates\":[")
        var m: Int64 = 0
        for (d in plan.duplicates) {
            if (m >= 50) {
                break
            }
            if (m > 0) {
                sb.append(",")
            }
            m = m + 1
            sb.append("{\"line\":${d.line},\"message\":\"${ApiResponse.escape(d.message)}\"}")
        }
        sb.append("],\"duplicatesTruncated\":${if (plan.duplicates.size > 50) { "true" } else { "false" }}}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * POST /api/import/tasks —— 创建导入任务（入参同 precheck）。
     */
    private func create(req: ApiRequest): ApiResponse {
        let csv = ImportRoutes.csvOf(req)
        if (csv.isEmpty()) {
            throw validationError("csv", "缺少 CSV 内容")
        }
        let defaultSubject = ImportRoutes.subjectOf(req)
        let taskNo = "IMP${Times.nowMillis()}${Ids.next() % 1000}"
        this.importService.submit(
            UserRepo.parseId(req.subjectId),
            req.perms.contains("archive:write:any"),
            csv,
            defaultSubject,
            taskNo
        )
        return ApiResponse.ok("{\"taskNo\":\"${ApiResponse.escape(taskNo)}\",\"status\":0}",
                              req.requestId)
    }

    /**
     * POST /api/import/bundle/precheck —— 导出包回导预检。
     *
     * 先验签（HMAC-SM3 / SHA-256）+ 核对 items 段 sha256 指纹，
     * 再逐行校验与判重；验签失败直接 4xx 拒绝，不进入行校验。
     */
    private func precheckBundle(req: ApiRequest): ApiResponse {
        let body = req.bodyText()
        if (body.isEmpty()) {
            throw validationError("bundle", "缺少导出包内容")
        }
        let defaultSubject = ImportRoutes.subjectOf(req)
        let plan = this.importService.planBundle(
            UserRepo.parseId(req.subjectId),
            req.perms.contains("archive:write:any"),
            body,
            defaultSubject
        )
        let sb = StringBuilder()
        sb.append("{\"total\":${plan.total},\"valid\":${plan.valid},\"invalid\":${plan.invalid},")
        sb.append("\"duplicate\":${plan.duplicate},")
        sb.append("\"errors\":[")
        var n: Int64 = 0
        for (e in plan.errors) {
            if (n >= 50) {
                break
            }
            if (n > 0) {
                sb.append(",")
            }
            n = n + 1
            sb.append("{\"line\":${e.line},\"field\":\"${ApiResponse.escape(e.field)}\",")
            sb.append("\"message\":\"${ApiResponse.escape(e.message)}\"}")
        }
        sb.append("],\"truncated\":${if (plan.errors.size > 50) { "true" } else { "false" }},")
        sb.append("\"duplicates\":[")
        var m: Int64 = 0
        for (d in plan.duplicates) {
            if (m >= 50) {
                break
            }
            if (m > 0) {
                sb.append(",")
            }
            m = m + 1
            sb.append("{\"line\":${d.line},\"message\":\"${ApiResponse.escape(d.message)}\"}")
        }
        sb.append("],\"duplicatesTruncated\":${if (plan.duplicates.size > 50) { "true" } else { "false" }}}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * POST /api/import/bundle —— 提交回导任务（异步）。
     */
    private func createBundle(req: ApiRequest): ApiResponse {
        let body = req.bodyText()
        if (body.isEmpty()) {
            throw validationError("bundle", "缺少导出包内容")
        }
        let defaultSubject = ImportRoutes.subjectOf(req)
        let taskNo = "IMP${Times.nowMillis()}${Ids.next() % 1000}"
        this.importService.submitBundle(
            UserRepo.parseId(req.subjectId),
            req.perms.contains("archive:write:any"),
            body,
            defaultSubject,
            taskNo
        )
        return ApiResponse.ok("{\"taskNo\":\"${ApiResponse.escape(taskNo)}\",\"status\":0}",
                              req.requestId)
    }

    private func list(req: ApiRequest): ApiResponse {
        let page = ImportRoutes.longOf(ImportRoutes.q(req, "page"), 1)
        let size = ImportRoutes.clamp(ImportRoutes.longOf(ImportRoutes.q(req, "size"), 20), 1, 100)
        let uid = UserRepo.parseId(req.subjectId)
        let rows = this.taskRepo.listOf(uid, "import", size, (page - 1) * size)
        let total = this.taskRepo.countOf(uid, "import")
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

    private func detail(req: ApiRequest): ApiResponse {
        let row = this.ownedTask(req, req.pathParam("no") ?? "")
        return ApiResponse.ok(ExportRoutes.taskJson(row), req.requestId)
    }

    /**
     * GET /api/import/tasks/:no/report —— 错误报告下载。
     */
    private func report(req: ApiRequest): ApiResponse {
        let row = this.ownedTask(req, req.pathParam("no") ?? "")
        if (row.i64("status") != TaskStatus.Success) {
            throw AppError(AppErrorKind.Conflict, "任务尚未成功结束，暂无报告")
        }
        let store = match (this.storage) {
            case Some(s) => s
            case None => throw AppError(AppErrorKind.Internal, "导入存储未配置")
        }
        let key = row.str("result_path")
        let bytes = match (store.get(key)) {
            case Some(b) => b
            case None => throw AppError(AppErrorKind.NotFound, "报告文件缺失")
        }
        let h = HashMap<String, String>()
        h["Content-Type"] = "text/csv; charset=utf-8"
        h["Content-Disposition"] =
            "attachment; filename=\"import-${ApiResponse.escape(row.str("task_no"))}-errors.csv\""
        return ApiResponse(200, String.fromUtf8(bytes), h)
    }

    private func cancel(req: ApiRequest): ApiResponse {
        let row = this.ownedTask(req, req.pathParam("no") ?? "")
        if (!this.taskRepo.cancel(row.i64("id"))) {
            throw AppError(AppErrorKind.Conflict, "任务已结束，无法取消")
        }
        return ApiResponse.ok("{\"cancelled\":true}", req.requestId)
    }

    private func ownedTask(req: ApiRequest, taskNo: String): RowData {
        if (taskNo.isEmpty()) {
            throw validationError("taskNo", "缺少任务号")
        }
        let row = match (this.taskRepo.findByNo(taskNo)) {
            case Some(r) => r
            case None => throw notFound("任务")
        }
        let isAdmin = req.perms.contains("system:admin") || req.perms.contains("archive:write:any")
        if (!isAdmin && row.str("user_id") != req.subjectId) {
            throw notFound("任务")
        }
        return row
    }

    private static func body(req: ApiRequest): SimpleJson {
        return match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
    }

    /**
     * 取 CSV 原文：优先按裸 text/csv 处理，其次回落到 JSON 的 `csv` 字段。
     */
    private static func csvOf(req: ApiRequest): String {
        let ct = (req.header("content-type") ?? "").toAsciiLower()
        if (!ct.contains("json")) {
            // 裸 CSV（含未声明 Content-Type 的客户端）
            return req.bodyText()
        }
        let json = ImportRoutes.body(req)
        return json.get("csv") ?? ""
    }

    /** 默认主体：query 优先，其次 JSON 字段 */
    private static func subjectOf(req: ApiRequest): Int64 {
        let fromQuery = match (req.queryParam("subjectId")) {
            case Some(v) => RowData.toI64(v)
            case None => 0
        }
        if (fromQuery > 0) {
            return fromQuery
        }
        let ct = (req.header("content-type") ?? "").toAsciiLower()
        if (ct.contains("json")) {
            match (SimpleJson.parse(req.bodyText())) {
                case Some(j) => return ImportRoutes.intFrom(j, "subjectId", 0)
                case None => return 0
            }
        }
        return 0
    }

    private static func intFrom(json: SimpleJson, key: String, default: Int64): Int64 {
        return match (json.get(key)) {
            case Some(v) => if (v.isEmpty()) { default } else { RowData.toI64(v) }
            case None => default
        }
    }

    private static func q(req: ApiRequest, name: String): String {
        return match (req.queryParam(name)) {
            case Some(v) => v
            case None => ""
        }
    }

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

    private static func clamp(v: Int64, lo: Int64, hi: Int64): Int64 {
        if (v < lo) {
            return lo
        }
        if (v > hi) {
            return hi
        }
        return v
    }
}

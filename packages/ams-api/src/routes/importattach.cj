// ============================================================
// ams.api.routes.importattach · 附件批量导入接口（FR-IMP-002）
//
// 路由：
//   POST /api/import/attachments/precheck  预检：解包 + 映射预览，**不落库**
//   POST /api/import/attachments/tasks     确认并执行（异步任务）
//
// 权限：与 CSV 导入一致 → archive:write:own
//       （产物仍是条目 + 附件，写入权限已覆盖其风险面）
//
// 【请求体格式：为什么要自定义封帧】
//   确认执行这一步需要**同时**传 ZIP（可能几十 MB）和一份映射决定
//   （目录名 → 条目 ID）。可选方案：
//     · multipart/form-data：要再写一个 multipart 解析器（边界切分、
//       二进制安全、CRLF 处理），为一个接口引入新的解析面不值当；
//     · base64 塞进 JSON：40MB 的包膨胀到 54MB，且完全没必要；
//     · 自定义封帧：`u32 小端 JSON 长度` + `JSON` + `ZIP`，编解码各十几行，
//       二进制安全，且能**自动识别**裸 ZIP（首字节 "PK"）。
//
//   故本接口接受两种请求体：
//     ① 封帧：u32le(jsonLen) + json + zip
//     ② 裸 ZIP：整个请求体就是 ZIP（等价于「没有任何重名冲突要指定」）
//        → `curl --data-binary @pkg.zip '.../tasks?subjectId=1&category=3'`
//
//   JSON 字段：
//     subjectId  目标主体（必填）
//     category   新建条目的分类 1-11（默认 3）
//     r.<目录名>  该目录指定的目标条目 ID（0 = 仍然新建条目）
//                用 `r.` 前缀是为了让键名不与其他字段冲突；
//                SimpleJson 是扁平解析器，用键名承载数据最省事。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.app.importer.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.id.*
import ams.kernel.time.*

/**
 * 附件批量导入接口。
 */
public class AttachmentImportRoutes {
    private let service: AttachmentImportService
    private let userRepo: UserRepo

    public init(service: AttachmentImportService, userRepo: UserRepo) {
        this.service = service
        this.userRepo = userRepo
    }

    public func register(router: Router): Unit {
        router.post("/api/import/attachments/precheck",
                    { req: ApiRequest => this.precheck(req) },
                    requiredPerm: "archive:write:own")
        router.post("/api/import/attachments/tasks",
                    { req: ApiRequest => this.create(req) },
                    requiredPerm: "archive:write:own")
        router.post("/api/import/attachments/tasks/:no/retry",
                    { req: ApiRequest => this.retry(req) },
                    requiredPerm: "archive:write:own")
    }

    /**
     * POST /api/import/attachments/tasks/:no/retry
     *
     * 重试上一个任务里失败的文件（PRD「失败可重试」）。
     * **不需要重新上传**：提交时的原始包已留存在服务端存储。
     */
    private func retry(req: ApiRequest): ApiResponse {
        let prev = req.pathParam("no") ?? ""
        let taskNo = "IMPA${Times.nowMillis()}${Ids.next() % 1000}"
        let rows = this.service.retry(
            UserRepo.parseId(req.subjectId),
            req.perms.contains("archive:write:any"),
            prev,
            taskNo
        )
        return ApiResponse.ok(
            "{\"taskNo\":\"${ApiResponse.escape(taskNo)}\",\"status\":0,\"total\":${rows}}",
            req.requestId
        )
    }

    /**
     * POST /api/import/attachments/precheck
     *
     * 请求体 = ZIP 原始字节（也接受与 /tasks 相同的封帧体）；
     * subjectId / category 走 query，缺省时回落到封帧内的 JSON。
     * 返回映射预览，**不写任何库**。
     */
    private func precheck(req: ApiRequest): ApiResponse {
        // 与 /tasks 共用同一个拆分器：裸 ZIP 与封帧体（u32le + JSON + ZIP）都接受。
        // 预检本身不看 resolutions，但让两个入口对请求体的解释保持一致，
        // 可以避免「预检能过、确认提交却解析失败」这类只在第二步才暴露的分叉。
        let (jsonText, zip) = AttachmentImportRoutes.splitFramed(req.bodyBytes)
        if (zip.size == 0) {
            throw validationError("file", "缺少 ZIP 内容")
        }
        let json = if (jsonText.isEmpty()) {
            SimpleJson()
        } else {
            match (SimpleJson.parse(jsonText)) {
                case Some(j) => j
                case None => throw validationError("body", "封帧内的 JSON 不合法")
            }
        }
        // 主体 / 分类：query 优先，缺省时回落到封帧内的 JSON
        var subjectId = AttachmentImportRoutes.queryLong(req, "subjectId", 0)
        if (subjectId <= 0) {
            subjectId = AttachmentImportRoutes.jsonLong(json, "subjectId", 0)
        }
        var category = AttachmentImportRoutes.queryLong(req, "category", 0)
        if (category <= 0) {
            category = AttachmentImportRoutes.jsonLong(json, "category", 3)
        }
        let plan = this.service.precheck(
            UserRepo.parseId(req.subjectId),
            req.perms.contains("archive:write:any"),
            zip,
            subjectId,
            category
        )
        return ApiResponse.ok(AttachmentImportRoutes.planJson(plan), req.requestId)
    }

    /**
     * POST /api/import/attachments/tasks
     *
     * 请求体见文件头（封帧或裸 ZIP）。
     */
    private func create(req: ApiRequest): ApiResponse {
        let (jsonText, zip) = AttachmentImportRoutes.splitFramed(req.bodyBytes)
        if (zip.size == 0) {
            throw validationError("file", "缺少 ZIP 内容")
        }
        let json = if (jsonText.isEmpty()) {
            SimpleJson()
        } else {
            match (SimpleJson.parse(jsonText)) {
                case Some(j) => j
                case None => throw validationError("body", "封帧内的 JSON 不合法")
            }
        }
        // subjectId / category：JSON 优先，其次 query（裸 ZIP 场景只能走 query）
        var subjectId = AttachmentImportRoutes.jsonLong(json, "subjectId", 0)
        if (subjectId <= 0) {
            subjectId = AttachmentImportRoutes.queryLong(req, "subjectId", 0)
        }
        var category = AttachmentImportRoutes.jsonLong(json, "category", 0)
        if (category <= 0) {
            category = AttachmentImportRoutes.queryLong(req, "category", 3)
        }
        // 重名目录的目标条目：键 `r.<目录名>` → 条目 ID
        let resolutions = HashMap<String, Int64>()
        for ((k, v) in json.entries()) {
            if (k.startsWith("r.") && k.size > 2) {
                resolutions.add(k[2..], RowData.toI64(v))
            }
        }
        let taskNo = "IMPA${Times.nowMillis()}${Ids.next() % 1000}"
        this.service.submit(
            UserRepo.parseId(req.subjectId),
            req.perms.contains("archive:write:any"),
            zip,
            subjectId,
            category,
            resolutions,
            taskNo
        )
        return ApiResponse.ok(
            "{\"taskNo\":\"${ApiResponse.escape(taskNo)}\",\"status\":0}", req.requestId
        )
    }

    // ---------------------------------------------------------
    // 封帧
    // ---------------------------------------------------------

    /**
     * 拆分请求体。
     *
     * @return (JSON 文本, ZIP 字节)；裸 ZIP 时 JSON 文本为空串
     */
    static func splitFramed(body: Array<Byte>): (String, Array<Byte>) {
        // 裸 ZIP：本地文件头/空档案标记都以 "PK" 开头
        if (body.size >= 2 && body[0] == 80 && body[1] == 75) {
            return ("", body)
        }
        if (body.size < 4) {
            return ("", Array<Byte>())
        }
        let len = Int64(body[0]) + Int64(body[1]) * 256 +
                  Int64(body[2]) * 65536 + Int64(body[3]) * 16777216
        if (len < 0 || len > 65536 || 4 + len > body.size) {
            // 长度不合理 → 当作裸 ZIP 试一次，交给 ZIP 解析器给出明确错误
            return ("", body)
        }
        let json = String.fromUtf8(body[4..(4 + len)])
        return (json, body[(4 + len)..])
    }

    // ---------------------------------------------------------
    // JSON
    // ---------------------------------------------------------

    static func planJson(plan: AttachPlan): String {
        let indexTruncFlag = if (plan.indexTruncated) { "true" } else { "false" }
        let sb = StringBuilder()
        sb.append("{\"total\":${plan.rows.size},")
        sb.append("\"match\":${plan.matchCount},\"create\":${plan.createCount},")
        sb.append("\"conflict\":${plan.conflictCount},\"skip\":${plan.skipCount},")
        sb.append("\"dirs\":${plan.dirCount},\"bytes\":${plan.totalBytes},")
        sb.append("\"indexTruncated\":${indexTruncFlag},")
        // 将新建的条目
        sb.append("\"newTitles\":[")
        var first = true
        for (t in plan.newTitles) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("\"${ApiResponse.escape(t)}\"")
        }
        sb.append("],")
        // 未解决的重名冲突（含候选，前端直接渲染成下拉框）
        sb.append("\"conflicts\":[")
        first = true
        for ((title, cands) in plan.conflicts) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("{\"title\":\"${ApiResponse.escape(title)}\",\"candidates\":[")
            var f2 = true
            for (c in cands) {
                if (!f2) {
                    sb.append(",")
                }
                f2 = false
                sb.append("{\"id\":\"${c.itemId}\",\"title\":\"${ApiResponse.escape(c.title)}\",")
                sb.append("\"category\":${c.category}}")
            }
            sb.append("]}")
        }
        sb.append("],")
        // 预览行（超上限截断）
        let limit = AttachmentImportService.MAX_PREVIEW_ROWS
        let rows = plan.rows
        let shown = if (rows.size > limit) { limit } else { rows.size }
        let truncFlag = if (rows.size > limit) { "true" } else { "false" }
        sb.append("\"rows\":[")
        var i: Int64 = 0
        while (i < shown) {
            let r = rows[i]
            if (i > 0) {
                sb.append(",")
            }
            sb.append("{\"i\":${r.index},\"path\":\"${ApiResponse.escape(r.zipPath)}\",")
            sb.append("\"title\":\"${ApiResponse.escape(r.dirTitle)}\",")
            sb.append("\"file\":\"${ApiResponse.escape(r.fileName)}\",")
            sb.append("\"size\":${r.size},\"action\":\"${r.action}\",")
            sb.append("\"itemId\":\"${r.targetItemId}\",")
            sb.append("\"note\":\"${ApiResponse.escape(r.note)}\"}")
            i = i + 1
        }
        sb.append("],\"rowsTruncated\":${truncFlag}}")
        return sb.toString()
    }

    // ---------------------------------------------------------
    // 参数
    // ---------------------------------------------------------

    private static func queryLong(req: ApiRequest, name: String, default: Int64): Int64 {
        match (req.queryParam(name)) {
            case Some(v) => if (v.isEmpty()) { default } else { RowData.toI64(v) }
            case None => default
        }
    }

    private static func jsonLong(json: SimpleJson, key: String, default: Int64): Int64 {
        match (json.get(key)) {
            case Some(v) => if (v.isEmpty()) { default } else { RowData.toI64(v) }
            case None => default
        }
    }
}

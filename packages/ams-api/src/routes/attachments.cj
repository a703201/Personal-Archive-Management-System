// ============================================================
// ams.api.routes.attachments · 附件接口
//
// 覆盖 FR-ATT-001（上传）、004（版本）、005（预览与下载）、006（元数据）
//
// 【上传用什么格式】
//   不做 multipart 解析：元数据走 **query 参数**，文件内容走 **原始二进制请求体**。
//     POST /api/attachments?itemId=123&title=身份证&fileName=a.jpg&category=10
//     Content-Type: application/octet-stream
//     <原始字节>
//   理由：仓颉侧手写 multipart 边界解析容易出错且难维护；
//   原始体对单文件上传是最简可靠形态，前端用 fetch(body: File) 即可直传。
//
// 【权限分离（FR-ATT-005）】
//   读元信息用 attachment:read:*；**下载解密内容**用 attachment:download:*。
//   两者是不同权限点 —— 可以只授权预览而不授权下载，满足最小权限。
//
// 【下载为何返回 base64】
//   当前 ApiResponse.body 是 String，HTTP 层不支持二进制响应体。
//   故下载以 base64 内嵌 JSON 返回，保证链路可用且不引入编码损坏。
//   ⚠️ 生产应扩展 ApiResponse 支持 Array<Byte> 并改用流式响应，
//      否则大文件会占用较多内存（见 §7.8 剩余清单）。
// ============================================================
package ams.api.routes

import std.collection.*
import stdx.encoding.base64.*

import ams.api.http.*
import ams.app.attachment.*
import ams.data.repo.*
import ams.kernel.error.*

/**
 * 附件接口。
 */
public class AttachmentRoutes {
    private let service: AttachmentService
    private let repo: AttachmentRepo

    public init(service: AttachmentService, repo: AttachmentRepo) {
        this.service = service
        this.repo = repo
    }

    public func register(router: Router): Unit {
        router.post("/api/attachments", { req: ApiRequest => this.upload(req) },
                    requiredPerm: "attachment:upload:own")
        router.get("/api/attachments", { req: ApiRequest => this.listByItem(req) },
                   requiredPerm: "attachment:read:own")
        router.get("/api/attachments/:id", { req: ApiRequest => this.meta(req) },
                   requiredPerm: "attachment:read:own")
        router.get("/api/attachments/:id/download", { req: ApiRequest => this.download(req) },
                   requiredPerm: "attachment:download:own")
        router.get("/api/attachments/:id/versions", { req: ApiRequest => this.versions(req) },
                   requiredPerm: "attachment:read:own")
        router.post("/api/attachments/:id/versions/:versionId/current",
                    { req: ApiRequest => this.switchVersion(req) },
                    requiredPerm: "attachment:upload:own")
    }

    // ---------------------------------------------------------

    /**
     * POST /api/attachments —— 元数据在 query，内容是原始字节。
     */
    private func upload(req: ApiRequest): ApiResponse {
        let fileName = req.queryParam("fileName") ?? ""
        if (fileName.isEmpty()) {
            throw validationError("fileName", "缺少 fileName 参数")
        }
        let title = match (req.queryParam("title")) {
            case Some(v) => if (v.isEmpty()) { fileName } else { v }
            case None => fileName
        }
        let category = AttachmentRoutes.intOfQuery(req, "category", 10)
        let subjectId = UserRepo.parseId(req.subjectId)
        let operatorId = subjectId

        // itemId 可选：不传即主体级独立附件
        // 仓颉的 Some/None 需显式类型实参，故这里先归约成标量再构造
        var hasItem = false
        var itemIdVal: Int64 = 0
        match (req.queryParam("itemId")) {
            case Some(v) =>
                if (!v.isEmpty()) {
                    hasItem = true
                    itemIdVal = RowData.toI64(v)
                }
            case None => ()
        }
        let itemId: Option<Int64> = if (hasItem) { Some<Int64>(itemIdVal) } else { None }

        let result = this.service.upload(
            subjectId, itemId, category, title, fileName, req.bodyBytes, operatorId
        )
        return ApiResponse.ok(
            "{\"id\":${result.attachmentId},\"dedupHit\":${result.dedupHit},\"status\":${result.status}}",
            req.requestId
        )
    }

    /**
     * GET /api/attachments?itemId=N
     */
    private func listByItem(req: ApiRequest): ApiResponse {
        let itemId = AttachmentRoutes.intOfQuery(req, "itemId", 0)
        if (itemId == 0) {
            throw validationError("itemId", "缺少 itemId 参数")
        }
        let list = this.repo.listByItem(itemId)
        let sb = StringBuilder()
        sb.append("{\"attachments\":[")
        var first = true
        for (a in list) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append(AttachmentRoutes.toJson(a))
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * GET /api/attachments/:id —— 元信息（不含内容）。
     */
    private func meta(req: ApiRequest): ApiResponse {
        let id = RowData.toI64(req.pathParam("id") ?? "")
        match (this.repo.findById(id)) {
            case Some(a) => return ApiResponse.ok(AttachmentRoutes.toJson(a), req.requestId)
            case None => throw notFound("附件")
        }
    }

    /**
     * GET /api/attachments/:id/download —— 解密并以 base64 返回。
     */
    private func download(req: ApiRequest): ApiResponse {
        let id = RowData.toI64(req.pathParam("id") ?? "")
        let plain = this.service.download(id)
        let b64 = toBase64String(plain)
        return ApiResponse.ok("{\"id\":${id},\"size\":${plain.size},\"base64\":\"${b64}\"}",
            req.requestId)
    }

    /**
     * GET /api/attachments/:id/versions —— 版本列表（FR-ATT-004）。
     */
    private func versions(req: ApiRequest): ApiResponse {
        let id = RowData.toI64(req.pathParam("id") ?? "")
        let rows = this.service.listVersions(id)
        let sb = StringBuilder()
        sb.append("{\"versions\":[")
        var first = true
        for (r in rows.all().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("{\"id\":${r.i64("id")},")
            sb.append("\"versionNo\":${r.i64("version_no")},")
            sb.append("\"fileSize\":${r.i64("file_size")},")
            sb.append("\"fileExt\":\"${ApiResponse.escape(r.str("file_ext"))}\",")
            sb.append("\"isCurrent\":${r.bool("is_current")},")
            sb.append("\"status\":${r.i64("status")},")
            sb.append("\"changeNote\":\"${ApiResponse.escape(r.str("change_note"))}\",")
            sb.append("\"uploadedAt\":${r.i64("uploaded_ms")}}")
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * POST /api/attachments/:id/versions/:versionId/current —— 切换当前版本。
     */
    private func switchVersion(req: ApiRequest): ApiResponse {
        let id = RowData.toI64(req.pathParam("id") ?? "")
        let versionId = RowData.toI64(req.pathParam("versionId") ?? "")
        this.service.switchVersion(id, versionId)
        return ApiResponse.ok("{\"id\":${id},\"currentVersionId\":${versionId}}", req.requestId)
    }

    // ---------------------------------------------------------

    private static func intOfQuery(req: ApiRequest, key: String, default: Int64): Int64 {
        match (req.queryParam(key)) {
            case Some(v) =>
                if (v.isEmpty()) {
                    return default
                }
                return RowData.toI64(v)
            case None => return default
        }
    }

    private static func toJson(a: AttachmentRecord): String {
        let sb = StringBuilder()
        sb.append("{\"id\":${a.id},")
        sb.append("\"subjectId\":${a.subjectId},")
        sb.append("\"itemId\":${a.itemId},")
        sb.append("\"category\":${a.category},")
        sb.append("\"title\":\"${ApiResponse.escape(a.title)}\",")
        sb.append("\"currentVersionId\":${a.currentVersionId},")
        sb.append("\"versionCount\":${a.versionCount},")
        sb.append("\"fileSize\":${a.fileSize},")
        sb.append("\"fileExt\":\"${ApiResponse.escape(a.fileExt)}\",")
        sb.append("\"mimeType\":\"${ApiResponse.escape(a.mimeType)}\",")
        sb.append("\"status\":${a.status},")
        sb.append("\"downloadCount\":${a.downloadCount}}")
        return sb.toString()
    }
}

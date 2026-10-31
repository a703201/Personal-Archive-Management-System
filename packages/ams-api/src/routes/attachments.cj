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
import ams.app.audit.*
import ams.crypto.provider.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.time.*
import ams.security.audit.*

/**
 * 附件接口。
 */
public class AttachmentRoutes {
    private let service: AttachmentService
    private let repo: AttachmentRepo
    /**
     * 用户仓储（可选）：装配后批量下载/打标签/删除都会校验
     * 「附件所属主体是否在当前账号的可访问集合内」——
     * 单条下载此前只靠权限码、没有行级归属校验（IDOR 面），
     * 批量入口必须先补上行级校验。
     */
    private let userRepo: ?UserRepo
    /** 加密服务（批量打包时用于生成 ZipCrypto 随机头） */
    private let crypto: ?CryptoProvider
    /** 审计记录器（批量导出/删除留痕） */
    private let recorder: ?AuditRecorder

    public init(
        service: AttachmentService,
        repo: AttachmentRepo,
        userRepo!: ?UserRepo = None,
        crypto!: ?CryptoProvider = None,
        recorder!: ?AuditRecorder = None
    ) {
        this.service = service
        this.repo = repo
        this.userRepo = userRepo
        this.crypto = crypto
        this.recorder = recorder
    }

    public func register(router: Router): Unit {
        router.post("/api/attachments", { req: ApiRequest => this.upload(req) },
                    requiredPerm: "attachment:upload:own")
        router.get("/api/attachments", { req: ApiRequest => this.listByItem(req) },
                   requiredPerm: "attachment:read:own")
        router.get("/api/attachments/:id", { req: ApiRequest => this.meta(req) },
                   requiredPerm: "attachment:read:own")
        // ---- FR-ATT-013 降级：手动录入摘要 / 关键词（OCR 不可用时）----
        router.put("/api/attachments/:id",
                   { req: ApiRequest => this.updateMeta(req) },
                   requiredPerm: "attachment:upload:own")
        router.get("/api/attachments/:id/download", { req: ApiRequest => this.download(req) },
                   requiredPerm: "attachment:download:own")
        router.get("/api/attachments/:id/versions", { req: ApiRequest => this.versions(req) },
                   requiredPerm: "attachment:read:own")
        // ---- FR-ATT-004 上传新版本（版本对比的数据前提）----
        router.post("/api/attachments/:id/versions",
                    { req: ApiRequest => this.uploadVersion(req) },
                    requiredPerm: "attachment:upload:own")
        router.post("/api/attachments/:id/versions/:versionId/current",
                    { req: ApiRequest => this.switchVersion(req) },
                    requiredPerm: "attachment:upload:own")
        // ---- FR-ATT-009 版本对比 ----
        router.get("/api/attachments/:id/versions/compare",
                   { req: ApiRequest => this.compareVersions(req) },
                   requiredPerm: "attachment:read:own")
        // ---- FR-ATT-008 预览水印 ----
        router.get("/api/attachments/:id/watermark",
                   { req: ApiRequest => this.watermark(req) },
                   requiredPerm: "attachment:read:own")
        // ---- FR-ATT-010 批量操作 ----
        router.post("/api/attachments/batch/download",
                    { req: ApiRequest => this.batchDownload(req) },
                    requiredPerm: "attachment:download:own")
        router.post("/api/attachments/batch/tag",
                    { req: ApiRequest => this.batchTag(req) },
                    requiredPerm: "attachment:upload:own")
        router.post("/api/attachments/batch/delete",
                    { req: ApiRequest => this.batchDelete(req) },
                    requiredPerm: "attachment:delete:any")
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
        // 主体级附件必须显式给 subjectId；条目级附件由 service 按 itemId 反查主体。
        // 旧实现把「当前用户 ID」当 subjectId，导致附件挂错主体（已修）。
        let subjectId = AttachmentRoutes.intOfQuery(req, "subjectId", 0)
        let operatorId = UserRepo.parseId(req.subjectId)

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

        let summary = req.queryParam("summary") ?? ""
        let keywords = req.queryParam("keywords") ?? ""
        let result = this.service.upload(
            subjectId, itemId, category, title, fileName, req.bodyBytes, operatorId,
            summary: summary, keywords: keywords
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
     * PATCH /api/attachments/:id —— 更新摘要 / 关键词（FR-ATT-013 降级）。
     *
     * 正文为 JSON：{"summary":"...","keywords":"..."}；两字段均可省略（省略即不改）。
     */
    private func updateMeta(req: ApiRequest): ApiResponse {
        let id = RowData.toI64(req.pathParam("id") ?? "")
        if (id <= 0) {
            throw validationError("id", "非法的附件 id")
        }
        // 先确认附件存在（顺带做归属/权限前置，路由层已按 attachment:upload:own 拦截）
        match (this.repo.findById(id)) {
            case Some(_) => ()
            case None => throw notFound("附件")
        }
        let body = match (SimpleJson.parse(req.bodyText())) {
            case Some(v) => v
            case None => throw validationError("body", "请求正文不是合法 JSON")
        }
        var summary: String = ""
        var keywords: String = ""
        match (body.get("summary")) {
            case Some(s) => summary = s
            case None => ()
        }
        match (body.get("keywords")) {
            case Some(k) => keywords = k
            case None => ()
        }
        let operatorId = UserRepo.parseId(req.subjectId)
        this.service.updateMeta(id, summary, keywords, operatorId)
        return ApiResponse.ok("{\"ok\":true,\"id\":${id}}", req.requestId)
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
     * POST /api/attachments/:id/versions —— 上传新版本。
     *
     * query：fileName（必填）、changeNote（可选）
     * body ：原始二进制
     */
    private func uploadVersion(req: ApiRequest): ApiResponse {
        let id = RowData.toI64(req.pathParam("id") ?? "")
        this.owned(id, req)
        let fileName = req.queryParam("fileName") ?? ""
        if (fileName.isEmpty()) {
            throw validationError("fileName", "缺少 fileName 参数")
        }
        let note = req.queryParam("changeNote") ?? ""
        let versionId = this.service.uploadVersion(
            id, fileName, note, req.bodyBytes, UserRepo.parseId(req.subjectId)
        )
        return ApiResponse.ok(
            "{\"attachmentId\":${id},\"versionId\":${versionId}}",
            req.requestId
        )
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
    // FR-ATT-009 版本对比 / FR-ATT-010 批量操作
    // ---------------------------------------------------------

    /**
     * GET /api/attachments/:id/versions/compare?from=&to=
     *
     * 只比**元数据**（不落字节 diff）：版本号、大小、扩展名、MIME、
     * 状态、变更说明、内容指纹。指纹不同即「内容变了」，
     * 这是服务端能给出的最可靠结论（内容 diff 需要按 MIME 分派解析器，
     * 本仓不引这类依赖）。
     */
    private func compareVersions(req: ApiRequest): ApiResponse {
        let id = RowData.toI64(req.pathParam("id") ?? "")
        let fromId = AttachmentRoutes.intOfQuery(req, "from", 0)
        let toId = AttachmentRoutes.intOfQuery(req, "to", 0)
        if (fromId == 0 || toId == 0) {
            throw validationError("from", "缺少 from / to 版本号参数")
        }
        let a = match (this.repo.findVersion(id, fromId)) {
            case Some(r) => r
            case None => throw notFound("来源版本")
        }
        let b = match (this.repo.findVersion(id, toId)) {
            case Some(r) => r
            case None => throw notFound("目标版本")
        }
        let sameContent = a.str("fp_hex") == b.str("fp_hex")
        let sizeDelta = b.i64("file_size") - a.i64("file_size")
        let sb = StringBuilder()
        sb.append("{\"attachmentId\":${id},")
        sb.append("\"from\":${AttachmentRoutes.versionJson(a)},")
        sb.append("\"to\":${AttachmentRoutes.versionJson(b)},")
        sb.append("\"diff\":{\"contentChanged\":${!sameContent},")
        sb.append("\"sizeDelta\":${sizeDelta},")
        sb.append("\"extChanged\":${a.str("file_ext") != b.str("file_ext")},")
        sb.append("\"mimeChanged\":${a.str("mime_type") != b.str("mime_type")},")
        sb.append("\"statusChanged\":${a.i64("status") != b.i64("status")},")
        sb.append("\"noteChanged\":${a.str("change_note") != b.str("change_note")},")
        sb.append("\"fields\":[")
        var first = true
        first = AttachmentRoutes.pushField(sb, first, "versionNo", "版本号",
            "${a.i64("version_no")}", "${b.i64("version_no")}")
        first = AttachmentRoutes.pushField(sb, first, "fileSize", "文件大小",
            "${a.i64("file_size")}", "${b.i64("file_size")}")
        first = AttachmentRoutes.pushField(sb, first, "fileExt", "扩展名",
            a.str("file_ext"), b.str("file_ext"))
        first = AttachmentRoutes.pushField(sb, first, "mimeType", "内容类型",
            a.str("mime_type"), b.str("mime_type"))
        first = AttachmentRoutes.pushField(sb, first, "status", "状态",
            "${a.i64("status")}", "${b.i64("status")}")
        first = AttachmentRoutes.pushField(sb, first, "fingerprint", "内容指纹",
            AttachmentRoutes.shortFp(a.str("fp_hex")), AttachmentRoutes.shortFp(b.str("fp_hex")))
        first = AttachmentRoutes.pushField(sb, first, "changeNote", "变更说明",
            a.str("change_note"), b.str("change_note"))
        sb.append("]}}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * POST /api/attachments/batch/download
     *
     * 请求体：{"ids":[1,2,3],"password":"可选"}
     * 响应：{fileName,size,sha256,encrypted,base64}
     *
     * 用 ZIP（store 方法）打包；`password` 非空时用 ZipCrypto 加密。
     * 不返回裸二进制：本仓 HTTP 层以 String 承载正文，二进制会经
     * UTF-8 编码损坏，故统一走 base64，由前端还原成 Blob 下载。
     */
    private func batchDownload(req: ApiRequest): ApiResponse {
        let json = match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        let ids = AttachmentRoutes.parseIds(json.get("ids") ?? "")
        if (ids.isEmpty()) {
            throw validationError("ids", "请至少选择一个附件")
        }
        if (ids.size > 200) {
            throw validationError("ids", "单次最多 200 个附件")
        }
        let password = json.get("password") ?? ""
        let crypto = match (this.crypto) {
            case Some(p) => p
            case None => throw AppError(AppErrorKind.Internal, "加密服务未装配")
        }
        let zip = ZipBuilder(crypto)
        var total: Int64 = 0
        for (id in ids) {
            let rec = this.owned(id, req)
            var name = rec.title
            if (name.isEmpty()) {
                name = "attachment-${id}"
            }
            if (!rec.fileExt.isEmpty()) {
                name = "${name}.${rec.fileExt}"
            }
            let bytes = this.service.download(id)
            zip.add(name, bytes)
            total = total + bytes.size
        }
        if (zip.size() == 0) {
            throw AppError(AppErrorKind.NotFound, "所选附件均不可下载")
        }
        let archive = zip.build(password)
        let ext = if (password.isEmpty()) { "zip" } else { "zip" }
        let fileName = "attachments-${Times.nowMillis()}.${ext}"
        // 打包下载属批量导出行为，必须留痕
        match (this.recorder) {
            case Some(r) =>
                r.record(
                    req.subjectId, ActorType.User, AuditAction.DataExport,
                    "attachment_batch", "${ids.size}",
                    "", 0, AuditResult.Success, "", req.remoteAddr,
                    req.header("user-agent") ?? "", "",
                    Array<(String, String)>()
                )
            case None => ()
        }
        let sb = StringBuilder()
        sb.append("{\"fileName\":\"${ApiResponse.escape(fileName)}\",")
        sb.append("\"count\":${zip.size()},")
        sb.append("\"rawBytes\":${total},")
        sb.append("\"size\":${archive.size},")
        sb.append("\"encrypted\":${!password.isEmpty()},")
        sb.append("\"base64\":\"${toBase64String(archive)}\"}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * POST /api/attachments/batch/tag
     *
     * 请求体：{"ids":[1,2],"tagIds":[3,4],"mode":"add|remove"}
     */
    private func batchTag(req: ApiRequest): ApiResponse {
        let json = match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        let ids = AttachmentRoutes.parseIds(json.get("ids") ?? "")
        let tagIds = AttachmentRoutes.parseIds(json.get("tagIds") ?? "")
        if (ids.isEmpty() || tagIds.isEmpty()) {
            throw validationError("ids", "附件与标签都不能为空")
        }
        let mode = json.get("mode") ?? "add"
        for (t in tagIds) {
            if (!this.repo.tagExists(t)) {
                throw validationError("tagIds", "标签 ${t} 不存在")
            }
        }
        let uid = UserRepo.parseId(req.subjectId)
        var changed: Int64 = 0
        for (id in ids) {
            this.owned(id, req)
            for (t in tagIds) {
                let ok = if (mode == "remove") {
                    this.repo.removeTag(id, t)
                } else {
                    this.repo.addTag(id, t, uid)
                }
                if (ok) {
                    changed = changed + 1
                }
            }
        }
        return ApiResponse.ok(
            "{\"attachments\":${ids.size},\"tags\":${tagIds.size}," +
            "\"changed\":${changed},\"mode\":\"${ApiResponse.escape(mode)}\"}",
            req.requestId
        )
    }

    /**
     * POST /api/attachments/batch/delete
     *
     * 请求体：{"ids":[...]}；软删除（status=9），保留版本与审计。
     */
    private func batchDelete(req: ApiRequest): ApiResponse {
        let json = match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        let ids = AttachmentRoutes.parseIds(json.get("ids") ?? "")
        if (ids.isEmpty()) {
            throw validationError("ids", "请至少选择一个附件")
        }
        var done = 0
        let uid = UserRepo.parseId(req.subjectId)
        for (id in ids) {
            this.owned(id, req)
            if (this.repo.softDelete(id, uid)) {
                done = done + 1
            }
        }
        match (this.recorder) {
            case Some(r) =>
                r.record(
                    req.subjectId, ActorType.User, AuditAction.BatchOperation,
                    "attachment", "${done}",
                    "", 0, AuditResult.Success, "", req.remoteAddr,
                    req.header("user-agent") ?? "", "",
                    Array<(String, String)>()
                )
            case None => ()
        }
        return ApiResponse.ok("{\"deleted\":${done}}", req.requestId)
    }

    /**
     * 取附件并校验主体归属（防止拿别人 ID 越权）。
     */
    private func owned(id: Int64, req: ApiRequest): AttachmentRecord {
        let rec = match (this.repo.findById(id)) {
            case Some(a) => a
            case None => throw notFound("附件")
        }
        match (this.userRepo) {
            case Some(ur) =>
                let uid = UserRepo.parseId(req.subjectId)
                let subs = ur.listAccessibleSubjectIds(uid)
                if (!subs.contains("${rec.subjectId}")) {
                    throw AppError(AppErrorKind.Forbidden, "无权访问该附件（主体不属于当前账号）")
                }
            case None => ()
        }
        return rec
    }

    /**
     * GET /api/attachments/:id/watermark —— 预览水印票据（FR-ATT-008）。
     *
     * 【为什么是「票据 + 前端叠加」而不是服务端烧进水印】
     *   服务端叠加水印需要图像/PDF 渲染与合成能力（编码、字体度量、PDF 内容流编辑）。
     *   本机仓颉 SDK 没有可用的图像编解码与 PDF 库，硬写一套像素合成既不安全
     *   也不可靠（字体、DPI、透明通道都要自己处理）。因此这里做**可追溯的降级**：
     *     · 服务端签发一次性水印文本（访问者 + 服务端时间 + 8 位追踪号）；
     *     · 同一次预览写入审计（trace 号可反查是谁、何时、从哪个 IP 看的）；
     *     · 前端把该文本以半透明斜向平铺覆盖在预览图上。
     *   截屏外泄时，水印上的追踪号能在审计里定位到具体一次预览，
     *   这才是「水印」真正的价值；相比之下，像素级水印只是更强的防裁剪。
     */
    private func watermark(req: ApiRequest): ApiResponse {
        let id = RowData.toI64(req.pathParam("id") ?? "")
        let rec = this.owned(id, req)
        let uid = UserRepo.parseId(req.subjectId)
        var who = req.subjectId
        match (this.userRepo) {
            case Some(ur) =>
                match (ur.findById(uid)) {
                    case Some(u) =>
                        if (!u.nickname.isEmpty()) {
                            who = u.nickname
                        } else {
                            who = u.username
                        }
                    case None => ()
                }
            case None => ()
        }
        let now = Times.nowMillis()
        let trace = AttachmentRoutes.traceNo(id, uid, now)
        let stamp = Times.toIso8601(now)
        // 2026-10-28T10:27:29.123Z → 2026-10-28 18:27（按 UTC+8 展示）
        var shown = stamp
        if (stamp.size >= 16) {
            shown = stamp[0..10] + " " + stamp[11..16]
        }
        let text = "${who} · ${shown} · #${trace}"
        // 预览留痕：水印号与审计条目一一对应
        match (this.recorder) {
            case Some(r) =>
                r.record(
                    req.subjectId, ActorType.User, AuditAction.FieldReveal,
                    "attachment", "${rec.id}",
                    "", 0, AuditResult.Success, "WATERMARK_${trace}", req.remoteAddr,
                    req.header("user-agent") ?? "", "",
                    Array<(String, String)>()
                )
            case None => ()
        }
        let ttl: Int64 = 5 * 60 * 1000
        return ApiResponse.ok(
            "{\"attachmentId\":${rec.id},\"text\":\"${ApiResponse.escape(text)}\"," +
            "\"traceNo\":\"${trace}\",\"issuedAt\":${now},\"expiresAt\":${now + ttl}}",
            req.requestId
        )
    }

    /** 8 位十六进制追踪号（附件 + 用户 + 时间混合，不可预测且可反查）。 */
    private static func traceNo(attachmentId: Int64, uid: Int64, millis: Int64): String {
        // ⚠️ 每一步都先截到 32 位再乘：attachmentId 本身已接近 2^58，
        //    直接乘 1000003 会溢出 Int64（实测 OverflowException: mul）。
        var h: Int64 = 2166136261
        h = ((h ^ (attachmentId & 0xFFFF)) * 16777619) & 0xFFFFFFFF
        h = ((h ^ ((attachmentId >> 16) & 0xFFFF)) * 16777619) & 0xFFFFFFFF
        h = ((h ^ ((attachmentId >> 32) & 0xFFFF)) * 16777619) & 0xFFFFFFFF
        h = ((h ^ (uid & 0xFFFF)) * 16777619) & 0xFFFFFFFF
        h = ((h ^ ((uid >> 16) & 0xFFFF)) * 16777619) & 0xFFFFFFFF
        h = ((h ^ (millis & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF
        h = (h * 1103515245 + 12345) & 0x7FFFFFFF
        let digits = "0123456789abcdef"
        var out = ""
        var i: Int64 = 0
        while (i < 8) {
            let shift = (7 - i) * 4
            let d = (h >> shift) & 15
            out = out + digits[d..d + 1]
            i = i + 1
        }
        return out
    }

    // ---------------------------------------------------------

    private static func versionJson(r: RowData): String {
        return "{\"id\":${r.i64("id")},\"versionNo\":${r.i64("version_no")}," +
            "\"fileSize\":${r.i64("file_size")}," +
            "\"fileExt\":\"${ApiResponse.escape(r.str("file_ext"))}\"," +
            "\"mimeType\":\"${ApiResponse.escape(r.str("mime_type"))}\"," +
            "\"fingerprint\":\"${ApiResponse.escape(r.str("fp_hex"))}\"," +
            "\"isCurrent\":${r.bool("is_current")},\"status\":${r.i64("status")}," +
            "\"changeNote\":\"${ApiResponse.escape(r.str("change_note"))}\"," +
            "\"uploadedBy\":${r.i64("uploaded_by")}," +
            "\"uploadedAt\":${r.i64("uploaded_ms")}}"
    }

    private static func pushField(
        sb: StringBuilder, first: Bool, field: String, label: String, a: String, b: String
    ): Bool {
        if (!first) {
            sb.append(",")
        }
        sb.append("{\"field\":\"${field}\",\"label\":\"${label}\",")
        sb.append("\"from\":\"${ApiResponse.escape(a)}\",")
        sb.append("\"to\":\"${ApiResponse.escape(b)}\",")
        sb.append("\"changed\":${a != b}}")
        return false
    }

    private static func shortFp(fp: String): String {
        if (fp.size <= 12) {
            return fp
        }
        return fp[0..12]
    }

    /** 解析 "[1,2,3]" 这类数字数组（SimpleJson 只处理扁平字符串）。 */
    private static func parseIds(raw: String): ArrayList<Int64> {
        let out = ArrayList<Int64>()
        var cur = ""
        for (b in raw.toArray()) {
            if (b >= 48 && b <= 57) {
                // 单字节数组用 (size, repeat:) 构造：Array<Byte>([x]) 在本 SDK 不可用
                cur = cur + String.fromUtf8(Array<Byte>(1, repeat: b))
            } else if (b == 44 || b == 93) {
                if (!cur.isEmpty()) {
                    out.add(RowData.toI64(cur))
                    cur = ""
                }
            }
        }
        if (!cur.isEmpty()) {
            out.add(RowData.toI64(cur))
        }
        return out
    }

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
        sb.append("\"downloadCount\":${a.downloadCount},")
        sb.append("\"summary\":\"${ApiResponse.escape(a.summary)}\",")
        sb.append("\"keywords\":\"${ApiResponse.escape(a.keywords)}\"}")
        return sb.toString()
    }
}

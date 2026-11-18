// ============================================================
// ams.api.routes.storagemigration · 存储平台迁移管理接口
//
//   GET  /api/admin/storage/migration            状态 / 进度
//   POST /api/admin/storage/migration/prepare    设定目标方案，开始全量迁移
//   POST /api/admin/storage/migration/run        执行一批（全量 / 增量追赶）
//   POST /api/admin/storage/migration/cancel     取消（切换前）
//   POST /api/admin/storage/migration/cutover    确认切换生效（需重启）
//   POST /api/admin/storage/migration/rollback   回滚到源平台（需重启）
//
// 响应中不含 AK/SK，凭据只通过 deployment.env 传递并脱敏回显。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.app.audit.*
import ams.app.storage.*
import ams.kernel.error.*
import ams.security.audit.*

public class StorageMigrationRoutes {
    private let service: StorageMigrationService
    private let recorder: ?AuditRecorder

    public init(service: StorageMigrationService, recorder!: ?AuditRecorder = None) {
        this.service = service
        this.recorder = recorder
    }

    public func register(router: Router): Unit {
        router.get("/api/admin/storage/migration",
                   { req: ApiRequest => this.status(req) }, requiredPerm: "cfg:read")
        router.post("/api/admin/storage/migration/prepare",
                    { req: ApiRequest => this.prepare(req) }, requiredPerm: "cfg:manage")
        router.post("/api/admin/storage/migration/run",
                    { req: ApiRequest => this.run(req) }, requiredPerm: "cfg:manage")
        router.post("/api/admin/storage/migration/cancel",
                    { req: ApiRequest => this.cancel(req) }, requiredPerm: "cfg:manage")
        router.post("/api/admin/storage/migration/cutover",
                    { req: ApiRequest => this.cutover(req) }, requiredPerm: "cfg:manage")
        router.post("/api/admin/storage/migration/rollback",
                    { req: ApiRequest => this.rollback(req) }, requiredPerm: "cfg:manage")
    }

    private static func boolText(v: Bool): String {
        return if (v) { "true" } else { "false" }
    }

    /**
     * 本地解析批大小，避免 api 层为取一个整数再 import ams.data.repo
     * （分层门禁要求 api → data.repo 的 import 数不增长）。
     * 非法输入返回 -1，由服务层钳制为 1。
     */
    private static func toI64(s: String): Int64 {
        let bytes = s.toArray()
        if (bytes.size == 0) {
            return -1
        }
        var i = 0
        var neg = false
        if (bytes[0] == 45) {
            neg = true
            i = 1
        }
        if (i >= bytes.size) {
            return -1
        }
        var acc: Int64 = 0
        while (i < bytes.size) {
            let b = bytes[i]
            if (b < 48 || b > 57) {
                return -1
            }
            acc = acc * 10 + Int64(b - 48)
            i = i + 1
        }
        return if (neg) { -acc } else { acc }
    }

    private static func jsonOf(s: MigrationStatus): String {
        let sb = StringBuilder()
        sb.append("{\"phase\":\"${ApiResponse.escape(s.phase)}\",")
        sb.append("\"marker\":\"${ApiResponse.escape(s.marker)}\",")
        sb.append("\"targetProvider\":\"${ApiResponse.escape(s.targetProvider)}\",")
        sb.append("\"targetEndpoint\":\"${ApiResponse.escape(s.targetEndpoint)}\",")
        sb.append("\"targetBucket\":\"${ApiResponse.escape(s.targetBucket)}\",")
        sb.append("\"targetRegion\":\"${ApiResponse.escape(s.targetRegion)}\",")
        sb.append("\"targetPathStyle\":${StorageMigrationRoutes.boolText(s.targetPathStyle)},")
        sb.append("\"sourceProvider\":\"${ApiResponse.escape(s.sourceProvider)}\",")
        sb.append("\"cursor\":${s.cursor},\"migrated\":${s.migrated},")
        sb.append("\"failed\":${s.failed},\"total\":${s.total},\"pending\":${s.pending},")
        sb.append("\"dualWriteFailures\":${s.dualWriteFailures},")
        sb.append("\"requiresRestart\":${StorageMigrationRoutes.boolText(s.requiresRestart)}}")
        return sb.toString()
    }

    private func audit(req: ApiRequest, action: String, detail: String): Unit {
        match (this.recorder) {
            case Some(r) =>
                r.record(req.subjectId, ActorType.User, AuditAction.ConfigChange,
                         "storage-migration", action, "", 0, AuditResult.Success, "",
                         req.remoteAddr, "", req.requestId, [("action", action), ("detail", detail)])
            case None => ()
        }
    }

    private func status(req: ApiRequest): ApiResponse {
        return ApiResponse.ok(
            StorageMigrationRoutes.jsonOf(this.service.status()), req.requestId)
    }

    /** body: {provider, endpoint, bucket, region, accessKey, secretKey, pathStyle} */
    private func prepare(req: ApiRequest): ApiResponse {
        let json = match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        let provider = json.get("provider") ?? ""
        let endpoint = json.get("endpoint") ?? ""
        let bucket = json.get("bucket") ?? ""
        let region = json.get("region") ?? ""
        let ak = json.get("accessKey") ?? ""
        let sk = json.get("secretKey") ?? ""
        let styleRaw = json.get("pathStyle") ?? ""
        let style = !(styleRaw == "false" || styleRaw == "0")
        // 必填参数按位置传；仅 `!` 可选参数支持命名实参
        let s = this.service.prepare(
            provider, endpoint, bucket, region, ak, sk, style)
        this.audit(req, "prepare", provider)
        return ApiResponse.ok(StorageMigrationRoutes.jsonOf(s), req.requestId)
    }

    /** body: {batch}（可选，默认 100，上限 500） */
    private func run(req: ApiRequest): ApiResponse {
        let json = match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        var batch: Int64 = 100
        match (json.get("batch")) {
            case Some(v) => batch = StorageMigrationRoutes.toI64(v)
            case None => ()
        }
        let s = this.service.run(batch)
        return ApiResponse.ok(StorageMigrationRoutes.jsonOf(s), req.requestId)
    }

    private func cancel(req: ApiRequest): ApiResponse {
        let s = this.service.cancel()
        this.audit(req, "cancel", s.phase)
        return ApiResponse.ok(StorageMigrationRoutes.jsonOf(s), req.requestId)
    }

    private func cutover(req: ApiRequest): ApiResponse {
        let s = this.service.cutover()
        this.audit(req, "cutover", s.targetProvider)
        return ApiResponse.ok(StorageMigrationRoutes.jsonOf(s), req.requestId)
    }

    private func rollback(req: ApiRequest): ApiResponse {
        let s = this.service.rollback()
        this.audit(req, "rollback", s.sourceProvider)
        return ApiResponse.ok(StorageMigrationRoutes.jsonOf(s), req.requestId)
    }
}

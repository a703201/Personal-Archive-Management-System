// ============================================================
// ams.api.routes.audit · 审计查询接口
//
// 覆盖 FR-AUD-003（链完整性校验）与 FR-AUD-004（多维查询）：
//   GET /api/audit            审计查询（多维过滤 + 分页）
//   GET /api/audit/verify-chain  链完整性校验
//
// 权限：
//   audit:read    查询
//   audit:export  导出（预留）
// ============================================================
package ams.api.routes

import ams.api.http.*
import ams.app.audit.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.id.*
import ams.security.audit.*

/**
 * 审计接口。
 */
public class AuditRoutes {
    private let recorder: AuditRecorder

    public init(recorder: AuditRecorder) {
        this.recorder = recorder
    }

    /**
     * 注册路由。
     */
    public func register(router: Router): Unit {
        router.get("/api/audit", { req: ApiRequest => this.query(req) },
                   requiredPerm: "audit:read")
        router.get("/api/audit/verify-chain", { req: ApiRequest => this.verifyChain(req) },
                   requiredPerm: "audit:read")
    }

    /**
     * 查询审计记录。
     */
    private func query(req: ApiRequest): ApiResponse {
        let actorId = AuditRoutes.intOfQuery(req, "actorId", 0)
        let subjectId = AuditRoutes.intOfQuery(req, "subjectId", 0)
        let category = AuditRoutes.intOfQuery(req, "category", 0)
        let action = match (req.queryParam("action")) {
            case Some(v) => v
            case None => ""
        }
        let result = AuditRoutes.intOfQuery(req, "result", -1)
        let from = AuditRoutes.intOfQuery(req, "from", 0)
        let to = AuditRoutes.intOfQuery(req, "to", 0)
        let ip = match (req.queryParam("clientIp")) {
            case Some(v) => v
            case None => ""
        }
        let page = AuditRoutes.intOfQuery(req, "page", 1)
        let size = AuditRoutes.intOfQuery(req, "size", 20)
        if (size < 1 || size > 200) {
            throw validationError("size", "每页条数须在 1~200 之间")
        }

        let rows = this.recorder.query(actorId, subjectId, category, action, result,
                                       from, to, ip, size, (page - 1) * size)
        let total = this.recorder.count(actorId, subjectId, category, action, result,
                                        from, to, ip)
        let sb = StringBuilder()
        sb.append("{\"items\":[")
        var first = true
        for (r in rows.all().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append(AuditRoutes.toJson(r))
        }
        sb.append("],\"total\":${total},\"page\":${page},\"size\":${size}}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * 链完整性校验（FR-AUD-003）。
     */
    private func verifyChain(req: ApiRequest): ApiResponse {
        let from = AuditRoutes.intOfQuery(req, "from", 1)
        let limit = AuditRoutes.intOfQuery(req, "limit", 1000)
        if (limit < 1 || limit > 10000) {
            throw validationError("limit", "校验条数须在 1~10000 之间")
        }
        let result = this.recorder.verifyChain(from, limit)
        let sb = StringBuilder()
        match (result) {
            case ChainVerifyResult.Ok =>
                sb.append("{\"status\":\"ok\",\"message\":\"链完整\"}")
            case ChainVerifyResult.Broken(seq) =>
                sb.append("{\"status\":\"broken\",\"message\":\"链断裂于第 ${seq} 条\",\"brokenAt\":${seq}}")
            case ChainVerifyResult.Tampered(seq) =>
                sb.append("{\"status\":\"tampered\",\"message\":\"第 ${seq} 条被篡改\",\"tamperedAt\":${seq}}")
            case ChainVerifyResult.Missing(seq) =>
                sb.append("{\"status\":\"missing\",\"message\":\"第 ${seq} 条缺失\",\"missingAt\":${seq}}")
        }
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * 行记录 → JSON。
     */
    private static func toJson(r: RowData): String {
        let sb = StringBuilder()
        sb.append("{\"chainSeq\":${r.i64("chain_seq")},")
        sb.append("\"actorId\":\"${r.i64("actor_id")}\",")
        sb.append("\"action\":\"${AuditRoutes.escape(r.str("action"))}\",")
        sb.append("\"actionDesc\":\"${AuditRoutes.escape(r.str("action_desc"))}\",")
        sb.append("\"targetType\":\"${AuditRoutes.escape(r.getOpt("target_type") ?? "")}\",")
        sb.append("\"targetId\":\"${AuditRoutes.escape(r.getOpt("target_id") ?? "")}\",")
        sb.append("\"subjectId\":\"${r.i64("subject_id")}\",")
        sb.append("\"category\":${r.i64("category")},")
        sb.append("\"result\":${r.i64("result")},")
        sb.append("\"errorCode\":\"${AuditRoutes.escape(r.getOpt("error_code") ?? "")}\",")
        sb.append("\"clientIp\":\"${AuditRoutes.escape(r.getOpt("client_ip") ?? "")}\",")
        sb.append("\"traceId\":\"${AuditRoutes.escape(r.getOpt("trace_id") ?? "")}\",")
        sb.append("\"occurredAt\":${r.i64("occurred_ms")}}")
        return sb.toString()
    }

    /**
     * JSON 字符串转义。
     */
    private static func escape(s: String): String {
        return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n")
    }

    /**
     * 取查询串中的整数参数。
     */
    private static func intOfQuery(req: ApiRequest, key: String, def: Int64): Int64 {
        match (req.queryParam(key)) {
            case Some(v) =>
                if (v.isEmpty()) {
                    return def
                }
                return RowData.toI64(v)
            case None => return def
        }
    }
}

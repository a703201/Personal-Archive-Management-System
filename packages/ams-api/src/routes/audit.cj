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

import std.collection.*

import ams.api.http.*
import ams.app.audit.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.id.*
import ams.kernel.log.*
import ams.kernel.time.*
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
        // FR-AUD-005 审计报告导出（带链校验结论）
        router.get("/api/audit/report", { req: ApiRequest => this.report(req) },
                   requiredPerm: "audit:export")
    }

    /**
     * 自审计（FR-AUD-009）：「看了审计」这件事本身也写一条审计。
     *
     * 【为什么必须有】
     *   审计是「谁干了什么」的唯一证据来源。但如果「谁翻过审计」不留痕，
     *   审计员/管理员查看敏感操作记录这一行为就**没有任何证据** ——
     *   证据链在这里断掉，审计系统自己成了盲区。
     *
     * 【为什么不对自审计再自审计】
     *   `record()` 是写不是查，不经过这三个处理器，不会递归。
     *   每次查询只多落一条记录，量级可控（分页查询本身就是低频管理动作）。
     *
     * 【为什么尽力而为】
     *   数据已经查出来、响应也构造好了，写审计失败不该让用户白查一次；
     *   但这属于安全能力降级，不能静默 —— 记 WARN 日志便于排障。
     */
    private func selfAudit(req: ApiRequest, target: String, detail: String): Unit {
        try {
            let ip = match (req.header("x-forwarded-for")) {
                case Some(v) => v
                case None => req.remoteAddr
            }
            let ua = match (req.header("user-agent")) {
                case Some(v) => v
                case None => ""
            }
            this.recorder.record(
                req.subjectId,
                ActorType.User,
                AuditAction.AuditQuery,
                "audit_log",
                target,
                "",
                0,
                AuditResult.Success,
                "",
                ip,
                ua,
                req.requestId,
                [("target", target), ("detail", detail)]
            )
        } catch (e: Exception) {
            AuditRoutes.warn("audit.self_audit_failed", e.message)
        }
    }

    private static func warn(event: String, reason: String): Unit {
        let log = Log.get()
        log.warn(event, None, [("reason", reason)])
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
        this.selfAudit(req, "query", "page=${page};size=${size};total=${total}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * 链完整性校验（FR-AUD-003）。
     *
     * mode=strict（默认）：段首 prev_hash 必须等于段前记录的哈希 ——
     *   能证明整条链未被删改，但链头有归档/历史断层时必然报 Broken。
     * mode=segment：以段首记录自身的 prev_hash 为锚点，只证明**段内**连续
     *   且内容未改；响应里 anchored=false 明示「段首未被锚定」。
     */
    private func verifyChain(req: ApiRequest): ApiResponse {
        let from = AuditRoutes.intOfQuery(req, "from", 1)
        let limit = AuditRoutes.intOfQuery(req, "limit", 1000)
        if (limit < 1 || limit > 10000) {
            throw validationError("limit", "校验条数须在 1~10000 之间")
        }
        let mode = match (req.queryParam("mode")) {
            case Some(v) => v
            case None => "strict"
        }
        let sb = StringBuilder()
        if (mode == "segment") {
            let (result, checked) = this.recorder.verifyChainSegment(from, limit)
            sb.append("{\"mode\":\"segment\",\"anchored\":false,\"checked\":${checked},")
            sb.append(AuditRoutes.chainVerdict(result))
            sb.append("}")
        } else {
            let result = this.recorder.verifyChain(from, limit)
            sb.append("{\"mode\":\"strict\",\"anchored\":true,")
            sb.append(AuditRoutes.chainVerdict(result))
            sb.append("}")
        }
        this.selfAudit(req, "verify-chain", "from=${from};limit=${limit};mode=${mode}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * 链校验结论 → JSON 片段（不含外层花括号）。
     */
    private static func chainVerdict(result: ChainVerifyResult): String {
        var text = ""
        match (result) {
            case ChainVerifyResult.Ok =>
                text = "\"status\":\"ok\",\"message\":\"链完整\""
            case ChainVerifyResult.Broken(seq) =>
                text = "\"status\":\"broken\",\"message\":\"链断裂于第 ${seq} 条\",\"brokenAt\":${seq}"
            case ChainVerifyResult.Tampered(seq) =>
                text = "\"status\":\"tampered\",\"message\":\"第 ${seq} 条被篡改\",\"tamperedAt\":${seq}"
            case ChainVerifyResult.Missing(seq) =>
                text = "\"status\":\"missing\",\"message\":\"第 ${seq} 条缺失\",\"missingAt\":${seq}"
        }
        return text
    }

    /**
     * 审计报告导出（FR-AUD-005）。
     *
     * 产出 CSV：首部为元信息与**链校验结论**，随后是筛选命中的记录明细。
     * 导出行为本身写审计（FR-AUD-001 覆盖「导出」）。
     * 查询参数与 /api/audit 一致，另加 limit（默认/上限 5000）。
     */
    private func report(req: ApiRequest): ApiResponse {
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
        var limit = AuditRoutes.intOfQuery(req, "limit", 5000)
        if (limit < 1 || limit > 5000) {
            limit = 5000
        }

        // 链校验结论（全局，最多 10000 条）
        let chain = this.recorder.verifyChain(1, 10000)
        let chainText = match (chain) {
            case ChainVerifyResult.Ok => "链完整"
            case ChainVerifyResult.Broken(seq) => "链断裂于第 ${seq} 条"
            case ChainVerifyResult.Tampered(seq) => "第 ${seq} 条被篡改"
            case ChainVerifyResult.Missing(seq) => "第 ${seq} 条缺失"
        }

        let rows = this.recorder.query(actorId, subjectId, category, action, result,
                                       from, to, ip, limit, 0)
        let nowMs = Times.nowMillis()
        let sb = StringBuilder()
        sb.append("# AMS 审计报告\n")
        sb.append("# 生成时间(ms): ${nowMs}\n")
        sb.append("# 筛选: actorId=${actorId} subjectId=${subjectId} category=${category} action=${action} result=${result} from=${from} to=${to} clientIp=${ip}\n")
        sb.append("# 链校验结论: ${chainText}\n")
        sb.append("chain_seq,occurred_ms,actor_id,action,action_desc,target_type,target_id,subject_id,category,result,error_code,client_ip,trace_id\n")
        for (r in rows.all().iterator()) {
            sb.append("${r.i64("chain_seq")},")
            sb.append("${r.i64("occurred_ms")},")
            sb.append("${r.i64("actor_id")},")
            sb.append(AuditRoutes.csvCell(r.str("action")))
            sb.append(",")
            sb.append(AuditRoutes.csvCell(r.str("action_desc")))
            sb.append(",")
            sb.append(AuditRoutes.csvCell(r.getOpt("target_type") ?? ""))
            sb.append(",")
            sb.append(AuditRoutes.csvCell(r.getOpt("target_id") ?? ""))
            sb.append(",")
            sb.append("${r.i64("subject_id")},")
            sb.append("${r.i64("category")},")
            sb.append("${r.i64("result")},")
            sb.append(AuditRoutes.csvCell(r.getOpt("error_code") ?? ""))
            sb.append(",")
            sb.append(AuditRoutes.csvCell(r.getOpt("client_ip") ?? ""))
            sb.append(",")
            sb.append(AuditRoutes.csvCell(r.getOpt("trace_id") ?? ""))
            sb.append("\n")
        }

        // 导出留痕（FR-AUD-001：导出属敏感操作）
        this.recorder.record(
            req.subjectId,
            ActorType.User,
            AuditAction.DataExport,
            "audit",
            "",
            "",
            0,
            AuditResult.Success,
            "",
            req.remoteAddr,
            req.header("user-agent") ?? "",
            "",
            [("scope", "audit-report"), ("rows", "${limit}"), ("chain", chainText)]
        )

        let h = HashMap<String, String>()
        h["Content-Type"] = "text/csv; charset=utf-8"
        h["Content-Disposition"] = "attachment; filename=\"audit-report.csv\""
        this.selfAudit(req, "report", "rows=${limit};chain=${chainText}")
        return ApiResponse(200, sb.toString(), h)
    }

    /**
     * CSV 单元格转义。
     */
    private static func csvCell(s: String): String {
        if (s.contains(",") || s.contains("\"") || s.contains("\n")) {
            return "\"" + s.replace("\"", "\"\"") + "\""
        }
        return s
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

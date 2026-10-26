// ============================================================
// ams.app.audit · 审计应用服务
//
// 职责（FR-AUD-001/002/003）：
//   - 记录敏感操作（统一入口，业务层只调 record(...)）
//   - 维护哈希链：定位链尾 → 计算 record_hash → 落库
//   - 链完整性校验（供 /api/audit/verify-chain 调用）
//
// 【为什么需要这一层】
//   AuditService（ams-security）实现了哈希算法与校验方法，
//   但此前**从未被业务调用** —— 审计只定义不落库。
//   本服务把「查链尾 → 算哈希 → 落库」串起来，
//   让所有敏感操作终于留下不可篡改的痕迹。
//
// 依赖：ams.data.repo（落库/查询）、ams.security.audit（哈希与校验）
// ============================================================
package ams.app.audit

import std.collection.*

import ams.crypto.provider.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.time.*
import ams.security.audit.*

/**
 * 审计服务。
 */
public class AuditRecorder {
    private let repo: AuditRepo
    private let audit: AuditService

    public init(repo: AuditRepo, provider: CryptoProvider) {
        this.repo = repo
        this.audit = AuditService(provider)
    }

    /**
     * 记录一条审计。
     *
     * @param actorId      操作者 ID（字符串；空 = 系统）
     * @param actorType    操作者类型
     * @param action       动作码
     * @param targetType   目标类型
     * @param targetId     目标 ID
     * @param subjectId    所属主体 ID（空 = 无）
     * @param category     分类码（0 = 无）
     * @param result       结果
     * @param errorCode    错误码
     * @param clientIp     客户端 IP
     * @param userAgent    客户端 UA
     * @param traceId      链路追踪 ID
     * @param detail       详情键值对
     */
    public func record(
        actorId: String,
        actorType: ActorType,
        action: AuditAction,
        targetType: String,
        targetId: String,
        subjectId: String,
        category: Int64,
        result: AuditResult,
        errorCode: String,
        clientIp: String,
        userAgent: String,
        traceId: String,
        detail: Array<(String, String)>
    ): Unit {
        // 1) 定位链尾
        let (seq, prevHash) = this.repo.chainTail()
        let nextSeq = seq + 1

        // 2) 构造条目并计算哈希
        // occurredAt 用**应用层**的毫秒值，落库时同时写入 occurred_ms 列 ——
        // 链校验时读该列，保证重算哈希与落库时**逐毫秒一致**。
        // （从 occurred_at 列换算会因微秒精度四舍五入而差 1，导致误报 broken。）
        let occurredMs = Times.nowMillis()

        // actorId / subjectId 统一为**数字串**（空 → "0"）：
        // 落库时写数字、校验时读回再转字符串，两边必须一致。
        let actorKey = AuditRecorder.toIdString(actorId)
        let subjectKey = AuditRecorder.toIdString(subjectId)

        let entry = AuditEntry(
            nextSeq,
            actorKey,
            actorType,
            action,
            action.code(),
            targetType,
            targetId,
            subjectKey,
            category,
            result,
            errorCode,
            clientIp,
            userAgent,
            traceId,
            detail,
            occurredMs
        )
        let hash = match (this.audit.computeHash(entry, prevHash)) {
            case CryptoResult.Ok(h) => h
            case CryptoResult.Err(e) => throw e
        }

        // 3) 落库（只 INSERT）
        this.repo.insert(
            nextSeq,
            AuditRecorder.toId(actorId),
            actorType.toCode(),
            action.code(),
            action.code(),
            targetType,
            targetId,
            AuditRecorder.toId(subjectId),
            category,
            result.toCode(),
            errorCode,
            clientIp,
            userAgent,
            traceId,
            AuditRecorder.detailToJson(detail),
            occurredMs,
            prevHash,
            hash
        )
    }

    /**
     * 链完整性校验（FR-AUD-003）。
     *
     * @param fromSeq 从哪一条开始校验（1 = 从头）
     * @param limit   最多校验多少条
     */
    public func verifyChain(fromSeq: Int64, limit: Int64): ChainVerifyResult {
        // 子段校验时，用「段前一条记录的 record_hash」作为锚点：
        // 本段首条的 prev_hash 实际等于段前记录的 record_hash，
        // 若以创世哈希为锚点，首条记录会被误判 Broken。
        // 段前记录不存在（gap 或 from=1）时回退到创世哈希（首条 prevHash 应即创世）。
        let startPrev = if (fromSeq > 1) {
            match (this.repo.recordHashAt(fromSeq - 1)) {
                case Some(h) => h
                case None => AuditService.genesisHash()
            }
        } else {
            AuditService.genesisHash()
        }
        let rows = this.repo.listChain(fromSeq, limit)
        let records = ArrayList<AuditRecord>()
        for (r in rows.all().iterator()) {
            records.add(this.toRecord(r))
        }
        return this.audit.verifyChainFrom(records.toArray(), startPrev)
    }

    /**
     * 查询审计记录（FR-AUD-004）。
     */
    public func query(
        actorId: Int64,
        subjectId: Int64,
        category: Int64,
        action: String,
        result: Int64,
        fromMillis: Int64,
        toMillis: Int64,
        clientIp: String,
        limit: Int64,
        offset: Int64
    ): RowSet {
        return this.repo.query(actorId, subjectId, category, action, result,
                               fromMillis, toMillis, clientIp, limit, offset)
    }

    /**
     * 统计审计记录数。
     */
    public func count(
        actorId: Int64,
        subjectId: Int64,
        category: Int64,
        action: String,
        result: Int64,
        fromMillis: Int64,
        toMillis: Int64,
        clientIp: String
    ): Int64 {
        return this.repo.count(actorId, subjectId, category, action, result,
                               fromMillis, toMillis, clientIp)
    }

    /**
     * 行记录 → AuditRecord（用于链校验）。
     */
    private func toRecord(r: RowData): AuditRecord {
        let entry = AuditEntry(
            r.i64("chain_seq"),
            "${r.i64("actor_id")}",
            AuditRecorder.toActorType(r.i64("actor_type")),
            AuditRecorder.toAction(r.str("action")),
            r.str("action_desc"),
            r.getOpt("target_type") ?? "",
            r.getOpt("target_id") ?? "",
            "${r.i64("subject_id")}",
            r.i64("category"),
            AuditRecorder.toResult(r.i64("result")),
            r.getOpt("error_code") ?? "",
            r.getOpt("client_ip") ?? "",
            r.getOpt("user_agent") ?? "",
            r.getOpt("trace_id") ?? "",
            AuditRecorder.jsonToDetail(r.getOpt("detail") ?? ""),
            r.i64("occurred_ms")
        )
        return AuditRecord(
            entry,
            AuditRepo.fromHex(r.getOpt("prev_hash_hex") ?? ""),
            AuditRepo.fromHex(r.getOpt("record_hash_hex") ?? "")
        )
    }

    // ---- 转换工具 ----

    /**
     * 字符串 ID → 规范化数字串（空 → "0"）。
     *
     * 哈希链的规范化要求「落库时的字符串」与「校验时重建的字符串」**完全一致**，
     * 故统一走这里转换。
     */
    private static func toIdString(s: String): String {
        if (s.isEmpty()) {
            return "0"
        }
        return "${AuditRecorder.toId(s)}"
    }

    /**
     * 字符串 ID → 数字（空串或非数字 → 0）。
     */
    private static func toId(s: String): Int64 {
        if (s.isEmpty()) {
            return 0
        }
        return RowData.toI64(s)
    }

    /**
     * 详情 → JSON 字符串。
     */
    private static func detailToJson(detail: Array<(String, String)>): String {
        if (detail.isEmpty()) {
            return "{}"
        }
        let sb = StringBuilder()
        sb.append("{")
        var first = true
        for ((k, v) in detail) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("\"${k}\":\"${v}\"")
        }
        sb.append("}")
        return sb.toString()
    }

    /**
     * JSON 字符串 → 详情键值对（极简解析，够用即可）。
     */
    private static func jsonToDetail(json: String): Array<(String, String)> {
        let out = ArrayList<(String, String)>()
        let t = json.trimStart().trimEnd()
        if (!t.startsWith("{") || !t.endsWith("}")) {
            return out.toArray()
        }
        let inner = t[1..t.size - 1]
        if (inner.isEmpty()) {
            return out.toArray()
        }
        for (part in inner.split(",")) {
            let kv = part.split(":", 2)
            if (kv.size < 2) {
                continue
            }
            let k = AuditRecorder.unquote(kv[0].trimStart().trimEnd())
            let v = AuditRecorder.unquote(kv[1].trimStart().trimEnd())
            if (!k.isEmpty()) {
                out.add((k, v))
            }
        }
        return out.toArray()
    }

    /**
     * 去引号。
     */
    private static func unquote(s: String): String {
        if (s.size >= 2 && s.startsWith("\"") && s.endsWith("\"")) {
            return s[1..s.size - 1]
        }
        return s
    }

    /**
     * 码 → 操作者类型。
     */
    private static func toActorType(code: Int64): ActorType {
        if (code == 1) {
            return ActorType.System
        }
        if (code == 2) {
            return ActorType.Anonymous
        }
        return ActorType.User
    }

    /**
     * 码 → 结果。
     */
    private static func toResult(code: Int64): AuditResult {
        if (code == 1) {
            return AuditResult.Failure
        }
        return AuditResult.Success
    }

    /**
     * 动作码 → AuditAction。
     *
     * 审计动作是**封闭枚举**，无法为未知码构造条目。
     * 未知码（如历史版本遗留）统一归为 Unknown —— 记录仍然落库，
     * 链校验时该条的 action 字段会与原始计算不一致而被判为 Tampered。
     * 这是**有意的**：宁可让链校验报出异常，也不要静默改写历史记录。
     */
    private static func toAction(code: String): AuditAction {
        return AuditAction.fromCode(code)
    }
}

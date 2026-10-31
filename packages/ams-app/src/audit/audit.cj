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
import ams.kernel.util.*
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
     * 段内完整性校验（无锚点模式，FR-AUD-003 补充）。
     *
     * 与 [verifyChain] 的差别：**不要求**段首 prev_hash 等于段前记录的哈希，
     * 而以段首记录自身的 prev_hash 作为锚点。
     *
     * 适用场景：审计链头部已按留存策略归档、或历史上确有断层（记录被删除）时，
     * 仍需证明「从 fromSeq 起的这一段」内部连续且内容未被改动。
     * 用默认模式校验这类分段会一律返回 Broken（段首无前驱可比），
     * 无法把「段内完好」与「段内被改」区分开。
     *
     * 代价：无法证明段首本身未被整体替换 —— 故返回值必须向调用方明示
     * “anchored=false”，由人判断是否接受。
     *
     * @return (校验结论, 本段实际校验条数)
     */
    public func verifyChainSegment(fromSeq: Int64, limit: Int64): (ChainVerifyResult, Int64) {
        let rows = this.repo.listChain(fromSeq, limit)
        let records = ArrayList<AuditRecord>()
        for (r in rows.all().iterator()) {
            records.add(this.toRecord(r))
        }
        if (records.isEmpty()) {
            return (ChainVerifyResult.Ok, 0)
        }
        let anchor = records[0].prevHash
        return (this.audit.verifyChainFrom(records.toArray(), anchor), records.size)
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
    /**
     * 详情键值对 → JSON 字符串。
     *
     * ⚠️ 必须转义：detail 列是 jsonb，裸写 `"` 会让 jsonb 解析失败；
     *    控制字符会被 jsonb 改写为 \uXXXX —— 两者都会使**校验时**读回的
     *    值与原值不同，从而让哈希链误报「被篡改」。
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
            sb.append("\"")
            sb.append(jsonEscape(k))
            sb.append("\":\"")
            sb.append(jsonEscape(v))
            sb.append("\"")
        }
        sb.append("}")
        return sb.toString()
    }

    /**
     * JSON 字符串 → 详情键值对。
     *
     * 交给 ams.kernel.util.jsonFlatEntries 做**扫描式**解析：
     *   - 引号内的 , 与 : 不切分（值里出现半角逗号不再截断）；
     *   - 正确处理 \" \\ \n \r \t \uXXXX 等转义；
     *   - 首尾空白用 trimSpace（String.trimStart/trimEnd 在本 SDK 是空实现）。
     *
     * 早前用 `split(",")` + `split(":", 2)` + `trimStart()` 实现，
     * 因 trimStart 空实现，把 `{"k": "v"}` 还原成 ` "k"= "v"`，
     * 使**每条带 detail 的记录**校验时重算哈希都与落库值不符，
     * /api/audit/verify-chain 因此对真实数据误报「被篡改」。
     */
    private static func jsonToDetail(json: String): Array<(String, String)> {
        return jsonFlatEntries(json)
    }

    /**
     * 码 → 操作者类型。
     *
     * 必须覆盖 ActorType.toCode() 的**全部**取值（0/1/2/3），
     * 否则漏掉的分支会退回 User(0)，使该类记录校验时哈希不符。
     */
    private static func toActorType(code: Int64): ActorType {
        if (code == 1) {
            return ActorType.System
        }
        if (code == 2) {
            return ActorType.Anonymous
        }
        if (code == 3) {
            return ActorType.Service
        }
        return ActorType.User
    }

    /**
     * 码 → 结果。
     */
    /**
     * 码 → 结果。
     *
     * 必须与 AuditResult.toCode() 完全互逆（0=Success / 1=Failure / 2=Denied）。
     * 早前只判 code==1 就返回 Failure、其余一律 Success，
     * 于是 result=2（Denied）的记录在校验时被还原成 0，
     * 规范化串随之改变 —— 所有「被拒绝」的审计记录都被误判「被篡改」
     * （实测：TOTP 挑战期的 auth.login_failed 即 result=2）。
     */
    private static func toResult(code: Int64): AuditResult {
        if (code == 1) {
            return AuditResult.Failure
        }
        if (code == 2) {
            return AuditResult.Denied
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

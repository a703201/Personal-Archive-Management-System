// ============================================================
// ams.data.repo.audit · 审计仓储
//
// 职责（FR-AUD-001/002/003/004/006）：
//   - 落库：只 INSERT（审计表不可篡改，FR-AUD-006）
//   - 哈希链：按 chain_seq 顺序追加，每条记录携带 prev_hash + record_hash
//   - 查询：多维过滤（操作者/主体/分类/动作/结果/时间/IP）+ 分页
//   - 链完整性：取全链供 verifyChain 校验
//
// 【不可篡改的设计】
//   ① 本仓储**只提供 insert**，不提供 update / delete；
//   ② 应用账号在数据库层被回收 UPDATE/DELETE 权限
//      （见 db/migrations/002_audit_schema_fix.sql 的 REVOKE 语句）；
//   ③ chain_seq 唯一索引 + record_hash 唯一索引 → 改一条即断链，可检出。
// ============================================================
package ams.data.repo

import std.collection.*
import std.database.sql.*
import stdx.encoding.hex.*

import ams.data.db.*
import ams.kernel.error.*
import ams.kernel.id.*

/**
 * 审计仓储。
 */
public class AuditRepo {
    private let db: Database

    public init(db: Database) {
        this.db = db
    }

    /**
     * 追加一条审计记录（**只 INSERT**）。
     *
     * @param chainSeq   链序号（从 1 开始连续）
     * @param actorId    操作者 ID（0 = 系统）
     * @param actorType  操作者类型（0 = 用户；1 = 系统；2 = 匿名）
     * @param action     动作码（如 "archive.export"）
     * @param actionDesc 动作描述
     * @param targetType 目标类型
     * @param targetId   目标 ID
     * @param subjectId  所属主体 ID（0 = 无）
     * @param category   分类码（0 = 无）
     * @param result     结果（0 = 成功；1 = 失败）
     * @param errorCode  错误码
     * @param clientIp   客户端 IP
     * @param userAgent  客户端 UA
     * @param traceId    链路追踪 ID
     * @param detailJson 详情（JSON 字符串）
     * @param prevHash   前一条记录的哈希（32 字节）
     * @param recordHash 本条记录的哈希（32 字节）
     */
    public func insert(
        chainSeq: Int64,
        actorId: Int64,
        actorType: Int64,
        action: String,
        actionDesc: String,
        targetType: String,
        targetId: String,
        subjectId: Int64,
        category: Int64,
        result: Int64,
        errorCode: String,
        clientIp: String,
        userAgent: String,
        traceId: String,
        detailJson: String,
        occurredMs: Int64,
        prevHash: Array<Byte>,
        recordHash: Array<Byte>
    ): Int64 {
        let id = Ids.next()
        let sql = "INSERT INTO aud_logs (" +
                  "id, chain_seq, actor_id, actor_type, action, action_desc, " +
                  "target_type, target_id, subject_id, category, result, error_code, " +
                  "client_ip, user_agent, trace_id, detail, occurred_ms, prev_hash, record_hash, occurred_at" +
                  ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?::jsonb, ?, ?, ?, " +
                  "CURRENT_TIMESTAMP)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, id)
            st.set(1, chainSeq)
            st.set(2, actorId)
            st.set(3, actorType)
            st.set(4, action)
            st.set(5, actionDesc)
            st.set(6, targetType)
            st.set(7, targetId)
            st.set(8, subjectId)
            st.set(9, category)
            st.set(10, result)
            st.set(11, errorCode)
            st.set(12, clientIp)
            st.set(13, userAgent)
            st.set(14, traceId)
            st.set(15, detailJson)
            st.set(16, occurredMs)
            st.set(17, prevHash)
            st.set(18, recordHash)
            st.update()
            return id
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 取链尾（最后一条记录的 chain_seq 与 record_hash）。
     *
     * 用于追加下一条时定位链位置。链为空时返回 (0, 全零哈希)。
     */
    public func chainTail(): (Int64, Array<Byte>) {
        // 用 encode(record_hash, 'hex') 取回 —— RowData 只能承载字符串，
        // BYTEA 列直接读会出问题；十六进制串再解码为字节。
        let sql = "SELECT chain_seq, encode(record_hash, 'hex') AS record_hash_hex " +
                  "FROM aud_logs ORDER BY chain_seq DESC LIMIT 1"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            let rows = readRows(st.query())
            if (rows.isEmpty()) {
                return (0, Array<Byte>(32, repeat: 0u8))
            }
            let r = rows.at(0)
            return (r.i64("chain_seq"), AuditRepo.fromHex(r.str("record_hash_hex")))
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 取指定序号记录的 record_hash（十六进制解码为字节）。
     *
     * 用于「子段校验」：校验 [from, ...) 段时，需要段前一条记录的
     * record_hash 作为本段首条 prev_hash 的期望值（锚点），
     * 否则首条记录的 prev_hash（= 段前记录的哈希）会与创世哈希比较而误判 Broken。
     *
     * @return 找到返回 Some(哈希)；序号不存在或哈希为空返回 None
     */
    public func recordHashAt(seq: Int64): Option<Array<Byte>> {
        let sql = "SELECT encode(record_hash, 'hex') AS record_hash_hex " +
                  "FROM aud_logs WHERE chain_seq = ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, seq)
            let rows = readRows(st.query())
            if (rows.isEmpty()) {
                return None
            }
            let hex = rows.at(0).str("record_hash_hex")
            if (hex.isEmpty()) {
                return None
            }
            return Some(AuditRepo.fromHex(hex))
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 取全链（按序号升序），供完整性校验。
     */
    public func listChain(fromSeq: Int64, limit: Int64): RowSet {
        let sql = "SELECT chain_seq, actor_id, actor_type, action, action_desc, " +
                  "target_type, target_id, subject_id, category, result, error_code, " +
                  "client_ip, user_agent, trace_id, detail::text AS detail, " +
                  "encode(prev_hash, 'hex') AS prev_hash_hex, " +
                  "encode(record_hash, 'hex') AS record_hash_hex, " +
                  "occurred_ms " +
                  "FROM aud_logs WHERE chain_seq >= ? ORDER BY chain_seq ASC LIMIT ?"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, fromSeq)
            st.set(1, limit)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 查询审计记录（多维过滤 + 分页）。
     *
     * 过滤维度对应 FR-AUD-004：操作者 / 主体 / 分类 / 动作 / 结果 / 时间 / IP。
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
        var sql = "SELECT id, chain_seq, actor_id, actor_type, action, action_desc, " +
                  "target_type, target_id, subject_id, category, result, error_code, " +
                  "client_ip, user_agent, trace_id, detail::text AS detail, " +
                  "encode(prev_hash, 'hex') AS prev_hash_hex, " +
                  "encode(record_hash, 'hex') AS record_hash_hex, " +
                  "occurred_ms " +
                  "FROM aud_logs WHERE 1=1"
        var params = ArrayList<SqlParam>()
        if (actorId > 0) {
            sql += " AND actor_id = ?"
            params.add(SqlParam.Num(actorId))
        }
        if (subjectId > 0) {
            sql += " AND subject_id = ?"
            params.add(SqlParam.Num(subjectId))
        }
        if (category > 0) {
            sql += " AND category = ?"
            params.add(SqlParam.Num(category))
        }
        if (!action.isEmpty()) {
            sql += " AND action = ?"
            params.add(SqlParam.Str(action))
        }
        if (result >= 0) {
            sql += " AND result = ?"
            params.add(SqlParam.Num(result))
        }
        if (fromMillis > 0) {
            sql += " AND occurred_at >= TO_TIMESTAMP(? / 1000.0)"
            params.add(SqlParam.Num(fromMillis))
        }
        if (toMillis > 0) {
            sql += " AND occurred_at <= TO_TIMESTAMP(? / 1000.0)"
            params.add(SqlParam.Num(toMillis))
        }
        if (!clientIp.isEmpty()) {
            sql += " AND client_ip = ?"
            params.add(SqlParam.Str(clientIp))
        }
        sql += " ORDER BY chain_seq DESC LIMIT ? OFFSET ?"
        params.add(SqlParam.Num(limit))
        params.add(SqlParam.Num(offset))
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            AuditRepo.bind(st, params)
            return readRows(st.query())
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * 统计审计记录数（分页用，条件同 query）。
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
        var sql = "SELECT COUNT(*) AS n FROM aud_logs WHERE 1=1"
        var params = ArrayList<SqlParam>()
        if (actorId > 0) {
            sql += " AND actor_id = ?"
            params.add(SqlParam.Num(actorId))
        }
        if (subjectId > 0) {
            sql += " AND subject_id = ?"
            params.add(SqlParam.Num(subjectId))
        }
        if (category > 0) {
            sql += " AND category = ?"
            params.add(SqlParam.Num(category))
        }
        if (!action.isEmpty()) {
            sql += " AND action = ?"
            params.add(SqlParam.Str(action))
        }
        if (result >= 0) {
            sql += " AND result = ?"
            params.add(SqlParam.Num(result))
        }
        if (fromMillis > 0) {
            sql += " AND occurred_at >= TO_TIMESTAMP(? / 1000.0)"
            params.add(SqlParam.Num(fromMillis))
        }
        if (toMillis > 0) {
            sql += " AND occurred_at <= TO_TIMESTAMP(? / 1000.0)"
            params.add(SqlParam.Num(toMillis))
        }
        if (!clientIp.isEmpty()) {
            sql += " AND client_ip = ?"
            params.add(SqlParam.Str(clientIp))
        }
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            AuditRepo.bind(st, params)
            let rows = readRows(st.query())
            if (rows.isEmpty()) {
                return 0
            }
            return rows.at(0).i64("n")
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * FR-AUD-008：将 aud_logs 中早于 beforeMillis 的记录**复制**到冷存 aud_logs_archive。
     *
     * 关键点：
     *   - aud_logs 不可篡改（应用账号无 UPDATE/DELETE，见 002 迁移），
     *     故留存策略只能「冷存归档」—— 把超期热表记录**复制**到 aud_logs_archive，
     *     而不能从热表删除（热表保留全量以满足哈希链完整性）。
     *   - 幂等：以 id 为键，NOT EXISTS 跳过已归档记录，可重复执行。
     *
     * @param beforeMillis 时间分界（毫秒 epoch）；早于它的记录进入归档
     * @return 本次实际复制（归档）的记录数
     */
    public func archiveExpired(beforeMillis: Int64): Int64 {
        // 列顺序与 aud_logs 完全一致（含 occurred_at、prev_hash、record_hash 等），
        // 直接整行复制，避免遗漏或类型错位。
        let sql = "INSERT INTO aud_logs_archive (" +
                  "id, chain_seq, actor_id, actor_type, action, action_desc, " +
                  "target_type, target_id, subject_id, category, result, error_code, " +
                  "client_ip, user_agent, trace_id, detail, prev_hash, record_hash, " +
                  "occurred_ms, occurred_at) " +
                  "SELECT id, chain_seq, actor_id, actor_type, action, action_desc, " +
                  "target_type, target_id, subject_id, category, result, error_code, " +
                  "client_ip, user_agent, trace_id, detail, prev_hash, record_hash, " +
                  "occurred_ms, occurred_at " +
                  "FROM aud_logs " +
                  "WHERE occurred_ms < ? " +
                  "AND NOT EXISTS (SELECT 1 FROM aud_logs_archive a WHERE a.id = aud_logs.id)"
        let c = this.db.connect()
        try {
            let st = c.prepareStatement(sql)
            st.set(0, beforeMillis)
            return st.update().rowCount
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    /**
     * FR-AUD-007：扫描自 fromMillis 起的高危操作信号，供实时告警使用。
     *
     * 覆盖四类（PRD §5.9 FR-AUD-007）：
     *   ① 暴力破解 —— 同一 IP 登录失败次数 ≥ 阈值（默认 5）
     *   ② 批量导出 —— 动作含 export 且失败（result = 1）
     *   ③ 越权尝试 —— authz / perm 类动作失败
     *   ④ 密钥操作 —— key 类动作失败
     *
     * 返回行（合并）：risk_type, client_ip, action, cnt, last_ms
     *   risk_type ∈ {brute_force, batch_export, key_op, privilege_escalation}
     */
    public func scanHighRisk(fromMillis: Int64): RowSet {
        let out = RowSet()
        let c = this.db.connect()
        try {
            // ① 暴力破解：按来源 IP 聚合登录失败次数
            let brute = "SELECT client_ip, COUNT(*) AS cnt, MAX(occurred_ms) AS last_ms " +
                        "FROM aud_logs WHERE action = 'auth.login' AND result = 1 " +
                        "AND occurred_ms >= ? GROUP BY client_ip HAVING COUNT(*) >= 5"
            let st1 = c.prepareStatement(brute)
            st1.set(0, fromMillis)
            for (r in readRows(st1.query()).all().iterator()) {
                let rd = RowData()
                rd.put("risk_type", Some("brute_force"))
                rd.put("client_ip", Some(r.str("client_ip")))
                rd.put("action", Some("auth.login"))
                rd.put("cnt", Some("${r.i64("cnt")}"))
                rd.put("last_ms", Some("${r.i64("last_ms")}"))
                out.add(rd)
            }
            // ②③④：失败的高危动作（批量导出 / 密钥操作 / 越权尝试）
            let high = "SELECT " +
                       "CASE " +
                       "  WHEN action LIKE '%export%' THEN 'batch_export' " +
                       "  WHEN action LIKE 'key.%' OR action LIKE 'crypto.key%' THEN 'key_op' " +
                       "  ELSE 'privilege_escalation' " +
                       "END AS risk_type, " +
                       "action, client_ip, COUNT(*) AS cnt, MAX(occurred_ms) AS last_ms " +
                       "FROM aud_logs WHERE result = 1 AND occurred_ms >= ? " +
                       "AND (action LIKE '%export%' OR action LIKE 'key.%' OR action LIKE 'crypto.key%' " +
                       "     OR action LIKE 'authz%' OR action LIKE 'perm%') " +
                       "GROUP BY action, client_ip"
            let st2 = c.prepareStatement(high)
            st2.set(0, fromMillis)
            for (r in readRows(st2.query()).all().iterator()) {
                let rd = RowData()
                rd.put("risk_type", Some(r.str("risk_type")))
                rd.put("client_ip", Some(r.str("client_ip")))
                rd.put("action", Some(r.str("action")))
                rd.put("cnt", Some("${r.i64("cnt")}"))
                rd.put("last_ms", Some("${r.i64("last_ms")}"))
                out.add(rd)
            }
        } catch (e: Exception) {
            throw toDbError(e)
        } finally {
            c.close()
        }
        return out
    }

    /**
     * 十六进制串 → 字节数组。
     *
     * 解码失败时返回全零数组（长度与预期不符的哈希不可能匹配，
     * 链校验会因此报 Broken —— 优于抛异常中断整个查询）。
     */
    public static func fromHex(hex: String): Array<Byte> {
        match (fromHexString(hex)) {
            case Some(b) => return b
            case None => return Array<Byte>(32, repeat: 0u8)
        }
    }

    /**
     * 绑定参数（0-based）。
     */
    private static func bind(st: Statement, params: ArrayList<SqlParam>): Unit {
        var i: Int = 0
        for (p in params.iterator()) {
            match (p) {
                case SqlParam.Str(v) => AuditRepo.bindStr(st, i, v)
                case SqlParam.Num(v) => st.set(i, v)
                case SqlParam.Nul => st.setNull(i)
            }
            i++
        }
    }

    /**
     * 绑定字符串（空串按 NULL 处理）。
     */
    private static func bindStr(st: Statement, index: Int, v: String): Unit {
        if (v.isEmpty()) {
            st.setNull(index)
        } else {
            st.set(index, v)
        }
    }
}

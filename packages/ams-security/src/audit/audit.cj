// ============================================================
// ams.security.audit · 审计记录与哈希链
//
// 需求：
//   FR-AUD-001 敏感操作审计（覆盖登录/登出/口令修改/授权撤销/导出/删除等）
//   FR-AUD-002 审计记录结构化（actor/action/target/result/ip/ua/trace_id/
//                              prev_hash/record_hash/timestamp）
//   FR-AUD-003 哈希链防篡改（record_hash = SM3(prev_hash + 规范化记录)）
//   FR-AUD-004 审计查询（多维过滤 + 分页 + 详情）
//   FR-AUD-006 不可篡改存储（表仅 INSERT，DB 层回收 UPDATE/DELETE 权限）
//
// [设计要点]
//   1. 哈希链：每条记录含 prev_hash 与 record_hash，
//      record_hash = SM3(prev_hash || 规范化记录)。
//      任何一条被改动，其后所有链的哈希都会对不上 → 篡改可检出。
//   2. 规范化：字段顺序固定、分隔符明确，避免"同一内容不同哈希"。
//   3. 链头锚定：每日把链头写到 aud_chain_anchors 并推到主库之外，
//      防「整链重写」攻击（只改链尾一段 + 重算整链）。
//   4. 敏感信息：detail 中的敏感字段必须已脱敏（由调用方保证）。
//
// [依赖说明]
//   本包不依赖 ams-kernel 的时间包（避免同包兄弟子包的 import 限制），
//   时间戳由调用方传入。
// ============================================================
package ams.security.audit

import std.collection.*
import std.sort.*
import stdx.encoding.hex.*

import ams.crypto.provider.*
import ams.kernel.error.*

/**
 * 操作者类型。
 */
public enum ActorType {
    | User      // 0 用户
    | System    // 1 系统
    | Anonymous // 2 匿名
    | Service   // 3 服务账号

    public func toCode(): Int64 {
        match (this) {
            case ActorType.User => return 0
            case ActorType.System => return 1
            case ActorType.Anonymous => return 2
            case ActorType.Service => return 3
        }
    }
}

/**
 * 操作结果。
 */
public enum AuditResult {
    | Success // 0 成功
    | Failure // 1 失败
    | Denied  // 2 拒绝

    public func toCode(): Int64 {
        match (this) {
            case AuditResult.Success => return 0
            case AuditResult.Failure => return 1
            case AuditResult.Denied => return 2
        }
    }
}

/**
 * 审计动作码（FR-AUD-001 要求的覆盖范围）。
 */
public enum AuditAction {
    | Login            // 登录
    | LoginFailed      // 登录失败
    | Logout           // 登出
    | LogoutAll        // 全局登出
    | PasswordChange   // 口令修改
    | PasswordReset    // 自助找回口令（验证码 → 令牌 → 改密）
    | RoleAssign       // 角色分配
    | RoleRevoke       // 授权撤销
    | GrantCreate      // 创建授权
    | GrantRevoke      // 撤销授权
    | ShareCreate      // 创建分享链接
    | ShareAccess      // 访问分享链接
    | DataExport       // 导出
    | ItemDelete       // 删除条目
    | ItemRestore      // 恢复条目
    | KeyRotate        // 密钥轮换
    | PermChange       // 权限变更
    | ConfigChange     // 配置变更
    | BatchOperation   // 数据批量操作
    | FieldReveal      // 展开敏感字段
    /**
     * 查询审计（FR-AUD-009 自审计）。
     *
     * 「谁看了审计」本身必须留痕：否则审计员/管理员翻看敏感操作记录
     * 这一行为没有任何证据，审计链的可信度在这里断掉。
     */
    | AuditQuery       // 查询审计日志
    // ---- 家庭协作（FR-ACL-010）：docs/14 §8 的 10 个动作码 ----
    | FamilyGroupCreate   // 创建家庭组
    | FamilyGroupDissolve // 解散家庭组
    | FamilyInviteCreate  // 创建邀请
    | FamilyInviteRevoke  // 撤销邀请
    | FamilyInviteAccept  // 接受邀请入组
    | FamilyInviteFail    // 邀请码错误（失败计数）
    | FamilyMemberRemove  // 移除成员（含级联撤销授权）
    | FamilyGrantCreate   // 组内授权创建
    | FamilyGrantRevoke   // 组内授权撤销
    | FamilyAccessDenied  // 越权访问家庭数据被拒
    /**
     * 未知动作（历史遗留或新增动作尚未同步到此枚举）。
     *
     * 审计动作是封闭枚举，但审计表可能存有旧版本写入的码。
     * 反查时归到 Unknown —— **记录仍然落库**，
     * 链校验会把该条判为 Tampered（因为重算时 action 不同）。
     * 这是有意的：宁可让链校验报出异常，也不静默改写历史记录。
     */
    | Unknown

    /**
     * 动作码 → AuditAction（反查，用于链校验时重建条目）。
     *
     * 未知码归为 Unknown。
     *
     * ⚠️ 必须与 code() **严格互逆**，否则哈希链校验必然误报：
     *    写入时 record_hash 用的是 `code()` 的返回值，校验时用
     *    `fromCode(落库值).code()` 重算 —— 若某个码不被 fromCode 接受，
     *    会退化为 Unknown（code() = "unknown"），规范化串随之改变，
     *    该条记录被判「被篡改」。
     *
     *    下列 4 个动作历史上 code() 与 fromCode 的用词不一致
     *    （写入用前一种、反查只认后一种），已造成真实误报：
     *      ShareCreate     写入 acl.share_create      反查只认 share.create
     *      ShareAccess     写入 acl.share_access      反查只认 share.access
     *      KeyRotate       写入 crypto.key_rotate     反查只认 kms.key_rotate
     *      BatchOperation  写入 archive.batch_operation 反查只认 archive.batch
     *    现**两种码都接受**：既兼容历史数据，也保证与当前 code() 互逆。
     */
    public static func fromCode(code: String): AuditAction {
        match (code) {
            case "auth.login" => return AuditAction.Login
            case "auth.login_failed" => return AuditAction.LoginFailed
            case "auth.logout" => return AuditAction.Logout
            case "auth.logout_all" => return AuditAction.LogoutAll
            case "auth.password_change" => return AuditAction.PasswordChange
            case "auth.password_reset" => return AuditAction.PasswordReset
            case "acl.role_assign" => return AuditAction.RoleAssign
            case "acl.role_revoke" => return AuditAction.RoleRevoke
            case "acl.grant_create" => return AuditAction.GrantCreate
            case "acl.grant_revoke" => return AuditAction.GrantRevoke
            case "acl.share_create" => return AuditAction.ShareCreate
            case "share.create" => return AuditAction.ShareCreate
            case "acl.share_access" => return AuditAction.ShareAccess
            case "share.access" => return AuditAction.ShareAccess
            case "archive.export" => return AuditAction.DataExport
            case "archive.item_delete" => return AuditAction.ItemDelete
            case "archive.item_restore" => return AuditAction.ItemRestore
            case "crypto.key_rotate" => return AuditAction.KeyRotate
            case "kms.key_rotate" => return AuditAction.KeyRotate
            case "acl.perm_change" => return AuditAction.PermChange
            case "cfg.change" => return AuditAction.ConfigChange
            case "archive.batch_operation" => return AuditAction.BatchOperation
            case "archive.batch" => return AuditAction.BatchOperation
            case "archive.field_reveal" => return AuditAction.FieldReveal
            case "audit.query" => return AuditAction.AuditQuery
            case "family.group.create" => return AuditAction.FamilyGroupCreate
            case "family.group.dissolve" => return AuditAction.FamilyGroupDissolve
            case "family.invite.create" => return AuditAction.FamilyInviteCreate
            case "family.invite.revoke" => return AuditAction.FamilyInviteRevoke
            case "family.invite.accept" => return AuditAction.FamilyInviteAccept
            case "family.invite.fail" => return AuditAction.FamilyInviteFail
            case "family.member.remove" => return AuditAction.FamilyMemberRemove
            case "family.grant.create" => return AuditAction.FamilyGrantCreate
            case "family.grant.revoke" => return AuditAction.FamilyGrantRevoke
            case "family.access.denied" => return AuditAction.FamilyAccessDenied
            case _ => return AuditAction.Unknown
        }
    }

    /**
     * 动作码（写入 aud_logs.action）。
     */
    public func code(): String {
        match (this) {
            case AuditAction.Login => return "auth.login"
            case AuditAction.LoginFailed => return "auth.login_failed"
            case AuditAction.Logout => return "auth.logout"
            case AuditAction.LogoutAll => return "auth.logout_all"
            case AuditAction.PasswordChange => return "auth.password_change"
            case AuditAction.PasswordReset => return "auth.password_reset"
            case AuditAction.RoleAssign => return "acl.role_assign"
            case AuditAction.RoleRevoke => return "acl.role_revoke"
            case AuditAction.GrantCreate => return "acl.grant_create"
            case AuditAction.GrantRevoke => return "acl.grant_revoke"
            case AuditAction.ShareCreate => return "acl.share_create"
            case AuditAction.ShareAccess => return "acl.share_access"
            case AuditAction.DataExport => return "archive.export"
            case AuditAction.ItemDelete => return "archive.item_delete"
            case AuditAction.ItemRestore => return "archive.item_restore"
            case AuditAction.KeyRotate => return "crypto.key_rotate"
            case AuditAction.PermChange => return "acl.perm_change"
            case AuditAction.ConfigChange => return "cfg.change"
            case AuditAction.BatchOperation => return "archive.batch_operation"
            case AuditAction.FieldReveal => return "archive.field_reveal"
            case AuditAction.AuditQuery => return "audit.query"
            case AuditAction.FamilyGroupCreate => return "family.group.create"
            case AuditAction.FamilyGroupDissolve => return "family.group.dissolve"
            case AuditAction.FamilyInviteCreate => return "family.invite.create"
            case AuditAction.FamilyInviteRevoke => return "family.invite.revoke"
            case AuditAction.FamilyInviteAccept => return "family.invite.accept"
            case AuditAction.FamilyInviteFail => return "family.invite.fail"
            case AuditAction.FamilyMemberRemove => return "family.member.remove"
            case AuditAction.FamilyGrantCreate => return "family.grant.create"
            case AuditAction.FamilyGrantRevoke => return "family.grant.revoke"
            case AuditAction.FamilyAccessDenied => return "family.access.denied"
            case AuditAction.Unknown => return "unknown"
        }
    }
}

/**
 * 一条审计记录（写入前）。
 */
public class AuditEntry {
    /** 链序号（由 DB 分配，保证全局有序） */
    public let chainSeq: Int64
    /** 操作者 ID（系统动作为空） */
    public let actorId: String
    /** 操作者类型 */
    public let actorType: ActorType
    /** 动作 */
    public let action: AuditAction
    /** 动作描述 */
    public let actionDesc: String
    /** 目标类型（item/subject/attachment/role/user...） */
    public let targetType: String
    /** 目标 ID */
    public let targetId: String
    /** 相关主体 ID */
    public let subjectId: String
    /** 分类码 */
    public let category: Int64
    /** 结果 */
    public let result: AuditResult
    /** 错误码 */
    public let errorCode: String
    /** 客户端 IP */
    public let clientIp: String
    /** User-Agent */
    public let userAgent: String
    /** 链路 ID */
    public let traceId: String
    /** 上下文（**必须已脱敏**） */
    public let detail: Array<(String, String)>
    /** 事件时间（Unix 毫秒） */
    public let occurredAt: Int64

    public init(
        chainSeq: Int64,
        actorId: String,
        actorType: ActorType,
        action: AuditAction,
        actionDesc: String,
        targetType: String,
        targetId: String,
        subjectId: String,
        category: Int64,
        result: AuditResult,
        errorCode: String,
        clientIp: String,
        userAgent: String,
        traceId: String,
        detail: Array<(String, String)>,
        occurredAt: Int64
    ) {
        this.chainSeq = chainSeq
        this.actorId = actorId
        this.actorType = actorType
        this.action = action
        this.actionDesc = actionDesc
        this.targetType = targetType
        this.targetId = targetId
        this.subjectId = subjectId
        this.category = category
        this.result = result
        this.errorCode = errorCode
        this.clientIp = clientIp
        this.userAgent = userAgent
        this.traceId = traceId
        this.detail = detail
        this.occurredAt = occurredAt
    }
}

/**
 * 一条已落库的审计记录（含哈希）。
 */
public class AuditRecord {
    public let entry: AuditEntry
    /** 前一条记录哈希（创世记录为 32 个 0） */
    public let prevHash: Array<Byte>
    /** 本条记录哈希 */
    public let recordHash: Array<Byte>

    public init(entry: AuditEntry, prevHash: Array<Byte>, recordHash: Array<Byte>) {
        this.entry = entry
        this.prevHash = prevHash
        this.recordHash = recordHash
    }
}

/**
 * 链完整性校验结果。
 */
public enum ChainVerifyResult {
    | Ok
    /** 序号处断裂：第 seq 条的 prev_hash 与第 seq-1 条的 record_hash 不匹配 */
    | Broken(Int64)
    /** 记录自身的哈希重算不符（内容被改动） */
    | Tampered(Int64)
    /** 记录数不足（中间有记录被删除） */
    | Missing(Int64)
}

/**
 * 审计服务：负责计算哈希链与校验链完整性。
 */
public class AuditService {
    private let provider: CryptoProvider

    public init(provider: CryptoProvider) {
        this.provider = provider
    }

    /**
     * 创世记录的 prev_hash（全 0）。
     */
    public static func genesisHash(): Array<Byte> {
        return Array<Byte>(32, repeat: 0u8)
    }

    /**
     * 计算一条记录的哈希。
     *
     * record_hash = SM3(prev_hash || 规范化记录)
     *
     * 规范化规则（必须稳定，否则历史链会失效）：
     *   字段顺序固定，用 '|' 分隔，字段内 '|' 与 '\' 转义；
     *   detail 按 key 字典序排列。
     */
    public func computeHash(entry: AuditEntry, prevHash: Array<Byte>): CryptoResult<Array<Byte>> {
        let canonical = AuditService.canonicalize(entry, prevHash)
        // record_hash = SM3(prev_hash || 规范化记录)
        // 注意：用 digest（纯 SM3 摘要）而非 hmac —— 规范里定义的就是摘要
        return this.provider.digest(canonical, DigestAlgorithm.Sm3)
    }

    /**
     * 规范化记录内容（用于哈希）。
     *
     * 字段顺序：chainSeq|actorId|actorType|action|targetType|targetId|
     *          subjectId|category|result|errorCode|clientIp|userAgent|
     *          traceId|occurredAt|detail(prevHash 单独前置)
     */
    public static func canonicalize(entry: AuditEntry, prevHash: Array<Byte>): Array<Byte> {
        var sb = StringBuilder()
        sb.append(toHexString(prevHash))
        sb.append("|")
        sb.append(entry.chainSeq.toString())
        sb.append("|")
        sb.append(entry.actorId)
        sb.append("|")
        sb.append(entry.actorType.toCode().toString())
        sb.append("|")
        sb.append(entry.action.code())
        sb.append("|")
        sb.append(entry.targetType)
        sb.append("|")
        sb.append(entry.targetId)
        sb.append("|")
        sb.append(entry.subjectId)
        sb.append("|")
        sb.append(entry.category.toString())
        sb.append("|")
        sb.append(entry.result.toCode().toString())
        sb.append("|")
        sb.append(entry.errorCode)
        sb.append("|")
        sb.append(entry.clientIp)
        sb.append("|")
        sb.append(entry.userAgent)
        sb.append("|")
        sb.append(entry.traceId)
        sb.append("|")
        sb.append(entry.occurredAt.toString())
        sb.append("|")
        // detail 按 key 排序后拼接
        sb.append(AuditService.canonicalDetail(entry.detail))
        return sb.toString().toArray()
    }

    /**
     * detail 的规范化：按 key 字典序，k=v 用 & 连接。
     */
    private static func canonicalDetail(detail: Array<(String, String)>): String {
        if (detail.isEmpty()) {
            return ""
        }
        // 排序（按 key）
        let keys = ArrayList<String>()
        for (i in 0..detail.size) {
            let (k, _) = detail[i]
            keys.add(k)
        }
        let sorted = keys.toArray()
        sort(sorted)

        var sb = StringBuilder()
        var first = true
        for (k in sorted) {
            var value = ""
            for (i in 0..detail.size) {
                let (k2, v2) = detail[i]
                if (k2 == k) {
                    value = v2
                    break
                }
            }
            if (!first) {
                sb.append("&")
            }
            sb.append(k)
            sb.append("=")
            sb.append(value)
            first = false
        }
        return sb.toString()
    }

    /**
     * 构造一条完整的审计记录（含 prev_hash 与 record_hash）。
     */
    public func buildRecord(entry: AuditEntry, prevHash: Array<Byte>): CryptoResult<AuditRecord> {
        let h = this.computeHash(entry, prevHash)
        match (h) {
            case CryptoResult.Ok(recordHash) => return CryptoResult.Ok(AuditRecord(entry, prevHash, recordHash))
            case CryptoResult.Err(e) => return CryptoResult.Err(e)
        }
    }

    /**
     * 校验链完整性（从创世锚点开始）。
     *
     * @param records 按 chainSeq 升序排列的记录
     * @return 校验结论
     */
    public func verifyChain(records: Array<AuditRecord>): ChainVerifyResult {
        return this.verifyChainFrom(records, AuditService.genesisHash())
    }

    /**
     * 校验链完整性（支持从任意段开始）。
     *
     * @param records    按 chainSeq 升序排列的记录（本段）
     * @param startPrev  本段首条记录期望的 prev_hash
     *                   —— 即「段前那一条记录的 record_hash」；
     *                   若从整链头部（seq=1）开始则为创世哈希。
     *
     * 为什么需要它：审计链可能只校验中段（分页 / 只验新记录）。
     * 中段首条的 prev_hash 是段前记录的哈希，而非创世哈希，
     * 若不把段前哈希作为锚点传入，第一段就会被误判为 Broken。
     */
    public func verifyChainFrom(records: Array<AuditRecord>, startPrev: Array<Byte>): ChainVerifyResult {
        var expectedPrev = startPrev
        for (r in records) {
            // ① 序号连续性
            // ⚠️ 期望值必须以「本批第一条记录的 chain_seq」为锚点，
            //    而非恒为 1 —— 从中间段（from > 1）校验时，
            //    第 0 条的 chain_seq 就是 base，第 i 条应为 base + i。
            //    否则整段都会被误判为 Missing。
            if (r.entry.chainSeq != expectedSeq(records, r)) {
                return ChainVerifyResult.Missing(r.entry.chainSeq)
            }
            // ② 链式衔接
            if (!this.provider.constantTimeEquals(r.prevHash, expectedPrev)) {
                return ChainVerifyResult.Broken(r.entry.chainSeq)
            }
            // ③ 内容未被改动（重算哈希）
            // 注意：仓颉的 match 分支只能是单个表达式，故把判定抽成方法，
            //       这里用「单表达式 match」来传播失败结果。
            let contentResult = this.checkContent(r)
            match (contentResult) {
                case ChainVerifyResult.Ok => ()
                case _ => return contentResult
            }
            expectedPrev = r.recordHash
        }
        return ChainVerifyResult.Ok
    }

    /**
     * 校验单条记录的内容未被改动（重算哈希并比对）。
     */
    private func checkContent(r: AuditRecord): ChainVerifyResult {
        let recomputed = this.computeHash(r.entry, r.prevHash)
        match (recomputed) {
            case CryptoResult.Ok(h) => return this.compareHash(r, h)
            case CryptoResult.Err(_) => return ChainVerifyResult.Tampered(r.entry.chainSeq)
        }
    }

    /**
     * 比对重算哈希与落库哈希。
     */
    private func compareHash(r: AuditRecord, recomputed: Array<Byte>): ChainVerifyResult {
        if (this.provider.constantTimeEquals(recomputed, r.recordHash)) {
            return ChainVerifyResult.Ok
        }
        return ChainVerifyResult.Tampered(r.entry.chainSeq)
    }

    /**
     * 期望的链序号。
     *
     * 以本批第一条记录的 chain_seq 为锚点（base），
     * 第 i 条记录（0-based）的期望值应为 base + i。
     * 这样既支持「从头校验」（base=1 → 1,2,3…），
     * 也支持「从中间段校验」（base=24 → 24,25,26…）。
     *
     * 若某条记录的 chain_seq 与 base+i 不符，说明中间有缺失（被删除），
     * 此时返回其实际值，使调用方判定为 Missing。
     */
    private static func expectedSeq(records: Array<AuditRecord>, current: AuditRecord): Int64 {
        if (records.isEmpty()) {
            return current.entry.chainSeq
        }
        let base = records[0].entry.chainSeq
        for (i in 0..records.size) {
            if (records[i].entry.chainSeq == current.entry.chainSeq) {
                return base + Int64(i)
            }
        }
        return current.entry.chainSeq
    }

    /**
     * 取链头哈希（最后一条记录的哈希）。
     */
    public static func chainHead(records: Array<AuditRecord>): Array<Byte> {
        if (records.isEmpty()) {
            return AuditService.genesisHash()
        }
        return records[records.size - 1].recordHash
    }
}

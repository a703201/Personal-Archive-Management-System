// ============================================================
// ams.app.subject · 档案主体应用服务
//
// 职责：
//   - 姓名的「明文 <-> 密文」转换（arc_subjects.name_enc 是 BYTEA 密文列）
//   - 首次访问时懒建「本人」主体（自愈存量账号）
//   - 业务校验（名称非空、重名、关系取值）
//
// 【为什么加密放在应用层而非仓储层】
//   架构 §4.2 的分层纪律：仓储只回答「数据库里是什么」，
//   密码学能力属于应用层（ams-app）协作范畴。
//   仓储因此只收发 Array<Byte>，不知道明文长什么样。
//
// 【信封格式】
//   直接复用 ams-core 的 AttachmentCipher（SM4-CBC + HMAC-SM3，
//   即安全章 §4.0 记录的 Encrypt-then-MAC 组合）。
//   —— 该实现已有单测覆盖，且与附件走同一套密码学路径，
//   避免为「主体姓名」再造一套自研信封。
//
// 【密钥来源】
//   由 KEK（AMS_KEK）派生：固定 salt + 固定迭代，写读两侧可复现。
//   与 BlindIndexService 的取舍一致（D4：本期全局一把密钥，
//   per-subject 派生留作后续加固项）。
//   注意：更换 AMS_KEK 会导致既有主体姓名不可解密 —— 这是设计上的
//   密钥轮换代价，需要配套的数据重加密迁移（未在本期范围）。
// ============================================================
package ams.app.subject

import std.collection.*

import ams.core.attachment.*
import ams.crypto.provider.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.log.*

/**
 * 主体视图（已解密的对外形态）。
 */
public class SubjectView {
    public let id: String
    public let name: String
    public let alias: String
    public let relation: Int64
    public let isPrimary: Bool
    public let status: Int64
    public let completeness: Int64
    public let summary: String
    public let version: Int64
    public let createdMs: Int64
    public let updatedMs: Int64

    public init(
        id: String,
        name: String,
        alias: String,
        relation: Int64,
        isPrimary: Bool,
        status: Int64,
        completeness: Int64,
        summary: String,
        version: Int64,
        createdMs: Int64,
        updatedMs: Int64
    ) {
        this.id = id
        this.name = name
        this.alias = alias
        this.relation = relation
        this.isPrimary = isPrimary
        this.status = status
        this.completeness = completeness
        this.summary = summary
        this.version = version
        this.createdMs = createdMs
        this.updatedMs = updatedMs
    }
}

/**
 * 主体应用服务。
 */
public class SubjectService {
    private let repo: SubjectRepo
    private let cipher: AttachmentCipher
    /** 姓名加解密密钥（SM4，16 字节） */
    private let nameKey: Array<Byte>

    public init(repo: SubjectRepo, provider: CryptoProvider, kek: Array<Byte>) {
        this.repo = repo
        this.cipher = AttachmentCipher(provider)
        let salt = "ams-subject-name-v1".toArray()
        this.nameKey = match (provider.deriveKey(kek, salt, 1000, 16)) {
            case CryptoResult.Ok(k) => k
            case CryptoResult.Err(e) => throw e
        }
    }

    /**
     * 确保调用者至少有一个主体。
     *
     * 这是「存量账号自愈」的关键：注册流程不会建主体，
     * 而建档案又必须先有主体 → 首次拉主体列表时补建「本人」，
     * 否则新老用户都会卡在 403「无权限在该主体下创建条目」。
     *
     * @param displayName 主体名（一般取昵称，空则用用户名）
     */
    public func ensureDefault(userId: Int64, displayName: String): Unit {
        if (this.repo.countByOwner(userId) > 0) {
            return
        }
        let name = if (displayName.isEmpty()) { "本人" } else { displayName }
        let id = this.repo.create(userId, this.seal(name), "", 0, true, "", userId)
        Log.get().info("subject.default.created", None, [
            ("uid", "${userId}"),
            ("subjectId", "${id}")
        ])
    }

    /**
     * 列出可读主体（自有 + 代管）。
     */
    public func list(userId: Int64): ArrayList<SubjectView> {
        let rows = this.repo.list(userId)
        let out = ArrayList<SubjectView>()
        for (r in rows.all().iterator()) {
            let name = this.open(r.getOpt("name_hex") ?? "")
            out.add(SubjectView(
                r.str("id"),
                name,
                r.str("alias"),
                r.i64("relation"),
                r.bool("is_primary"),
                r.i64("status"),
                r.i64("completeness"),
                r.str("summary"),
                r.i64("version"),
                r.i64("created_ms"),
                r.i64("updated_ms")
            ))
        }
        return out
    }

    /**
     * 新建主体。
     *
     * @throws AppError ValidationFailed / Conflict
     */
    public func create(
        ownerId: Int64,
        name: String,
        alias: String,
        relation: Int64,
        summary: String
    ): Int64 {
        let trimmed = name.trimAscii()
        if (trimmed.isEmpty()) {
            throw validationError("name", "主体姓名不能为空")
        }
        if (trimmed.size > 64) {
            throw validationError("name", "主体姓名不能超过 64 个字符")
        }
        if (relation < 0 || relation > 4) {
            throw validationError("relation", "关系取值非法（0=本人 1=配偶 2=子女 3=父母 4=其他）")
        }
        // 重名判定：name_enc 每次加密的 IV 不同，密文不可比对，
        // 因此按「解密后的明文」在内存里比对（单用户主体数量很小）。
        for (s in this.list(ownerId).iterator()) {
            if (s.name == trimmed) {
                throw conflict("已存在同名主体「${trimmed}」")
            }
        }
        let isFirst = this.repo.countByOwner(ownerId) == 0
        return this.repo.create(ownerId, this.seal(trimmed), alias, relation, isFirst, summary, ownerId)
    }

    /**
     * 更新主体（乐观锁）。
     *
     * @return false = 版本冲突
     * @throws AppError NotFound / ValidationFailed
     */
    public func update(
        id: Int64,
        ownerId: Int64,
        expectedVersion: Int64,
        name: String,
        alias: String,
        relation: Int64,
        summary: String
    ): Bool {
        let trimmed = name.trimAscii()
        if (trimmed.isEmpty()) {
            throw validationError("name", "主体姓名不能为空")
        }
        if (relation < 0 || relation > 4) {
            throw validationError("relation", "关系取值非法（0=本人 1=配偶 2=子女 3=父母 4=其他）")
        }
        // 先确认可写（所有者）且存在，避免把「无权」误报成「版本冲突」
        match (this.repo.findAccessible(id, ownerId)) {
            case Some(_) => ()
            case None => throw notFound("主体")
        }
        return this.repo.update(
            id, ownerId, expectedVersion, this.seal(trimmed), alias, relation, summary, ownerId
        )
    }

    /**
     * 软删除主体。
     *
     * 允许删除最后一个主体 —— 若用户真的清空了，下次拉列表会重新补建「本人」，
     * 不会留下「无主体可用」的死局。
     */
    public func remove(id: Int64, ownerId: Int64): Bool {
        return this.repo.softDelete(id, ownerId, ownerId)
    }

    /**
     * 该主体下的条目数（删除前提示）。
     */
    public func itemCount(id: Int64): Int64 {
        return this.repo.itemCount(id)
    }

    // ---------------------------------------------------------------
    // 明文 <-> 密文
    // ---------------------------------------------------------------

    /**
     * 加密姓名。
     */
    private func seal(plain: String): Array<Byte> {
        let enc = match (this.cipher.encrypt(plain.toArray(), this.nameKey)) {
            case CryptoResult.Ok(v) => v
            case CryptoResult.Err(e) => throw e
        }
        return enc
    }

    /**
     * 解密姓名（十六进制密文串 → 明文）。
     *
     * 解密失败返回空串而非抛异常：单个主体的密钥问题
     * 不应让整个主体列表 500。失败留 warn 日志便于排查。
     */
    private func open(nameHex: String): String {
        let enc = SubjectRepo.hexToBytes(nameHex)
        if (enc.isEmpty()) {
            return ""
        }
        match (this.decryptOrNone(enc)) {
            case Some(bytes) => return String.fromUtf8(bytes)
            case None => return ""
        }
    }

    /**
     * 解密并吞掉异常（失败返回 None）。
     */
    private func decryptOrNone(enc: Array<Byte>): Option<Array<Byte>> {
        match (this.cipher.decrypt(enc, this.nameKey)) {
            case CryptoResult.Ok(v) => return Some(v)
            case CryptoResult.Err(e) => return SubjectService.failDecrypt(e)
        }
    }

    /**
     * 记录解密失败并返回 None。
     *
     * 独立成方法的原因：仓颉的 match 分支体只能是一条表达式，
     * 无法在分支里「先记日志再 return」。
     */
    private static func failDecrypt(e: AppError): Option<Array<Byte>> {
        Log.get().warn("subject.name.decrypt.failed", None, [("reason", e.toString())])
        return None
    }
}

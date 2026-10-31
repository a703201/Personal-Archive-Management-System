// ============================================================
// ams.app.family · 家庭成员邀请的应用服务（FR-ACL-010 · 方案 B）
//
// 职责：把「建组 / 邀请 / 接受 / 移除 / 授权」编排起来，
//       并把 docs/14 §3 的十条安全原则落到每一次调用上。
//
// 三条贯穿全文件的约定：
//   ① **默认拒绝**：不是组内成员 → 一切组内接口 403；成员 → 仍然零可见，
//      可见性只来自 acl_grants。
//   ② **失败关闭**：缺加密提供者 / 缺签名密钥 → 抛错，绝不降级成弱 token
//      或空摘要（空摘要会让「有 code 的邀请」变成「随便谁都能进」）。
//   ③ **不越权授权**：只能对**自己拥有**的主体授权，且被授权人必须已在组内。
//
// 审计不在这里做：项目既有约定是「路由层持 AuditRecorder 落痕」
// （见 ExportRoutes / AttachmentRoutes / SystemRoutes），本服务只返回
// 足够的信息（如被撤销的授权条数）供路由层写进 detail。
// ============================================================
package ams.app.family

import ams.core.family.*
import ams.crypto.provider.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.id.*
import ams.kernel.time.*

/**
 * 邀请创建结果（明文 code / token **只在此处出现一次**）。
 */
public class InviteCreated {
    public let inviteId: Int64
    public let code: String
    public let token: String
    public let expiresMs: Int64
    public let maxUses: Int64

    public init(inviteId: Int64, code: String, token: String, expiresMs: Int64, maxUses: Int64) {
        this.inviteId = inviteId
        this.code = code
        this.token = token
        this.expiresMs = expiresMs
        this.maxUses = maxUses
    }
}

/**
 * 邀请落地页元数据（公开，不含任何 PII）。
 */
public class InviteMeta {
    public let valid: Bool
    public let groupName: String
    public let inviterNick: String
    public let expiresMs: Int64
    public let remainingUses: Int64
    public let reason: String

    public init(
        valid: Bool,
        groupName: String,
        inviterNick: String,
        expiresMs: Int64,
        remainingUses: Int64,
        reason: String
    ) {
        this.valid = valid
        this.groupName = groupName
        this.inviterNick = inviterNick
        this.expiresMs = expiresMs
        this.remainingUses = remainingUses
        this.reason = reason
    }
}

/**
 * 接受邀请的结果。
 */
public class AcceptResult {
    public let groupId: Int64
    public let groupName: String
    public let role: String
    /** 是否本来就已是成员（幂等命中，未消耗次数） */
    public let alreadyMember: Bool

    public init(groupId: Int64, groupName: String, role: String, alreadyMember: Bool) {
        this.groupId = groupId
        this.groupName = groupName
        this.role = role
        this.alreadyMember = alreadyMember
    }
}

/**
 * 家庭协作应用服务。
 */
public class FamilyService {
    private let groupRepo: FamGroupRepo
    private let memberRepo: FamMemberRepo
    private let inviteRepo: FamInviteRepo
    private let grantRepo: FamGrantRepo
    private let subjectRepo: SubjectRepo
    private let userRepo: UserRepo
    private let itemRepo: ItemRepo
    private let crypto: ?CryptoProvider
    private let signKey: String

    public init(
        groupRepo: FamGroupRepo,
        memberRepo: FamMemberRepo,
        inviteRepo: FamInviteRepo,
        grantRepo: FamGrantRepo,
        subjectRepo: SubjectRepo,
        userRepo: UserRepo,
        itemRepo: ItemRepo,
        crypto!: ?CryptoProvider = None,
        signKey!: String = ""
    ) {
        this.groupRepo = groupRepo
        this.memberRepo = memberRepo
        this.inviteRepo = inviteRepo
        this.grantRepo = grantRepo
        this.subjectRepo = subjectRepo
        this.userRepo = userRepo
        this.itemRepo = itemRepo
        this.crypto = crypto
        this.signKey = signKey
    }

    // ============================================================
    // 家庭组
    // ============================================================

    /**
     * 建组。创建者自动成为组内 owner。
     *
     * 组名做基本清洗（去首尾空白、长度 1~64）：组名会显示在被邀请人的
     * 落地页上，是「防钓鱼核对」的依据（docs/14 §7 T14），空名等于让
     * 对方无从核对。
     */
    public func createGroup(name: String, ownerId: Int64): Int64 {
        let clean = name.trimAscii()
        if (clean.isEmpty()) {
            throw validationError("name", "家庭组名称不能为空")
        }
        if (clean.toArray().size > 64) {
            throw validationError("name", "家庭组名称不能超过 64 字节")
        }
        if (ownerId <= 0) {
            throw AppError(AppErrorKind.Unauthorized, "未认证")
        }
        let groupId = this.groupRepo.create(clean, ownerId)
        // 建组后立刻写入 owner 成员行：否则「组存在但无人可管理」，
        // 而后续所有接口都以成员身份为门槛，组会变成无人可用的孤儿。
        let (_, _) = this.memberRepo.join(groupId, ownerId, FamilyRole.Owner.code(), ownerId)
        return groupId
    }

    /** 我加入的组（含组内角色与成员数）。 */
    public func listGroups(userId: Int64): RowSet {
        return this.groupRepo.listByUser(userId)
    }

    /**
     * 我在该组的角色；不在组内 / 已移除 / 组已解散 → None。
     *
     * 这是**所有组内接口的第一道门槛**，且返回值一律 None 表示不可访问 ——
     * 不区分「组不存在」与「你不在组里」，避免把组的存在性变成探测信号。
     */
    public func myRole(groupId: Int64, userId: Int64): Option<FamilyRole> {
        match (this.groupRepo.findById(groupId)) {
            case Some(g) =>
                if (g.i64("status") != 0) {
                    return None
                }
            case None => return None
        }
        return match (this.memberRepo.findActive(groupId, userId)) {
            case Some(m) => Some(FamilyRole.fromCode(m.str("role")))
            case None => None
        }
    }

    /** 组详情（调用方已确认成员身份）。 */
    public func groupDetail(groupId: Int64): Option<RowData> {
        return this.groupRepo.findById(groupId)
    }

    /**
     * 解散组：撤销本组全部授权 + 撤销全部未用邀请 + 软删组。
     *
     * **不删任何档案条目** —— 条目属于主体所有者，组只是协作外壳
     * （docs/14 §13 R4）。成员行保留（status 由组状态间接失效），
     * 以便「组被解散」这件事在审计上可回溯。
     *
     * @return 被撤销的授权条数
     */
    public func dissolveGroup(groupId: Int64, operatorId: Int64): Int64 {
        let role = this.requireRole(groupId, operatorId)
        if (!role.canDissolve()) {
            throw forbidden(message: "只有家庭组所有者可以解散该组")
        }
        let revoked = this.grantRepo.revokeAll(groupId, 0, "group_dissolved")
        this.inviteRepo.revokeAllByGroup(groupId)
        this.memberRepo.remove(groupId, operatorId, operatorId)
        let ok = this.groupRepo.dissolve(groupId, operatorId)
        if (!ok) {
            throw notFound("家庭组")
        }
        return revoked
    }

    // ============================================================
    // 邀请
    // ============================================================

    /**
     * 创建邀请。
     *
     * 生成两套凭据（docs/14 §5.2）：
     *   · `code`  —— 8 位 / 32 字符表 / 40 bit，供口头或当面传达；
     *   · `token` —— 16 字节随机（128 bit），供二维码/链接。
     * 两者**都只落摘要**，明文仅在本次响应里出现一次。
     */
    public func createInvite(
        groupId: Int64,
        operatorId: Int64,
        targetRole: String,
        minutes: Int64,
        maxUses: Int64,
        maxFails: Int64
    ): InviteCreated {
        let role = this.requireRole(groupId, operatorId)
        if (!role.canInvite()) {
            throw forbidden(message: "只有组所有者或管理员可以邀请成员")
        }
        let prov = this.provider()
        let ttl = InviteLimits.clampMinutes(minutes)
        let uses = InviteLimits.clampUses(maxUses)
        let fails = if (maxFails <= 0) { InviteLimits.DEFAULT_MAX_FAILS } else { maxFails }
        // 目标角色只能是 member / manager：邀请**不能**直接产出第二个 owner
        // （否则「邀请」变成「转让所有权」的隐蔽通道）。
        let wantRole = FamilyRole.fromCode(targetRole)
        let finalRole = if (wantRole.isOwner()) {
            FamilyRole.Manager.code()
        } else {
            wantRole.code()
        }

        let random = match (prov.randomBytes(InviteCode.LENGTH + 16)) {
            case CryptoResult.Ok(b) => b
            case CryptoResult.Err(e) => throw e
        }
        // 前 8 字节给 code，后 16 字节给 token
        let codeBytes = random[0..InviteCode.LENGTH]
        let code = InviteCode.generate(codeBytes)
        if (!InviteCode.isWellFormed(code)) {
            throw AppError(AppErrorKind.Internal, "邀请码生成失败（随机源返回异常长度）")
        }
        var tokenBytes = Array<Byte>(16, repeat: 0u8)
        for (i in 0..16) {
            tokenBytes[i] = random[InviteCode.LENGTH + i]
        }
        let token = FamilyService.hex(tokenBytes)
        let salt = "f${Ids.next()}"
        let codeHash = this.hmacHex(salt, code)
        let tokenHash = this.hmacHex(this.signKeyOrThrow(), token)
        let expiresMs = Times.nowMillis() + ttl * 60 * 1000
        let id = this.inviteRepo.create(
            groupId, operatorId, codeHash, salt, tokenHash, finalRole,
            uses, fails, Times.toIso8601(expiresMs)
        )
        return InviteCreated(id, code, token, expiresMs, uses)
    }

    /** 组内邀请列表（owner/manager 可见）。 */
    public func listInvites(groupId: Int64, operatorId: Int64): RowSet {
        let role = this.requireRole(groupId, operatorId)
        if (!role.canInvite()) {
            throw forbidden(message: "只有组所有者或管理员可以查看邀请")
        }
        return this.inviteRepo.listByGroup(groupId, 50)
    }

    /** 撤销邀请。 */
    public func revokeInvite(groupId: Int64, inviteId: Int64, operatorId: Int64): Bool {
        let role = this.requireRole(groupId, operatorId)
        if (!role.canInvite()) {
            throw forbidden(message: "只有组所有者或管理员可以撤销邀请")
        }
        return this.inviteRepo.revoke(inviteId, groupId)
    }

    /**
     * 落地页元数据（**公开接口**）。
     *
     * 安全取舍：无效邀请也要返回 `valid = false` 而不是 404 —— 落地页
     * 需要把「无效或已过期」渲染成一个正常页面，而不是让用户看到
     * 一个接口报错。但同时**不返回任何原因细节以外的信息**：
     * 组名与邀请人昵称只在仍有效时给出，失效后连组名都不再暴露。
     */
    public func inviteMeta(token: String): InviteMeta {
        if (token.isEmpty()) {
            return InviteMeta(false, "", "", 0, 0, "missing")
        }
        let tokenHash = this.hmacHex(this.signKeyOrThrow(), token)
        let row = match (this.inviteRepo.findByTokenHash(tokenHash)) {
            case Some(r) => r
            case None => return InviteMeta(false, "", "", 0, 0, "not_found")
        }
        let snap = FamilyService.snapshotOf(row)
        let state = snap.stateAt(Times.nowMillis())
        if (state.isDead()) {
            return InviteMeta(false, "", "", row.i64("expires_ms"), 0, state.reason())
        }
        let groupName = match (this.groupRepo.findById(row.i64("group_id"))) {
            case Some(g) => g.str("name")
            case None => ""
        }
        let inviterNick = this.nicknameOf(row.i64("inviter_id"))
        return InviteMeta(
            true, groupName, inviterNick, row.i64("expires_ms"),
            snap.remainingUses(Times.nowMillis()), state.reason()
        )
    }

    /**
     * 接受邀请。
     *
     * 判定顺序**不可交换**：
     *   1. token 能定位到邀请（否则 404，与「已失效」同一文案）
     *   2. 邀请仍然有效（否则 404）
     *   3. code 正确（否则 403 + 失败计数 +1；达上限即撤销）
     *   4. 原子消耗一次使用次数（并发下只有一个能成功）
     *   5. 入组（幂等）
     *
     * 为什么第 4 步在入组之前：先入组再消耗，若消耗失败就会出现
     * 「人进来了但次数没扣」—— 一次性邀请可以无限用。
     */
    public func acceptInvite(token: String, code: String, userId: Int64): AcceptResult {
        if (userId <= 0) {
            throw AppError(AppErrorKind.Unauthorized, "未认证")
        }
        let tokenHash = this.hmacHex(this.signKeyOrThrow(), token)
        let row = match (this.inviteRepo.findByTokenHash(tokenHash)) {
            case Some(r) => r
            case None => throw notFound("邀请")
        }
        let inviteId = row.i64("id")
        let groupId = row.i64("group_id")
        // ---- 先判「是不是已经在组里」----
        // 必须在状态判定之前：家人拿到链接点第二次时，邀请可能刚好被
        // 上一次接受用尽（默认就是 1 次）。若先判状态，他会看到
        // 「邀请不存在」，而实际上他早就在组里了 —— 这种「明明加入了却
        // 说邀请无效」的反馈会让人反复找邀请人重发。
        //
        // 这里不泄漏信息：能走到这一步说明持有 token（凭据已具备），
        // 而「你在不在这个组里」对本人本来就不是秘密。非成员仍拿 404。
        match (this.memberRepo.findActive(groupId, userId)) {
            case Some(m) =>
                let gname = match (this.groupRepo.findById(groupId)) {
                    case Some(g) => g.str("name")
                    case None => ""
                }
                return AcceptResult(groupId, gname, m.str("role"), true)
            case None => ()
        }
        let snap = FamilyService.snapshotOf(row)
        let state = snap.stateAt(Times.nowMillis())
        if (state.isDead()) {
            // 统一 404 + 统一文案：区分「已撤销」与「已过期」等于告诉
            // 探测者「这个 token 真的存在过」。
            throw notFound("邀请")
        }
        // ---- code 校验 ----
        // 先做「数据完整性」自检：缺摘要属于内部缺陷，不能伪装成
        // 「邀请码错误」去扣用户的失败次数（上限只有 5 次，扣完就作废）。
        let storedHash = row.str("code_hash")
        let storedSalt = row.str("code_salt")
        if (storedHash.isEmpty() || storedSalt.isEmpty()) {
            throw AppError(
                AppErrorKind.Internal,
                "邀请数据不完整（缺少 code 摘要），请联系管理员重新生成邀请"
            )
        }
        let normalized = InviteCode.normalize(code)
        if (!InviteCode.isWellFormed(normalized)) {
            let fails = this.inviteRepo.bumpFail(inviteId)
            throw AppError(
                AppErrorKind.Forbidden,
                "邀请码不正确（已连续错误 ${fails} 次）"
            )
        }
        let actual = this.hmacHex(storedSalt, normalized)
        if (!this.constantTimeEq(actual, storedHash)) {
            let fails = this.inviteRepo.bumpFail(inviteId)
            throw AppError(
                AppErrorKind.Forbidden,
                "邀请码不正确（已连续错误 ${fails} 次）"
            )
        }
        // 走到这里说明「邀请有效 + code 正确 + 调用者还不是成员」，
        // 三个条件都满足才消耗次数。
        // ---- 原子消耗一次 ----
        if (!this.inviteRepo.consumeOnce(inviteId)) {
            throw notFound("邀请")
        }
        let targetRole = FamilyRole.fromCode(row.str("target_role"))
        let (_, _) = this.memberRepo.join(
            groupId, userId, targetRole.code(), row.i64("inviter_id")
        )
        let gname = match (this.groupRepo.findById(groupId)) {
            case Some(g) => g.str("name")
            case None => ""
        }
        return AcceptResult(groupId, gname, targetRole.code(), false)
    }

    // ============================================================
    // 成员
    // ============================================================

    /** 成员列表（组内成员均可看）。 */
    public func listMembers(groupId: Int64, userId: Int64): RowSet {
        this.requireRole(groupId, userId)
        return this.memberRepo.listByGroup(groupId)
    }

    /**
     * 移除成员：撤销其在本组的全部授权 + 移除成员行。
     *
     * 不吊销全局会话（docs/14 §13 R2：会影响其个人使用），
     * 但授权撤销是**立即生效**的 —— 可见性每次请求现算，没有缓存。
     *
     * @return 被撤销的授权条数
     */
    public func removeMember(groupId: Int64, targetUserId: Int64, operatorId: Int64): Int64 {
        let role = this.requireRole(groupId, operatorId)
        let targetRole = match (this.memberRepo.findActive(groupId, targetUserId)) {
            case Some(m) => FamilyRole.fromCode(m.str("role"))
            case None => throw notFound("成员")
        }
        if (!role.canRemove(targetRole)) {
            throw forbidden(message: "无权移除该成员")
        }
        if (targetUserId == operatorId) {
            throw validationError("userId", "不能移除自己；如需退出请联系组所有者")
        }
        let revoked = this.grantRepo.revokeAll(groupId, targetUserId, "member_removed")
        this.memberRepo.remove(groupId, targetUserId, operatorId)
        return revoked
    }

    // ============================================================
    // 授权
    // ============================================================

    /**
     * 创建授权。
     *
     * 三重校验（docs/14 §3 原则 9）：
     *   ① 操作人必须是组内 owner/manager；
     *   ② 操作人必须**拥有**该主体（不能拿别人的档案做人情）；
     *   ③ 被授权人必须是本组有效成员。
     * 另外条目级授权时校验条目确实属于该主体。
     */
    public func createGrant(
        groupId: Int64,
        operatorId: Int64,
        granteeId: Int64,
        subjectId: Int64,
        itemId: Int64,
        category: Int64,
        expiresAtMs: Int64
    ): Int64 {
        let role = this.requireRole(groupId, operatorId)
        if (!role.canGrant()) {
            throw forbidden(message: "只有组所有者或管理员可以授权")
        }
        if (subjectId <= 0) {
            throw validationError("subjectId", "缺少档案主体 ID")
        }
        // ② 只能授出自己拥有的主体
        let owned = this.userRepo.listOwnedSubjectIds(operatorId)
        var owns = false
        for (s in owned) {
            if (s == "${subjectId}") {
                owns = true
                break
            }
        }
        if (!owns) {
            throw forbidden(message: "只能授权自己名下的档案")
        }
        // ③ 被授权人必须是本组有效成员
        match (this.memberRepo.findActive(groupId, granteeId)) {
            case Some(_) => ()
            case None => throw validationError("granteeId", "该用户不是本组成员")
        }
        let normCategory = GrantScope.normalizeCategory(category)
        // 条目级授权：条目必须属于该主体，否则会造出「挂在 A 主体下
        // 却指向 B 主体条目」的授权 —— covers() 只比 itemId，于是它
        // 真的能读到那条不属于本主体的条目。
        if (itemId > 0) {
            match (this.itemRepo.findByIdRaw(itemId)) {
                case Some(it) =>
                    if (it.subjectId != "${subjectId}") {
                        throw validationError("itemId", "该条目不属于所选主体")
                    }
                case None => throw notFound("条目")
            }
        }
        // 本期仅只读（docs/14 §1.3 非目标：不做写协作）
        let perms = "archive:read:own"
        return this.grantRepo.create(
            groupId, subjectId, itemId, normCategory, granteeId, perms,
            operatorId, expiresAtMs
        )
    }

    /** 组内授权列表。 */
    public func listGrants(groupId: Int64, operatorId: Int64): RowSet {
        let role = this.requireRole(groupId, operatorId)
        if (!role.canGrant()) {
            throw forbidden(message: "只有组所有者或管理员可以查看授权")
        }
        return this.grantRepo.listByGroup(groupId, 100)
    }

    /** 撤销授权（只能撤销本组的授权）。 */
    public func revokeGrant(groupId: Int64, grantId: Int64, operatorId: Int64): Bool {
        let role = this.requireRole(groupId, operatorId)
        if (!role.canGrant()) {
            throw forbidden(message: "只有组所有者或管理员可以撤销授权")
        }
        if (!this.grantRepo.belongsToGroup(grantId, groupId)) {
            // 不属于本组 → 当作不存在，避免用 grantId 探测别组的授权
            throw notFound("授权")
        }
        return this.grantRepo.revoke(grantId, "manual")
    }

    /**
     * 按授权 ID 撤销（路径里没有 groupId 时的入口）。
     *
     * 先反查归属组再校验权限：否则任何登录用户都能拿别人的 grantId
     * 把自己的授权撤掉（撤销是破坏性操作，越权撤销同样有害）。
     */
    public func revokeGrantById(grantId: Int64, operatorId: Int64): Bool {
        let groupId = this.grantRepo.groupOf(grantId)
        if (groupId <= 0) {
            throw notFound("授权")
        }
        return this.revokeGrant(groupId, grantId, operatorId)
    }

    /**
     * 按邀请 ID 撤销（路径里没有 groupId 时的入口）。
     */
    public func revokeInviteById(inviteId: Int64, operatorId: Int64): Bool {
        let groupId = match (this.inviteRepo.findById(inviteId)) {
            case Some(r) => r.i64("group_id")
            case None => throw notFound("邀请")
        }
        return this.revokeInvite(groupId, inviteId, operatorId)
    }

    // ============================================================
    // 成员视角：被授权的条目（只读出口）
    // ============================================================

    /** 我作为家庭成员被授权可见的条目（分页）。 */
    public func listSharedItems(userId: Int64, limit: Int64, offset: Int64): RowSet {
        if (userId <= 0) {
            throw AppError(AppErrorKind.Unauthorized, "未认证")
        }
        return this.grantRepo.listSharedItems(userId, limit, offset)
    }

    /** 我可见的授权条目总数。 */
    public func countSharedItems(userId: Int64): Int64 {
        return this.grantRepo.countSharedItems(userId)
    }

    /**
     * 单条只读读取（家庭成员视角）。
     *
     * 读不到一律 404 —— 与 `ShareRoutes` 同口径：区分「不存在」与
     * 「无权」等于确认条目存在。
     */
    public func sharedItemDetail(userId: Int64, itemId: Int64): Option<ItemRecord> {
        if (!this.grantRepo.canReadItem(userId, itemId)) {
            return None
        }
        return this.itemRepo.findByIdRaw(itemId)
    }

    // ============================================================
    // 内部工具
    // ============================================================

    /** 取成员角色，不在组内则 403（不区分「组不存在」）。 */
    private func requireRole(groupId: Int64, userId: Int64): FamilyRole {
        return match (this.myRole(groupId, userId)) {
            case Some(r) => r
            case None => throw forbidden(message: "无权访问该家庭组")
        }
    }

    /** 取加密提供者（缺失即抛错，绝不降级）。 */
    private func provider(): CryptoProvider {
        return match (this.crypto) {
            case Some(c) => c
            case None => throw AppError(
                AppErrorKind.Internal,
                "服务未配置加密提供者，无法处理家庭邀请"
            )
        }
    }

    /**
     * 邀请人昵称（落地页「请核对是谁邀请你」用）。
     *
     * 昵称为空时回落到用户名首 2 字符 + 星号：落地页必须能核对身份，
     * 但也不该把完整用户名摆在一个公开页面上。
     */
    private func nicknameOf(userId: Int64): String {
        let rec = match (this.userRepo.findById(userId)) {
            case Some(u) => u
            case None => return ""
        }
        let nick = rec.nickname.trimAscii()
        if (!nick.isEmpty()) {
            return nick
        }
        let uname = rec.username
        if (uname.toArray().size <= 2) {
            return uname
        }
        return uname[0..2] + "***"
    }

    /** 取签名密钥（空即抛错）。 */
    private func signKeyOrThrow(): String {
        if (this.signKey.isEmpty()) {
            throw AppError(
                AppErrorKind.Internal,
                "服务未配置签名密钥（AMS_EXPORT_SIGN_KEY / AMS_TOKEN_SECRET），无法处理家庭邀请"
            )
        }
        return this.signKey
    }

    /** HMAC-SM3 十六进制摘要（与全仓国密口径一致）。 */
    private func hmacHex(key: String, data: String): String {
        let prov = this.provider()
        match (prov.hmac(key.toArray(), data.toArray(), DigestAlgorithm.Sm3)) {
            case CryptoResult.Ok(bytes) => return FamilyService.hex(bytes)
            case CryptoResult.Err(e) => throw e
        }
    }

    /** 定时无关比较。 */
    private func constantTimeEq(a: String, b: String): Bool {
        let prov = this.provider()
        return prov.constantTimeEquals(a.toArray(), b.toArray())
    }

    private static func snapshotOf(row: RowData): InviteSnapshot {
        return InviteSnapshot(
            row.bool("revoked"),
            row.i64("expires_ms"),
            row.i64("used_count"),
            row.i64("max_uses"),
            row.i64("fail_count"),
            row.i64("max_fails")
        )
    }

    private static func hex(bytes: Array<Byte>): String {
        let digits = ["0", "1", "2", "3", "4", "5", "6", "7",
                      "8", "9", "a", "b", "c", "d", "e", "f"]
        let sb = StringBuilder()
        for (b in bytes) {
            let v = Int64(b)
            sb.append(digits[(v >> 4) & 15])
            sb.append(digits[v & 15])
        }
        return sb.toString()
    }
}

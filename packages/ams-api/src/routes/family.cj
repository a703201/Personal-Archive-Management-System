// ============================================================
// ams.api.routes.family · 家庭成员邀请与轻量协作（FR-ACL-010 · 方案 B）
//
// 路由分组：
//   公开（无需登录）：
//     GET  /api/family/invites/:token          邀请落地页元数据（含组名+邀请人昵称）
//   已登录（不要求功能权限 —— 见下方说明）：
//     POST /api/family/invites/accept          接受邀请入组
//     GET  /api/family/groups                  我加入的组
//     GET  /api/family/groups/:id              组详情
//     GET  /api/family/groups/:id/members      成员列表
//     GET  /api/family/shared-items            我被授权可见的条目（只读出口）
//     GET  /api/family/shared-items/:id        单条只读
//   需要 family:manage：
//     POST   /api/family/groups                      建组
//     DELETE /api/family/groups/:id                  解散
//     DELETE /api/family/groups/:id/members/:userId  移除成员
//   需要 family:invite：
//     POST   /api/family/groups/:id/invites   创建邀请（code/token 仅此一次返回）
//     GET    /api/family/groups/:id/invites   邀请列表
//     DELETE /api/family/invites/:id          撤销邀请
//     POST   /api/family/groups/:id/grants    创建授权
//     GET    /api/family/groups/:id/grants    授权列表
//     DELETE /api/family/grants/:id           撤销授权
//
// 【为什么 /shared-items 不挂功能权限】
//   新注册账号默认**没有任何角色**（默认拒绝是刻意设计），而
//   docs/14 §3 T3 又明确「入组不改变成员的全局权限」。若这条只读出口
//   也要求 archive:read:own，家人必须先找管理员开角色才能看到东西 ——
//   功能等于不可用；若为此自动写 sys_user_roles，就违背了 T3。
//   故单开一条「只认授权、不认角色」的通道：内部由 acl_grants 判定，
//   一条多余的数据也读不到，且**不提供任何写/删/导出/分享操作**。
//
// 【审计】
//   项目约定审计在路由层落痕（与 ExportRoutes / SystemRoutes 一致），
//   故本文件持有 AuditRecorder，服务层只返回足够的信息供 detail 使用。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.app.audit.*
import ams.app.family.*
import ams.core.family.*
import ams.core.search.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.log.*
import ams.kernel.time.*
import ams.security.audit.*

/**
 * 家庭协作接口。
 */
public class FamilyRoutes {
    private let service: FamilyService
    private let recorder: AuditRecorder

    public init(service: FamilyService, recorder: AuditRecorder) {
        this.service = service
        this.recorder = recorder
    }

    public func register(router: Router): Unit {
        // ---- 公开：落地页元数据 ----
        // 必须放在 :id 类路由之前注册 —— 两者段数相同（4 段），
        // 虽然方法不同（GET vs DELETE）不会误匹配，但显式排前面更直观。
        router.get("/api/family/invites/:token", { req: ApiRequest => this.inviteMeta(req) },
            isPublic: true)

        // ---- 邀请接受 ----
        router.post("/api/family/invites/accept", { req: ApiRequest => this.accept(req) })
        router.delete("/api/family/invites/:id", { req: ApiRequest => this.revokeInvite(req) },
            requiredPerm: "family:invite")

        // ---- 家庭组 ----
        router.post("/api/family/groups", { req: ApiRequest => this.createGroup(req) },
            requiredPerm: "family:manage")
        router.get("/api/family/groups", { req: ApiRequest => this.listGroups(req) })
        router.get("/api/family/groups/:id", { req: ApiRequest => this.groupDetail(req) })
        router.delete("/api/family/groups/:id", { req: ApiRequest => this.dissolve(req) },
            requiredPerm: "family:manage")

        // ---- 成员 ----
        router.get("/api/family/groups/:id/members", { req: ApiRequest => this.listMembers(req) })
        router.delete("/api/family/groups/:id/members/:userId",
            { req: ApiRequest => this.removeMember(req) },
            requiredPerm: "family:manage")

        // ---- 邀请（组内）----
        router.post("/api/family/groups/:id/invites",
            { req: ApiRequest => this.createInvite(req) }, requiredPerm: "family:invite")
        router.get("/api/family/groups/:id/invites",
            { req: ApiRequest => this.listInvites(req) }, requiredPerm: "family:invite")

        // ---- 授权 ----
        router.post("/api/family/groups/:id/grants",
            { req: ApiRequest => this.createGrant(req) }, requiredPerm: "family:invite")
        router.get("/api/family/groups/:id/grants",
            { req: ApiRequest => this.listGrants(req) }, requiredPerm: "family:invite")
        router.delete("/api/family/grants/:id", { req: ApiRequest => this.revokeGrant(req) },
            requiredPerm: "family:invite")

        // ---- 成员视角：被授权的条目（只读）----
        router.get("/api/family/shared-items", { req: ApiRequest => this.sharedItems(req) })
        router.get("/api/family/shared-items/:id", { req: ApiRequest => this.sharedItem(req) })
    }

    // ============================================================
    // 家庭组
    // ============================================================

    private func createGroup(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let json = FamilyRoutes.body(req)
        let name = FamilyRoutes.strOf(json, "name", "")
        let groupId = this.service.createGroup(name, uid)
        this.audit(req, AuditAction.FamilyGroupCreate, "family_group", "${groupId}",
                   [("groupId", "${groupId}"), ("name", name)])
        return ApiResponse.ok(
            "{\"groupId\":\"${groupId}\",\"role\":\"owner\"}", req.requestId)
    }

    private func listGroups(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let rows = this.service.listGroups(uid)
        let sb = StringBuilder()
        sb.append("{\"items\":[")
        var first = true
        for (r in rows.all().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("{\"groupId\":\"${r.str("id")}\",")
            sb.append("\"name\":\"${ApiResponse.escape(r.str("name"))}\",")
            sb.append("\"ownerId\":\"${r.str("owner_id")}\",")
            sb.append("\"myRole\":\"${ApiResponse.escape(r.str("my_role"))}\",")
            sb.append("\"memberCount\":${r.i64("member_count")},")
            sb.append("\"createdAt\":${r.i64("created_ms")}}")
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * 组详情。
     *
     * 非成员一律 403 且**不返回组名** —— 区分「组不存在」与「你不在组里」
     * 等于把组的存在性变成探测信号（docs/14 §9.4）。
     */
    private func groupDetail(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let groupId = FamilyRoutes.idOf(req, "id")
        let role = match (this.service.myRole(groupId, uid)) {
            case Some(r) => r
            case None =>
                this.audit(req, AuditAction.FamilyAccessDenied, "family_group", "${groupId}",
                           [("groupId", "${groupId}"), ("reason", "not_member")])
                throw forbidden(message: "无权访问该家庭组")
        }
        let g = match (this.service.groupDetail(groupId)) {
            case Some(v) => v
            case None => throw notFound("家庭组")
        }
        let sb = StringBuilder()
        sb.append("{\"groupId\":\"${g.str("id")}\",")
        sb.append("\"name\":\"${ApiResponse.escape(g.str("name"))}\",")
        sb.append("\"ownerId\":\"${g.str("owner_id")}\",")
        sb.append("\"myRole\":\"${role.code()}\",")
        sb.append("\"canInvite\":${if (role.canInvite()) { "true" } else { "false" }},")
        sb.append("\"canGrant\":${if (role.canGrant()) { "true" } else { "false" }},")
        sb.append("\"canDissolve\":${if (role.canDissolve()) { "true" } else { "false" }},")
        sb.append("\"createdAt\":${g.i64("created_ms")}}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    private func dissolve(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let groupId = FamilyRoutes.idOf(req, "id")
        let revoked = this.service.dissolveGroup(groupId, uid)
        this.audit(req, AuditAction.FamilyGroupDissolve, "family_group", "${groupId}",
                   [("groupId", "${groupId}"), ("revokedGrants", "${revoked}")])
        return ApiResponse.ok(
            "{\"dissolved\":true,\"revokedGrants\":${revoked}}", req.requestId)
    }

    // ============================================================
    // 邀请
    // ============================================================

    private func createInvite(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let groupId = FamilyRoutes.idOf(req, "id")
        let json = FamilyRoutes.body(req)
        let targetRole = FamilyRoutes.strOf(json, "targetRole", "member")
        let minutes = FamilyRoutes.intOf(json, "expiresInMinutes", 0)
        let maxUses = FamilyRoutes.intOf(json, "maxUses", 0)
        let maxFails = FamilyRoutes.intOf(json, "maxFails", 0)
        let created = this.service.createInvite(
            groupId, uid, targetRole, minutes, maxUses, maxFails)
        // ⚠️ 审计 detail **只写 ID 与计数，绝不写 code/token 明文**（docs/14 §8）
        this.audit(req, AuditAction.FamilyInviteCreate, "fam_invite", "${created.inviteId}", [
            ("groupId", "${groupId}"),
            ("inviteId", "${created.inviteId}"),
            ("targetRole", targetRole),
            ("maxUses", "${created.maxUses}"),
            ("expiresAt", "${created.expiresMs}")
        ])
        let sb = StringBuilder()
        sb.append("{\"inviteId\":\"${created.inviteId}\",")
        sb.append("\"code\":\"${ApiResponse.escape(created.code)}\",")
        sb.append("\"token\":\"${ApiResponse.escape(created.token)}\",")
        sb.append("\"link\":\"/invite/${created.token}\",")
        sb.append("\"maxUses\":${created.maxUses},")
        sb.append("\"expiresAt\":${created.expiresMs}}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    private func listInvites(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let groupId = FamilyRoutes.idOf(req, "id")
        let rows = this.service.listInvites(groupId, uid)
        let now = Times.nowMillis()
        let sb = StringBuilder()
        sb.append("{\"items\":[")
        var first = true
        for (r in rows.all().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            let snap = InviteSnapshot(
                r.bool("revoked"), r.i64("expires_ms"), r.i64("used_count"),
                r.i64("max_uses"), r.i64("fail_count"), r.i64("max_fails"))
            let state = snap.stateAt(now)
            sb.append("{\"inviteId\":\"${r.str("id")}\",")
            sb.append("\"targetRole\":\"${ApiResponse.escape(r.str("target_role"))}\",")
            sb.append("\"maxUses\":${r.i64("max_uses")},")
            sb.append("\"usedCount\":${r.i64("used_count")},")
            sb.append("\"failCount\":${r.i64("fail_count")},")
            sb.append("\"remainingUses\":${snap.remainingUses(now)},")
            sb.append("\"revoked\":${if (r.bool("revoked")) { "true" } else { "false" }},")
            sb.append("\"state\":\"${state.reason()}\",")
            sb.append("\"expiresAt\":${r.i64("expires_ms")},")
            sb.append("\"createdAt\":${r.i64("created_ms")}}")
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    private func revokeInvite(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let inviteId = FamilyRoutes.idOf(req, "id")
        let ok = this.service.revokeInviteById(inviteId, uid)
        if (!ok) {
            throw notFound("邀请")
        }
        this.audit(req, AuditAction.FamilyInviteRevoke, "fam_invite", "${inviteId}",
                   [("inviteId", "${inviteId}")])
        return ApiResponse.ok("{\"revoked\":true}", req.requestId)
    }

    /**
     * GET /api/family/invites/:token —— 公开落地页元数据。
     *
     * 无效邀请回 200 + `valid=false`，不抛 404：落地页需要正常渲染，
     * 而「接口报错」会让用户以为是网络问题、反复重试。
     */
    private func inviteMeta(req: ApiRequest): ApiResponse {
        let token = req.pathParam("token") ?? ""
        let meta = this.service.inviteMeta(token)
        let sb = StringBuilder()
        sb.append("{\"valid\":${if (meta.valid) { "true" } else { "false" }},")
        sb.append("\"groupName\":\"${ApiResponse.escape(meta.groupName)}\",")
        sb.append("\"inviter\":\"${ApiResponse.escape(meta.inviterNick)}\",")
        sb.append("\"expiresAt\":${meta.expiresMs},")
        sb.append("\"remainingUses\":${meta.remainingUses}}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    private func accept(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let json = FamilyRoutes.body(req)
        let token = FamilyRoutes.strOf(json, "token", "")
        let code = FamilyRoutes.strOf(json, "code", "")
        if (token.isEmpty()) {
            throw validationError("token", "缺少邀请链接标识")
        }
        try {
            let r = this.service.acceptInvite(token, code, uid)
            this.audit(req, AuditAction.FamilyInviteAccept, "family_group", "${r.groupId}", [
                ("groupId", "${r.groupId}"),
                ("role", r.role),
                ("alreadyMember", if (r.alreadyMember) { "true" } else { "false" })
            ])
            let sb = StringBuilder()
            sb.append("{\"groupId\":\"${r.groupId}\",")
            sb.append("\"groupName\":\"${ApiResponse.escape(r.groupName)}\",")
            sb.append("\"role\":\"${ApiResponse.escape(r.role)}\",")
            sb.append("\"alreadyMember\":${if (r.alreadyMember) { "true" } else { "false" }}}")
            return ApiResponse.ok(sb.toString(), req.requestId)
        } catch (e: AppError) {
            // 邀请码错误要留痕（docs/14 §8：family.invite.fail）。
            // 仓颉自定义枚举没有内建 `==`，只能用 match 判定。
            let badCode = match (e.kind) {
                case AppErrorKind.Forbidden => true
                case _ => false
            }
            if (badCode) {
                this.audit(req, AuditAction.FamilyInviteFail, "fam_invite", "", [
                    ("reason", "bad_code")
                ])
            }
            throw e
        }
    }

    // ============================================================
    // 成员
    // ============================================================

    private func listMembers(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let groupId = FamilyRoutes.idOf(req, "id")
        let rows = this.service.listMembers(groupId, uid)
        let sb = StringBuilder()
        sb.append("{\"items\":[")
        var first = true
        for (r in rows.all().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("{\"userId\":\"${r.str("user_id")}\",")
            sb.append("\"nickname\":\"${ApiResponse.escape(r.str("nickname"))}\",")
            sb.append("\"username\":\"${ApiResponse.escape(r.str("username"))}\",")
            sb.append("\"role\":\"${ApiResponse.escape(r.str("role"))}\",")
            sb.append("\"joinedAt\":${r.i64("joined_ms")},")
            sb.append("\"invitedBy\":\"${r.str("invited_by")}\"}")
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    private func removeMember(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let groupId = FamilyRoutes.idOf(req, "id")
        let target = FamilyRoutes.idOf(req, "userId")
        let revoked = this.service.removeMember(groupId, target, uid)
        this.audit(req, AuditAction.FamilyMemberRemove, "family_member", "${target}", [
            ("groupId", "${groupId}"),
            ("userId", "${target}"),
            ("revokedGrants", "${revoked}")
        ])
        return ApiResponse.ok(
            "{\"removed\":true,\"revokedGrants\":${revoked}}", req.requestId)
    }

    // ============================================================
    // 授权
    // ============================================================

    private func createGrant(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let groupId = FamilyRoutes.idOf(req, "id")
        let json = FamilyRoutes.body(req)
        let granteeId = FamilyRoutes.intOf(json, "granteeId", 0)
        let subjectId = FamilyRoutes.intOf(json, "subjectId", 0)
        let itemId = FamilyRoutes.intOf(json, "itemId", 0)
        let category = FamilyRoutes.intOf(json, "category", 0)
        let hours = FamilyRoutes.intOf(json, "expiresInHours", 0)
        if (granteeId <= 0) {
            throw validationError("granteeId", "缺少被授权人")
        }
        let expiresAtMs = if (hours > 0) {
            Times.nowMillis() + hours * 3600 * 1000
        } else {
            0
        }
        let grantId = this.service.createGrant(
            groupId, uid, granteeId, subjectId, itemId, category, expiresAtMs)
        let scope = GrantScope.resourceTypeOf("${itemId}", category)
        this.audit(req, AuditAction.FamilyGrantCreate, "acl_grant", "${grantId}", [
            ("groupId", "${groupId}"),
            ("granteeId", "${granteeId}"),
            ("subjectId", "${subjectId}"),
            ("resourceType", scope),
            ("itemId", "${itemId}"),
            ("category", "${category}"),
            ("expiresAt", "${expiresAtMs}")
        ])
        let sb = StringBuilder()
        sb.append("{\"grantId\":\"${grantId}\",")
        sb.append("\"resourceType\":\"${scope}\",")
        sb.append("\"expiresAt\":${expiresAtMs}}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    private func listGrants(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let groupId = FamilyRoutes.idOf(req, "id")
        let rows = this.service.listGrants(groupId, uid)
        let sb = StringBuilder()
        sb.append("{\"items\":[")
        var first = true
        for (r in rows.all().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            let itemId = r.str("item_id")
            let cat = r.i64("category")
            let scope = GrantScope.resourceTypeOf(itemId, cat)
            sb.append("{\"grantId\":\"${r.str("id")}\",")
            sb.append("\"granteeId\":\"${r.str("grantee_id")}\",")
            sb.append("\"subjectId\":\"${r.str("subject_id")}\",")
            sb.append("\"itemId\":\"${itemId}\",")
            sb.append("\"category\":${cat},")
            sb.append("\"resourceType\":\"${scope}\",")
            sb.append("\"perms\":\"${ApiResponse.escape(r.str("perm_codes"))}\",")
            sb.append("\"active\":${if (r.bool("active")) { "true" } else { "false" }},")
            sb.append("\"expiresAt\":${r.i64("expires_ms")},")
            sb.append("\"grantedAt\":${r.i64("granted_ms")}}")
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    private func revokeGrant(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let grantId = FamilyRoutes.idOf(req, "id")
        let ok = this.service.revokeGrantById(grantId, uid)
        if (!ok) {
            throw notFound("授权")
        }
        this.audit(req, AuditAction.FamilyGrantRevoke, "acl_grant", "${grantId}",
                   [("grantId", "${grantId}")])
        return ApiResponse.ok("{\"revoked\":true}", req.requestId)
    }

    // ============================================================
    // 成员视角：被授权的条目
    // ============================================================

    private func sharedItems(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let page = FamilyRoutes.longOf(req.queryParam("page") ?? "", 1)
        let size = FamilyRoutes.clamp(FamilyRoutes.longOf(req.queryParam("size") ?? "", 20), 1, 100)
        let rows = this.service.listSharedItems(uid, size, (page - 1) * size)
        let total = this.service.countSharedItems(uid)
        let sb = StringBuilder()
        sb.append("{\"total\":${total},\"page\":${page},\"size\":${size},\"items\":[")
        var first = true
        for (r in rows.all().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            let sens = r.i64("sensitivity")
            let high = sens >= 3
            let issuer = if (high) { "" } else { Masker.mask(r.str("issuer"), sens) }
            let remark = if (high) { "" } else { Masker.mask(r.str("remark"), sens) }
            sb.append("{\"id\":\"${r.str("id")}\",")
            sb.append("\"subjectId\":\"${r.str("subject_id")}\",")
            sb.append("\"category\":${r.i64("category")},")
            sb.append("\"title\":\"${ApiResponse.escape(r.str("title"))}\",")
            sb.append("\"status\":${r.i64("status")},")
            sb.append("\"sensitivity\":${sens},")
            sb.append("\"issuer\":\"${ApiResponse.escape(issuer)}\",")
            sb.append("\"issuedDate\":\"${ApiResponse.escape(r.str("issued_date"))}\",")
            sb.append("\"expiresAt\":\"${ApiResponse.escape(r.str("expires_at"))}\",")
            sb.append("\"remark\":\"${ApiResponse.escape(remark)}\",")
            sb.append("\"updatedAt\":${r.i64("updated_ms")},")
            sb.append("\"shared\":true}")
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    private func sharedItem(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let itemId = FamilyRoutes.idOf(req, "id")
        let item = match (this.service.sharedItemDetail(uid, itemId)) {
            case Some(v) => v
            case None =>
                this.audit(req, AuditAction.FamilyAccessDenied, "archive_item", "${itemId}",
                           [("itemId", "${itemId}"), ("reason", "not_granted")])
                // 与共享链接同口径：读不到一律 404，不确认条目是否存在
                throw notFound("条目")
        }
        let sens = item.sensitivity
        let high = sens >= 3
        let issuer = if (high) { "" } else { Masker.mask(item.issuer, sens) }
        let remark = if (high) { "" } else { Masker.mask(item.remark, sens) }
        let sb = StringBuilder()
        sb.append("{\"id\":\"${item.id}\",")
        sb.append("\"subjectId\":\"${item.subjectId}\",")
        sb.append("\"category\":${item.category},")
        sb.append("\"title\":\"${ApiResponse.escape(item.title)}\",")
        sb.append("\"status\":${item.status},")
        sb.append("\"sensitivity\":${sens},")
        sb.append("\"issuer\":\"${ApiResponse.escape(issuer)}\",")
        sb.append("\"issuedDate\":\"${ApiResponse.escape(item.issuedDate)}\",")
        sb.append("\"expiresAt\":\"${ApiResponse.escape(item.expiresAt)}\",")
        sb.append("\"remark\":\"${ApiResponse.escape(remark)}\",")
        sb.append("\"updatedAt\":${item.updatedAt},")
        sb.append("\"shared\":true}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    // ============================================================
    // 工具
    // ============================================================

    /**
     * 落一条审计（尽力而为）。
     *
     * 写审计失败不应让已经成功的业务动作变成错误响应 —— 但要留 WARN，
     * 因为这是安全能力降级，不能静默（与 AuditRoutes.selfAudit 同策略）。
     */
    private func audit(
        req: ApiRequest,
        action: AuditAction,
        targetType: String,
        targetId: String,
        detail: Array<(String, String)>
    ): Unit {
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
                req.subjectId, ActorType.User, action, targetType, targetId,
                "", 0, AuditResult.Success, "", ip, ua, req.requestId, detail
            )
        } catch (e: Exception) {
            Log.get().warn("family.audit_failed", None, [
                ("action", action.code()),
                ("reason", e.message)
            ])
        }
    }

    private static func body(req: ApiRequest): SimpleJson {
        let raw = req.bodyText().trimAscii()
        if (raw.isEmpty()) {
            return SimpleJson.parse("{}").getOrThrow()
        }
        return match (SimpleJson.parse(raw)) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
    }

    private static func idOf(req: ApiRequest, key: String): Int64 {
        let raw = req.pathParam(key) ?? ""
        let v = RowData.toI64(raw)
        if (v <= 0) {
            throw validationError(key, "路径参数不是合法的 ID")
        }
        return v
    }

    private static func strOf(j: SimpleJson, key: String, def: String): String {
        return match (j.get(key)) {
            case Some(v) => v
            case None => def
        }
    }

    private static func intOf(j: SimpleJson, key: String, def: Int64): Int64 {
        return match (j.get(key)) {
            case Some(v) => if (v.isEmpty()) { def } else { RowData.toI64(v) }
            case None => def
        }
    }

    private static func longOf(raw: String, def: Int64): Int64 {
        if (raw.isEmpty()) {
            return def
        }
        let v = RowData.toI64(raw)
        if (v <= 0) {
            return def
        }
        return v
    }

    private static func clamp(v: Int64, lo: Int64, hi: Int64): Int64 {
        if (v < lo) {
            return lo
        }
        if (v > hi) {
            return hi
        }
        return v
    }
}

// ============================================================
// ams.api.routes.management · 管理类 HTTP 接口
//
// 需求：
//   FR-CFG-001 用户管理（列表 / 详情 / 新建 / 改口令 / 启停用 / 解锁 / 删除）
//   FR-CFG-002 角色与权限管理（角色列表 / 权限点列表 / 分配权限）
//   FR-CFG-004 数据字典管理（字典类型 / 字典项）
//   FR-TAG-001 标签 CRUD
//   FR-TAG-002 标签关联条目
//   FR-NTF-001 站内通知（列表 / 未读数 / 标记已读）
//
// [权限点映射]
//   GET    /api/users                user:read
//   POST   /api/users                user:manage
//   POST   /api/users/:id/password   user:manage
//   POST   /api/users/:id/status     user:manage
//   POST   /api/users/:id/unlock     user:manage
//   DELETE /api/users/:id            user:manage
//   GET    /api/roles                role:read
//   GET    /api/perms                role:read
//   POST   /api/roles/:code/perms    role:manage
//   GET    /api/tags                 tag:read
//   POST   /api/tags                 tag:write
//   PUT    /api/tags/:id             tag:write
//   DELETE /api/tags/:id             tag:write
//   POST   /api/items/:id/tags       tag:write
//   DELETE /api/items/:id/tags/:tid  tag:write
//   GET    /api/notifications        notify:read
//   GET    /api/notifications/unread notify:read
//   POST   /api/notifications/:id/read notify:read
//   POST   /api/notifications/read-all notify:read
//   GET    /api/dict                 dict:read
//   POST   /api/dict                 dict:manage
//
// [安全约束]
//   ① 所有管理接口都要求登录且校验功能权限（由鉴权中间件执行）；
//   ② 标签操作强制按 owner_id 隔离（仓储层已实现，接口层只传当前用户 ID）；
//   ③ 口令哈希**永不出现在**任何响应里；
//   ④ 删除类接口一律软删除（DB 层 deleted_at）。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.crypto.provider.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.id.*
import ams.kernel.log.*
import ams.security.authn.*

/**
 * 管理类接口处理器集合。
 */
public class ManagementRoutes {
    private let userRepo: UserRepo
    private let roleRepo: RoleRepo
    private let tagRepo: TagRepo
    private let notifyRepo: NotifyRepo
    private let configRepo: ConfigRepo
    private let hasher: PasswordHasher
    /**
     * 口令策略校验器（FR-AUTH-004）。
     *
     * ⚠️ 此前本类**从不调用**校验器 —— 策略规则虽已实现且有单测，
     *    但实际未生效（弱口令、过短口令都能建账号）。
     *    现已在 createUser / resetPassword 两处强制执行。
     */
    private let passwordValidator: PasswordValidator
    /** 口令策略（用于取最小修改间隔） */
    private let passwordPolicy: PasswordPolicy

    public init(
        userRepo: UserRepo,
        roleRepo: RoleRepo,
        tagRepo: TagRepo,
        notifyRepo: NotifyRepo,
        configRepo: ConfigRepo,
        hasher: PasswordHasher,
        passwordValidator!: PasswordValidator,
        passwordPolicy!: PasswordPolicy = PasswordPolicy()
    ) {
        this.userRepo = userRepo
        this.roleRepo = roleRepo
        this.tagRepo = tagRepo
        this.notifyRepo = notifyRepo
        this.configRepo = configRepo
        this.hasher = hasher
        this.passwordValidator = passwordValidator
        this.passwordPolicy = passwordPolicy
    }

    /**
     * 注册到路由表。
     */
    public func register(router: Router): Unit {
        // ---- 用户管理 ----
        router.get("/api/users", { req: ApiRequest => this.listUsers(req) }, requiredPerm: "user:read:any")
        router.get("/api/users/:id", { req: ApiRequest => this.getUser(req) }, requiredPerm: "user:read:any")
        router.post("/api/users", { req: ApiRequest => this.createUser(req) }, requiredPerm: "user:manage")
        router.post("/api/users/:id/password", { req: ApiRequest => this.resetPassword(req) }, requiredPerm: "user:manage")
        router.post("/api/users/:id/status", { req: ApiRequest => this.setUserStatus(req) }, requiredPerm: "user:manage")
        router.post("/api/users/:id/unlock", { req: ApiRequest => this.unlockUser(req) }, requiredPerm: "user:manage")
        router.delete("/api/users/:id", { req: ApiRequest => this.deleteUser(req) }, requiredPerm: "user:manage")

        // ---- 角色与权限 ----
        router.get("/api/roles", { req: ApiRequest => this.listRoles(req) }, requiredPerm: "acl:manage")
        router.get("/api/perms", { req: ApiRequest => this.listPerms(req) }, requiredPerm: "acl:manage")
        router.post("/api/roles/:code/perms", { req: ApiRequest => this.assignPerms(req) }, requiredPerm: "acl:manage")

        // ---- 角色管理闭环（FR-ACL-002）----
        router.post("/api/roles", { req: ApiRequest => this.createRole(req) }, requiredPerm: "acl:manage")
        router.put("/api/roles/:code", { req: ApiRequest => this.updateRole(req) }, requiredPerm: "acl:manage")
        router.delete("/api/roles/:code", { req: ApiRequest => this.deleteRole(req) }, requiredPerm: "acl:manage")

        // ---- 用户-角色分配（FR-ACL-004）----
        router.get("/api/users/:id/roles", { req: ApiRequest => this.listUserRoles(req) }, requiredPerm: "user:manage")
        router.post("/api/users/:id/roles", { req: ApiRequest => this.assignUserRole(req) }, requiredPerm: "user:manage")
        router.delete("/api/users/:id/roles/:roleCode", { req: ApiRequest => this.revokeUserRole(req) }, requiredPerm: "user:manage")

        // ---- 显式授权（FR-ACL-008）----
        router.post("/api/grants", { req: ApiRequest => this.createGrant(req) }, requiredPerm: "acl:grant:own")
        router.delete("/api/grants/:id", { req: ApiRequest => this.revokeGrant(req) }, requiredPerm: "acl:revoke:own")
        router.get("/api/grants", { req: ApiRequest => this.listGrants(req) }, requiredPerm: "acl:read:own")

        // ---- 标签 ----
        router.get("/api/tags", { req: ApiRequest => this.listTags(req) }, requiredPerm: "tag:read:own")
        router.post("/api/tags", { req: ApiRequest => this.createTag(req) }, requiredPerm: "tag:write:own")
        router.put("/api/tags/:id", { req: ApiRequest => this.updateTag(req) }, requiredPerm: "tag:write:own")
        router.delete("/api/tags/:id", { req: ApiRequest => this.deleteTag(req) }, requiredPerm: "tag:write:own")
        router.post("/api/items/:id/tags", { req: ApiRequest => this.attachTag(req) }, requiredPerm: "tag:write:own")
        router.delete("/api/items/:id/tags/:tagId", { req: ApiRequest => this.detachTag(req) }, requiredPerm: "tag:write:own")

        // ---- 通知 ----
        router.get("/api/notifications", { req: ApiRequest => this.listNotifications(req) }, requiredPerm: "notify:read:own")
        router.get("/api/notifications/unread", { req: ApiRequest => this.unreadCount(req) }, requiredPerm: "notify:read:own")
        router.post("/api/notifications/:id/read", { req: ApiRequest => this.markRead(req) }, requiredPerm: "notify:read:own")
        router.post("/api/notifications/read-all", { req: ApiRequest => this.markAllRead(req) }, requiredPerm: "notify:read:own")

        // ---- 字典 ----
        router.get("/api/dict", { req: ApiRequest => this.listDictTypes(req) }, requiredPerm: "cfg:read")
        router.get("/api/dict/:code/items", { req: ApiRequest => this.listDictItems(req) }, requiredPerm: "cfg:read")
        router.post("/api/dict", { req: ApiRequest => this.createDictType(req) }, requiredPerm: "cfg:dict:manage")
        router.post("/api/dict/:code/items", { req: ApiRequest => this.createDictItem(req) }, requiredPerm: "cfg:dict:manage")
    }

    // ==================== 用户管理 ====================

    private func listUsers(req: ApiRequest): ApiResponse {
        let keyword = req.queryParam("keyword") ?? ""
        let page = ManagementRoutes.intParam(req, "page", 1)
        let size = ManagementRoutes.intParam(req, "size", 20)
        let offset = (page - 1) * size
        let rows = this.userRepo.list(keyword, offset, size)
        let total = this.userRepo.count(keyword)
        return ApiResponse.ok(ManagementRoutes.rowsToJson(rows, "total", "${total}"), req.requestId)
    }

    private func getUser(req: ApiRequest): ApiResponse {
        let id = ManagementRoutes.pathId(req, "id")
        match (this.userRepo.findById(id)) {
            case Some(u) =>
                // 注意：口令哈希**不返回**（UserRecord 里有该字段，此处显式不输出）
                let data = "{\"id\":${u.id},\"username\":\"${ApiResponse.escape(u.username)}\"," +
                    "\"email\":\"${ApiResponse.escape(u.email)}\",\"phone\":\"${ApiResponse.escape(u.phone)}\"," +
                    "\"nickname\":\"${ApiResponse.escape(u.nickname)}\",\"status\":${u.status}," +
                    "\"failedAttempts\":${u.failedAttempts},\"permVersion\":${u.permVersion}," +
                    "\"createdAt\":${u.createdAtMillis},\"version\":${u.version}}"
                return ApiResponse.ok(data, req.requestId)
            case None => throw notFound("用户")
        }
    }

    private func createUser(req: ApiRequest): ApiResponse {
        let json = ManagementRoutes.body(req)
        let username = json.get("username") ?? ""
        let password = json.get("password") ?? ""
        if (username.isEmpty() || password.isEmpty()) {
            throw validationError("username", "用户名与口令不能为空")
        }
        // ---- 口令策略校验（FR-AUTH-004）----
        this.checkPasswordPolicy(password, username)
        // 生成盐与哈希
        var salt: Array<Byte> = Array<Byte>(16, repeat: 0u8)
        match (this.hasher.generateSalt()) {
            case CryptoResult.Ok(b) => salt = b
            case CryptoResult.Err(_) => throw AppError(AppErrorKind.Internal, "口令哈希生成失败")
        }
        var hash = ""
        match (this.hasher.hash(password, salt)) {
            case CryptoResult.Ok(h) => hash = h
            case CryptoResult.Err(_) => throw AppError(AppErrorKind.Internal, "口令哈希生成失败")
        }
        let email = json.get("email")
        let phone = json.get("phone")
        let nickname = json.get("nickname")
        let opId = ManagementRoutes.operatorId(req)
        let id = this.userRepo.create(username, email, phone, nickname, hash, 600000, opId)
        return ApiResponse.ok("{\"id\":${id}}", req.requestId)
    }

    private func resetPassword(req: ApiRequest): ApiResponse {
        let id = ManagementRoutes.pathId(req, "id")
        let json = ManagementRoutes.body(req)
        let password = json.get("password") ?? ""
        if (password.isEmpty()) {
            throw validationError("password", "新口令不能为空")
        }
        // ---- 口令策略校验（FR-AUTH-004）----
        // 重置他人口令时，用**目标用户名**做「口令不得包含用户名」检查
        let targetName = this.userRepo.findById(id).map { u => u.username } ?? ""
        this.checkPasswordPolicy(password, targetName)
        // ---- 两次修改间隔检查（FR-AUTH-004）----
        this.checkPasswordChangeInterval(id)
        var salt: Array<Byte> = Array<Byte>(16, repeat: 0u8)
        match (this.hasher.generateSalt()) {
            case CryptoResult.Ok(b) => salt = b
            case CryptoResult.Err(_) => throw AppError(AppErrorKind.Internal, "口令哈希生成失败")
        }
        var hash = ""
        match (this.hasher.hash(password, salt)) {
            case CryptoResult.Ok(h) => hash = h
            case CryptoResult.Err(_) => throw AppError(AppErrorKind.Internal, "口令哈希生成失败")
        }
        let ok = this.userRepo.updatePassword(id, hash, 600000, ManagementRoutes.operatorId(req))
        if (!ok) {
            throw notFound("用户")
        }
        return ApiResponse.ok("{\"updated\":true}", req.requestId)
    }

    /**
     * 校验口令是否符合策略（FR-AUTH-004）。
     *
     * 校验项：长度、字符类别数、弱口令字典、含用户名、连续重复字符。
     * 失败一律返回 400（校验类错误），不泄露具体是哪一项弱 ——
     * 但给出可读提示，让用户知道怎么改。
     */
    private func checkPasswordPolicy(password: String, username: String): Unit {
        let result = this.passwordValidator.check(password, username)
        match (result) {
            case PasswordCheck.Ok => return
            case PasswordCheck.TooShort(min) =>
                throw validationError("password", "口令长度至少 ${min} 位")
            case PasswordCheck.TooFewCharClasses(min) =>
                throw validationError("password", "口令需包含至少 ${min} 类字符（小写/大写/数字/符号）")
            case PasswordCheck.InWeakDictionary =>
                throw validationError("password", "该口令过于常见，请换一个")
            case PasswordCheck.ContainsUsername =>
                throw validationError("password", "口令不得包含用户名")
            case PasswordCheck.RepeatedChars =>
                throw validationError("password", "口令不得包含连续重复字符")
        }
    }

    /**
     * 校验两次口令修改的最小间隔（FR-AUTH-004，默认 ≥ 24 小时）。
     *
     * 管理员**重置**他人口令时同样受此约束 —— 防止绕过策略
     * （例如用户自己想改却受限，管理员却能随时重置）。
     * 从未设置过口令的账号不受限制。
     */
    private func checkPasswordChangeInterval(userId: Int64): Unit {
        let elapsed = this.userRepo.millisSincePasswordUpdate(userId)
        if (elapsed <= 0) {
            return
        }
        let minMs = this.passwordPolicy.minChangeIntervalHours * 3600 * 1000
        if (elapsed < minMs) {
            let hours = (minMs - elapsed) / 3600000 + 1
            throw validationError("password", "距上次修改口令不足 ${hours} 小时，请稍后再试")
        }
    }

    private func setUserStatus(req: ApiRequest): ApiResponse {
        let id = ManagementRoutes.pathId(req, "id")
        let json = ManagementRoutes.body(req)
        let status = ManagementRoutes.intFrom(json, "status", 0)
        let ok = this.userRepo.setStatus(id, status, ManagementRoutes.operatorId(req))
        if (!ok) {
            throw notFound("用户")
        }
        return ApiResponse.ok("{\"status\":${status}}", req.requestId)
    }

    private func unlockUser(req: ApiRequest): ApiResponse {
        let id = ManagementRoutes.pathId(req, "id")
        // 解锁 = 重置失败计数与锁定时间
        let ok = this.userRepo.unlock(id, ManagementRoutes.operatorId(req))
        if (!ok) {
            throw notFound("用户")
        }
        return ApiResponse.ok("{\"unlocked\":true}", req.requestId)
    }

    private func deleteUser(req: ApiRequest): ApiResponse {
        let id = ManagementRoutes.pathId(req, "id")
        let ok = this.userRepo.softDelete(id, ManagementRoutes.operatorId(req))
        if (!ok) {
            throw notFound("用户")
        }
        return ApiResponse.ok("{\"deleted\":true}", req.requestId)
    }

    // ==================== 角色与权限 ====================

    private func listRoles(req: ApiRequest): ApiResponse {
        let rows = this.roleRepo.listRoles()
        return ApiResponse.ok(ManagementRoutes.rowsToJson(rows, "total", "${rows.size()}"), req.requestId)
    }

    private func listPerms(req: ApiRequest): ApiResponse {
        let rows = this.roleRepo.listPerms()
        return ApiResponse.ok(ManagementRoutes.rowsToJson(rows, "total", "${rows.size()}"), req.requestId)
    }

    private func assignPerms(req: ApiRequest): ApiResponse {
        let code = match (req.pathParam("code")) {
            case Some(c) => c
            case None => throw validationError("code", "缺少角色编码")
        }
        let json = ManagementRoutes.body(req)
        let perms = ManagementRoutes.stringArray(json, "perms")
        let ok = this.roleRepo.assignPerms(code, perms, ManagementRoutes.operatorId(req))
        if (!ok) {
            throw notFound("角色")
        }
        return ApiResponse.ok("{\"assigned\":${perms.size}}", req.requestId)
    }

    // ==================== 标签 ====================

    private func listTags(req: ApiRequest): ApiResponse {
        let ownerId = ManagementRoutes.subjectId(req)
        let rows = this.tagRepo.list(ownerId)
        return ApiResponse.ok(ManagementRoutes.rowsToJson(rows, "total", "${rows.size()}"), req.requestId)
    }

    private func createTag(req: ApiRequest): ApiResponse {
        let json = ManagementRoutes.body(req)
        let name = json.get("name") ?? ""
        if (name.isEmpty()) {
            throw validationError("name", "标签名不能为空")
        }
        let ownerId = ManagementRoutes.subjectId(req)
        let id = this.tagRepo.create(
            ownerId,
            name,
            ManagementRoutes.normalize(name),
            json.get("color"),
            ManagementRoutes.longOpt(json, "category"),
            ManagementRoutes.longOpt(json, "parentId"),
            ownerId
        )
        return ApiResponse.ok("{\"id\":${id}}", req.requestId)
    }

    private func updateTag(req: ApiRequest): ApiResponse {
        let id = ManagementRoutes.pathId(req, "id")
        let json = ManagementRoutes.body(req)
        let name = json.get("name") ?? ""
        if (name.isEmpty()) {
            throw validationError("name", "标签名不能为空")
        }
        let ok = this.tagRepo.update(
            ManagementRoutes.subjectId(req),
            id,
            name,
            ManagementRoutes.normalize(name),
            json.get("color"),
            ManagementRoutes.longOpt(json, "category"),
            ManagementRoutes.subjectId(req)
        )
        if (!ok) {
            throw notFound("标签")
        }
        return ApiResponse.ok("{\"updated\":true}", req.requestId)
    }

    private func deleteTag(req: ApiRequest): ApiResponse {
        let id = ManagementRoutes.pathId(req, "id")
        let ok = this.tagRepo.softDelete(ManagementRoutes.subjectId(req), id, ManagementRoutes.subjectId(req))
        if (!ok) {
            throw notFound("标签")
        }
        return ApiResponse.ok("{\"deleted\":true}", req.requestId)
    }

    private func attachTag(req: ApiRequest): ApiResponse {
        let itemId = ManagementRoutes.pathId(req, "id")
        let json = ManagementRoutes.body(req)
        let tagId = ManagementRoutes.intFrom(json, "tagId", 0)
        if (tagId <= 0) {
            throw validationError("tagId", "缺少标签 ID")
        }
        this.tagRepo.attach(tagId, itemId)
        return ApiResponse.ok("{\"attached\":true}", req.requestId)
    }

    private func detachTag(req: ApiRequest): ApiResponse {
        let itemId = ManagementRoutes.pathId(req, "id")
        let tagId = ManagementRoutes.pathId(req, "tagId")
        this.tagRepo.detach(tagId, itemId)
        return ApiResponse.ok("{\"detached\":true}", req.requestId)
    }

    // ==================== 通知 ====================

    private func listNotifications(req: ApiRequest): ApiResponse {
        let onlyUnread = req.queryParam("unread") == "true"
        let page = ManagementRoutes.intParam(req, "page", 1)
        let size = ManagementRoutes.intParam(req, "size", 20)
        let rows = this.notifyRepo.list(
            ManagementRoutes.subjectId(req),
            onlyUnread,
            (page - 1) * size,
            size
        )
        return ApiResponse.ok(ManagementRoutes.rowsToJson(rows, "total", "${rows.size()}"), req.requestId)
    }

    private func unreadCount(req: ApiRequest): ApiResponse {
        let n = this.notifyRepo.unreadCount(ManagementRoutes.subjectId(req))
        return ApiResponse.ok("{\"count\":${n}}", req.requestId)
    }

    private func markRead(req: ApiRequest): ApiResponse {
        let id = ManagementRoutes.pathId(req, "id")
        this.notifyRepo.markRead(ManagementRoutes.subjectId(req), id)
        return ApiResponse.ok("{\"read\":true}", req.requestId)
    }

    private func markAllRead(req: ApiRequest): ApiResponse {
        let n = this.notifyRepo.markAllRead(ManagementRoutes.subjectId(req))
        return ApiResponse.ok("{\"updated\":${n}}", req.requestId)
    }

    // ==================== 字典 ====================

    private func listDictTypes(req: ApiRequest): ApiResponse {
        let rows = this.configRepo.listDictTypes()
        return ApiResponse.ok(ManagementRoutes.rowsToJson(rows, "total", "${rows.size()}"), req.requestId)
    }

    private func listDictItems(req: ApiRequest): ApiResponse {
        let code = match (req.pathParam("code")) {
            case Some(c) => c
            case None => throw validationError("code", "缺少字典编码")
        }
        let rows = this.configRepo.listDictItems(code)
        return ApiResponse.ok(ManagementRoutes.rowsToJson(rows, "total", "${rows.size()}"), req.requestId)
    }

    private func createDictType(req: ApiRequest): ApiResponse {
        let json = ManagementRoutes.body(req)
        let code = json.get("code") ?? ""
        let name = json.get("name") ?? ""
        if (code.isEmpty() || name.isEmpty()) {
            throw validationError("code", "字典编码与名称不能为空")
        }
        let id = this.configRepo.createDictType(
            code,
            name,
            json.get("description") ?? "",
            ManagementRoutes.operatorId(req)
        )
        return ApiResponse.ok("{\"id\":${id}}", req.requestId)
    }

    private func createDictItem(req: ApiRequest): ApiResponse {
        let code = match (req.pathParam("code")) {
            case Some(c) => c
            case None => throw validationError("code", "缺少字典编码")
        }
        let json = ManagementRoutes.body(req)
        let itemCode = json.get("itemCode") ?? ""
        let label = json.get("label") ?? ""
        if (itemCode.isEmpty() || label.isEmpty()) {
            throw validationError("itemCode", "字典项编码与名称不能为空")
        }
        // 先查字典类型 ID
        let types = this.configRepo.listDictTypes()
        var dictTypeId: Int64 = 0
        for (r in types.all().iterator()) {
            if (r.str("code") == code) {
                dictTypeId = r.i64("id")
                break
            }
        }
        if (dictTypeId == 0) {
            throw notFound("字典类型")
        }
        let id = this.configRepo.createDictItem(
            dictTypeId,
            itemCode,
            label,
            ManagementRoutes.intFrom(json, "sortOrder", 0),
            ManagementRoutes.operatorId(req)
        )
        return ApiResponse.ok("{\"id\":${id}}", req.requestId)
    }

    // ==================== 角色管理闭环（FR-ACL-002） ====================

    private func createRole(req: ApiRequest): ApiResponse {
        let json = ManagementRoutes.body(req)
        let code = json.get("code") ?? ""
        let name = json.get("name") ?? ""
        if (code.isEmpty() || name.isEmpty()) {
            throw validationError("code", "角色编码与名称不能为空")
        }
        let parentId: Int64 = match (ManagementRoutes.longOpt(json, "parentRoleId")) {
            case Some(v) => v
            case None => 0
        }
        let id = this.roleRepo.createRole(
            code,
            name,
            json.get("description") ?? "",
            ManagementRoutes.intFrom(json, "maxDataLevel", 1),
            parentId,
            ManagementRoutes.operatorId(req)
        )
        return ApiResponse.ok("{\"id\":${id}}", req.requestId)
    }

    private func updateRole(req: ApiRequest): ApiResponse {
        let code = match (req.pathParam("code")) {
            case Some(c) => c
            case None => throw validationError("code", "缺少角色编码")
        }
        let json = ManagementRoutes.body(req)
        let name = json.get("name") ?? ""
        if (name.isEmpty()) {
            throw validationError("name", "角色名称不能为空")
        }
        let parentId: Int64 = match (ManagementRoutes.longOpt(json, "parentRoleId")) {
            case Some(v) => v
            case None => 0
        }
        let ok = this.roleRepo.updateRole(
            code,
            name,
            json.get("description") ?? "",
            ManagementRoutes.intFrom(json, "maxDataLevel", 1),
            parentId,
            ManagementRoutes.operatorId(req)
        )
        if (!ok) {
            throw notFound("角色")
        }
        return ApiResponse.ok("{\"updated\":true}", req.requestId)
    }

    private func deleteRole(req: ApiRequest): ApiResponse {
        let code = match (req.pathParam("code")) {
            case Some(c) => c
            case None => throw validationError("code", "缺少角色编码")
        }
        let ok = this.roleRepo.deleteRole(code, ManagementRoutes.operatorId(req))
        if (!ok) {
            throw notFound("角色")
        }
        return ApiResponse.ok("{\"deleted\":true}", req.requestId)
    }

    // ==================== 用户-角色分配（FR-ACL-004） ====================

    private func listUserRoles(req: ApiRequest): ApiResponse {
        let userId = ManagementRoutes.pathId(req, "id")
        let rows = this.roleRepo.listUserRoles(userId)
        return ApiResponse.ok(ManagementRoutes.rowsToJson(rows, "total", "${rows.size()}"), req.requestId)
    }

    private func assignUserRole(req: ApiRequest): ApiResponse {
        let userId = ManagementRoutes.pathId(req, "id")
        let json = ManagementRoutes.body(req)
        let roleCode = json.get("roleCode") ?? ""
        if (roleCode.isEmpty()) {
            throw validationError("roleCode", "缺少角色编码")
        }
        let subjectId: Int64 = match (ManagementRoutes.longOpt(json, "subjectId")) {
            case Some(v) => v
            case None => 0
        }
        let id = this.roleRepo.assignUserRole(
            userId,
            roleCode,
            subjectId,
            ManagementRoutes.intFrom(json, "category", 0),
            ManagementRoutes.operatorId(req)
        )
        return ApiResponse.ok("{\"id\":${id}}", req.requestId)
    }

    private func revokeUserRole(req: ApiRequest): ApiResponse {
        let userId = ManagementRoutes.pathId(req, "id")
        let roleCode = match (req.pathParam("roleCode")) {
            case Some(c) => c
            case None => throw validationError("roleCode", "缺少角色编码")
        }
        let subjectId = match (req.queryParam("subjectId")) {
            case Some(v) => ManagementRoutes.parseInt(v)
            case None => 0
        }
        let ok = this.roleRepo.revokeUserRole(userId, roleCode, subjectId)
        if (!ok) {
            throw notFound("角色分配")
        }
        return ApiResponse.ok("{\"revoked\":true}", req.requestId)
    }

    // ==================== 显式授权（FR-ACL-008） ====================

    private func createGrant(req: ApiRequest): ApiResponse {
        let json = ManagementRoutes.body(req)
        let subjectId: Int64 = match (ManagementRoutes.longOpt(json, "subjectId")) {
            case Some(v) => v
            case None => 0
        }
        let granteeId: Int64 = match (ManagementRoutes.longOpt(json, "granteeId")) {
            case Some(v) => v
            case None => 0
        }
        let codes = ManagementRoutes.stringArray(json, "permCodes")
        if (subjectId <= 0) {
            throw validationError("subjectId", "缺少授权主体")
        }
        if (granteeId <= 0) {
            throw validationError("granteeId", "缺少被授权人")
        }
        if (codes.isEmpty()) {
            throw validationError("permCodes", "至少选择一个权限")
        }
        // 授权人必须能访问该主体（防越权授权，FR-ACL-008 安全约束）
        if (!this.userRepo.listAccessibleSubjectIds(ManagementRoutes.operatorId(req)).contains("${subjectId}")) {
            throw AppError(AppErrorKind.Forbidden, "无权对该主体授权")
        }
        let sb = StringBuilder()
        var first = true
        for (c in codes.iterator()) {
            if (!first) {
                sb.append(",")
            } else {
                first = false
            }
            sb.append(c)
        }
        let id = this.roleRepo.createGrant(
            subjectId,
            match (ManagementRoutes.longOpt(json, "itemId")) { case Some(v) => v; case None => 0 },
            ManagementRoutes.intFrom(json, "category", 0),
            granteeId,
            sb.toString(),
            ManagementRoutes.operatorId(req),
            match (ManagementRoutes.longOpt(json, "expiresAt")) { case Some(v) => v; case None => 0 }
        )
        return ApiResponse.ok("{\"id\":${id}}", req.requestId)
    }

    private func revokeGrant(req: ApiRequest): ApiResponse {
        let id = ManagementRoutes.pathId(req, "id")
        let ok = this.roleRepo.revokeGrant(id, ManagementRoutes.operatorId(req))
        if (!ok) {
            throw notFound("授权")
        }
        return ApiResponse.ok("{\"revoked\":true}", req.requestId)
    }

    private func listGrants(req: ApiRequest): ApiResponse {
        let rows = this.roleRepo.listGrantsByGrantee(ManagementRoutes.subjectId(req))
        return ApiResponse.ok(ManagementRoutes.rowsToJson(rows, "total", "${rows.size()}"), req.requestId)
    }

    // ==================== 工具方法 ====================

    /**
     * 解析请求体 JSON。
     */
    private static func body(req: ApiRequest): SimpleJson {
        return match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
    }

    /**
     * 取路径参数中的整数 ID。
     */
    private static func pathId(req: ApiRequest, name: String): Int64 {
        let raw = match (req.pathParam(name)) {
            case Some(v) => v
            case None => throw validationError(name, "缺少路径参数 ${name}")
        }
        return ManagementRoutes.parseInt(raw)
    }

    /**
     * 取查询参数中的整数（带默认值）。
     */
    private static func intParam(req: ApiRequest, name: String, defaultValue: Int64): Int64 {
        match (req.queryParam(name)) {
            case Some(v) => return ManagementRoutes.parseInt(v)
            case None => return defaultValue
        }
    }

    /**
     * 字符串转 Int64（解析失败返回 0）。
     */
    private static func parseInt(s: String): Int64 {
        var acc: Int64 = 0
        if (s.isEmpty()) {
            return 0
        }
        for (b in s.toArray().iterator()) {
            if (b < 48 || b > 57) {
                return 0
            }
            acc = acc * 10 + Int64(b - 48)
        }
        return acc
    }

    /**
     * 从 JSON 取整数（带默认值）。
     */
    private static func intFrom(json: SimpleJson, key: String, defaultValue: Int64): Int64 {
        match (json.get(key)) {
            case Some(v) => return ManagementRoutes.parseInt(v)
            case None => return defaultValue
        }
    }

    /**
     * 从 JSON 取可空整数。
     */
    private static func longOpt(json: SimpleJson, key: String): Option<Int64> {
        match (json.get(key)) {
            case Some(v) =>
                let n = ManagementRoutes.parseInt(v)
                if (n == 0) {
                    return None
                }
                return Some(n)
            case None => return None
        }
    }

    /**
     * 从 JSON 取字符串数组（兼容逗号分隔的字符串形式）。
     */
    private static func stringArray(json: SimpleJson, key: String): ArrayList<String> {
        let out = ArrayList<String>()
        match (json.get(key)) {
            case Some(v) =>
                if (v.startsWith("[")) {
                    // 简化解析：["a","b"]
                    let inner = v[1..v.size - 1]
                    for (part in inner.split(",")) {
                        let t = part.trimStart().trimEnd()
                        if (!t.isEmpty()) {
                            out.add(SimpleJson.unquotePublic(t))
                        }
                    }
                } else {
                    // 逗号分隔：a,b,c
                    for (part in v.split(",")) {
                        let t = part.trimStart().trimEnd()
                        if (!t.isEmpty()) {
                            out.add(t)
                        }
                    }
                }
            case None => ()
        }
        return out
    }

    /**
     * 标签名规范化（去空格 + 转小写）。
     */
    private static func normalize(name: String): String {
        return name.trimStart().trimEnd().toAsciiLower()
    }

    /**
     * 当前操作者 ID（用于审计字段）。
     */
    private static func operatorId(req: ApiRequest): Int64 {
        return UserRepo.parseId(req.subjectId)
    }

    /**
     * 当前主体 ID（标签归属）。
     */
    private static func subjectId(req: ApiRequest): Int64 {
        let id = UserRepo.parseId(req.subjectId)
        if (id == 0) {
            throw unauthorized(message: "缺少用户信息")
        }
        return id
    }

    /**
     * 把行集合转成 JSON 数组。
     *
     * @param extraKey 额外的顶层字段名（用于分页总数）
     * @param extraVal 额外的顶层字段值
     */
    private static func rowsToJson(rows: RowSet, extraKey: String, extraVal: String): String {
        let sb = StringBuilder()
        sb.append("{\"items\":[")
        var first = true
        for (r in rows.all().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append(ManagementRoutes.rowToJson(r))
        }
        sb.append("],")
        sb.append("\"${extraKey}\":${extraVal}}")
        return sb.toString()
    }

    /**
     * 单行转 JSON 对象。
     */
    private static func rowToJson(r: RowData): String {
        let sb = StringBuilder()
        sb.append("{")
        var first = true
        for (name in r.columnNames().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("\"${ApiResponse.escape(name)}\":")
            match (r.getOpt(name)) {
                case Some(v) => sb.append("\"${ApiResponse.escape(v)}\"")
                case None => sb.append("null")
            }
        }
        sb.append("}")
        return sb.toString()
    }
}

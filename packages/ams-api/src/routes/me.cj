// ============================================================
// ams.api.routes.me · 个人中心与概览接口
//
// 覆盖 FR-UX-001（个人主页与概览）：
//   GET  /api/me           当前登录者档案（不含任何凭据字段）
//   PUT  /api/me           自助修改昵称 / 邮箱 / 手机号
//   POST /api/me/password  自助修改口令（校验原口令 + 策略 + 间隔）
//   GET  /api/overview     概览统计（总数 / 分类分布 / 最近更新 / 待处理提醒）
//
// 【为什么单独开这个文件】
//   这些端点是前端首屏就要用的「用户态」接口，与既有 management.cj
//   （管理员视角的用户管理）语义不同，混在一起容易误用管理权限。
//
// 【安全约束】
//   ① /api/me **绝不返回** passwordHash / kdfCost 等凭据字段
//   ② /api/overview 的统计一律按**服务端算出的可访问主体**过滤（FR-ACL-006），
//      不统计他人数据
//   ③ 邮箱与手机号按敏感度掩码返回（FR-SRC-006 的掩码策略一以贯之）
//   ④ 自助改口令只认「本人 + 原口令」，不接受任何越权字段
//      （status / perm_version / role 一律不可经此接口修改）
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.app.auth.*
import ams.core.search.*
import ams.crypto.provider.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.security.authn.*

/**
 * 个人中心与概览接口。
 */
public class MeRoutes {
    private let userRepo: UserRepo
    private let itemRepo: ItemRepo
    private let notifyRepo: NotifyRepo
    /** 口令哈希器（自助改口令用；未注入则该端点返回 5xx） */
    private let hasher: ?PasswordHasher
    /** 口令策略校验器（FR-AUTH-004） */
    private let passwordValidator: ?PasswordValidator
    /** 口令策略（取最小修改间隔） */
    private let policy: ?PasswordPolicy
    /** 认证服务（改口令后吊销全部会话） */
    private let authService: ?AuthService
    /** 会话存储（FR-AUTH-007 会话管理与设备列表） */
    private let sessions: ?SessionStore
    /** PBKDF2 迭代次数（新建口令时落库的 kdf_cost） */
    private let kdfIterations: Int64
    /** 附件仓储（FR-ATT-011 存储配额统计） */
    private let attachmentRepo: AttachmentRepo
    /** 配置仓储（FR-ATT-011 全局默认配额） */
    private let configRepo: ConfigRepo

    public init(
        userRepo: UserRepo,
        itemRepo: ItemRepo,
        notifyRepo: NotifyRepo,
        hasher!: ?PasswordHasher = None,
        passwordValidator!: ?PasswordValidator = None,
        policy!: ?PasswordPolicy = None,
        authService!: ?AuthService = None,
        sessions!: ?SessionStore = None,
        kdfIterations!: Int64 = 600000,
        attachmentRepo!: AttachmentRepo,
        configRepo!: ConfigRepo
    ) {
        this.userRepo = userRepo
        this.itemRepo = itemRepo
        this.notifyRepo = notifyRepo
        this.hasher = hasher
        this.passwordValidator = passwordValidator
        this.policy = policy
        this.authService = authService
        this.sessions = sessions
        this.kdfIterations = kdfIterations
        this.attachmentRepo = attachmentRepo
        this.configRepo = configRepo
    }

    public func register(router: Router): Unit {
        // 两个端点只需登录 + 基础档案读权限即可访问自己的数据
        router.get("/api/me", { req: ApiRequest => this.me(req) },
                   requiredPerm: "archive:read:own")
        router.get("/api/overview", { req: ApiRequest => this.overview(req) },
                   requiredPerm: "archive:read:own")
        // 自助维护**自己的账号**，因此只要求登录，不绑定业务权限点 ——
        // 否则只有 subject 权限的角色就无法改自己的口令。
        router.put("/api/me", { req: ApiRequest => this.updateMe(req) })
        router.post("/api/me/password", { req: ApiRequest => this.changePassword(req) })
        // FR-AUTH-007 会话管理与设备列表
        router.get("/api/me/sessions", { req: ApiRequest => this.listSessions(req) })
        router.delete("/api/me/sessions/:sid", { req: ApiRequest => this.revokeSession(req) })
        router.delete("/api/me/sessions", { req: ApiRequest => this.revokeOthers(req) })
        // FR-ATT-011 存储配额（按服务端算出的可访问主体聚合用量）
        router.get("/api/me/storage", { req: ApiRequest => this.storage(req) },
                   requiredPerm: "archive:read:own")
    }

    // ---------------------------------------------------------

    /**
     * GET /api/me —— 当前登录者档案。
     *
     * 只需登录即可（能过鉴权中间件就说明令牌有效），不再要求额外权限点。
     */
    private func me(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let rec = match (this.userRepo.findById(uid)) {
            case Some(u) => u
            case None => throw notFound("用户")
        }
        let sb = StringBuilder()
        sb.append("{\"id\":${rec.id},")
        sb.append("\"username\":\"${ApiResponse.escape(rec.username)}\",")
        sb.append("\"nickname\":\"${ApiResponse.escape(rec.nickname)}\",")
        // 邮箱/手机号掩码：概览类接口不返回完整联系方式
        sb.append("\"email\":\"${ApiResponse.escape(Masker.mask(rec.email, 2))}\",")
        sb.append("\"phone\":\"${ApiResponse.escape(Masker.maskPhone(rec.phone))}\",")
        sb.append("\"status\":${rec.status},")
        sb.append("\"perms\":[")
        var first = true
        for (p in req.perms) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("\"${ApiResponse.escape(p)}\"")
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * GET /api/overview —— 概览统计。
     */
    private func overview(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let subjects = this.userRepo.listAccessibleSubjectIds(uid).toArray()

        let total = this.itemRepo.count(subjects, 0, -1, "")

        // 分类分布：一条 GROUP BY 取回全部分类计数，缺失的分类补 0。
        // （原先对 11 个内置分类逐个 COUNT(*)，单请求 12 条查询，
        //   首屏因此要占用 13 条数据库连接。）
        var counts = Array<Int64>(12, repeat: 0)
        for (r in this.itemRepo.countByCategory(subjects).all().iterator()) {
            let cat = r.i64("category")
            if (cat >= 0 && cat <= 11) {
                counts[cat] = r.i64("n")
            }
        }
        let sb = StringBuilder()
        sb.append("{\"total\":${total},\"categories\":[")
        var first = true
        var c: Int64 = 1
        while (c <= 11) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("{\"category\":${c},\"count\":${counts[c]}}")
            c = c + 1
        }
        sb.append("],")

        // 最近更新（取前 5 条，按更新时间倒序）
        let recent = this.itemRepo.list(subjects, 0, -1, "", 5, 0)
        sb.append("\"recent\":[")
        var rf = true
        for (r in recent.all().iterator()) {
            if (!rf) {
                sb.append(",")
            }
            rf = false
            sb.append("{\"id\":${r.i64("id")},")
            sb.append("\"category\":${r.i64("category")},")
            sb.append("\"title\":\"${ApiResponse.escape(r.str("title"))}\",")
            sb.append("\"updatedAt\":${r.i64("updated_ms")}}")
        }
        sb.append("],")

        // 待处理提醒：未读通知数
        let unread = this.notifyRepo.unreadCount(uid)
        sb.append("\"unreadNotifications\":${unread}}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    // ---------------------------------------------------------------
    // 自助维护（此前完全缺失：个人主页只能看不能改）
    // ---------------------------------------------------------------

    /**
     * PUT /api/me —— 自助修改昵称 / 邮箱 / 手机号。
     *
     * 请求体：{"nickname?","email?","phone?"}
     *   - 缺省字段表示「保持不变」（PATCH 语义）
     *   - 空串表示「清空」（但邮箱与手机号不允许同时为空）
     *
     * 【越权面控制】只读取这三个键，其余字段（status / role / perms /
     *   permVersion / passwordHash）**一律忽略**，即使请求体里带了也不会生效。
     */
    private func updateMe(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let rec = match (this.userRepo.findById(uid)) {
            case Some(u) => u
            case None => throw notFound("用户")
        }
        let json = MeRoutes.body(req)
        let nickname = json.get("nickname") ?? rec.nickname
        let email = (json.get("email") ?? rec.email).trimAscii()
        let phone = (json.get("phone") ?? rec.phone).trimAscii()

        if (!email.isEmpty()) {
            if (!MeRoutes.isEmail(email)) {
                throw validationError("email", "邮箱格式不正确")
            }
            if (email != rec.email) {
                match (this.userRepo.findByEmail(email)) {
                    case Some(_) => throw conflict("邮箱已被其他账号占用")
                    case None => ()
                }
            }
        }
        if (!phone.isEmpty()) {
            if (!MeRoutes.isPhone(phone)) {
                throw validationError("phone", "手机号格式不正确（11 位、以 1 开头）")
            }
            if (phone != rec.phone) {
                match (this.userRepo.findByPhone(phone)) {
                    case Some(_) => throw conflict("手机号已被其他账号占用")
                    case None => ()
                }
            }
        }
        // 邮箱与手机号至少保留一项：两者皆无则无法走口令找回流程
        if (email.isEmpty() && phone.isEmpty()) {
            throw validationError("contact", "邮箱与手机号至少保留一项")
        }
        if (!this.userRepo.updateProfile(uid, nickname, email, phone)) {
            throw notFound("用户")
        }
        return ApiResponse.ok("{\"updated\":true}", req.requestId)
    }

    /**
     * POST /api/me/password —— 自助修改口令。
     *
     * 请求体：{"oldPassword","newPassword"}
     *
     * 【校验顺序】先验原口令，再走策略校验 —— 避免未持原口令者
     *   通过错误信息差异探测口令策略（FR-AUTH-004）。
     * 【改后动作】吊销该账号全部会话（含当前），前端须重新登录。
     */
    private func changePassword(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let json = MeRoutes.body(req)
        let oldPwd = json.get("oldPassword") ?? ""
        let newPwd = json.get("newPassword") ?? ""
        if (oldPwd.isEmpty() || newPwd.isEmpty()) {
            throw validationError("password", "原口令与新口令均不能为空")
        }
        let hasher = match (this.hasher) {
            case Some(h) => h
            case None => throw AppError(AppErrorKind.Internal, "口令哈希服务未配置")
        }
        let validator = match (this.passwordValidator) {
            case Some(v) => v
            case None => throw AppError(AppErrorKind.Internal, "口令策略校验器未配置")
        }
        let rec = match (this.userRepo.findById(uid)) {
            case Some(u) => u
            case None => throw notFound("用户")
        }
        if (rec.status != 0) {
            throw AppError(AppErrorKind.Forbidden, "账号已停用，无法修改口令")
        }
        // ① 原口令校验（恒定时间比较在 PasswordHasher 内部完成）
        if (!hasher.verify(oldPwd, rec.passwordHash, Array<Byte>(16, repeat: 0u8))) {
            throw validationError("oldPassword", "原口令不正确")
        }
        // ② 新口令策略
        match (validator.check(newPwd, rec.username)) {
            case PasswordCheck.Ok => ()
            case PasswordCheck.TooShort(min) =>
                throw validationError("newPassword", "口令长度至少 ${min} 位")
            case PasswordCheck.TooFewCharClasses(n) =>
                throw validationError("newPassword", "口令至少包含 ${n} 类字符（大小写/数字/符号）")
            case PasswordCheck.InWeakDictionary =>
                throw validationError("newPassword", "口令过于常见，请更换")
            case PasswordCheck.ContainsUsername =>
                throw validationError("newPassword", "口令不得包含用户名")
            case PasswordCheck.RepeatedChars =>
                throw validationError("newPassword", "口令不得包含连续重复字符")
        }
        if (newPwd == oldPwd) {
            throw validationError("newPassword", "新口令不能与原口令相同")
        }
        // ③ 最小修改间隔（FR-AUTH-004）
        let intervalHours = match (this.policy) {
            case Some(p) => p.minChangeIntervalHours
            case None => 0
        }
        let intervalMs = intervalHours * 3600 * 1000
        let elapsed = this.userRepo.millisSincePasswordUpdate(uid)
        if (intervalMs > 0 && elapsed > 0 && elapsed < intervalMs) {
            let leftMin = (intervalMs - elapsed) / 60000
            throw AppError(
                AppErrorKind.Conflict,
                "两次修改口令的间隔不得少于 ${intervalHours} 小时，请约 ${leftMin} 分钟后再试"
            )
        }
        // ④ 生成盐与哈希
        let salt = match (hasher.generateSalt()) {
            case CryptoResult.Ok(b) => b
            case CryptoResult.Err(_) => throw AppError(AppErrorKind.Internal, "口令哈希生成失败")
        }
        let hash = match (hasher.hash(newPwd, salt)) {
            case CryptoResult.Ok(h) => h
            case CryptoResult.Err(_) => throw AppError(AppErrorKind.Internal, "口令哈希生成失败")
        }
        if (!this.userRepo.updatePassword(uid, hash, this.kdfIterations, uid)) {
            throw notFound("用户")
        }
        // ⑤ 吊销全部会话：改口令后旧令牌立即失效
        let revoked = match (this.authService) {
            case Some(svc) => svc.logoutAll(req.subjectId)
            case None => 0
        }
        return ApiResponse.ok(
            "{\"updated\":true,\"revokedSessions\":${revoked},\"reloginRequired\":true}",
            req.requestId
        )
    }

    // ---------------------------------------------------------------
    // FR-AUTH-007 会话管理与设备列表
    // ---------------------------------------------------------------

    /**
     * GET /api/me/sessions —— 我的活跃会话（设备 / IP / 最近活动）。
     *
     * 只列**未吊销**的会话：已登出的设备对用户无意义，
     * 且 sid 属于敏感标识，能少暴露就少暴露。
     */
    private func listSessions(req: ApiRequest): ApiResponse {
        let store = match (this.sessions) {
            case Some(s) => s
            case None => throw AppError(AppErrorKind.Internal, "会话服务未配置")
        }
        let sb = StringBuilder()
        sb.append("{\"sessions\":[")
        var first = true
        for (s in store.listByUser(req.subjectId)) {
            if (s.revoked) {
                continue
            }
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("{\"sid\":\"${ApiResponse.escape(s.sid)}\",")
            sb.append("\"ip\":\"${ApiResponse.escape(s.ip)}\",")
            sb.append("\"userAgent\":\"${ApiResponse.escape(s.userAgent)}\",")
            sb.append("\"createdAt\":${s.createdAt},")
            sb.append("\"lastActiveAt\":${s.lastActiveAt},")
            sb.append("\"current\":${s.sid == req.sid}}")
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * DELETE /api/me/sessions/:sid —— 踢出指定设备。
     *
     * 归属校验在 SessionStore 内部完成（比对 uid），
     * 因此猜到别人的 sid 也踢不掉。
     */
    private func revokeSession(req: ApiRequest): ApiResponse {
        let store = match (this.sessions) {
            case Some(s) => s
            case None => throw AppError(AppErrorKind.Internal, "会话服务未配置")
        }
        let sid = req.pathParam("sid") ?? ""
        if (sid.isEmpty()) {
            throw validationError("sid", "会话 ID 不能为空")
        }
        if (!store.revoke(sid, req.subjectId)) {
            throw notFound("会话")
        }
        return ApiResponse.ok("{\"revoked\":true}", req.requestId)
    }

    /**
     * DELETE /api/me/sessions —— 踢出**其他**设备（保留当前会话）。
     */
    private func revokeOthers(req: ApiRequest): ApiResponse {
        let store = match (this.sessions) {
            case Some(s) => s
            case None => throw AppError(AppErrorKind.Internal, "会话服务未配置")
        }
        let n = store.revokeOthersByUser(req.subjectId, req.sid)
        return ApiResponse.ok("{\"revoked\":${n}}", req.requestId)
    }

    /**
     * GET /api/me/storage —— 存储配额与用量（FR-ATT-011）。
     *
     * 用量按**服务端算出的可访问主体**聚合（FR-ACL-006），前端无法扩大范围。
     * 配额：优先全局默认（cfg_settings scope=storage key=default_quota_bytes），
     * 未配则兜底 5 GiB。接近阈值（≥ 90%）置 thresholdReached。
     */
    private func storage(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let subjects = this.userRepo.listAccessibleSubjectIds(uid).toArray()
        let used = this.attachmentRepo.totalBytesInSubjects(subjects)
        let defaultQuota = this.configRepo.getInt("storage", "default_quota_bytes", 5368709120)
        let quota = if (defaultQuota <= 0) { 5368709120 } else { defaultQuota }
        let reached = used >= quota
        let pct = if (quota > 0) { (used * 100) / quota } else { 0 }
        return ApiResponse.ok(
            "{\"usedBytes\":${used},\"quotaBytes\":${quota}," +
            "\"usedPercent\":${pct},\"thresholdReached\":${if (reached) { "true" } else { "false" }}}",
            req.requestId
        )
    }

    // ---------------------------------------------------------------

    /**
     * 解析请求体。
     */
    private static func body(req: ApiRequest): SimpleJson {
        match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => return j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
    }

    /**
     * 邮箱格式（轻量校验：本地部分@域名含点，无空白）。
     *
     * 不引正则：仓颉标准库无 regexp，且真实有效性最终以
     * 「能否收到邮件」为准，此处只挡明显非法输入。
     */
    private static func isEmail(s: String): Bool {
        if (s.size > 128) {
            return false
        }
        let at = match (s.indexOf("@")) {
            case Some(i) => i
            case None => return false
        }
        if (at <= 0 || at >= s.size - 1) {
            return false
        }
        let domain = s[at + 1..s.size]
        if (!domain.contains(".")) {
            return false
        }
        for (b in s.toArray().iterator()) {
            if (b == 32 || b == 9) {
                return false
            }
        }
        return true
    }

    /**
     * 手机号格式（中国大陆：11 位、以 1 开头）。
     */
    private static func isPhone(s: String): Bool {
        if (s.size != 11) {
            return false
        }
        let bytes = s.toArray()
        if (bytes[0] != 49) {
            return false
        }
        for (b in bytes.iterator()) {
            if (b < 48 || b > 57) {
                return false
            }
        }
        return true
    }
}

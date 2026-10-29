// ============================================================
// ams.api.routes.share · 条目共享链接（FR-ACL-011 / FR-ACL-012 · 方案 A）
//
// 路由：
//   公开（无需登录）：
//     GET  /api/share/:token        读共享页（密码保护时只返回 needPassword）
//     POST /api/share/:token        提交密码换取内容
//   所有者（需 archive:write:own）：
//     POST   /api/share-links       创建链接
//     GET    /api/share-links       列出本人链接
//     DELETE /api/share-links/:id   撤销
//
// 安全要点：
//   · token 用**密钥 HMAC-SM3** 从「条目+用户+时间+ID」派生，不可预测；
//   · 密码只存加盐 HMAC-SM3 摘要；比较用定时无关算法；
//   · 失败次数落库并跨重启生效；达到上限即 revoked，链接**立即失效**；
//   · 不存在 / 已撤销 / 已过期 / 条目已删 一律 **404** ——
//     不区分原因，避免token 枚举探测；
//   · 公开返回**只含展示字段**：不含条目标识、归属主体、扩展字段、附件。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.core.search.*
import ams.crypto.provider.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.id.*
import ams.kernel.time.*

/**
 * 共享链接接口。
 */
public class ShareRoutes {
    private let shareRepo: ShareLinkRepo
    private let itemRepo: ItemRepo
    private let userRepo: UserRepo
    private let crypto: ?CryptoProvider
    private let signKey: String

    /** 默认有效期：7 天 */
    private static let DEFAULT_HOURS: Int64 = 168
    /** 有效期上限：365 天 */
    private static let MAX_HOURS: Int64 = 8760
    /** 默认密码错误上限 */
    private static let DEFAULT_MAX_FAILS: Int64 = 5

    public init(
        shareRepo: ShareLinkRepo,
        itemRepo: ItemRepo,
        userRepo: UserRepo,
        crypto!: ?CryptoProvider = None,
        signKey!: String = ""
    ) {
        this.shareRepo = shareRepo
        this.itemRepo = itemRepo
        this.userRepo = userRepo
        this.crypto = crypto
        this.signKey = signKey
    }

    public func register(router: Router): Unit {
        // ---- 公开只读（token 即凭据）----
        router.get("/api/share/:token", { req: ApiRequest => this.publicGet(req) },
            isPublic: true)
        router.post("/api/share/:token", { req: ApiRequest => this.publicPost(req) },
            isPublic: true)
        // ---- 所有者管理 ----
        router.post("/api/share-links", { req: ApiRequest => this.create(req) },
            requiredPerm: "archive:write:own")
        router.get("/api/share-links", { req: ApiRequest => this.list(req) },
            requiredPerm: "archive:write:own")
        router.delete("/api/share-links/:id", { req: ApiRequest => this.revoke(req) },
            requiredPerm: "archive:write:own")
    }

    // ============================================================
    // 所有者：创建 / 列表 / 撤销
    // ============================================================

    /**
     * POST /api/share-links
     *
     * 入参：{"itemId": 123, "password": "可选", "expiresInHours": 168, "maxFails": 5}
     * 返回：{"id","token","url","expiresAt","maxFails"}
     */
    private func create(req: ApiRequest): ApiResponse {
        let json = ShareRoutes.body(req)
        let uid = UserRepo.parseId(req.subjectId)
        let itemId = ShareRoutes.intOf(json, "itemId", 0)
        if (itemId <= 0) {
            throw validationError("itemId", "缺少条目 ID")
        }
        let scopeAny = req.perms.contains("archive:write:any")
        let subjectIds = if (scopeAny) {
            this.userRepo.listAccessibleSubjectIds(uid).toArray()
        } else {
            this.userRepo.listOwnedSubjectIds(uid).toArray()
        }
        // 只有对条目所在主体有写权限的人才能创建共享链接
        match (this.itemRepo.findById(itemId, subjectIds)) {
            case Some(_) => ()
            case None => throw notFound("条目")
        }

        var hours = ShareRoutes.intOf(json, "expiresInHours", DEFAULT_HOURS)
        if (hours <= 0) {
            hours = DEFAULT_HOURS
        }
        if (hours > MAX_HOURS) {
            hours = MAX_HOURS
        }
        var maxFails = ShareRoutes.intOf(json, "maxFails", DEFAULT_MAX_FAILS)
        if (maxFails < 1) {
            maxFails = 1
        }
        if (maxFails > 20) {
            maxFails = 20
        }

        let token = this.newToken(itemId, uid)
        let password = ShareRoutes.strOf(json, "password", "").trimAscii()
        var passwordHash = ""
        var salt = ""
        if (!password.isEmpty()) {
            salt = "s${Ids.next()}"
            passwordHash = this.hashPassword(password, salt)
        }
        let expiresMs = Times.nowMillis() + hours * 3600 * 1000
        let expiresAt = Times.toIso8601(expiresMs)
        let id = this.shareRepo.create(
            token, itemId, uid, passwordHash, salt, maxFails, expiresAt
        )
        let sb = StringBuilder()
        sb.append("{\"id\":\"${id}\",")
        sb.append("\"token\":\"${token}\",")
        sb.append("\"url\":\"/share/${token}\",")
        sb.append("\"protected\":${if (passwordHash.isEmpty()) { "false" } else { "true" }},")
        sb.append("\"maxFails\":${maxFails},")
        sb.append("\"expiresAt\":${expiresMs}}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * GET /api/share-links
     */
    private func list(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let page = ShareRoutes.longOf(req.queryParam("page") ?? "", 1)
        let size = ShareRoutes.clamp(ShareRoutes.longOf(req.queryParam("size") ?? "", 20), 1, 100)
        let rows = this.shareRepo.listByOwner(uid, size, (page - 1) * size)
        let total = this.shareRepo.countByOwner(uid)
        let sb = StringBuilder()
        sb.append("{\"total\":${total},\"items\":[")
        var first = true
        for (r in rows.all().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("{\"id\":\"${r.str("id")}\",")
            sb.append("\"token\":\"${ApiResponse.escape(r.str("token"))}\",")
            sb.append("\"itemId\":\"${r.str("item_id")}\",")
            sb.append("\"revoked\":${if (r.bool("revoked")) { "true" } else { "false" }},")
            sb.append("\"expired\":${if (r.bool("expired")) { "true" } else { "false" }},")
            sb.append("\"viewCount\":${r.i64("view_count")},")
            sb.append("\"failCount\":${r.i64("fail_count")},")
            sb.append("\"expiresAt\":${r.i64("expires_ms")},")
            sb.append("\"createdAt\":${r.i64("created_ms")},")
            sb.append("\"lastAccessAt\":${r.i64("last_access_ms")}}")
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * DELETE /api/share-links/:id
     */
    private func revoke(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let raw = req.pathParam("id") ?? ""
        let id = RowData.toI64(raw)
        if (id <= 0) {
            throw validationError("id", "缺少合法的链接 ID")
        }
        if (!this.shareRepo.revoke(id, uid)) {
            throw notFound("共享链接")
        }
        return ApiResponse.ok("{\"revoked\":true}", req.requestId)
    }

    // ============================================================
    // 公开：读取 / 密码校验
    // ============================================================

    /**
     * GET /api/share/:token
     *
     * 密码保护时**不泄露任何条目信息**，只返回 needPassword。
     */
    private func publicGet(req: ApiRequest): ApiResponse {
        let token = req.pathParam("token") ?? ""
        let row = this.activeLink(token)
        if (!row.str("password_hash").isEmpty()) {
            let sb = StringBuilder()
            sb.append("{\"needPassword\":true,")
            sb.append("\"expiresAt\":${row.i64("expires_ms")}}")
            return ApiResponse.ok(sb.toString(), req.requestId)
        }
        this.shareRepo.recordView(token)
        return ApiResponse.ok(this.publicView(row), req.requestId)
    }

    /**
     * POST /api/share/:token
     *
     * 入参：{"password":"..."}
     */
    private func publicPost(req: ApiRequest): ApiResponse {
        let token = req.pathParam("token") ?? ""
        let row = this.activeLink(token)
        let storedHash = row.str("password_hash")
        if (storedHash.isEmpty()) {
            this.shareRepo.recordView(token)
            return ApiResponse.ok(this.publicView(row), req.requestId)
        }
        let json = ShareRoutes.body(req)
        let password = ShareRoutes.strOf(json, "password", "").trimAscii()
        if (password.isEmpty()) {
            throw validationError("password", "该链接需要密码")
        }
        let salt = row.str("password_salt")
        let actual = this.hashPassword(password, salt)
        if (!this.constantTimeEq(actual, storedHash)) {
            let fails = this.shareRepo.bumpFail(token)
            let maxFails = row.i64("max_fails")
            if (fails >= maxFails) {
                throw AppError(AppErrorKind.Forbidden, "密码错误次数超限，链接已失效")
            }
            let remain = maxFails - fails
            throw AppError(AppErrorKind.Forbidden, "密码不正确（还可尝试 ${remain} 次）")
        }
        this.shareRepo.resetFail(token)
        this.shareRepo.recordView(token)
        return ApiResponse.ok(this.publicView(row), req.requestId)
    }

    /**
     * 取「可用」的链接：不存在 / 已撤销 / 已过期 一律 404。
     *
     * 为什么不区分原因：区分就等于告诉探测者「这个 token 真的存在」。
     */
    private func activeLink(token: String): RowData {
        if (token.isEmpty()) {
            throw notFound("共享链接")
        }
        let row = match (this.shareRepo.findByToken(token)) {
            case Some(r) => r
            case None => throw notFound("共享链接")
        }
        if (row.bool("revoked") || row.bool("expired")) {
            throw notFound("共享链接")
        }
        return row
    }

    /**
     * 公开视图：只输出展示字段。
     *
     * 掩码口径与列表页保持一致（复用 `Masker.mask`），避免同一份数据
     * 在「列表页」和「共享页」呈现不同的脱敏程度 —— 两套掩码规则是最
     * 典型的越权旁路来源。
     *
     * 高敏（sensitivity >= 3）条目连签发机关与备注都不给 ——
     * 共享链接是「最低门槛出口」，不能成为高敏信息的旁路。
     */
    private func publicView(link: RowData): String {
        let itemId = RowData.toI64(link.str("item_id"))
        let item = match (this.itemRepo.findByIdRaw(itemId)) {
            case Some(r) => r
            case None => throw notFound("条目")
        }
        let sens = item.sensitivity
        let high = sens >= 3
        let issuer = if (high) { "" } else { Masker.mask(item.issuer, sens) }
        let remark = if (high) { "" } else { item.remark }
        let sb = StringBuilder()
        sb.append("{\"title\":\"${ApiResponse.escape(item.title)}\",")
        sb.append("\"category\":${item.category},")
        sb.append("\"status\":${item.status},")
        sb.append("\"sensitivity\":${sens},")
        sb.append("\"issuer\":\"${ApiResponse.escape(issuer)}\",")
        sb.append("\"issuedDate\":\"${ApiResponse.escape(item.issuedDate)}\",")
        sb.append("\"expiresAt\":\"${ApiResponse.escape(item.expiresAt)}\",")
        sb.append("\"remark\":\"${ApiResponse.escape(remark)}\",")
        sb.append("\"shared\":true,")
        sb.append("\"linkExpiresAt\":${link.i64("expires_ms")},")
        sb.append("\"viewCount\":${link.i64("view_count")}}")
        return sb.toString()
    }

    // ============================================================
    // 工具
    // ============================================================

    /**
     * 派生不可预测 token：HMAC-SM3(密钥, 条目+用户+时间+两次雪花ID)。
     *
     * 为什么不直接用 Ids.next()：雪花 ID 单调可推，拿到一个就能猜邻近的。
     * 加一层密钥 HMAC 后，输出与输入之间没有可逆关系。
     *
     * ⚠️ **失败关闭**：缺少加密提供者时直接抛错，绝不退回「可预测 ID 拼串」。
     *    弱 token 在共享链接场景等同于无鉴权 —— 宁可创建失败，也不发一个
     *    能被枚举的链接出去（这也是本方法不再有降级分支的原因）。
     */
    private func newToken(itemId: Int64, ownerId: Int64): String {
        let prov = match (this.crypto) {
            case Some(c) => c
            case None => throw AppError(
                AppErrorKind.Internal,
                "服务未配置加密提供者，无法生成共享链接"
            )
        }
        if (this.signKey.isEmpty()) {
            throw AppError(
                AppErrorKind.Internal,
                "服务未配置签名密钥（AMS_EXPORT_SIGN_KEY / AMS_TOKEN_SECRET），无法生成共享链接"
            )
        }
        let raw = "${itemId}|${ownerId}|${Times.nowMillis()}|${Ids.next()}|${Ids.next()}"
        match (prov.hmac(this.signKey.toArray(), raw.toArray(), DigestAlgorithm.Sm3)) {
            case CryptoResult.Ok(bytes) =>
                let hex = ShareRoutes.hex(bytes)
                if (hex.size >= 32) {
                    return hex[0..32]
                }
                return hex
            case CryptoResult.Err(_) => throw AppError(
                AppErrorKind.Internal,
                "共享链接生成失败（HMAC-SM3 计算异常）"
            )
        }
    }

    /**
     * 加盐 HMAC-SM3 摘要（不存明文密码）。
     *
     * ⚠️ **失败关闭**：摘要失败必须抛错。若返回空串，调用方会把
     *    `password_hash=''` 落库，而 `publicGet` 判定「hash 为空 = 无密码保护」，
     *    于是**带密码的链接会静默变成公开链接** —— 这是必须避免的降级。
     */
    private func hashPassword(password: String, salt: String): String {
        let prov = match (this.crypto) {
            case Some(c) => c
            case None => throw AppError(
                AppErrorKind.Internal,
                "服务未配置加密提供者，无法设置访问密码"
            )
        }
        if (this.signKey.isEmpty()) {
            throw AppError(
                AppErrorKind.Internal,
                "服务未配置签名密钥（AMS_EXPORT_SIGN_KEY / AMS_TOKEN_SECRET），无法设置访问密码"
            )
        }
        match (prov.hmac(salt.toArray(), password.toArray(), DigestAlgorithm.Sm3)) {
            case CryptoResult.Ok(bytes) => return ShareRoutes.hex(bytes)
            case CryptoResult.Err(_) => throw AppError(
                AppErrorKind.Internal,
                "访问密码摘要失败（HMAC-SM3 计算异常）"
            )
        }
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

    /** 定时无关比较：避免按字节提前返回泄露摘要前缀。 */
    private func constantTimeEq(a: String, b: String): Bool {
        let prov = match (this.crypto) {
            case Some(c) => c
            case None => return false
        }
        return prov.constantTimeEquals(a.toArray(), b.toArray())
    }

    private static func body(req: ApiRequest): SimpleJson {
        return match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
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

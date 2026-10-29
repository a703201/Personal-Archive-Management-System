// ============================================================
// ams.api.routes.twofa · 双因子（TOTP）自助管理（FR-AUTH-009）
//
// 路由（均为「本人」语义，权限点走登录态，不需要额外权限码）：
//   GET  /api/me/2fa          查询状态
//   POST /api/me/2fa/setup    生成密钥 + otpauth 链接（此时**未**启用）
//   POST /api/me/2fa/enable   用一次动态码确认启用
//   POST /api/me/2fa/disable  用一次动态码确认停用
//
// 安全设计：
//   · setup 生成的密钥写入后 verified=FALSE —— 用户若没完成确认，
//     登录不会要求动态码，避免把用户锁在门外；
//   · enable / disable 都必须**当场验一次码**：前者证明 App 已正确录入，
//     后者防止「会话被劫持后一键关掉二因子」；
//   · 校验带 ±1 时间步容差（时钟漂移），并用 last_step 做重放保护。
// ============================================================
package ams.api.routes

import ams.api.http.*
import ams.crypto.provider.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.time.*
import ams.security.totp.*

/**
 * 双因子管理接口。
 */
public class TwoFaRoutes {
    private let totpRepo: TotpRepo
    private let crypto: CryptoProvider

    public init(totpRepo: TotpRepo, crypto: CryptoProvider) {
        this.totpRepo = totpRepo
        this.crypto = crypto
    }

    public func register(router: Router): Unit {
        router.get("/api/me/2fa", { req: ApiRequest => this.status(req) })
        router.post("/api/me/2fa/setup", { req: ApiRequest => this.setup(req) })
        router.post("/api/me/2fa/enable", { req: ApiRequest => this.enable(req) })
        router.post("/api/me/2fa/disable", { req: ApiRequest => this.disable(req) })
    }

    /** GET /api/me/2fa */
    private func status(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let rec = this.totpRepo.find(uid)
        let (bound, verified) = match (rec) {
            case Some(r) => (true, r.bool("verified"))
            case None => (false, false)
        }
        return ApiResponse.ok(
            "{\"bound\":${if (bound) { "true" } else { "false" }}," +
            "\"enabled\":${if (verified) { "true" } else { "false" }}}",
            req.requestId
        )
    }

    /**
     * POST /api/me/2fa/setup —— 生成新密钥。
     *
     * 会覆盖旧密钥（重新绑定）；返回 secret 与 otpauth 链接，
     * 前端可据此渲染二维码，也可手输 secret。
     */
    private func setup(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let bytes = match (this.crypto.randomBytes(20)) {
            case CryptoResult.Ok(b) => b
            case CryptoResult.Err(_) => throw AppError(AppErrorKind.Internal, "随机数生成失败")
        }
        let secret = Totp.newSecret(bytes)
        this.totpRepo.upsertSecret(uid, secret)
        let account = req.header("x-ams-account") ?? req.subjectId
        return ApiResponse.ok(
            "{\"secret\":\"${ApiResponse.escape(secret)}\"," +
            "\"otpauthUrl\":\"${ApiResponse.escape(Totp.otpauthUrl("AMS", account, secret))}\"," +
            "\"digits\":6,\"period\":30,\"algorithm\":\"SHA1\",\"enabled\":false}",
            req.requestId
        )
    }

    /** POST /api/me/2fa/enable —— 用一次动态码确认启用。 */
    private func enable(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let code = req.bodyText().trimAscii()
        let rec = match (this.totpRepo.find(uid)) {
            case Some(r) => r
            case None => throw AppError(AppErrorKind.ValidationFailed, "请先生成密钥（setup）")
        }
        let step = Totp.verify(rec.str("secret_b32"), code, Times.nowMillis(), 1)
        if (step < 0) {
            throw AppError(AppErrorKind.ValidationFailed, "动态码不正确，请核对设备时间")
        }
        if (!this.totpRepo.markVerified(uid, step)) {
            throw AppError(AppErrorKind.Internal, "启用失败，请重试")
        }
        return ApiResponse.ok("{\"enabled\":true}", req.requestId)
    }

    /** POST /api/me/2fa/disable —— 验码后停用。 */
    private func disable(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let code = req.bodyText().trimAscii()
        let rec = match (this.totpRepo.find(uid)) {
            case Some(r) => r
            case None => throw AppError(AppErrorKind.NotFound, "未启用双因子")
        }
        if (rec.bool("verified")) {
            let step = Totp.verify(rec.str("secret_b32"), code, Times.nowMillis(), 1)
            if (step < 0) {
                throw AppError(AppErrorKind.ValidationFailed, "动态码不正确，无法停用")
            }
        }
        this.totpRepo.remove(uid)
        return ApiResponse.ok("{\"enabled\":false}", req.requestId)
    }
}

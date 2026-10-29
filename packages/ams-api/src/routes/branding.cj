// ============================================================
// ams.api.routes.branding · 登录页定制（FR-CFG-008）
//
// 需求：Logo、公告、页脚、备案号可配置。
//
// 【为什么是公开接口】
//   登录页在**拿到令牌之前**就要渲染，而 `/api/admin/config` 需要
//   `system:config` 权限。给登录页开一个公开只读的出口是唯一选择，
//   所以这里刻意只暴露 4 个展示用字段，不含任何内部配置。
//
// 【为什么单独一个文件】
//   认证路由文件里塞着口令/TOTP 相关逻辑，把「读配置渲染品牌信息」
//   混进去既无必要又会牵动安全模块的评审面；独立文件让这个出口
//   一眼可审：它只读、只返回四个字符串。
//
// 【写入路径】
//   沿用既有的 `PUT /api/admin/config?scope=branding&key=...`（FR-CFG-003），
//   不另开写接口 —— 配置中心已经有权限校验与审计留痕。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.data.repo.*

/**
 * 登录页品牌配置（公开只读）。
 */
public class BrandingRoutes {
    /** 配置作用域 */
    public static let SCOPE: String = "branding"
    public static let KEY_NAME: String = "brand_name"
    public static let KEY_LOGO: String = "logo_url"
    public static let KEY_NOTICE: String = "notice"
    public static let KEY_FOOTER: String = "footer_text"
    public static let KEY_ICP: String = "icp_no"

    private let configRepo: ConfigRepo

    public init(configRepo: ConfigRepo) {
        this.configRepo = configRepo
    }

    public func register(router: Router): Unit {
        router.get("/api/branding", { req: ApiRequest => this.branding(req) }, isPublic: true)
    }

    /**
     * GET /api/branding —— 返回登录页展示用配置。
     *
     * 一律返回默认值兜底：配置项没建过、或库不可用时，登录页照常显示，
     * 不会因为「品牌配置缺失」而白屏。
     */
    private func branding(req: ApiRequest): ApiResponse {
        let sb = StringBuilder()
        sb.append("{\"brandName\":\"${ApiResponse.escape(this.value(BrandingRoutes.KEY_NAME, "AMS"))}\",")
        sb.append("\"logoUrl\":\"${ApiResponse.escape(this.value(BrandingRoutes.KEY_LOGO, ""))}\",")
        sb.append("\"notice\":\"${ApiResponse.escape(this.value(BrandingRoutes.KEY_NOTICE, ""))}\",")
        sb.append("\"footerText\":\"${ApiResponse.escape(this.value(BrandingRoutes.KEY_FOOTER, ""))}\",")
        sb.append("\"icpNo\":\"${ApiResponse.escape(this.value(BrandingRoutes.KEY_ICP, ""))}\"}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    private func value(key: String, defaultVal: String): String {
        let v = this.configRepo.getValue(BrandingRoutes.SCOPE, key, defaultVal)
        if (v.isEmpty()) {
            return defaultVal
        }
        return v
    }
}

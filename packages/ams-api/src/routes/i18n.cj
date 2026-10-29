// ============================================================
// ams.api.routes.i18n · 多语言框架（FR-CFG-009）
//
// 需求：i18n 框架预留，默认 zh-CN。
//
// 【后端职责】
//   提供「支持的语言 + 默认语言」出口，供前端初始化时拉取。
//   具体的文案翻译与切换逻辑在前端完成（见 web/src/i18n）。
//
// 【为什么轻量】
//   当前文案集中在前端；后端只负责声明语言清单与默认值，
//   避免后端硬编码 UI 字符串。后续接入更多语言时，仅扩展前端目录即可。
// ============================================================
package ams.api.routes

import ams.api.http.*

/**
 * 多语言路由（公开只读）。
 */
public class I18nRoutes {
    public static let DEFAULT_LOCALE: String = "zh-CN"
    public static let SUPPORTED: Array<String> = ["zh-CN", "en"]

    public func register(router: Router): Unit {
        router.get("/api/i18n/locales", { req: ApiRequest => this.locales(req) }, isPublic: true)
    }

    /**
     * GET /api/i18n/locales —— 返回支持的语言与默认语言。
     */
    private func locales(req: ApiRequest): ApiResponse {
        let sb = StringBuilder()
        sb.append("{\"default\":\"${I18nRoutes.DEFAULT_LOCALE}\",\"supported\":[")
        var first = true
        for (l in I18nRoutes.SUPPORTED) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("\"${l}\"")
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }
}

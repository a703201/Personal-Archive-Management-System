// ============================================================
// ams.api.routes.notify · 通知偏好中心（FR-NTF-006 / FR-NTF-007）
//
// 需求：
//   - FR-NTF-006 免打扰设置：按类别设置静默时段（dndEnabled / dndStart / dndEnd）
//   - FR-NTF-007 通知偏好中心：用户自定义接收渠道（站内信 / 邮件）与频率
//
// 【存储】
//   复用配置中心 cfg_settings（FR-CFG-003），按用户隔离 key：
//   scope = "notify"，key = "u:<userId>:<field>"。
//   既避免新增表与迁移，又把「谁改了偏好」交给既有的配置审计留痕。
//
// 【鉴权】
//   仅本人可读写自己的偏好（用 req.subjectId 强制绑定，禁止越权改他人）。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.data.repo.*
import ams.kernel.error.*

/**
 * 通知偏好路由（用户级）。
 */
public class NotifyRoutes {
    public static let SCOPE: String = "notify"
    public static let K_DND_ENABLED: String = "dnd_enabled"
    public static let K_DND_START: String = "dnd_start"
    public static let K_DND_END: String = "dnd_end"
    public static let K_CHANNEL_INAPP: String = "channel_inapp"
    public static let K_CHANNEL_EMAIL: String = "channel_email"
    public static let K_FREQ: String = "freq"

    private let configRepo: ConfigRepo

    public init(configRepo: ConfigRepo) {
        this.configRepo = configRepo
    }

    public func register(router: Router): Unit {
        // 非公开接口：认证中间件（main.cj 装配）保证 req.subjectId 已绑定，
        // 偏好数据一律按 req.subjectId 隔离，无需额外权限声明。
        router.get("/api/notify/prefs", { req: ApiRequest => this.getPrefs(req) })
        router.put("/api/notify/prefs", { req: ApiRequest => this.putPrefs(req) })
    }

    /**
     * GET /api/notify/prefs —— 返回当前用户的全部通知偏好（带默认值兜底）。
     */
    private func getPrefs(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let key = { f: String => "u:${uid}:${f}" }
        let sb = StringBuilder()
        sb.append("{")
        sb.append("\"dndEnabled\":${if (this.boolOf(key(K_DND_ENABLED), false)) { "true" } else { "false" }},")
        sb.append("\"dndStart\":\"${ApiResponse.escape(this.value(key(K_DND_START), "22:00"))}\",")
        sb.append("\"dndEnd\":\"${ApiResponse.escape(this.value(key(K_DND_END), "08:00"))}\",")
        sb.append("\"channelInApp\":${if (this.boolOf(key(K_CHANNEL_INAPP), true)) { "true" } else { "false" }},")
        sb.append("\"channelEmail\":${if (this.boolOf(key(K_CHANNEL_EMAIL), false)) { "true" } else { "false" }},")
        sb.append("\"freq\":\"${ApiResponse.escape(this.value(key(K_FREQ), "realtime"))}\"}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * PUT /api/notify/prefs —— 增量更新当前用户偏好。
     *
     * 仅接受白名单字段；缺省字段保持不变（upsert，不动其他 key）。
     */
    private func putPrefs(req: ApiRequest): ApiResponse {
        let uid = UserRepo.parseId(req.subjectId)
        let json = match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        let key = { f: String => "u:${uid}:${f}" }
        let op = UserRepo.parseId(req.subjectId)

        this.setIfPresent(json, key(K_DND_ENABLED), "dndEnabled", op)
        this.setIfPresent(json, key(K_DND_START), "dndStart", op)
        this.setIfPresent(json, key(K_DND_END), "dndEnd", op)
        this.setIfPresent(json, key(K_CHANNEL_INAPP), "channelInApp", op)
        this.setIfPresent(json, key(K_CHANNEL_EMAIL), "channelEmail", op)
        this.setIfPresent(json, key(K_FREQ), "freq", op)

        return ApiResponse.ok("{\"updated\":true}", req.requestId)
    }

    // ---- 辅助 ----

    private func setIfPresent(
        json: SimpleJson,
        settingKey: String,
        field: String,
        operatorId: Int64
    ): Unit {
        let raw = json.get(field)
        match (raw) {
            case Some(v) =>
                if (v.isEmpty()) {
                    return
                }
                // 布尔 / 字符串均原样存为 "true"/"false"/文本
                this.configRepo.setSetting(
                    NotifyRoutes.SCOPE, settingKey, v, "string", false,
                    "用户通知偏好：${field}", operatorId
                )
            case None => ()
        }
    }

    private func value(key: String, defaultVal: String): String {
        let v = this.configRepo.getValue(NotifyRoutes.SCOPE, key, defaultVal)
        if (v.isEmpty()) {
            return defaultVal
        }
        return v
    }

    private func boolOf(key: String, defaultVal: Bool): Bool {
        let v = this.configRepo.getValue(NotifyRoutes.SCOPE, key, if (defaultVal) { "true" } else { "false" })
        if (v == "true") {
            return true
        }
        if (v == "false") {
            return false
        }
        return defaultVal
    }
}

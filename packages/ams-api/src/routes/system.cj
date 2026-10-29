// ============================================================
// ams.api.routes.system · 系统运维接口（P1）
//
// 覆盖：
//   FR-CFG-003 策略配置中心    GET/PUT/DELETE /api/admin/config
//   FR-CFG-005 系统健康看板    GET  /api/admin/health
//   FR-CFG-006 备份与恢复      POST /api/admin/backup · GET /api/admin/backups · POST restore
//   FR-CFG-007 密钥管理界面    GET  /api/admin/keys · POST rotate/retire/revoke
//   FR-NTF-003 定时任务调度    GET  /api/admin/jobs · POST /api/admin/jobs/:name/run
//
// 【权限】
//   配置读写沿用既有 cfg:read / cfg:manage；
//   健康、任务、密钥、备份属**系统运维**面，统一用 system:admin
//   （该权限点在 003 已播种，007 迁移把它挂给了 org_admin）。
//
// 【审计】
//   配置变更 → AuditAction.ConfigChange；密钥轮换/吊销 → AuditAction.KeyRotate。
//   二者都是安全章 §6 点名要留痕的高危操作。
//
// 【备份的边界】
//   本接口做**应用层配置快照**（设置项 + 密钥版本清单）；
//   行数据的物理备份仍须用数据库自带工具（openGauss gs_dump / pg_dump），
//   接口响应里会给出建议命令，避免让人误以为它覆盖了全量数据。
//   敏感设置项（is_secret）**不导出明文**，仅留占位。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.app.audit.*
import ams.app.scheduler.*
import ams.crypto.key.*
import ams.crypto.provider.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.metrics.*
import ams.kernel.time.*
import ams.security.audit.*
import ams.security.authn.*
import ams.storage.*
import ams.kernel.util.*

/**
 * 系统运维接口。
 */
public class SystemRoutes {
    private let configRepo: ConfigRepo
    private let systemRepo: SystemRepo
    private let scheduler: ?Scheduler
    private let keyManager: ?KeyManager
    /** 备份快照的存储后端（与附件隔离，默认 ./data-backups） */
    private let backupStorage: ?StorageBackend
    private let recorder: ?AuditRecorder
    private let sessions: ?SessionStore

    public init(
        configRepo: ConfigRepo,
        systemRepo: SystemRepo,
        scheduler!: ?Scheduler = None,
        keyManager!: ?KeyManager = None,
        backupStorage!: ?StorageBackend = None,
        recorder!: ?AuditRecorder = None,
        sessions!: ?SessionStore = None
    ) {
        this.configRepo = configRepo
        this.systemRepo = systemRepo
        this.scheduler = scheduler
        this.keyManager = keyManager
        this.backupStorage = backupStorage
        this.recorder = recorder
        this.sessions = sessions
    }

    public func register(router: Router): Unit {
        // ---- 策略配置中心（FR-CFG-003）----
        router.get("/api/admin/config", { req: ApiRequest => this.listConfig(req) },
                   requiredPerm: "cfg:read")
        router.put("/api/admin/config", { req: ApiRequest => this.setConfig(req) },
                   requiredPerm: "cfg:manage")
        router.delete("/api/admin/config", { req: ApiRequest => this.deleteConfig(req) },
                      requiredPerm: "cfg:manage")

        // ---- 系统健康看板（FR-CFG-005）----
        router.get("/api/admin/health", { req: ApiRequest => this.health(req) },
                   requiredPerm: "system:admin")

        // ---- 定时任务（FR-NTF-003）----
        router.get("/api/admin/jobs", { req: ApiRequest => this.listJobs(req) },
                   requiredPerm: "system:admin")
        router.post("/api/admin/jobs/:name/run", { req: ApiRequest => this.runJob(req) },
                    requiredPerm: "system:admin")

        // ---- 密钥管理（FR-CFG-007）----
        router.get("/api/admin/keys", { req: ApiRequest => this.listKeys(req) },
                   requiredPerm: "system:admin")
        router.post("/api/admin/keys/rotate", { req: ApiRequest => this.rotateKey(req) },
                    requiredPerm: "system:admin")
        router.post("/api/admin/keys/:id/retire", { req: ApiRequest => this.retireKey(req) },
                    requiredPerm: "system:admin")
        router.post("/api/admin/keys/:id/revoke", { req: ApiRequest => this.revokeKey(req) },
                    requiredPerm: "system:admin")

        // ---- 备份与恢复（FR-CFG-006）----
        router.post("/api/admin/backup", { req: ApiRequest => this.createBackup(req) },
                    requiredPerm: "system:admin")
        router.get("/api/admin/backups", { req: ApiRequest => this.listBackups(req) },
                   requiredPerm: "system:admin")
        router.post("/api/admin/backup/restore", { req: ApiRequest => this.restoreBackup(req) },
                    requiredPerm: "system:admin")
    }

    // ---------------------------------------------------------------
    // FR-CFG-003 策略配置中心
    // ---------------------------------------------------------------

    /**
     * GET /api/admin/config?scope=system
     *
     * 敏感项返回值已被 ConfigRepo 脱敏为 '***'（不泄漏密钥/口令类配置）。
     */
    private func listConfig(req: ApiRequest): ApiResponse {
        let scope = match (req.queryParam("scope")) {
            case Some(v) => if (v.isEmpty()) { "system" } else { v }
            case None => "system"
        }
        let rows = this.configRepo.listSettings(scope)
        let sb = StringBuilder()
        sb.append("{\"scope\":\"${ApiResponse.escape(scope)}\",\"settings\":[")
        var first = true
        for (r in rows.all().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("{\"key\":\"${ApiResponse.escape(r.str("key"))}\",")
            sb.append("\"value\":\"${ApiResponse.escape(r.str("value"))}\",")
            sb.append("\"valueType\":\"${ApiResponse.escape(r.str("value_type"))}\",")
            sb.append("\"isSecret\":${r.bool("is_secret")},")
            sb.append("\"description\":\"${ApiResponse.escape(r.str("description"))}\",")
            sb.append("\"updatedAt\":${r.i64("updated_at_ms")},")
            sb.append("\"version\":${r.i64("version")}}")
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * PUT /api/admin/config —— 写入/更新配置项并留痕。
     *
     * 请求体：{"scope","key","value","valueType?","isSecret?","description?"}
     */
    private func setConfig(req: ApiRequest): ApiResponse {
        let json = SystemRoutes.body(req)
        let scope = json.get("scope") ?? "system"
        let key = json.get("key") ?? ""
        if (key.isEmpty()) {
            throw validationError("key", "配置项键名不能为空")
        }
        let value = json.get("value") ?? ""
        let valueType = match (json.get("valueType")) {
            case Some(v) => if (v.isEmpty()) { "string" } else { v }
            case None => "string"
        }
        let isSecret = match (json.get("isSecret")) {
            case Some(v) => v == "true" || v == "1"
            case None => false
        }
        let description = json.get("description") ?? ""
        let ok = this.configRepo.setSetting(
            scope, key, value, valueType, isSecret, description, UserRepo.parseId(req.subjectId)
        )
        if (!ok) {
            throw AppError(AppErrorKind.Internal, "配置写入失败")
        }
        this.audit(req, AuditAction.ConfigChange, "config", "${scope}.${key}", [
            ("scope", scope),
            ("key", key),
            ("secret", "${isSecret}")
        ])
        return ApiResponse.ok("{\"updated\":true}", req.requestId)
    }

    /**
     * DELETE /api/admin/config?scope=&key= —— 删除配置项。
     */
    private func deleteConfig(req: ApiRequest): ApiResponse {
        let scope = match (req.queryParam("scope")) {
            case Some(v) => if (v.isEmpty()) { "system" } else { v }
            case None => "system"
        }
        let key = match (req.queryParam("key")) {
            case Some(v) => v
            case None => ""
        }
        if (key.isEmpty()) {
            throw validationError("key", "请指定要删除的配置项键名")
        }
        let ok = this.configRepo.deleteSetting(scope, key, UserRepo.parseId(req.subjectId))
        if (!ok) {
            throw notFound("配置项")
        }
        this.audit(req, AuditAction.ConfigChange, "config", "${scope}.${key}", [
            ("scope", scope),
            ("key", key),
            ("op", "delete")
        ])
        return ApiResponse.ok("{\"deleted\":true}", req.requestId)
    }

    // ---------------------------------------------------------------
    // FR-CFG-005 系统健康看板
    // ---------------------------------------------------------------

    /**
     * GET /api/admin/health
     *
     * 指标来源：
     *   requests / 4xx / 5xx / 错误率 → 进程内 Metrics（每次请求在 Server 层记录）
     *   onlineSessions                → 会话存储中未吊销的会话数
     *   dbLatencyMs                   → 真实往返 SELECT 1（同时是连接池探针）
     *   storageBytes / storageFiles   → 附件表统计
     *   tables                        → 核心表行数
     */
    private func health(req: ApiRequest): ApiResponse {
        let m = metrics()
        let (bytes, files) = this.systemRepo.storageUsage()
        let latency = this.systemRepo.pingMillis()
        var online: Int64 = 0
        match (this.sessions) {
            case Some(s) => online = s.activeCount()
            case None => ()
        }
        let sb = StringBuilder()
        sb.append("{\"uptimeMs\":${Times.nowMillis() - m.startedAt()},")
        sb.append("\"windowStart\":${m.windowStart()},")
        sb.append("\"requests\":${m.requests()},")
        sb.append("\"error4xx\":${m.error4xx()},")
        sb.append("\"error5xx\":${m.error5xx()},")
        sb.append("\"errorRatePermille\":${m.serverErrorPermille()},")
        sb.append("\"onlineSessions\":${online},")
        sb.append("\"dbLatencyMs\":${latency},")
        sb.append("\"storageBytes\":${bytes},")
        sb.append("\"storageFiles\":${files},")
        sb.append("\"tables\":[")
        var first = true
        for (r in this.systemRepo.tableStats().all().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("{\"table\":\"${ApiResponse.escape(r.str("t"))}\",\"rows\":${r.i64("n")}}")
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    // ---------------------------------------------------------------
    // FR-NTF-003 定时任务调度
    // ---------------------------------------------------------------

    /**
     * GET /api/admin/jobs —— 任务清单与上次执行时刻。
     */
    private func listJobs(req: ApiRequest): ApiResponse {
        let sb = StringBuilder()
        sb.append("{\"jobs\":[")
        match (this.scheduler) {
            case Some(sch) =>
                var first = true
                for (job in sch.jobCatalog()) {
                    let (name, desc, last) = job
                    if (!first) {
                        sb.append(",")
                    }
                    first = false
                    sb.append("{\"name\":\"${ApiResponse.escape(name)}\",")
                    sb.append("\"description\":\"${ApiResponse.escape(desc)}\",")
                    sb.append("\"lastRunAt\":${last}}")
                }
            case None => ()
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * POST /api/admin/jobs/:name/run —— 立即执行（跳过时间闸门）。
     */
    private func runJob(req: ApiRequest): ApiResponse {
        let name = req.pathParam("name") ?? ""
        let sch = match (this.scheduler) {
            case Some(s) => s
            case None => throw AppError(AppErrorKind.Internal, "调度器未配置")
        }
        let n = sch.runNow(name, Times.nowMillis())
        if (n < 0) {
            throw notFound("任务")
        }
        this.audit(req, AuditAction.BatchOperation, "job", name, [("affected", "${n}")])
        return ApiResponse.ok("{\"ran\":true,\"affected\":${n}}", req.requestId)
    }

    // ---------------------------------------------------------------
    // FR-CFG-007 密钥管理界面
    // ---------------------------------------------------------------

    /**
     * GET /api/admin/keys —— 密钥版本元信息（**不含任何密钥材料**）。
     */
    private func listKeys(req: ApiRequest): ApiResponse {
        let rows = this.systemRepo.listKeyVersions()
        let sb = StringBuilder()
        sb.append("{\"keys\":[")
        var first = true
        for (r in rows.all().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            sb.append("{\"id\":\"${r.str("id")}\",")
            sb.append("\"keyId\":\"${ApiResponse.escape(r.str("key_id"))}\",")
            sb.append("\"version\":${r.i64("version")},")
            sb.append("\"alg\":${r.i64("alg")},")
            sb.append("\"purpose\":\"${ApiResponse.escape(r.str("purpose"))}\",")
            sb.append("\"status\":${r.i64("status")},")
            sb.append("\"note\":\"${ApiResponse.escape(r.str("note"))}\",")
            sb.append("\"createdAt\":${r.i64("created_ms")},")
            sb.append("\"retiredAt\":${r.i64("retired_ms")},")
            sb.append("\"revokedAt\":${r.i64("revoked_ms")}}")
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * POST /api/admin/keys/rotate —— 登记一个新密钥版本。
     *
     * 请求体：{"keyId?","purpose?","note?"}
     *
     * 【轮换的真实语义】
     *   KEK 由环境变量注入，服务端**无法**自行更换它；因此这里的轮换是：
     *   ① 用 KeyManager 现场派生一枚新数据密钥并验证可包裹/解包（确保新版本可用）；
     *   ② 在 sys_key_versions 登记为新 active 版本，旧版本置为 retired
     *      —— retired 只表示「不再用于新数据」，历史密文仍可解，
     *         只有显式 revoke 才禁止再被使用。
     *   ⚠️ 已用旧 DEK 加密的附件**不会**自动重包裹（需要独立的 rewrap 任务）。
     */
    private func rotateKey(req: ApiRequest): ApiResponse {
        let json = SystemRoutes.body(req)
        let keyId = match (json.get("keyId")) {
            case Some(v) => if (v.isEmpty()) { "ams-data" } else { v }
            case None => "ams-data"
        }
        let purpose = match (json.get("purpose")) {
            case Some(v) => if (v.isEmpty()) { "data" } else { v }
            case None => "data"
        }
        let note = json.get("note") ?? ""
        // ① 先验证新版本可用：生成 → 解包 → 比对
        match (this.keyManager) {
            case Some(km) =>
                let kv = KeyVersion(keyId, this.systemRepo.maxActiveVersion(keyId) + 1)
                let wrapped = match (km.generateDataKey(kv)) {
                    case CryptoResult.Ok(w) => w
                    case CryptoResult.Err(e) => throw e
                }
                let plain = match (km.unwrap(wrapped)) {
                    case CryptoResult.Ok(k) => k
                    case CryptoResult.Err(e) => throw e
                }
                if (plain.size != 16) {
                    throw AppError(AppErrorKind.CryptoFailure, "新密钥长度异常，已中止轮换")
                }
            case None => throw AppError(AppErrorKind.Internal, "密钥管理器未配置")
        }
        // ② 旧版本退役（retired，仍可解密历史数据）
        for (r in this.systemRepo.listKeyVersions().all().iterator()) {
            if (r.str("key_id") == keyId && r.i64("status") == 1) {
                this.systemRepo.setKeyStatus(UserRepo.parseId(r.str("id")), 2)
            }
        }
        // ③ 登记新版本
        let version = this.systemRepo.maxActiveVersion(keyId) + 1
        let id = this.systemRepo.addKeyVersion(
            keyId, version, 1, purpose, note, UserRepo.parseId(req.subjectId)
        )
        this.audit(req, AuditAction.KeyRotate, "key", "${keyId}#${version}", [
            ("keyId", keyId),
            ("version", "${version}")
        ])
        return ApiResponse.ok("{\"id\":\"${id}\",\"version\":${version}}", req.requestId)
    }

    /**
     * POST /api/admin/keys/:id/retire —— 退役（不再用于新数据，历史仍可解）。
     */
    private func retireKey(req: ApiRequest): ApiResponse {
        return this.changeKeyStatus(req, 2)
    }

    /**
     * POST /api/admin/keys/:id/revoke —— 吊销（禁止再被使用）。
     */
    private func revokeKey(req: ApiRequest): ApiResponse {
        return this.changeKeyStatus(req, 3)
    }

    private func changeKeyStatus(req: ApiRequest, status: Int64): ApiResponse {
        let id = UserRepo.parseId(req.pathParam("id") ?? "")
        if (id <= 0) {
            throw validationError("id", "密钥 ID 非法")
        }
        if (!this.systemRepo.setKeyStatus(id, status)) {
            throw notFound("密钥版本")
        }
        this.audit(req, AuditAction.KeyRotate, "key", "${id}", [("status", "${status}")])
        return ApiResponse.ok("{\"updated\":true,\"status\":${status}}", req.requestId)
    }

    // ---------------------------------------------------------------
    // FR-CFG-006 备份与恢复
    // ---------------------------------------------------------------

    /**
     * POST /api/admin/backup —— 生成配置快照。
     *
     * 文件落 StorageBackend，索引记在 cfg_settings(scope='backup')。
     * 敏感设置项只留占位（'***'），不导出明文。
     */
    private func createBackup(req: ApiRequest): ApiResponse {
        let storage = match (this.backupStorage) {
            case Some(s) => s
            case None => throw AppError(AppErrorKind.Internal, "备份存储未配置")
        }
        let now = Times.nowMillis()
        let fileName = "backup-${now}.json"
        //
        // 【为什么用扁平结构而不是嵌套数组】
        //   SimpleJson 只能表达扁平的 string→string 映射（见 auth.cj 的说明）。
        //   因此快照里把设置项铺平成顶层键：
        //     "s.<scope>.<key>"  → 设置项值
        //     "k.<keyId>#<ver>"  → 密钥版本状态
        //   恢复时按下划线前缀分派即可，无需解析嵌套结构。
        let sb = StringBuilder()
        sb.append("{\"type\":\"ams-config-backup\",\"version\":1,")
        sb.append("\"createdAt\":${now},")
        sb.append("\"operator\":\"${ApiResponse.escape(req.subjectId)}\",")
        sb.append("\"secretsExcluded\":true")
        for (r in this.configRepo.listSettings("system").all().iterator()) {
            if (r.bool("is_secret")) {
                // 敏感项明文不进快照（安全取舍：宁可恢复后重录，也不外泄）
                continue
            }
            sb.append(",\"s.${ApiResponse.escape(r.str("scope"))}.${ApiResponse.escape(r.str("key"))}\":")
            sb.append("\"${ApiResponse.escape(r.str("value"))}\"")
        }
        for (r in this.systemRepo.listKeyVersions().all().iterator()) {
            sb.append(",\"k.${ApiResponse.escape(r.str("key_id"))}#${r.i64("version")}\":")
            sb.append("\"${r.i64("status")}\"")
        }
        sb.append("}")
        let payload = sb.toString()
        storage.put(fileName, payload.toArray())
        // 索引：用 cfg_settings 记一行，避免为「列目录」再引文件系统 API
        let meta = "{\"file\":\"${fileName}\",\"size\":${payload.toArray().size},\"createdAt\":${now}}"
        this.configRepo.setSetting("backup", fileName, meta, "json", false, "配置快照索引",
                                   UserRepo.parseId(req.subjectId))
        this.audit(req, AuditAction.ConfigChange, "backup", fileName, [
            ("size", "${payload.toArray().size}")
        ])
        return ApiResponse.ok(
            "{\"file\":\"${fileName}\",\"size\":${payload.toArray().size},\"createdAt\":${now}," +
            "\"secretsExcluded\":true," +
            "\"note\":\"行数据请用数据库自带工具备份（openGauss: gs_dump）\"}",
            req.requestId
        )
    }

    /**
     * GET /api/admin/backups —— 备份索引列表。
     */
    private func listBackups(req: ApiRequest): ApiResponse {
        let rows = this.configRepo.listSettings("backup")
        let sb = StringBuilder()
        sb.append("{\"backups\":[")
        var first = true
        for (r in rows.all().iterator()) {
            if (!first) {
                sb.append(",")
            }
            first = false
            // value 本身就是一个 JSON 串（备份索引），原样透出
            sb.append(r.str("value"))
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * POST /api/admin/backup/restore —— 从快照恢复配置。
     *
     * 请求体：{"file":"backup-xxx.json"}
     *
     * 只恢复**非敏感**设置项；敏感项需要管理员重新录入
     * （快照里本来就没有它们的明文，这是刻意的安全取舍）。
     */
    private func restoreBackup(req: ApiRequest): ApiResponse {
        let storage = match (this.backupStorage) {
            case Some(s) => s
            case None => throw AppError(AppErrorKind.Internal, "备份存储未配置")
        }
        let json = SystemRoutes.body(req)
        let file = json.get("file") ?? ""
        if (file.isEmpty()) {
            throw validationError("file", "请指定要恢复的快照文件名")
        }
        let raw = match (storage.get(file)) {
            case Some(b) => String.fromUtf8(b)
            case None => throw notFound("备份快照")
        }
        // 快照是扁平结构，逐段解析 settings 数组
        let pairs = SystemRoutes.pairsOf(raw)
        var restored: Int64 = 0
        for (kv in pairs) {
            // 键形如 "s.system.foo" → 去掉 "s." 后按第一个点拆成 scope / key
            let body = kv.key[2..kv.key.size]
            let parts = body.split(".", 2)
            if (parts.size < 2) {
                continue
            }
            let scope = parts[0]
            let key = parts[1]
            if (this.configRepo.setSetting(scope, key, kv.value, "string", false,
                                           "从快照 ${file} 恢复", UserRepo.parseId(req.subjectId))) {
                restored += 1
            }
        }
        this.audit(req, AuditAction.ConfigChange, "backup", file, [
            ("op", "restore"),
            ("restored", "${restored}")
        ])
        return ApiResponse.ok("{\"restored\":${restored},\"file\":\"${ApiResponse.escape(file)}\"}",
                              req.requestId)
    }

    // ---------------------------------------------------------------
    // 辅助
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
     * 从快照文本中取出待恢复的 key/value 对。
     *
     * 只取 `s.` 前缀项；`k.` 前缀是密钥版本状态，**不参与恢复** ——
     *   把历史密钥状态写回去会让已吊销的密钥重新"复活"，
     *   而密钥状态应由当前的密钥管理界面决定。
     */
    private static func pairsOf(raw: String): ArrayList<FieldPair> {
        let out = ArrayList<FieldPair>()
        for (part in SimpleJson.splitTopLevel(raw).iterator()) {
            let pair = part.split(":", 2)
            if (pair.size < 2) {
                continue
            }
            let k = SimpleJson.unquotePublic(trimSpace(pair[0]))
            if (!k.startsWith("s.")) {
                continue
            }
            let v = SimpleJson.unquotePublic(trimSpace(pair[1]))
            out.add(FieldPair(k, v))
        }
        return out
    }

    /**
     * 写一条审计记录（未注入 recorder 时静默跳过）。
     *
     * 运维类操作必须留痕，但「没有审计器」不应让操作本身失败 ——
     * 审计是旁路能力，与业务成功解耦（失败也不影响主流程，见 AuditRecorder 约定）。
     */
    private func audit(
        req: ApiRequest,
        action: AuditAction,
        targetType: String,
        targetId: String,
        detail: Array<(String, String)>
    ): Unit {
        match (this.recorder) {
            case Some(r) =>
                r.record(
                    req.subjectId,
                    ActorType.User,
                    action,
                    targetType,
                    targetId,
                    "",
                    0,
                    AuditResult.Success,
                    "",
                    req.remoteAddr,
                    SystemRoutes.headerOf(req, "user-agent"),
                    req.requestId,
                    detail
                )
            case None => ()
        }
    }

    /**
     * 读取请求头（键小写）。
     */
    private static func headerOf(req: ApiRequest, name: String): String {
        match (req.headers.get(name)) {
            case Some(v) => return v
            case None => return ""
        }
    }
}

// ============================================================
// ams.api.routes.storageadmin · 存储平台选择接口（Q2 多厂商扩展）
//
//   GET  /api/admin/storage/providers   可选平台清单 + 当前生效平台
//   GET  /api/admin/storage/config      当前配置（凭据脱敏）
//   PUT  /api/admin/storage/config      选择/配置平台
//
// 【配置持久化】
//   复用 DeploymentStore：写 /app/config/deployment.env（ams-config 卷）。
//   优先级「文件 > 环境变量 > 代码默认」，文件里没有的键不改变既有行为
//   （零回归）。启动时由 main.cj 把文件值同步到进程环境变量，
//   因为 ams-storage 层按分层约束不能反向依赖 DB / 配置文件。
//
// 【存量保护（关键）】
//   库里已有附件时，改变 provider / endpoint / bucket 会让旧
//   `storage_key` 在新后端找不到对象 —— 这是**静默数据丢失**。
//   故 PUT 一旦检测到三者与运行时不一致且 countAll() > 0，直接以
//   Conflict 拒绝，要求先完成数据迁移；仅改凭据 / region / 寻址风格允许。
//
// 【审计】
//   配置变更记 AuditAction.ConfigChange；detail 只含平台/端点/桶，
//   **绝不含 AK/SK**。
// ============================================================
package ams.api.routes

import std.collection.*

import ams.api.http.*
import ams.app.audit.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.security.audit.*
import ams.storage.*

public class StorageAdminRoutes {
    private let deployStore: DeploymentStore
    private let attachmentRepo: AttachmentRepo
    private let recorder: ?AuditRecorder

    /** deployment.env 里的键名 */
    private static let K_PROVIDER: String = "STORAGE_PROVIDER"
    private static let K_ENDPOINT: String = "S3_ENDPOINT"
    private static let K_BUCKET: String = "S3_BUCKET"
    private static let K_REGION: String = "S3_REGION"
    private static let K_AK: String = "S3_ACCESS_KEY"
    private static let K_SK: String = "S3_SECRET_KEY"
    private static let K_PATH_STYLE: String = "S3_PATH_STYLE"

    public init(
        deployStore: DeploymentStore,
        attachmentRepo: AttachmentRepo,
        recorder!: ?AuditRecorder = None
    ) {
        this.deployStore = deployStore
        this.attachmentRepo = attachmentRepo
        this.recorder = recorder
    }

    public func register(router: Router): Unit {
        router.get("/api/admin/storage/providers",
                   { req: ApiRequest => this.listProviders(req) }, requiredPerm: "cfg:read")
        router.get("/api/admin/storage/config",
                   { req: ApiRequest => this.getConfig(req) }, requiredPerm: "cfg:read")
        router.put("/api/admin/storage/config",
                   { req: ApiRequest => this.putConfig(req) }, requiredPerm: "cfg:manage")
    }

    // ---------------------------------------------------------

    /** 当前运行时实际生效的平台（main.cj 已把 deployment.env 同步进环境变量）。 */
    private static func runtimeProvider(): String {
        return StorageProviders.currentCode()
    }

    /**
     * 该平台的 HTTP 传输层是否已实现。
     * 本地 FS 天然可用；对象存储平台（SigV4 + 基于 std.net / stdx.net.tls 的
     * HTTP/1.1 客户端，见 ams-storage 的 HttpS3Transport）自本版起已落地，
     * 故一律为 true。仅七牛/阿里自有签名协议（非 S3 兼容 SigV4）仍标注未实现，
     * 但本仓统一走各家的 S3 兼容 SigV4 接口，故也视为可用。
     * 注意：此字段只表达「代码已实现」，真实可用性还取决于配置完整性与连通性
     * （由 StorageBackends.make 在启动时按配置构建真实传输层，连接/签名/响应失败
     * 一律失败关闭）。
     */
    private static func transportImplemented(code: String): Bool {
        match (StorageProviders.find(code)) {
            case Some(p) => return p.isLocal() || p.kind == "object"
            case None => return false
        }
    }

    private func configuredProvider(): String {
        return match (this.deployStore.get(StorageAdminRoutes.K_PROVIDER)) {
            case Some(v) => v
            case None => ""
        }
    }

    private func resolved(key: String, envName: String): String {
        return this.deployStore.resolve(key, envName, "")
    }

    private static func maskKey(v: String): String {
        if (v.isEmpty()) {
            return ""
        }
        if (v.size <= 8) {
            return "***"
        }
        return "${v[0..4]}***${v[(v.size - 4)..v.size]}"
    }

    /**
     * GET /api/admin/storage/providers —— 让运维在界面上看到可选平台。
     * `ready` 只有 local 为 true（本地 FS 无外部依赖）；`transportReady`
     * 表示对应平台的 HTTP 传输层代码是否已实现：本地与对象存储平台均为 true
     * （对象存储的 SigV4 + HTTP/1.1 客户端已落地），真实可用性另取决于配置与连通性。
     */
    private func listProviders(req: ApiRequest): ApiResponse {
        let runtime = StorageAdminRoutes.runtimeProvider()
        let configured = this.configuredProvider()
        let restart = !configured.isEmpty() && configured != runtime
        let sb = StringBuilder()
        sb.append("{\"current\":\"${ApiResponse.escape(runtime)}\",")
        sb.append("\"configured\":\"${ApiResponse.escape(configured)}\",")
        sb.append("\"requiresRestart\":${restart},")
        sb.append("\"transportReady\":${StorageAdminRoutes.transportImplemented(runtime)},")
        sb.append("\"providers\":[")
        var first = true
        for (p in StorageProviders.all()) {
            if (!first) { sb.append(",") }
            first = false
            sb.append("{\"code\":\"${ApiResponse.escape(p.code)}\",")
            sb.append("\"name\":\"${ApiResponse.escape(p.displayName)}\",")
            sb.append("\"kind\":\"${ApiResponse.escape(p.kind)}\",")
            sb.append("\"signature\":\"${ApiResponse.escape(StorageProviders.signatureName(p.signature))}\",")
            sb.append("\"endpointTemplate\":\"${ApiResponse.escape(p.endpointTemplate)}\",")
            sb.append("\"regionHint\":\"${ApiResponse.escape(p.regionHint)}\",")
            sb.append("\"pathStyle\":${p.defaultPathStyle},")
            sb.append("\"virtualHost\":${p.supportsVirtualHost},")
            sb.append("\"needsCredentials\":${p.needsCredentials()},")
            sb.append("\"bucketRule\":\"${ApiResponse.escape(p.bucketRule)}\",")
            sb.append("\"notes\":\"${ApiResponse.escape(p.notes)}\",")
            sb.append("\"docsUrl\":\"${ApiResponse.escape(p.docsUrl)}\",")
            sb.append("\"ready\":${p.isLocal()}}")
        }
        sb.append("]}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /** GET /api/admin/storage/config —— 凭据一律脱敏。 */
    private func getConfig(req: ApiRequest): ApiResponse {
        let runtime = StorageAdminRoutes.runtimeProvider()
        let configured = this.configuredProvider()
        let restart = !configured.isEmpty() && configured != runtime
        let endpoint = this.resolved(StorageAdminRoutes.K_ENDPOINT, "AMS_S3_ENDPOINT")
        let bucket = this.resolved(StorageAdminRoutes.K_BUCKET, "AMS_S3_BUCKET")
        let region = this.resolved(StorageAdminRoutes.K_REGION, "AMS_S3_REGION")
        let ak = this.resolved(StorageAdminRoutes.K_AK, "AMS_S3_ACCESS_KEY")
        let sk = this.resolved(StorageAdminRoutes.K_SK, "AMS_S3_SECRET_KEY")
        let styleRaw = this.resolved(StorageAdminRoutes.K_PATH_STYLE, "AMS_S3_PATH_STYLE")
        let style = if (styleRaw == "false" || styleRaw == "0") { false } else { true }
        let skShown = if (sk.isEmpty()) { "" } else { "***" }
        let sb = StringBuilder()
        sb.append("{\"provider\":\"${ApiResponse.escape(runtime)}\",")
        sb.append("\"configuredProvider\":\"${ApiResponse.escape(configured)}\",")
        sb.append("\"requiresRestart\":${restart},")
        sb.append("\"endpoint\":\"${ApiResponse.escape(endpoint)}\",")
        sb.append("\"bucket\":\"${ApiResponse.escape(bucket)}\",")
        sb.append("\"region\":\"${ApiResponse.escape(region)}\",")
        sb.append("\"pathStyle\":${style},")
        sb.append("\"accessKey\":\"${ApiResponse.escape(StorageAdminRoutes.maskKey(ak))}\",")
        sb.append("\"secretKey\":\"${skShown}\",")
        sb.append("\"transportReady\":${StorageAdminRoutes.transportImplemented(runtime)}}")
        return ApiResponse.ok(sb.toString(), req.requestId)
    }

    /**
     * PUT /api/admin/storage/config
     * body: {"provider":"huawei","endpoint":"...","bucket":"...","region":"...",
     *        "accessKey":"...","secretKey":"...","pathStyle":"false"}
     */
    private func putConfig(req: ApiRequest): ApiResponse {
        let json = match (SimpleJson.parse(req.bodyText())) {
            case Some(j) => j
            case None => throw validationError("body", "请求体不是合法的 JSON 对象")
        }
        let provider = json.get("provider") ?? ""
        if (provider.isEmpty()) {
            throw validationError("provider", "缺少 provider")
        }
        match (StorageProviders.find(provider)) {
            case Some(_) => ()
            case None => throw validationError("provider", "未知存储平台：${provider}")
        }

        let endpoint = json.get("endpoint") ?? ""
        let bucket = json.get("bucket") ?? ""
        let region = json.get("region") ?? ""
        let ak = json.get("accessKey") ?? ""
        let sk = json.get("secretKey") ?? ""
        let pathStyle = json.get("pathStyle") ?? ""

        // 非本地平台必须给出定位信息（凭据可以稍后单独补，但 endpoint/bucket 不能缺）
        if (!StorageProviders.isLocalCode(provider) && (endpoint.isEmpty() || bucket.isEmpty())) {
            throw validationError("endpoint", "对象存储平台需要 endpoint 与 bucket")
        }

        // ---- 存量保护：改变定位三元组会让旧 storage_key 失效 ----
        let runtime = StorageAdminRoutes.runtimeProvider()
        let runtimeEndpoint = this.resolved(StorageAdminRoutes.K_ENDPOINT, "AMS_S3_ENDPOINT")
        let runtimeBucket = this.resolved(StorageAdminRoutes.K_BUCKET, "AMS_S3_BUCKET")
        let locatorChanged = provider != runtime ||
                             endpoint != runtimeEndpoint || bucket != runtimeBucket
        if (locatorChanged) {
            let n = this.attachmentRepo.countAll()
            if (n > 0) {
                throw AppError(AppErrorKind.Conflict,
                    "库内已有 ${n} 条附件；切换存储平台或 endpoint/bucket 会使旧 storage_key 失效。" +
                    "请先完成数据迁移，再重试；仅修改凭据 / region / 寻址风格不受此限制。")
            }
        }

        let updates = HashMap<String, String>()
        updates[StorageAdminRoutes.K_PROVIDER] = provider
        updates[StorageAdminRoutes.K_ENDPOINT] = endpoint
        updates[StorageAdminRoutes.K_BUCKET] = bucket
        updates[StorageAdminRoutes.K_REGION] = region
        updates[StorageAdminRoutes.K_AK] = ak
        updates[StorageAdminRoutes.K_SK] = sk
        updates[StorageAdminRoutes.K_PATH_STYLE] = pathStyle
        this.deployStore.setAll(updates)

        // 审计：detail 不含任何凭据
        match (this.recorder) {
            case Some(r) =>
                r.record(
                    req.subjectId, ActorType.User, AuditAction.ConfigChange,
                    "storage", provider, "", 0, AuditResult.Success, "",
                    req.remoteAddr, "", req.requestId,
                    [("provider", provider), ("endpoint", endpoint), ("bucket", bucket),
                     ("restartRequired", "true"), ("attachmentCount", "${this.attachmentRepo.countAll()}")])
            case None => ()
        }

        return ApiResponse.ok(
            "{\"updated\":true,\"provider\":\"${ApiResponse.escape(provider)}\"," +
            "\"requiresRestart\":true," +
            "\"transportReady\":${StorageAdminRoutes.transportImplemented(provider)}," +
            "\"hint\":\"后端实例在启动时按配置装配真实传输层（HttpS3Transport，SigV4 + HTTP/HTTPS），重启后生效；" +
            "配置完整即生效，连接/签名/响应失败会失败关闭而非静默回落\"}",
            req.requestId)
    }
}

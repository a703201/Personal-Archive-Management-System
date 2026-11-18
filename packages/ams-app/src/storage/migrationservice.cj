// ============================================================
// ams.app.storage · 存储平台迁移服务（全量 + 增量）
//
// 设计要点：
//   ① 目标配置先写 deployment.env 的 MIGRATION_* 键，**不覆盖现网 S3_*** ，
//      因此切换前重启仍使用源后端，不存在「改配置即静默丢附件」；
//   ② 逐行标记用 arc_attachments.storage_provider 存一次性 marker（mg_…），
//      不用 provider code —— 源/目标同为某平台但 endpoint/bucket 不同时
//      code 相同，用 code 会误判「已迁移」；marker 避开了这个坑；
//   ③ 全量阶段按 id 游标分批搬字节（密文，不解密），完成后进入 catchup，
//      期间 AttachmentService 通过 StorageDualWrite 双写新对象；
//   ④ catchup 无剩余行后进入 ready，运维确认才 cutover（写回现网配置）；
//   ⑤ 回滚把源配置写回并归一平台标记，源端字节始终保留，可反向恢复。
// ============================================================
package ams.app.storage

import std.collection.*

import ams.app.attachment.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.kernel.id.*
import ams.storage.*

/** 迁移状态（API 层据此拼 JSON）。 */
public class MigrationStatus {
    public let phase: String
    public let marker: String
    public let targetProvider: String
    public let targetEndpoint: String
    public let targetBucket: String
    public let targetRegion: String
    public let targetPathStyle: Bool
    public let sourceProvider: String
    public let cursor: Int64
    public let migrated: Int64
    public let failed: Int64
    public let total: Int64
    public let pending: Int64
    public let dualWriteFailures: Int64
    public let requiresRestart: Bool

    public init(
        phase: String, marker: String,
        targetProvider: String, targetEndpoint: String, targetBucket: String,
        targetRegion: String, targetPathStyle: Bool,
        sourceProvider: String,
        cursor: Int64, migrated: Int64, failed: Int64, total: Int64,
        pending: Int64, dualWriteFailures: Int64, requiresRestart: Bool
    ) {
        this.phase = phase
        this.marker = marker
        this.targetProvider = targetProvider
        this.targetEndpoint = targetEndpoint
        this.targetBucket = targetBucket
        this.targetRegion = targetRegion
        this.targetPathStyle = targetPathStyle
        this.sourceProvider = sourceProvider
        this.cursor = cursor
        this.migrated = migrated
        this.failed = failed
        this.total = total
        this.pending = pending
        this.dualWriteFailures = dualWriteFailures
        this.requiresRestart = requiresRestart
    }
}

public class StorageMigrationService {
    private let deployStore: DeploymentStore
    private let repo: AttachmentRepo
    /** 当前运行时后端（源）；迁移期绝不改它的构造配置。 */
    private let sourceBackend: StorageBackend
    private let storageRoot: String
    private let dualWrite: StorageDualWrite

    private static let PHASE: String = "MIGRATION_PHASE"
    private static let MARKER: String = "MIGRATION_MARKER"
    private static let T_PROVIDER: String = "MIGRATION_TARGET_PROVIDER"
    private static let T_ENDPOINT: String = "MIGRATION_TARGET_ENDPOINT"
    private static let T_BUCKET: String = "MIGRATION_TARGET_BUCKET"
    private static let T_REGION: String = "MIGRATION_TARGET_REGION"
    private static let T_STYLE: String = "MIGRATION_TARGET_PATH_STYLE"
    private static let T_AK: String = "MIGRATION_ACCESS_KEY"
    private static let T_SK: String = "MIGRATION_SECRET_KEY"
    private static let S_PROVIDER: String = "MIGRATION_SOURCE_PROVIDER"
    private static let S_ENDPOINT: String = "MIGRATION_SOURCE_ENDPOINT"
    private static let S_BUCKET: String = "MIGRATION_SOURCE_BUCKET"
    private static let S_REGION: String = "MIGRATION_SOURCE_REGION"
    private static let S_STYLE: String = "MIGRATION_SOURCE_PATH_STYLE"
    private static let S_AK: String = "MIGRATION_SOURCE_ACCESS_KEY"
    private static let S_SK: String = "MIGRATION_SOURCE_SECRET_KEY"
    private static let CURSOR: String = "MIGRATION_CURSOR"
    private static let MIGRATED: String = "MIGRATION_MIGRATED"
    private static let FAILED: String = "MIGRATION_FAILED"
    private static let TOTAL: String = "MIGRATION_TOTAL"

    /** 现网生效键（cutover / rollback 写回这里）。 */
    private static let R_PROVIDER: String = "STORAGE_PROVIDER"
    private static let R_ENDPOINT: String = "S3_ENDPOINT"
    private static let R_BUCKET: String = "S3_BUCKET"
    private static let R_REGION: String = "S3_REGION"
    private static let R_AK: String = "S3_ACCESS_KEY"
    private static let R_SK: String = "S3_SECRET_KEY"
    private static let R_STYLE: String = "S3_PATH_STYLE"

    public init(
        deployStore: DeploymentStore,
        repo: AttachmentRepo,
        sourceBackend: StorageBackend,
        storageRoot: String,
        dualWrite: StorageDualWrite
    ) {
        this.deployStore = deployStore
        this.repo = repo
        this.sourceBackend = sourceBackend
        this.storageRoot = storageRoot
        this.dualWrite = dualWrite
    }

    private func raw(key: String): String {
        return this.deployStore.get(key) ?? ""
    }

    private func num(key: String): Int64 {
        return RowData.toI64(this.raw(key))
    }

    private func set(key: String, value: String): Unit {
        let m = HashMap<String, String>()
        m[key] = value
        this.deployStore.setAll(m)
    }

    private func clearAll(): Unit {
        let keys = [
            StorageMigrationService.PHASE, StorageMigrationService.MARKER,
            StorageMigrationService.T_PROVIDER, StorageMigrationService.T_ENDPOINT,
            StorageMigrationService.T_BUCKET, StorageMigrationService.T_REGION,
            StorageMigrationService.T_STYLE, StorageMigrationService.T_AK,
            StorageMigrationService.T_SK, StorageMigrationService.S_PROVIDER,
            StorageMigrationService.S_ENDPOINT, StorageMigrationService.S_BUCKET,
            StorageMigrationService.S_REGION, StorageMigrationService.S_STYLE,
            StorageMigrationService.S_AK, StorageMigrationService.S_SK,
            StorageMigrationService.CURSOR, StorageMigrationService.MIGRATED,
            StorageMigrationService.FAILED, StorageMigrationService.TOTAL,
            StorageDualWrite.RETRY_KEY
        ]
        let m = HashMap<String, String>()
        for (k in keys) {
            m[k] = "" // DeploymentStore.persist() 遇到空值即删除该行
        }
        this.deployStore.setAll(m)
        this.dualWrite.setTarget(None)
    }

    private static func boolOf(v: String): Bool {
        return !(v == "false" || v == "0")
    }

    private static func strOf(v: Bool): String {
        return if (v) { "true" } else { "false" }
    }

    private static func backendCode(provider: String): Int64 {
        return if (StorageProviders.isLocalCode(provider)) {
            StorageBackends.BACKEND_FS
        } else {
            StorageBackends.BACKEND_S3
        }
    }

    /** 构造目标后端；配置缺失 / 非法一律失败关闭。 */
    private func targetBackend(): StorageBackend {
        let provider = this.raw(StorageMigrationService.T_PROVIDER)
        // 仅 `!` 可选参数支持命名实参，前 8 个必填参数必须按位置传（SDK 1.0.5 实测）
        return StorageBackends.makeFrom(
            provider, this.storageRoot, "attachments",
            this.raw(StorageMigrationService.T_ENDPOINT),
            this.raw(StorageMigrationService.T_BUCKET),
            this.raw(StorageMigrationService.T_REGION),
            this.raw(StorageMigrationService.T_AK),
            this.raw(StorageMigrationService.T_SK),
            pathStyle: StorageMigrationService.boolOf(
                this.raw(StorageMigrationService.T_STYLE)))
    }

    /** 当前状态（凭据永不出现在返回值里）。 */
    public func status(): MigrationStatus {
        let marker = this.raw(StorageMigrationService.MARKER)
        let target = this.raw(StorageMigrationService.T_PROVIDER)
        let phaseNow = this.raw(StorageMigrationService.PHASE)
        let pending = if (marker.isEmpty() || phaseNow == "done" || phaseNow == "rolledback") {
            0
        } else {
            this.repo.pendingMigrationCount(marker)
        }
        let configured = this.deployStore.get(StorageMigrationService.R_PROVIDER) ?? ""
        let runtime = StorageProviders.currentCode()
        // 构造函数必填参数按位置传（仅 `!` 可选参数支持命名实参）
        return MigrationStatus(
            this.raw(StorageMigrationService.PHASE), marker,
            target,
            this.raw(StorageMigrationService.T_ENDPOINT),
            this.raw(StorageMigrationService.T_BUCKET),
            this.raw(StorageMigrationService.T_REGION),
            StorageMigrationService.boolOf(this.raw(StorageMigrationService.T_STYLE)),
            this.raw(StorageMigrationService.S_PROVIDER),
            this.num(StorageMigrationService.CURSOR),
            this.num(StorageMigrationService.MIGRATED),
            this.num(StorageMigrationService.FAILED),
            this.num(StorageMigrationService.TOTAL),
            pending,
            this.dualWrite.failureCount(),
            !configured.isEmpty() && configured != runtime)
    }

    /**
     * 准备迁移：保存目标配置与源配置快照，开启双写。
     * 此时**不改动现网生效配置**，重启仍是源平台。
     */
    public func prepare(
        provider: String,
        endpoint: String,
        bucket: String,
        region: String,
        accessKey: String,
        secretKey: String,
        pathStyle: Bool
    ): MigrationStatus {
        let active = this.raw(StorageMigrationService.PHASE)
        if (!active.isEmpty() && active != "done" && active != "rolledback") {
            throw AppError(AppErrorKind.Conflict, "已有迁移任务在进行中（${active}），请先完成或取消")
        }
        // 失败关闭：先校验目标配置，任何不合法都不写任何状态
        match (StorageProviders.find(provider)) {
            case Some(_) => ()
            case None => throw validationError("provider", "未知存储平台：${provider}")
        }
        if (!StorageProviders.isLocalCode(provider)) {
            if (endpoint.isEmpty() || bucket.isEmpty() || accessKey.isEmpty() || secretKey.isEmpty()) {
                throw validationError("provider", "对象存储平台需要 endpoint / bucket / AK / SK")
            }
            let cfg = S3StorageConfig(
                endpoint, bucket, region, accessKey, secretKey, pathStyle, "attachments",
                provider: provider)
            cfg.validate()
        }
        let m = HashMap<String, String>()
        m[StorageMigrationService.T_PROVIDER] = provider
        m[StorageMigrationService.T_ENDPOINT] = endpoint
        m[StorageMigrationService.T_BUCKET] = bucket
        m[StorageMigrationService.T_REGION] = region
        m[StorageMigrationService.T_STYLE] = StorageMigrationService.strOf(pathStyle)
        m[StorageMigrationService.T_AK] = accessKey
        m[StorageMigrationService.T_SK] = secretKey
        m[StorageDualWrite.RETRY_KEY] = "" // 新任务从空补偿清单开始
        this.deployStore.setAll(m)
        let target = this.targetBackend()

        let marker = "mg_${Ids.next()}"
        let sourceStyleRaw = this.deployStore.resolve(
            StorageMigrationService.R_STYLE, "AMS_S3_PATH_STYLE", "")
        let source = HashMap<String, String>()
        source[StorageMigrationService.PHASE] = "full"
        source[StorageMigrationService.MARKER] = marker
        source[StorageMigrationService.S_PROVIDER] = StorageProviders.currentCode()
        source[StorageMigrationService.S_ENDPOINT] = this.deployStore.resolve(
            StorageMigrationService.R_ENDPOINT, "AMS_S3_ENDPOINT", "")
        source[StorageMigrationService.S_BUCKET] = this.deployStore.resolve(
            StorageMigrationService.R_BUCKET, "AMS_S3_BUCKET", "")
        source[StorageMigrationService.S_REGION] = this.deployStore.resolve(
            StorageMigrationService.R_REGION, "AMS_S3_REGION", "")
        source[StorageMigrationService.S_STYLE] = StorageMigrationService.strOf(
            StorageMigrationService.boolOf(sourceStyleRaw))
        // 源凭据快照：回滚时若原来写在 deployment.env 里，必须原样写回，
        // 否则清空文件行后会丢失源平台访问凭据（环境变量注入的场景留空即可）。
        source[StorageMigrationService.S_AK] = this.deployStore.resolve(
            StorageMigrationService.R_AK, "AMS_S3_ACCESS_KEY", "")
        source[StorageMigrationService.S_SK] = this.deployStore.resolve(
            StorageMigrationService.R_SK, "AMS_S3_SECRET_KEY", "")
        source[StorageMigrationService.CURSOR] = "0"
        source[StorageMigrationService.MIGRATED] = "0"
        source[StorageMigrationService.FAILED] = "0"
        source[StorageMigrationService.TOTAL] = "${this.repo.countAll()}"
        this.deployStore.setAll(source)
        this.dualWrite.setTarget(target)
        return this.status()
    }

    private func copyObject(
        src: StorageBackend, dst: StorageBackend, key: String, required!: Bool = false
    ): Unit {
        match (src.get(key)) {
            case Some(data) => dst.put(key, data)
            case None =>
                if (required) {
                    throw AppError(AppErrorKind.Internal, "迁移源对象不存在：${key}")
                }
        }
    }

    /**
     * 补偿增量期双写失败的键（含新版本 / 派生对象）。
     * 清单由 StorageDualWrite 持久化到 deployment.env，进程重启后仍在。
     */
    private func drainRetries(src: StorageBackend, dst: StorageBackend): Unit {
        let rawKeys = this.raw(StorageDualWrite.RETRY_KEY)
        if (rawKeys.isEmpty()) {
            return
        }
        var remaining = ArrayList<String>()
        for (k in rawKeys.split(",")) {
            if (k.isEmpty()) { continue }
            try {
                this.copyObject(src, dst, k, required: true)
            } catch (e: Exception) {
                remaining.add(k)
            }
        }
        var joined = ""
        for (k in remaining) {
            if (!joined.isEmpty()) { joined = joined + "," }
            joined = joined + k
        }
        this.set(StorageDualWrite.RETRY_KEY, joined)
    }

    /**
     * 执行一批搬迁。前端循环调用直到 phase 变为 catchup / ready。
     * 每批都在 deployment.env 落游标，进程重启后可续跑（断点续传）。
     */
    public func run(batch: Int64): MigrationStatus {
        let phase = this.raw(StorageMigrationService.PHASE)
        if (phase != "full" && phase != "catchup") {
            throw AppError(AppErrorKind.Conflict, "当前阶段（${phase}）不可执行搬迁")
        }
        let marker = this.raw(StorageMigrationService.MARKER)
        if (marker.isEmpty()) {
            throw AppError(AppErrorKind.Conflict, "迁移标记丢失，请取消后重新准备")
        }
        var limit = batch
        if (limit < 1) { limit = 1 }
        if (limit > 500) { limit = 500 }
        let targetProvider = this.raw(StorageMigrationService.T_PROVIDER)
        let target = this.targetBackend()
        let code = StorageMigrationService.backendCode(targetProvider)
        // 每批先补偿双写失败键，避免切换后新对象缺失
        this.drainRetries(this.sourceBackend, target)
        var cursor = this.num(StorageMigrationService.CURSOR)
        let rows = this.repo.listMigrationCandidates(marker, cursor, limit)
        if (rows.isEmpty()) {
            if (phase == "full") {
                this.set(StorageMigrationService.PHASE, "catchup")
                this.set(StorageMigrationService.CURSOR, "0")
            } else {
                this.set(StorageMigrationService.PHASE, "ready")
            }
            return this.status()
        }
        var migrated = this.num(StorageMigrationService.MIGRATED)
        var failed = this.num(StorageMigrationService.FAILED)
        for (r in rows.all()) {
            let id = r.i64("id")
            let key = r.str("storage_key")
            let attStatus = r.i64("status")
            if (attStatus == 3) {
                // 隔离件恒定在 QuarantineStorage（本地 FS），不随主后端切换；
                // 源后端没有该对象，直接标记完成，避免 required:true 永久失败。
                this.repo.markMigrated(id, code, marker)
                migrated = migrated + 1
                cursor = id
                continue
            }
            try {
                this.copyObject(this.sourceBackend, target, key, required: true)
                // 历史版本 + 派生对象（thumb_/wm_ 未登记 DB，按约定键名补齐）
                for (v in this.repo.listVersionKeys(id).all()) {
                    this.copyObject(this.sourceBackend, target, v.str("storage_key"))
                }
                this.copyObject(this.sourceBackend, target, "thumb_${id}.png")
                this.copyObject(this.sourceBackend, target, "wm_${id}.png")
                this.repo.markMigrated(id, code, marker)
                migrated = migrated + 1
                // 失败行不推进游标：下一批从头重试，避免跳过造成静默缺失
                cursor = id
            } catch (e: Exception) {
                failed = failed + 1
            }
        }
        this.set(StorageMigrationService.CURSOR, "${cursor}")
        this.set(StorageMigrationService.MIGRATED, "${migrated}")
        this.set(StorageMigrationService.FAILED, "${failed}")
        return this.status()
    }

    /** 取消（仅切换前）：清状态、关双写、恢复平台标记。 */
    public func cancel(): MigrationStatus {
        let phase = this.raw(StorageMigrationService.PHASE)
        if (phase == "done") {
            throw AppError(AppErrorKind.Conflict, "已切换完成，请使用回滚接口")
        }
        let marker = this.raw(StorageMigrationService.MARKER)
        if (!marker.isEmpty()) {
            this.repo.resetMigrationMarkers(
                marker, this.raw(StorageMigrationService.S_PROVIDER))
        }
        this.clearAll()
        return this.status()
    }

    /**
     * 切换生效：仅在 ready 且无剩余行时允许。
     * 写回现网配置后需重启进程；重启前双写已关闭，源后端仍可正常服务。
     */
    public func cutover(): MigrationStatus {
        let phase = this.raw(StorageMigrationService.PHASE)
        if (phase != "ready") {
            throw AppError(AppErrorKind.Conflict, "只有增量追赶完成（ready）后才能切换")
        }
        let marker = this.raw(StorageMigrationService.MARKER)
        if (this.repo.pendingMigrationCount(marker) > 0) {
            throw AppError(AppErrorKind.Conflict, "仍有未迁移附件，请继续执行增量搬迁")
        }
        // 双写失败补偿清单必须清空，否则切换后新对象只存在于目标端
        if (!this.raw(StorageDualWrite.RETRY_KEY).isEmpty()) {
            throw AppError(AppErrorKind.Conflict,
                "仍有双写失败对象未补偿，请再次执行搬迁直至补偿清单为空")
        }
        let provider = this.raw(StorageMigrationService.T_PROVIDER)
        let m = HashMap<String, String>()
        m[StorageMigrationService.R_PROVIDER] = provider
        m[StorageMigrationService.R_ENDPOINT] = this.raw(StorageMigrationService.T_ENDPOINT)
        m[StorageMigrationService.R_BUCKET] = this.raw(StorageMigrationService.T_BUCKET)
        m[StorageMigrationService.R_REGION] = this.raw(StorageMigrationService.T_REGION)
        m[StorageMigrationService.R_AK] = this.raw(StorageMigrationService.T_AK)
        m[StorageMigrationService.R_SK] = this.raw(StorageMigrationService.T_SK)
        m[StorageMigrationService.R_STYLE] = this.raw(StorageMigrationService.T_STYLE)
        this.deployStore.setAll(m)
        this.repo.finalizeProviders(
            provider, StorageMigrationService.backendCode(provider))

        // 保留源快照供回滚，清掉目标凭据与游标
        let keep = HashMap<String, String>()
        keep[StorageMigrationService.PHASE] = "done"
        keep[StorageMigrationService.MARKER] = ""
        keep[StorageMigrationService.T_PROVIDER] = ""
        keep[StorageMigrationService.T_ENDPOINT] = ""
        keep[StorageMigrationService.T_BUCKET] = ""
        keep[StorageMigrationService.T_REGION] = ""
        keep[StorageMigrationService.T_STYLE] = ""
        keep[StorageMigrationService.T_AK] = ""
        keep[StorageMigrationService.T_SK] = ""
        keep[StorageMigrationService.CURSOR] = ""
        keep[StorageMigrationService.MIGRATED] = ""
        keep[StorageMigrationService.FAILED] = ""
        keep[StorageMigrationService.TOTAL] = ""
        this.deployStore.setAll(keep)
        // 重启前仍以源后端为主：把新对象反向镜像回源端，使「重启前回滚」不丢数据
        this.dualWrite.setTarget(this.sourceBackend)
        return this.status()
    }

    /**
     * 回滚：仅在切换尚未重启生效时允许（重启前新写入会反向镜像回源端）。
     * 已生效后拒绝自动回滚 —— 此时新对象只在目标端，强行切回会静默丢失。
     */
    public func rollback(): MigrationStatus {
        let phase = this.raw(StorageMigrationService.PHASE)
        if (phase.isEmpty() || phase == "none") {
            throw AppError(AppErrorKind.Conflict, "没有可回滚的迁移任务")
        }
        if (phase == "done") {
            if (!this.status().requiresRestart) {
                throw AppError(AppErrorKind.Conflict,
                    "目标平台已重启生效，自动回滚会丢失切换后新增附件；请执行反向迁移后再切换")
            }
            let source = this.raw(StorageMigrationService.S_PROVIDER)
            if (source.isEmpty()) {
                throw AppError(AppErrorKind.Conflict, "源配置快照丢失，无法自动回滚")
            }
            let m = HashMap<String, String>()
            m[StorageMigrationService.R_PROVIDER] = source
            m[StorageMigrationService.R_ENDPOINT] = this.raw(StorageMigrationService.S_ENDPOINT)
            m[StorageMigrationService.R_BUCKET] = this.raw(StorageMigrationService.S_BUCKET)
            m[StorageMigrationService.R_REGION] = this.raw(StorageMigrationService.S_REGION)
            m[StorageMigrationService.R_AK] = this.raw(StorageMigrationService.S_AK)
            m[StorageMigrationService.R_SK] = this.raw(StorageMigrationService.S_SK)
            m[StorageMigrationService.R_STYLE] = this.raw(StorageMigrationService.S_STYLE)
            this.deployStore.setAll(m)
            this.repo.finalizeProviders(
                source, StorageMigrationService.backendCode(source))
        } else {
            let marker = this.raw(StorageMigrationService.MARKER)
            if (!marker.isEmpty()) {
                this.repo.resetMigrationMarkers(
                    marker, this.raw(StorageMigrationService.S_PROVIDER))
            }
        }
        this.clearAll()
        return this.status()
    }
}

// ============================================================
// ams.app.attachment · 迁移期双写开关
//
// 全量搬迁期间新写入的附件仍会落到源后端；进入增量（catchup）阶段后，
// AttachmentService 通过本对象把同一份**密文字节**同步写一份到目标后端，
// 使「全量 + 增量」收敛到零差异，再执行切换。
//
// 目标后端为 None 时完全零开销 —— 未开启迁移的部署行为不变。
// 双写失败只记录计数、不阻断主链路：下一批 catchup 会按 DB 标记补偿。
// ============================================================
package ams.app.attachment

import std.collection.*

import ams.storage.*

public class StorageDualWrite {
    /** 双写失败键的持久化清单（deployment.env），供迁移服务每批补偿 */
    public static let RETRY_KEY: String = "MIGRATION_RETRY_KEYS"

    private var target: ?StorageBackend = None
    private var failures: Int64 = 0
    private let deployStore: ?DeploymentStore

    public init(deployStore!: ?DeploymentStore = None) {
        this.deployStore = deployStore
    }

    /** 开启 / 关闭目标写入（迁移取消或切换完成后置回 None）。 */
    public func setTarget(backend: ?StorageBackend): Unit {
        this.target = backend
        if (backend.isNone()) {
            this.failures = 0
        }
    }

    public func isActive(): Bool {
        return this.target.isSome()
    }

    public func failureCount(): Int64 {
        return this.failures
    }

    /**
     * 主后端写入由调用方先完成；本方法只负责镜像到目标。
     * 目标写入失败不抛错（主链路已经成功落库），仅累加失败数供前端展示。
     */
    public func mirror(key: String, data: Array<Byte>): Unit {
        match (this.target) {
            case Some(b) =>
                try {
                    b.put(key, data)
                } catch (e: Exception) {
                    this.failures = this.failures + 1
                    // 持久化失败键：进程重启后仍能补偿，避免切换后静默丢对象
                    match (this.deployStore) {
                        case Some(ds) =>
                            let old = ds.get(StorageDualWrite.RETRY_KEY) ?? ""
                            var keys = ArrayList<String>()
                            if (!old.isEmpty()) {
                                for (k in old.split(",")) {
                                    if (!k.isEmpty() && k != key) { keys.add(k) }
                                }
                            }
                            keys.add(key)
                            var joined = ""
                            for (k in keys) {
                                if (!joined.isEmpty()) { joined = joined + "," }
                                joined = joined + k
                            }
                            let m = HashMap<String, String>()
                            m[StorageDualWrite.RETRY_KEY] = joined
                            ds.setAll(m)
                        case None => ()
                    }
                }
            case None => ()
        }
    }
}

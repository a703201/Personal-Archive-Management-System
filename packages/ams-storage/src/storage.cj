// ============================================================
// ams-storage · 存储抽象层
//
// 职责：StorageBackend 接口 + 本地 FS 实现 + 隔离区
//
// 分层约束（架构 §4.2）：
//   - 本包只能依赖架构图中位于其下层的包
//   - 领域层（ams-core）不得依赖 HTTP / DB / 存储
//   - 所有跨层错误统一转换为 ams-kernel 的 AppError
//
// [FR-ATT-001 / FR-ATT-003 落地说明]
//   此前本包只有包声明（11 行空壳），附件无处可存。现补齐：
//     - StorageBackend：后端抽象，便于将来换对象存储（S3/OBS）
//     - LocalFileStorage：本地文件系统实现（本项目当前部署形态）
//     - QuarantineStorage：隔离区，扫描未通过的附件落此处，禁止下载
//
// [接口为何只有 put / get]
//   std.fs 在本工具链下只稳定提供 `File.readFrom` / `File.writeTo` /
//   `Directory.create`；`File.exists` / `File.remove` 并非其成员。
//   这里不为了凑接口去猜 API：
//     · 是否存在 → 由 `get()` 返回 None 表达（读即判存在，无额外开销差异）
//     · 删除     → 附件的删除一律走 DB 软删（deleted_at），
//                  物理文件由运维按需清理，不暴露删除接口反而更安全
//   （若将来接入对象存储，put/get 正好也是对象存储的最小充分接口）
//
// [安全约束]
//   ① 存储键一律经 sanitize() 去除路径分隔符与盘符冒号 ——
//      即使上层拼接了恶意键（"../../etc/passwd"）也不会逃出根目录。
//   ② 根目录下**不做多级子目录**：一律扁平存放，
//      避免递归建目录的平台差异，也让键与文件一一对应便于审计。
//   ③ 异常统一转 AppError（Internal），不向调用方泄漏本地路径细节。
// ============================================================
package ams.storage

import std.fs.*
import ams.kernel.error.*

/**
 * 存储后端抽象（对象存储的最小充分接口）。
 */
public interface StorageBackend {
    /** 写入（覆盖）对象 */
    func put(key: String, data: Array<Byte>): Unit
    /** 读取对象；不存在返回 None */
    func get(key: String): Option<Array<Byte>>
}

/**
 * 本地文件系统存储。
 */
public class LocalFileStorage <: StorageBackend {
    /** 根目录（构造时确保存在） */
    private let root: String

    public init(root: String) {
        this.root = root
        LocalFileStorage.ensureDir(root)
    }

    public func put(key: String, data: Array<Byte>): Unit {
        try {
            File.writeTo(this.pathOf(key), data)
        } catch (e: Exception) {
            throw AppError(AppErrorKind.Internal, "写入存储对象失败")
        }
    }

    /**
     * 读取对象。
     *
     * 不先判存在再读（避免 File.exists 不可用的问题，也避免 TOCTOU）：
     * 直接读，读不到即视为不存在，返回 None。
     */
    public func get(key: String): Option<Array<Byte>> {
        try {
            return Some(File.readFrom(this.pathOf(key)))
        } catch (e: Exception) {
            return None
        }
    }

    /**
     * 键 → 本地路径（先消毒，防目录穿越）。
     */
    private func pathOf(key: String): String {
        return "${this.root}/${LocalFileStorage.sanitize(key)}"
    }

    /**
     * 去除路径分隔符与盘符冒号，把键压成单层文件名。
     */
    private static func sanitize(key: String): String {
        return key.replace("/", "_").replace("\\", "_").replace(":", "_")
    }

    /**
     * 确保目录存在。
     *
     * 目录已存在时 Directory.create 会抛异常 —— 这里吞掉即可，
     * 因为「已存在」正是我们想要的结果（幂等）。
     */
    private static func ensureDir(path: String): Unit {
        try {
            Directory.create(path)
        } catch (e: Exception) {
            // 已存在或无权创建：均不在此中断启动
        }
    }
}

/**
 * 隔离区存储。
 *
 * 扫描未通过的附件放这里，与正常区**物理分离**：
 * 正常区的下载路径按原键根本读不到隔离区对象（键带前缀），
 * 即使将来出现逻辑漏洞，也多一层物理兜底（FR-ATT-007）。
 */
public class QuarantineStorage <: StorageBackend {
    private let inner: LocalFileStorage

    public init(root: String) {
        this.inner = LocalFileStorage(root)
    }

    public func put(key: String, data: Array<Byte>): Unit {
        this.inner.put(QuarantineStorage.keyOf(key), data)
    }

    public func get(key: String): Option<Array<Byte>> {
        return this.inner.get(QuarantineStorage.keyOf(key))
    }

    /** 隔离区键前缀，避免与正常区键冲突 */
    private static func keyOf(key: String): String {
        return "quarantine_${key}"
    }
}

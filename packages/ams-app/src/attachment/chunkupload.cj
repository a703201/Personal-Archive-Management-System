// ============================================================
// ams.app.attachment · 分片上传 / 断点续传（FR-ATT-001 补齐）
//
// 【为什么单独一层】
//   现有 `AttachmentService.upload()` 接收**完整明文** Array<Byte>，
//   一次请求传完（单次 raw body，50MB 上限）。分片上传不该复制它的
//   指纹 / 去重 / DEK / 加密 / 落库逻辑 —— 那正是最容易漂移的部分。
//   本层只负责「收齐分片 → 按序拼回完整明文」，再由路由层把拼好的
//   明文原样交给 `AttachmentService.upload()`，因此加密、去重、权限、
//   审计、媒体处理全部零回归。
//
// 【协议】
//   POST   /api/attachments/uploads                 创建会话（元数据 JSON）
//   PUT    /api/attachments/uploads/:id/chunks/:index   上传一片（raw bytes）
//   GET    /api/attachments/uploads/:id            查询已收分片（续传）
//   POST   /api/attachments/uploads/:id/complete  合并并落成正式附件
//   DELETE /api/attachments/uploads/:id           取消并释放
//
// 【安全约束】
//   ① 会话绑定 ownerId，任何读写都校验 operatorId —— 防越权续传 / 合并。
//   ② 上传 ID 用 Ids.next() + 毫秒时间戳拼接；即便被猜到，无 owner 匹配
//      也拿不到数据（与内存态验证码 challenge 同一安全模型）。
//   ③ 非末片必须恰好 CHUNK_SIZE 字节：否则乱序 / 缺片会拼出错位明文，
//      宁可显式拒绝也不产出损坏文件。
//   ④ 合并前校验总字节数 == totalSize，且分片 0..totalChunks-1 齐全。
//   ⑤ 会话数与单片大小均设硬上限，防内存耗尽；过期会话惰性清理。
//
// 【P1-5 多副本支持】
//   启动时调用 RuntimeStateDb.configure(db) 后，会话与分片字节落
//   sys_upload_sessions / sys_upload_chunks，多副本可续传同一上传；
//   未配置时退回原内存实现，单测与本地开发零改动可用。
// ============================================================
package ams.app.attachment

import std.collection.*
import std.sync.*
import std.database.sql.*

import ams.data.db.*
import ams.data.repo.*
import ams.kernel.error.*
import ams.security.authn.*

/** 完成合并后的产物：路由层据此调用 AttachmentService.upload()。 */
public class ChunkUploadComplete {
    public let subjectId: Int64
    public let itemId: Option<Int64>
    public let category: Int64
    public let title: String
    public let fileName: String
    public let summary: String
    public let keywords: String
    public let plain: Array<Byte>

    public init(
        subjectId: Int64, itemId: Option<Int64>, category: Int64,
        title: String, fileName: String, summary: String, keywords: String,
        plain: Array<Byte>
    ) {
        this.subjectId = subjectId
        this.itemId = itemId
        this.category = category
        this.title = title
        this.fileName = fileName
        this.summary = summary
        this.keywords = keywords
        this.plain = plain
    }
}

/** 一次上传会话。 */
public class ChunkUploadSession {
    public let id: String
    public let ownerId: Int64
    public let subjectId: Int64
    public let itemId: Option<Int64>
    public let category: Int64
    public let title: String
    public let fileName: String
    public let summary: String
    public let keywords: String
    public let totalSize: Int64
    public let chunkSize: Int64
    public let totalChunks: Int64
    public let createdAt: Int64
    public let chunks: HashMap<Int64, Array<Byte>>

    public init(
        id: String, ownerId: Int64, subjectId: Int64, itemId: Option<Int64>,
        category: Int64, title: String, fileName: String,
        summary: String, keywords: String, totalSize: Int64,
        chunkSize: Int64, totalChunks: Int64, createdAt: Int64
    ) {
        this.id = id
        this.ownerId = ownerId
        this.subjectId = subjectId
        this.itemId = itemId
        this.category = category
        this.title = title
        this.fileName = fileName
        this.summary = summary
        this.keywords = keywords
        this.totalSize = totalSize
        this.chunkSize = chunkSize
        this.totalChunks = totalChunks
        this.createdAt = createdAt
        this.chunks = HashMap<Int64, Array<Byte>>()
    }
}

/**
 * complete() 在锁内取出的快照。
 *
 * 合并（最多 50 MB 逐字节拷贝）放在锁外执行：持锁期间只做「校验 +
 * 收集分片引用 + 摘除会话」，避免一次大文件合并阻塞所有其它上传请求。
 * 会话摘除后分片数据不再被其它线程改动，锁外只读是安全的。
 */
public class ChunkUploadSnapshot {
    public let subjectId: Int64
    public let itemId: Option<Int64>
    public let category: Int64
    public let title: String
    public let fileName: String
    public let summary: String
    public let keywords: String
    public let totalSize: Int64
    public let parts: Array<Array<Byte>>

    public init(s: ChunkUploadSession, parts: Array<Array<Byte>>) {
        this.subjectId = s.subjectId
        this.itemId = s.itemId
        this.category = s.category
        this.title = s.title
        this.fileName = s.fileName
        this.summary = s.summary
        this.keywords = s.keywords
        this.totalSize = s.totalSize
        this.parts = parts
    }
}

/**
 * 分片上传会话存储 + 合并逻辑。全静态方法，由路由层直接调用，
 * 无需改动 main.cj 的装配（与 CaptchaStore 同一接入形态）。
 */
public class ChunkUploadStore {
    /** 单片大小：1 MiB */
    public static let CHUNK_SIZE: Int64 = 1048576
    /** 单文件上限：与 FileTypes.maxFileSize 对齐（50 MB） */
    public static let MAX_FILE_SIZE: Int64 = 50 * 1024 * 1024
    /** 最多分片数（含余量） */
    public static let MAX_CHUNKS: Int64 = 64
    /** 会话存活 24 小时 */
    public static let TTL_MS: Int64 = 24 * 60 * 60 * 1000
    /** 同时存活会话上限，防内存耗尽 */
    public static let MAX_SESSIONS: Int64 = 128
    /**
     * 全局分片缓存字节预算（256 MiB）。
     *
     * 只按会话数限流是不够的：128 个会话 × 每会话 50 MB = 6.4 GB。
     * 这里按「实际已收到并常驻内存的字节」设硬上限，超额即显式拒绝，
     * 绝不静默丢片或让进程被 OOM 杀掉。
     */
    public static let MAX_BUFFER_BYTES: Int64 = 256 * 1024 * 1024

    private static let sessions: HashMap<String, ChunkUploadSession> = HashMap<String, ChunkUploadSession>()
    private static let mutex: Mutex = Mutex()
    /** 已缓存分片字节总数（持锁维护；写入 / 释放 / 过期清理时同步增减）。 */
    private static var bufferedBytes: Int64 = 0
    /**
     * 会话序号（持锁自增）。
     *
     * 【为什么不复用 `Ids.next()`】那是全局雪花 ID，**故意 fail-fast**：
     * 未调用 `Ids.setup(workerId)` 时直接抛 "ID 生成器未初始化"。
     * 上传会话 ID 只需要「本进程内唯一」，不需要全局有序 / 跨机器唯一，
     * 引入全局初始化顺序依赖只会让纯内存单测与将来嵌入式复用无故失败。
     * 归属绑定（ownerId）才是这里的安全边界，ID 可预测不构成越权。
     */
    private static var seq: Int64 = 0

    /**
     * 创建会话。返回 uploadId。
     */
    public static func create(
        ownerId: Int64, subjectId: Int64, itemId: Option<Int64>,
        category: Int64, title: String, fileName: String,
        summary: String, keywords: String, totalSize: Int64, nowMillis: Int64
    ): String {
        if (ownerId <= 0) {
            throw validationError("ownerId", "无法确定上传者")
        }
        if (fileName.isEmpty()) {
            throw validationError("fileName", "缺少 fileName")
        }
        if (totalSize <= 0 || totalSize > ChunkUploadStore.MAX_FILE_SIZE) {
            throw validationError("totalSize", "文件大小必须在 1 字节到 50MB 之间")
        }
        let n = (totalSize + ChunkUploadStore.CHUNK_SIZE - 1) / ChunkUploadStore.CHUNK_SIZE
        if (n > ChunkUploadStore.MAX_CHUNKS) {
            throw validationError("totalSize", "分片数超过上限")
        }
        if (RuntimeStateDb.isConfigured()) {
            return ChunkUploadStore.dbCreate(
                ownerId, subjectId, itemId, category, title, fileName,
                summary, keywords, totalSize, n, nowMillis)
        }
        ChunkUploadStore.mutex.lock()
        try {
            ChunkUploadStore.sweep(nowMillis)
            if (ChunkUploadStore.sessions.size >= ChunkUploadStore.MAX_SESSIONS) {
                throw validationError("upload", "并发上传会话过多，请稍后重试")
            }
            ChunkUploadStore.seq = ChunkUploadStore.seq + 1
            let id = "UP${nowMillis}${ChunkUploadStore.seq}"
            let s = ChunkUploadSession(
                id, ownerId, subjectId, itemId, category, title, fileName,
                summary, keywords, totalSize, ChunkUploadStore.CHUNK_SIZE, n, nowMillis
            )
            ChunkUploadStore.sessions[id] = s
            return id
        } finally {
            ChunkUploadStore.mutex.unlock()
        }
    }

    /**
     * 写入一片。返回当前已收分片数。重复写同一 index 幂等覆盖（支持重传）。
     */
    public static func putChunk(
        operatorId: Int64, id: String, index: Int64, data: Array<Byte>, nowMillis: Int64
    ): Int64 {
        if (RuntimeStateDb.isConfigured()) {
            return ChunkUploadStore.dbPutChunk(operatorId, id, index, data, nowMillis)
        }
        ChunkUploadStore.mutex.lock()
        try {
            let s = ChunkUploadStore.sessionOf(operatorId, id, nowMillis)
            if (index < 0 || index >= s.totalChunks) {
                throw validationError("index", "分片序号越界")
            }
            if (data.size <= 0 || data.size > s.chunkSize) {
                throw validationError("chunk", "分片大小非法")
            }
            // 非末片必须恰好 CHUNK_SIZE；末片按 totalSize 反推的期望长度
            let expected = if (index == s.totalChunks - 1) {
                s.totalSize - s.chunkSize * (s.totalChunks - 1)
            } else {
                s.chunkSize
            }
            if (data.size != expected) {
                throw validationError("chunk", "分片长度与预期不符（请检查分片顺序与大小）")
            }
            // 重传同一 index 时用新片替换旧片，按增量核算预算，不重复计费。
            let oldSize = match (s.chunks.get(index)) {
                case Some(old) => old.size
                case None => 0
            }
            let delta = data.size - oldSize
            if (ChunkUploadStore.bufferedBytes + delta > ChunkUploadStore.MAX_BUFFER_BYTES) {
                throw validationError("upload", "服务端上传缓存已满，请稍后重试")
            }
            s.chunks[index] = data
            ChunkUploadStore.bufferedBytes = ChunkUploadStore.bufferedBytes + delta
            return s.chunks.size
        } finally {
            ChunkUploadStore.mutex.unlock()
        }
    }

    /**
     * 查询续传状态：返回 (totalChunks, 已收分片索引数组, totalSize, chunkSize)。
     * 索引数组升序，前端据此跳过已传分片。
     */
    public static func status(
        operatorId: Int64, id: String, nowMillis: Int64
    ): (Int64, Array<Int64>, Int64, Int64) {
        if (RuntimeStateDb.isConfigured()) {
            return ChunkUploadStore.dbStatus(operatorId, id, nowMillis)
        }
        ChunkUploadStore.mutex.lock()
        try {
            let s = ChunkUploadStore.sessionOf(operatorId, id, nowMillis)
            let arr = ArrayList<Int64>()
            for ((k, _) in s.chunks) {
                arr.add(k)
            }
            return (s.totalChunks, ChunkUploadStore.sortAsc(arr.toArray()), s.totalSize, s.chunkSize)
        } finally {
            ChunkUploadStore.mutex.unlock()
        }
    }

    /**
     * 锁内校验并摘除会话，返回分片快照；失败时会话保持原样可继续续传。
     */
    private static func takeSnapshot(
        operatorId: Int64, id: String, nowMillis: Int64
    ): ChunkUploadSnapshot {
        if (RuntimeStateDb.isConfigured()) {
            return ChunkUploadStore.takeSnapshotDb(operatorId, id, nowMillis)
        }
        ChunkUploadStore.mutex.lock()
        try {
            let s = ChunkUploadStore.sessionOf(operatorId, id, nowMillis)
            if (s.chunks.size != s.totalChunks) {
                throw validationError("upload", "分片未收齐（缺 ${s.totalChunks - s.chunks.size} 片）")
            }
            // 校验每一片都在，避免 HashMap.size 恰好相等但索引错位的极端情况
            let parts = ArrayList<Array<Byte>>()
            var held: Int64 = 0
            var i: Int64 = 0
            while (i < s.totalChunks) {
                match (s.chunks.get(i)) {
                    case Some(v) =>
                        parts.add(v)
                        held = held + v.size
                    case None => throw validationError("upload", "缺少第 ${i} 片")
                }
                i = i + 1
            }
            ChunkUploadStore.sessions.remove(id)
            ChunkUploadStore.bufferedBytes = ChunkUploadStore.bufferedBytes - held
            return ChunkUploadSnapshot(s, parts.toArray())
        } finally {
            ChunkUploadStore.mutex.unlock()
        }
    }

    /**
     * 合并并移除会话。返回可直接交给 AttachmentService.upload() 的明文与元数据。
     *
     * 【锁粒度】持锁只做 takeSnapshot（校验 + 摘除），逐字节合并在锁外完成，
     * 一次 50 MB 合并不再阻塞其它会话的 create / putChunk / status。
     */
    public static func complete(operatorId: Int64, id: String, nowMillis: Int64): ChunkUploadComplete {
        let snap = ChunkUploadStore.takeSnapshot(operatorId, id, nowMillis)
        let merged = Array<Byte>(snap.totalSize, repeat: 0u8)
        var at: Int64 = 0
        var i: Int64 = 0
        while (i < snap.parts.size) {
            let part = snap.parts[i]
            var j: Int64 = 0
            while (j < part.size) {
                merged[at + j] = part[j]
                j = j + 1
            }
            at = at + part.size
            i = i + 1
        }
        if (at != snap.totalSize) {
            throw validationError("upload", "合并后大小与声明不一致")
        }
        return ChunkUploadComplete(
            snap.subjectId, snap.itemId, snap.category, snap.title, snap.fileName,
            snap.summary, snap.keywords, merged
        )
    }

    /** 取消会话并释放内存。 */
    public static func cancel(operatorId: Int64, id: String, nowMillis: Int64): Bool {
        if (RuntimeStateDb.isConfigured()) {
            return ChunkUploadStore.dbCancel(operatorId, id)
        }
        ChunkUploadStore.mutex.lock()
        try {
            match (ChunkUploadStore.sessions.get(id)) {
                case Some(s) =>
                    if (s.ownerId != operatorId) {
                        throw notFound("上传会话")
                    }
                    ChunkUploadStore.bufferedBytes = ChunkUploadStore.bufferedBytes -
                        ChunkUploadStore.heldBytes(s)
                    ChunkUploadStore.sessions.remove(id)
                    return true
                case None => return false
            }
        } finally {
            ChunkUploadStore.mutex.unlock()
        }
    }

    /** 当前存活会话数（供单测 / 运维观测）。 */
    public static func size(): Int64 {
        if (RuntimeStateDb.isConfigured()) {
            let c = RuntimeStateDb.get().connect()
            try {
                let st = c.prepareStatement("SELECT COUNT(*) AS n FROM sys_upload_sessions")
                let rows = readRows(st.query())
                return if (rows.isEmpty()) { 0 } else { rows.at(0).i64("n") }
            } catch (e: Exception) {
                throw toDbError(e)
            } finally {
                c.close()
            }
        }
        ChunkUploadStore.mutex.lock()
        try {
            return ChunkUploadStore.sessions.size
        } finally {
            ChunkUploadStore.mutex.unlock()
        }
    }

    /** 当前缓存分片总字节数（供单测 / 运维观测预算水位）。 */
    public static func buffered(): Int64 {
        if (RuntimeStateDb.isConfigured()) {
            let c = RuntimeStateDb.get().connect()
            try {
                let st = c.prepareStatement(
                    "SELECT COALESCE(SUM(LENGTH(data)), 0) AS n FROM sys_upload_chunks"
                )
                let rows = readRows(st.query())
                return if (rows.isEmpty()) { 0 } else { rows.at(0).i64("n") }
            } catch (e: Exception) {
                throw toDbError(e)
            } finally {
                c.close()
            }
        }
        ChunkUploadStore.mutex.lock()
        try {
            return ChunkUploadStore.bufferedBytes
        } finally {
            ChunkUploadStore.mutex.unlock()
        }
    }

    // ---------------------------------------------------------
    // 内部工具（调用方必须已持有 mutex）
    // ---------------------------------------------------------

    /** 统计一个会话当前缓存的字节数（调用方须持锁）。 */
    private static func heldBytes(s: ChunkUploadSession): Int64 {
        var total: Int64 = 0
        for ((idx, part) in s.chunks) {
            total = total + part.size
        }
        return total
    }

    /** 取会话并校验归属与过期；不命中一律按 notFound（不泄漏会话是否存在）。 */
    private static func sessionOf(operatorId: Int64, id: String, nowMillis: Int64): ChunkUploadSession {
        match (ChunkUploadStore.sessions.get(id)) {
            case Some(s) =>
                if (s.ownerId != operatorId) {
                    throw notFound("上传会话")
                }
                if (nowMillis - s.createdAt > ChunkUploadStore.TTL_MS) {
                    ChunkUploadStore.bufferedBytes = ChunkUploadStore.bufferedBytes -
                        ChunkUploadStore.heldBytes(s)
                    ChunkUploadStore.sessions.remove(id)
                    throw notFound("上传会话")
                }
                return s
            case None => throw notFound("上传会话")
        }
    }

    /** 惰性清理过期会话（同步回收缓存计数，避免预算被僵尸会话永久占用）。 */
    private static func sweep(nowMillis: Int64): Unit {
        let dead = ArrayList<String>()
        var freed: Int64 = 0
        for ((k, s) in ChunkUploadStore.sessions) {
            if (nowMillis - s.createdAt > ChunkUploadStore.TTL_MS) {
                dead.add(k)
                freed = freed + ChunkUploadStore.heldBytes(s)
            }
        }
        for (k in dead) {
            ChunkUploadStore.sessions.remove(k)
        }
        ChunkUploadStore.bufferedBytes = ChunkUploadStore.bufferedBytes - freed
    }

    // ---------------------------------------------------------
    // DB 路径（多副本共享，落 sys_upload_sessions / sys_upload_chunks）
    // ---------------------------------------------------------

    private static func dbCreate(
        ownerId: Int64, subjectId: Int64, itemId: Option<Int64>, category: Int64,
        title: String, fileName: String, summary: String, keywords: String,
        totalSize: Int64, totalChunks: Int64, nowMillis: Int64
    ): String {
        let c = RuntimeStateDb.get().connect()
        try {
            ChunkUploadStore.sweepDb(c, nowMillis)
            let cnt = c.prepareStatement("SELECT COUNT(*) AS n FROM sys_upload_sessions")
            if (readRows(cnt.query()).at(0).i64("n") >= ChunkUploadStore.MAX_SESSIONS) {
                throw validationError("upload", "并发上传会话过多，请稍后重试")
            }
            // 随机后缀保证跨实例唯一（不依赖各进程各自从 0 开始的 seq）。
            let id = "UP${nowMillis}${RuntimeStateDb.newToken()}"
            ChunkUploadStore.insertSessionDb(
                c, id, ownerId, subjectId, itemId, category, title, fileName,
                summary, keywords, totalSize, totalChunks, nowMillis)
            return id
        } catch (e: Exception) {
            if (e is AppError) {
                throw e
            }
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    private static func insertSessionDb(
        c: Connection, id: String, ownerId: Int64, subjectId: Int64, itemId: Option<Int64>,
        category: Int64, title: String, fileName: String, summary: String, keywords: String,
        totalSize: Int64, totalChunks: Int64, nowMillis: Int64
    ): Unit {
        match (itemId) {
            case Some(v) =>
                let st = c.prepareStatement(
                    "INSERT INTO sys_upload_sessions " +
                    "(upload_id, owner_id, subject_id, item_id, category, title, file_name, " +
                    "summary, keywords, total_size, chunk_size, total_chunks, created_at) " +
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                )
                st.set(0, id)
                st.set(1, ownerId)
                st.set(2, subjectId)
                st.set(3, v)
                st.set(4, category)
                st.set(5, title)
                st.set(6, fileName)
                st.set(7, summary)
                st.set(8, keywords)
                st.set(9, totalSize)
                st.set(10, ChunkUploadStore.CHUNK_SIZE)
                st.set(11, totalChunks)
                st.set(12, nowMillis)
                st.update()
            case None =>
                let st = c.prepareStatement(
                    "INSERT INTO sys_upload_sessions " +
                    "(upload_id, owner_id, subject_id, item_id, category, title, file_name, " +
                    "summary, keywords, total_size, chunk_size, total_chunks, created_at) " +
                    "VALUES (?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                )
                st.set(0, id)
                st.set(1, ownerId)
                st.set(2, subjectId)
                st.set(3, category)
                st.set(4, title)
                st.set(5, fileName)
                st.set(6, summary)
                st.set(7, keywords)
                st.set(8, totalSize)
                st.set(9, ChunkUploadStore.CHUNK_SIZE)
                st.set(10, totalChunks)
                st.set(11, nowMillis)
                st.update()
        }
    }

    /** 取会话并校验归属与过期；不命中一律按 notFound（不泄漏会话是否存在）。 */
    private static func loadSessionDb(
        c: Connection, operatorId: Int64, id: String, nowMillis: Int64
    ): ChunkUploadSession {
        let st = c.prepareStatement(
            "SELECT upload_id, owner_id, subject_id, item_id, category, title, file_name, " +
            "summary, keywords, total_size, chunk_size, total_chunks, created_at " +
            "FROM sys_upload_sessions WHERE upload_id = ?"
        )
        st.set(0, id)
        let rows = readRows(st.query())
        if (rows.isEmpty()) {
            throw notFound("上传会话")
        }
        let r = rows.at(0)
        let owner = r.i64("owner_id")
        if (owner != operatorId) {
            throw notFound("上传会话")
        }
        if (nowMillis - r.i64("created_at") > ChunkUploadStore.TTL_MS) {
            ChunkUploadStore.deleteSessionCascade(c, id)
            throw notFound("上传会话")
        }
        var itemIdOpt: Option<Int64> = None
        match (r.getOpt("item_id")) {
            case Some(v) => itemIdOpt = Some(RowData.toI64(v))
            case None => ()
        }
        return ChunkUploadSession(
            r.str("upload_id"), owner, r.i64("subject_id"), itemIdOpt,
            r.i64("category"), r.str("title"), r.str("file_name"),
            r.str("summary"), r.str("keywords"), r.i64("total_size"),
            r.i64("chunk_size"), r.i64("total_chunks"), r.i64("created_at")
        )
    }

    /** 级联删除会话及其分片（调用方负责事务）。 */
    private static func deleteSessionCascade(c: Connection, id: String): Unit {
        let d1 = c.prepareStatement("DELETE FROM sys_upload_chunks WHERE upload_id = ?")
        d1.set(0, id)
        d1.update()
        let d2 = c.prepareStatement("DELETE FROM sys_upload_sessions WHERE upload_id = ?")
        d2.set(0, id)
        d2.update()
    }

    /** 惰性清理过期会话（连同分片），避免预算被僵尸会话永久占用。 */
    private static func sweepDb(c: Connection, nowMillis: Int64): Unit {
        let cutoff = nowMillis - ChunkUploadStore.TTL_MS
        let d1 = c.prepareStatement(
            "DELETE FROM sys_upload_chunks WHERE upload_id IN " +
            "(SELECT upload_id FROM sys_upload_sessions WHERE created_at < ?)"
        )
        d1.set(0, cutoff)
        d1.update()
        let d2 = c.prepareStatement("DELETE FROM sys_upload_sessions WHERE created_at < ?")
        d2.set(0, cutoff)
        d2.update()
    }

    private static func dbPutChunk(
        operatorId: Int64, id: String, index: Int64, data: Array<Byte>, nowMillis: Int64
    ): Int64 {
        return RuntimeStateDb.get().withTransaction { c: Connection =>
            let s = ChunkUploadStore.loadSessionDb(c, operatorId, id, nowMillis)
            if (index < 0 || index >= s.totalChunks) {
                throw validationError("index", "分片序号越界")
            }
            if (data.size <= 0 || data.size > s.chunkSize) {
                throw validationError("chunk", "分片大小非法")
            }
            let expected = if (index == s.totalChunks - 1) {
                s.totalSize - s.chunkSize * (s.totalChunks - 1)
            } else {
                s.chunkSize
            }
            if (data.size != expected) {
                throw validationError("chunk", "分片长度与预期不符（请检查分片顺序与大小）")
            }
            // 重传同一 index 幂等覆盖（先删后插，主键无冲突）。
            let d = c.prepareStatement(
                "DELETE FROM sys_upload_chunks WHERE upload_id = ? AND chunk_index = ?"
            )
            d.set(0, id)
            d.set(1, index)
            d.update()
            let ins = c.prepareStatement(
                "INSERT INTO sys_upload_chunks (upload_id, chunk_index, data) VALUES (?, ?, ?)"
            )
            ins.set(0, id)
            ins.set(1, index)
            ins.set<Array<Byte>>(2, data)
            ins.update()
            let q = c.prepareStatement(
                "SELECT COUNT(*) AS n FROM sys_upload_chunks WHERE upload_id = ?"
            )
            q.set(0, id)
            readRows(q.query()).at(0).i64("n")
        }
    }

    private static func dbStatus(
        operatorId: Int64, id: String, nowMillis: Int64
    ): (Int64, Array<Int64>, Int64, Int64) {
        let c = RuntimeStateDb.get().connect()
        try {
            let s = ChunkUploadStore.loadSessionDb(c, operatorId, id, nowMillis)
            let st = c.prepareStatement(
                "SELECT chunk_index FROM sys_upload_chunks WHERE upload_id = ? ORDER BY chunk_index"
            )
            st.set(0, id)
            let rows = readRows(st.query())
            let arr = ArrayList<Int64>()
            for (r in rows.all().iterator()) {
                arr.add(r.i64("chunk_index"))
            }
            return (s.totalChunks, ChunkUploadStore.sortAsc(arr.toArray()), s.totalSize, s.chunkSize)
        } catch (e: Exception) {
            if (e is AppError) {
                throw e
            }
            throw toDbError(e)
        } finally {
            c.close()
        }
    }

    private static func takeSnapshotDb(
        operatorId: Int64, id: String, nowMillis: Int64
    ): ChunkUploadSnapshot {
        // 读校验 + 摘除会话 + 删分片在同一事务内完成，多副本不会重复合并。
        return RuntimeStateDb.get().withTransaction { c: Connection =>
            let s = ChunkUploadStore.loadSessionDb(c, operatorId, id, nowMillis)
            let q = c.prepareStatement(
                "SELECT COUNT(*) AS n FROM sys_upload_chunks WHERE upload_id = ?"
            )
            q.set(0, id)
            let received = readRows(q.query()).at(0).i64("n")
            if (received != s.totalChunks) {
                throw validationError("upload", "分片未收齐（缺 ${s.totalChunks - received} 片）")
            }
            let st = c.prepareStatement(
                "SELECT chunk_index, data FROM sys_upload_chunks " +
                "WHERE upload_id = ? ORDER BY chunk_index"
            )
            st.set(0, id)
            let rs = st.query()
            let parts = ArrayList<Array<Byte>>()
            var held: Int64 = 0
            while (rs.next()) {
                // 按序读取：主键 (upload_id, chunk_index) + 行数已校验，故索引必连续齐全。
                let part = rs.get<Array<Byte>>(1)
                parts.add(part)
                held = held + part.size
            }
            if (held != s.totalSize) {
                throw validationError("upload", "合并后大小与声明不一致")
            }
            ChunkUploadStore.deleteSessionCascade(c, id)
            ChunkUploadSnapshot(s, parts.toArray())
        }
    }

    private static func dbCancel(operatorId: Int64, id: String): Bool {
        return RuntimeStateDb.get().withTransaction { c: Connection =>
            let st = c.prepareStatement("SELECT owner_id FROM sys_upload_sessions WHERE upload_id = ?")
            st.set(0, id)
            let rows = readRows(st.query())
            if (rows.isEmpty()) {
                return false
            }
            if (rows.at(0).i64("owner_id") != operatorId) {
                throw notFound("上传会话")
            }
            ChunkUploadStore.deleteSessionCascade(c, id)
            true
        }
    }

    /** 简单插入排序（分片数 <= 64，无需引入排序依赖）。 */
    private static func sortAsc(src: Array<Int64>): Array<Int64> {
        let a = ArrayList<Int64>()
        for (v in src) {
            a.add(v)
        }
        var i: Int64 = 1
        while (i < a.size) {
            let key = a[i]
            var j = i - 1
            while (j >= 0 && a[j] > key) {
                a[j + 1] = a[j]
                j = j - 1
            }
            a[j + 1] = key
            i = i + 1
        }
        return a.toArray()
    }
}

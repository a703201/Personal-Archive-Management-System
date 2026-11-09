// ============================================================
// ams.app.attachment · 分片上传 / 断点续传单元测试
//
// 覆盖 FR-ATT-001 补齐项：
//   会话创建 / 取消、乱序收片、续传状态、按序合并、缺片拒绝、
//   长度校验、归属隔离、过期清理、超上限拒绝、重传幂等。
//
// 纯内存驱动，不依赖数据库 / 网络 / 外部进程。
// 运行：bash scripts/test.sh ams-app
// ============================================================
package ams.app.attachment.test

import std.unittest.*

import ams.app.attachment.*

@Test
public class ChunkUploadTest {
    private static let OWNER: Int64 = 880001
    private static let OTHER: Int64 = 880002
    private static let NOW: Int64 = 1790000000000

    /** 构造固定长度的填充分片 */
    private static func filled(n: Int64, b: Byte): Array<Byte> {
        return Array<Byte>(n, repeat: b)
    }

    private static func newSession(total: Int64): String {
        return ChunkUploadStore.create(
            ChunkUploadTest.OWNER, 1001, None, 10, "测试附件", "a.png",
            "", "", total, ChunkUploadTest.NOW
        )
    }

    @TestCase
    public func testCreateAndCancel() {
        let before = ChunkUploadStore.size()
        let id = ChunkUploadTest.newSession(1024)
        @Assert(id.isEmpty(), false)
        @Assert(ChunkUploadStore.size(), before + 1)
        @Assert(ChunkUploadStore.cancel(ChunkUploadTest.OWNER, id, ChunkUploadTest.NOW), true)
        @Assert(ChunkUploadStore.size(), before)
    }

    @TestCase
    public func testOutOfOrderChunksAndResumeStatus() {
        // 3 片：第 1、2 片必须恰好 1 MiB，末片为余量
        let total = ChunkUploadStore.CHUNK_SIZE * 2 + 7
        let id = ChunkUploadTest.newSession(total)
        let full = ChunkUploadStore.CHUNK_SIZE
        // 故意乱序：先传末片、再传第 1 片
        let n1 = ChunkUploadStore.putChunk(
            ChunkUploadTest.OWNER, id, 2, ChunkUploadTest.filled(7, 0xCCu8), ChunkUploadTest.NOW)
        @Assert(n1, 1)
        let n2 = ChunkUploadStore.putChunk(
            ChunkUploadTest.OWNER, id, 0, ChunkUploadTest.filled(full, 0xAAu8), ChunkUploadTest.NOW)
        @Assert(n2, 2)
        let (totalChunks, received, totalSize, chunkSize) =
            ChunkUploadStore.status(ChunkUploadTest.OWNER, id, ChunkUploadTest.NOW)
        @Assert(totalChunks, 3)
        @Assert(totalSize, total)
        @Assert(chunkSize, ChunkUploadStore.CHUNK_SIZE)
        @Assert(received.size, 2)
        // 状态数组必须升序，前端据此跳过分片
        @Assert(received[0], 0)
        @Assert(received[1], 2)
        ChunkUploadStore.cancel(ChunkUploadTest.OWNER, id, ChunkUploadTest.NOW)
    }

    @TestCase
    public func testCompleteMergesInDeclaredOrder() {
        let total = ChunkUploadStore.CHUNK_SIZE + 5
        let id = ChunkUploadTest.newSession(total)
        ChunkUploadStore.putChunk(
            ChunkUploadTest.OWNER, id, 1, ChunkUploadTest.filled(5, 0xBBu8), ChunkUploadTest.NOW)
        ChunkUploadStore.putChunk(
            ChunkUploadTest.OWNER, id, 0,
            ChunkUploadTest.filled(ChunkUploadStore.CHUNK_SIZE, 0xAAu8), ChunkUploadTest.NOW)
        let c = ChunkUploadStore.complete(ChunkUploadTest.OWNER, id, ChunkUploadTest.NOW)
        @Assert(c.plain.size, total)
        @Assert(c.plain[0], 0xAAu8)
        @Assert(c.plain[ChunkUploadStore.CHUNK_SIZE - 1], 0xAAu8)
        @Assert(c.plain[ChunkUploadStore.CHUNK_SIZE], 0xBBu8)
        @Assert(c.plain[total - 1], 0xBBu8)
        @Assert(c.fileName, "a.png")
        // complete 后会话自动移除
        @Assert(ChunkUploadStore.cancel(ChunkUploadTest.OWNER, id, ChunkUploadTest.NOW), false)
    }

    @TestCase
    public func testCompleteRejectsMissingChunks() {
        let total = ChunkUploadStore.CHUNK_SIZE * 2 + 3
        let id = ChunkUploadTest.newSession(total)
        ChunkUploadStore.putChunk(
            ChunkUploadTest.OWNER, id, 0,
            ChunkUploadTest.filled(ChunkUploadStore.CHUNK_SIZE, 0x11u8), ChunkUploadTest.NOW)
        var rejected = false
        try {
            let c = ChunkUploadStore.complete(ChunkUploadTest.OWNER, id, ChunkUploadTest.NOW)
            let n = c.plain.size
            if (n > 0) { rejected = false }
        } catch (e: Exception) {
            rejected = true
        }
        @Assert(rejected, true)
        ChunkUploadStore.cancel(ChunkUploadTest.OWNER, id, ChunkUploadTest.NOW)
    }

    @TestCase
    public func testWrongChunkLengthRejected() {
        let total = ChunkUploadStore.CHUNK_SIZE * 2 + 3
        let id = ChunkUploadTest.newSession(total)
        var rejected = false
        try {
            // 非末片却只给了 10 字节
            let n = ChunkUploadStore.putChunk(
                ChunkUploadTest.OWNER, id, 0, ChunkUploadTest.filled(10, 0x11u8), ChunkUploadTest.NOW)
            if (n > 0) { rejected = false }
        } catch (e: Exception) {
            rejected = true
        }
        @Assert(rejected, true)
        ChunkUploadStore.cancel(ChunkUploadTest.OWNER, id, ChunkUploadTest.NOW)
    }

    @TestCase
    public func testOwnerBindingRejectsOtherOperator() {
        let id = ChunkUploadTest.newSession(1024)
        var rejected = false
        try {
            let (t, r, s, cs) = ChunkUploadStore.status(ChunkUploadTest.OTHER, id, ChunkUploadTest.NOW)
            if (t > 0) { rejected = false }
        } catch (e: Exception) {
            rejected = true
        }
        @Assert(rejected, true)
        ChunkUploadStore.cancel(ChunkUploadTest.OWNER, id, ChunkUploadTest.NOW)
    }

    @TestCase
    public func testExpiredSessionRejected() {
        let id = ChunkUploadTest.newSession(1024)
        var rejected = false
        try {
            let (t, r, s, cs) = ChunkUploadStore.status(
                ChunkUploadTest.OWNER, id, ChunkUploadTest.NOW + ChunkUploadStore.TTL_MS + 1)
            if (t > 0) { rejected = false }
        } catch (e: Exception) {
            rejected = true
        }
        @Assert(rejected, true)
    }

    @TestCase
    public func testTotalSizeUpperBoundRejected() {
        var rejected = false
        try {
            let id = ChunkUploadStore.create(
                ChunkUploadTest.OWNER, 1001, None, 10, "x", "a.png", "", "",
                ChunkUploadStore.MAX_FILE_SIZE + 1, ChunkUploadTest.NOW)
            if (id.size > 0) { rejected = false }
        } catch (e: Exception) {
            rejected = true
        }
        @Assert(rejected, true)
    }

    @TestCase
    public func testDuplicateChunkIsIdempotent() {
        let total = ChunkUploadStore.CHUNK_SIZE + 5
        let id = ChunkUploadTest.newSession(total)
        ChunkUploadStore.putChunk(
            ChunkUploadTest.OWNER, id, 0,
            ChunkUploadTest.filled(ChunkUploadStore.CHUNK_SIZE, 0xAAu8), ChunkUploadTest.NOW)
        let n = ChunkUploadStore.putChunk(
            ChunkUploadTest.OWNER, id, 0,
            ChunkUploadTest.filled(ChunkUploadStore.CHUNK_SIZE, 0xDDu8), ChunkUploadTest.NOW)
        @Assert(n, 1)   // 仍只有 1 片，未重复计数
        ChunkUploadStore.putChunk(
            ChunkUploadTest.OWNER, id, 1, ChunkUploadTest.filled(5, 0xBBu8), ChunkUploadTest.NOW)
        let c = ChunkUploadStore.complete(ChunkUploadTest.OWNER, id, ChunkUploadTest.NOW)
        @Assert(c.plain[0], 0xDDu8)   // 后写覆盖
        @Assert(c.plain.size, total)
    }
}

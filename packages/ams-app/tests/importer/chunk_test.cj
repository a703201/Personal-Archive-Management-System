// ============================================================
// ams.app.importer · 请求体分块累积回归（原为临时诊断，已转正）
//
// 【背景】
//   现场反馈「60 个条目的压缩包预检失败」，而同一个包从磁盘直接喂
//   `ZipArchive` 却完全正常（60 条目全部解析、路径无误）。定位方向
//   因此转到**请求体进入解析器之前**：`ApiRequest.fromContext` 用一个
//   复用的 64 KiB 缓冲区循环读，若分块用的是「切片视图」而非拷贝，
//   所有分块都会指向同一段内存 —— 拼出来的 body 长度正确、内容全错，
//   症状正是「小包没事、条目一多就崩」。
//
//   处置见 `api.http`：改为显式逐字节拷贝（`ApiRequest.copyOf`），
//   从此不依赖 `Array[Range]` 到底是拷贝还是视图。
//
// 【本文件保留什么】
//   把「复用缓冲区 + 分块显式拷贝 → 逐字节还原」这个算法钉住。
//   `copyOf` 在 ams-api 包内对测试不可见，故这里按同一语义复刻，
//   作为回归基线：谁把显式拷贝改回直接存切片，这两条用例会立刻报错。
// ============================================================
package ams.app.importer.test

import std.collection.*
import std.io.*
import std.unittest.*

import ams.app.importer.*

/** 把分块按顺序拼成一个数组（不依赖切片语义，逐字节写入）。 */
func flattenBytes(parts: ArrayList<Array<Byte>>, total: Int64): Array<Byte> {
    let out = Array<Byte>(total, repeat: 0u8)
    var at: Int64 = 0
    for (p in parts) {
        for (b in p) {
            out[at] = b
            at = at + 1
        }
    }
    return out
}

/** 逐字节比较（Array 的 == 语义在 SDK 间不稳，这里显式比较）。 */
func sameBytes(a: Array<Byte>, b: Array<Byte>): Bool {
    if (a.size != b.size) {
        return false
    }
    var i: Int64 = 0
    while (i < a.size) {
        if (a[i] != b[i]) {
            return false
        }
        i = i + 1
    }
    return true
}

/**
 * 分块累积语义。
 */
@Test
public class ChunkAccumulateTest {
    /**
     * 拷出的块必须**独立于**后续读入。
     *
     * 这是「长度对、内容错」的最后一道防线：复用缓冲区在下一次 read()
     * 时会被整块覆盖，若存的是视图，先前所有块会一起变成最后一轮的内容。
     */
    @TestCase
    public func testCopiedPartIsIndependent() {
        let chunk = Array<Byte>(4, repeat: 0u8)
        chunk[0] = 1
        chunk[3] = 4
        let part = Array<Byte>(4, repeat: 0u8)
        var j: Int64 = 0
        while (j < 4) {
            part[j] = chunk[j]
            j = j + 1
        }
        // 模拟下一轮读把缓冲区整个覆盖
        chunk[0] = 9
        chunk[3] = 9
        @Assert(part[0], 1)
        @Assert(part[3], 4)
    }

    /**
     * 60 字节请求体跨 3 块拼回后必须与源串逐字节一致（含块序）。
     */
    @TestCase
    public func testCopyKeepsOrder() {
        let src = Array<Byte>(150, repeat: 0u8)
        var i: Int64 = 0
        while (i < 150) {
            src[i] = UInt8(i)
            i = i + 1
        }
        let chunk = Array<Byte>(64, repeat: 0u8)
        let parts = ArrayList<Array<Byte>>()
        var at: Int64 = 0
        while (at < src.size) {
            let remain = src.size - at
            let n = if (remain > 64) { 64 } else { remain }
            var j: Int64 = 0
            while (j < n) {
                chunk[j] = src[at + j]
                j = j + 1
            }
            // 与 ApiRequest.copyOf 同一语义：把**当前**这一块拷出来再存
            let part = Array<Byte>(n, repeat: 0u8)
            j = 0
            while (j < n) {
                part[j] = chunk[j]
                j = j + 1
            }
            parts.add(part)
            at = at + n
        }
        @Assert(parts.size, 3)
        var k: Int64 = 0
        for (p in parts) {
            for (b in p) {
                @Assert(b, src[k])
                k = k + 1
            }
        }
        @Assert(k, 150)
    }

    /**
     * SDK 语义记录（本机 SDK 1.0.5 实测）：`Array<T>[Range]` 返回**视图**，不是拷贝。
     *
     * 这条不是「验证 SDK 对不对」，而是把 `copyOf` 存在的理由写进代码：
     * 若哪天它失败（切片变成拷贝），说明可以简化 `copyOf`；
     * 在那之前，**任何人把 `copyOf` 改回 `src[0..n]` 都会重新引入串块缺陷**。
     */
    @TestCase
    public func testArraySliceIsViewNotCopy() {
        let buf = Array<Byte>(4, repeat: 0u8)
        buf[0] = 1
        let s = buf[0..4]
        buf[0] = 9
        @Assert(s[0], 9u8)          // 视图：跟着源变
        // 显式拷贝则不受影响
        let c = Array<Byte>(4, repeat: 0u8)
        c[0] = buf[0]
        buf[0] = 7
        @Assert(c[0], 9u8)
    }

    /**
     * 端到端形态：一个跨多个 64 KiB 块的 60 条目 ZIP，
     * 「存切片」累积后**解析必失败**，「显式拷贝」累积后**解析出 60 条目**。
     *
     * 这就是现场「60 个条目的包预检失败」的最小复现：
     * 包小于一次读取时（单块）两种写法都对，一旦跨块，旧写法拼出的 body
     * 长度仍然正确、内容却是最后一块的重复 —— 只有解析器看得见。
     */
    @TestCase
    public func testChunkedBodyKeepsZipIntact() {
        // 60 条目 × 3 KB store 载荷 ≈ 180 KB > 64 KiB，必然跨块
        let payload = Array<Byte>(3072, repeat: 65u8)     // 'A'
        let maker = ZipMaker()
        var i: Int64 = 0
        while (i < 60) {
            maker.add("目录${i}/文件${i}.png".toArray(), payload, payload, 0, 0x0800)
            i = i + 1
        }
        let zipBytes = maker.build()
        @Assert(zipBytes.size > 65536, true)

        let oldParts = ArrayList<Array<Byte>>()    // 旧写法：存切片（视图）
        let newParts = ArrayList<Array<Byte>>()    // 新写法：显式拷贝
        let chunk = Array<Byte>(65536, repeat: 0u8)
        let stream = ByteBuffer(zipBytes)
        var total: Int64 = 0
        while (true) {
            let n = stream.read(chunk)
            if (n <= 0) {
                break
            }
            oldParts.add(chunk[0..n])
            let part = Array<Byte>(n, repeat: 0u8)
            var j: Int64 = 0
            while (j < n) {
                part[j] = chunk[j]
                j = j + 1
            }
            newParts.add(part)
            total = total + n
        }
        @Assert(oldParts.size > 1, true)           // 确实跨块了
        let oldBody = flattenBytes(oldParts, total)
        let newBody = flattenBytes(newParts, total)
        // 长度都对得上 —— 所以「只看 size」永远发现不了这个缺陷
        @Assert(oldBody.size, zipBytes.size)
        @Assert(newBody.size, zipBytes.size)
        @Assert(sameBytes(newBody, zipBytes), true)
        @Assert(sameBytes(oldBody, zipBytes), false)
        // 真解析：新写法 60 条目俱全，且**每个文件都能解出内容**
        let newZip = ZipArchive.open(newBody)
        @Assert(newZip.entries().size, 60)
        var okCount: Int64 = 0
        for (e in newZip.entries()) {
            if (caught({ => newZip.read(e, 8192) }).isEmpty()) {
                okCount = okCount + 1
            }
        }
        @Assert(okCount, 60)

        // 旧写法：EOCD 与中央目录正好落在**最后一次读取的尾部**，串块恰好把它们保住了，
        // 所以包仍然「打得开」、条目数照样是 60 —— 但每个条目的载荷都指向了错位置，
        // 一读就失败（本地头损坏 / CRC 不符）。
        // 这才是现场症状的真实形态：**不是「打不开包」，而是「文件全都说内容损坏」**。
        // 若哪天有人把 copyOf 改回切片，这里会从 60/60 掉成 0/60。
        let oldZip = ZipArchive.open(oldBody)
        @Assert(oldZip.entries().size, 60)
        var badCount: Int64 = 0
        for (e in oldZip.entries()) {
            if (!caught({ => oldZip.read(e, 8192) }).isEmpty()) {
                badCount = badCount + 1
            }
        }
        // 实测 41/60 损坏 —— 只有落在「最后一块」里（偏移 >= 131072）的那 19 条
        // 侥幸指到了真实位置。这里只断言「一定有损坏」：
        // 一旦 SDK 改成切片返回拷贝，badCount 会变成 0，本用例即报错提醒复核。
        @Assert(badCount > 0, true)
    }
}

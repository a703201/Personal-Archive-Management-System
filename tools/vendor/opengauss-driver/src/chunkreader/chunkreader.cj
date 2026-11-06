/**
 * Copyright (c) [2022] Huawei Technologies Co., Ltd.
 * [opengauss-driver] is licensed under Mulan PSL v2.
 * You can use this software according to the terms and conditions of the Mulan PSL v2.
 * You may obtain a copy of Mulan PSL v2 at:
 *            http://license.coscl.org.cn/MulanPSL2
 * THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS,
 * WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED,
 * INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
 * See the Mulan PSL v2 for more details.
 */
package cangjie_tpc::opengauss.chunkreader

internal import std.collection.*
internal import std.io.*
internal import stdx.encoding.hex.*
import cangjie_tpc::opengauss.slog

const CHUNK_BUF_LENGTH: Int64 = 4096

public class ChunkReader {
    let logger = slog.Default()
    let r: InputStream
    var data = Array<Byte>(CHUNK_BUF_LENGTH, repeat: 0)
    var begin: Int64 = 0
    var end: Int64 = 0
    public init(r: InputStream) {
        this.r = r
    }

    func readAtLeast(buf: Array<Byte>, min: Int): Int {
        var n = 0
        if (buf.size < min) {
            return 0
        }
        while (n < min) {
            var nn = r.read(buf[n..])
            if (nn <= 0) {
                throw IOException("cannot read data. read length is ${nn}")
            }
            n += nn
        }
        n
    }

    public func readToEnd(): Array<Byte> {
        if (begin == end) {
            begin = 0
            end = 0
        }
        let buflen = 1024 * 1024
        var readlen = r.read(data[end..])
        while (readlen == data.size - end) {
            end = data.size
            grow(data.size + CHUNK_BUF_LENGTH)
            readlen = r.read(data[end..])
        }
        end += readlen
        let ret = data[begin..end]
        begin = end
        return ret
    }

    public func read(n: Int64): Option<Array<Byte>> {
        if (begin == end) {
            begin = 0
            end = 0
        }
        if ((end - begin) >= n) {
            var buf = data[begin..begin + n]
            begin += n
            return buf
        }
        if (data.size < n) {
            grow(n)
        }
        let minReadlen = n - (end - begin)
        if (data.size - end < minReadlen) {
            data.copyTo(data, begin, 0, end - begin)
            end = end - begin
            begin = 0
        }
        let rlen = readAtLeast(data[end..], minReadlen)
        if (rlen < minReadlen) {
            return None
        }

        // logger.debug("read ${rlen} ${toHexString(data[end..end+rlen])}")
        end += rlen
        var buf = data[begin..begin + n]
        begin += n
        return buf
    }

    func grow(n: Int64) {
        let oldCap = data.size
        if (n <= oldCap) {
            return
        }
        var newCap = oldCap + (oldCap << 1)
        if (newCap < n) {
            newCap = n
        }
        let newArr = Array<Byte>(newCap, repeat: 0)
        data.copyTo(newArr, begin, 0, end - begin)
        end -= begin
        begin = 0
        data = newArr
    }
}

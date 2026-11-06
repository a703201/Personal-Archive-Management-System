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
package cangjie_tpc::opengauss.utils

internal import std.io.*
import std.binary.*
import cangjie_tpc::opengauss.chunkreader.*
import cangjie_tpc::opengauss.slog

public func startWith(s: Array<Byte>, prefix: Array<Byte>): Bool {
    return (s.size >= prefix.size) && (s[0..prefix.size] == prefix)
}

public func bytesToString(u8arr: Array<Byte>): String {
    return bytesToString(u8arr, true)
}

public func bytesToString(u8arr: Array<Byte>, logerr: Bool): String {
    try {
        return String.fromUtf8(u8arr)
    } catch (ex: Exception) {
        if (logerr) {
            let logger = slog.Default()
            logger.error("cannot translate to string. ${ex}. the data is ${u8arr}")
        }
        return u8arr.toString()
    }
}

public func bytesToString(u8arr: Array<Byte>, pos: Int64, count: Int64): String {
    return bytesToString(u8arr, pos, count, true)
}

public func bytesToString(u8arr: Array<Byte>, pos: Int64, count: Int64, logerr: Bool): String {
    if (pos >= u8arr.size) {
        return ""
    }
    var max = pos + count
    if (max > u8arr.size) {
        max = u8arr.size
    }
    try {
        return String.fromUtf8(u8arr[pos..max])
    } catch (ex: Exception) {
        if (logerr) {
            let logger = slog.Default()
            logger.error("cannot translate to string. ${ex}. the data is ${u8arr[pos..max]}")
        }
        return u8arr[pos..max].toString()
    }
}

public func inputStreamToBytes(inputStream: InputStream): Array<Byte> {
    var cr = ChunkReader(inputStream)
    return cr.readToEnd()
}

public interface SizeOfExt<T> {
    func sizeOf(): Int64
}

public interface BigEndianExt<T> {
    func toBeBytes(): Array<UInt8>
}

public interface LitterEndianExt<T> {
    func toLeBytes(): Array<UInt8>
}

public interface BytesExtension<T> <: BigEndianExt<T> & LitterEndianExt<T> & SizeOfExt<T> {}

extend UInt64 <: BytesExtension<UInt64> {
    public func sizeOf(): Int64 {
        8
    }

    @OverflowWrapping
    public func toLeBytes(): Array<UInt8> {
        var dst = Array<UInt8>(8, repeat: 0)
        for (i in 0..8) {
            dst[i] = UInt8((this >> 8 * (i)) & 0xFF)
        }
        return dst
    }

    @OverflowWrapping
    public func toBeBytes(): Array<UInt8> {
        var dst = Array<UInt8>(8, repeat: 0)
        for (i in 0..8) {
            dst[i] = UInt8((this >> 8 * (7 - i)) & 0xFF)
        }
        return dst
    }
}

extend Int64 <: BytesExtension<Int64> {
    public func sizeOf(): Int64 {
        8
    }

    @OverflowWrapping
    public func toLeBytes(): Array<UInt8> {
        return UInt64(this).toLeBytes()
    }

    @OverflowWrapping
    public func toBeBytes(): Array<UInt8> {
        return UInt64(this).toBeBytes()
    }
}

extend UInt32 <: BytesExtension<UInt32> {
    public func sizeOf(): Int64 {
        4
    }

    @OverflowWrapping
    public func toLeBytes(): Array<UInt8> {
        var dst = Array<UInt8>(4, repeat: 0)
        dst[0] = UInt8(this)
        dst[1] = UInt8(this >> 8)
        dst[2] = UInt8(this >> 16)
        dst[3] = UInt8(this >> 24)
        return dst
    }

    @OverflowWrapping
    public func toBeBytes(): Array<UInt8> {
        var dst = Array<UInt8>(4, repeat: 0)
        dst[0] = UInt8(this >> 24)
        dst[1] = UInt8(this >> 16)
        dst[2] = UInt8(this >> 8)
        dst[3] = UInt8(this)
        return dst
    }
}

extend Int32 <: BytesExtension<Int32> {
    public func sizeOf(): Int64 {
        4
    }

    @OverflowWrapping
    public func toLeBytes(): Array<UInt8> {
        return UInt32(this).toLeBytes()
    }

    @OverflowWrapping
    public func toBeBytes(): Array<UInt8> {
        return UInt32(this).toBeBytes()
    }
}

extend UInt16 <: BytesExtension<UInt16> {
    public func sizeOf(): Int64 {
        2
    }

    @OverflowWrapping
    public func toLeBytes(): Array<UInt8> {
        var dst = Array<UInt8>(2, repeat: 0)
        dst[0] = UInt8(this)
        dst[1] = UInt8(this >> 8)
        return dst
    }

    @OverflowWrapping
    public func toBeBytes(): Array<UInt8> {
        var dst = Array<UInt8>(2, repeat: 0)
        dst[0] = UInt8(this >> 8)
        dst[1] = UInt8(this)
        return dst
    }
}

extend Int16 <: BytesExtension<Int16> {
    public func sizeOf(): Int64 {
        2
    }

    @OverflowWrapping
    public func toLeBytes(): Array<UInt8> {
        return UInt16(this).toLeBytes()
    }

    @OverflowWrapping
    public func toBeBytes(): Array<UInt8> {
        return UInt16(this).toBeBytes()
    }
}

extend Int8 <: BytesExtension<Int8> {
    public func sizeOf(): Int64 {
        1
    }

    @OverflowWrapping
    public func toLeBytes(): Array<UInt8> {
        [UInt8(this)]
    }

    @OverflowWrapping
    public func toBeBytes(): Array<UInt8> {
        [UInt8(this)]
    }
}

extend UInt8 <: BytesExtension<UInt8> {
    public func sizeOf(): Int64 {
        1
    }
    public func toLeBytes(): Array<UInt8> {
        [this]
    }
    public func toBeBytes(): Array<UInt8> {
        [this]
    }
}

extend String <: BigEndianExt<String> & SizeOfExt<String> {
    public func sizeOf(): Int64 {
        this.size
    }
    public func toBeBytes(): Array<UInt8> {
        return this.toArray()
    }
}

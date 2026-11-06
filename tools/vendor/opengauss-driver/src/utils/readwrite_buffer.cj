/**
 * Copyright 2024 Beijing Baolande Software Corporation
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Runtime Library Exception to the Apache 2.0 License:
 *
 * As an exception, if you use this Software to compile your source code and
 * portions of this Software are embedded into the binary product as a result,
 * you may redistribute such product without providing attribution as would
 * otherwise be required by Sections 4(a), 4(b) and 4(d) of the License.
 */

package cangjie_tpc::opengauss.utils

internal import std.collection.*
internal import std.math.*
internal import std.convert.*

const WRITE_BUF_LENGTH: Int64 = 8192

public class ReadWriteBuffer {
    protected var buf: Array<UInt8>
    protected var position: Int64 = 0

    public init() {
        buf = Array<UInt8>(WRITE_BUF_LENGTH, repeat: 0)
    }

    public init(len: Int64) {
        buf = if (len < 0) {
            Array<UInt8>(WRITE_BUF_LENGTH, repeat: 0)
        } else {
            Array<UInt8>(len, repeat: 0)
        }
    }

    public func add(b: UInt64): Unit {
        if (position + 8 >= buf.size) {
            var tmpbuf = buf
            buf = Array<UInt8>(buf.size + WRITE_BUF_LENGTH, repeat: 0)
            tmpbuf.copyTo(buf, 0, 0, tmpbuf.size)
        }
        buf[position] = UInt8((b >> 56) & 0xff)
        buf[position + 1] = UInt8((b >> 48) & 0xff)
        buf[position + 2] = UInt8((b >> 40) & 0xff)
        buf[position + 3] = UInt8((b >> 32) & 0xff)
        buf[position + 4] = UInt8((b >> 24) & 0xff)
        buf[position + 5] = UInt8((b >> 16) & 0xff)
        buf[position + 6] = UInt8((b >> 8) & 0xff)
        buf[position + 7] = UInt8(b & 0xff)
        position += 8
    }

    @OverflowWrapping
    public func add(b: Int64): Unit {
        this.add(UInt64(b))
    }

    public func add(b: UInt32): Unit {
        if (position + 4 >= buf.size) {
            var tmpbuf = buf
            buf = Array<UInt8>(buf.size + WRITE_BUF_LENGTH, repeat: 0)
            tmpbuf.copyTo(buf, 0, 0, tmpbuf.size)
        }
        buf[position] = UInt8((b >> 24) & 0xff)
        buf[position + 1] = UInt8((b >> 16) & 0xff)
        buf[position + 2] = UInt8((b >> 8) & 0xff)
        buf[position + 3] = UInt8(b & 0xff)
        position += 4
    }

    @OverflowWrapping
    public func add(b: Int32): Unit {
        this.add(UInt32(b))
    }

    public func add(b: UInt16): Unit {
        if (position + 2 >= buf.size) {
            var tmpbuf = buf
            buf = Array<UInt8>(buf.size + WRITE_BUF_LENGTH, repeat: 0)
            tmpbuf.copyTo(buf, 0, 0, tmpbuf.size)
        }
        buf[position] = UInt8((b >> 8) & 0xff)
        buf[position + 1] = UInt8(b & 0xff)
        position += 2
    }

    @OverflowWrapping
    public func add(b: Int16): Unit {
        this.add(UInt16(b))
    }

    public func add(b: UInt8): Unit {
        if (position >= buf.size) {
            var tmpbuf = buf
            buf = Array<UInt8>(buf.size + WRITE_BUF_LENGTH, repeat: 0)
            tmpbuf.copyTo(buf, 0, 0, tmpbuf.size)
        }
        buf[position] = b
        position++
    }

    @OverflowWrapping
    public func add(b: Int8): Unit {
        this.add(UInt8(b))
    }

    public func add(msg: String): Unit {
        if (msg.size == 0) {
            return
        }
        add(msg.toArray())
    }

    public func add(arr: Array<UInt8>): Unit {
        if (arr.size == 0) {
            return
        }
        put(arr, 0, arr.size)
    }

    public func isEmpty(): Bool {
        return position == 0
    }

    public prop size: Int64 {
        get() {
            return position
        }
    }

    public func getPosition(): Int64 {
        return this.position
    }

    public func setPosition(newPosition: Int64): ReadWriteBuffer {
        if (newPosition > buf.size || newPosition < 0) {
            throw Exception("newPosition = ${newPosition}")
        }
        position = newPosition
        return this
    }

    public func put(i: Int64, x: UInt8): ReadWriteBuffer {
        if (i >= buf.size) {
            var tmpbuf = buf
            buf = Array<UInt8>(i + WRITE_BUF_LENGTH, repeat: 0)
            tmpbuf.copyTo(buf, 0, 0, tmpbuf.size)
        }
        buf[i] = x
        return this
    }

    public func put(src: Array<UInt8>): ReadWriteBuffer {
        return put(src, 0, src.size)
    }

    public func put(src: Array<UInt8>, offset: Int64, length: Int64): ReadWriteBuffer {
        if (buf.size - position < length) {
            var newlength = 0
            if (length <= WRITE_BUF_LENGTH) {
                newlength = buf.size + WRITE_BUF_LENGTH
            } else {
                newlength = buf.size + length
            }
            var tmpbuf = buf
            buf = Array<UInt8>(newlength, repeat: 0)
            tmpbuf.copyTo(buf, 0, 0, tmpbuf.size)
        }
        src.copyTo(buf, offset, position, length)
        position += length
        return this
    }

    public func add(src: ReadWriteBuffer): ReadWriteBuffer {
        put(src.data())
        return this
    }

    public func data(): Array<UInt8> {
        return buf[0..position]
    }

    public func data(offset: Int64, length: Int64): Array<UInt8> {
        if (offset + length > position) {
            throw IndexOutOfBoundsException("${offset + length} > ${position}")
        }
        return buf[offset..offset + length]
    }

    public func cloneData(): Array<UInt8> {
        var ret = Array<UInt8>(position, repeat: 0)
        buf.copyTo(ret, 0, 0, position)
        return ret
    }

    public func reset(): Unit {
        position = 0
    }
}

extend ReadWriteBuffer <: ToString {
    public func toString(): String {
        var sb = StringBuilder()
        for (i in 0..buf.size) {
            sb.append(buf[i].format("#x"))
            sb.append(" ")
        }
        return "${sb.toString()}"
    }
}

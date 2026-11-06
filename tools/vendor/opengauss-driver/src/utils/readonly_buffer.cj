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

import std.collection.*
import std.math.*
import std.convert.*

public class ReadOnlyBuffer {
    protected var buf: Array<UInt8> = Array<UInt8>()

    public var position: Int64 = 0

    public init(buffs: Array<UInt8>) {
        this.buf = buffs
    }

    public init(buffs: Array<UInt8>, isBig: Bool) {
        this.buf = buffs
    }

    public func isEmpty(): Bool {
        return this.buf.size == 0
    }

    public prop size: Int64 {
        get() {
            return this.buf.size
        }
    }

    public func getPosition(): Int64 {
        return this.position
    }

    public func setPosition(newPosition: Int64): ReadOnlyBuffer {
        if (newPosition > buf.size || newPosition < 0) {
            throw Exception("newPosition = ${newPosition} and limit = ${buf.size}")
        }
        position = newPosition
        return this
    }

    public func remaining(): Int64 {
        var rem: Int64 = buf.size - position
        if (rem < 0) {
            rem = 0
        }
        return rem
    }

    public func equals(ob: ReadOnlyBuffer): Bool {
        let thisPos: Int64 = this.position
        let thisRem: Int64 = buf.size - thisPos
        let obPos: Int64 = ob.getPosition()
        let obRem: Int64 = ob.size - obPos
        if (thisRem < 0 || thisRem != obRem) {
            return false
        }
        return this.buf == ob.buf
    }

    func checkIndex(i: Int64): Int64 {
        if ((i < 0) || (i >= buf.size)) {
            throw IndexOutOfBoundsException("i = ${i}")
        }
        return i
    }

    public func hasRemaining(): Bool {
        return this.position < this.buf.size
    }

    static func checkBounds(off: Int64, len: Int64, size: Int64): Unit {
        if ((off | len | (off + len) | (size - (off + len))) < 0) {
            throw IndexOutOfBoundsException()
        }
    }

    public func get(length: Int64): Array<UInt8> {
        if (position + length > buf.size) {
            throw Exception("position(${position}) + length(${length}) > limit(${buf.size})")
        }
        var tmppos = position
        position += length
        return buf[tmppos..position]
    }

    public func get(dst: Array<UInt8>, offset: Int64, length: Int64): ReadOnlyBuffer {
        checkBounds(offset, length, dst.size)
        if (length > remaining()) {
            throw IndexOutOfBoundsException()
        }
        let end: Int64 = offset + length
        buf.copyTo(dst, position, offset, length)
        position += length
        return this
    }

    public func get(): UInt8 {
        if (position >= buf.size) {
            throw Exception("position(${position}) >= limit(${buf.size})")
        }
        position++
        return buf[position - 1]
    }

    public func getString(): String {
        var tmppos = position;
        var tmpendpos = getZeroPosOfString()
        position = tmpendpos + 1
        return String.fromUtf8(unsafe { buf[tmppos..tmpendpos] })
    }

    private func getZeroPosOfString(): Int64 {
        var ret = -1
        for (index in position..buf.size) {
            if (buf[index] == 0) {
                ret = index
                break
            }
        }
        if (ret == -1) {
            throw Exception("cannot find the null-terminated byte of a string")
        }
        return ret
    }

    public func getNTString(): String {
        var sb = ArrayList<Rune>()
        var c: UInt8 = 0
        while (true) {
            c = getByte()
            if (c == 0) {
                break
            }
            sb.add(Rune(c))
        }
        return String(sb)
    }

    @OverflowWrapping
    public func getInt64(): Int64 {
        return Int64(getUInt64())
    }

    public func getUInt64(): UInt64 {
        if (remaining() < 8) {
            throw Exception("remaining(${remaining()}) < 8")
        }
        position += 8
        return (UInt64(buf[position - 8]) << 56) + (UInt64(buf[position - 7]) << 48) + (UInt64(buf[position - 6]) << 40) +
            (UInt64(buf[position - 5]) << 32) + (UInt64(buf[position - 4]) << 24) + (UInt64(buf[position - 3]) << 16) + (UInt64(buf[position -
                2]) << 8) + UInt64(buf[position - 1])
    }

    public func getUInt32(): UInt32 {
        if (remaining() < 4) {
            throw Exception("remaining(${remaining()}) < 4")
        }
        position += 4
        return (UInt32(buf[position - 4]) << 24) + (UInt32(buf[position - 3]) << 16) + (UInt32(buf[position - 2]) << 8) +
            UInt32(buf[position - 1])
    }

    @OverflowWrapping
    public func getInt32(): Int32 {
        return Int32(getUInt32())
    }

    public func getUInt16(): UInt16 {
        if (remaining() < 2) {
            throw Exception("remaining(${remaining()}) < 2")
        }
        position += 2
        return (UInt16(buf[position - 2]) << 8) + UInt16(buf[position - 1])
    }

    @OverflowWrapping
    public func getInt16(): Int16 {
        return Int16(getUInt16())
    }

    public func getUInt8(): UInt8 {
        if (remaining() < 1) {
            throw Exception("remaining(${remaining()}) < 1")
        }
        position++
        return buf[position - 1]
    }

    public func getByte(): Byte {
        return getUInt8()
    }

    @OverflowWrapping
    public func getInt8(): Int8 {
        return Int8(getUInt8())
    }

    public func reset(): Unit {
        this.position = 0
    }
}

extend ReadOnlyBuffer <: ToString {
    public func toString(): String {
        var sb = StringBuilder()
        for (i in 0..buf.size) {
            sb.append(buf[i].format("#x"))
            sb.append(" ")
        }
        return "${sb.toString()}"
    }
}

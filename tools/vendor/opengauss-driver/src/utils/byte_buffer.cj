// /**
//  * Copyright (c) [2022] Huawei Technologies Co., Ltd.
//  * [opengauss-driver] is licensed under Mulan PSL v2.
//  * You can use this software according to the terms and conditions of the Mulan PSL v2.
//  * You may obtain a copy of Mulan PSL v2 at:
//  *            http://license.coscl.org.cn/MulanPSL2
//  * THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS,
//  * WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR IMPLIED,
//  * INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
//  * See the Mulan PSL v2 for more details.
//  */
// /*
//  * Copyright (c) Cangjie Library Team 2022-2022. All rights reserved.
//  * Description:
//  */

// /**
//  * @file The file ByteBuffer class.
//  */

package cangjie_tpc::opengauss.utils

// internal import std.collection.*
// internal import std.math.*
// internal import std.convert.*

// /**
//  * The class is ByteBuffer inherited from Collection<UInt8>
//  * @author liyanqing14
//  * @since 0.29.3
//  */
// public class InnerByteBuffer <: Collection<UInt8> {
//     protected var buf: ArrayList<UInt8> = ArrayList<UInt8>()
//     protected var offset: Int64 = 0
//     protected var isReadOnly: Bool = false

//     protected var mycapacity = 16

//     /* Invariants: mark <= position <= limit <= capacity */
//     public var mark: Int64 = -1
//     public var position: Int64 = 0
//     public var limit: Int64 = 0
//     public var capacity: Int64 = 0

//     protected var address: Int64 = 0

//     protected var bigEndian: Bool = false

//     public init() {
//         this.buf = ArrayList<UInt8>()
//         this.bigEndian = true
//     }

//     public init(len: Int64) {
//         this.buf = if (len < 0) {
//             ArrayList<UInt8>()
//         } else {
//             ArrayList<UInt8>(len)
//         }
//         this.bigEndian = true
//     }

//     private init(capacity: Int64, limit: Int64) {
//         this(-1, 0, limit, capacity, ArrayList<UInt8>(capacity, {i => 0}), 0)
//         this.bigEndian = true
//     }

//     private init(mark: Int64, position: Int64, limit: Int64, capacity: Int64) {
//         if (capacity < 0) {
//             throw Exception("cap < 0")
//         }
//         this.capacity = capacity
//         if (mark >= 0) {
//             if (mark > position) {
//                 throw Exception("mark > position: ( ${mark} > ${position} )")
//             }
//             this.mark = mark
//         }
//         setLimit(limit)
//         setPosition(position)
//     }

//     private init(
//         mark: Int64,
//         position: Int64,
//         limit: Int64,
//         capacity: Int64,
//         buf: ArrayList<UInt8>,
//         offset: Int64
//     ) {
//         this(mark, position, limit, capacity)
//         this.buf = buf
//         this.offset = offset
//     }

//     public init(buffs: Collection<UInt8>) {
//         this(-1, 0, buffs.size, buffs.size)
//         this.buf = ArrayList<UInt8>(buffs.size)
//         for (b in buffs) {
//             this.buf.add(b)
//         }
//         this.bigEndian = true
//     }

//     public init(buffs: Collection<UInt8>, isBig: Bool) {
//         this.buf = ArrayList<UInt8>(buffs.size)
//         for (b in buffs) {
//             this.buf.add(b)
//         }
//         this.bigEndian = isBig
//     }

//     public init(isBig: Bool) {
//         this.buf = ArrayList<UInt8>()
//         this.bigEndian = isBig
//     }

//     public static func allocate(capacity: Int64): ByteBuffer {
//         if (capacity < 0) {
//             throw Exception("capacity less than 0!")
//         }
//         return ByteBuffer(capacity, capacity)
//     }

//     public func add(b: UInt64): Unit {
//         if (this.bigEndian) {
//             this.add(UInt32(b >> 32))
//             this.add(UInt32(b & 0xffffffff))
//         } else {
//             this.add(UInt32(b & 0xffffffff))
//             this.add(UInt32(b >> 32))
//         }
//     }

//     @OverflowWrapping
//     public func add(b: Int64): Unit {
//         this.add(UInt64(b))
//     }

//     public func add(b: UInt32): Unit {
//         if (this.bigEndian) {
//             this.add(UInt16(b >> 16))
//             this.add(UInt16(b & 0xffff))
//         } else {
//             this.add(UInt16(b & 0xffff))
//             this.add(UInt16(b >> 16))
//         }
//     }

//     @OverflowWrapping
//     public func add(b: Int32): Unit {
//         this.add(UInt32(b))
//     }

//     public func add(b: UInt16): Unit {
//         if (this.bigEndian) {
//             this.add(UInt8(b >> 8))
//             this.add(UInt8(b & 0xff))
//         } else {
//             this.add(UInt8(b & 0xff))
//             this.add(UInt8(b >> 8))
//         }
//     }

//     @OverflowWrapping
//     public func add(b: Int16): Unit {
//         this.add(UInt16(b))
//     }

//     public func add(b: UInt8): Unit {
//         this.buf.add(b)
//         if (this.buf.size == this.mycapacity) {
//             this.mycapacity = this.mycapacity << 1
//         }
//         this.capacity++
//         this.limit++
//     }

//     @OverflowWrapping
//     public func add(b: Int8): Unit {
//         this.add(UInt8(b))
//     }

//     public func add(msg: String): Unit {
//         if (msg.size == 0) {
//             return
//         }
//         let arr: Array<UInt8> = msg.toArray()
//         for (u in arr) {
//             this.add(u)
//         }
//     }

//     public func add(arr: Array<UInt8>): Unit {
//         if (arr.size == 0) {
//             return
//         }
//         for (u in arr) {
//             this.add(u)
//         }
//     }

//     public func getCurAvail(): Int64 {
//         return this.mycapacity - this.buf.size
//     }

//     public func isEmpty(): Bool {
//         return this.buf.size == 0
//     }

//     public func iterator(): Iterator<UInt8> {
//         return this.buf.iterator()
//     }

//     public prop size: Int64 {
//         get() {
//             return this.buf.size
//         }
//     }

//     public func slice(range: Range<Int64>): ByteBuffer {
//         let newbuf: ArrayList<UInt8> = this.buf.slice(range)
//         return ByteBuffer(newbuf)
//     }

//     public func isNull(): Bool {
//         return this.capacity == 0
//     }

//     public func getLimit(): Int64 {
//         return this.limit
//     }

//     public func getCapacity(): Int64 {
//         return this.capacity
//     }

//     public func getPosition(): Int64 {
//         return this.position
//     }

//     public func setPosition(newPosition: Int64): ByteBuffer {
//         if (newPosition > limit || newPosition < 0) {
//             throw Exception("newPosition = ${newPosition}")
//         }
//         if (mark > newPosition) {
//             mark = -1
//         }
//         position = newPosition
//         return this
//     }

//     public func setLimit(newLimit: Int64): ByteBuffer {
//         if (newLimit > capacity || newLimit < 0) {
//             throw Exception("newLimit = ${newLimit}")
//         }
//         limit = newLimit
//         if (position > newLimit) {
//             position = newLimit
//         }
//         if (mark > newLimit) {
//             mark = -1
//         }
//         return this
//     }

//     public func remaining(): Int64 {
//         var rem: Int64 = limit - position
//         if (rem < 0) {
//             rem = 0
//         }
//         return rem
//     }

//     public func equals(ob: ByteBuffer): Bool {
//         let thisPos: Int64 = this.position
//         let thisRem: Int64 = this.limit - thisPos
//         let obPos: Int64 = ob.getPosition()
//         let obRem: Int64 = ob.getLimit() - obPos
//         if (thisRem < 0 || thisRem != obRem) {
//             return false
//         }
//         return this.buf == ob.buf
//     }

//     public func put(flags: UInt8): ByteBuffer {
//         buf[ix(nextPutIndex())] = flags
//         return this
//     }

//     public func put(i: Int64, x: UInt8): ByteBuffer {
//         buf[ix(checkIndex(i))] = x
//         return this
//     }
//     func checkIndex(i: Int64): Int64 {
//         if ((i < 0) || (i >= limit)) {
//             throw IndexOutOfBoundsException("i = ${i}")
//         }
//         return i
//     }

//     public func put(src: Array<UInt8>): ByteBuffer {
//         return put(src, 0, src.size)
//     }

//     public func put(src: Array<UInt8>, offset: Int64, length: Int64): ByteBuffer {
//         let num: Int64 = src.size
//         if ((num | offset | num) < 0 || length > num - offset) {
//             throw Exception("the num is error: src.size() = ${num}, offset = ${offset}, length = ${length}")
//         }
//         let pos: Int64 = getPosition()
//         if (length > getLimit() - pos) {
//             throw Exception("buffer over flow, length > limit() - pos")
//         }
//         putArray(pos, src, offset, length);
//         setPosition(pos + length)
//         return this
//     }

//     private func putArray(index: Int64, src: Array<UInt8>, offset: Int64, length: Int64): ByteBuffer {
//         let end: Int64 = offset + length
//         var indexi: Int64 = offset
//         var indexj: Int64 = index
//         for (i in offset..end) {
//             this.put(indexj, src[indexi])
//             indexi++
//             indexj++
//         }
//         return this
//     }

//     protected func ix(num: Int64): Int64 {
//         return num + offset
//     }

//     protected func nextPutIndex(): Int64 {
//         let p: Int64 = position
//         if (p >= limit) {
//             throw Exception("p >= limit")
//         }
//         this.position = p + 1
//         return p
//     }

//     protected func nextPutIndex(num: Int64): Int64 {
//         let p: Int64 = position
//         if (limit - p < num) {
//             throw Exception("Over flow the buf!")
//         }
//         this.position = p + num
//         return p
//     }

//     public func put(src: ByteBuffer): ByteBuffer {
//         var srcPos: Int64 = src.getPosition()
//         var srcLim: Int64 = src.getLimit()
//         var srcRem: Int64 = 0
//         if (srcPos <= srcLim) {
//             srcRem = srcLim - srcPos
//         }
//         var pos: Int64 = this.position
//         var lim: Int64 = this.limit
//         var rem: Int64 = 0
//         if (pos <= lim) {
//             rem = lim - pos
//         }
//         if (srcRem > rem) {
//             throw Exception("BufferOverflow")
//         }
//         var srcBase: ArrayList<UInt8> = src.base()

//         if (srcBase.isEmpty()) {
//             throw Exception("ByteBuffer src is empty.")
//         }

//         var base: ArrayList<UInt8> = base()
//         if (base.isEmpty()) {
//             throw Exception("this ByteBuffer is empty.")
//         }

//         var srcAddr: Int64 = src.address + (srcPos << 0)
//         var addr: Int64 = this.address + (pos << 0)
//         var len: Int64 = srcRem << 0
//         if (len > 0) {
//             for (i in 0..len) {
//                 base[addr + i] = srcBase[srcAddr + i]
//             }
//         }
//         setPosition(pos + srcRem)
//         src.setPosition(srcPos + srcRem)
//         return this
//     }

//     private func base(): ArrayList<UInt8> {
//         return this.buf
//     }

//     public func getBuf(): ArrayList<UInt8> {
//         return this.buf.clone()
//     }

//     public func hasRemaining(): Bool {
//         return this.position < this.limit
//     }

//     static func checkBounds(off: Int64, len: Int64, size: Int64): Unit {
//         if ((off | len | (off + len) | (size - (off + len))) < 0) {
//             throw IndexOutOfBoundsException()
//         }
//     }

//     public func get(dst: Array<UInt8>, offset: Int64, length: Int64): ByteBuffer {
//         checkBounds(offset, length, dst.size)
//         if (length > remaining()) {
//             throw IndexOutOfBoundsException()
//         }
//         let end: Int64 = offset + length
//         for (i in offset..end) {
//             dst[i] = get()
//         }
//         return this
//     }

//     public func get(): UInt8 {
//         return buf[nextGetIndex()]
//     }

//     public func nextGetIndex(): Int64 {
//         if (position >= limit) {
//             throw Exception("position >= limit")
//         }
//         let num: Int64 = position
//         position++
//         return num
//     }

//     public func nextGetIndex(num: Int64): Int64 {
//         if (limit - position < num) {
//             throw Exception("limit - position < num")
//         }
//         let nums: Int64 = position
//         position += num
//         return nums
//     }

//     public func getString(): String {
//         var sb = ArrayList<Byte>()
//         var c: UInt8 = 0
//         while (true) {
//             c = getByte()
//             if (c == 0) {
//                 break
//             }
//             sb.add(c)
//         }
//         return String.fromUtf8(unsafe { sb.getRawArray()[0..sb.size] })
//     }

//     public func getNTString(): String {
//         var sb = ArrayList<Rune>()
//         var c: UInt8 = 0
//         while (true) {
//             c = getByte()
//             if (c == 0) {
//                 break
//             }
//             sb.add(Rune(c))
//         }
//         return String(sb)
//     }

//     @OverflowWrapping
//     public func getInt64(): Int64 {
//         return Int64(getUInt64())
//     }

//     public func getUInt64(): UInt64 {
//         if (remaining() < 8) {
//             throw Exception("remaining() < 8")
//         }
//         var val: UInt64 = UInt64(getByte())
//         val = (val << 8) + UInt64(getByte())
//         val = (val << 8) + UInt64(getByte())
//         val = (val << 8) + UInt64(getByte())
//         val = (val << 8) + UInt64(getByte())
//         val = (val << 8) + UInt64(getByte())
//         val = (val << 8) + UInt64(getByte())
//         val = (val << 8) + UInt64(getByte())
//         return val
//     }

//     public func getUInt32(): UInt32 {
//         if (remaining() < 4) {
//             throw Exception("remaining() < 4")
//         }
//         var val: UInt32 = UInt32(getByte())
//         val = (val << 8) + UInt32(getByte())
//         val = (val << 8) + UInt32(getByte())
//         val = (val << 8) + UInt32(getByte())
//         return val
//     }

//     @OverflowWrapping
//     public func getInt32(): Int32 {
//         return Int32(getUInt32())
//     }

//     public func getUInt16(): UInt16 {
//         if (remaining() < 2) {
//             throw Exception("remaining() < 2")
//         }
//         var val: UInt16 = UInt16(getByte())
//         val = (val << 8) + UInt16(getByte())
//         return val
//     }

//     @OverflowWrapping
//     public func getInt16(): Int16 {
//         return Int16(getUInt16())
//     }

//     public func getUInt8(): UInt8 {
//         let num: UInt8 = UInt8(get()) & 0xff
//         return num
//     }

//     public func getByte(): Byte {
//         let num: Byte = getUInt8()
//         return num
//     }

//     @OverflowWrapping
//     public func getInt8(): Int8 {
//         return Int8(getUInt8())
//     }

//     /**
//      * The Function is flip
//      *
//      * @return Type of ByteBuffer
//      * @since 0.29.3
//      */
//     public func flip(): ByteBuffer {
//         limit = position
//         position = 0
//         mark = -1
//         return this
//     }

//     /**
//      * The Function is putShort
//      *
//      * @param num of Int16
//      *
//      * @return Type of ByteBuffer
//      * @since 0.29.3
//      */
//     public func putShort(num: Int16): ByteBuffer {
//         putShortParts(
//             UInt8((num >> 0) & 0xff),
//             UInt8((num >> 8) & 0xff)
//         )
//         return this
//     }

//     /**
//      * The Function is putInt
//      *
//      * @param num of Int64
//      *
//      * @return Type of ByteBuffer
//      * @since 0.29.3
//      */
//     public func putInt(num: Int64): ByteBuffer {
//         putIntParts(
//             UInt8((num >> 0) & 0xff),
//             UInt8((num >> 8) & 0xff),
//             UInt8((num >> 16) & 0xff),
//             UInt8((num >> 24) & 0xff)
//         )
//         return this
//     }

//     private func putShortParts(i0: UInt8, i1: UInt8): Unit {
//         putByte(i1)
//         putByte(i0)
//     }

//     private func putIntParts(i0: UInt8, i1: UInt8, i2: UInt8, i3: UInt8): Unit {
//         putByte(i3)
//         putByte(i2)
//         putByte(i1)
//         putByte(i0)
//     }

//     private func putByte(offset: Int64, val: UInt8): Unit {
//         buf[offset] = val
//         position++
//     }

//     private func putByte(val: UInt8): Unit {
//         buf[position] = val
//         position++
//     }

//     public func reset(): Unit {
//         this.buf = ArrayList<UInt8>()
//         this.offset = 0
//         this.mark = -1
//         this.position = 0
//         this.limit = 0
//         this.capacity = 0
//     }
// }

// extend InnerByteBuffer <: ToString {
//     public func toString(): String {
//         var sb = StringBuilder()
//         for (i in 0..buf.size) {
//             sb.append(buf[i].format("#x"))
//             sb.append(" ")
//         }
//         return "bigEndian=${bigEndian}, buf=${sb.toString()}"
//     }
// }

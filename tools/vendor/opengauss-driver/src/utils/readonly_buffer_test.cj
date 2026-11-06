package cangjie_tpc::opengauss.utils

import std.unittest.* 
import std.unittest.testmacro.* 


@Test
public class TestReadOnlyBuffer {

    @TestCase
    func testReadOnlyBuffer(): Unit {
        var write_buffer = ReadWriteBuffer()
        write_buffer.add(1i8)     // setPosition(1)
        write_buffer.add(99i8)    // get()
        write_buffer.add(100i32)  // get(4)
        write_buffer.add(101i32)  // get(dst, 0, 4)
        write_buffer.add(102i64)  // getInt64()
        write_buffer.add(103i32)  // getInt32()
        write_buffer.add(104i16)  // getInt16()
        write_buffer.add(105i8)   // getInt8()
        write_buffer.add(106i8)   // getByte()
        write_buffer.add("abc")   // getString()
        write_buffer.add(0i8)
        write_buffer.add("123")   // getNTString()
        write_buffer.add(0i8)

        var cur_pos = 0i64
        let buf = write_buffer.data()
        let read_buffer = ReadOnlyBuffer(buf)
        @Assert(!read_buffer.isEmpty())
        @Assert(read_buffer.size == buf.size)
        @Assert(read_buffer.getPosition() == 0)
        @Assert(read_buffer.remaining() == buf.size)
        read_buffer.setPosition(1)
        cur_pos += 1
        @Assert(read_buffer.remaining() == buf.size - 1)
        @Assert(read_buffer.equals(read_buffer))
        @Assert(read_buffer.checkIndex(1) == 1)
        @Assert(read_buffer.hasRemaining())
        ReadOnlyBuffer.checkBounds(1i64, 4i64, 10i64)

        @Assert(read_buffer.get() == 99)
        cur_pos += 1
        @Assert(read_buffer.get(4).size == 4)
        cur_pos += 4

        var dst = Array<UInt8>(4, {i: Int64 => 0})
        read_buffer.get(dst, 0, 4)
        cur_pos += 4
        @Assert(read_buffer.getPosition() == cur_pos)

        @Assert(read_buffer.getInt64() == 102)
        cur_pos += 8
        @Assert(read_buffer.getInt32() == 103)
        cur_pos += 4
        @Assert(read_buffer.getInt16() == 104)
        cur_pos += 2
        @Assert(read_buffer.getInt8() == 105)
        cur_pos += 1
        @Assert(read_buffer.getByte() == 106)
        cur_pos += 1

        @Assert(read_buffer.getString() == "abc")
        read_buffer.getNTString()
        read_buffer.reset()
        read_buffer.toString()
        write_buffer.toString()
    }

}

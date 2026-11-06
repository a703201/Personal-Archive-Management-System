package cangjie_tpc::opengauss.utils

import std.unittest.* 
import std.unittest.testmacro.* 


@Test
public class TestReadWriteBuffer {

    @TestCase
    func testReadWriteBuffer(): Unit {
        var pos = 0i64
        var write_buffer = ReadWriteBuffer()
        write_buffer.add(1u64)
        pos += 8
        @Assert(write_buffer.getPosition() == pos)

        pos = 0i64
        write_buffer = ReadWriteBuffer(-1)
        write_buffer.add(1i64)
        pos += 8
        @Assert(write_buffer.getPosition() == pos)

        pos = 0i64
        write_buffer = ReadWriteBuffer(1024)
        write_buffer.add(1u32)
        pos += 4
        @Assert(write_buffer.getPosition() == pos)
        write_buffer.add(1i32)
        pos += 4
        @Assert(write_buffer.getPosition() == pos)
        write_buffer.add(1u16)
        pos += 2
        @Assert(write_buffer.getPosition() == pos)
        write_buffer.add(1i16)
        pos += 2
        @Assert(write_buffer.getPosition() == pos)
        write_buffer.add(1u8)
        pos += 1
        @Assert(write_buffer.getPosition() == pos)
        write_buffer.add(1i8)
        pos += 1
        @Assert(write_buffer.getPosition() == pos)
        @Assert(!write_buffer.isEmpty())
        @Assert(write_buffer.size == pos)
        @Assert(write_buffer.cloneData().size == pos)
        @Assert(write_buffer.data().size == pos)
        @Assert(write_buffer.data(0, pos).size == pos)
        write_buffer.add(write_buffer)
        pos += pos
        @Assert(write_buffer.getPosition() == pos)
        write_buffer.put(write_buffer.data(), 0, pos)
        pos += pos
        @Assert(write_buffer.getPosition() == pos)
        write_buffer.add(1i8)
        @Assert(write_buffer.data()[pos] == 1)
        write_buffer.setPosition(0i64)
        pos = 0
        @Assert(write_buffer.size == pos)

        var dst = Array<UInt8>(4, {i: Int64 => 0})
        write_buffer.add(dst)
        pos += 4
        @Assert(write_buffer.size == pos)
        write_buffer.add("adb")
        pos += 3
        @Assert(write_buffer.size == pos)

        write_buffer.toString()
        write_buffer.reset()
        write_buffer = ReadWriteBuffer(1)
        write_buffer.add(1u64)
        @Assert(write_buffer.size == 8)
        write_buffer = ReadWriteBuffer(1)
        write_buffer.add(1u32)
        @Assert(write_buffer.size == 4)
        write_buffer = ReadWriteBuffer(1)
        write_buffer.add(1u16)
        @Assert(write_buffer.size == 2)
        write_buffer = ReadWriteBuffer(1)
        write_buffer.add(1u8)
        write_buffer.add(1u8)
        @Assert(write_buffer.size == 2)
        write_buffer = ReadWriteBuffer(1)
        write_buffer.put(10, 11u8)
        @Assert(write_buffer.buf[10] == 11u8)
        write_buffer = ReadWriteBuffer(1)
        write_buffer.put(dst, 0, dst.size)
        @Assert(write_buffer.size == dst.size)
    }

}
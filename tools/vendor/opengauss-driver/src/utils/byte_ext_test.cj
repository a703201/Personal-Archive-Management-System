package cangjie_tpc::opengauss.utils

import std.unittest.* 
import std.unittest.testmacro.* 


@Test
public class TestByteExt {

    @TestCase
    func testBytesToString(): Unit {
        let s = "abc123"
        let prefix = "abc"
        @Assert(startWith(s.toArray(), prefix.toArray()))
        @Assert(bytesToString(s.toArray()) == s)

        var bytes = Array<Byte>(4, {i: Int64 => 0})
        @Assert(bytesToString(bytes).size == bytes.size)
        
        @Assert(bytesToString(s.toArray(), 0, s.size) == s)
        @Assert(bytesToString(s.toArray(), 0, s.size) == s)

        bytes = Array<Byte>(4, {i: Int64 => 0})
        let inputStream = ByteBuffer(bytes)
        @Assert(inputStreamToBytes(inputStream).size == bytes.size)
    }

    @TestCase
    func testBytesExtension(): Unit {
        let a = 11u64
        @Assert(a.sizeOf() == 8)
        @Assert(a.toLeBytes()[0] == UInt8(a))
        @Assert(a.toBeBytes()[7] == UInt8(a))

        let a1 = 11i64
        @Assert(a1.sizeOf() == 8)
        @Assert(a1.toLeBytes()[0] == UInt8(a1))
        @Assert(a1.toBeBytes()[7] == UInt8(a1))

        let a2 = 11u32
        @Assert(a2.sizeOf() == 4)
        @Assert(a2.toLeBytes()[0] == UInt8(a2))
        @Assert(a2.toBeBytes()[3] == UInt8(a2))

        let a3 = 11i32
        @Assert(a3.sizeOf() == 4)
        @Assert(a3.toLeBytes()[0] == UInt8(a3))
        @Assert(a3.toBeBytes()[3] == UInt8(a3))

        let a4 = 11u16
        @Assert(a4.sizeOf() == 2)
        @Assert(a4.toLeBytes()[0] == UInt8(a4))
        @Assert(a4.toBeBytes()[1] == UInt8(a4))

        let a5 = 11i16
        @Assert(a5.sizeOf() == 2)
        @Assert(a5.toLeBytes()[0] == UInt8(a5))
        @Assert(a5.toBeBytes()[1] == UInt8(a5))

        let a6 = 11u8
        @Assert(a6.sizeOf() == 1)
        @Assert(a6.toLeBytes()[0] == UInt8(a6))
        @Assert(a6.toBeBytes()[0] == UInt8(a6))

        let a7 = 11i8
        @Assert(a7.sizeOf() == 1)
        @Assert(a7.toLeBytes()[0] == UInt8(a7))
        @Assert(a7.toBeBytes()[0] == UInt8(a7))

        let s = "abc"
        @Assert(s.sizeOf() == s.size)
        @Assert(s.toBeBytes().size == s.size)
    }

}


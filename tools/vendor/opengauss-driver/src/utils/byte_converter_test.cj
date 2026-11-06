package cangjie_tpc::opengauss.utils

import std.unittest.* 
import std.unittest.testmacro.* 


@Test
public class TestByteConverter {

    @TestCase
    func testByteConverter(): Unit {
        var len = 100i64
        var dst = Array<UInt8>(len, {i: Int64 => 0})
        
        ByteConverter.put(dst, 0, "a")
        @Assert(dst[0] == 97u8)

        ByteConverter.put(dst, 0, true)
        @Assert(dst[0] == 1u8)

        ByteConverter.put(dst, 0, 10u8)
        @Assert(dst[0] == 10u8)

        ByteConverter.put(dst, 0, 11u16)
        @Assert(dst[1] == 11u8)

        ByteConverter.put(dst, 0, 12u32)
        @Assert(dst[3] == 12u8)

        ByteConverter.put(dst, 0, 13u64)
        @Assert(dst[7] == 13u8)
    }

}



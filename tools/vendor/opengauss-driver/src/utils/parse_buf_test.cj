package cangjie_tpc::opengauss.utils

import std.unittest.* 
import std.unittest.testmacro.* 


@Test
public class TestParseBuf {

    @TestCase
    func testParseBuf(): Unit {
        var len = 100i64
        var bytes = Array<Byte>(len, {i: Int64 => 0})
        var parseBuf = ParseBuf(bytes)

        parseBuf.eat(1)
        len -= 1
        @Assert(parseBuf.remaining() == len)

        parseBuf.parse<UInt64>()
        len -= 8
        @Assert(parseBuf.remaining() == len)

        parseBuf.parse(4)
        len -= 4
        @Assert(parseBuf.remaining() == len)
        
        let s = "adb"
        parseBuf = ParseBuf(s.toArray())
        parseBuf.parseEOFStr()
        @Assert(parseBuf.remaining() == 0)
    }

}




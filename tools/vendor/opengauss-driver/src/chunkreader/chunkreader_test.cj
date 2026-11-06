package cangjie_tpc::opengauss.chunkreader

import std.unittest.*
import std.unittest.testmacro.*
import std.io.ByteBuffer

@Test
public class TestChunkReader {

    @TestCase
    func testReadToEnd(): Unit {
        let len = CHUNK_BUF_LENGTH * 2
        var bytes = Array<Byte>(len, {i: Int64 => 0})
        let inputStream = ByteBuffer(bytes)

        var reader = ChunkReader(inputStream)        
        @Assert(reader.readToEnd().size == len)
    }

    @TestCase
    func testRead(): Unit {
        let len = CHUNK_BUF_LENGTH * 2
        var bytes = Array<Byte>(len, {i: Int64 => 0})
        let inputStream = ByteBuffer(bytes)

        var reader = ChunkReader(inputStream)
        @Assert(reader.read(len).getOrThrow().size == len)
    }

}

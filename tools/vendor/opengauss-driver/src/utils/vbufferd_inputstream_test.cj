package cangjie_tpc::opengauss.utils

import std.unittest.* 
import std.unittest.testmacro.* 
import std.io.*

@Test
func testVBufferedInputStream(): Unit {
    try {
        let data_len = 8192 * 2
        var data = Array<UInt8>(data_len, {i: Int64 => 0})
        var input = ByteBuffer(data)
        var input_stream = BufferedInputStream(input)
        var buffer = Array<UInt8>(data_len, {i: Int64 => 0})
        var vbuffer = VBufferedInputStream(input_stream)
        var read_len = 0
        vbuffer.get(buffer, 0, 10)
        read_len += 10
        vbuffer.get(buffer, 0, data_len - read_len)  // 如果要获取的消息比较大，那么直接读取数据

        input = ByteBuffer(data)
        input_stream = BufferedInputStream(input)
        vbuffer = VBufferedInputStream(input_stream)
        vbuffer.get(buffer, 0, 8000)
        read_len += 8000
        vbuffer.get(buffer, 0, data_len / 2)  // 剩余的数组长度不够，先把当前的数据拷贝出去

    } catch (ex: Exception) {
        @Assert(false)
    }
}

package cangjie_tpc::opengauss.url

import std.unittest.* 
import std.unittest.testmacro.* 

@Test
func testEncode(): Unit {
    var v = percent_decode("hello%20world") // "hello world"
    @Assert("hello world" == v)
    v = percent_decode("a%2Bb")         // "a+b"
    @Assert("a+b" == v)
    v = percent_decode("a+b", q: true)     // "a b"
    @Assert("a b" == v)
    v = percent_encode(1)              // "%01"
    @Assert("%01" == v)
}


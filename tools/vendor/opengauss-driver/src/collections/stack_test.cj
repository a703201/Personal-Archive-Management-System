package cangjie_tpc::opengauss.collections

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class TestStack {

    @TestCase
    func testStack(): Unit {
        var stack1 = InnerStack<Int32>()
        stack1.push(1)
        stack1.push(2)
        @Assert(stack1.pop() == 2)
        @Assert(stack1.size == 1)
        @Assert(!stack1.isEmpty())
        @Assert(stack1.peek().getOrThrow() == 1)

        var stack2 = stack1.clone()
        @Assert(stack2.size == 1)
    }

    @TestCase
    func tesStackIterator(): Unit {
        var stack = InnerStack<Int32>(1, {i: Int64 => 1i32})

        var iter = stack.iterator()
        @Assert(iter.next().getOrThrow() == 1)
    }

}



// ============================================================
// ams.data.repo.test · 标签层级纯函数（FR-TAG-005）
//
// 为什么单独一个目录：环路检测与深度计算是**纯函数**（不碰数据库），
// 可以在没有 openGauss 的环境里跑，也值得跑 —— 它们是自引用结构上
// 唯一能防止「把树写成环」的闸门，环一旦形成，前端递归渲染与级联
// 删除都会直接死循环。
// ============================================================
package ams.data.repo.test

import std.collection.*
import std.unittest.*

import ams.data.repo.*

@Test
public class TagTreeTest {
    /** 直线链：1(根) ← 2 ← 3 */
    private static func chain(): Array<(Int64, Int64)> {
        return [(1, 0), (2, 1), (3, 2)]
    }

    @TestCase
    public func testDepthOfChain() {
        let e = TagTreeTest.chain()
        @Assert(tagDepthOf(e, 1), 1)
        @Assert(tagDepthOf(e, 2), 2)
        @Assert(tagDepthOf(e, 3), 3)
        // 不在边表里的标签按顶层处理（防御坏数据，不抛异常）
        @Assert(tagDepthOf(e, 99), 1)
    }

    @TestCase
    public func testDepthLimitConstant() {
        @Assert(TAG_MAX_DEPTH, 5)
    }

    /** 挂到顶层 / 挂到兄弟节点：都不成环 */
    @TestCase
    public func testMoveToRootOrSiblingIsFine() {
        let e = TagTreeTest.chain()
        @Assert(tagMoveWouldCycle(e, 3, 0), false)
        @Assert(tagMoveWouldCycle(e, 3, 1), false)   // 1 不在 3 的子树里
        @Assert(tagMoveWouldCycle(e, 1, 0), false)
    }

    /** 把祖先挂到后代下 = 成环，必须拒绝 */
    @TestCase
    public func testMoveAncestorUnderDescendantIsCycle() {
        let e = TagTreeTest.chain()
        @Assert(tagMoveWouldCycle(e, 1, 3), true)
        @Assert(tagMoveWouldCycle(e, 1, 2), true)
        @Assert(tagMoveWouldCycle(e, 2, 3), true)
    }

    /** 自己挂自己 */
    @TestCase
    public func testSelfParentIsCycle() {
        let e = TagTreeTest.chain()
        @Assert(tagMoveWouldCycle(e, 2, 2), true)
    }

    /** 数据里已存在自引用（坏数据）时也要判定为环，不能死循环 */
    @TestCase
    public func testBrokenSelfEdgeIsCycle() {
        let e = [(1, 1), (2, 1)]
        @Assert(tagMoveWouldCycle(e, 2, 1), true)
        @Assert(tagMoveWouldCycle(e, 2, 0), false)
    }

    /** 两个节点互相引用（A←B、B←A）：步数上限必须拦截，不能无限循环 */
    @TestCase
    public func testMutualCycleTerminates() {
        let e = [(1, 2), (2, 1)]
        @Assert(tagMoveWouldCycle(e, 1, 2), true)
        @Assert(tagMoveWouldCycle(e, 2, 1), true)
    }
}

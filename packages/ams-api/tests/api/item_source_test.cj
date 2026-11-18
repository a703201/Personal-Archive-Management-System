// ============================================================
// ams-api · 条目来源枚举解析回归测试
//
// 背景：OCR 建档前端已传 source=3，但 POST /api/items 曾未读取该字段，
//       导致全部落库为 0（手动），按「OCR 识别」筛选永远为空。
// ============================================================
package ams.api.tests

import std.unittest.*
import std.unittest.testmacro.*

import ams.api.routes.*

/** OCR 来源 3 必须原样解析。 */
@Test
public func testParseItemSourceOcr(): Unit {
    match (SimpleJson.parse("{\"title\":\"x\",\"source\":3}")) {
        case Some(j) => @Assert(ItemRoutes.parseSource(j) == 3)
        case None => @Assert(false)
    }
}

/** 缺省 / 越界 / 负数统一降级为手动 0。 */
@Test
public func testParseItemSourceFallback(): Unit {
    match (SimpleJson.parse("{\"title\":\"x\"}")) {
        case Some(j) => @Assert(ItemRoutes.parseSource(j) == 0)
        case None => @Assert(false)
    }
    match (SimpleJson.parse("{\"source\":99}")) {
        case Some(j) => @Assert(ItemRoutes.parseSource(j) == 0)
        case None => @Assert(false)
    }
    match (SimpleJson.parse("{\"source\":-1}")) {
        case Some(j) => @Assert(ItemRoutes.parseSource(j) == 0)
        case None => @Assert(false)
    }
}

// ============================================================
// ams.api.http · 请求体上限分档单元测试
//
// 覆盖：默认接口 1MB；附件上传 / 批量导入 / AI 文件预填走 64MB
// 运行：bash scripts/test.sh ams-api
// ============================================================
package ams.api.http.test

import std.unittest.*
import std.unittest.testmacro.*

import ams.api.http.*

@Test
public class BodyCapTest {
    @TestCase
    public func testDefaultCap() {
        @Assert(bodyCapFor("/api/items"), MAX_BODY_BYTES)
        @Assert(bodyCapFor("/api/search/ask"), MAX_BODY_BYTES)
    }

    @TestCase
    public func testLargeCapForAiParseFile() {
        // 新建档案 AI 预填：证书原图 base64 可超 1MB（7016x4961 PNG ≈ 2MB）
        @Assert(bodyCapFor("/api/ai/parse-file"), MAX_LARGE_BODY_BYTES)
        @Assert(bodyCapFor("/api/attachments"), MAX_LARGE_BODY_BYTES)
        @Assert(bodyCapFor("/api/import/bundle"), MAX_LARGE_BODY_BYTES)
    }
}

package ams.app.ai.test

import ams.app.ai.*
import std.collection.*
import std.unittest.*

@Test
public class RecognizeFieldTest {
    @TestCase
    public func testPrettyJsonFieldMatch() {
        // 模型常返回 pretty JSON（冒号后带空格/换行），旧实现硬匹配 "code":"x" 会漏
        let arr = "[\n  {\n    \"code\": \"cert_name\",\n    \"value\": \"Huawei Certification\"\n  },\n  {\n    \"code\": \"cert_no\", \"value\": \"HCIA\"\n  }\n]"
        match (AiRecognizeService.findFieldValue(arr, "cert_name")) {
            case Some(v) => @Assert(v[0], "Huawei Certification")
            case None => @Assert(false, true)
        }
        match (AiRecognizeService.findFieldValue(arr, "cert_no")) {
            case Some(v) => @Assert(v[0], "HCIA")
            case None => @Assert(false, true)
        }
    }

    @TestCase
    public func testParseFieldsPrettyModelOutput() {
        // 真实 qwen2.5vl 输出（pretty JSON，冒号后带空格）
        let raw = "{\n  \"fields\": [\n    {\n      \"code\": \"cert_name\",\n      \"value\": \"Huawei Certification\"\n    },\n    {\n      \"code\": \"cert_no\",\n      \"value\": \"HCIA\"\n    }\n  ]\n}"
        let allowed = ArrayList<(String, String, Int64)>()
        allowed.add(("cert_name", "证书名称", 1))
        allowed.add(("cert_no", "证书编号", 1))
        let out = AiRecognizeService.parseFields(raw, allowed)
        @Assert(out.size, 2)
        if (out.size == 2) {
            @Assert(out[0].value, "Huawei Certification")
            @Assert(out[1].value, "HCIA")
        }
    }


    @TestCase
    public func testCompactJsonFieldMatch() {
        let arr = "[{\"code\":\"issuer\",\"value\":\"Huawei\",\"confidence\":0.95}]"
        match (AiRecognizeService.findFieldValue(arr, "issuer")) {
            case Some(v) => @Assert(v[0], "Huawei")
            case None => @Assert(false, true)
        }
    }
}
